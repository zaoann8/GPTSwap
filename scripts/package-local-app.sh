#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
RESOURCE_BUNDLE="CodexAccountSwitcher_CodexAccountSwitcher.bundle"
APP_ICON="$PROJECT_DIR/assets/AppIcon.icns"
APP_VERSION=${RELEASE_VERSION:-1.0.16}
SWIFT_EXECUTABLE=${SWITCHER_SWIFT:-swift}
case "${1:-}" in
    ''|--personal) ;;
    *) print -u2 'Usage: package-local-app.sh [--personal]'; exit 2 ;;
esac
APP_NAME="gptswap"
BUNDLE_IDENTIFIER="local.gptswap"

cd "$PROJECT_DIR"
BUILD_ARGUMENTS=(-c release --product CodexAccountSwitcher --disable-dependency-cache)
if [[ "${SWITCHER_DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]]; then
    BUILD_ARGUMENTS+=(--disable-sandbox)
fi
if [[ "$(xcode-select -p 2>/dev/null || true)" == "/Library/Developer/CommandLineTools" ]]; then
    BUILD_ARGUMENTS+=(--build-system native)
fi
if [[ -n "${SWIFT_BUILD_ARCH:-}" ]]; then
    BUILD_ARGUMENTS+=(--arch "$SWIFT_BUILD_ARCH")
fi

"$SWIFT_EXECUTABLE" build "${BUILD_ARGUMENTS[@]}"
BUILD_DIR=$("$SWIFT_EXECUTABLE" build "${BUILD_ARGUMENTS[@]}" --show-bin-path)
PACKAGE_DIR=$(mktemp -d "$BUILD_DIR/personal-package.XXXXXXXX")
APP_DIR="$PACKAGE_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BUILD_DIR/CodexAccountSwitcher" "$MACOS_DIR/CodexAccountSwitcher"
chmod 0755 "$MACOS_DIR/CodexAccountSwitcher"
ditto "$BUILD_DIR/$RESOURCE_BUNDLE" "$RESOURCES_DIR/$RESOURCE_BUNDLE"
ditto "$APP_ICON" "$RESOURCES_DIR/AppIcon.icns"
cp "$PROJECT_DIR/LICENSE" "$RESOURCES_DIR/LICENSE.txt"

/usr/bin/plutil -create xml1 "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleDevelopmentRegion -string en "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleDisplayName -string "$APP_NAME" "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string CodexAccountSwitcher "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string "$BUNDLE_IDENTIFIER" "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleIconFile -string AppIcon "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleName -string "$APP_NAME" "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundlePackageType -string APPL "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string "$APP_VERSION" "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleVersion -string "$APP_VERSION" "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert LSMinimumSystemVersion -string 14.0 "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert NSHighResolutionCapable -bool true "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert LSUIElement -bool false "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CodexSwitcherPersonalBuild -bool true "$CONTENTS_DIR/Info.plist"

/usr/bin/codesign --sign - --timestamp=none "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"

echo "$APP_DIR"
