#!/usr/bin/env bash
# The only part of the build that needs root: installs the system packages from apt-packages.sh.
# Run once (and again after a package was added there): sudo bash setup-root.sh
# build-tools.sh, build-vapoursynth-plugins.sh and deploy-tools.sh then run without sudo.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "❌ Run as root: sudo bash $0"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/apt-packages.sh"

dpkg --print-foreign-architectures | grep -qx i386 || dpkg --add-architecture i386
apt-get update
apt-get install --no-install-recommends -y "${BUILD_PACKAGES[@]}" "${DEPLOY_PACKAGES[@]}"

missing=$(missing_packages "${BUILD_PACKAGES[@]}" "${DEPLOY_PACKAGES[@]}" | tr '\n' ' ')
if [ -n "$missing" ]; then
  echo "❌ Still missing: $missing"
  exit 1
fi
echo "✅ All system packages installed"
