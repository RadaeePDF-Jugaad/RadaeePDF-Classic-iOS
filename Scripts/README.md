# Converting libRDPDFLib.a to an XCFramework with Apple Silicon simulator support

## The problem

`PDFViewer/PDFLib/libRDPDFLib.a` is a prebuilt, closed-source static library.
The copy in this repo is a universal `.a` with three slices:

- `armv7` — 32-bit device, dead since iOS 11 and no longer even parseable by
  current Xcode toolchains.
- `x86_64` — Intel *simulator*.
- `arm64` — **device only**. It predates Apple Silicon Macs, so there is no
  `arm64` *simulator* slice.

That was fine as long as Simulator builds ran on Intel Macs (or under Rosetta) —
this is exactly why the README used to tell developers on M1/M2/M3 Macs to
install the **Universal** (x86_64/Rosetta-inclusive) simulator runtime instead
of the default arm64-only one. On Apple Silicon, Xcode's native simulator
architecture is `arm64`, and this `.a` has no code for that ABI. Newer
Xcode/iOS SDKs (this was done against Xcode 27 / iOS SDK 27) also
increasingly expect dependencies to ship as `.xcframework`s rather than raw
fat `.a` files with manual `EXCLUDED_ARCHS` workarounds.

We don't have the RDPDFLib source, so recompiling for `arm64-simulator` isn't
an option. The fix instead is **binary translation**: take the existing
`arm64` *device* object code and patch its Mach-O load commands so the linker
and dyld treat it as `arm64` *simulator* code. The actual machine code is
untouched — only the platform metadata changes.

## How it works

The heavy lifting is done by [`arm64-to-sim`](https://github.com/bogo/arm64-to-sim),
a small Swift tool that rewrites a Mach-O object file's `LC_BUILD_VERSION` /
`LC_VERSION_MIN_IPHONEOS` load command to declare `PLATFORM_IOSSIMULATOR`
instead of `PLATFORM_IOS`, adjusting a few segment/symtab offsets to match
(older, pre-iOS12-style object files use `version_min_command`, which is a
different size than `build_version_command`, hence the offset shuffle).
Static libraries aren't Mach-O objects themselves — they're `ar` archives of
`.o` files — so the tool has to run per object file, and the archive gets
rebuilt afterwards.

`Scripts/make_xcframework.sh` automates the whole pipeline:

1. `lipo -thin` out the `x86_64` and `arm64` slices from the source `.a`
   (the `armv7` slice is dropped — see above).
2. `ar x` the `arm64` slice into its individual `.o` files.
3. Run `arm64-to-sim <file> <minos> <sdk>` on every `.o`, patching it in place
   to look like `arm64-simulator` object code.
4. `ar crv` the patched objects back into a `libRDPDFLib.a.arm64-sim.a`.
5. `lipo -create` the `x86_64` slice + the `arm64-sim` slice into one
   universal simulator library.
6. `xcodebuild -create-xcframework` combines that simulator library with the
   untouched `arm64` device slice (each with its own copy of the public
   headers) into the final `.xcframework`.

The `arm64-to-sim` tool itself is a Swift package with no binary releases, so
the script clones and builds it on first use (cached under
`~/.cache/arm64-to-sim`, `swift build -c release --arch arm64 --arch x86_64`).

## Usage

```bash
Scripts/make_xcframework.sh <path/to/libFoo.a> [headers_dir] [output.xcframework]
```

For RDPDFLib specifically:

```bash
Scripts/make_xcframework.sh \
    PDFViewer/PDFLib/libRDPDFLib.a \
    PDFViewer/PDFLib \
    PDFViewer/PDFLib/RDPDFLib.xcframework
```

- `headers_dir` (optional) is copied into both `Headers/` subfolders of the
  xcframework. Only `*.h`/`*.m`/`*.mm`/`*.hpp` files directly in that
  directory are copied — the source `.a` living next to the headers (as it
  does in `PDFLib/`) is correctly excluded.
- `output.xcframework` defaults to `<dir of the .a>/<name>.xcframework`
  (`lib` prefix and `.a` extension stripped).
- `MINOS` / `SDK` env vars control the minimum-OS/SDK version stamped onto the
  patched simulator slice (default `12` / `27`, matching this project's
  `IPHONEOS_DEPLOYMENT_TARGET` and the current Xcode's iOS SDK).

Re-run it whenever `libRDPDFLib.a` is updated upstream (a new Radaee SDK
drop) to regenerate `RDPDFLib.xcframework`.

## What this does *not* fix

Getting the xcframework to link and run also required two unrelated project
changes (already applied, kept here for context if this is ever redone from
scratch):

- `EXCLUDED_ARCHS[sdk=iphonesimulator*] = arm64` in
  `PDFViewer.xcodeproj/project.pbxproj` — a legacy workaround for the missing
  arm64-simulator slice (the counterpart of the "install the Universal
  simulator runtime" README instructions). It's no longer needed — and
  actively harmful, since it forces Intel/Rosetta simulator builds — once the
  xcframework is in place.
- The app itself crashed on iOS 27 with `EXC_BREAKPOINT` /
  `UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption` because it
  never adopted the `UIWindowScene` lifecycle
  (`PDFViewer/RDSceneDelegate.{h,m}`, `UIApplicationSceneManifest` in
  `PDFViewer-Info.plist`). Unrelated to the library conversion itself, but
  worth knowing if you're chasing down why a rebuilt xcframework still won't
  run on a fresh checkout.

## Verification

Don't trust `BUILD SUCCEEDED` alone — with an unrelated `EXCLUDED_ARCHS`
misconfiguration, Xcode can report success while silently linking zero
architectures. What actually confirmed the conversion worked:

1. `otool -l` on a patched `.o` shows `LC_BUILD_VERSION` / `platform 7`
   (`PLATFORM_IOSSIMULATOR`) instead of the original
   `LC_VERSION_MIN_IPHONEOS`.
2. A standalone test program (`PDFObjc.m` + a `.m` calling into an RDPDFLib
   class) compiled and linked against the `ios-arm64_x86_64-simulator` slice
   with `clang -arch arm64 -target arm64-apple-ios12.0-simulator`, then
   actually **executed** inside a booted iOS Simulator via
   `xcrun simctl spawn <udid> ./binary` — printing real output from the
   library, not just linking cleanly.
3. `lipo -info` on the app's final linked binary shows both `arm64` and
   `x86_64`.
4. The full PDFViewer app, installed and launched on a booted iOS 27.0
   Simulator (Apple Silicon, native — not Rosetta), successfully opened and
   rendered a real PDF (the bundled EULA) end to end.
