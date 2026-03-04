#!/bin/bash
#
# Build minimal FFmpeg for tvOS (arm64 only)
# Produces static libraries: libavformat.a, libavutil.a, libavcodec.a
# Only demuxers, parsers, and protocols — no encoders, decoders, or filters.
#
# Usage: ./build-ffmpeg-tvos.sh [ffmpeg-source-dir]
#
# Prerequisites:
#   - Xcode with tvOS SDK installed
#   - FFmpeg source (git clone https://git.ffmpeg.org/ffmpeg.git)
#   - pkg-config (brew install pkg-config)
#
# Output: ./ffmpeg-tvos-build/lib/*.a and ./ffmpeg-tvos-build/include/*

set -euo pipefail

FFMPEG_SRC="${1:-$(pwd)/ffmpeg}"
BUILD_DIR="$(pwd)/ffmpeg-tvos-build"
TVOS_MIN="18.0"
ARCH="arm64"

if [ ! -d "$FFMPEG_SRC" ]; then
    echo "Error: FFmpeg source directory not found at $FFMPEG_SRC"
    echo "Usage: $0 [path-to-ffmpeg-source]"
    echo ""
    echo "To get FFmpeg source:"
    echo "  git clone https://git.ffmpeg.org/ffmpeg.git"
    echo "  cd ffmpeg && git checkout n7.1"
    exit 1
fi

# Find tvOS SDK
TVOS_SDK=$(xcrun --sdk appletvos --show-sdk-path 2>/dev/null)
if [ -z "$TVOS_SDK" ]; then
    echo "Error: tvOS SDK not found. Install Xcode with tvOS support."
    exit 1
fi
echo "Using tvOS SDK: $TVOS_SDK"

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

cd "$FFMPEG_SRC"

# Clean any previous FFmpeg build artifacts
make distclean 2>/dev/null || true

echo "Configuring FFmpeg for tvOS arm64 (demuxer-only build)..."

# Configure minimal build
./configure \
    --prefix="$BUILD_DIR" \
    --target-os=darwin \
    --arch="$ARCH" \
    --enable-cross-compile \
    --cc="xcrun -sdk appletvos clang" \
    --as="xcrun -sdk appletvos clang" \
    --ar="xcrun -sdk appletvos ar" \
    --ranlib="xcrun -sdk appletvos ranlib" \
    --strip="xcrun -sdk appletvos strip" \
    --extra-cflags="-arch $ARCH -mtvos-version-min=$TVOS_MIN -isysroot $TVOS_SDK -fembed-bitcode -DCONFIG_SECURETRANSPORT=1" \
    --extra-ldflags="-arch $ARCH -mtvos-version-min=$TVOS_MIN -isysroot $TVOS_SDK" \
    --disable-everything \
    \
    --enable-demuxer=matroska,mov,mpegts,hls,flv,avi,ogg,wav,aiff,flac,mp3,concat,srt,webvtt,ass \
    --enable-parser=hevc,h264,aac,ac3,eac3,flac,opus,vorbis,h263 \
    --enable-protocol=file,http,https,tcp,tls,crypto \
    --enable-decoder=srt,webvtt,ass,ssa,subrip,truehd,mlp,dca \
    \
    --disable-encoders \
    --disable-muxers \
    --disable-filters \
    --disable-bsfs \
    --disable-indevs \
    --disable-outdevs \
    --disable-programs \
    --disable-doc \
    --disable-htmlpages \
    --disable-manpages \
    --disable-podpages \
    --disable-txtpages \
    --disable-network \
    --enable-network \
    --disable-debug \
    --disable-symver \
    --disable-stripping \
    --disable-avdevice \
    --enable-swresample \
    --disable-swscale \
    --disable-postproc \
    --disable-avfilter \
    --enable-small \
    --enable-pic \
    --enable-static \
    --disable-shared \
    --enable-securetransport \
    --disable-videotoolbox \
    --disable-audiotoolbox

echo ""
echo "Building FFmpeg..."
make -j$(sysctl -n hw.ncpu)

echo ""
echo "Installing to $BUILD_DIR..."
make install

echo ""
echo "Build complete!"
echo ""
echo "Libraries:"
ls -lh "$BUILD_DIR/lib/"*.a 2>/dev/null || echo "  (none found)"
echo ""
echo "Headers:"
ls -d "$BUILD_DIR/include/"*/ 2>/dev/null || echo "  (none found)"
echo ""

# Show total size
TOTAL_SIZE=$(du -sh "$BUILD_DIR/lib/" | cut -f1)
echo "Total library size: $TOTAL_SIZE"
echo ""
echo "Next steps:"
echo "  1. Add $BUILD_DIR/lib/*.a to your Xcode project (Link Binary With Libraries)"
echo "  2. Add $BUILD_DIR/include to Header Search Paths"
echo "  3. Add -lz -liconv to Other Linker Flags"
echo "  4. Ensure FFmpegBridge.h is set as the bridging header for the target"
