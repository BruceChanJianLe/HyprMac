#!/bin/bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/release.sh"

grep -q '^set -Eeuo pipefail$' "$SCRIPT"
grep -q 'ERROR: Sparkle generate_appcast missing' "$SCRIPT"
grep -q 'git -C "$TEMP_TAP" push origin HEAD:main' "$SCRIPT"
if grep -Eq 'git .*push.*\|\| true|xcodebuild .*\|.*\|\| true' "$SCRIPT"; then
    echo "release failures can still be swallowed" >&2
    exit 1
fi

commit_line=$(grep -n 'git commit -m "Release v\$NEW_VERSION"' "$SCRIPT" | cut -d: -f1)
tag_line=$(grep -n 'git tag -a "v\$NEW_VERSION"' "$SCRIPT" | cut -d: -f1)
release_line=$(grep -n 'gh release create "v\$NEW_VERSION"' "$SCRIPT" | head -1 | cut -d: -f1)
[[ "$commit_line" -lt "$tag_line" && "$tag_line" -lt "$release_line" ]]

echo "release pipeline invariants verified"
