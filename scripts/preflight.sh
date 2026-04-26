#!/bin/bash
# preflight.sh — release-readiness verification.
# Invoked automatically by the pre-push hook; can also be run manually before tagging.
# A non-zero exit blocks the push.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# === 0. Required tools present? ===
missing_tools=()
for tool in bash python3 jq shellcheck; do
  command -v "$tool" >/dev/null 2>&1 || missing_tools+=("$tool")
done
if [ "${#missing_tools[@]}" -ne 0 ]; then
  echo "❌ Required tools missing: ${missing_tools[*]}" >&2
  echo "   macOS:  brew install ${missing_tools[*]}" >&2
  echo "   Ubuntu: sudo apt-get install ${missing_tools[*]}" >&2
  exit 1
fi

echo "[1/5] Bash syntax check (hooks/, lib/, scripts/)"
find hooks lib scripts -type f -name '*.sh' -print0 \
  | xargs -0 -n1 bash -n

echo "[2/5] Shellcheck"
find hooks lib scripts -type f -name '*.sh' -print0 \
  | xargs -0 shellcheck --severity=warning

echo "[3/5] Python compile check"
python3 -m compileall -q lib/

echo "[4/5] JSON validity"
for f in .claude-plugin/plugin.json .claude-plugin/marketplace.json hooks/hooks.json config.json; do
  jq empty "$f" >/dev/null
done

echo "[5/5] Secret / absolute-path grep"
PATTERNS=(
  'sk-ant-api[0-9]{2}-[A-Za-z0-9_-]{40,}'
  'sk-[A-Za-z0-9]{32,}'
  'gh[ps]_[A-Za-z0-9]{36}'
  'AKIA[0-9A-Z]{16}'
  'xox[baprs]-[A-Za-z0-9-]{10,}'
  '/Users/[a-z][a-z0-9._-]+/'
  'ANTHROPIC_API_KEY[[:space:]]*=[[:space:]]*[^$"'"'"'[:space:]]'
)
matched=0
for pat in "${PATTERNS[@]}"; do
  if grep -rIE --color=never "$pat" \
       --include='*.sh' --include='*.py' --include='*.md' \
       --include='*.json' --include='*.yml' --include='*.yaml' \
       --exclude-dir='.git' --exclude='preflight.sh' . 2>/dev/null; then
    echo "❌ Suspicious pattern detected: $pat" >&2
    matched=1
  fi
done
[ "$matched" -eq 1 ] && exit 1

echo "✅ All checks passed"
