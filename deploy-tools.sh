#!/bin/bash
set -e

readme_file="README.md"
binaries_qt="Hybrid bdsup2sub++ d2vwitch delaycut FrameCounter IdxSubCutter vsViewer"
binaries_32bit="DivX265 neroAacEnc"
binaries_64bit="""
fdkaac
aften
aomenc
faac
ffdcaenc
ffmpeg
ffmsindex
flac
FLVExtractCL
kvazaar
lame
lsdvd
mediainfo
mencoder
mkvextract
mkvinfo
mkvmerge
MP4Box
mp4fpsmod
mplayer
oggenc
opusenc
rav1e
sox
telxcc
tsMuxeR
vpxenc
x264
x265
xvid_encraw
SvtHevcEncApp
SvtAv1EncApp
"""
deploy_dir="hybrid"

#set -e
set -x

sudo dpkg --add-architecture i386
sudo apt update
sudo apt upgrade -y

sudo apt install --no-install-recommends -y \
  build-essential \
  autoconf \
  automake \
  fuse \
  git \
  wget \
  p7zip-full \
  libqt5multimedia5 \
  libqt5multimedia5-plugins \
  libqt5xml5 \
  libfreetype6:i386 \
  zlib1g:i386 \
  libgcc1:i386 \
  libstdc++6:i386

cd tools
#ORIGIN=$(dirname $0)
rm -rf $deploy_dir
mkdir $deploy_dir
cd $deploy_dir

wget https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage
#wget https://artifacts.assassinate-you.net/artifactory/list/linuxdeploy/travis-456/linuxdeploy-x86_64.AppImage
wget https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-x86_64.AppImage
chmod a+x *.AppImage

cmdLine="--appdir=. --plugin qt -l/usr/lib/i386-linux-gnu/libfreetype.so.6 -l/lib/i386-linux-gnu/libz.so.1"
for bin in $binaries_qt $binaries_64bit $binaries_32bit ; do
  cmdLine="$cmdLine --executable ../$bin"
done
echo "call: ./linuxdeploy-x86_64.AppImage $cmdLine"
./linuxdeploy-x86_64.AppImage $cmdLine

cd ..
cd $deploy_dir

git clone --depth=1 https://github.com/Selur/VapoursynthScriptsInHybrid vsscripts
rm -rf vsscripts/.git

git clone --depth=1 https://github.com/FranceBB/LinearTransformation.git TimeCubeFiles
rm -rf TimeCubeFiles/.git

mv ./usr/* .
mv ./bin/* .
mv ./share/doc .

git clone https://github.com/NixOS/patchelf
cd patchelf
./bootstrap.sh
./configure
make
cd ..

for bin in $binaries_qt $binaries_64bit ; do
  if [ "$bin" != "MP4Box" ]; then
    ./patchelf/src/patchelf --set-rpath '$ORIGIN/lib' $bin
  fi
done

for bin in $binaries_32bit ; do
  ./patchelf/src/patchelf --set-rpath '$ORIGIN/lib32' $bin
done

chmod a+x $binaries_qt $binaries_64bit $binaries_32bit

cat <<EOF >qt.conf
[Paths]
Prefix = .
Plugins = plugins
Imports = qml
Qml2Imports = qml
EOF

rm -rf ./usr ./bin ./share ./patchelf *.AppImage
cd ..

now=$(date +"%Y%m%d")
7z a -m0=lzma2 -mx "../Hybrid_$now.7z" $deploy_dir

