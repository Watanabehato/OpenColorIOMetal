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
    -F dist/Release -framework OpenColorIOMetal -framework Metal -framework Foundation \
    "${cli_sources[@]}" -o "build/cli/$arch/ocio-metal"
done
xcrun lipo -create build/cli/arm64/ocio-metal build/cli/x86_64/ocio-metal -output dist/Debug/ocio-metal
xcrun dsymutil dist/Debug/ocio-metal -o dist/Debug/ocio-metal.dSYM
cp -R Sources/OpenColorIOMetal/Resources/Catalogue dist/Debug/
dist/Debug/ocio-metal info --archive dist/Debug/Catalogue
# A consumer links against the packaged framework and its public Swift interface.
cat > build/cli/consumer.swift <<'SWIFT'
import Foundation
import OpenColorIOMetal
let archive = try OCIOCatalogue(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
try archive.validateResources()
print("Framework consumer loaded \(archive.configurations.count) configurations")
SWIFT
xcrun swiftc -swift-version 6 -F dist/Release -framework OpenColorIOMetal \
  -framework Metal -framework Foundation build/cli/consumer.swift -o build/cli/consumer
build/cli/consumer dist/Release/OpenColorIOMetal.framework/Resources/Catalogue
if otool -L dist/Debug/ocio-metal | grep -E 'libOpenColorIO|libc\+\+|libpython|OpenColorIOMetal.framework'; then
  echo "Unexpected dynamic runtime dependency in static CLI" >&2
  exit 1
fi
