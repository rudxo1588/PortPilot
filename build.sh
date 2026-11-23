#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p Build/ModuleCache
# Sign a fresh bundle before replacing the running app. Finder metadata on an
# existing bundle can make codesign refuse it; no security attributes are removed.
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/portpilot-build.XXXXXX")"
APP_STAGE="$STAGING_DIR/PortPilot.app"
trap 'rm -rf "$STAGING_DIR"' EXIT
mkdir -p "$APP_STAGE/Contents/MacOS" "$APP_STAGE/Contents/Resources"
SDK_PATH="$(xcrun --show-sdk-path)"
swiftc -O -swift-version 5 -sdk "$SDK_PATH" -target arm64-apple-macosx14.0 -module-cache-path Build/ModuleCache Resources/generate-icon.swift -framework AppKit -o Build/generate-icon
Build/generate-icon Resources
cp -X Resources/PortPilot.icns "$APP_STAGE/Contents/Resources/PortPilot.icns"
clang -O2 -Wall -Wextra -isysroot "$SDK_PATH" -mmacosx-version-min=14.0 -c Sources/ProcessBridge.c -o Build/ProcessBridge.o
swiftc -O -swift-version 5 -sdk "$SDK_PATH" -target arm64-apple-macosx14.0 -module-cache-path Build/ModuleCache -import-objc-header Sources/ProcessBridge.h Sources/PortCore.swift Sources/main.swift Build/ProcessBridge.o -framework AppKit -o "$APP_STAGE/Contents/MacOS/PortPilot"
cat > "$APP_STAGE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>PortPilot</string>
<key>CFBundleDisplayName</key><string>PortPilot</string>
<key>CFBundleIdentifier</key><string>local.portpilot.app</string>
<key>CFBundleExecutable</key><string>PortPilot</string>
<key>CFBundleIconFile</key><string>PortPilot.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --identifier local.portpilot.app --timestamp=none "$APP_STAGE"
codesign --verify --deep --strict "$APP_STAGE"
# Archive the verified bundle before a cloud-backed workspace attaches metadata.
mkdir -p Dist
ditto -c -k --norsrc --keepParent "$APP_STAGE" Dist/PortPilot-macOS-arm64.zip
if [[ -d Build/PortPilot.app ]]; then
    PREVIOUS_DIR="$(mktemp -d Build/previous-build.XXXXXX)"
    mv Build/PortPilot.app "$PREVIOUS_DIR/PortPilot.app"
fi
mv "$APP_STAGE" Build/PortPilot.app
if ! codesign --verify --deep --strict Build/PortPilot.app; then
    printf 'Workspace bundle did not pass strict verification. No security attributes were removed. The verified staged bundle is preserved in Dist/PortPilot-macOS-arm64.zip.\n' >&2
fi
LC_ALL=C shasum -a 256 Sources/ProcessBridge.c Sources/ProcessBridge.h Sources/PortCore.swift Sources/main.swift Resources/generate-icon.swift Resources/PortPilot.icns build.sh > Build/built_sources.sha256
printf 'Built: %s/Build/PortPilot.app\n' "$PWD"
