#!/usr/bin/env bash
set -euo pipefail

APP_NAME="OpenWhisper"
SCHEME="OpenWhisper"
REPO="richardwu/openwhisper"

# --- Parse args ---
if [ $# -lt 1 ]; then
  echo "Usage: scripts/create_release.sh <VERSION>"
  echo "  e.g. scripts/create_release.sh 0.2.0"
  exit 1
fi

VERSION="$1"
TAG="v${VERSION}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.release"

cd "$PROJECT_DIR"

# --- Validate environment ---
echo "==> Checking prerequisites..."

command -v xcodegen >/dev/null || { echo "Error: xcodegen not found (brew install xcodegen)"; exit 1; }
command -v hdiutil >/dev/null || { echo "Error: hdiutil not found (should be built-in on macOS)"; exit 1; }
command -v gh >/dev/null || { echo "Error: gh not found (brew install gh)"; exit 1; }
command -v xcrun >/dev/null || { echo "Error: xcrun not found (install Xcode)"; exit 1; }

# Check for Developer ID cert
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "Error: No 'Developer ID Application' certificate found in keychain."
  echo "Create one in Xcode → Settings → Accounts → Manage Certificates."
  exit 1
fi

TEAM_ID=$(security find-certificate -c "Developer ID Application" -p | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([^,]*\).*/\1/p')
if [ -z "$TEAM_ID" ]; then
  echo "Error: Could not extract Team ID from Developer ID certificate"
  exit 1
fi
echo "    Team ID: $TEAM_ID"
echo "    Version: $VERSION (tag: $TAG)"

# Check for Sparkle public key
SPARKLE_PUBLIC_KEY=$(.build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -p 2>/dev/null || true)
if [ -z "$SPARKLE_PUBLIC_KEY" ]; then
  echo "Error: No Sparkle EdDSA key found. Run: .build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys"
  exit 1
fi
echo "    Sparkle public key: ${SPARKLE_PUBLIC_KEY:0:20}..."

# --- Bump versions in project.yml ---
echo ""
echo "==> Bumping versions in project.yml..."
OLD_BUILD=$(grep 'CURRENT_PROJECT_VERSION' project.yml | head -1 | sed 's/.*: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/')
NEW_BUILD=$((OLD_BUILD + 1))
sed -i '' "s/CURRENT_PROJECT_VERSION: \"$OLD_BUILD\"/CURRENT_PROJECT_VERSION: \"$NEW_BUILD\"/" project.yml
sed -i '' "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"$VERSION\"/" project.yml
echo "    MARKETING_VERSION: $VERSION"
echo "    CURRENT_PROJECT_VERSION: $OLD_BUILD → $NEW_BUILD"

# --- Clean and build ---
echo ""
echo "==> Generating Xcode project..."
xcodegen generate

echo "==> Archiving Release build..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

xcodebuild archive \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$BUILD_DIR/$APP_NAME.xcarchive" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  SPARKLE_PUBLIC_EDKEY="$SPARKLE_PUBLIC_KEY" \
  MARKETING_VERSION="$VERSION" \
  | tail -5

# --- Export ---
echo "==> Exporting archive..."
cat > "$BUILD_DIR/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>teamID</key>
  <string>$TEAM_ID</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath "$BUILD_DIR/$APP_NAME.xcarchive" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
  -exportPath "$BUILD_DIR/export" \
  | tail -3

APP_PATH="$BUILD_DIR/export/$APP_NAME.app"

# --- Notarize ---
echo "==> Notarizing..."
echo "    (You may be prompted for Apple ID credentials on first run."
echo "     Store them with: xcrun notarytool store-credentials)"

ditto -c -k --keepParent "$APP_PATH" "$BUILD_DIR/$APP_NAME-notarize.zip"

xcrun notarytool submit "$BUILD_DIR/$APP_NAME-notarize.zip" \
  --keychain-profile "notarytool" \
  --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "$APP_PATH"

# --- DMG ---
echo "==> Creating DMG..."
# Use hdiutil directly instead of create-dmg to avoid Full Disk Access issues.
# xcodebuild -exportArchive produces root-owned files, so we ditto to a temp dir first.
DMG_STAGING=$(mktemp -d)
DMG_VOL=$(mktemp -d)
DMG_RW="$DMG_STAGING/$APP_NAME-rw.dmg"
trap 'hdiutil detach "$DMG_VOL" 2>/dev/null || true; rm -rf "$DMG_STAGING" "$DMG_VOL"' EXIT

ditto "$APP_PATH" "$DMG_STAGING/$APP_NAME.app"
APP_SIZE_MB=$(du -sm "$DMG_STAGING/$APP_NAME.app" | awk '{print $1}')
DMG_SIZE_MB=$((APP_SIZE_MB + 50))
hdiutil create -size "${DMG_SIZE_MB}m" -fs HFS+ -volname "$APP_NAME" "$DMG_RW"
hdiutil attach "$DMG_RW" -mountpoint "$DMG_VOL"
ditto "$DMG_STAGING/$APP_NAME.app" "$DMG_VOL/$APP_NAME.app"
ln -s /Applications "$DMG_VOL/Applications"
hdiutil detach "$DMG_VOL"
hdiutil convert "$DMG_RW" -format UDZO -imagekey zlib-level=9 -o "$BUILD_DIR/$APP_NAME.dmg"
rm -rf "$DMG_STAGING" "$DMG_VOL"

if [ ! -f "$BUILD_DIR/$APP_NAME.dmg" ]; then
  echo "Error: DMG creation failed"
  exit 1
fi

# --- Sparkle sign ---
echo "==> Signing DMG with Sparkle..."
SIGN_UPDATE=$(find .build -path "*/artifacts/sparkle/Sparkle/bin/sign_update" -type f 2>/dev/null | head -1)
if [ -z "$SIGN_UPDATE" ]; then
  echo "Error: sign_update not found. Run xcodebuild -resolvePackageDependencies first."
  exit 1
fi

SPARKLE_SIG=$("$SIGN_UPDATE" "$BUILD_DIR/$APP_NAME.dmg" 2>&1)
echo "    $SPARKLE_SIG"

ED_SIGNATURE=$(echo "$SPARKLE_SIG" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
DMG_SIZE=$(stat -f%z "$BUILD_DIR/$APP_NAME.dmg")

# --- Appcast ---
echo "==> Updating appcast.xml..."
BUILD_NUMBER=$(grep 'CURRENT_PROJECT_VERSION' project.yml | head -1 | sed 's/.*: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/')
DATE=$(date -R)
DOWNLOAD_URL="https://github.com/$REPO/releases/download/$TAG/$APP_NAME.dmg"

APPCAST_FILE="$PROJECT_DIR/appcast.xml"

python3 - "$APPCAST_FILE" "$VERSION" "$BUILD_NUMBER" "$DATE" "$DOWNLOAD_URL" "$DMG_SIZE" "$ED_SIGNATURE" "$APP_NAME" <<'PYEOF'
import sys
import xml.etree.ElementTree as ET

appcast_file, version, build_number, date, url, length, signature, app_name = sys.argv[1:]

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)

def make_item():
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Version {version}"
    ET.SubElement(item, "pubDate").text = date
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = build_number
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = version
    enc = ET.SubElement(item, "enclosure")
    enc.set("url", url)
    enc.set("length", length)
    enc.set("type", "application/octet-stream")
    enc.set(f"{{{SPARKLE_NS}}}edSignature", signature)
    return item

try:
    tree = ET.parse(appcast_file)
    channel = tree.find("channel")
    # Replace existing item for this version, or insert as first item
    svs_tag = f"{{{SPARKLE_NS}}}shortVersionString"
    existing = [item for item in channel.findall("item") if item.findtext(svs_tag) == version]
    if existing:
        for old in existing:
            idx = list(channel).index(old)
            channel.remove(old)
            channel.insert(idx, make_item())
    else:
        channel.insert(1, make_item())
except (FileNotFoundError, ET.ParseError):
    rss = ET.Element("rss", version="2.0")
    rss.set("xmlns:sparkle", SPARKLE_NS)
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = app_name
    channel.append(make_item())
    tree = ET.ElementTree(rss)

ET.indent(tree, space="  ")
tree.write(appcast_file, xml_declaration=True, encoding="unicode")
# Ensure trailing newline
with open(appcast_file, "a") as f:
    f.write("\n")
PYEOF

cp "$APPCAST_FILE" "$BUILD_DIR/appcast.xml"
echo "    Appcast updated ($(grep -c '<item>' "$APPCAST_FILE") versions)"

# --- Done ---

echo ""
echo "=== Build $VERSION complete ==="
echo "  DMG:     $BUILD_DIR/$APP_NAME.dmg"
echo "  Appcast: appcast.xml (copied to repo root)"
echo ""
echo "Next steps:"
echo "  git tag $TAG && git push origin $TAG"
echo "  gh release create $TAG --title '$APP_NAME $VERSION' --generate-notes $BUILD_DIR/$APP_NAME.dmg"
echo "  git add appcast.xml && git commit -m 'Update appcast.xml for $VERSION' && git push origin main"
echo ""
echo "NOTE: First time? Store notarization credentials with:"
echo "  xcrun notarytool store-credentials notarytool"
