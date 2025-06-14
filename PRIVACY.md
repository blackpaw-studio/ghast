# Privacy Policy for Ghast

*Last updated: January 2025*

## Overview

Ghast ("we", "our", or "the app") is committed to protecting your privacy. This privacy policy explains how we handle your information when you use our macOS application for managing GitHub Actions runners.

## Information We Collect

### GitHub Authentication
- **OAuth Token**: When you sign in with GitHub, we receive an OAuth token that is stored securely in your macOS Keychain
- **GitHub Username**: Retrieved from GitHub's API to personalize your experience
- **Email Address**: Retrieved from GitHub's API if publicly available in your profile

### Repository Information
- **Repository Names and Metadata**: Accessed through GitHub's API to display your repositories
- **Runner Information**: Configuration and status of GitHub Actions runners

### Local Information
- **Runner Directories**: File paths to GitHub Actions runner installations on your Mac
- **Runner Logs**: Output from runner processes stored temporarily in memory during execution

## How We Use Your Information

We use the collected information solely to:
- Authenticate you with GitHub
- Display your repositories and runners
- Manage local GitHub Actions runners on your behalf
- Provide real-time runner status and logs

## Data Storage

### Local Storage Only
- All data is stored locally on your Mac
- OAuth tokens are secured in the macOS Keychain
- Runner configurations are stored in UserDefaults
- No data is transmitted to any servers owned or operated by Ghast

### Third-Party Services
- **GitHub API**: We communicate directly with GitHub's API using your OAuth token
- All communications with GitHub use HTTPS encryption
- We do not share your data with any other third parties

## Data Security

- OAuth tokens are stored using macOS Keychain Services with hardware encryption
- The app uses App Transport Security for all network communications
- Local runner processes are managed with appropriate file system permissions

## Your Rights

You can:
- **Access Your Data**: All data is stored locally and accessible through the app
- **Delete Your Data**: Sign out of the app to remove your OAuth token, or delete the app to remove all data
- **Revoke Access**: Revoke Ghast's access through your GitHub account settings

## Analytics and Tracking

Ghast does not:
- Collect analytics data
- Track your usage patterns
- Send crash reports to external servers
- Use any third-party analytics services

## Children's Privacy

Ghast is not intended for use by anyone under the age of 13. We do not knowingly collect information from children under 13.

## Changes to This Policy

We may update this privacy policy from time to time. Changes will be noted with an updated revision date at the top of this policy.

## Contact

For questions about this privacy policy or Ghast's privacy practices, please create an issue on our GitHub repository.

## Compliance

This app complies with:
- Apple's App Store Review Guidelines
- GitHub's API Terms of Service
- Applicable data protection regulations