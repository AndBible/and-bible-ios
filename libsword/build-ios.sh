#!/bin/bash
#
# build-ios.sh — Cross-compile libsword C++ for Apple platforms
#
# Produces: libsword.xcframework containing:
#   - iOS arm64 (device)
#   - iOS Simulator arm64 + x86_64 (fat binary)
#   - macOS arm64 + x86_64 (fat binary)
#
# Prerequisites:
#   - Xcode with command line tools
#   - CMake (brew install cmake)
#   - SWORD source code (cloned from CrossWire SVN)
#
# Usage:
#   cd libsword && ./build-ios.sh
#
# The script will:
#   1. Clone/update the SWORD source if not present
#   2. Build for each target architecture
#   3. Package into an XCFramework

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
OUTPUT_DIR="${SCRIPT_DIR}"
SWORD_SRC="${SCRIPT_DIR}/sword-src"

# SWORD source to build
SWORD_SVN_URL="${SWORD_SVN_URL:-https://crosswire.org/svn/sword/trunk}"
SWORD_SVN_REVISION="${SWORD_SVN_REVISION:-3914}"

# Minimum deployment targets
IOS_MIN="17.0"
MACOS_MIN="14.0"

# Number of parallel build jobs
JOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)

echo "=== libsword iOS Build Script ==="
echo "Build directory: ${BUILD_DIR}"
echo "Output: ${OUTPUT_DIR}/libsword.xcframework"
echo "SWORD source: ${SWORD_SVN_URL}@${SWORD_SVN_REVISION}"
echo ""

# --- Step 1: Get SWORD Source ---

if [ ! -d "${SWORD_SRC}" ]; then
    echo ">>> Cloning SWORD source from CrossWire SVN..."
    echo "    (This may take a while on first run)"

    # Try SVN first, fall back to a mirror
    if command -v svn &>/dev/null; then
        svn checkout -r "${SWORD_SVN_REVISION}" "${SWORD_SVN_URL}" "${SWORD_SRC}" --depth infinity
    else
        echo "ERROR: svn not found. Install with: brew install subversion"
        echo "Alternatively, download SWORD source manually to: ${SWORD_SRC}"
        exit 1
    fi
else
    echo ">>> SWORD source found at ${SWORD_SRC}"
    if command -v svn &>/dev/null; then
        echo ">>> Updating SWORD source to revision ${SWORD_SVN_REVISION}"
        svn update -r "${SWORD_SVN_REVISION}" "${SWORD_SRC}"
    else
        echo "ERROR: svn not found. Install with: brew install subversion"
        exit 1
    fi
fi

# --- Step 2: CMake Build Function ---

build_for_platform() {
    local PLATFORM=$1     # iphoneos, iphonesimulator, macosx
    local ARCHS=$2        # arm64, "arm64;x86_64"
    local MIN_VERSION=$3  # 17.0, 14.0
    local BUILD_SUBDIR="${BUILD_DIR}/${PLATFORM}"

    echo ""
    echo ">>> Building for ${PLATFORM} (${ARCHS})..."

    rm -rf "${BUILD_SUBDIR}"
    mkdir -p "${BUILD_SUBDIR}"

    local CMAKE_ARGS=(
        -S "${SWORD_SRC}"
        -B "${BUILD_SUBDIR}"
        -DCMAKE_SYSTEM_NAME="$([ "${PLATFORM}" = "macosx" ] && echo "Darwin" || echo "iOS")"
        -DCMAKE_OSX_ARCHITECTURES="${ARCHS}"
        -DCMAKE_INSTALL_PREFIX="${BUILD_SUBDIR}/install"
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
        -DLIBSWORD_LIBRARY_TYPE=Static
        -DSWORD_BUILD_TESTS=No
        -DSWORD_BUILD_EXAMPLES=No
        -DSWORD_BUILD_UTILS=No
        -DWITH_ICU=OFF
        -DWITH_CURL=OFF
        -DWITH_CLUCENE=OFF
        -DWITH_ZLIB=ON
        "-DCMAKE_C_FLAGS=-DGLOBALREF=extern -DGLOBALDEF= -D__unix__"
        "-DCMAKE_CXX_FLAGS=-DGLOBALREF=extern -DGLOBALDEF= -D__unix__"
    )

    # Platform-specific settings
    case "${PLATFORM}" in
        iphoneos)
            CMAKE_ARGS+=(
                -DCMAKE_OSX_SYSROOT="iphoneos"
                -DCMAKE_OSX_DEPLOYMENT_TARGET="${MIN_VERSION}"
            )
            ;;
        iphonesimulator)
            CMAKE_ARGS+=(
                -DCMAKE_OSX_SYSROOT="iphonesimulator"
                -DCMAKE_OSX_DEPLOYMENT_TARGET="${MIN_VERSION}"
            )
            ;;
        macosx)
            CMAKE_ARGS+=(
                -DCMAKE_OSX_SYSROOT="macosx"
                -DCMAKE_OSX_DEPLOYMENT_TARGET="${MIN_VERSION}"
            )
            ;;
    esac

    # Configure
    cmake "${CMAKE_ARGS[@]}"

    # Build
    cmake --build "${BUILD_SUBDIR}" \
        --parallel "${JOBS}"

    # Install
    cmake --install "${BUILD_SUBDIR}"

    echo ">>> Built ${PLATFORM} successfully"
}

# --- Step 3: Build All Platforms ---

echo ">>> Starting builds..."

# iOS Device (arm64)
build_for_platform "iphoneos" "arm64" "${IOS_MIN}"

# iOS Simulator (arm64 + x86_64)
build_for_platform "iphonesimulator" "arm64;x86_64" "${IOS_MIN}"

# macOS (arm64 + x86_64)
build_for_platform "macosx" "arm64;x86_64" "${MACOS_MIN}"

# --- Step 4: Create XCFramework ---

echo ""
echo ">>> Creating XCFramework..."

# Find the built static libraries
IOS_LIB="${BUILD_DIR}/iphoneos/install/lib/libsword.a"
SIM_LIB="${BUILD_DIR}/iphonesimulator/install/lib/libsword.a"
MAC_LIB="${BUILD_DIR}/macosx/install/lib/libsword.a"

# Find the headers
HEADERS="${BUILD_DIR}/iphoneos/install/include"

# Remove old framework
rm -rf "${OUTPUT_DIR}/libsword.xcframework"

# Create XCFramework
xcodebuild -create-xcframework \
    -library "${IOS_LIB}" -headers "${HEADERS}" \
    -library "${SIM_LIB}" -headers "${HEADERS}" \
    -library "${MAC_LIB}" -headers "${HEADERS}" \
    -output "${OUTPUT_DIR}/libsword.xcframework"

echo ""
echo "=== Build Complete ==="
echo "XCFramework: ${OUTPUT_DIR}/libsword.xcframework"
echo ""

# --- Step 5: Verify ---

echo ">>> Verifying XCFramework..."
xcodebuild -checkFirstLaunchStatus 2>/dev/null || true

for PLATFORM_DIR in "${OUTPUT_DIR}/libsword.xcframework"/*/; do
    PLATFORM_NAME=$(basename "${PLATFORM_DIR}")
    if [ -f "${PLATFORM_DIR}libsword.a" ]; then
        SIZE=$(du -h "${PLATFORM_DIR}libsword.a" | cut -f1)
        ARCHS=$(lipo -info "${PLATFORM_DIR}libsword.a" 2>/dev/null | sed 's/.*: //')
        echo "  ${PLATFORM_NAME}: ${SIZE} (${ARCHS})"
    fi
done

echo ""
echo ">>> To use in your project, add libsword.xcframework to Xcode"
echo "    or reference it in Package.swift with .binaryTarget()"
