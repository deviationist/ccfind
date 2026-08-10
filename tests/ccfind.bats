#!/usr/bin/env bats
# Behavioral suite for ccfind. Focus: the local search + profile logic, which is
# fully exercisable without fzf/ssh/TTY via the flat-list path (CCFIND_INTERACTIVE=0).
load helpers

setup() { ccfind_setup; }

@test "default: searches ~/.claude, no profile labels, plain resume" {
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy the widget"
  run_ccfind -N deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"/proj/a"* ]]
  [[ "$output" != *"work:"* && "$output" != *"personal:"* ]]
  [[ "$output" == *"claude --resume s1"* ]]
  [[ "$output" != *"CLAUDE_CONFIG_DIR"* ]]
}

@test "default: no match prints 'No matching sessions.'" {
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy"
  run_ccfind -N zzzznope
  [ "$status" -eq 0 ]
  [[ "$output" == *"No matching sessions."* ]]
}

@test "default: no query lists recent sessions" {
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "anything"
  run_ccfind -N
  [ "$status" -eq 0 ]
  [[ "$output" == *"/proj/a"* ]]
}

@test "-d scopes to a cwd subtree" {
  mk_session "$FIXHOME/.claude" "/proj/keep" k1 "term"
  mk_session "$FIXHOME/.claude" "/proj/other" o1 "term"
  run_ccfind -N -d /proj/keep term
  [ "$status" -eq 0 ]
  [[ "$output" == *"/proj/keep"* ]]
  [[ "$output" != *"/proj/other"* ]]
}

@test "multi-profile: union searches both, tags each hit with its label" {
  mk_session "$BATS_TEST_TMPDIR/work" "/w/a" w1 "shared-term work-side"
  mk_session "$BATS_TEST_TMPDIR/personal" "/p/a" p1 "shared-term personal-side"
  export CCFIND_PROFILES="work:$BATS_TEST_TMPDIR/work personal:$BATS_TEST_TMPDIR/personal"
  run_ccfind -N shared-term
  [ "$status" -eq 0 ]
  [[ "$output" == *"work:/w/a"* ]]
  [[ "$output" == *"personal:/p/a"* ]]
}

@test "multi-profile: positional label scopes to one profile" {
  mk_session "$BATS_TEST_TMPDIR/work" "/w/a" w1 "term"
  mk_session "$BATS_TEST_TMPDIR/personal" "/p/a" p1 "term"
  export CCFIND_PROFILES="work:$BATS_TEST_TMPDIR/work personal:$BATS_TEST_TMPDIR/personal"
  run_ccfind -N work term
  [ "$status" -eq 0 ]
  [[ "$output" == *"work:/w/a"* ]]
  [[ "$output" != *"personal:"* ]]
}

@test "multi-profile: -p scopes to one profile" {
  mk_session "$BATS_TEST_TMPDIR/work" "/w/a" w1 "term"
  mk_session "$BATS_TEST_TMPDIR/personal" "/p/a" p1 "term"
  export CCFIND_PROFILES="work:$BATS_TEST_TMPDIR/work personal:$BATS_TEST_TMPDIR/personal"
  run_ccfind -N -p personal term
  [ "$status" -eq 0 ]
  [[ "$output" == *"personal:/p/a"* ]]
  [[ "$output" != *"work:"* ]]
}

@test "multi-profile: resume carries CLAUDE_CONFIG_DIR of the hit's profile" {
  mkdir -p "$BATS_TEST_TMPDIR/work/projects"     # configured but empty
  mk_session "$BATS_TEST_TMPDIR/personal" "/p/a" p1 "term"
  export CCFIND_PROFILES="work:$BATS_TEST_TMPDIR/work personal:$BATS_TEST_TMPDIR/personal"
  run_ccfind -N personal term
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLAUDE_CONFIG_DIR=$BATS_TEST_TMPDIR/personal claude --resume p1"* ]]
}

@test "unknown profile via -p errors (exit 2) and lists configured ones" {
  mk_session "$BATS_TEST_TMPDIR/work" "/w/a" w1 "term"
  export CCFIND_PROFILES="work:$BATS_TEST_TMPDIR/work"
  run_ccfind -p nope term
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown profile 'nope'"* ]]
  [[ "$output" == *"work"* ]]
}

@test "positional label is a literal search term when profiles are unconfigured" {
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy the widget"
  run_ccfind -N work
  [ "$status" -eq 0 ]
  [[ "$output" == *"No matching sessions."* ]]   # 'work' matches nothing here
}

@test "multi-profile: a configured-but-missing profile dir is skipped" {
  mk_session "$BATS_TEST_TMPDIR/work" "/w/a" w1 "term"
  export CCFIND_PROFILES="work:$BATS_TEST_TMPDIR/work ghost:$BATS_TEST_TMPDIR/does-not-exist"
  run_ccfind -N term
  [ "$status" -eq 0 ]
  [[ "$output" == *"work:/w/a"* ]]
  [[ "$output" != *"ghost:"* ]]
}

@test "-n caps the number of hits shown" {
  mk_session "$FIXHOME/.claude" "/proj/a" a1 "term"
  mk_session "$FIXHOME/.claude" "/proj/b" b1 "term"
  mk_session "$FIXHOME/.claude" "/proj/c" c1 "term"
  run_ccfind -N -n 2 term
  [ "$status" -eq 0 ]
  # 3 sessions match but only 2 are shown, with a truncation footer.
  [[ "$output" == *"3 total"* ]]
}

@test "remote (stubbed ssh): host column + default ssh resume command" {
  install_ssh_stub
  run_ccfind -H fakehost -N anything
  [ "$status" -eq 0 ]
  [[ "$output" == *"fakehost:/remote/proj"* ]]
  [[ "$output" == *"ssh -t fakehost"* ]]
}

@test "CCFIND_REMOTE_RESUME overrides the remote resume command" {
  install_ssh_stub
  export CCFIND_REMOTE_RESUME="my-resume"
  run_ccfind -H fakehost -N anything
  [ "$status" -eq 0 ]
  [[ "$output" == *"fakehost:/remote/proj"* ]]
  [[ "$output" == *"my-resume fakehost /remote/proj RID123"* ]]
  [[ "$output" != *"ssh -t fakehost"* ]]
}

# --- the resume line as a contract ----------------------------------------
# ccfind hands off to `claude` (in practice, to claude-profile's wrapper, which
# honors a caller-set CLAUDE_CONFIG_DIR verbatim). These pin that the emitted
# line is not merely well-worded but actually executes into the right seat.

@test "multi-profile: the emitted resume line really launches into that profile's dir" {
  mkdir -p "$BATS_TEST_TMPDIR/work/projects" "$BATS_TEST_TMPDIR/proj"
  mk_session "$BATS_TEST_TMPDIR/personal" "$BATS_TEST_TMPDIR/proj" p1 "term"
  export CCFIND_PROFILES="work:$BATS_TEST_TMPDIR/work personal:$BATS_TEST_TMPDIR/personal"
  run_ccfind -N personal term
  [ "$status" -eq 0 ]
  local line; line="$(resume_line_from_output)"
  install_claude_stub
  run_resume "$line"
  [ "$status" -eq 0 ]
  [[ "$output" == *"argv=[--resume p1]"* ]]
  [[ "$output" == *"dir=[$BATS_TEST_TMPDIR/personal]"* ]]
  [[ "$output" == *"pwd=[$BATS_TEST_TMPDIR/proj]"* ]]
}

@test "unconfigured: the resume line launches with no CLAUDE_CONFIG_DIR set" {
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR/proj" s1 "term"
  run_ccfind -N term
  local line; line="$(resume_line_from_output)"
  install_claude_stub
  run_resume "$line"
  [[ "$output" == *"dir=[<unset>]"* ]]
}

@test "the env assignment binds to claude, not to the cd that precedes it" {
  mkdir -p "$BATS_TEST_TMPDIR/work/projects" "$BATS_TEST_TMPDIR/proj"
  mk_session "$BATS_TEST_TMPDIR/personal" "$BATS_TEST_TMPDIR/proj" p1 "term"
  export CCFIND_PROFILES="work:$BATS_TEST_TMPDIR/work personal:$BATS_TEST_TMPDIR/personal"
  run_ccfind -N personal term
  [[ "$output" == *"cd $BATS_TEST_TMPDIR/proj && CLAUDE_CONFIG_DIR=$BATS_TEST_TMPDIR/personal claude --resume p1"* ]]
}

@test "a session cwd containing spaces is quoted, so the line stays executable" {
  mkdir -p "$BATS_TEST_TMPDIR/work/projects" "$BATS_TEST_TMPDIR/my proj"
  mk_session "$BATS_TEST_TMPDIR/personal" "$BATS_TEST_TMPDIR/my proj" p1 "term"
  export CCFIND_PROFILES="work:$BATS_TEST_TMPDIR/work personal:$BATS_TEST_TMPDIR/personal"
  run_ccfind -N personal term
  local line; line="$(resume_line_from_output)"
  install_claude_stub
  run_resume "$line"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pwd=[$BATS_TEST_TMPDIR/my proj]"* ]]
  [[ "$output" == *"dir=[$BATS_TEST_TMPDIR/personal]"* ]]
}

@test "no cd prefix when the hit's cwd is already the current directory" {
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR/proj" s1 "term"
  run env HOME="$FIXHOME" CCFIND_INTERACTIVE=0 \
    zsh -fc 'cd "$2"; source "$1"; ccfind -N term' _ "$CCFIND_ZSH" "$BATS_TEST_TMPDIR/proj"
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude --resume s1"* ]]
  [[ "$output" != *"cd "* ]]
}

@test "single-profile fallback: configured profiles that are all absent fall back to ~/.claude" {
  # The shape a shared .env produces on a single-account host: both profiles
  # named, neither present. Every token is skipped, profiles_on stays 0, and
  # ccfind must behave exactly as if CCFIND_PROFILES were never set — no label
  # column and, crucially, no CLAUDE_CONFIG_DIR on the resume line.
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR/proj" s1 "term"
  export CCFIND_PROFILES="work:$BATS_TEST_TMPDIR/gone-a personal:$BATS_TEST_TMPDIR/gone-b"
  run_ccfind -N term
  [ "$status" -eq 0 ]
  [[ "$output" == *"$BATS_TEST_TMPDIR/proj"* ]]
  [[ "$output" != *"work:"* && "$output" != *"personal:"* ]]
  [[ "$output" != *"CLAUDE_CONFIG_DIR"* ]]
  local line; line="$(resume_line_from_output)"
  install_claude_stub
  run_resume "$line"
  [[ "$output" == *"dir=[<unset>]"* ]]
}

@test "single-profile: one configured profile that IS present still labels and pins the dir" {
  # Current behavior, pinned deliberately: profiles_on flips on for a single
  # surviving profile, so hits carry its label and the resume line presets
  # CLAUDE_CONFIG_DIR. Correct seat either way — but note that a preset dir
  # makes claude-profile's wrapper step fully aside (no launch-time
  # auto-rotation), which is why the all-absent case above must NOT do this.
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR/proj" s1 "term"
  export CCFIND_PROFILES="work:$FIXHOME/.claude personal:$BATS_TEST_TMPDIR/gone"
  run_ccfind -N term
  [ "$status" -eq 0 ]
  [[ "$output" == *"work:$BATS_TEST_TMPDIR/proj"* ]]
  [[ "$output" == *"CLAUDE_CONFIG_DIR=$FIXHOME/.claude claude --resume s1"* ]]
}
