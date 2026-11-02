#!/bin/bash

# Script to set up notarization credentials for Ghast

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
TEAM_ID="52M9C6892K"
PROFILE_NAME="ghast-notarization"

echo -e "${BLUE}Ghast Notarization Setup${NC}"
echo "========================="
echo ""
echo "This script will help you set up notarization credentials."
echo ""
echo -e "${YELLOW}Prerequisites:${NC}"
echo "1. An Apple Developer account"
echo "2. An App Store Connect API key (.p8) for team $TEAM_ID, plus its Key ID and Issuer ID"
echo "   (1Password: Blackpaw Studio / App Store Connect Blackpaw Studio Admin)"
echo ""
echo "Press Enter to continue..."
read

# Check if credentials already exist
if xcrun notarytool store-credentials --list 2>/dev/null | grep -q "$PROFILE_NAME"; then
    echo -e "${YELLOW}Warning:${NC} Credentials '$PROFILE_NAME' already exist."
    echo "Do you want to overwrite them? (y/N)"
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo "Setup cancelled."
        exit 0
    fi
fi

# Get API key details
echo -e "${BLUE}Path to the AuthKey_XXXX.p8 file:${NC}"
read -r KEY_PATH
echo -e "${BLUE}Key ID:${NC}"
read -r KEY_ID
echo -e "${BLUE}Issuer ID:${NC}"
read -r ISSUER_ID

# Store credentials
echo ""
echo -e "${BLUE}Setting up notarization credentials...${NC}"

xcrun notarytool store-credentials "$PROFILE_NAME" \
    --key "$KEY_PATH" \
    --key-id "$KEY_ID" \
    --issuer "$ISSUER_ID"

# Verify credentials
echo ""
echo -e "${BLUE}Verifying credentials...${NC}"

if xcrun notarytool store-credentials --list 2>/dev/null | grep -q "$PROFILE_NAME"; then
    echo -e "${GREEN}✓${NC} Credentials stored successfully!"
    echo ""
    echo "You can now use the notarize.sh script to notarize your app."
else
    echo -e "${RED}✗${NC} Failed to store credentials"
    exit 1
fi