#!/usr/bin/env bash
# Shared helpers for the ccfind bats suite.
#
# ccfind.zsh is zsh-only (glob qualifiers, ${(s)}/${(@f)}/${(q)} flags, assoc
# arrays), so — unlike a portable tool — we do NOT source it under bash. Each
# test invokes ccfind inside an isolated `zsh -f` subprocess with a fixture HOME
# and a copy of the script that has no sibling .env (so your real .env beside
# ccfind.zsh is never sourced). All state lives in
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
  # Anything running these tests from inside a Claude Code session (or any
  # profile-switching wrapper) has CLAUDE_CONFIG_DIR exported; it would be
  # inherited by an executed resume line and mask what ccfind actually emits.
  unset CLAUDE_CONFIG_DIR
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

# install_ssh_stub — shadow `ssh` with a stub that answers as a host WITHOUT
# ccfind: the worker's fallback header, then one record in the wire format.
# ccfind calls `command ssh`, which honors PATH.
install_ssh_stub() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/ssh" <<'STUB'
#!/usr/bin/env bash
# header, then: epoch \t profile \t cfgdir \t id \t cwd \t ts \t snippet \t path
# No ccfind on this host, so the profile column is empty — one nameless seat.
printf '#ccfind mode=fallback reason=not-installed\n'
printf '1700000000\t\t/root/.claude\tRID123\t/remote/proj\t2024-01-01 12:00:00\tremote snippet\t/remote/proj/RID123.jsonl\n'
exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/ssh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# install_ssh_stub_real_host — shadow `ssh` with a stub that runs the remote
# command locally against a fake remote $HOME, with a real copy of ccfind.zsh
# installed there. Nothing is canned: the worker script really does go over
# "the wire" on stdin, really does find that ccfind, and the records really are
# produced by its --tsv emitter. So this exercises BOTH sides of the protocol —
# which is the only way the wire format is actually pinned, since caller and
# host are two different copies of this tool.
#
# Sets REMOTE_HOME (with the two profiles seeded) for the test to write into.
install_ssh_stub_real_host() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export REMOTE_HOME="$BATS_TEST_TMPDIR/remote-home"
  export REMOTE_CCFIND_DIR="$BATS_TEST_TMPDIR/remote-ccfind"
  mkdir -p "$REMOTE_HOME" "$REMOTE_CCFIND_DIR"
  cp "$CCFIND_SRC" "$REMOTE_CCFIND_DIR/ccfind.zsh"
  # The host's own profile config, where a real install keeps it: a .env beside
  # the script. This is the thing the caller cannot know and must ask for.
  cat > "$REMOTE_CCFIND_DIR/.env" <<ENV
typeset CCFIND_PROFILES="rwork:$REMOTE_HOME/.claude rpersonal:$REMOTE_HOME/.claude-personal"
ENV
  cat > "$BATS_TEST_TMPDIR/bin/ssh" <<'STUB'
#!/usr/bin/env bash
cmd=""; for a in "$@"; do cmd="$a"; done       # the remote command is the last arg
cmd="${cmd#CCFIND_REMOTE_PATH=* }"             # drop the caller's hint; we set our own
exec env HOME="$REMOTE_HOME" CCFIND_REMOTE_PATH="$REMOTE_CCFIND_DIR/ccfind.zsh" \
     sh -c "$cmd"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/ssh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# install_ssh_stub_bare_host — the same, but with no ccfind installed on the
# far end, so the worker takes its filesystem-walk fallback for real.
install_ssh_stub_bare_host() {
  install_ssh_stub_real_host
  rm -rf "$REMOTE_CCFIND_DIR"
}

# install_claude_stub — shadow `claude` with a stub that reports the argv and
# the CLAUDE_CONFIG_DIR it inherited. Lets a test *execute* an emitted resume
# line and assert where it would actually have landed, rather than only
# string-matching the line. (Mirrors the receiving-end wrapper in
# claude-profile, which honors a caller-set CLAUDE_CONFIG_DIR verbatim.)
install_claude_stub() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
echo "CLAUDE argv=[$*] dir=[${CLAUDE_CONFIG_DIR-<unset>}] pwd=[$PWD]"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
}

# resume_line_from_output — the resume command ccfind printed for the first hit.
resume_line_from_output() { printf '%s\n' "$output" | grep -m1 -- 'claude --resume'; }

# run_resume <line> — execute an emitted resume line with the stub on PATH.
run_resume() {
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" HOME="$FIXHOME" bash -c "$1"
}

# install_fzf_stub — shadow `fzf` with a stub that records the rows it is fed
# (and its argv) and exits 130, fzf's "cancelled". Lets the picker path be
# driven with no terminal and nothing selected, so what the picker *would*
# display is assertable. Same trick the README-SVG generator uses.
install_fzf_stub() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export FZF_ROWS="$BATS_TEST_TMPDIR/fzf-rows" FZF_ARGV="$BATS_TEST_TMPDIR/fzf-argv"
  export FZF_TABS="$BATS_TEST_TMPDIR/fzf-tabs"
  cat > "$BATS_TEST_TMPDIR/bin/fzf" <<'STUB'
#!/usr/bin/env bash
case "$1" in --version) echo "0.74.2 (stub)"; exit 0 ;; esac
printf '%s\n' "$@" > "$FZF_ARGV"
# Snapshot the tab-view state directory while it still exists: ccfind builds it
# in a temp dir wiped by the trap when the function returns, so a test can only
# see it from in here. Its path is in the Tab keybinding ccfind passes us.
for a in "$@"; do
  case "$a" in
    *_ccfind_tab_shift*)
      d="${a#*_ccfind_tab_shift }"; d="${d%% *}"; d="${d%\'}"; d="${d#\'}"
      [ -d "$d" ] && cp -R "$d" "$FZF_TABS"
      break ;;
  esac
done
cat > "$FZF_ROWS"
exit 130
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/fzf"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# --- assertions -------------------------------------------------------------
# Use these rather than a bare `[[ … ]]`. A false `[[ … ]]` in the MIDDLE of a
# bats test does not fail it — only the last command in the body, or a plain
# `[ … ]`, is checked — so every mid-test `[[ … ]]` in this suite was silently
# decorative until it was the final line. (Verified against bats 1.13: a false
# `[[ x == y ]]` mid-body reports ok; the same as a helper function reports not
# ok.) These are functions, so a failure really does fail the test, and each
# one prints what it wanted and what it got.
assert_contains() {   # <haystack> <needle>
  case "$1" in *"$2"*) return 0 ;; esac
  printf 'expected output to contain:\n  %s\nactual output:\n%s\n' "$2" "$1" >&2
  return 1
}

refute_contains() {   # <haystack> <needle>
  case "$1" in
    *"$2"*)
      printf 'expected output NOT to contain:\n  %s\nactual output:\n%s\n' "$2" "$1" >&2
      return 1 ;;
  esac
  return 0
}

assert_equal() {      # <actual> <expected>
  [ "$1" = "$2" ] && return 0
  printf 'expected: %s\nactual:   %s\n' "$2" "$1" >&2
  return 1
}

# install_claude_profile_stub [<dir>] — put a `claude-profile` on PATH that
# answers `list` with the porcelain claude-profile really emits:
#   <name>\t<dir>[\tactive]
# Dirs are resolved against $HOME at call time, so the same stub serves a local
# machine and a fake remote one (the stub is on PATH for both).
install_claude_profile_stub() {
  local bindir="${1:-$BATS_TEST_TMPDIR/bin}"
  mkdir -p "$bindir"
  cat > "$bindir/claude-profile" <<'STUB'
#!/bin/sh
[ "$1" = list ] || exit 2
printf 'daily\t%s/.claude\n' "$HOME"
printf 'client\t%s/.claude-work\tactive\n' "$HOME"
STUB
  chmod +x "$bindir/claude-profile"
  export PATH="$bindir:$PATH"
}

# run_preview <host> <file> [query] — render the fzf preview pane for a
# transcript, the way the picker's --preview command does (its own zsh, sourcing
# ccfind.zsh and calling the function directly).
run_preview() {
  run env HOME="$FIXHOME" CCFIND_PV_QUERY="${3-}" CCFIND_PV_CACHE="$BATS_TEST_TMPDIR" \
      CCFIND_LOCAL_LABELS="local" \
      zsh -fc 'src=$1; shift; source "$src"; _ccfind_preview "$@"' _ "$CCFIND_ZSH" "$1" "$2"
}

# mk_transcript <file> <lines...> — a transcript with real message records, for
# the preview to render. mk_session writes one searchable line; this writes a
# conversation.
mk_transcript() {
  local f="$1"; shift
  mkdir -p "${f%/*}"
  : > "$f"
  local role=user line
  for line in "$@"; do
    printf '{"type":"%s","message":{"role":"%s","content":"%s"}}\n' "$role" "$role" "$line" >> "$f"
    [ "$role" = user ] && role=assistant || role=user
  done
}
