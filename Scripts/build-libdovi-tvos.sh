#!/bin/bash
#
# Build libdovi for tvOS from source (quietvoid/dovi_tool)
# Produces: Libdovi.xcframework with tvOS device + simulator slices
#
# Usage: ./build-libdovi-tvos.sh [dovi_tool-source-dir]
#
# Prerequisites:
#   - Rust (rustup install nightly && rustup component add rust-src --toolchain nightly)
#   - cargo-c (cargo install cargo-c)
#   - Xcode with tvOS SDK
#   - dovi_tool source (git clone https://github.com/quietvoid/dovi_tool.git)
#
# Output: ./libdovi-tvos-build/Libdovi.xcframework

set -euo pipefail

DOVI_SRC="${1:-$(pwd)/dovi_tool}"
BUILD_DIR="$(pwd)/libdovi-tvos-build"
TVOS_MIN="18.0"

if [ ! -d "$DOVI_SRC/dolby_vision" ]; then
    echo "Error: dovi_tool source not found at $DOVI_SRC"
    echo "Usage: $0 [path-to-dovi_tool-source]"
    echo ""
    echo "To get the source:"
    echo "  git clone https://github.com/quietvoid/dovi_tool.git"
    echo "  cd dovi_tool && git checkout libdovi-1.6.7"
    exit 1
fi

# Check prerequisites
if ! command -v rustup &>/dev/null; then
    echo "Error: rustup not found. Install Rust: https://rustup.rs"
    exit 1
fi

if ! cargo c --version &>/dev/null 2>&1; then
    echo "Installing cargo-c..."
    cargo install cargo-c
fi

# Ensure nightly toolchain with rust-src (needed for -Zbuild-std on tier 3 targets)
if ! rustup run nightly rustc --version &>/dev/null; then
    echo "Installing Rust nightly toolchain..."
    rustup install nightly
fi
rustup component add rust-src --toolchain nightly 2>/dev/null || true

# Find tvOS SDKs
TVOS_SDK=$(xcrun --sdk appletvos --show-sdk-path 2>/dev/null)
TVOS_SIM_SDK=$(xcrun --sdk appletvsimulator --show-sdk-path 2>/dev/null)
if [ -z "$TVOS_SDK" ]; then
    echo "Error: tvOS SDK not found."
    exit 1
fi
echo "tvOS SDK: $TVOS_SDK"
echo "tvOS Simulator SDK: $TVOS_SIM_SDK"

# Clean
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"/{device,simulator,headers}

cd "$DOVI_SRC/dolby_vision"

# Build for tvOS device (aarch64-apple-tvos)
echo ""
echo "=== Building libdovi for tvOS device (aarch64-apple-tvos) ==="
SDKROOT="$TVOS_SDK" \
CFLAGS_aarch64_apple_tvos="-mtvos-version-min=$TVOS_MIN -isysroot $TVOS_SDK" \
cargo +nightly build \
    --release \
    --lib \
    --target aarch64-apple-tvos \
    -Zbuild-std=std,panic_abort

# Copy device static lib
cp "$DOVI_SRC/target/aarch64-apple-tvos/release/libdovi.a" "$BUILD_DIR/device/"
echo "Device lib: $(du -h "$BUILD_DIR/device/libdovi.a" | cut -f1)"

# Build for tvOS simulator (aarch64-apple-tvos-sim)
echo ""
echo "=== Building libdovi for tvOS simulator (aarch64-apple-tvos-sim) ==="
SDKROOT="$TVOS_SIM_SDK" \
CFLAGS_aarch64_apple_tvos_sim="-mtvos-simulator-version-min=$TVOS_MIN -isysroot $TVOS_SIM_SDK" \
cargo +nightly build \
    --release \
    --lib \
    --target aarch64-apple-tvos-sim \
    -Zbuild-std=std,panic_abort

# Copy simulator static lib
cp "$DOVI_SRC/target/aarch64-apple-tvos-sim/release/libdovi.a" "$BUILD_DIR/simulator/"
echo "Simulator lib: $(du -h "$BUILD_DIR/simulator/libdovi.a" | cut -f1)"

# Generate C headers using cbindgen
echo ""
echo "=== Generating C headers ==="
if command -v cbindgen &>/dev/null; then
    cbindgen --config cbindgen.toml --crate dolby_vision --output "$BUILD_DIR/headers/libdovi/rpu_parser.h"
else
    echo "cbindgen not found, installing..."
    cargo install cbindgen
    cbindgen --config cbindgen.toml --crate dolby_vision --output "$BUILD_DIR/headers/libdovi/rpu_parser.h"
fi

# Create module.modulemap for Swift import
cat > "$BUILD_DIR/headers/libdovi/module.modulemap" << 'MODULEMAP'
framework module Libdovi {
    umbrella header "rpu_parser.h"
    export *
    module * { export * }
}
MODULEMAP

# Create xcframework
echo ""
echo "=== Creating Libdovi.xcframework ==="

# Create framework structure for device
DEVICE_FW="$BUILD_DIR/device/Libdovi.framework"
mkdir -p "$DEVICE_FW/Headers" "$DEVICE_FW/Modules"
cp "$BUILD_DIR/device/libdovi.a" "$DEVICE_FW/Libdovi"
cp "$BUILD_DIR/headers/libdovi/rpu_parser.h" "$DEVICE_FW/Headers/"
cp "$BUILD_DIR/headers/libdovi/module.modulemap" "$DEVICE_FW/Modules/"
cat > "$DEVICE_FW/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.github.quietvoid.libdovi</string>
    <key>CFBundleName</key><string>Libdovi</string>
    <key>CFBundleVersion</key><string>1.6.7</string>
    <key>CFBundleShortVersionString</key><string>1.6.7</string>
    <key>MinimumOSVersion</key><string>${TVOS_MIN}</string>
</dict>
</plist>
PLIST

# Create framework structure for simulator
SIM_FW="$BUILD_DIR/simulator/Libdovi.framework"
mkdir -p "$SIM_FW/Headers" "$SIM_FW/Modules"
cp "$BUILD_DIR/simulator/libdovi.a" "$SIM_FW/Libdovi"
cp "$BUILD_DIR/headers/libdovi/rpu_parser.h" "$SIM_FW/Headers/"
cp "$BUILD_DIR/headers/libdovi/module.modulemap" "$SIM_FW/Modules/"
cp "$DEVICE_FW/Info.plist" "$SIM_FW/Info.plist"

# Build xcframework
rm -rf "$BUILD_DIR/Libdovi.xcframework"
xcodebuild -create-xcframework \
    -framework "$DEVICE_FW" \
    -framework "$SIM_FW" \
    -output "$BUILD_DIR/Libdovi.xcframework"

echo ""
echo "=== Done ==="
echo "Output: $BUILD_DIR/Libdovi.xcframework"
echo ""
echo "To install into Rivulet:"
echo "  cp -R $BUILD_DIR/Libdovi.xcframework Frameworks/Libdovi.xcframework"
