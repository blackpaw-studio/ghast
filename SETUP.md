# Developer Setup

## OAuth Configuration

Ghast requires GitHub OAuth credentials to authenticate users. For security reasons, these credentials are not included in the source code.

### Setting Up Development Environment

1. **Create a GitHub OAuth App**:
   - Go to https://github.com/settings/developers
   - Click "New OAuth App"
   - Fill in the details:
     - Application name: `Ghast (Development)`
     - Homepage URL: `https://github.com/yourusername/ghast`
     - Authorization callback URL: `ghast://auth/callback`
   - Click "Register application"

2. **Set Environment Variables**:
   ```bash
   export GHAST_GITHUB_CLIENT_ID="your_client_id_here"
   export GHAST_GITHUB_CLIENT_SECRET="your_client_secret_here"
   ```

   Or create a `.env` file (not tracked by git):
   ```
   GHAST_GITHUB_CLIENT_ID=your_client_id_here
   GHAST_GITHUB_CLIENT_SECRET=your_client_secret_here
   ```

3. **Run the app**:
   ```bash
   # Generate Xcode project
   xcodegen
   
   # Build and run
   xcodebuild -project Ghast.xcodeproj -scheme Ghast build
   ```

### Production Configuration

For production releases, we recommend:

1. **Using GitHub Device Flow**: This eliminates the need for client secrets in the app
2. **Using a Proxy Server**: Keep the client secret on a secure server and proxy token requests
3. **Never embed client secrets**: Client secrets should never be included in the distributed app

### Security Notes

- The `GHAST_GITHUB_CLIENT_ID` and `GHAST_GITHUB_CLIENT_SECRET` environment variables are only for development
- Never commit `.env` files or any file containing OAuth credentials
- Rotate credentials immediately if they are accidentally exposed
- Consider implementing device flow for production releases to eliminate client secret requirements