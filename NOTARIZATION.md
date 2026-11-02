# Notarization Guide for Ghast

This guide explains how to notarize Ghast for distribution outside the Mac App Store.

## Prerequisites

1. **Apple Developer Account** (paid - $99/year)
2. **Xcode** installed and configured
3. **App Store Connect API key** (.p8, Key ID, Issuer ID) for team 52M9C6892K
4. **Code signing certificate** (automatically managed)

## Initial Setup

### 1. Get the App Store Connect API Key

Use the key in 1Password (Blackpaw Studio / "App Store Connect Blackpaw Studio Admin"):
the `AuthKey_*.p8` attachment, `key id`, and `issuer id`. It must belong to the same
team as the Developer ID certificate (52M9C6892K).

### 2. Store Notarization Credentials

Run the setup script:

```bash
./setup-notarization.sh
```

This will prompt you for:
- Path to the `.p8` key
- Key ID
- Issuer ID

## Manual Notarization

To notarize a build manually:

```bash
./notarize.sh
```

This script will:
1. Generate the Xcode project
2. Build and archive the app
3. Export with Developer ID signing
4. Create a ZIP for notarization
5. Submit to Apple for notarization
6. Wait for approval (usually 5-10 minutes)
7. Staple the notarization ticket
8. Create a final distribution ZIP

### Script Options

- `--skip-build`: Skip building if you already have an archive
- `--notarize-only`: Only notarize an existing ZIP

## Automated Notarization (GitHub Actions)

The repository includes a GitHub Actions workflow that automatically notarizes releases.

### Setup GitHub Secrets

Add these secrets to your repository:
- `APPLE_NOTARIZATION_KEY`: contents of the App Store Connect API `.p8` (written to a temp file for `notarytool --key`)
- `APPLE_NOTARIZATION_KEY_ID`: its Key ID
- `APPLE_NOTARIZATION_ISSUER`: its Issuer ID
- `MACOS_CERTIFICATE`: base64 Developer ID Application .p12 (imported into a per-job temp keychain by `.github/scripts/keychain.sh`, deleted at job end)
- `MACOS_CERTIFICATE_PWD`: password for that .p12
- `APPLE_TEAM_ID`: Your team ID (52M9C6892K)
- `SPARKLE_PRIVATE_KEY`: **Required.** Sparkle EdDSA private key (1Password: Olympus / "Ghast Sparkle EdDSA Private Key"). The workflow fails without it.

The workflow runs on `macos-26` with Xcode 26.6. The appcast is hosted manually at https://evancoleman.net/ghast/appcast.xml: after a release, paste the `sparkle:edSignature`/`length` from the release notes into the appcast item and upload it.

### Triggering a Release

1. Create and push a version tag:
   ```bash
   git tag v1.0.1
   git push origin v1.0.1
   ```

2. The workflow will automatically:
   - Build and notarize the app
   - Create a draft GitHub release
   - Attach the notarized ZIP
   - Include the Sparkle signature

## Verification

To verify a notarized app:

```bash
# Check notarization status
spctl -a -vvv -t install path/to/Ghast.app

# Check code signature
codesign -vvv --deep --strict path/to/Ghast.app

# Verify entitlements
codesign -d --entitlements - path/to/Ghast.app
```

## Troubleshooting

### Common Issues

1. **"Unable to validate your application"**
   - Ensure all frameworks and bundles are signed
   - Check for unsigned binaries in the app bundle

2. **"The signature is invalid"**
   - Make sure you're using Developer ID certificate
   - Check that hardened runtime is enabled

3. **Notarization fails**
   - Check the log file in build/notarization-log.json
   - Common issues: unsigned binaries, missing entitlements

### Checking Notarization History

```bash
xcrun notarytool history --keychain-profile ghast-notarization
```

### Getting Detailed Logs

```bash
xcrun notarytool log SUBMISSION_ID --keychain-profile ghast-notarization log.json
```

## Best Practices

1. **Always test locally** before pushing a release tag
2. **Verify the notarized app** on a clean machine
3. **Keep credentials secure** - never commit them
4. **Update version numbers** in project.yml before releasing
5. **Sign all embedded binaries** including GitHub Actions runners

## Distribution

After notarization, you can distribute your app via:
- Direct download from your website
- GitHub Releases
- Sparkle updates (auto-updates)
- Third-party distribution platforms

The notarized app will run on any Mac without Gatekeeper warnings.