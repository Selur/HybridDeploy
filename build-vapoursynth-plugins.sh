#!/usr/bin/env bash
# Builds the VapourSynth plugins with no pip wheel, for the Linux AppImage bundle (Hybrid/docs/32-linux-appimage-vapoursynth.md).
# Usage: ./build-vapoursynth-plugins.sh [output-dir]  ->  <output-dir>/*.so

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${1:-$SCRIPT_DIR/vsplugins-build}"
WORK_DIR="$(mktemp -d)"
JOBS="$(nproc)"

# Keep in step with VS_VERSION in deploy-tools.sh (R81, like the Windows trees; macOS stays on R79, docs/16-macos-build.md).
VS_TAG="R81"

trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$OUT_DIR"
echo "Working directory: $WORK_DIR"
echo "Output directory:  $OUT_DIR"

# --- Step 1: pull the pip core wheel as a build SDK (headers + .pc) ---------
echo "Fetching vapoursynth core wheel (build SDK)..."
SDK_DIR="$WORK_DIR/sdk"
mkdir -p "$SDK_DIR"

# Same release as the bundled core (VS_VERSION in deploy-tools.sh), not the newest.
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
# FrFun7, DeJitter (vcm), ReduceFlicker and DeblockPP7 come as API 4 wheels from deploy-tools.sh, so no API 3 plugin is built here any more.

# Bore (API 4, GPL-3): GSL is linked statically so the bundle needs no libgsl; the distro libgsl.a is not PIC,
# so GSL is built from the tarball with --with-pic.
GSL_VERSION="2.8"
echo "=== Building GSL $GSL_VERSION (static, PIC, for Bore) ==="
GSL_SRC="$WORK_DIR/gsl-$GSL_VERSION"
# Download to a file, try several mirrors and check the SHA-256 before unpacking: ftpmirror.gnu.org redirects to a mirror that is
# sometimes down, and a truncated stream piped into tar ended the whole deploy.
GSL_SHA256="6a99eeed15632c6354895b1dd542ed5a855c0f15d9ad1326c6fe2b2c9e423190"
GSL_TARBALL="$WORK_DIR/gsl-$GSL_VERSION.tar.gz"
gsl_ok=0
for base in https://ftp.fau.de/gnu/gsl https://mirror.dogado.de/gnu/gsl https://mirrors.kernel.org/gnu/gsl https://ftpmirror.gnu.org/gnu/gsl https://ftp.gnu.org/gnu/gsl; do
  if curl -sfL --retry 2 --retry-delay 3 --connect-timeout 15 -m 120 -o "$GSL_TARBALL" "$base/gsl-$GSL_VERSION.tar.gz" \
     && echo "$GSL_SHA256  $GSL_TARBALL" | sha256sum -c --status -; then
    gsl_ok=1
    break
  fi
  echo "  ⚠️ gsl-$GSL_VERSION.tar.gz from $base failed or does not match the SHA-256, trying the next mirror"
done
[ "$gsl_ok" = 1 ] || { echo "  ❌ could not download gsl-$GSL_VERSION.tar.gz"; exit 1; }
tar -xzf "$GSL_TARBALL" -C "$WORK_DIR"
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

# --- Step 3c: neo-smo (cmake; second implementation of rg, ttempsmooth, cnr, ccd beside zsmooth, docs 60) ---
NEO_SMO_TAG="0.9.2"
echo "=== Building neo-smo $NEO_SMO_TAG (cmake) ==="
NS_SRC="$WORK_DIR/neo-smo"
git clone --depth 1 --branch "$NEO_SMO_TAG" https://github.com/HomeOfAviSynthPlusEvolution/neo-smo.git "$NS_SRC"
(
  cd "$NS_SRC"
  cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DNEO_SMO_BUILD_AVISYNTH=OFF -DBUILD_TESTING=OFF
  cmake --build build --target neo_smo -j"$JOBS"
)
cp "$NS_SRC/build/neo-smo.so" "$OUT_DIR/"
echo "-> $OUT_DIR/neo-smo.so"

# --- Step 3d: Anime4KCPP (cmake; resizer Anime4KCPP, VapourSynth filter only, CPU and OpenCL, no CUDA) ---
# OpenCL loader and libgomp go to site-packages/vapoursynth_anime4kcpp.libs/, the place auditwheel uses for the wheels
A4K_TAG="v3.2.0"
echo "=== Building Anime4KCPP $A4K_TAG (cmake) ==="
A4K_SRC="$WORK_DIR/Anime4KCPP"
git clone --depth 1 --branch "$A4K_TAG" https://github.com/TianZerL/Anime4KCPP.git "$A4K_SRC"
(
  cd "$A4K_SRC"
  cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DAC_BUILD_CLI=OFF -DAC_BUILD_FILTER_VAPOURSYNTH=ON -DAC_CORE_WITH_OPENCL=ON \
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON '-DCMAKE_INSTALL_RPATH=$ORIGIN/../../vapoursynth_anime4kcpp.libs'
  cmake --build build --target ac_filter_vs -j"$JOBS"
)
cp "$A4K_SRC/build/bin/libac_filter_vs.so" "$OUT_DIR/libanime4kcpp.so"
mkdir -p "$OUT_DIR/vapoursynth_anime4kcpp.libs"
for lib in libOpenCL.so.1 libgomp.so.1; do
  cp -L "$(ldconfig -p | awk -v l="$lib" '$1 == l && /x86-64/ {print $NF; exit}')" "$OUT_DIR/vapoursynth_anime4kcpp.libs/$lib"
done
echo "-> $OUT_DIR/libanime4kcpp.so (+ vapoursynth_anime4kcpp.libs/)"

# --- Step 4: RemoveDirt (cmake, vendors its own API4 headers) --------------

echo "=== Building RemoveDirt (cmake) ==="
RD_SRC="$WORK_DIR/RemoveDirt"
git clone --depth 1 https://github.com/pinterf/RemoveDirt.git "$RD_SRC"
(
  cd "$RD_SRC"
  # RestoreMotionBlocks shares one block buffer across frames: fmParallel gives other frames per run (pinterf/RemoveDirt#5)
  sed -i 's/restoreMotionBlocksFree, fmParallel, deps/restoreMotionBlocksFree, fmParallelRequests, deps/' RemoveDirt/RemoveDirt.cpp
  grep -aq 'restoreMotionBlocksFree, fmParallelRequests, deps' RemoveDirt/RemoveDirt.cpp || { echo "RemoveDirt patch did not apply"; exit 1; }
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
