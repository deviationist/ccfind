#!/usr/bin/env bash
# Shared helpers for the ccfind bats suite.
#
# ccfind.zsh is zsh-only (glob qualifiers, ${(s)}/${(@f)}/${(q)} flags, assoc
# arrays), so — unlike a portable tool — we do NOT source it under bash. Each
# test invokes ccfind inside an isolated `zsh -f` subprocess with a fixture HOME
# and a copy of the script that has no sibling .env (so the operator's real
# ~/code-private/ccfind/.env is never sourced). All state lives in
# $BATS_TEST_TMPDIR, which bats creates and removes per test.

ccfind_setup() {
  CCFIND_SRC="$BATS_TEST_DIRNAME/../ccfind.zsh"
  # Copy into an isolated dir so ${_CCFIND_SOURCE:h}/.env resolves to a dir with
  # no .env — the auto-load is skipped and only exported CCFIND_* env is used.
  export CCFIND_ZSH="$BATS_TEST_TMPDIR/ccfind.zsh"
  cp "$CCFIND_SRC" "$CCFIND_ZSH"

  # Fixture HOME; the default (unconfigured) profile is $FIXHOME/.claude.
  export FIXHOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$FIXHOME/.claude/projects"

  export CCFIND_INTERACTIVE=0     # always the flat list — deterministic, no TTY
  unset CCFIND_PROFILES CCFIND_HOSTS CCFIND_TABS CCFIND_MAX
}

# mk_session <config-dir> <cwd> <id> <text>
# Writes <config-dir>/projects/<encoded-cwd>/<id>.jsonl carrying a cwd field and
# some searchable text (mirrors how Claude Code stores transcripts).
mk_session() {
  local root="$1" cwd="$2" id="$3" text="$4"
  local enc="${cwd//\//-}"
  mkdir -p "$root/projects/$enc"
  printf '{"cwd":"%s","text":"%s"}\n' "$cwd" "$text" > "$root/projects/$enc/$id.jsonl"
}

# run_ccfind <ccfind-args...> — run ccfind in an isolated zsh with the fixture
# HOME. Exported CCFIND_* vars set by the test propagate into the subprocess.
run_ccfind() {
  run env HOME="$FIXHOME" zsh -fc 'src=$1; shift; source "$src"; ccfind "$@"' _ "$CCFIND_ZSH" "$@"
}
