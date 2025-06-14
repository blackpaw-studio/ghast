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
echo "2. An app-specific password from https://appleid.apple.com"
echo "   (Sign in → Security → App-Specific Passwords → Generate)"
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

# Get Apple ID
echo -e "${BLUE}Enter your Apple ID email:${NC}"
read -r APPLE_ID

# Store credentials
echo ""
echo -e "${BLUE}Setting up notarization credentials...${NC}"
echo "You will be prompted for your app-specific password."
echo ""

xcrun notarytool store-credentials "$PROFILE_NAME" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID"

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