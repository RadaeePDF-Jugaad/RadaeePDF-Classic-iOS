#!/bin/bash
#
# make_xcframework.sh — turn a legacy universal static library (armv7/x86_64/arm64,
# built for a device-only arm64 slice with no simulator support) into an
# .xcframework that also runs on the Apple Silicon iOS Simulator.
#
# The original .a has no arm64-simulator slice (it predates Apple Silicon Macs),
# so modern Xcode can only run it on Intel simulators via Rosetta, or not at all
# once XCFrameworks are required. This script does NOT recompile anything from
# source (the RDPDFLib sources aren't available to us) — it patches the
# Mach-O load commands of the existing arm64 *device* object files so they are
# accepted as arm64 *simulator* code, using the `arm64-to-sim` tool
# (https://github.com/bogo/arm64-to-sim). See Scripts/README.md for the full
# writeup and background.
#
# Usage:
#   Scripts/make_xcframework.sh <path/to/libFoo.a> [headers_dir] [output.xcframework]
#
# Env overrides:
#   MINOS              minimum simulator deployment version to stamp (default: 12)
#   SDK                simulator SDK version to stamp (default: 27)
#   ARM64_TO_SIM_BIN   path to a prebuilt arm64-to-sim executable (skips auto-build)
#
# Example:
#   Scripts/make_xcframework.sh PDFViewer/PDFLib/libRDPDFLib.a PDFViewer/PDFLib \
#       PDFViewer/PDFLib/RDPDFLib.xcframework

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MINOS="${MINOS:-12}"
SDK="${SDK:-27}"

usage() {
    echo "Usage: $(basename "$0") <path/to/libFoo.a> [headers_dir] [output.xcframework]" >&2
    exit 1
}

[ $# -ge 1 ] || usage

INPUT_A="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
[ -f "$INPUT_A" ] || { echo "❌ not found: $INPUT_A" >&2; exit 1; }

HEADERS_DIR=""
if [ $# -ge 2 ] && [ -n "$2" ]; then
    HEADERS_DIR="$(cd "$2" && pwd)"
fi

BASENAME="$(basename "$INPUT_A")"           # e.g. libRDPDFLib.a
LIBNAME="${BASENAME#lib}"; LIBNAME="${LIBNAME%.a}"  # e.g. RDPDFLib

OUTPUT_XCFW="${3:-$(dirname "$INPUT_A")/$LIBNAME.xcframework}"
OUTPUT_XCFW="$(mkdir -p "$(dirname "$OUTPUT_XCFW")" && cd "$(dirname "$OUTPUT_XCFW")" && pwd)/$(basename "$OUTPUT_XCFW")"

echo "📦 input:   $INPUT_A"
echo "📄 headers: ${HEADERS_DIR:-<none>}"
echo "📦 output:  $OUTPUT_XCFW"
echo "🎯 stamping simulator slice as minos=$MINOS sdk=$SDK"

# ---------------------------------------------------------------------------
# 1. Resolve (or build) the arm64-to-sim tool
# ---------------------------------------------------------------------------

resolve_arm64_to_sim() {
    if [ -n "${ARM64_TO_SIM_BIN:-}" ] && [ -x "${ARM64_TO_SIM_BIN}" ]; then
        echo "$ARM64_TO_SIM_BIN"
        return
    fi

    local cache_dir="$HOME/.cache/arm64-to-sim"
    local src_dir="$cache_dir/src"
    local existing
    existing="$(find "$src_dir/.build" -type f -perm -u+x -name arm64-to-sim 2>/dev/null | head -1 || true)"
    if [ -n "$existing" ]; then
        echo "$existing"
        return
    fi

    echo "🔧 arm64-to-sim not found, building it from source (one-time)..." >&2
    mkdir -p "$cache_dir"
    if [ ! -d "$src_dir" ]; then
        git clone --quiet https://github.com/bogo/arm64-to-sim.git "$src_dir" >&2
    fi
    (cd "$src_dir" && swift build -c release --arch arm64 --arch x86_64) >&2

    local built
    built="$(find "$src_dir/.build" -type f -perm -u+x -name arm64-to-sim 2>/dev/null | head -1 || true)"
    [ -n "$built" ] || { echo "❌ failed to build arm64-to-sim" >&2; exit 1; }
    echo "$built"
}

ARM64_TO_SIM_BIN="$(resolve_arm64_to_sim)"
echo "🔧 arm64-to-sim: $ARM64_TO_SIM_BIN"

# ---------------------------------------------------------------------------
# 2. Work in a throwaway temp dir
# ---------------------------------------------------------------------------

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

DEVICE_A="$WORK_DIR/device/$BASENAME"
SIM_A="$WORK_DIR/sim/$BASENAME"
mkdir -p "$(dirname "$DEVICE_A")" "$(dirname "$SIM_A")" "$WORK_DIR/objs"

echo "✂️  thinning x86_64 + arm64 slices"
lipo -thin x86_64 "$INPUT_A" -output "$WORK_DIR/x86_64.a"
lipo -thin arm64  "$INPUT_A" -output "$DEVICE_A"

echo "🩹 patching arm64 device objects to look like arm64-simulator objects"
(
    cd "$WORK_DIR/objs"
    ar x "$DEVICE_A"
    for f in *.o; do
        "$ARM64_TO_SIM_BIN" "$f" "$MINOS" "$SDK"
    done
    ar crv "$WORK_DIR/arm64-sim.a" *.o > /dev/null
)

echo "🔗 building universal simulator library (x86_64 + arm64-sim)"
lipo -create "$WORK_DIR/x86_64.a" "$WORK_DIR/arm64-sim.a" -output "$SIM_A"

echo "📦 creating xcframework"
rm -rf "$OUTPUT_XCFW"
XCFW_ARGS=(-create-xcframework)
if [ -n "$HEADERS_DIR" ]; then
    # xcodebuild copies the *entire* -headers directory verbatim into the
    # xcframework, so hand it a scratch copy containing only header/source
    # files — not the .a (or anything else) that may live alongside them.
    CLEAN_HEADERS="$WORK_DIR/headers"
    mkdir -p "$CLEAN_HEADERS"
    find "$HEADERS_DIR" -maxdepth 1 -type f \( -name '*.h' -o -name '*.m' -o -name '*.mm' -o -name '*.hpp' \) \
        -exec cp {} "$CLEAN_HEADERS/" \;
    XCFW_ARGS+=(-library "$DEVICE_A" -headers "$CLEAN_HEADERS")
    XCFW_ARGS+=(-library "$SIM_A" -headers "$CLEAN_HEADERS")
else
    XCFW_ARGS+=(-library "$DEVICE_A")
    XCFW_ARGS+=(-library "$SIM_A")
fi
XCFW_ARGS+=(-output "$OUTPUT_XCFW")

xcodebuild "${XCFW_ARGS[@]}"

echo "✅ done: $OUTPUT_XCFW"
lipo -info "$OUTPUT_XCFW"/*/lib*.a 2>/dev/null || true
