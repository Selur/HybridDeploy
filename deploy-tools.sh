#!/bin/bash
set -e

readme_file="README.md"
binaries_qt="Hybrid bdsup2sub++ d2vwitch delaycut FrameCounter IdxSubCutter vsViewer"
binaries_32bit="DivX265 neroAacEnc"
binaries_64bit="fdkaac aften aomenc faac ffdcaenc ffmpeg ffmsindex flac FLVExtractCL kvazaar lame lsdvd mediainfo mencoder mkvextract mkvinfo mkvmerge MP4Box mp4fpsmod mplayer oggenc opusenc rav1e sox telxcc tsMuxeR vpxenc x264 x265 xvid_encraw SvtHevcEncApp SvtAv1EncApp"

# Use current date as version
version=$(date +"%Y.%m.%d.1")
echo "Building Hybrid version: $version"

set -x

# Get absolute path of the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "Script directory: $SCRIPT_DIR"

# Change to tools directory
if [ "$(basename "$PWD")" = "tools" ]; then
    echo "Already in tools directory! This is not right!"
    exit 1;
else
    echo "Changing to tools directory"
    cd tools
    TOOLS_DIR="$PWD"
fi

echo "Current working directory: $TOOLS_DIR"

# Verify required binaries exist
echo "Verifying built binaries exist..."
all_binaries="$binaries_qt $binaries_64bit $binaries_32bit"
missing_bins=""
for bin in $all_binaries; do
  if [ ! -f "$bin" ]; then
    echo "Binary $bin not found!"
    missing_bins="$missing_bins $bin"
  else
    echo "Found: $bin"
  fi
done

# If binaries missing → ask user to build
if [ -n "$missing_bins" ]; then
    echo "Some binaries missing:"
    echo "$missing_bins"
    read -p "Do you want to run build-tools.sh now? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Building tools..."
        cd "$SCRIPT_DIR"
        ./build-tools.sh all
        cd "$TOOLS_DIR"
    else
        echo "Aborting script as required binaries are missing."
        exit 1
    fi
else
    echo "All binaries exist, skipping build step"
fi

# Recheck after potential build
for bin in $all_binaries; do
  [ -f "$bin" ] || { echo "ERROR: Binary $bin still missing!"; exit 1; }
done

# Install dependencies for packaging
sudo apt install --no-install-recommends -y \
  build-essential autoconf automake git wget p7zip-full libfuse2t64

# Set up directories
DEPLOY_DIR_NAME="hybrid"
DEPLOY_DIR_ABS="$TOOLS_DIR/$DEPLOY_DIR_NAME"
APPDIR_ABS="$DEPLOY_DIR_ABS/AppDir"

rm -rf "$DEPLOY_DIR_ABS"
mkdir -p "$DEPLOY_DIR_ABS"
cd "$DEPLOY_DIR_ABS"

# Download linuxdeploy + qt plugin
wget -q https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage
wget -q https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-x86_64.AppImage
chmod a+x *.AppImage

# Create AppDir structure
mkdir -p "$APPDIR_ABS/usr/bin"
mkdir -p "$APPDIR_ABS/usr/lib"
mkdir -p "$APPDIR_ABS/usr/share/applications"
mkdir -p "$APPDIR_ABS/usr/share/icons/hicolor/1024x1024/apps"

# Copy binaries
for bin in $all_binaries; do
  if [ -f "../$bin" ]; then
    cp "../$bin" "$APPDIR_ABS/usr/bin/"
    chmod +x "$APPDIR_ABS/usr/bin/$bin"
  else
    echo "Warning: Binary $bin not found!"
  fi
done

# Copy icon
ICON_PATH="$SCRIPT_DIR/icons/icon.png"
if [ -f "$ICON_PATH" ]; then
    cp "$ICON_PATH" "$APPDIR_ABS/hybrid.png"
    cp "$ICON_PATH" "$APPDIR_ABS/usr/share/icons/hicolor/1024x1024/apps/hybrid.png"
else
    echo "ERROR: icon not found at $ICON_PATH!"
    exit 1
fi

# Create .desktop file
cat <<EOF > "$APPDIR_ABS/usr/share/applications/hybrid.desktop"
[Desktop Entry]
Name=Hybrid
Comment=Video Encoding Tool
Exec=HybridLauncher
Icon=hybrid
Terminal=false
Type=Application
Categories=AudioVideo;Video;
EOF

# Create HybridLauncher (Qt6 aware)
cat <<'EOF' > "$APPDIR_ABS/usr/bin/HybridLauncher"
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPDIR="$SCRIPT_DIR/.."

export LD_LIBRARY_PATH="$APPDIR/lib:$APPDIR/usr/lib:$LD_LIBRARY_PATH"
export QT_QPA_PLATFORM_PLUGIN_PATH="$APPDIR/usr/lib/qt6/plugins/platforms"
export QT_PLUGIN_PATH="$APPDIR/usr/lib/qt6/plugins"
export QML2_IMPORT_PATH="$APPDIR/usr/lib/qt6/qml"

cd "$APPDIR/usr/bin"
exec "$APPDIR/usr/bin/Hybrid" "$@"
EOF

chmod +x "$APPDIR_ABS/usr/bin/HybridLauncher"

# ✅ Create AppRun (main Qt6 launcher)
cat <<'EOF' > "$APPDIR_ABS/AppRun"
#!/bin/bash
HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

export LD_LIBRARY_PATH="$HERE/usr/lib:$HERE/lib:$LD_LIBRARY_PATH"
export QT_QPA_PLATFORM_PLUGIN_PATH="$HERE/usr/lib/qt6/plugins/platforms"
export QT_PLUGIN_PATH="$HERE/usr/lib/qt6/plugins"
export QML2_IMPORT_PATH="$HERE/usr/lib/qt6/qml"

exec "$HERE/usr/bin/Hybrid" "$@"
EOF
chmod +x "$APPDIR_ABS/AppRun"

# Copy desktop file to AppDir root (for AppImage metadata)
cp "$APPDIR_ABS/usr/share/applications/hybrid.desktop" "$APPDIR_ABS/"

# Download appimagetool if missing
if [ ! -f "$DEPLOY_DIR_ABS/appimagetool-x86_64.AppImage" ]; then
    wget -q https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage
    chmod a+x appimagetool-x86_64.AppImage
fi

APPIMAGETOOL_PATH="$DEPLOY_DIR_ABS/appimagetool-x86_64.AppImage"

# Build AppImage
ARCH=x86_64 "$APPIMAGETOOL_PATH" "$APPDIR_ABS" "${SCRIPT_DIR}/Hybrid-$version-x86_64.AppImage"

# Cleanup
cd "$SCRIPT_DIR"
rm -rf "$DEPLOY_DIR_ABS"

echo "✅ Build completed successfully!"
echo "Version: $version"

echo "Compressing AppImage,..."
7z a -m0=lzma2 -mx "Hybrid_$version.7z" "Hybrid-$version-x86_64.AppImage"

echo "Created:"
ls -la "$SCRIPT_DIR"/Hybrid-*.AppImage
