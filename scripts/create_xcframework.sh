#!/bin/bash
# create_xcframework.sh
#
# Converts the fat static libraries (libRDPDFLib.a, libRDDLib.a) into
# XCFrameworks that contain proper arm64-simulator slices, enabling
# Xcode 27+ simulator support on Apple Silicon Macs.
#
# The original .a files contain:
#   - armv7  (iOS device, legacy)
#   - x86_64 (iOS simulator, Intel/Rosetta)
#   - arm64  (iOS device)
#
# Xcode 27 dropped x86_64 simulator support, requiring an arm64 slice
# tagged for the iOS Simulator platform.  This script:
#   1. Extracts the arm64 (device) and x86_64 (simulator) slices
#   2. Re-tags every arm64 object file from "ios" to "iossim" using
#      ld -r (to upgrade the Mach-O header) + vtool (to set the platform)
#   3. Creates a fat simulator library (arm64 + x86_64)
#   4. Packages device and simulator libraries into an XCFramework
#
# Usage:
#   cd <project-root>
#   bash scripts/create_xcframework.sh
#
# Prerequisites: Xcode command-line tools (ld, vtool, lipo, ar, ranlib, xcodebuild)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="${PROJECT_DIR}/PDFViewer/PDFLib"
WORK_DIR="/tmp/xcframework_work_$$"
OUTPUT_DIR="${LIB_DIR}"

# Minimum iOS deployment target for the re-tagged objects
MINOS="12.0"
# SDK version stamped into the re-tagged objects
SDK_VERSION="26.5"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

for LIB_NAME in libRDPDFLib libRDDLib; do
    echo "=== Processing ${LIB_NAME}.a ==="

    LIB_FILE="${LIB_DIR}/${LIB_NAME}.a"
    if [ ! -f "$LIB_FILE" ]; then
        echo "  SKIP: ${LIB_FILE} not found"
        continue
    fi

    mkdir -p "${WORK_DIR}/${LIB_NAME}/arm64_device_objs"
    mkdir -p "${WORK_DIR}/${LIB_NAME}/arm64_intermediate_objs"
    mkdir -p "${WORK_DIR}/${LIB_NAME}/arm64_sim_objs"
    mkdir -p "${WORK_DIR}/${LIB_NAME}/ios-arm64"
    mkdir -p "${WORK_DIR}/${LIB_NAME}/ios-arm64_x86_64-simulator"

    # 1. Extract architecture slices
    echo "  Extracting arm64 slice..."
    lipo -thin arm64 -output "${WORK_DIR}/${LIB_NAME}/arm64_device.a" "$LIB_FILE"

    echo "  Extracting x86_64 slice..."
    lipo -thin x86_64 -output "${WORK_DIR}/${LIB_NAME}/x86_64_sim.a" "$LIB_FILE"

    # 2. Extract individual arm64 object files
    echo "  Extracting arm64 objects..."
    cd "${WORK_DIR}/${LIB_NAME}/arm64_device_objs"
    ar x "${WORK_DIR}/${LIB_NAME}/arm64_device.a"

    # 3. Re-tag each .o for the iOS Simulator platform
    #    Step 1: ld -r upgrades LC_VERSION_MIN_IPHONEOS to LC_BUILD_VERSION
    #            (the newer load command is larger and needs header space that
    #             the original objects lack; ld -r allocates a fresh header)
    #            -keep_private_externs preserves global symbol visibility
    #    Step 2: vtool changes the platform field from "ios" to "iossim"
    echo "  Re-tagging arm64 objects for simulator..."
    OBJ_COUNT=0
    FAIL_COUNT=0
    for obj in "${WORK_DIR}/${LIB_NAME}/arm64_device_objs"/*.o; do
        obj_name=$(basename "$obj")
        intermediate="${WORK_DIR}/${LIB_NAME}/arm64_intermediate_objs/${obj_name}"
        output="${WORK_DIR}/${LIB_NAME}/arm64_sim_objs/${obj_name}"

        if ld -r -arch arm64 -platform_version ios "$MINOS" "$SDK_VERSION" \
              -keep_private_externs "$obj" -o "$intermediate" 2>/dev/null; then
            if vtool -set-build-version iossim "$MINOS" "$SDK_VERSION" \
                  -replace -output "$output" "$intermediate" 2>/dev/null; then
                OBJ_COUNT=$((OBJ_COUNT + 1))
            else
                echo "    WARNING: vtool failed for ${obj_name}"
                FAIL_COUNT=$((FAIL_COUNT + 1))
            fi
        else
            echo "    WARNING: ld -r failed for ${obj_name}"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    done
    echo "  Re-tagged ${OBJ_COUNT} objects (${FAIL_COUNT} failures)"

    if [ "$FAIL_COUNT" -gt 0 ]; then
        echo "  ERROR: some objects failed to convert; aborting ${LIB_NAME}"
        continue
    fi

    # 4. Re-archive arm64-simulator objects
    echo "  Creating arm64-simulator archive..."
    cd "${WORK_DIR}/${LIB_NAME}/arm64_sim_objs"
    ar rcs "${WORK_DIR}/${LIB_NAME}/arm64_sim.a" *.o
    ranlib "${WORK_DIR}/${LIB_NAME}/arm64_sim.a"

    # 5. Create fat simulator library (arm64 + x86_64)
    echo "  Creating fat simulator library..."
    lipo -create \
        "${WORK_DIR}/${LIB_NAME}/arm64_sim.a" \
        "${WORK_DIR}/${LIB_NAME}/x86_64_sim.a" \
        -output "${WORK_DIR}/${LIB_NAME}/ios-arm64_x86_64-simulator/${LIB_NAME}.a"

    # 6. Copy device library (arm64 only)
    cp "${WORK_DIR}/${LIB_NAME}/arm64_device.a" \
       "${WORK_DIR}/${LIB_NAME}/ios-arm64/${LIB_NAME}.a"

    # 7. Create XCFramework
    echo "  Creating xcframework..."
    rm -rf "${OUTPUT_DIR}/${LIB_NAME}.xcframework"
    xcodebuild -create-xcframework \
        -library "${WORK_DIR}/${LIB_NAME}/ios-arm64/${LIB_NAME}.a" \
        -library "${WORK_DIR}/${LIB_NAME}/ios-arm64_x86_64-simulator/${LIB_NAME}.a" \
        -output "${OUTPUT_DIR}/${LIB_NAME}.xcframework"

    echo "  Done: ${OUTPUT_DIR}/${LIB_NAME}.xcframework"
    echo ""
done

echo "=== All xcframeworks created successfully ==="
echo ""
echo "Next steps:"
echo "  1. Open the project in Xcode"
echo "  2. Remove the old .a library reference from the project"
echo "  3. Add the new .xcframework to the project"
echo "  4. Remove any EXCLUDED_ARCHS[sdk=iphonesimulator*] settings"
echo "  5. Clean Build Folder (Cmd+Shift+K) and rebuild"
