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

# --- colour ----------------------------------------------------------------
# The contract is that colour is a display layer only: on when a human is
# looking, gone the moment output is piped — which is what keeps every
# assertion above (and any user's grep) working on plain bytes.

@test "colour is off when stdout is not a terminal" {
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy the widget"
  run_ccfind -N deploy
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\033['* ]]
}

@test "CCFIND_COLOR=always emits SGR even when piped" {
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy the widget"
  export CCFIND_COLOR=always
  run_ccfind -N deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\033[32m'*"claude --resume s1"* ]]   # the resume command
}

@test "the match is highlighted inside the snippet" {
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "before DePlOy after"
  export CCFIND_COLOR=always
  run_ccfind -N deploy
  [ "$status" -eq 0 ]
  # case-insensitive, and the original casing survives the highlighting
  [[ "$output" == *$'\033[1;33m'"DePlOy"$'\033[0m'* ]]
}

@test "-C strips the colour even with CCFIND_COLOR=always" {
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy the widget"
  export CCFIND_COLOR=always
  run_ccfind -N -C deploy
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\033['* ]]
}

@test "NO_COLOR wins over the auto default" {
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy the widget"
  export NO_COLOR=1
  run_ccfind -N deploy
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\033['* ]]
}

@test "an empty result says what was searched" {
  mk_session "$BATS_TEST_TMPDIR/work" "/w/a" w1 "term"
  export CCFIND_PROFILES="work:$BATS_TEST_TMPDIR/work"
  run_ccfind -N zzzznope
  [ "$status" -eq 0 ]
  [[ "$output" == *"No matching sessions."* ]]
  [[ "$output" == *'query "zzzznope"'* ]]
  [[ "$output" == *"profiles: work"* ]]
}

# --- the two colour helpers, unit-tested ------------------------------------
# The picker path needs a TTY, so these exercise its two moving parts directly:
# a query is highlighted literally (not as a glob), and a row that somehow came
# back still carrying SGR is stripped before it is parsed into fields.

@test "_ccfind_hl treats a glob-metacharacter query literally" {
  run env zsh -fc 'source "$1"; _CCF_HIT="<"; _CCF_OFF=">"
                   _ccfind_hl "keep a*b and a*b" "a*b" ""' _ "$CCFIND_ZSH"
  [ "$status" -eq 0 ]
  [ "$output" = "keep <a*b> and <a*b>" ]
}

@test "_ccfind_strip_sgr removes every SGR run" {
  run env zsh -fc 'source "$1"
                   _ccfind_strip_sgr $'"'"'\033[36mwork\033[0m\tid\t\033[2mts\033[0m'"'"'' _ "$CCFIND_ZSH"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'work\tid\tts')" ]
}

# --- the picker path, driven through a stub fzf -----------------------------
# -i is documented as the explicit "give me the picker", overriding both
# CCFIND_INTERACTIVE=0 and the TTY sniff — which is the only reason the picker
# is reachable from a test (or from the SVG generator) at all. These pin the
# row contract the picker is built on, without needing a terminal.

@test "-i reaches the picker with no TTY, and hands fzf the rows" {
  install_fzf_stub
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy the widget"
  run_ccfind -i deploy
  [ "$status" -eq 0 ]          # stub exits 130 = cancelled → nothing resumed
  [ -s "$FZF_ROWS" ]
  [[ "$(cat "$FZF_ARGV")" == *"--with-nth=7"* ]]
}

@test "picker rows keep the data fields plain behind the display field" {
  install_fzf_stub
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy the widget"
  export CCFIND_COLOR=always
  run_ccfind -i deploy
  [ "$status" -eq 0 ]
  local row; row="$(head -1 "$FZF_ROWS")"
  # 7 fields: host, id, cwd, ts, snippet, path, display
  [ "$(awk -F'\t' '{print NF}' <<<"$row")" -eq 7 ]
  # 1 (host) and 6 (path) are what the resume and the preview read — no SGR in
  # them, or a profile label stops matching and a path stops opening.
  [ "$(cut -f1 <<<"$row")" = "local" ]
  [ "$(cut -f2 <<<"$row")" = "s1" ]
  [ "$(cut -f3 <<<"$row")" = "/proj/a" ]
  [[ "$(cut -f6 <<<"$row")" == *"/projects/-proj-a/s1.jsonl" ]]
  # …while field 7, the one fzf shows, carries the colour and the columns
  [[ "$(cut -f7 <<<"$row")" == *$'\033['* ]]
  [[ "$(cut -f7 <<<"$row")" == *"/proj/a"* ]]
}

@test "the picker gets one row per hit, newest first" {
  install_fzf_stub
  mk_session "$FIXHOME/.claude" "/proj/old" o1 "term"
  sleep 1
  mk_session "$FIXHOME/.claude" "/proj/new" n1 "term"
  run_ccfind -i term
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$FZF_ROWS")" -eq 2 ]
  [[ "$(head -1 "$FZF_ROWS")" == *"/proj/new"* ]]
}
