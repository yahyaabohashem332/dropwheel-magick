#!/bin/bash
# Custom clone-dependencies.sh for DropWheel Magick.Native
# Excludes: de265 (HEVC decoder), heif (HEIF container), openh264 (H.264 codec)
# These are patented codecs not allowed for Microsoft Store distribution
# Windows WIC and Media Foundation are used instead

set -e

clone()
{
  local repo=$1
  local folder=$2

  echo ''
  echo "Cloning $repo"

  if [ -z "$folder" ]; then
    folder=$repo
  fi

  if [ -d "$folder" ]; then
    cd $folder
  else
    git clone https://github.com/ImageMagick/$repo.git $folder
    if [ $? != 0 ]; then
      echo "Error during checkout";
      exit;
    fi

    cd $folder
    git remote add sshpush git@github.com:ImageMagick/$repo.git
    git config remote.pushDefault sshpush
  fi

  git reset --hard
  git pull origin main
  cd ..
}

clone_dependencies()
{
  echo "Cloning Core Dependencies (excluding de265, heif)"
  clone aom
  clone brotli
  clone bzip2
  # clone de265  -- EXCLUDED: HEVC decoder (patented)
  clone exr
  clone ffi
  clone freetype
  clone glib
  # clone heif  -- EXCLUDED: HEIF container (depends on libde265, patented)
  clone highway
  clone imath
  clone jpeg-turbo
  clone jpeg-xl
  clone lcms
  clone lqr
  clone openjpeg
  clone openjph
  clone png
  clone raw
  clone tiff
  clone webp
  clone xml
  clone zlib
  clone zstd

  if [ "$1" != "wasm" ]; then
    echo "Cloning Non-WASM Dependencies (excluding openh264)"
    clone cairo
    clone croco
    clone fribidi
    clone gdk-pixbuf
    clone harfbuzz
    clone lzma
    # clone openh264  -- EXCLUDED: H.264 codec (patented)
    clone pango
    clone pixman
    clone raqm
    clone rsvg
    clone zip
  fi

  if [ "$1" == "windows" ]; then
    echo "Cloning Windows-only Dependencies"
    clone jpeg-turbo-12
    clone jpeg-turbo-16

    echo "Cloning Optional Windows Dependencies"
    clone fftw
    clone flif
    clone jbig
  fi

  if [ "$1" != "windows" ]; then
    echo "Cloning Non-Windows Dependencies"
    clone fontconfig
  fi
}

# Parse arguments
platform=""
if [ $# -gt 0 ]; then
  platform=$1
fi

clone_dependencies $platform