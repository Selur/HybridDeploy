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

# --- Install dependencies ---
echo "🔧 Configuring system dependencies (requires sudo)..."
sudo dpkg --add-architecture i386
sudo apt-get update
sudo apt-get install --no-install-recommends -y \
  qt6-base-dev qt6-base-dev-tools qt6-multimedia-dev qt6-svg-dev \
  libqt6svg6 libqt6multimedia6 libqt6widgets6 libqt6gui6 libqt6core6 \
  qt6-wayland libqt6waylandclient6 libqt6waylandcompositor6 \
  p7zip-full rsync wget libc6:i386 libstdc++6:i386 libgcc-s1:i386 libpthread-stubs0-dev:i386

# --- Prepare AppDir ---
DEPLOY_DIR="$SCRIPT_DIR/hybrid"
APPDIR="$DEPLOY_DIR/AppDir"

rm -rf "$DEPLOY_DIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib" "$APPDIR/usr/lib32" \
         "$APPDIR/usr/share/applications" "$APPDIR/usr/share/icons/hicolor/1024x1024/apps"

echo "📦 Copying tool binaries into AppDir..."
for bin in $all_binaries; do
  cp "$TOOLS_DIR/$bin" "$APPDIR/usr/bin/"
  chmod +x "$APPDIR/usr/bin/$bin"
done

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

cp "$ICON_PATH" "$APPDIR/hybrid.png"
cp "$ICON_PATH" "$APPDIR/usr/share/icons/hicolor/1024x1024/apps/hybrid.png"

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

export QT_PLUGIN_PATH="$HERE/usr/lib/qt6/plugins"
export QT_QPA_PLATFORM_PLUGIN_PATH="$HERE/usr/lib/qt6/plugins/platforms"
export QML2_IMPORT_PATH="$HERE/usr/lib/qt6/qml"

export GIO_MODULE_DIR="$HERE/usr/lib/gio/modules"
export XDG_DATA_DIRS="$HERE/usr/share:${XDG_DATA_DIRS:-}"

# Plattform-Auswahl: Wayland wenn verfügbar, sonst XCB
if [ -n "${WAYLAND_DISPLAY:-}" ] && \
   [ -f "$HERE/usr/lib/qt6/plugins/platforms/libqwayland-generic.so" ]; then
  export QT_QPA_PLATFORM="wayland;xcb"
else
  export QT_QPA_PLATFORM="xcb"
fi

BIN="$HERE/usr/bin/Hybrid"
if file "$BIN" | grep -q "32-bit"; then
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

export QT_PLUGIN_PATH="$HERE/usr/lib/qt6/plugins"
export QT_QPA_PLATFORM_PLUGIN_PATH="$HERE/usr/lib/qt6/plugins/platforms"
export QML2_IMPORT_PATH="$HERE/usr/lib/qt6/qml"

export GIO_MODULE_DIR="$HERE/usr/lib/gio/modules"
export XDG_DATA_DIRS="$HERE/usr/share:${XDG_DATA_DIRS:-}"

# Plattform-Auswahl: Wayland wenn verfügbar, sonst XCB
if [ -n "${WAYLAND_DISPLAY:-}" ] && \
   [ -f "$HERE/usr/lib/qt6/plugins/platforms/libqwayland-generic.so" ]; then
  export QT_QPA_PLATFORM="wayland;xcb"
else
  export QT_QPA_PLATFORM="xcb"
fi

BIN="$HERE/usr/bin/Hybrid"
if file "$BIN" | grep -q "32-bit"; then
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

# --- Theora + AMR fixes (unchanged) ---
for lib in theoradec theoraenc; do
  real=$(ls /usr/lib/x86_64-linux-gnu/lib${lib}.so.1.* 2>/dev/null | head -n1 || true)
  target="/usr/lib/x86_64-linux-gnu/lib${lib}.so.2"
  if [ -n "$real" ] && [ ! -f "$target" ]; then
    echo "🔧 Creating missing $target symlink → $(basename "$real")"
    sudo ln -sf "$real" "$target"
  fi
done

if ! ldconfig -p | grep -q libvo-amrwbenc.so.0; then
  echo "🔧 Installing missing libvo-amrwbenc..."
  sudo apt-get install -y libvo-amrwbenc-dev libvo-amrwbenc0 || true
fi

export LD_LIBRARY_PATH="$APPDIR/usr/lib:$APPDIR/usr/lib32"

./linuxdeploy-x86_64.AppImage --appdir "$APPDIR" \
  -e "$APPDIR/usr/bin/Hybrid" \
  -i "$APPDIR/hybrid.png" \
  -d "$APPDIR/usr/share/applications/hybrid.desktop" \
  --plugin qt || echo "⚠️ linuxdeploy failed — fallback will run."

# --- Bundle Qt6 libs (Core + DBus + all essentials) ---
mkdir -p "$APPDIR/usr/lib/qt6/plugins"
QT_LIB_DIR="/usr/lib"   # Arch default path, adjust if needed
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

ICU_VERSION="74"
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
