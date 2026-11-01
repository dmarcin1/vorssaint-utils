#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
sdk="$1"
[[ -f Dependencies/libwebp/src/webp/encode.h ]] || { print -u2 'Run git submodule update --init Dependencies/libwebp'; exit 1; }
mkdir -p build/webp-source
rsync -a --exclude=.git Dependencies/libwebp/ build/webp-source/
make -s -C build/webp-source -f makefile.unix -j "$(sysctl -n hw.logicalcpu)" \
    CC=clang AR=ar "EXTRA_FLAGS=-target arm64-apple-macosx14.0 -isysroot $sdk -fno-common -DWEBP_USE_THREAD -fvisibility=hidden" \
    src/libwebp.a sharpyuv/libsharpyuv.a
