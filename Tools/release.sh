#!/bin/bash
# Build, sign, notarize, and publish an IndieLicense release from the maintainer's Mac.
# The Developer ID private key never leaves the local Keychain.
set -euo pipefail

VERSION="${1:-}"
TEAM_ID="4UPMHT6AFG"
NOTARY_PROFILE="indielicense-notary"
REPO="tarasowski/indielicence"
TAP_REPO="tarasowski/homebrew-tap"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: Tools/release.sh <major.minor.patch>" >&2
  exit 2
fi

TAG="v$VERSION"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

for command in swift node git gh codesign security xcrun ditto shasum; do
  command -v "$command" >/dev/null || { echo "missing required command: $command" >&2; exit 1; }
done

[[ $(git branch --show-current) == main ]] || { echo "release must run from main" >&2; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "working tree must be clean" >&2; exit 1; }
git fetch --quiet origin main --tags
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || {
  echo "local main must exactly match origin/main" >&2; exit 1;
}
! git rev-parse "$TAG" >/dev/null 2>&1 || { echo "tag already exists: $TAG" >&2; exit 1; }
! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 || {
  echo "GitHub release already exists: $TAG" >&2; exit 1;
}
grep -F "version: \"$VERSION\"" Sources/CLI/Commands.swift >/dev/null || {
  echo "CLI version does not match $VERSION" >&2; exit 1;
}

IDENTITY=$(security find-identity -v -p codesigning | \
  sed -n 's/.*"\(Developer ID Application:.*(4UPMHT6AFG)\)"/\1/p' | head -n 1)
[[ -n "$IDENTITY" ]] || { echo "Developer ID Application identity not found" >&2; exit 1; }

# Verify the local notarization profile before spending time on the build.
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null

swift test -Xswiftc -warnings-as-errors
node --test Tests/verify.test.mjs
node Tools/make-vectors.mjs > /tmp/indielicense-release-vectors.json
diff Tests/vectors.json /tmp/indielicense-release-vectors.json

swift build -c release --arch arm64 --arch x86_64 --product indielicense
SOURCE_BIN=.build/apple/Products/Release/indielicense
lipo -info "$SOURCE_BIN"

WORK=$(mktemp -d /tmp/indielicense-release.XXXXXX)
TAP_WORK=$(mktemp -d /tmp/indielicense-tap.XXXXXX)
trap 'rm -rf "$WORK" "$TAP_WORK"' EXIT

cp "$SOURCE_BIN" "$WORK/indielicense"
swift package show-dependencies --format json > "$WORK/dependencies.json"

codesign --force --sign "$IDENTITY" --options runtime --timestamp "$WORK/indielicense"
codesign --verify --strict --verbose=2 "$WORK/indielicense"
"$WORK/indielicense" --version

ditto -c -k --keepParent "$WORK/indielicense" "$WORK/notarization.zip"
xcrun notarytool submit "$WORK/notarization.zip" \
  --keychain-profile "$NOTARY_PROFILE" --wait
spctl --assess --type execute --verbose=2 "$WORK/indielicense"

mkdir -p dist
ARCHIVE="dist/indielicense-$TAG-macos-universal.tar.gz"
CHECKSUM="$ARCHIVE.sha256"
FORMULA="dist/indielicense.rb"
[[ ! -e "$ARCHIVE" && ! -e "$CHECKSUM" && ! -e "$FORMULA" ]] || {
  echo "release output already exists in dist; move it before retrying" >&2; exit 1;
}

tar -C "$WORK" -czf "$ARCHIVE" indielicense dependencies.json
shasum -a 256 "$ARCHIVE" > "$CHECKSUM"
SHA256=$(awk '{print $1}' "$CHECKSUM")
sed -e "s/v1.0.0/$TAG/g" \
    -e "s/REPLACE_WITH_SHA256_FROM_RELEASE_ASSET/$SHA256/" \
    Formula/indielicense.rb > "$FORMULA"

git tag -a "$TAG" -m "IndieLicense $TAG"
git push origin "$TAG"
gh release create "$TAG" "$ARCHIVE" "$CHECKSUM" "$FORMULA" \
  --repo "$REPO" --verify-tag --generate-notes --title "IndieLicense $TAG"

git clone --quiet "git@github.com:$TAP_REPO.git" "$TAP_WORK"
TAP_BRANCH="indielicense-$TAG"
git -C "$TAP_WORK" switch -c "$TAP_BRANCH"
mkdir -p "$TAP_WORK/Formula"
cp "$FORMULA" "$TAP_WORK/Formula/indielicense.rb"
git -C "$TAP_WORK" add Formula/indielicense.rb
git -C "$TAP_WORK" commit -m "Publish IndieLicense $TAG"
git -C "$TAP_WORK" push -u origin "$TAP_BRANCH"
TAP_PR=$(gh pr create --repo "$TAP_REPO" --base main --head "$TAP_BRANCH" \
  --title "Publish IndieLicense $TAG" \
  --body "Formula generated from the signed and notarized $TAG release archive.")
gh pr merge "$TAP_PR" --repo "$TAP_REPO" --squash --delete-branch

echo
echo "Published IndieLicense $TAG"
echo "Release: https://github.com/$REPO/releases/tag/$TAG"
echo "Install: brew install tarasowski/tap/indielicense"
