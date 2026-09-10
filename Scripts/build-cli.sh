#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sdk="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p dist/Debug build/cli
cli_sources=(Sources/OCIOCLI/*.swift)
for arch in arm64 x86_64; do
  mkdir -p "build/cli/$arch"
  xcrun swiftc -swift-version 6 -parse-as-library -Onone -g \
    -sdk "$sdk" -target "$arch-apple-macosx13.0" \
    -F dist/Debug -framework OpenColorIOMetal -framework Metal -framework Foundation \
    "${cli_sources[@]}" -o "build/cli/$arch/ocio-metal"
done
xcrun lipo -create build/cli/arm64/ocio-metal build/cli/x86_64/ocio-metal -output dist/Debug/ocio-metal
xcrun dsymutil dist/Debug/ocio-metal -o dist/Debug/ocio-metal.dSYM
cp -R Sources/OpenColorIOMetal/Resources/Catalogue dist/Debug/
# A consumer links against the packaged framework and its public Swift interface.
cat > build/cli/consumer.swift <<'SWIFT'
import Foundation
import OpenColorIOMetal
let configuration = try OCIOConfigDocument(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let engine = try MetalColorEngine()
let processor = try engine.nativeProcessor(configuration: configuration, source: "Scaled", destination: "Linear")
let values = try processor.processRGBA([0.125, 0.25, 0.5, 0.75])
precondition(values == [0.25, 0.5, 1, 0.75], "Framework consumer matrix conversion differs")
print("Static framework consumer executed Metal conversion: \(values)")
if CommandLine.arguments.count > 2 {
    let archive = try OCIOCatalogue(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    try archive.validateResources()
    print("Framework consumer loaded \(archive.configurations.count) configurations")
}
SWIFT
cat > build/cli/consumer.ocio <<'YAML'
ocio_profile_version: 2.5
colorspaces:
  - !<ColorSpace> {name: Linear}
  - !<ColorSpace>
    name: Scaled
    to_scene_reference: !<MatrixTransform> {matrix: [2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 1]}
YAML
for arch in arm64 x86_64; do
  xcrun swiftc -swift-version 6 -sdk "$sdk" -target "$arch-apple-macosx13.0" \
    -F dist/Release -framework OpenColorIOMetal -framework Metal -framework Foundation \
    build/cli/consumer.swift -o "build/cli/$arch/consumer"
done
xcrun lipo -create build/cli/arm64/consumer build/cli/x86_64/consumer -output build/cli/consumer
archive_arguments=()
if [ -f dist/Debug/Catalogue/manifest.json ]; then
  dist/Debug/ocio-metal info --archive dist/Debug/Catalogue
  archive_arguments+=(dist/Release/OpenColorIOMetal.framework/Resources/Catalogue)
elif [ "${ALLOW_MISSING_CATALOGUE:-0}" != 1 ]; then
  echo "Generate the complete catalogue before building release CLI artifacts" >&2
  exit 1
fi
build/cli/consumer build/cli/consumer.ocio "${archive_arguments[@]}"
dist/Debug/ocio-metal convert --ocio build/cli/consumer.ocio \
  --src Scaled --dst Linear --rgba '0.125,0.25,0.5,0.75' > build/cli/cli-result.json
python3 -c 'import json; assert json.load(open("build/cli/cli-result.json")) == [0.25, 0.5, 1, 0.75]'
if otool -L dist/Debug/ocio-metal | grep -E 'libOpenColorIO|libc\+\+|libpython|OpenColorIOMetal.framework'; then
  echo "Unexpected dynamic runtime dependency in static CLI" >&2
  exit 1
fi
