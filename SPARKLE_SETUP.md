# Sparkle Update Framework Setup

This document describes how to set up and use Sparkle for automatic updates in Ghast.

## Initial Setup

1. **Generate EdDSA Keys**
   ```bash
   # After building the project once, run:
   ./generate-sparkle-keys.sh
   ```
   This will generate a public/private key pair. Keep the private key secure!

2. **Update Info.plist**
   Replace `YOUR_PUBLIC_KEY_HERE` in `project.yml` with your actual public key.

3. **Set Up Your Update Server**
   - Host the `appcast.xml` file at: https://evancoleman.net/ghast/appcast.xml
   - Use `appcast-template.xml` as a starting point

## Creating Updates

1. **Build and Archive Your App**
   ```bash
   xcodegen
   xcodebuild -project Ghast.xcodeproj -scheme Ghast -configuration Release archive
   ```

2. **Create a ZIP Archive**
   ```bash
   cd /path/to/Ghast.app/..
   zip -r Ghast-1.0.1.zip Ghast.app
   ```

3. **Sign the Update**
   ```bash
   # Find sign_update in the Sparkle artifacts after building
   ./sign_update Ghast-1.0.1.zip -s YOUR_PRIVATE_KEY
   ```

4. **Update appcast.xml**
   - Update version numbers
   - Add the EdDSA signature from step 3
   - Update file size and download URL
   - Add release notes

5. **Upload Files**
   - Upload the signed ZIP file
   - Upload the updated appcast.xml
   - Upload release notes HTML file

## Testing Updates

1. Build an older version of the app
2. Run it and check for updates
3. Verify the update process works correctly

## Security Notes

- Never commit your private key
- Use HTTPS for all update URLs
- Sign all updates with your EdDSA key
- Consider using CloudFront or similar CDN for distribution