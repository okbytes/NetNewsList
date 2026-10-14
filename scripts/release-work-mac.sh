#!/bin/bash
# Build, notarize and publish the work-computer copy of NetNewsList as a release on this repo.
# Usage: scripts/release-work-mac.sh
#
# The release leaves the CloudKit API token out, since anyone can download it (the repository is
# public): the app asks for the token once on the work Mac and keeps it across updates. It's tagged
# work-<date> (work-<date>.2 and so on for more that day) at HEAD. On the work Mac,
#   gh api repos/okbytes/NetNewsList/contents/scripts/install-work-mac.sh \
#     -H "Accept: application/vnd.github.raw" | bash
# installs it (scripts/install-work-mac.sh). Needs the netnewslist-notary notarytool profile.
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1
REPO="okbytes/NetNewsList"
NOTARY_PROFILE="${NOTARY_PROFILE:-netnewslist-notary}"
BUILT="build/Work.noindex"

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
DATE="$(date +%Y-%m-%d)"
TAG="work-$DATE"
n=2
while git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; do
    TAG="work-$DATE.$n"
    n=$((n + 1))
done
ZIP="$BUILT/NetNewsList-Work-${TAG#work-}.zip"

scripts/build-work-mac.sh --no-token

# The checks the release depends on, on the app as it ships.
CHECK="$(mktemp -d)"
trap 'rm -rf "$CHECK"' EXIT
ditto -x -k "$BUILT/NetNewsList-Work.zip" "$CHECK"
token="$(/usr/libexec/PlistBuddy -c 'Print :CloudKitAPIToken' "$CHECK/NetNewsList.app/Contents/Info.plist" 2>/dev/null || true)"
[ -z "$token" ] || fail "The build has an API token in it; a public release mustn't."
spctl --assess --type execute "$CHECK/NetNewsList.app" || fail "Gatekeeper rejects the build: it isn't notarized."
cp "$BUILT/NetNewsList-Work.zip" "$ZIP"

echo "▸ Publishing ${TAG}…"
git tag -a "$TAG" -m "NetNewsList for the work computer, $TAG"
git push -q origin "$TAG"
if [ "$latest" = none ]; then
    notes="First release of the work-computer copy."
else
    notes="$(git log --format='- %s' "$latest..$TAG")"
fi
gh release create "$TAG" "$ZIP" --repo "$REPO" --title "NetNewsList for the work computer, $TAG" --notes "$notes" --latest
echo "✓ $TAG is released; on the work Mac, scripts/install-work-mac.sh installs it"
