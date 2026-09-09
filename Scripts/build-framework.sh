#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="${CONFIGURATION:-Release}"
linkage="${FRAMEWORK_LINKAGE:-static}"
deployment="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
case "$linkage" in static|dynamic) ;; *) echo "FRAMEWORK_LINKAGE must be static or dynamic" >&2; exit 2;; esac
case "$configuration" in Debug) optimization=-Onone ;; Release) optimization=-O ;; *) echo "CONFIGURATION must be Debug or Release" >&2; exit 2;; esac
swift_version="$(xcrun swiftc --version)"
echo "$swift_version"
if ! [[ "$swift_version" =~ Swift\ version\ [6-9]\. ]]; then
  echo "Swift 6 or later with Swift 6 language mode is required" >&2
  exit 1
fi
sdk="$(xcrun --sdk macosx --show-sdk-path)"
framework="dist/$configuration/OpenColorIOMetal.framework"
version="$framework/Versions/A"
mkdir -p "$version/Modules/OpenColorIOMetal.swiftmodule" "$version/Resources" build/framework
sources=()
while IFS= read -r source; do sources+=("$source"); done < <(find Sources/OpenColorIOMetal Sources/OpenColorIOConfig -name '*.swift' -type f | sort)
if [ "${#sources[@]}" -eq 0 ]; then echo "No Swift source files" >&2; exit 1; fi
architectures=(arm64 x86_64)
binaries=()
for arch in "${architectures[@]}"; do
  archdir="build/framework/$configuration/$arch"
  mkdir -p "$archdir"
  triple="$arch-apple-macosx$deployment"
  module_triple="$arch-apple-macos"
  flags=(-swift-version 6 -parse-as-library -module-name OpenColorIOMetal -sdk "$sdk" -target "$triple"
    -enable-library-evolution -emit-module -emit-module-path "$archdir/OpenColorIOMetal.swiftmodule"
    -emit-module-interface-path "$archdir/OpenColorIOMetal.swiftinterface" "$optimization" -g
    -framework Foundation -framework Metal)
  if [ "$linkage" = static ]; then
    xcrun swiftc "${flags[@]}" -whole-module-optimization -emit-object "${sources[@]}" -o "$archdir/OpenColorIOMetal.o"
    xcrun libtool -static -o "$archdir/OpenColorIOMetal" "$archdir/OpenColorIOMetal.o"
  else
    xcrun swiftc "${flags[@]}" -emit-library "${sources[@]}" -o "$archdir/OpenColorIOMetal" \
      -Xlinker -install_name -Xlinker @rpath/OpenColorIOMetal.framework/Versions/A/OpenColorIOMetal
  fi
  for suffix in swiftmodule swiftdoc swiftinterface private.swiftinterface; do
    if [ -f "$archdir/OpenColorIOMetal.$suffix" ]; then
      cp "$archdir/OpenColorIOMetal.$suffix" "$version/Modules/OpenColorIOMetal.swiftmodule/$module_triple.$suffix"
    fi
  done
  binaries+=("$archdir/OpenColorIOMetal")
done
xcrun lipo -create "${binaries[@]}" -output "$version/OpenColorIOMetal"
cp -R Sources/OpenColorIOMetal/Resources/Catalogue "$version/Resources/"
cp LICENSE UPSTREAM.json "$version/Resources/"
cat > "$version/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.opencolorio.metal</string>
<key>CFBundleName</key><string>OpenColorIOMetal</string>
<key>CFBundleExecutable</key><string>OpenColorIOMetal</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
ln -sfn A "$framework/Versions/Current"
ln -sfn Versions/Current/OpenColorIOMetal "$framework/OpenColorIOMetal"
ln -sfn Versions/Current/Modules "$framework/Modules"
ln -sfn Versions/Current/Resources "$framework/Resources"
xcrun lipo -info "$framework/OpenColorIOMetal"
if [ "$linkage" = static ]; then
  # Verify each architecture is an archive, not an accidentally dynamic framework.
  for arch in "${architectures[@]}"; do
    xcrun ar -t "build/framework/$configuration/$arch/OpenColorIOMetal"
  done
fi
echo "Built $linkage $configuration universal framework: $framework"
