#!/bin/bash
cd "$(dirname "$0")"
source ./script/setup.sh

build_version="0.0.0-SNAPSHOT"
apple_id=""
team_id=""
app_password=""

while test $# -gt 0; do
    case $1 in
        --build-version) build_version="$2"; shift 2;;
        --apple-id) apple_id="$2"; shift 2;;
        --team-id) team_id="$2"; shift 2;;
        --app-password) app_password="$2"; shift 2;;
        *) echo "Unknown option $1" > /dev/stderr; exit 1 ;;
    esac
done

if [ -z "$apple_id" ] || [ -z "$team_id" ] || [ -z "$app_password" ]; then
    echo "Error: Missing required parameters"
    echo "Usage: $0 --build-version VERSION --apple-id APPLE_ID --team-id TEAM_ID --app-password APP_PASSWORD"
    echo ""
    echo "Example:"
    echo "  $0 --build-version 0.1.2 \\"
    echo "     --apple-id 'your@email.com' \\"
    echo "     --team-id 'ABC123DEF4' \\"
    echo "     --app-password 'xxxx-xxxx-xxxx-xxxx'"
    echo ""
    echo "Note: Generate app-specific password at https://appleid.apple.com/account/manage"
    exit 1
fi

APP_PATH=".release/AeroSpace.app"
ZIP_PATH=".release/AeroSpace-v$build_version.zip"
DMG_PATH=".release/AeroSpace-v$build_version.dmg"

echo "========================================="
echo "Notarizing AeroSpace v$build_version"
echo "========================================="
echo ""

###############################
### Verify app is signed    ###
###############################

echo "Verifying code signature..."
if ! codesign -vvv --deep --strict "$APP_PATH" 2>&1; then
    echo "Error: App is not properly signed"
    exit 1
fi
echo "✓ App signature verified"
echo ""

###############################
### Create ZIP for notarization ###
###############################

echo "Creating ZIP archive for notarization..."
NOTARIZE_ZIP=".release/AeroSpace-notarize-temp.zip"
rm -f "$NOTARIZE_ZIP"

# Create a clean zip with just the app for notarization
ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

if [ ! -f "$NOTARIZE_ZIP" ]; then
    echo "Error: Failed to create notarization ZIP"
    exit 1
fi
echo "✓ Created notarization ZIP"
echo ""

###############################
### Submit for notarization ###
###############################

echo "Submitting to Apple for notarization..."
echo "This may take 5-10 minutes. Please wait..."
echo ""

# Submit and capture the request UUID
NOTARIZE_OUTPUT=$(xcrun notarytool submit "$NOTARIZE_ZIP" \
    --apple-id "$apple_id" \
    --team-id "$team_id" \
    --password "$app_password" \
    --wait 2>&1)

echo "$NOTARIZE_OUTPUT"

# Check if notarization was successful
if echo "$NOTARIZE_OUTPUT" | grep -q "status: Accepted"; then
    echo ""
    echo "✓ Notarization successful!"
    echo ""
else
    echo ""
    echo "✗ Notarization failed!"
    echo "Check the output above for details."

    # Try to extract submission ID for logs
    SUBMISSION_ID=$(echo "$NOTARIZE_OUTPUT" | grep "id:" | head -1 | awk '{print $2}')
    if [ -n "$SUBMISSION_ID" ]; then
        echo ""
        echo "Get detailed logs with:"
        echo "xcrun notarytool log $SUBMISSION_ID --apple-id '$apple_id' --team-id '$team_id' --password '$app_password'"
    fi

    rm -f "$NOTARIZE_ZIP"
    exit 1
fi

# Clean up notarization zip
rm -f "$NOTARIZE_ZIP"

###############################
### Staple the ticket       ###
###############################

echo "Stapling notarization ticket to app..."
if ! xcrun stapler staple "$APP_PATH" 2>&1; then
    echo "Warning: Failed to staple ticket to app"
    echo "The app is notarized but the ticket is not attached"
else
    echo "✓ Ticket stapled to app"
fi
echo ""

###############################
### Verify notarization     ###
###############################

echo "Verifying notarization with spctl..."
if spctl -a -vvv -t execute "$APP_PATH" 2>&1; then
    echo "✓ App passes Gatekeeper verification"
else
    echo "Warning: App may have issues with Gatekeeper"
fi
echo ""

###############################
### Rebuild DMG             ###
###############################

echo "Rebuilding DMG with notarized app..."

# Remove old DMG
rm -f "$DMG_PATH"

# Create a temporary directory for DMG contents
temp_dmg_dir=".release/dmg-temp"
rm -rf "$temp_dmg_dir" && mkdir -p "$temp_dmg_dir"

# Copy notarized app to temp directory
cp -r "$APP_PATH" "$temp_dmg_dir/"

# Create Applications symlink for easy installation
ln -s /Applications "$temp_dmg_dir/Applications"

# Create the DMG
echo "Creating DMG..."
hdiutil create -volname "HyprSpace v$build_version" \
    -srcfolder "$temp_dmg_dir" \
    -ov -format UDZO \
    "$DMG_PATH"

# Cleanup
rm -rf "$temp_dmg_dir"

if [ ! -f "$DMG_PATH" ]; then
    echo "Error: Failed to create DMG"
    exit 1
fi

echo "✓ DMG created"
echo ""

###############################
### Sign the DMG            ###
###############################

echo "Signing the DMG..."
# Get the same certificate used for the app
CERT_IDENTITY=$(codesign -dvv "$APP_PATH" 2>&1 | grep "Authority=" | head -1 | sed 's/Authority=//')

if [ -n "$CERT_IDENTITY" ]; then
    codesign -s "$CERT_IDENTITY" "$DMG_PATH"
    echo "✓ DMG signed with: $CERT_IDENTITY"
else
    echo "Warning: Could not determine certificate identity, DMG not signed"
fi
echo ""

###############################
### Update ZIP              ###
###############################

echo "Rebuilding ZIP with notarized app..."

# The ZIP contains more than just the app, so we need to rebuild it
cd .release
    rm -rf "AeroSpace-v$build_version"
    mkdir -p "AeroSpace-v$build_version"

    # Copy notarized app
    cp -r AeroSpace.app "AeroSpace-v$build_version/"

    # Copy CLI binary
    mkdir -p "AeroSpace-v$build_version/bin"
    cp aerospace "AeroSpace-v$build_version/bin/"

    # Copy documentation
    mkdir -p "AeroSpace-v$build_version/manpage"
    cp ../.man/*.1 "AeroSpace-v$build_version/manpage/" 2>/dev/null || true

    # Copy legal files
    cp -r ../legal "AeroSpace-v$build_version/legal" 2>/dev/null || true

    # Copy shell completion
    cp -r ../.shell-completion "AeroSpace-v$build_version/shell-completion" 2>/dev/null || true

    # Create new ZIP
    rm -f "AeroSpace-v$build_version.zip"
    zip -r "AeroSpace-v$build_version.zip" "AeroSpace-v$build_version"
cd -

echo "✓ ZIP updated with notarized app"
echo ""

###############################
### Summary                 ###
###############################

echo "========================================="
echo "Notarization Complete!"
echo "========================================="
echo ""
echo "Release artifacts:"
echo "  • DMG:  .release/AeroSpace-v$build_version.dmg (signed, notarized)"
echo "  • ZIP:  .release/AeroSpace-v$build_version.zip (notarized app included)"
echo ""
echo "The app is now ready for distribution!"
echo ""
