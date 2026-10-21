#!/bin/bash
# Build, notarize and publish the work-computer copy of NetNewsList as a release on this repo.
# Usage: scripts/release-work-mac.sh [version]
#
# The version is the one given (1.4), or else the last release's with its last number raised by
# one (v1.4 → 1.5), or 1.0 for the first. It goes into xcconfig/common/NetNewsWire_version.xcconfig
# in a "Release <version>" commit, so About shows it in every build from then on, and the release
# is tagged v<version>. The release leaves the CloudKit API token out, since anyone can download it
# (the repository is public): the app asks for the token once on the work Mac and keeps it across
# updates. On the work Mac,
#   gh api repos/okbytes/NetNewsList/contents/scripts/install-work-mac.sh \
#     -H "Accept: application/vnd.github.raw" | bash
# installs it (scripts/install-work-mac.sh). Needs the netnewslist-notary notarytool profile.
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1
REPO="okbytes/NetNewsList"
NOTARY_PROFILE="${NOTARY_PROFILE:-netnewslist-notary}"
BUILT="build/Work.noindex"
VERSION_FILE="xcconfig/common/NetNewsWire_version.xcconfig"

fail() {
    echo "✗ $1" >&2
    exit 1
}

command -v gh >/dev/null || fail "Install the GitHub CLI (brew install gh), then run: gh auth login"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 ||
    fail "No notarytool profile named '$NOTARY_PROFILE' (TODO-Brett.md, section 2)."
[ -z "$(git status --porcelain)" ] || fail "Commit or discard local changes first."

git fetch -q --tags origin
latest="$(gh release view --repo "$REPO" --json tagName -q .tagName 2>/dev/null || echo none)"
last="$(git tag -l 'v[0-9]*' --sort=-v:refname | head -1)"
last="${last#v}"
if [ -n "${1:-}" ]; then
    VERSION="$1"
elif [ -n "$last" ]; then
    VERSION="${last%.*}.$((${last##*.} + 1))"
else
    VERSION="1.0"
fi
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)+$ ]] || fail "Give the version as numbers with a dot, like 1.4."
TAG="v$VERSION"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    fail "$TAG already exists; pass another version."
fi
ZIP="$BUILT/NetNewsList-Work-$VERSION.zip"

if ! grep -qx "MARKETING_VERSION = $VERSION" "$VERSION_FILE"; then
    sed -i '' "s/^MARKETING_VERSION = .*/MARKETING_VERSION = $VERSION/" "$VERSION_FILE"
    git commit -q -m "Release $VERSION" -- "$VERSION_FILE"
fi

scripts/build-work-mac.sh --no-token

# The checks the release depends on, on the app as it ships.
CHECK="$(mktemp -d)"
trap 'rm -rf "$CHECK"' EXIT
ditto -x -k "$BUILT/NetNewsList-Work.zip" "$CHECK"
token="$(/usr/libexec/PlistBuddy -c 'Print :CloudKitAPIToken' "$CHECK/NetNewsList.app/Contents/Info.plist" 2>/dev/null || true)"
[ -z "$token" ] || fail "The build has an API token in it; a public release mustn't."
built_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CHECK/NetNewsList.app/Contents/Info.plist")"
[ "$built_version" = "$VERSION" ] || fail "The build says it's version $built_version, not $VERSION."
spctl --assess --type execute "$CHECK/NetNewsList.app" || fail "Gatekeeper rejects the build: it isn't notarized."
cp "$BUILT/NetNewsList-Work.zip" "$ZIP"

echo "▸ Publishing NetNewsList ${VERSION}…"
git push -q origin HEAD
git tag -a "$TAG" -m "NetNewsList $VERSION for the work computer"
git push -q origin "$TAG"
if [ "$latest" = none ]; then
    notes="First release of the work-computer copy."
else
    notes="$(git log --format='- %s' --invert-grep --grep='^Release [0-9]' "$latest..$TAG")"
fi
gh release create "$TAG" "$ZIP" --repo "$REPO" --title "NetNewsList $VERSION for the work computer" --notes "$notes" --latest
echo "✓ NetNewsList $VERSION is released as $TAG; on the work Mac, scripts/install-work-mac.sh installs it"
