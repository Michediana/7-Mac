#!/bin/sh
#
# Build a release the way Sparkle will receive it: archive, sign with
# Developer ID, notarize, staple, zip, and write a signed appcast.xml that
# points at the zip on the GitHub release.
#
#     Scripts/release.sh <version> [--publish]
#
#     Scripts/release.sh 1.1             # build/release/1.1/{7-Mac-1.1.zip,appcast.xml}
#     Scripts/release.sh 1.1 --publish   # ...and create the GitHub release v1.1
#
# The build number is the commit count on HEAD, so it only ever grows and the
# same commit always gets the same one. Sparkle compares that, not <version>.
#
# Notarization credentials, one of:
#   NOTARY_PROFILE      a keychain profile from `xcrun notarytool store-credentials`
#                       (default "7-Mac", the local route)
#   NOTARY_KEY_PATH     an App Store Connect API key (.p8), with
#   NOTARY_KEY_ID       NOTARY_KEY_ID and NOTARY_ISSUER_ID (the CI route; the same
#   NOTARY_ISSUER_ID    key also lets Xcode fetch Developer ID profiles)
#
# Sparkle keys:
#   SPARKLE_PUBLIC_ED_KEY   default: read from the login keychain by generate_keys -p
#   SPARKLE_PRIVATE_KEY     default: the login keychain, where generate_keys left it
#
set -eu

VERSION=${1:?usage: Scripts/release.sh <version> [--publish]}
PUBLISH=${2:-}
VERSION=${VERSION#v}
TAG="v$VERSION"
REPO=Michediana/7-Mac
TEAM_ID=ALUYQV47T2

REPO_ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
OUT="$REPO_ROOT/build/release/$VERSION"
SPM="$REPO_ROOT/build/spm"
SPARKLE_BIN="$SPM/artifacts/sparkle/Sparkle/bin"
BUILD=$(git -C "$REPO_ROOT" rev-list --count HEAD)

if [ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]; then
    printf 'warning: the working tree has uncommitted changes; build %s will not match its commit\n' "$BUILD" >&2
fi

rm -rf "$OUT"
mkdir -p "$OUT"
LOG="$OUT/build.log"
step() { printf '==> %s\n' "$1"; }
fail() { tail -40 "$LOG" >&2; printf 'failed; full log at %s\n' "$LOG" >&2; exit 1; }

# Xcode signs, and fetches the Developer ID profiles the app group needs,
# with the API key when there is one, else with the account in Xcode.
AUTH=""
if [ -n "${NOTARY_KEY_PATH:-}" ]; then
    AUTH="-authenticationKeyPath $NOTARY_KEY_PATH -authenticationKeyID $NOTARY_KEY_ID -authenticationKeyIssuerID $NOTARY_ISSUER_ID"
fi

step "resolving packages"
# shellcheck disable=SC2086
xcodebuild -resolvePackageDependencies -project "$REPO_ROOT/7-Mac.xcodeproj" -scheme 7-Mac \
           -clonedSourcePackagesDirPath "$SPM" >"$LOG" 2>&1 || fail

if [ -z "${SPARKLE_PUBLIC_ED_KEY:-}" ]; then
    SPARKLE_PUBLIC_ED_KEY=$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null) || {
        printf 'no Sparkle key: run %s/generate_keys once, or set SPARKLE_PUBLIC_ED_KEY\n' "$SPARKLE_BIN" >&2
        exit 1
    }
fi

step "archiving $VERSION ($BUILD)"
# The public key goes in here rather than in the project, so that builds from
# source and Debug builds -- always build 1 -- never offer an update.
# shellcheck disable=SC2086
xcodebuild archive -project "$REPO_ROOT/7-Mac.xcodeproj" -scheme 7-Mac -configuration Release \
           -destination 'generic/platform=macOS' \
           -archivePath "$OUT/7-Mac.xcarchive" \
           -clonedSourcePackagesDirPath "$SPM" \
           -allowProvisioningUpdates $AUTH \
           MARKETING_VERSION="$VERSION" \
           CURRENT_PROJECT_VERSION="$BUILD" \
           SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" >>"$LOG" 2>&1 || fail

step "exporting with Developer ID"
cat >"$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
</dict>
</plist>
EOF
# shellcheck disable=SC2086
xcodebuild -exportArchive -archivePath "$OUT/7-Mac.xcarchive" \
           -exportOptionsPlist "$OUT/ExportOptions.plist" \
           -exportPath "$OUT/export" \
           -allowProvisioningUpdates $AUTH >>"$LOG" 2>&1 || fail
APP="$OUT/export/7-Mac.app"

step "notarizing"
ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
if [ -n "${NOTARY_KEY_PATH:-}" ]; then
    set -- --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"
else
    set -- --keychain-profile "${NOTARY_PROFILE:-7-Mac}"
fi
xcrun notarytool submit "$OUT/notarize.zip" "$@" --wait --timeout 30m | tee -a "$LOG"
grep -q 'status: Accepted' "$LOG" || { printf 'notarization was not accepted\n' >&2; exit 1; }
xcrun stapler staple "$APP" >>"$LOG" 2>&1 || fail
spctl --assess --type execute "$APP" || { printf 'Gatekeeper rejects the app\n' >&2; exit 1; }

step "packaging"
ZIP="7-Mac-$VERSION.zip"
mkdir "$OUT/appcast"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/appcast/$ZIP"

# One item only: the feed lives at releases/latest/download/appcast.xml, so
# each release replaces it, and an old copy has nothing to offer.
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    set -- --ed-key-file -
else
    set --
fi
printf '%s' "${SPARKLE_PRIVATE_KEY:-}" | "$SPARKLE_BIN/generate_appcast" "$@" \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    --full-release-notes-url "https://github.com/$REPO/releases/tag/$TAG" \
    --link "https://github.com/$REPO" \
    "$OUT/appcast" >>"$LOG" 2>&1 || fail
grep -q 'sparkle:edSignature' "$OUT/appcast/appcast.xml" || { printf 'the appcast is not signed\n' >&2; exit 1; }

mv "$OUT/appcast/$ZIP" "$OUT/appcast/appcast.xml" "$OUT/"
rm -rf "$OUT/appcast" "$OUT/notarize.zip"
printf '\n%s\n%s\n' "$OUT/$ZIP" "$OUT/appcast.xml"

if [ "$PUBLISH" = "--publish" ]; then
    step "publishing $TAG"
    gh release create "$TAG" "$OUT/$ZIP" "$OUT/appcast.xml" \
       --repo "$REPO" --title "7-Mac $VERSION" --generate-notes --verify-tag
fi
