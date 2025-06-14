#!/bin/bash

# Notarization script for Ghast
# This script builds, archives, exports, and notarizes the app

set -e

# Configuration
APP_NAME="Ghast"
BUNDLE_ID="net.evancoleman.ghast"
TEAM_ID="52M9C6892K"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_step() {
    echo -e "${BLUE}==>${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

# Check if running on macOS
if [[ "$OSTYPE" != "darwin"* ]]; then
    print_error "This script must be run on macOS"
    exit 1
fi

# Check for required tools
if ! command -v jq &> /dev/null; then
    print_error "jq is required but not installed"
    echo "Install with: brew install jq"
    exit 1
fi

# Parse command line arguments
NOTARIZE_ONLY=false
SKIP_BUILD=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --notarize-only)
            NOTARIZE_ONLY=true
            shift
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--notarize-only] [--skip-build]"
            exit 1
            ;;
    esac
done

# Create build directory
BUILD_DIR="build"
mkdir -p "$BUILD_DIR"

# Step 1: Generate Xcode project
if [ "$SKIP_BUILD" != true ]; then
    print_step "Generating Xcode project..."
    xcodegen
    print_success "Project generated"
fi

# Step 2: Build and Archive
if [ "$SKIP_BUILD" != true ]; then
    print_step "Building and archiving..."
    
    ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
    
    xcodebuild archive \
        -project "$APP_NAME.xcodeproj" \
        -scheme "$APP_NAME" \
        -configuration Release \
        -archivePath "$ARCHIVE_PATH" \
        -quiet \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        CODE_SIGN_STYLE="Automatic"
    
    print_success "Archive created at $ARCHIVE_PATH"
fi

# Step 3: Export Archive
if [ "$SKIP_BUILD" != true ]; then
    print_step "Exporting archive..."
    
    EXPORT_PATH="$BUILD_DIR/export"
    
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_PATH" \
        -exportOptionsPlist "ExportOptions.plist" \
        -quiet
    
    print_success "App exported to $EXPORT_PATH"
fi

# Step 4: Create DMG or ZIP for notarization
print_step "Creating ZIP for notarization..."

APP_PATH="$BUILD_DIR/export/$APP_NAME.app"
ZIP_PATH="$BUILD_DIR/$APP_NAME.zip"

# Remove old zip if exists
rm -f "$ZIP_PATH"

# Create zip with proper structure
cd "$BUILD_DIR/export"
zip -r -y "../$APP_NAME.zip" "$APP_NAME.app"
cd ../..

print_success "ZIP created at $ZIP_PATH"

# Step 5: Notarize
print_step "Submitting for notarization..."

# Check for notarytool credentials
if ! xcrun notarytool store-credentials --list 2>/dev/null | grep -q "ghast-notarization"; then
    print_error "Notarization credentials not found!"
    echo ""
    echo "Please run the following command to store your credentials:"
    echo "xcrun notarytool store-credentials ghast-notarization --apple-id YOUR_APPLE_ID --team-id $TEAM_ID"
    echo ""
    echo "You'll need:"
    echo "1. Your Apple ID email"
    echo "2. An app-specific password from https://appleid.apple.com"
    echo "3. Your team ID: $TEAM_ID"
    exit 1
fi

# Submit for notarization
SUBMISSION_ID=$(xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "ghast-notarization" \
    --wait \
    --timeout 30m \
    --output-format json | jq -r '.id')

if [ -z "$SUBMISSION_ID" ]; then
    print_error "Failed to get submission ID"
    exit 1
fi

print_success "Notarization submission ID: $SUBMISSION_ID"

# Check notarization status
print_step "Checking notarization status..."

STATUS_RESPONSE=$(xcrun notarytool info "$SUBMISSION_ID" \
    --keychain-profile "ghast-notarization" \
    --output-format json)

STATUS=$(echo "$STATUS_RESPONSE" | jq -r '.status')

if [ "$STATUS" == "Accepted" ]; then
    print_success "Notarization successful!"
else
    print_error "Notarization failed with status: $STATUS"
    
    # Get the log
    print_step "Fetching notarization log..."
    xcrun notarytool log "$SUBMISSION_ID" \
        --keychain-profile "ghast-notarization" \
        "$BUILD_DIR/notarization-log.json"
    
    echo "Check $BUILD_DIR/notarization-log.json for details"
    exit 1
fi

# Step 6: Staple the notarization ticket
print_step "Stapling notarization ticket..."

xcrun stapler staple "$APP_PATH"
print_success "Notarization ticket stapled"

# Step 7: Create final distribution ZIP
print_step "Creating final distribution ZIP..."

DIST_ZIP="$BUILD_DIR/$APP_NAME-notarized.zip"
rm -f "$DIST_ZIP"

cd "$BUILD_DIR/export"
zip -r -y "../$APP_NAME-notarized.zip" "$APP_NAME.app"
cd ../..

print_success "Distribution ZIP created at $DIST_ZIP"

# Step 8: Verify the notarization
print_step "Verifying notarization..."

spctl -a -vvv -t install "$APP_PATH"
print_success "Notarization verified"

# Final summary
echo ""
print_success "Notarization complete!"
echo ""
echo "Distribution files:"
echo "  - App: $APP_PATH"
echo "  - ZIP: $DIST_ZIP"
echo ""
echo "The app is now ready for distribution!"

# Optional: Sign the ZIP for Sparkle updates
if [ -f "sparkle_private_key" ]; then
    print_step "Signing update for Sparkle..."
    
    # Find sign_update tool
    SIGN_UPDATE=$(find ~/Library/Developer/Xcode/DerivedData -name "sign_update" -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin/*" 2>/dev/null | head -n 1)
    
    if [ -n "$SIGN_UPDATE" ] && [ -f "$SIGN_UPDATE" ]; then
        SIGNATURE=$("$SIGN_UPDATE" "$DIST_ZIP" -f sparkle_private_key)
        echo ""
        echo "Sparkle EdDSA signature:"
        echo "$SIGNATURE"
        echo ""
        echo "Add this to your appcast.xml"
    else
        echo "sign_update tool not found. Build the project first to download Sparkle."
    fi
fi