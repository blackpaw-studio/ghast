# Ghast

A native macOS app for managing GitHub Actions self-hosted runners with a delightful ghost-themed interface.

![Ghast App Icon](Ghast/Assets.xcassets/AppIcon.appiconset/icon_128x128.png)

## Features

- **GitHub Device Flow Sign-in**: Approve Ghast with a one-time code in your browser; no secrets ship in the app and the token is stored in the macOS Keychain
- **Repository Management**: Browse and manage your GitHub repositories
- **Self-Hosted Runners**: 
  - View existing runners for any repository
  - Create new self-hosted runners with guided setup
  - Start/stop local runners directly from the app
  - Real-time log streaming from running instances
- **Native macOS Experience**: Built with SwiftUI for a modern, responsive interface

## Installation

### Requirements
- macOS 26.0 or later
- GitHub account with repository access
- GitHub Actions enabled on your repositories

### Download
1. Download the latest release from the [Releases](https://github.com/yourusername/ghast/releases) page
2. Move Ghast.app to your Applications folder
3. Launch Ghast from Applications or Spotlight

### Building from Source
```bash
# Clone the repository
git clone https://github.com/yourusername/ghast.git
cd ghast

# Generate Xcode project
xcodegen

# Build the app
xcodebuild -project Ghast.xcodeproj -scheme Ghast build

# Or open in Xcode
open Ghast.xcodeproj
```

## Getting Started

1. **Launch Ghast** and click "Sign in with GitHub"
2. **Approve Ghast on GitHub**: the app shows a one-time code, copies it, and opens github.com/login/device; paste the code and authorize
3. **Create a runner**: click New Runner (the + in the toolbar), pick a repository or organization, name it and set labels; Ghast downloads, registers and starts it
4. **Manage it** from the sidebar: Start, Stop and Restart from the toolbar, live output on the Output tab, labels, folder and environment on the Configuration tab

## Managing Runners

### Viewing Runner Logs
- Click on any running runner to view real-time logs
- Logs automatically scroll to show the latest output
- Use the search function to find specific log entries

## Security

- GitHub OAuth tokens are stored securely in the macOS Keychain
- The app never stores your GitHub password
- All API communications use HTTPS
- Local runner credentials remain on your machine

## Troubleshooting

### Authentication Issues
- Check Console.app for OAuth debug logs (search for "🔐 OAuth:")
- Ensure you're using the latest version of Ghast
- Try signing out and back in

### Runner Connection Problems
- Verify the runner directory contains `run.sh`
- Check that you have execution permissions on runner scripts
- Ensure no other instance of the runner is already running

### App Won't Launch
- Verify you're running macOS 26.0 or later
- Check if Gatekeeper is blocking the app (System Preferences > Security & Privacy)
- Try removing the app from quarantine: `xattr -d com.apple.quarantine /Applications/Ghast.app`

## Development

### Architecture
- **SwiftUI + Combine**: Modern reactive UI architecture
- **XcodeGen**: Project generation from YAML configuration
- **GitHub REST API**: Repository and runner management
- **Process Management**: Local runner lifecycle control

### Testing
```bash
# Run all tests
xcodebuild test -project Ghast.xcodeproj -scheme Ghast

# Run snapshot tests (for UI verification)
# Set isRecording = true in test files to record new snapshots
```

### Contributing
1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m '✨ Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

Copyright © 2024 Blackpaw Studio, LLC. All rights reserved.

## Acknowledgments

- Built with [Alamofire](https://github.com/Alamofire/Alamofire) for networking
- [KeychainAccess](https://github.com/kishikawakatsumi/KeychainAccess) for secure token storage
- [SnapshotTesting](https://github.com/pointfreeco/swift-snapshot-testing) for UI testing