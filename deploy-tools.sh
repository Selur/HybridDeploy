#!/usr/bin/env bash
# build-appimage.sh

set -euo pipefail


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$SCRIPT_DIR/tools"

if [ ! -d "$TOOLS_DIR" ]; then
  echo "❌ tools directory not found: $TOOLS_DIR"
  exit 1
fi

all_binaries=$(find "$TOOLS_DIR" -maxdepth 1 -type f ! -name "*-sources.txt" -exec basename {} \; | tr '\n' ' ')
if [ -z "$all_binaries" ]; then
  echo "❌ No tool binaries found in $TOOLS_DIR"
  exit 1
fi

# CLI args
COMPRESS=0
KEEP_APPDIR=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --compress) COMPRESS=1; shift ;;
    --keep-appdir) KEEP_APPDIR=1; shift ;;
    -h|--help) echo "Usage: $0 [--compress] [--keep-appdir]"; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

version=$(date +"%Y.%m.%d.1")
OUT_APPIMAGE="$SCRIPT_DIR/Hybrid-$version-x86_64.AppImage"
echo "🧱 Building Hybrid version: $version -> $OUT_APPIMAGE"

# --- Verify binaries ---
echo "🔍 Checking binaries..."
missing_bins=""
for bin in $all_binaries; do
  if [ ! -f "$TOOLS_DIR/$bin" ]; then
    echo "❌ Missing: $bin"
    missing_bins="$missing_bins $bin"
  else
    echo "✅ Found: $bin"
  fi
done

if [ -n "$missing_bins" ]; then
  echo "⚠️ Missing binaries: $missing_bins"
  echo "❌ Aborting build due to missing binaries."
  exit 1
fi

# --- Check dependencies (installed by setup-root.sh, the only step with sudo) ---
source "$SCRIPT_DIR/apt-packages.sh"
require_packages "${DEPLOY_PACKAGES[@]}"

# --- Prepare AppDir ---
DEPLOY_DIR="$SCRIPT_DIR/hybrid"
APPDIR="$DEPLOY_DIR/AppDir"

rm -rf "$DEPLOY_DIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib" "$APPDIR/usr/lib32" \
         "$APPDIR/usr/share/applications" "$APPDIR/usr/share/icons/hicolor/512x512/apps"

echo "📦 Copying tool binaries into AppDir..."
for bin in $all_binaries; do
  cp "$TOOLS_DIR/$bin" "$APPDIR/usr/bin/"
  chmod +x "$APPDIR/usr/bin/$bin"
done

# --- VapourSynth: bundled interpreter + wheelhouse + hand-built plugins --- see Hybrid/docs/32-linux-appimage-vapoursynth.md
echo "🐍 Bundling VapourSynth (interpreter + pip wheelhouse + native plugins)..."

VS_DIR="$APPDIR/usr/vapoursynth"
VS_PYTHON="$VS_DIR/python"
mkdir -p "$VS_DIR"

VS_PBS_TAG="20260901"
VS_PBS_ASSET="cpython-3.14.7+${VS_PBS_TAG}-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz"
if [ ! -x "$VS_PYTHON/bin/python3" ]; then
  echo "  ⬇️ Fetching python-build-standalone ($VS_PBS_TAG)..."
  curl -sL "https://github.com/astral-sh/python-build-standalone/releases/download/${VS_PBS_TAG}/${VS_PBS_ASSET}" \
    -o "$DEPLOY_DIR/python.tar.gz"
  mkdir -p "$VS_PYTHON"
  tar xzf "$DEPLOY_DIR/python.tar.gz" -C "$VS_DIR"
  rm -f "$DEPLOY_DIR/python.tar.gz"
fi

VS_PY_BIN="$VS_PYTHON/bin/python3"
"$VS_PY_BIN" -m ensurepip --upgrade >/dev/null 2>&1 || true

# Core pin for every pip call (same as VS_TAG); R81 loads no API 3 plugins, bestsource stays 21 (docs 32, 7 and 56, 2 D).
VS_VERSION="81"
echo "vapoursynth==$VS_VERSION" > "$DEPLOY_DIR/vs-constraints.txt"
export PIP_CONSTRAINT="$DEPLOY_DIR/vs-constraints.txt"

# open-svpflow (Interframe/SVP and the SVP methods, docs 47) comes from pip, wheels are bit-identical to the pinned
# nightly-20260930-baaaaaadcee8; the plugins land in site-packages/vapoursynth/plugins/open-svpflow/ (Autoload finds them).
# Packages confirmed to have a working manylinux wheel (docs 32, 1); dghdrtosdr excluded, win_amd64-only, see docs 32, 1.
VS_PIP_PACKAGES="
vapoursynth
vapoursynth-mvutensils vapoursynth-adaptivegrain vapoursynth-akarin
vapoursynth-awarp vapoursynth-bestsource==21
vapoursynth-bm3d vapoursynth-bm3dvk vapoursynth-bm3dvk2 vapoursynth-bwdif vapoursynth-cas vapoursynth-cdef
vapoursynth-cranexpr vapoursynth-d2vsource vapoursynth-dctfilter vapoursynth-dfttest2-cpu
vapoursynth-deblock vapoursynth-decross vapoursynth-dedot vapoursynth-descale
vapoursynth-descratch vapoursynth-dotkill vapoursynth-edgefixer
vapoursynth-edgemasks vapoursynth-eedi3 vapoursynth-eedi3vk2
vapoursynth-fillborders vapoursynth-ffms2 vapoursynth-fmtconv
vapoursynth-hysteresis vapoursynth-iscombed vapoursynth-knlmeanscl
vapoursynth-lsmas vapoursynth-readmpls
vapoursynth-mvtools vapoursynth-nnedi3vk vapoursynth-knlmeansvk vapoursynth-feel
vapoursynth-nlm-ispc vapoursynth-resize2 vapoursynth-sangnom
vapoursynth-scenechange vapoursynth-scxvid vapoursynth-sneedif vapoursynth-subtext
vapoursynth-timecube vapoursynth-vivtc vapoursynth-tivtc
vapoursynth-bifrost vapoursynth-vszip vapoursynth-vszipcu
vapoursynth-vszipcl vapoursynth-zit vapoursynth-znedi3
vapoursynth-zsmooth vapoursynth-oxidctf vapoursynth-composite
vapoursynth-interlace vs-placebo vsnoise
open-svpflow==0.1.0
"
echo "  📦 Installing pip wheelhouse..."
for pkg in $VS_PIP_PACKAGES; do
  "$VS_PY_BIN" -m pip install "$pkg" \
    --extra-index-url https://jaded-encoding-thaumaturgy.github.io/vs-wheels/simple/ \
    --disable-pip-version-check -q \
    || echo "  ⚠️ $pkg failed to install (see docs 32, 1 for known exceptions)"
done

echo "  📦 Installing GitHub-release wheels (vinverse, grwrld)..."
"$VS_PY_BIN" -m pip install --disable-pip-version-check -q \
  "https://github.com/Asd-g/vinverse/releases/download/0.9.6/vapoursynth_vinverse-0.9.6-py3-none-manylinux_2_24_x86_64.manylinux_2_28_x86_64.whl" \
  "https://github.com/Asd-g/AviSynthPlus-grayworld/releases/download/1.0.4/vapoursynth_grwrld-1.0.4-py3-none-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl"

# Own plugins with GitHub release wheels (API 4, x86_64 only here): always the latest release.
# Tag, wheel URL and SHA-256 come from the release API; the wheel is picked by platform (manylinux x86_64), not by name,
# because a release can keep the version of its metadata in the file name (MiniDeenNeo v1.1 ships *-1.0-*.whl).
# GitHub (API and the signed release-asset redirect) now and then fails for a moment; a single failed request must not end a deploy that has run for minutes.
CURL_RETRY=(--retry 3 --retry-delay 5 --retry-all-errors)
# install_latest_release_wheel <label> <owner/repo>
install_latest_release_wheel() {
  local label="$1" repo="$2" info tag url sha wheel
  echo "  📦 Installing $label (latest release of $repo)..."
  info=$(curl -sfL "${CURL_RETRY[@]}" "https://api.github.com/repos/$repo/releases/latest" | "$VS_PY_BIN" -c '
import json, sys
d = json.load(sys.stdin)
for a in d["assets"]:
    n = a["name"]
    if n.endswith(".whl") and "manylinux" in n and "x86_64" in n:
        print(d["tag_name"], a["browser_download_url"], a.get("digest", "").removeprefix("sha256:"), n)
        break
else:
    sys.exit("no manylinux x86_64 wheel in the latest release")
') || { echo "  ❌ could not resolve the latest $label release"; exit 1; }
  read -r tag url sha wheel <<< "$info"
  echo "     $tag ($wheel)"
  curl -sfL "${CURL_RETRY[@]}" -o "$DEPLOY_DIR/$wheel" "$url" || { echo "  ❌ download of $wheel failed"; exit 1; }
  if [ -n "$sha" ]; then
    echo "$sha  $DEPLOY_DIR/$wheel" | sha256sum -c - || exit 1
  fi
  "$VS_PY_BIN" -m pip install --disable-pip-version-check -q --no-deps "$DEPLOY_DIR/$wheel"
}
# neo-minideen (MiniDeenNeo, docs 49), hqdn3d (Selur/vapoursynth-hqdn3d, 8-16 bit integer and GRAY since 1.1),
# eedi2 (Selur/VapourSynth-EEDI2, API 4 port of the EEDI2 plugin, same namespace),
# neo-vague-denoiser (Selur/neo_Vague_Denoiser, API 4, namespace neo_vd, docs 52)
install_latest_release_wheel neo-minideen Selur/MiniDeenNeo
install_latest_release_wheel hqdn3d Selur/vapoursynth-hqdn3d
install_latest_release_wheel eedi2 Selur/VapourSynth-EEDI2
install_latest_release_wheel neo-vague-denoiser Selur/neo_Vague_Denoiser
# vcm (DeJitter, Selur/vcm v1.0.1: API 4 port that fixes jmax = 0) and ReduceFlicker (Selur/ReduceFlicker v1.0.2: API 4 port, runs 12 bit);
# both wheels put libvcm.so / libReduceFlicker.so into vapoursynth/plugins, same namespaces (vcm, rdfl) as the API 3 builds they replace
install_latest_release_wheel vcm Selur/vcm
install_latest_release_wheel ReduceFlicker Selur/ReduceFlicker
# DeblockPP7 (Selur/VapourSynth-DeblockPP7 v5: API 4 port, namespace pp7, libdeblockpp7.so)
install_latest_release_wheel DeblockPP7 Selur/VapourSynth-DeblockPP7
# FrFun7 (Selur/vapoursynth-frfun7 v1: API 4 port, 8 bit only, libfrfun7.so in vapoursynth/plugins, same namespace as the API 3 build it replaces)
install_latest_release_wheel FrFun7 Selur/vapoursynth-frfun7

# smoothuv (RainbowSmooth, docs 32, 6): API 4 port from AliceTeaParty/vapoursynth-api4-wheels, a third-party repo, so URL and SHA-256 are pinned.
# The wheel also ships a RainbowSmooth.py without Hybrid's `tools` argument; Hybrid's vsscripts come first in sys.path, the copy is deleted anyway.
SMOOTHUV_WHEEL="vapoursynth_smoothuv-3.1-py3-none-manylinux_2_27_x86_64.whl"
SMOOTHUV_URL="https://github.com/AliceTeaParty/vapoursynth-api4-wheels/releases/download/vapoursynth-smoothuv-v3.1/$SMOOTHUV_WHEEL"
SMOOTHUV_SHA256="8a2dd7a7aaf76751eb037cb77a6b45479dbdd1e01676738792a7973ff957eb68"
echo "  📦 Installing smoothuv 3.1..."
curl -sfL "${CURL_RETRY[@]}" -o "$DEPLOY_DIR/$SMOOTHUV_WHEEL" "$SMOOTHUV_URL" || { echo "  ❌ download of $SMOOTHUV_WHEEL failed"; exit 1; }
echo "$SMOOTHUV_SHA256  $DEPLOY_DIR/$SMOOTHUV_WHEEL" | sha256sum -c - || exit 1
"$VS_PY_BIN" -m pip install --disable-pip-version-check -q --no-deps "$DEPLOY_DIR/$SMOOTHUV_WHEEL"
rm -f "$VS_PYTHON/lib/python3.14/site-packages/RainbowSmooth.py"

echo "  📦 Installing vsjetpack from git..."
"$VS_PY_BIN" -m pip install --disable-pip-version-check -q \
  "vsjetpack @ git+https://github.com/Jaded-Encoding-Thaumaturgy/vs-jetpack.git@main"

# pip's vspipe entry script carries this build machine's interpreter path as shebang and would shadow the real
# vspipe (site-packages/vapoursynth, next in AppRun's PATH) - it only works where the build tree still exists.
rm -f "$VS_PYTHON/bin/vspipe"
# python/bin/ffmsindex (statically linked, from the vapoursynth-ffms2 wheel) stays: Hybrid indexes FFMS2 jobs with it, so the index matches libffms2.so.

VS_SITE="$VS_PYTHON/lib/python3.14/site-packages"
VS_PLUGDIR="$VS_SITE/vapoursynth/plugins"

echo "  🔧 Building the 12 plugins with no pip wheel (docs 32, 1)..."
"$SCRIPT_DIR/build-vapoursynth-plugins.sh" "$DEPLOY_DIR/vsplugins-build"
cp "$DEPLOY_DIR"/vsplugins-build/*.so "$VS_PLUGDIR/"

echo "  🔧 Installing vsconfig-write.py (fixes vspipe on python-build-standalone, docs 32, 2.1)..."
cp "$SCRIPT_DIR/vsconfig-write.py" "$VS_SITE/vapoursynth/"

if [ ! -d "$VS_DIR/vsscripts/.git" ]; then
  echo "  ⬇️ Cloning vsscripts..."
  git clone --depth 1 https://github.com/Selur/VapoursynthScriptsInHybrid.git "$VS_DIR/vsscripts"
fi

# GLSL shader sources for the GLSL* color/sharpen filters and the GLSL-Resizers AI upscalers
# (docs 32, 2.6); two different base paths, matching where Hybrid's own C++ looks for each:
# GLSL/ under the plugins dir (VsFilter::filterLocation), GLSL-Resizers/ next to the binary itself.
GLSL_CLONE="$DEPLOY_DIR/hybrid-glsl-filters"
if [ ! -d "$GLSL_CLONE/.git" ]; then
  echo "  ⬇️ Cloning hybrid-glsl-filters..."
  git clone --depth 1 https://github.com/Selur/hybrid-glsl-filters.git "$GLSL_CLONE"
fi
cp -r "$GLSL_CLONE/GLSL" "$VS_PLUGDIR/"
cp -r "$GLSL_CLONE/GLSL-Resizers" "$APPDIR/usr/bin/"

# Hybrid's translations (docs 58) go next to the binary; qtbase_*.qm already sit in usr/translations (qt.conf).
HYBRID_SRC="${HYBRID_SRC:-$SCRIPT_DIR/../Hybrid}"
if ! ls "$HYBRID_SRC"/translations/hybrid_*.ts >/dev/null 2>&1; then
  echo "  ❌ no translations/hybrid_*.ts in $HYBRID_SRC (set HYBRID_SRC to the Hybrid checkout)"
  exit 1
fi
mkdir -p "$APPDIR/usr/bin/translations"
cp "$HYBRID_SRC"/translations/hybrid_*.ts "$APPDIR/usr/bin/translations/"
echo "  🌐 $(ls "$APPDIR"/usr/bin/translations/hybrid_*.ts | wc -l) translations from $HYBRID_SRC"

# Stable, Python-version-independent paths for Hybrid's C++ side (Stufe E); "site-packages" name is required, see SystemHelper::resolveVapoursynthSitePackagesPath().
ln -sf "python/lib/python3.14/site-packages" "$VS_DIR/site-packages"
ln -sf "site-packages/vapoursynth/vspipe" "$VS_DIR/vspipe"

echo "🔍 Scanning for missing dependencies..."

MISSING_LIBS=()

scan_binary_deps() {
    local BIN="$1"

    while IFS= read -r line; do
        lib=$(echo "$line" | awk '{print $1}')
        echo "  ❌ Missing dependency: $lib for $BIN"
        MISSING_LIBS+=("$lib")
    done < <(ldd "$BIN" 2>/dev/null | grep "not found" || true)
}

# Scan using original binaries (correct)
for bin in $all_binaries; do
    echo "➡️ Checking: $bin"
    scan_binary_deps "$TOOLS_DIR/$bin"
done

# Remove duplicates
MISSING_LIBS=($(printf "%s\n" "${MISSING_LIBS[@]}" | sort -u))
echo "📋 Missing libs to bundle: ${MISSING_LIBS[*]}"

echo "🔧 Resolving missing libraries..."

resolve_and_copy_lib() {
    local LIB="$1"
    local FOUND=""

    FOUND=$(ldconfig -p | grep "/$LIB" | awk '{print $NF}' | head -n1 || true)

    if [ -z "$FOUND" ]; then
        echo "  ⚠️ Could not locate: $LIB"
        return 1
    fi

    echo "  📦 Copying: $FOUND"
    cp -v --preserve=links "$FOUND" "$APPDIR/usr/lib/" || true

    local DIR=$(dirname "$FOUND")
    local BASE=$(basename "$FOUND" | sed 's/\.so.*/.so/')

    for so in "$DIR/$BASE"*; do
        [ -f "$so" ] && cp -v --preserve=links "$so" "$APPDIR/usr/lib/" || true
    done
}

for lib in "${MISSING_LIBS[@]}"; do
    resolve_and_copy_lib "$lib"
done

echo "🔄 Re-checking dependencies after bundling..."
UNRESOLVED_AGAIN=0

for bin in $all_binaries; do
    echo "➡️ Checking: $bin"
    if ldd "$TOOLS_DIR/$bin" | grep -q "not found"; then
        echo "  ❌ Still missing after bundling!"
        UNRESOLVED_AGAIN=1
    fi
done

if [ "$UNRESOLVED_AGAIN" -eq 1 ]; then
    echo "⚠️ Warning: Some libraries could not be resolved automatically."
else
    echo "✅ All dependencies successfully bundled."
fi

# --- 32-bit runtime support ---
echo "🔍 Bundling 32-bit libraries..."
for bin in $all_binaries; do
    if file "$APPDIR/usr/bin/$bin" | grep -q "32-bit"; then
        echo "📦 Detected 32-bit binary: $bin"
        deps=$(ldd "$APPDIR/usr/bin/$bin" | awk '/=>/ {print $3}' | grep "^/lib" || true)
        for dep in $deps; do
            if [ -f "$dep" ]; then
                echo "  ↳ Copying dependency: $dep"
                target="$APPDIR/usr/lib32$(dirname "$dep")"
                mkdir -p "$target"
                cp -v --preserve=links "$dep" "$target"/ || true
            fi
        done
        if [ -f "/lib/ld-linux.so.2" ]; then
            echo "  ↳ Copying ld-linux.so.2"
            cp -v /lib/ld-linux.so.2 "$APPDIR/usr/lib32/" || true
        fi
    fi
done

# --- Icon + desktop file ---
ICON_PATH="$SCRIPT_DIR/icons/icon.png"
if [ ! -f "$ICON_PATH" ]; then
  echo "❌ Icon missing: $ICON_PATH"
  exit 1
fi

# linuxdeploy only accepts a fixed set of icon resolutions (8..512px) for -i; the 1024px source fails with
# "invalid x resolution" and linuxdeploy aborts to the fallback path. The hicolor theme also only
# recognizes sizes its own index.theme declares (checked against the system's hicolor/index.theme -
# "1024x1024" isn't one of them, "512x512" is), so QIcon::fromTheme("hybrid") silently finds nothing
# at 1024x1024 regardless of XDG_DATA_DIRS. Both uses share the same 512px downscale.
magick "$ICON_PATH" -resize 512x512 "$APPDIR/hybrid.png"
cp "$APPDIR/hybrid.png" "$APPDIR/usr/share/icons/hicolor/512x512/apps/hybrid.png"

cat <<EOF > "$APPDIR/usr/share/applications/hybrid.desktop"
[Desktop Entry]
Name=Hybrid
Comment=Video Encoding Tool
Exec=HybridLauncher
Icon=hybrid
Terminal=false
Type=Application
Categories=AudioVideo;Video;
EOF

# --- Launchers ---
cat <<'EOF' > "$APPDIR/usr/bin/HybridLauncher"
#!/usr/bin/env bash
set -euo pipefail
HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."

export APP_LIB="$HERE/usr/lib"
export APP_LIB32="$HERE/usr/lib32"

export LD_LIBRARY_PATH="$APP_LIB:$APP_LIB32:${LD_LIBRARY_PATH:-}"

# libwayland comes from the host: the host's Mesa (libEGL_mesa) is built against the host's libwayland-client and fails with the
# bundled one from the build host once that is older ("undefined symbol: wl_display_create_queue_with_name", wayland >= 1.23).
# The bundled copy in wayland-fallback only serves systems without libwayland.
LDCACHE="$( { /sbin/ldconfig -p || /usr/sbin/ldconfig -p || ldconfig -p; } 2>/dev/null || true)"
if ! grep -q "libwayland-client.so.0 (libc6,x86-64)" <<<"$LDCACHE"; then
  export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$APP_LIB/wayland-fallback"
fi

export QT_PLUGIN_PATH="$HERE/usr/lib/qt6/plugins"
export QT_QPA_PLATFORM_PLUGIN_PATH="$HERE/usr/lib/qt6/plugins/platforms"
export QML2_IMPORT_PATH="$HERE/usr/lib/qt6/qml"

export GIO_MODULE_DIR="$HERE/usr/lib/gio/modules"
export XDG_DATA_DIRS="$HERE/usr/share:${XDG_DATA_DIRS:-}"

# Bundled VapourSynth (docs 32); vsconfig-write.py must rerun every launch, the AppImage mount path changes each time (section 2.1).
VS_PYTHON="$HERE/usr/vapoursynth/python"
if [ -x "$VS_PYTHON/bin/python3" ]; then
  export PYTHONHOME="$VS_PYTHON"
  export PYTHONPATH="$VS_PYTHON/lib/python3.14/site-packages"
  export PATH="$VS_PYTHON/bin:$VS_PYTHON/lib/python3.14/site-packages/vapoursynth:$PATH"
  "$VS_PYTHON/bin/python3" \
    "$VS_PYTHON/lib/python3.14/site-packages/vapoursynth/vsconfig-write.py" >/dev/null 2>&1 || true
fi

# Self-register the .desktop entry + icon so GNOME/desktop shells can resolve Hybrid's own icon for
# the dock/taskbar - a bare AppImage isn't "installed" anywhere by default (docs 32, 2.1/2.5).
# $APPIMAGE (set by the AppImage runtime) is the persistent path to the .AppImage file itself, unlike
# $HERE which is the ephemeral mount point - rewritten every launch so a moved AppImage stays correct.
if [ -n "${APPIMAGE:-}" ]; then
  DESKTOP_DIR="$HOME/.local/share/applications"
  ICON_DIR="$HOME/.local/share/icons/hicolor/512x512/apps"
  mkdir -p "$DESKTOP_DIR" "$ICON_DIR"
  cat > "$DESKTOP_DIR/hybrid.desktop" <<DESKTOPEOF
[Desktop Entry]
Name=Hybrid
Comment=Video Encoding Tool
Exec=$APPIMAGE
Icon=hybrid
Terminal=false
Type=Application
Categories=AudioVideo;Video;
DESKTOPEOF
  cp "$HERE/hybrid.png" "$ICON_DIR/hybrid.png" 2>/dev/null || true
fi

# Plattform-Auswahl: Wayland wenn verfügbar, sonst XCB
if [ -n "${WAYLAND_DISPLAY:-}" ] && \
   { [ -f "$HERE/usr/lib/qt6/plugins/platforms/libqwayland.so" ] || [ -f "$HERE/usr/lib/qt6/plugins/platforms/libqwayland-generic.so" ]; }; then
  export QT_QPA_PLATFORM="wayland;xcb"
else
  export QT_QPA_PLATFORM="xcb"
fi

BIN="$HERE/usr/bin/Hybrid"
# Host 'file' without the bundled libmagic: libmagic 5.45 from the build host cannot read a newer host magic.mgc
# ("File 5.45 supports only version 18 magic files").
if env -u LD_LIBRARY_PATH file "$BIN" | grep -q "32-bit"; then
  if [ -x "$APP_LIB32/ld-linux.so.2" ]; then
    exec "$APP_LIB32/ld-linux.so.2" --library-path "$APP_LIB32:$APP_LIB" "$BIN" "$@"
  else
    exec "$BIN" "$@"
  fi
else
  exec "$BIN" "$@"
fi
EOF
chmod +x "$APPDIR/usr/bin/HybridLauncher"

cat <<'EOF' > "$APPDIR/AppRun"
#!/usr/bin/env bash
set -euo pipefail
HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

export APP_LIB="$HERE/usr/lib"
export APP_LIB32="$HERE/usr/lib32"

export LD_LIBRARY_PATH="$APP_LIB:$APP_LIB32:${LD_LIBRARY_PATH:-}"

# libwayland comes from the host: the host's Mesa (libEGL_mesa) is built against the host's libwayland-client and fails with the
# bundled one from the build host once that is older ("undefined symbol: wl_display_create_queue_with_name", wayland >= 1.23).
# The bundled copy in wayland-fallback only serves systems without libwayland.
LDCACHE="$( { /sbin/ldconfig -p || /usr/sbin/ldconfig -p || ldconfig -p; } 2>/dev/null || true)"
if ! grep -q "libwayland-client.so.0 (libc6,x86-64)" <<<"$LDCACHE"; then
  export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$APP_LIB/wayland-fallback"
fi

export QT_PLUGIN_PATH="$HERE/usr/lib/qt6/plugins"
export QT_QPA_PLATFORM_PLUGIN_PATH="$HERE/usr/lib/qt6/plugins/platforms"
export QML2_IMPORT_PATH="$HERE/usr/lib/qt6/qml"

export GIO_MODULE_DIR="$HERE/usr/lib/gio/modules"
export XDG_DATA_DIRS="$HERE/usr/share:${XDG_DATA_DIRS:-}"

# Bundled VapourSynth (docs 32); vsconfig-write.py must rerun every launch, the AppImage mount path changes each time (section 2.1).
VS_PYTHON="$HERE/usr/vapoursynth/python"
if [ -x "$VS_PYTHON/bin/python3" ]; then
  export PYTHONHOME="$VS_PYTHON"
  export PYTHONPATH="$VS_PYTHON/lib/python3.14/site-packages"
  export PATH="$VS_PYTHON/bin:$VS_PYTHON/lib/python3.14/site-packages/vapoursynth:$PATH"
  "$VS_PYTHON/bin/python3" \
    "$VS_PYTHON/lib/python3.14/site-packages/vapoursynth/vsconfig-write.py" >/dev/null 2>&1 || true
fi

# Self-register the .desktop entry + icon so GNOME/desktop shells can resolve Hybrid's own icon for
# the dock/taskbar - a bare AppImage isn't "installed" anywhere by default (docs 32, 2.1/2.5).
# $APPIMAGE (set by the AppImage runtime) is the persistent path to the .AppImage file itself, unlike
# $HERE which is the ephemeral mount point - rewritten every launch so a moved AppImage stays correct.
if [ -n "${APPIMAGE:-}" ]; then
  DESKTOP_DIR="$HOME/.local/share/applications"
  ICON_DIR="$HOME/.local/share/icons/hicolor/512x512/apps"
  mkdir -p "$DESKTOP_DIR" "$ICON_DIR"
  cat > "$DESKTOP_DIR/hybrid.desktop" <<DESKTOPEOF
[Desktop Entry]
Name=Hybrid
Comment=Video Encoding Tool
Exec=$APPIMAGE
Icon=hybrid
Terminal=false
Type=Application
Categories=AudioVideo;Video;
DESKTOPEOF
  cp "$HERE/hybrid.png" "$ICON_DIR/hybrid.png" 2>/dev/null || true
fi

# Plattform-Auswahl: Wayland wenn verfügbar, sonst XCB
if [ -n "${WAYLAND_DISPLAY:-}" ] && \
   { [ -f "$HERE/usr/lib/qt6/plugins/platforms/libqwayland.so" ] || [ -f "$HERE/usr/lib/qt6/plugins/platforms/libqwayland-generic.so" ]; }; then
  export QT_QPA_PLATFORM="wayland;xcb"
else
  export QT_QPA_PLATFORM="xcb"
fi

BIN="$HERE/usr/bin/Hybrid"
# Host 'file' without the bundled libmagic: libmagic 5.45 from the build host cannot read a newer host magic.mgc
# ("File 5.45 supports only version 18 magic files").
if env -u LD_LIBRARY_PATH file "$BIN" | grep -q "32-bit"; then
  if [ -x "$APP_LIB32/ld-linux.so.2" ]; then
    exec "$APP_LIB32/ld-linux.so.2" --library-path "$APP_LIB32:$APP_LIB" "$BIN" "$@"
  else
    exec "$BIN" "$@"
  fi
else
  exec "$BIN" "$@"
fi
EOF
chmod +x "$APPDIR/AppRun"

cp "$APPDIR/usr/share/applications/hybrid.desktop" "$APPDIR/"

# --- Download linuxdeploy and appimagetool (unchanged) ---
cd "$DEPLOY_DIR"
wget -q -O linuxdeploy-x86_64.AppImage https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage || true
wget -q -O linuxdeploy-plugin-qt-x86_64.AppImage https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-x86_64.AppImage || true
wget -q -O appimagetool-x86_64.AppImage https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage || true
chmod +x linuxdeploy-*.AppImage appimagetool-x86_64.AppImage || true

export LD_LIBRARY_PATH="$APPDIR/usr/lib:$APPDIR/usr/lib32"
# /usr/bin/qmake is qtchooser and resolves to Qt 5 (qtbase5-dev is installed for d2vwitch); the qt plugin then finds no modules
export QMAKE="$(command -v qmake6)"

./linuxdeploy-x86_64.AppImage --appdir "$APPDIR" \
  -e "$APPDIR/usr/bin/Hybrid" \
  -i "$APPDIR/hybrid.png" \
  -d "$APPDIR/usr/share/applications/hybrid.desktop" \
  --plugin qt || echo "⚠️ linuxdeploy failed — fallback will run."

# --- Bundle Qt6 libs (Core + DBus + all essentials) ---
mkdir -p "$APPDIR/usr/lib/qt6/plugins"
# pkg-config resolves the real per-distro path (e.g. /usr/lib/x86_64-linux-gnu on Debian/Ubuntu,
# /usr/lib on Arch) instead of hardcoding one distro's layout - a wrong path here means this whole
# block silently bundles nothing, since every use below is guarded by an existence check.
QT_LIB_DIR="$(pkg-config --variable=libdir Qt6Core 2>/dev/null || echo /usr/lib)"
QT_LIBS=("Qt6Core" "Qt6Gui" "Qt6Widgets" "Qt6Xml" "Qt6Svg" "Qt6Multimedia" \
         "Qt6Network" "Qt6Concurrent" "Qt6OpenGL" "Qt6Qml" "Qt6Quick" \
         "Qt6QuickControls2" "Qt6DBus")

echo "📦 Copying Qt6 libraries..."
mkdir -p "$APPDIR/usr/lib"
for lib in "${QT_LIBS[@]}"; do
    for so in "$QT_LIB_DIR/lib${lib}.so"*; do
        [ -f "$so" ] && cp -v --preserve=links "$so" "$APPDIR/usr/lib/"
    done
done

# --- Copy Qt plugins ---
QT_PLUGIN_DIR="$QT_LIB_DIR/qt6/plugins"
if [ -d "$QT_PLUGIN_DIR" ]; then
    echo "📦 Copying Qt6 plugins..."
    mkdir -p "$APPDIR/usr/lib/qt6/plugins"
    rsync -a "$QT_PLUGIN_DIR/" "$APPDIR/usr/lib/qt6/plugins/"
fi

echo "🔧 Bundling Qt platform plugins..."
QT_PLATFORM_PLUGINS_SRC="$QT_LIB_DIR/qt6/plugins/platforms"
QT_PLATFORM_PLUGINS_DST="$APPDIR/usr/lib/qt6/plugins/platforms"
mkdir -p "$QT_PLATFORM_PLUGINS_DST"

if [ -d "$QT_PLATFORM_PLUGINS_SRC" ]; then
  cp -v --preserve=links "$QT_PLATFORM_PLUGINS_SRC"/libqwayland*.so \
    "$QT_PLATFORM_PLUGINS_DST/" 2>/dev/null || echo "⚠️ Wayland plugins not found on build host"
  cp -v --preserve=links "$QT_PLATFORM_PLUGINS_SRC"/libqxcb.so \
    "$QT_PLATFORM_PLUGINS_DST/" 2>/dev/null || true
fi

# Wayland-Client-Lib
for lib in \
  libQt6WaylandClient.so.6 \
  libQt6WaylandCompositor.so.6 \
  libwayland-client.so.0 \
  libwayland-egl.so.1 \
  libwayland-cursor.so.0; do
  src=$(ldconfig -p | grep "/$lib" | awk '{print $NF}' | head -n1 || true)
  if [ -n "$src" ]; then
    cp -v --preserve=links "$src" "$APPDIR/usr/lib/" || true
  else
    echo "⚠️ $lib not found on build host"
  fi
done


# --- Fix RPATH in Hybrid binary ---
echo "🔧 Patching Hybrid binary RPATH..."
patchelf --set-rpath '$ORIGIN/../lib:$ORIGIN/../lib32' "$APPDIR/usr/bin/Hybrid"

# --- Verify DBus library loads internally ---
echo "🔍 Verifying libQt6DBus.so.6 in AppImage..."
if [ ! -f "$APPDIR/usr/lib/libQt6DBus.so.6" ]; then
    echo "❌ libQt6DBus.so.6 not found in AppDir!"
    exit 1
fi

THEORA_LIB_DIR="/usr/lib/x86_64-linux-gnu"
for lib in theoradec theoraenc; do
    for so in "$THEORA_LIB_DIR/lib${lib}.so."*; do
        [ -f "$so" ] && cp -v --preserve=links "$so" "$APPDIR/usr/lib/"
    done
done

pushd "$APPDIR/usr/lib" >/dev/null
for lib in theoradec theoraenc; do
    if ls lib${lib}.so.1* >/dev/null 2>&1; then
        real=$(ls lib${lib}.so.1*)
        ln -sf "$real" lib${lib}.so.2
        echo "🔧 Created symlink lib${lib}.so.2 → $real"
    fi
done
popd >/dev/null

if [ -f "$QT_LIB_DIR/libQt6DBus.so.6" ]; then
  cp -v --preserve=links "$QT_LIB_DIR/libQt6DBus.so.6"* "$APPDIR/usr/lib/" || true
fi
if [ -f "/lib/x86_64-linux-gnu/libdbus-1.so.3" ]; then
  cp -v --preserve=links /lib/x86_64-linux-gnu/libdbus-1.so.3* "$APPDIR/usr/lib/" || true
fi

# ffplay links libSDL2 dynamically (build-tools.sh installs libsdl2-dev via apt, docs 35); unlike X11/ALSA/Pulse it isn't a base-desktop library guaranteed on the target machine, so the build machine always resolves it and the generic ldd "not found" scan above never catches it.
SDL2_LIB=$(ldconfig -p | grep '/libSDL2-2\.0\.so\.0' | awk '{print $NF}' | head -n1 || true)
if [ -n "$SDL2_LIB" ]; then
  echo "📦 Bundling $SDL2_LIB for ffplay..."
  cp -v --preserve=links "$SDL2_LIB"* "$APPDIR/usr/lib/" || true
else
  echo "⚠️ libSDL2-2.0.so.0 not found on build host — ffplay will be missing it in the AppImage"
fi

# ICU version Qt links against (Ubuntu 24.04: 74, 26.04: 78)
ICU_VERSION=$(ldd "$QT_LIB_DIR/libQt6Core.so.6" | sed -n 's/.*libicuuc\.so\.\([0-9]*\) =>.*/\1/p' | head -n1)
ICU_LIBS=("icui18n" "icuuc" "icudata")
for lib in "${ICU_LIBS[@]}"; do
    src="$QT_LIB_DIR/lib${lib}.so.${ICU_VERSION}"
    if [ -f "$src" ]; then
        cp -v --preserve=links "$src" "$APPDIR/usr/lib/" || true
    else
        echo "⚠️ ICU library missing on this system: $src"
    fi
done

mkdir -p "$APPDIR/usr/lib/gio/modules"

./linuxdeploy-x86_64.AppImage --appdir "$APPDIR" -e "$APPDIR/usr/bin/Hybrid" -i "$APPDIR/hybrid.png" -d "$APPDIR/usr/share/applications/hybrid.desktop" || true

# d2vwitch is a Qt5 program and creates a QGuiApplication even on the command line. linuxdeploy bundles its Qt5 libraries, but no Qt5
# platform plugin, and the launchers point QT_PLUGIN_PATH/QT_QPA_PLATFORM_PLUGIN_PATH at the Qt6 plugins - without a plugin it aborts at
# once with 'Could not find the Qt platform plugin "xcb"' and every MPEG-1/2 index job fails (check_job_runs.py vs-x264-mkv). The wrapper
# runs it on the Qt5 'offscreen' plugin, which needs no display, with its own plugin path; Hybrid keeps starting 'd2vwitch'.
# Done after the last linuxdeploy run, which patches the RUNPATH of the ELF files in usr/bin (the wrapper is not one).
# Only needed for a Qt5 build (dubhater/D2VWitch); Selur/D2VWitch v6 is a Qt6 program whose command line needs no platform plugin, then nothing is wrapped.
if [ -f "$APPDIR/usr/bin/d2vwitch" ] && file "$APPDIR/usr/bin/d2vwitch" | grep -q ELF && readelf -d "$APPDIR/usr/bin/d2vwitch" | grep -q "libQt5Core"; then
  QT5_OFFSCREEN="$(ls /usr/lib/*/qt5/plugins/platforms/libqoffscreen.so /usr/lib/qt5/plugins/platforms/libqoffscreen.so 2>/dev/null | head -n1 || true)"
  if [ -n "$QT5_OFFSCREEN" ]; then
    mkdir -p "$APPDIR/usr/lib/qt5/plugins/platforms"
    cp -v "$QT5_OFFSCREEN" "$APPDIR/usr/lib/qt5/plugins/platforms/"
    mv "$APPDIR/usr/bin/d2vwitch" "$APPDIR/usr/bin/d2vwitch.bin"
    cat > "$APPDIR/usr/bin/d2vwitch" <<'D2VEOF'
#!/usr/bin/env bash
HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
export QT_PLUGIN_PATH="$HERE/../lib/qt5/plugins"
export QT_QPA_PLATFORM_PLUGIN_PATH="$HERE/../lib/qt5/plugins/platforms"
export QT_QPA_PLATFORM=offscreen
unset QML2_IMPORT_PATH
exec "$HERE/d2vwitch.bin" "$@"
D2VEOF
    chmod +x "$APPDIR/usr/bin/d2vwitch"
  else
    echo "⚠️ Qt5 offscreen platform plugin not found on build host (apt: libqt5gui5) - d2vwitch will not start"
  fi
fi

# libwayland out of usr/lib, the launchers take the host's (see there). After the last linuxdeploy run, which copies it back as a
# dependency of the Qt Wayland plugin, SDL2, GTK and sox; libQt6WaylandClient's RUNPATH would otherwise find it in usr/lib.
mkdir -p "$APPDIR/usr/lib/wayland-fallback"
mv -v "$APPDIR"/usr/lib/libwayland-*.so* "$APPDIR/usr/lib/wayland-fallback/" 2>/dev/null || true

ARCH=x86_64 ./appimagetool-x86_64.AppImage "$APPDIR" "$OUT_APPIMAGE"

cd "$SCRIPT_DIR"
if [ "$KEEP_APPDIR" -eq 0 ]; then
  rm -rf "$DEPLOY_DIR"
fi

echo "✅ Build completed!"
echo "Output: $OUT_APPIMAGE"

if [ "$COMPRESS" -eq 1 ]; then
  echo "📦 Compressing AppImage with 7z..."
  7z a -m0=lzma2 -mx=9 "Hybrid_${version}.7z" "$OUT_APPIMAGE"
  echo "📦 Created: Hybrid_${version}.7z"
fi
