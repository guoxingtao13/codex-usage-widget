#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY=${0:A:h}
PROJECT_DIRECTORY=${SCRIPT_DIRECTORY:h}
BUILD_CONFIGURATION=release
PRODUCT_NAME=CodexUsageWidget
WIDGET_PRODUCT_NAME=CodexUsageWidgetExtension
AGENT_PRODUCT_NAME=CodexUsageAgent
APP_NAME="Codex 用量"
DIST_DIRECTORY="$PROJECT_DIRECTORY/dist"
XCODE_BUILD_DIRECTORY="$PROJECT_DIRECTORY/.xcode-build"
AGENT_BUILD_DIRECTORY="$PROJECT_DIRECTORY/.agent-build"
AGENT_BUILD_BINARY="$AGENT_BUILD_DIRECTORY/$AGENT_PRODUCT_NAME"
APP_BUNDLE="$DIST_DIRECTORY/$APP_NAME.app"
CONTENTS_DIRECTORY="$APP_BUNDLE/Contents"
MACOS_DIRECTORY="$CONTENTS_DIRECTORY/MacOS"
RESOURCES_DIRECTORY="$CONTENTS_DIRECTORY/Resources"
PLUGINS_DIRECTORY="$CONTENTS_DIRECTORY/PlugIns"
HELPERS_DIRECTORY="$CONTENTS_DIRECTORY/Helpers"
WIDGET_BUNDLE="$PLUGINS_DIRECTORY/$WIDGET_PRODUCT_NAME.appex"
WIDGET_CONTENTS_DIRECTORY="$WIDGET_BUNDLE/Contents"

cd "$PROJECT_DIRECTORY"

swift build --configuration "$BUILD_CONFIGURATION" --product "$PRODUCT_NAME"

BUILD_BINARY=$(swift build --configuration "$BUILD_CONFIGURATION" --show-bin-path)/"$PRODUCT_NAME"

XCODE_DEVELOPER_DIRECTORY=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
XCODE_SIGNING_ARGUMENTS=()
DEVELOPMENT_TEAM=${CODEX_WIDGET_DEVELOPMENT_TEAM:-}
if [[ -n "$DEVELOPMENT_TEAM" ]]; then
    XCODE_SIGNING_ARGUMENTS+=(
        CODE_SIGN_STYLE=Automatic
        DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
    )
else
    XCODE_SIGNING_ARGUMENTS+=(CODE_SIGNING_ALLOWED=NO)
fi

env DEVELOPER_DIR="$XCODE_DEVELOPER_DIRECTORY" \
    xcodebuild \
    -project "$PROJECT_DIRECTORY/CodexUsageWidget.xcodeproj" \
    -scheme "$WIDGET_PRODUCT_NAME" \
    -configuration Release \
    -derivedDataPath "$XCODE_BUILD_DIRECTORY" \
    build \
    "${XCODE_SIGNING_ARGUMENTS[@]}"

XCODE_WIDGET_BUNDLE="$XCODE_BUILD_DIRECTORY/Build/Products/Release/$WIDGET_PRODUCT_NAME.appex"

mkdir -p "$AGENT_BUILD_DIRECTORY"
SDK_PATH=$(env DEVELOPER_DIR="$XCODE_DEVELOPER_DIRECTORY" xcrun --sdk macosx --show-sdk-path)
SWIFT_COMPILER=$(env DEVELOPER_DIR="$XCODE_DEVELOPER_DIRECTORY" xcrun --find swiftc)

"$SWIFT_COMPILER" \
    -parse-as-library \
    -O \
    -target arm64-apple-macos14.0 \
    -sdk "$SDK_PATH" \
    -module-name "$AGENT_PRODUCT_NAME" \
    -framework Network \
    -framework WidgetKit \
    -o "$AGENT_BUILD_BINARY" \
    "$PROJECT_DIRECTORY/Sources/CodexUsageAgent/CodexUsageAgentMain.swift" \
    "$PROJECT_DIRECTORY/Sources/CodexUsageWidget/CodexUsageMonitor.swift" \
    "$PROJECT_DIRECTORY/Sources/CodexUsageWidget/UsageModels.swift" \
    "$PROJECT_DIRECTORY/Sources/CodexUsageWidget/UsageSnapshotServer.swift" \
    "$PROJECT_DIRECTORY/Sources/CodexUsageWidget/WidgetConfiguration.swift"

rm -rf "$APP_BUNDLE"
mkdir -p \
    "$MACOS_DIRECTORY" \
    "$RESOURCES_DIRECTORY" \
    "$PLUGINS_DIRECTORY" \
    "$HELPERS_DIRECTORY"

cp "$BUILD_BINARY" "$MACOS_DIRECTORY/$PRODUCT_NAME"
cp "$AGENT_BUILD_BINARY" "$HELPERS_DIRECTORY/$AGENT_PRODUCT_NAME"
cp "$PROJECT_DIRECTORY/Resources/Info.plist" "$CONTENTS_DIRECTORY/Info.plist"
cp "$PROJECT_DIRECTORY/Resources/local.codex.usage-agent.plist" "$RESOURCES_DIRECTORY/"
cp -R "$XCODE_WIDGET_BUNDLE" "$WIDGET_BUNDLE"

chmod 755 "$MACOS_DIRECTORY/$PRODUCT_NAME"
chmod 755 "$HELPERS_DIRECTORY/$AGENT_PRODUCT_NAME"

SIGNING_IDENTITY=${CODEX_WIDGET_SIGNING_IDENTITY:-}
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning \
        | awk '/Apple Development:|Developer ID Application:/ { print $2; exit }')
fi

if [[ -n "$SIGNING_IDENTITY" ]]; then
    codesign \
        --force \
        --options runtime \
        --sign "$SIGNING_IDENTITY" \
        "$HELPERS_DIRECTORY/$AGENT_PRODUCT_NAME"
    codesign \
        --force \
        --options runtime \
        --entitlements "$PROJECT_DIRECTORY/Resources/Widget.entitlements" \
        --sign "$SIGNING_IDENTITY" \
        "$WIDGET_BUNDLE"
    codesign \
        --force \
        --options runtime \
        --entitlements "$PROJECT_DIRECTORY/Resources/App.entitlements" \
        --sign "$SIGNING_IDENTITY" \
        "$APP_BUNDLE"
else
    codesign --force --sign - "$HELPERS_DIRECTORY/$AGENT_PRODUCT_NAME"
    codesign \
        --force \
        --entitlements "$PROJECT_DIRECTORY/Resources/Widget.entitlements" \
        --sign - \
        "$WIDGET_BUNDLE"
    codesign --force --sign - "$APP_BUNDLE"
fi

plutil -lint "$CONTENTS_DIRECTORY/Info.plist"
plutil -lint "$WIDGET_CONTENTS_DIRECTORY/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "$APP_BUNDLE"
