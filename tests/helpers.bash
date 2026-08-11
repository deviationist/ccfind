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

# install_ssh_stub — shadow `ssh` with a stub that emulates ccfind's remote
# worker (one TSV hit regardless of args), so the remote (-r/-H) code path is
# exercisable without a real host. ccfind calls `command ssh`, which honors PATH.
install_ssh_stub() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/ssh" <<'STUB'
#!/usr/bin/env bash
# worker output: epoch \t id \t cwd \t ts \t snippet \t path
printf '1700000000\tRID123\t/remote/proj\t2024-01-01 12:00:00\tremote snippet\t/remote/proj/RID123.jsonl\n'
exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/ssh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
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
  cat > "$BATS_TEST_TMPDIR/bin/fzf" <<'STUB'
#!/usr/bin/env bash
case "$1" in --version) echo "0.74.2 (stub)"; exit 0 ;; esac
printf '%s\n' "$@" > "$FZF_ARGV"
cat > "$FZF_ROWS"
exit 130
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/fzf"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}
