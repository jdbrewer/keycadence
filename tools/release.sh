#!/bin/zsh
# Builds a signed, notarized zip, and updates the Homebrew cask to match it.
# It publishes nothing: it ends by printing the commands that do.
#
#   tools/release.sh <version>             needs Developer ID and a notarytool profile
#   tools/release.sh <version> --dry-run   signs for this Mac only, skips notarizing,
#                                          and leaves the cask alone
#
# See docs/RELEASING.md.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

version=${1:-}
mode=${2:-}
profile=keycadence
team=7QL3988ZQY
cask=packaging/homebrew/keycadence.rb
derived=build/release
out=build/dist

[[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 "usage: tools/release.sh <x.y.z> [--dry-run]"; exit 2 }
[[ -z $mode || $mode == --dry-run ]] || { print -u2 "unknown option: $mode"; exit 2 }

if [[ $mode == --dry-run ]]; then
  identity="Apple Development"
else
  identity="Developer ID Application"
  [[ -z $(git status --porcelain) ]] || { print -u2 "Commit your changes first: a release has to match a commit."; exit 1 }
  security find-identity -v -p codesigning | grep -q "$identity" || {
    print -u2 "No $identity certificate on this Mac. See docs/RELEASING.md."; exit 1 }
  xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 || {
    print -u2 "No notarytool profile called '$profile'. See docs/RELEASING.md."; exit 1 }
fi

print "Testing the engine"
(cd Engine && swift test --quiet)

print "Building $version, signed with $identity"
rm -rf "$derived" "$out"
mkdir -p "$out"
xcodegen generate --quiet
log="$out/build.log"
if ! xcodebuild -project Keycadence.xcodeproj -scheme Keycadence -configuration Release \
    -derivedDataPath "$derived" -destination 'platform=macOS,arch=arm64' \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team" \
    PROVISIONING_PROFILE_SPECIFIER="" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)" \
    build >"$log" 2>&1; then
  grep -E "error:|BUILD FAILED" "$log" >&2 || tail -20 "$log" >&2
  exit 1
fi

app="$derived/Build/Products/Release/Keycadence.app"
zip="$out/Keycadence-$version.zip"

print "Checking the app"
codesign --verify --deep --strict "$app"
details=$(codesign -dvv "$app" 2>&1)
print -r -- "$details" | grep -q 'flags=.*runtime' || { print -u2 "Hardened runtime is off."; exit 1 }
print -r -- "$details" | grep -q '^Timestamp=' || { print -u2 "The signature has no secure timestamp."; exit 1 }
entitlements=$(codesign -d --entitlements - --xml "$app" 2>/dev/null)
for key in com.apple.security.get-task-allow com.apple.security.network.client com.apple.security.network.server; do
  if print -r -- "$entitlements" | grep -q "$key"; then print -u2 "Unexpected entitlement: $key"; exit 1; fi
done
print -r -- "$entitlements" | grep -q com.apple.security.app-sandbox || { print -u2 "The sandbox is off."; exit 1 }
built=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
[[ $built == $version ]] || { print -u2 "The app says version $built, not $version."; exit 1 }
if LC_ALL=C grep -a -q -F "$HOME" "$app/Contents/MacOS/Keycadence"; then
  print -u2 "The binary contains your home folder path."; exit 1
fi

if [[ $mode != --dry-run ]]; then
  print "Notarizing: this usually takes a few minutes"
  ditto -c -k --keepParent "$app" "$out/notarize.zip"
  xcrun notarytool submit "$out/notarize.zip" --keychain-profile "$profile" --wait
  rm "$out/notarize.zip"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=2 "$app"
fi

ditto -c -k --keepParent "$app" "$zip"
sum=$(shasum -a 256 "$zip" | cut -d' ' -f1)

if [[ $mode == --dry-run ]]; then
  print "\nDry run passed. $zip, sha256 $sum"
  print "This zip isn't notarized, so don't publish it. The cask wasn't changed."
  exit 0
fi

sed -i '' -E "s/^  version \".*\"/  version \"$version\"/; s/^  sha256 \".*\"/  sha256 \"$sum\"/" "$cask"

print "\nReady: $zip"
print "sha256: $sum"
print "\nTo publish, commit the updated cask, then:"
print "  git tag v$version && git push origin main v$version"
print "  gh release create v$version $zip --title \"Keycadence $version\" --generate-notes"
print "  cp $cask <your homebrew-tap checkout>/Casks/keycadence.rb"
print "Then commit and push the tap."
