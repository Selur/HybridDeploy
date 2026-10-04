#!/usr/bin/env bash
# Builds the VapourSynth plugins with no pip wheel, for the Linux AppImage bundle (Hybrid/docs/32-linux-appimage-vapoursynth.md).
# Usage: ./build-vapoursynth-plugins.sh [output-dir]  ->  <output-dir>/*.so

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${1:-$SCRIPT_DIR/vsplugins-build}"
WORK_DIR="$(mktemp -d)"
JOBS="$(nproc)"

# Keep in step with the macOS bundle's VapourSynth version (docs/16-macos-build.md).
VS_TAG="R79"

trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$OUT_DIR"
echo "Working directory: $WORK_DIR"
echo "Output directory:  $OUT_DIR"

# --- Step 1: pull the pip core wheel as a build SDK (headers + .pc) ---------
echo "Fetching vapoursynth core wheel (build SDK)..."
SDK_DIR="$WORK_DIR/sdk"
mkdir -p "$SDK_DIR"

# Same release as the bundled core (VS_VERSION in deploy-tools.sh), not the newest: R80 dropped API 3.
VS_WHEEL_URL=$(curl -s "https://pypi.org/pypi/vapoursynth/json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
v = sys.argv[1]
for u in d["releases"][v]:
    if "manylinux" in u["filename"] and "x86_64" in u["filename"] and "aarch64" not in u["filename"]:
        print(u["url"])
        break
' "${VS_TAG#R}")
curl -sL "$VS_WHEEL_URL" -o "$WORK_DIR/vapoursynth-core.whl"
python3 -c "
import zipfile
zipfile.ZipFile('$WORK_DIR/vapoursynth-core.whl').extractall('$SDK_DIR')
"

PC_FILE="$SDK_DIR/vapoursynth/pkgconfig/vapoursynth.pc"
# meson needs a libdir var to compute its (unused) install_dir; the pip wheel's .pc lacks one.
if ! grep -q '^libdir=' "$PC_FILE"; then
  sed -i '1a libdir=${prefix}/lib' "$PC_FILE"
fi
export PKG_CONFIG_PATH="$SDK_DIR/vapoursynth/pkgconfig"

# --- Step 2: the API 3 headers (DeblockPP7, FrFun7; the pip wheel only ships VapourSynth4.h) ----
echo "Fetching API3 headers ($VS_TAG)..."
API3_DIR="$WORK_DIR/api3"
mkdir -p "$API3_DIR/vapoursynth"
for h in VapourSynth.h VSHelper.h; do
  curl -sL "https://raw.githubusercontent.com/vapoursynth/vapoursynth/$VS_TAG/include/$h" -o "$API3_DIR/$h"
done
# Also expose the headers under the <vapoursynth/...> subpath.
cp "$API3_DIR"/*.h "$API3_DIR/vapoursynth/"

# --- Helpers -----------------------------------------------------------------

# build_meson <name> <git-url> <so-filename-in-build-dir> [extra CXXFLAGS] [branch-or-tag] [subdir-with-meson.build] [installed-filename] [extra meson args]
build_meson() {
  local name="$1" url="$2" so_name="$3" extra_cxxflags="${4:-}" branch="${5:-}" subdir="${6:-.}" dest_name="${7:-$3}" meson_args="${8:-}"
  echo "=== Building $name (meson) ==="
  local src="$WORK_DIR/$name"
  git clone --depth 1 ${branch:+--branch "$branch"} "$url" "$src"
  (
    cd "$src/$subdir"
    CXXFLAGS="$extra_cxxflags" meson setup build $meson_args
    ninja -C build -j"$JOBS"
  )
  cp "$src/$subdir/build/$so_name" "$OUT_DIR/$dest_name"
  echo "-> $OUT_DIR/$dest_name"
}

# --- Step 3: build the meson-based plugins ------------------------------

build_meson AddGrain \
  https://github.com/HomeOfVapourSynthEvolution/VapourSynth-AddGrain.git \
  libaddgrain.so

# API 4 port, same namespace and functions as the original
build_meson Retinex \
  https://github.com/Selur/VapourSynth-Retinex-api4.git \
  libretinex.so

build_meson TCanny \
  https://github.com/HomeOfVapourSynthEvolution/VapourSynth-TCanny.git \
  libtcanny.so

# --- Step 3a: plugins without a wheel, filters that had no Linux build before (docs 32, 6) ----------------
# API 3 plugins (R79 loads them): DeblockPP7, FrFun7. DeJitter (vcm) and ReduceFlicker come as API 4 wheels from deploy-tools.sh.
build_meson DeblockPP7 \
  https://github.com/HomeOfVapourSynthEvolution/VapourSynth-DeblockPP7.git \
  libdeblockpp7.so \
  "-I$API3_DIR"

build_meson Frfun7 \
  https://github.com/dubhatervapoursynth/vapoursynth-frfun7.git \
  libfrfun7.so \
  "-I$API3_DIR" v2

# Bore (API 4, GPL-3): GSL is linked statically so the bundle needs no libgsl; the distro libgsl.a is not PIC,
# so GSL is built from the tarball with --with-pic.
GSL_VERSION="2.8"
echo "=== Building GSL $GSL_VERSION (static, PIC, for Bore) ==="
GSL_SRC="$WORK_DIR/gsl-$GSL_VERSION"
curl -sfL "https://ftpmirror.gnu.org/gnu/gsl/gsl-$GSL_VERSION.tar.gz" | tar -xz -C "$WORK_DIR"
GSL_PREFIX="$WORK_DIR/gsl-prefix"
(
  cd "$GSL_SRC"
  ./configure --prefix="$GSL_PREFIX" --disable-shared --enable-static --with-pic -q
  make -j"$JOBS" -s
  make install -s
)
PKG_CONFIG_PATH="$GSL_PREFIX/lib/pkgconfig:$PKG_CONFIG_PATH" build_meson Bore \
  https://github.com/OpusGang/bore.git \
  libbore.so \
  "" "" . libbore.so "-Dstatic_gsl=true"

# --- Step 3b: neo-fft (cmake; replaces FFT3DFilter and DFTTest) -------------
# Built from the tag, not taken from the release zip: the release .so is built on glibc 2.43 and needs GLIBC_2.43,
# a source build links against the build host's glibc (2.32 on Ubuntu 24.04). Dependencies (dualsynth2, highway,
# pocketfft) are pinned by commit in the tag's cmake/Dependencies.cmake and fetched at configure time.
NEO_FFT_TAG="0.9.0"
echo "=== Building neo-fft $NEO_FFT_TAG (cmake) ==="
NF_SRC="$WORK_DIR/neo-fft"
git clone --depth 1 --branch "$NEO_FFT_TAG" https://github.com/HomeOfAviSynthPlusEvolution/neo-fft.git "$NF_SRC"
(
  cd "$NF_SRC"
  cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DNEO_FFT_BUILD_AVISYNTH=OFF
  cmake --build build --target neo_fft -j"$JOBS"
)
cp "$NF_SRC/build/neo-fft.so" "$OUT_DIR/"
echo "-> $OUT_DIR/neo-fft.so"

# --- Step 4: RemoveDirt (cmake, vendors its own API4 headers) --------------

echo "=== Building RemoveDirt (cmake) ==="
RD_SRC="$WORK_DIR/RemoveDirt"
git clone --depth 1 https://github.com/pinterf/RemoveDirt.git "$RD_SRC"
(
  cd "$RD_SRC"
  cmake .
  make -j"$JOBS"
)
cp "$RD_SRC/RemoveDirt/libremovedirt.so" "$OUT_DIR/"
echo "-> $OUT_DIR/libremovedirt.so"

# --- Step 5: RIFE (meson, ncnn+glslang as cmake subprojects) ---------------

echo "=== Building RIFE (meson + ncnn subproject) ==="
RIFE_SRC="$WORK_DIR/rife"
git clone --depth 1 --recurse-submodules \
  https://github.com/styler00dollar/VapourSynth-RIFE-ncnn-Vulkan.git "$RIFE_SRC"
(
  cd "$RIFE_SRC"
  meson setup build
  ninja -C build -j"$JOBS"
)
cp "$RIFE_SRC/build/librife.so" "$OUT_DIR/"
echo "-> $OUT_DIR/librife.so"

# --- Done --------------------------------------------------------------------

echo
echo "All plugins built:"
ls -la "$OUT_DIR"
echo
echo "Verifying entry points..."
for so in "$OUT_DIR"/*.so; do
  entry=$(nm -D --extern-only "$so" 2>/dev/null | grep -o 'VapourSynthPluginInit2\?' | head -1)
  printf '  %-24s %s\n' "$(basename "$so")" "${entry:-MISSING ENTRY POINT}"
done
