# Releasing

A release is a notarized zip on GitHub, plus a Homebrew cask that points to it.

## One-time setup

1. **Developer ID certificate.** In Xcode, go to Settings > Accounts > Manage Certificates,
   click +, and choose Developer ID Application.
2. **App-specific password.** Create one at [account.apple.com](https://account.apple.com),
   under Sign-In and Security.
3. **Save it for the notary tool.** This prompts for the password and keeps it in your keychain:

   ```bash
   xcrun notarytool store-credentials keycadence --apple-id YOUR_APPLE_ID --team-id 7QL3988ZQY
   ```

4. **Homebrew tap.** Create a public repo called `homebrew-tap`, with a `Casks` folder.

## Each release

1. Run the release script. It tests the engine, builds, checks the signature and
   entitlements, notarizes, staples, and updates `packaging/homebrew/keycadence.rb`:

   ```bash
   tools/release.sh 1.0.0
   ```

2. Commit the updated cask, then run the publish commands the script prints. They tag the
   commit, create the GitHub release, and copy the cask to your tap.
3. Test it the way a new user would, ideally on another Mac:

   ```bash
   brew install --cask jdbrewer/tap/keycadence
   ```

To check everything except notarization, without a Developer ID certificate:

```bash
tools/release.sh 1.0.0 --dry-run
```

## Things to know

- **Apple silicon only.** The build and the cask are arm64, because the app hasn't been
  tested on Intel. To add Intel, test it there first, then remove `arch=arm64` and
  `ONLY_ACTIVE_ARCH` from the script and `depends_on arch` from the cask.
- **Updates.** The app has no network access, so it can't update itself. People update with
  `brew upgrade`, or by downloading the new zip.
- **The bundle ID stays the same.** Changing `com.notebrewer.keycadence` would make macOS ask
  for Input Monitoring again and would leave people's settings behind.
