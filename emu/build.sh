#!/bin/bash
# iOS 26's QEMU (libqemu26.so) from the public sources, as the upstream author builds it in his WSL
# (13-qemu.sh, not in the repository): qemu-sptm, reims-vgpu and metal2vulkan at their asoft-android
# commits, with the NDK, against Termux's headers and the very libraries the upstream APK ships.
#   emu/build.sh WORKDIR UPSTREAM_APK        (ANDROID_NDK_HOME set)
# Patches in emu/patches/{qemu,reims,m2v}/*.patch are applied in order.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
W=$(mkdir -p "$1" && cd "$1" && pwd)
APK=$(realpath "$2")
API=29
QEMU_REV=b2dce3a693fbecadb9cd5e8def6681e978f91b6d
REIMS_REV=d011826e7660601710274bbbe0359806cbf584ab
M2V_REV=05d1bdaa5760686d8fd305c114b9361291f0bd9b
TC=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin
export PATH=$TC:$PATH
# our own compiler wrappers (the NDK's per-API ones are not relied on)
mkdir -p "$W/bin"
printf '#!/bin/sh\nexec "%s/clang" --target=aarch64-linux-android%s "$@"\n' "$TC" "$API" > "$W/bin/a64-clang"
printf '#!/bin/sh\nexec "%s/clang++" --target=aarch64-linux-android%s "$@"\n' "$TC" "$API" > "$W/bin/a64-clang++"
chmod +x "$W/bin/a64-clang" "$W/bin/a64-clang++"

fetch() {   # dir repo rev patches
    if [ ! -d "$W/$1/.git" ]; then
        git init -q "$W/$1"
        git -C "$W/$1" remote add origin "https://github.com/alpersamur3/$2"
    fi
    git -C "$W/$1" fetch -q --depth 1 origin "$3"
    git -C "$W/$1" checkout -q -f FETCH_HEAD
    git -C "$W/$1" clean -qfd
    for p in "$HERE/patches/$4"/*.patch; do
        [ -e "$p" ] || continue
        echo "patch $1: $(basename "$p")"
        git -C "$W/$1" apply --whitespace=nowarn "$p"
    done
}
fetch qemu qemu-sptm $QEMU_REV qemu
fetch reims-vgpu reims-vgpu $REIMS_REV reims
fetch metal2vulkan-win metal2vulkan $M2V_REV m2v     # reims' Cargo.toml patches metal2vulkan to this path

# -- Termux's headers and pkg-config files, the APK's libraries -----------------------------------
R=$W/root
P=$R/data/data/com.termux/files/usr
if [ ! -d "$P/include/glib-2.0" ]; then
    rm -rf "$R" && mkdir -p "$R" "$W/debs"
    M=https://packages.termux.dev/apt/termux-main
    curl -fsSL "$M/dists/stable/main/binary-aarch64/Packages" -o "$W/Packages"
    for pkg in glib pcre2 libffi libiconv libandroid-support zlib libpixman libpng libjpeg-turbo libgnutls libnettle libgmp \
               libidn2 libunistring libtasn1 libcurl openssl zstd libsnappy liblzo capstone libslirp dtc libbz2 ndk-sysroot; do
        f=$(awk -v p="$pkg" '$1=="Package:"{ok=($2==p)} ok&&$1=="Filename:"{print $2; exit}' "$W/Packages")
        [ -n "$f" ] || { echo "no Termux package $pkg" >&2; exit 1; }
        curl -fsSL "$M/$f" -o "$W/debs/$pkg.deb"
        [ "$pkg" = ndk-sysroot ] && continue        # the NDK's own sysroot is used
        dpkg-deb -x "$W/debs/$pkg.deb" "$R"
    done
    # link against what the phone will load: the APK's own libraries, under their sonames
    find "$P/lib" -maxdepth 1 \( -name '*.so' -o -name '*.so.*' -o -name '*.a' \) -delete
    mkdir -p "$W/apk" && unzip -q -o "$APK" 'lib/arm64-v8a/lib_*.so' -d "$W/apk"
    for f in "$W"/apk/lib/arm64-v8a/lib_*.so; do
        n=$(basename "$f"); n=${n#lib_}; n=${n%.so}          # lib_libz.so.1.so -> libz.so.1
        cp "$f" "$P/lib/$n"
        base=${n%%.so*}.so
        [ "$base" = "$n" ] || ln -sf "$n" "$P/lib/$base"
    done
    rm -f "$P/lib/libvulkan.so" "$P/lib/libvulkan_freedreno.so" "$P/lib/libc++_shared.so"
fi
ls "$P/lib" | tr '\n' ' '; echo

# -- reims-vgpu with metal2vulkan: the static archive and its pkg-config file -------------------
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=$W/bin/a64-clang
export CC_aarch64_linux_android=$W/bin/a64-clang
export CXX_aarch64_linux_android=$W/bin/a64-clang++
export AR_aarch64_linux_android=$TC/llvm-ar
# the library's inline atomics (ldapr, ldsetal) are ARMv8.2's: every phone iOS 26 runs on has them
export RUSTFLAGS="-C target-feature=+lse,+rcpc"
D=$W/dist
mkdir -p "$D/lib/pkgconfig" "$D/include"
(cd "$W/reims-vgpu" && rustup target add aarch64-linux-android >/dev/null &&
    cargo rustc --release -p reims-vgpu-c --lib --no-default-features --features reims-vgpu-c/vulkan \
        --target aarch64-linux-android --crate-type staticlib -- --print native-static-libs 2>&1 | tee "$W/reims-build.log" | tail -40)
NATIVE=$(sed -n 's/.*native-static-libs: //p' "$W/reims-build.log" | tail -1)
cp "$W/reims-vgpu/target/aarch64-linux-android/release/libreims_vgpu_c.a" "$D/lib/libreims_vgpu.a"
cp "$W/reims-vgpu/crates/reims-vgpu-c/include/reims_vgpu.h" "$D/include/"
cat > "$D/lib/pkgconfig/reims-vgpu.pc" <<PC
prefix=$D
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: reims-vgpu
Description: ReimsVGPU
Version: 0.1.0
Libs: -L\${libdir} -lreims_vgpu
Libs.private: ${NATIVE:--lm -ldl -lc}
Cflags: -I\${includedir}
PC
cat "$D/lib/pkgconfig/reims-vgpu.pc"

# -- QEMU ----------------------------------------------------------------------------------------
# pkg-config: Termux's files say prefix=/data/data/com.termux/files/usr, moved under $R; ours is absolute
cat > "$W/pkg-config" <<SH
#!/bin/sh
case " \$* " in
*" reims-vgpu "*|*" reims-vgpu"*) PKG_CONFIG_LIBDIR=$D/lib/pkgconfig exec /usr/bin/pkg-config "\$@" ;;
esac
PKG_CONFIG_SYSROOT_DIR=$R PKG_CONFIG_LIBDIR=$P/lib/pkgconfig:$P/share/pkgconfig exec /usr/bin/pkg-config "\$@"
SH
chmod +x "$W/pkg-config"
# bionic has no shm_open (and no librt): QEMU asks for the library where the function is missing. The app
# starts no memory-backend-shm; the stub says so to whoever would.
mkdir -p "$W/stub"
cat > "$W/stub/rt.c" <<'C'
#include <errno.h>
#include <sys/types.h>
int shm_open(const char *name, int oflag, mode_t mode) { (void)name; (void)oflag; (void)mode; errno = ENOSYS; return -1; }
int shm_unlink(const char *name) { (void)name; errno = ENOSYS; return -1; }
C
"$W/bin/a64-clang" -O2 -c -o "$W/stub/rt.o" "$W/stub/rt.c" && "$TC/llvm-ar" rcs "$W/stub/librt.a" "$W/stub/rt.o"
B=$W/qemu-build
rm -rf "$B" && mkdir -p "$B" && cd "$B"
AR=$TC/llvm-ar NM=$TC/llvm-nm OBJCOPY=$TC/llvm-objcopy RANLIB=$TC/llvm-ranlib STRIP=$TC/llvm-strip PKG_CONFIG=$W/pkg-config \
"$W/qemu/configure" --target-list=aarch64-softmmu --cross-prefix=aarch64-linux-android- --cpu=aarch64 \
    --cc="$W/bin/a64-clang" --cxx="$W/bin/a64-clang++" --host-cc=gcc \
    --extra-cflags="-O2 -fno-emulated-tls -I$P/include" --extra-ldflags="-L$P/lib -L$W/stub -Wl,-rpath-link,$P/lib" \
    --enable-reims-vgpu --disable-docs --disable-werror --disable-guest-agent --disable-tools \
    --disable-vnc-sasl --disable-linux-aio --disable-linux-io-uring --disable-kvm \
    --disable-vhost-user --disable-vhost-net --disable-vhost-kernel --disable-vhost-crypto --disable-vhost-vdpa \
    --disable-vhost-user-blk-server \
    || { echo "== config.log"; tail -60 "$B/config.log" || true; echo "== meson-log"; tail -200 "$B/meson-logs/meson-log.txt" || true; exit 1; }
ninja -C "$B" -k 0 qemu-system-aarch64 > "$W/ninja.log" 2>&1 || { grep -E "FAILED|error:|undefined" "$W/ninja.log" | sort | uniq -c | sort -rn | head -80; tail -30 "$W/ninja.log"; exit 1; }
tail -3 "$W/ninja.log"
"$TC/llvm-strip" --strip-debug -o "$W/libqemu26.so" "$B/qemu-system-aarch64"
ls -la "$W/libqemu26.so"
"$TC/llvm-readelf" -d "$W/libqemu26.so" | grep NEEDED
