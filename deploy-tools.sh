#!/bin/bash
set -e
set -x

# ===========================================
# Hybrid AppImage Build Script (with 32-bit support)
# ===========================================

# --- Configuration ---
readme_file="README.md"

# --- Automatically include all tools in the tools/ folder ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$SCRIPT_DIR/tools"

if [ ! -d "$TOOLS_DIR" ]; then
  echo "❌ tools directory not found!"
  exit 1
fi

all_binaries=$(find "$TOOLS_DIR" -maxdepth 1 -type f ! -name "*-sources.txt" -exec basename {} \;)

version=$(date +"%Y.%m.%d.1")
echo "🧱 Building Hybrid version: $version"

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
  echo "⚠️ Missing binaries:"
  echo "$missing_bins"
  echo "❌ Aborting build due to missing binaries."
  exit 1
fi

# --- Install dependencies ---
sudo dpkg --add-architecture i386
sudo apt-get update
sudo apt-get install --no-install-recommends -y \
  qt6-base-dev qt6-base-dev-tools qt6-multimedia-dev qt6-svg-dev \
  libqt6svg6 libqt6multimedia6 libqt6widgets6 libqt6gui6 libqt6core6 \
  p7zip-full rsync wget libc6:i386 libstdc++6:i386 libgcc-s1:i386 libpthread-stubs0-dev:i386


# --- Prepare AppDir ---
DEPLOY_DIR="$SCRIPT_DIR/hybrid"
APPDIR="$DEPLOY_DIR/AppDir"

rm -rf "$DEPLOY_DIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib" "$APPDIR/usr/share/applications" "$APPDIR/usr/share/icons/hicolor/1024x1024/apps"

# --- Copy binaries ---
for bin in $all_binaries; do
    cp "$TOOLS_DIR/$bin" "$APPDIR/usr/bin/"
    chmod +x "$APPDIR/usr/bin/$bin"
done

# --- 32-bit runtime support ---
echo "🔍 Bundling 32-bit libraries..."
mkdir -p "$APPDIR/usr/lib32"
for bin in $all_binaries; do
    if file "$APPDIR/usr/bin/$bin" | grep -q "32-bit"; then
        echo "📦 Detected 32-bit binary: $bin"
        # Copy dependencies
        deps=$(ldd "$APPDIR/usr/bin/$bin" | awk '/=>/ {print $3}' | grep "^/lib32" || true)
        for dep in $deps; do
            if [ -f "$dep" ]; then
                echo "  ↳ Copying dependency: $dep"
                cp -v --parents "$dep" "$APPDIR/usr/lib32/" 2>/dev/null || true
            fi
        done
        # Copy 32-bit loader
        if [ -f "/lib/ld-linux.so.2" ]; then
            echo "  ↳ Copying ld-linux.so.2"
            mkdir -p "$APPDIR/usr/lib32/lib"
            cp -v /lib/ld-linux.so.2 "$APPDIR/usr/lib32/"
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
#!/bin/bash
HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."

# 64-bit libraries
export LD_LIBRARY_PATH="$HERE/usr/lib:$HERE/lib:$LD_LIBRARY_PATH"

# 32-bit binaries loader
export LIB32="$HERE/usr/lib32"
export LD_LIBRARY_PATH="$LIB32:$LD_LIBRARY_PATH"

# Qt paths
export QT_QPA_PLATFORM_PLUGIN_PATH="$HERE/usr/lib/qt6/plugins/platforms"
export QT_PLUGIN_PATH="$HERE/usr/lib/qt6/plugins"
export QML2_IMPORT_PATH="$HERE/usr/lib/qt6/qml"

# Wrapper function for 32-bit binaries
run_bin() {
    BIN="$HERE/usr/bin/$1"
    shift
    if file "$BIN" | grep -q "32-bit"; then
        "$LIB32/ld-linux.so.2" --library-path "$LIB32" "$BIN" "$@"
    else
        "$BIN" "$@"
    fi
}

run_bin Hybrid "$@"
EOF
chmod +x "$APPDIR/usr/bin/HybridLauncher"

cat <<'EOF' > "$APPDIR/AppRun"
#!/bin/bash
HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

# 64-bit libraries
export LD_LIBRARY_PATH="$HERE/usr/lib:$HERE/lib:$LD_LIBRARY_PATH"

# 32-bit binaries loader
export LIB32="$HERE/usr/lib32"
export LD_LIBRARY_PATH="$LIB32:$LD_LIBRARY_PATH"

# Qt paths
export QT_QPA_PLATFORM_PLUGIN_PATH="$HERE/usr/lib/qt6/plugins/platforms"
export QT_PLUGIN_PATH="$HERE/usr/lib/qt6/plugins"
export QML2_IMPORT_PATH="$HERE/usr/lib/qt6/qml"

# Wrapper function for 32-bit binaries
run_bin() {
    BIN="$HERE/usr/bin/$1"
    shift
    if file "$BIN" | grep -q "32-bit"; then
        "$LIB32/ld-linux.so.2" --library-path "$LIB32" "$BIN" "$@"
    else
        "$BIN" "$@"
    fi
}

run_bin Hybrid "$@"
EOF
chmod +x "$APPDIR/AppRun"

# --- Copy desktop file to AppDir root ---
cp "$APPDIR/usr/share/applications/hybrid.desktop" "$APPDIR/"

# --- Download linuxdeploy and appimagetool ---
cd "$DEPLOY_DIR"
wget -q https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage
wget -q https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-x86_64.AppImage
wget -q https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage
chmod +x *.AppImage

# --- Run linuxdeploy ---
./linuxdeploy-x86_64.AppImage --appdir "$APPDIR" \
  -e "$APPDIR/usr/bin/Hybrid" \
  -i "$APPDIR/hybrid.png" \
  -d "$APPDIR/usr/share/applications/hybrid.desktop" \
  --plugin qt || echo "⚠️ linuxdeploy failed — fallback will run."

# --- Copy Qt manually if linuxdeploy missed it ---
if [ -z "$(find "$APPDIR/usr/lib" -maxdepth 1 -name 'libQt6*.so*' 2>/dev/null)" ]; then
  echo "⚠️ Qt6 libs missing, copying manually..."
  QT_LIB_DIR="/usr/lib/x86_64-linux-gnu"
  for lib in Core Gui Widgets Xml Svg Multimedia Network Concurrent OpenGL Qml Quick QuickControls2; do
    src="$QT_LIB_DIR/libQt6${lib}.so.6"
    [ -f "$src" ] && cp "$src" "$APPDIR/usr/lib/"
  done
  QT_PLUGIN_BASE="$QT_LIB_DIR/qt6/plugins"
  [ -d "$QT_PLUGIN_BASE" ] && rsync -a "$QT_PLUGIN_BASE/" "$APPDIR/usr/lib/qt6/plugins/"
fi

# --- Build AppImage ---
ARCH=x86_64 ./appimagetool-x86_64.AppImage "$APPDIR" "$SCRIPT_DIR/Hybrid-$version-x86_64.AppImage"

# --- Cleanup ---
cd "$SCRIPT_DIR"
rm -rf "$DEPLOY_DIR"

echo "✅ Build completed!"
echo "Output: $SCRIPT_DIR/Hybrid-$version-x86_64.AppImage"

if [[ "$1" == "--compress" ]]; then
    echo "Compressing AppImage with 7z..."
    7z a -m0=lzma2 -mx=9 "Hybrid_${version}.7z" "Hybrid-$version-x86_64.AppImage"
    echo "Created:"
    ls -la "Hybrid-$version-x86_64.AppImage"
else
    echo "Skipping compression (use --compress to enable)"
fi
