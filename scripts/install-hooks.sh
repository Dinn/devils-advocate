#!/bin/bash
# install-hooks.sh — activate the repo's git hooks. Run once after clone.
# Sets core.hooksPath to scripts/git-hooks/ so the in-repo hooks are picked up
# without touching .git/hooks/ (which is not tracked by git).

set -euo pipefail

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "❌ This script must be run inside a git repo." >&2
  exit 1
fi

git config core.hooksPath scripts/git-hooks

chmod +x scripts/git-hooks/* scripts/preflight.sh

echo "✅ git hooks activated (core.hooksPath = scripts/git-hooks)"
echo "   - pre-commit: fast secret scan (blocks entry into history)"
echo "   - pre-push:   full preflight checks (release gate)"
echo ""
echo "Bypass: git commit/push --no-verify (own the consequences)"
