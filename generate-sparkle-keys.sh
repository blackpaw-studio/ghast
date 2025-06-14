#!/bin/bash

echo "Generating EdDSA keys for Sparkle..."
echo "This script will generate keys using Sparkle's generate_keys tool."
echo ""

# Check if Sparkle is available in the build directory
SPARKLE_BIN_PATH=".build/artifacts/sparkle/Sparkle/bin"

if [ ! -d "$SPARKLE_BIN_PATH" ]; then
    echo "Sparkle binary tools not found."
    echo "Please run 'xcodegen' and build the project first."
    echo "The Sparkle package will be downloaded and its tools will be available."
    exit 1
fi

# Run the key generation tool
if [ -f "$SPARKLE_BIN_PATH/generate_keys" ]; then
    "$SPARKLE_BIN_PATH/generate_keys"
else
    echo "generate_keys tool not found at $SPARKLE_BIN_PATH"
    echo "Looking for alternative location..."
    
    # Try to find it in DerivedData
    DERIVED_DATA_PATH="$HOME/Library/Developer/Xcode/DerivedData"
    GENERATE_KEYS=$(find "$DERIVED_DATA_PATH" -name "generate_keys" -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin/*" 2>/dev/null | head -n 1)
    
    if [ -n "$GENERATE_KEYS" ]; then
        echo "Found at: $GENERATE_KEYS"
        "$GENERATE_KEYS"
    else
        echo "Could not find generate_keys tool."
        echo "After building the project, you can find it in the Sparkle package artifacts."
    fi
fi

echo ""
echo "Once you have the keys:"
echo "1. Add the public key (SUPublicEDKey) to your Info.plist"
echo "2. Keep the private key secure - you'll use it to sign updates"
echo "3. Use sign_update tool to sign your app updates"