#!/usr/bin/env bash
#
# Pull the latest Alchemist-Aloha/StashFlow into android/ and re-strip the
# platforms we don't ship. Run from the stashy repo ROOT, on a clean tree.
#
#   bash android/scripts/sync-android-upstream.sh
#
# Then: cd android && flutter pub get && flutter analyze && flutter test,
# eyeball the app, and push.
set -euo pipefail

UPSTREAM="https://github.com/Alchemist-Aloha/StashFlow.git"
PREFIX="android"
STRIP=(ios web windows macos linux .github .metadata)

echo "==> Pulling upstream StashFlow into $PREFIX/ ..."
git subtree pull --prefix="$PREFIX" "$UPSTREAM" main --squash \
  -m "chore(android): sync from upstream StashFlow"

echo "==> Re-stripping non-Android platforms upstream may have reintroduced ..."
for dir in "${STRIP[@]}"; do
  git rm -r --quiet --ignore-unmatch "$PREFIX/$dir" 2>/dev/null || true
done

if git diff --cached --quiet; then
  echo "==> Nothing to re-strip; tree already Android-only."
else
  git commit -q -m "chore(android): re-strip non-Android platforms after upstream sync"
  echo "==> Re-strip committed."
fi

echo "==> Done. Now: cd $PREFIX && flutter pub get && flutter analyze && flutter test"
