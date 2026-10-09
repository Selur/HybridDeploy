#!/usr/bin/env bash
# System packages for build-tools.sh, build-vapoursynth-plugins.sh and deploy-tools.sh (package names of Ubuntu 26.04).
# Sourced by those scripts, which only check; setup-root.sh installs them (the only step that needs sudo).

BUILD_PACKAGES=(
  build-essential git subversion wget curl cmake nasm yasm unzip upx-ucl autoconf automake gettext libtool-bin pkg-config
  qt6-base-dev qt6-multimedia-dev qt6-svg-dev qtbase5-dev
  docbook-xsl xsltproc rake ragel
  libgl1-mesa-dev libgmp-dev libboost-filesystem-dev libboost-regex-dev libboost-date-time-dev
  libdvdread-dev libfdk-aac-dev libogg-dev libvorbis-dev libflac-dev zlib1g-dev liblzma-dev libbz2-dev
  libpng-dev libjpeg-dev libgif-dev libopenal-dev libasound2-dev libpulse-dev
  libopencore-amrnb-dev libopencore-amrwb-dev libmp3lame-dev libmpg123-dev libopus-dev libopusfile-dev
  libsndfile1-dev libwavpack-dev libmagic-dev libnuma-dev libbluray-dev libxvidcore-dev libva-dev libvdpau-dev
  libsdl2-dev libxml2-dev libfreetype-dev libfontconfig1-dev libxcb1-dev libxcb-shm0-dev libxcb-xfixes0-dev
  libxcb-shape0-dev libcmark-dev libtheora-dev libfribidi-dev ninja-build meson
  # build-vapoursynth-plugins.sh
  libfftw3-dev libvulkan-dev python3
)

DEPLOY_PACKAGES=(
  qt6-base-dev qt6-base-dev-tools qt6-multimedia-dev qt6-svg-dev
  libqt6svg6 libqt6multimedia6 libqt6widgets6 libqt6gui6 libqt6core6t64
  qt6-wayland libqt6waylandclient6 libqt6waylandcompositor6
  7zip rsync wget imagemagick patchelf libvo-amrwbenc-dev libvo-amrwbenc0
  libc6:i386 libstdc++6:i386 libgcc-s1:i386 libpthread-stubs0-dev:i386
)

# Prints the packages of the given list that are not installed.
missing_packages() {
  local p
  for p in "$@"; do
    [ "$(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null)" = "installed" ] || echo "$p"
  done
}

# Aborts with a hint to setup-root.sh if a package of the given list is missing.
require_packages() {
  local missing
  missing=$(missing_packages "$@" | tr '\n' ' ')
  if [ -n "$missing" ]; then
    echo "❌ Missing system packages: $missing"
    echo "   Install them once with: sudo bash \"$(dirname "${BASH_SOURCE[0]}")/setup-root.sh\""
    exit 1
  fi
}
