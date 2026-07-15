#!/usr/bin/env bash
# Run the ccfind test suite. Usage: tests/run.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v bats >/dev/null 2>&1; then
  echo "bats not found — install with: brew install bats-core (macOS) / apt install bats (Debian)" >&2
  exit 127
fi
if ! command -v zsh >/dev/null 2>&1; then
  echo "zsh not found — ccfind is zsh-only" >&2
  exit 127
fi

echo "== ccfind bats suite =="
bats "$here/ccfind.bats"
