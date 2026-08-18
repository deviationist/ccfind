#!/usr/bin/env bats
# Behavioral suite for ccfind. Focus: the local search + profile logic, which is
# fully exercisable without fzf/ssh/TTY via the flat-list path (CCFIND_INTERACTIVE=0).
load helpers

setup() { ccfind_setup; }
teardown() { ccfind_teardown; }

@test "default: searches ~/.claude, no profile labels, plain resume" {
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy the widget"
  run_ccfind -N deploy
  [ "$status" -eq 0 ]
  assert_contains "$output" "/proj/a"
  refute_contains "$output" "work:"
  refute_contains "$output" "personal:"
  assert_contains "$output" "claude --resume s1"
  refute_contains "$output" "CLAUDE_CONFIG_DIR"
}

@test "default: no match prints 'No matching sessions.'" {
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy"
  run_ccfind -N zzzznope
  [ "$status" -eq 0 ]
  assert_contains "$output" "No matching sessions."
}

@test "default: no query lists recent sessions" {
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "anything"
  run_ccfind -N
  [ "$status" -eq 0 ]
  assert_contains "$output" "/proj/a"
}

@test "-d scopes to a cwd subtree" {
  mk_session "$FIXHOME/.claude" "/proj/keep" k1 "term"
  mk_session "$FIXHOME/.claude" "/proj/other" o1 "term"
  run_ccfind -N -d /proj/keep term
  [ "$status" -eq 0 ]
  assert_contains "$output" "/proj/keep"
  refute_contains "$output" "/proj/other"
}

@test "-d scopes a dotted path (encoding flattens the dot, not only the slash)" {
  mk_session "$FIXHOME/.claude" "/proj/me/.zsh/tool" z1 "term"
  mk_session "$FIXHOME/.claude" "/proj/me/other"     o1 "term"
  run_ccfind -N -d /proj/me/.zsh/tool term
  [ "$status" -eq 0 ]
  # Assert on the resume line, not on the path: the "no sessions recorded
  # under <dir>" message quotes the path back too, so a path-only assertion
  # passes even when the scope matched nothing.
  assert_contains "$output" "claude --resume z1"
  refute_contains "$output" "/proj/me/other"
}

@test "-x scopes to the exact dir, excluding its subdirectories" {
  mk_session "$FIXHOME/.claude" "/proj/keep"     k1 "term"
  mk_session "$FIXHOME/.claude" "/proj/keep/sub" s1 "term"
  run_ccfind -N -x -d /proj/keep term
  [ "$status" -eq 0 ]
  assert_contains "$output" "/proj/keep"
  refute_contains "$output" "/proj/keep/sub"
}

@test "-d without -x still includes the subdirectories" {
  mk_session "$FIXHOME/.claude" "/proj/keep"     k1 "term"
  mk_session "$FIXHOME/.claude" "/proj/keep/sub" s1 "term"
  run_ccfind -N -d /proj/keep term
  [ "$status" -eq 0 ]
  assert_contains "$output" "/proj/keep/sub"
}

@test "-x with no -d means the current directory" {
  local here; here="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/here"
  mkdir -p "$here/sub"
  mk_session "$FIXHOME/.claude" "$here"     h1 "term"
  mk_session "$FIXHOME/.claude" "$here/sub" s1 "term"
  run_ccfind_in "$here" -N -x term
  [ "$status" -eq 0 ]
  assert_contains "$output" "$here"
  refute_contains "$output" "$here/sub"
}

@test "-x does not over-match a sibling that shares the encoded prefix" {
  # /proj/keep and /proj/keep-scratch both encode to -proj-keep… — the subtree
  # glob cannot tell them apart, the exact name can.
  mk_session "$FIXHOME/.claude" "/proj/keep"         k1 "term"
  mk_session "$FIXHOME/.claude" "/proj/keep-scratch" x1 "term"
  run_ccfind -N -x -d /proj/keep term
  [ "$status" -eq 0 ]
  assert_contains "$output" "/proj/keep"
  refute_contains "$output" "/proj/keep-scratch"
}

@test "-x with nothing in that dir says so, and says why" {
  mk_session "$FIXHOME/.claude" "/proj/keep/sub" s1 "term"
  run_ccfind -N -x -d /proj/keep term
  [ "$status" -eq 0 ]
  assert_contains "$output" "No sessions recorded in /proj/keep itself"
}

@test "multi-profile: union searches both, tags each hit with its label" {
  mk_session "$BATS_TEST_TMPDIR/work" "/w/a" w1 "shared-term work-side"
  mk_session "$BATS_TEST_TMPDIR/personal" "/p/a" p1 "shared-term personal-side"
  export CCFIND_PROFILES="work:$BATS_TEST_TMPDIR/work personal:$BATS_TEST_TMPDIR/personal"
  run_ccfind -N shared-term
  [ "$status" -eq 0 ]
  assert_contains "$output" "work:/w/a"
  assert_contains "$output" "personal:/p/a"
}

@test "multi-profile: positional label scopes to one profile" {
  mk_session "$BATS_TEST_TMPDIR/work" "/w/a" w1 "term"
  mk_session "$BATS_TEST_TMPDIR/personal" "/p/a" p1 "term"
  export CCFIND_PROFILES="work:$BATS_TEST_TMPDIR/work personal:$BATS_TEST_TMPDIR/personal"
  run_ccfind -N work term
  [ "$status" -eq 0 ]
  assert_contains "$output" "work:/w/a"
  refute_contains "$output" "personal:"
}

@test "multi-profile: -p scopes to one profile" {
  mk_session "$BATS_TEST_TMPDIR/work" "/w/a" w1 "term"
  mk_session "$BATS_TEST_TMPDIR/personal" "/p/a" p1 "term"
  export CCFIND_PROFILES="work:$BATS_TEST_TMPDIR/work personal:$BATS_TEST_TMPDIR/personal"
  run_ccfind -N -p personal term
  [ "$status" -eq 0 ]
  assert_contains "$output" "personal:/p/a"
  refute_contains "$output" "work:"
}

@test "multi-profile: resume carries CLAUDE_CONFIG_DIR of the hit's profile" {
  mkdir -p "$BATS_TEST_TMPDIR/work/projects"     # configured but empty
  mk_session "$BATS_TEST_TMPDIR/personal" "/p/a" p1 "term"
  export CCFIND_PROFILES="work:$BATS_TEST_TMPDIR/work personal:$BATS_TEST_TMPDIR/personal"
  run_ccfind -N personal term
  [ "$status" -eq 0 ]
  assert_contains "$output" "CLAUDE_CONFIG_DIR=$BATS_TEST_TMPDIR/personal claude --resume p1"
}

@test "unknown profile via -p errors (exit 2) and lists configured ones" {
  mk_session "$BATS_TEST_TMPDIR/work" "/w/a" w1 "term"
  export CCFIND_PROFILES="work:$BATS_TEST_TMPDIR/work"
  run_ccfind -p nope term
  [ "$status" -eq 2 ]
  assert_contains "$output" "unknown profile 'nope'"
  assert_contains "$output" "work"
}

@test "positional label is a literal search term when profiles are unconfigured" {
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy the widget"
  run_ccfind -N work
  [ "$status" -eq 0 ]
  assert_contains "$output" "No matching sessions."   # 'work' matches nothing here
}

@test "multi-profile: a configured-but-missing profile dir is skipped" {
  mk_session "$BATS_TEST_TMPDIR/work" "/w/a" w1 "term"
  export CCFIND_PROFILES="work:$BATS_TEST_TMPDIR/work ghost:$BATS_TEST_TMPDIR/does-not-exist"
  run_ccfind -N term
  [ "$status" -eq 0 ]
  assert_contains "$output" "work:/w/a"
  refute_contains "$output" "ghost:"
}

@test "-n caps the number of hits shown" {
  mk_session "$FIXHOME/.claude" "/proj/a" a1 "term"
  mk_session "$FIXHOME/.claude" "/proj/b" b1 "term"
  mk_session "$FIXHOME/.claude" "/proj/c" c1 "term"
  run_ccfind -N -n 2 term
  [ "$status" -eq 0 ]
  # 3 sessions match but only 2 are shown, with a truncation footer.
  assert_contains "$output" "3 total"
}

@test "remote (stubbed ssh): host column + default ssh resume command" {
  install_ssh_stub
  run_ccfind -H fakehost -N anything
  [ "$status" -eq 0 ]
  assert_contains "$output" "fakehost:/remote/proj"
  assert_contains "$output" "ssh -t fakehost"
}

@test "CCFIND_REMOTE_RESUME overrides the remote resume command" {
  install_ssh_stub
  export CCFIND_REMOTE_RESUME="my-resume"
  run_ccfind -H fakehost -N anything
  [ "$status" -eq 0 ]
  assert_contains "$output" "fakehost:/remote/proj"
  assert_contains "$output" "my-resume fakehost /remote/proj RID123"
  refute_contains "$output" "ssh -t fakehost"
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
  assert_contains "$output" "argv=[--resume p1]"
  assert_contains "$output" "dir=[$BATS_TEST_TMPDIR/personal]"
  assert_contains "$output" "pwd=[$BATS_TEST_TMPDIR/proj]"
}

@test "unconfigured: the resume line launches with no CLAUDE_CONFIG_DIR set" {
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR/proj" s1 "term"
  run_ccfind -N term
  local line; line="$(resume_line_from_output)"
  install_claude_stub
  run_resume "$line"
  assert_contains "$output" "dir=[<unset>]"
}

@test "the env assignment binds to claude, not to the cd that precedes it" {
  mkdir -p "$BATS_TEST_TMPDIR/work/projects" "$BATS_TEST_TMPDIR/proj"
  mk_session "$BATS_TEST_TMPDIR/personal" "$BATS_TEST_TMPDIR/proj" p1 "term"
  export CCFIND_PROFILES="work:$BATS_TEST_TMPDIR/work personal:$BATS_TEST_TMPDIR/personal"
  run_ccfind -N personal term
  assert_contains "$output" "cd $BATS_TEST_TMPDIR/proj && CLAUDE_CONFIG_DIR=$BATS_TEST_TMPDIR/personal claude --resume p1"
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
  assert_contains "$output" "pwd=[$BATS_TEST_TMPDIR/my proj]"
  assert_contains "$output" "dir=[$BATS_TEST_TMPDIR/personal]"
}

@test "no cd prefix when the hit's cwd is already the current directory" {
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR/proj" s1 "term"
  run env HOME="$FIXHOME" CCFIND_INTERACTIVE=0 \
    zsh -fc 'cd "$2"; source "$1"; ccfind -N term' _ "$CCFIND_ZSH" "$BATS_TEST_TMPDIR/proj"
  [ "$status" -eq 0 ]
  assert_contains "$output" "claude --resume s1"
  refute_contains "$output" "cd "
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
  assert_contains "$output" "$BATS_TEST_TMPDIR/proj"
  refute_contains "$output" "work:"
  refute_contains "$output" "personal:"
  refute_contains "$output" "CLAUDE_CONFIG_DIR"
  local line; line="$(resume_line_from_output)"
  install_claude_stub
  run_resume "$line"
  assert_contains "$output" "dir=[<unset>]"
}

@test "single-profile: one configured profile that IS present still labels the hit" {
  # profiles_on flips on for a single surviving profile, so hits carry its
  # label — and note that a preset dir makes claude-profile's wrapper step
  # fully aside (no launch-time auto-rotation), which is why the all-absent
  # case above must NOT do this.
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR/proj" s1 "term"
  export CCFIND_PROFILES="work:$FIXHOME/.claude personal:$BATS_TEST_TMPDIR/gone"
  run_ccfind -N term
  [ "$status" -eq 0 ]
  assert_contains "$output" "work:$BATS_TEST_TMPDIR/proj"
}

@test "a profile pointing at the default ~/.claude is labelled but never exported" {
  # CLAUDE_CONFIG_DIR is not a no-op when it names the dir claude would have
  # used anyway: it also moves the global .claude.json to
  # $CLAUDE_CONFIG_DIR/.claude.json, a file that has never been onboarded — so
  # exporting the default seat opens the first-run setup wizard instead of the
  # session. Label it, don't export it.
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR/proj" s1 "term"
  export CCFIND_PROFILES="work:$FIXHOME/.claude"
  run_ccfind -N term
  [ "$status" -eq 0 ]
  assert_contains "$output" "work:$BATS_TEST_TMPDIR/proj"
  refute_contains "$output" "CLAUDE_CONFIG_DIR"
  local line; line="$(resume_line_from_output)"
  install_claude_stub
  run_resume "$line"
  [ "$status" -eq 0 ]
  assert_contains "$output" "argv=[--resume s1]"
  assert_contains "$output" "dir=[<unset>]"
}

# --- colour ----------------------------------------------------------------
# The contract is that colour is a display layer only: on when a human is
# looking, gone the moment output is piped — which is what keeps every
# assertion above (and any user's grep) working on plain bytes.

@test "colour is off when stdout is not a terminal" {
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy the widget"
  run_ccfind -N deploy
  [ "$status" -eq 0 ]
  refute_contains "$output" $'\033['
}

@test "CCFIND_COLOR=always emits SGR even when piped" {
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy the widget"
  export CCFIND_COLOR=always
  run_ccfind -N deploy
  [ "$status" -eq 0 ]
  assert_contains "$output" $'\033[32m'   # the resume command is coloured
  assert_contains "$output" "claude --resume s1"
}

@test "the match is highlighted inside the snippet" {
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "before DePlOy after"
  export CCFIND_COLOR=always
  run_ccfind -N deploy
  [ "$status" -eq 0 ]
  # case-insensitive, and the original casing survives the highlighting
  assert_contains "$output" $'\033[1;33m'"DePlOy"$'\033[0m'
}

@test "-C strips the colour even with CCFIND_COLOR=always" {
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy the widget"
  export CCFIND_COLOR=always
  run_ccfind -N -C deploy
  [ "$status" -eq 0 ]
  refute_contains "$output" $'\033['
}

@test "NO_COLOR wins over the auto default" {
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy the widget"
  export NO_COLOR=1
  run_ccfind -N deploy
  [ "$status" -eq 0 ]
  refute_contains "$output" $'\033['
}

@test "an empty result says what was searched" {
  mk_session "$BATS_TEST_TMPDIR/work" "/w/a" w1 "term"
  export CCFIND_PROFILES="work:$BATS_TEST_TMPDIR/work"
  run_ccfind -N zzzznope
  [ "$status" -eq 0 ]
  assert_contains "$output" "No matching sessions."
  assert_contains "$output" 'query "zzzznope"'
  assert_contains "$output" "profiles: work"
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
  assert_contains "$(cat "$FZF_ARGV")" "--with-nth=9"
}

@test "picker rows keep the data fields plain behind the display field" {
  install_fzf_stub
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy the widget"
  export CCFIND_COLOR=always
  run_ccfind -i deploy
  [ "$status" -eq 0 ]
  local row; row="$(head -1 "$FZF_ROWS")"
  # 9 fields: host, profile, cfgdir, id, cwd, ts, snippet, path, display
  [ "$(awk -F'\t' '{print NF}' <<<"$row")" -eq 9 ]
  # the data fields are what the resume and the preview read — no SGR in them,
  # or a host stops matching and a path stops opening.
  [ "$(cut -f1 <<<"$row")" = "local" ]
  [ "$(cut -f2 <<<"$row")" = "" ]          # unconfigured: one nameless profile
  [ "$(cut -f4 <<<"$row")" = "s1" ]
  [ "$(cut -f5 <<<"$row")" = "/proj/a" ]
  assert_contains "$(cut -f8 <<<"$row")" "/projects/-proj-a/s1.jsonl"
  # …while field 9, the one fzf shows, carries the colour and the columns
  assert_contains "$(cut -f9 <<<"$row")" $'\033['
  assert_contains "$(cut -f9 <<<"$row")" "/proj/a"
}

@test "the picker gets one row per hit, newest first" {
  install_fzf_stub
  mk_session "$FIXHOME/.claude" "/proj/old" o1 "term"
  sleep 1
  mk_session "$FIXHOME/.claude" "/proj/new" n1 "term"
  run_ccfind -i term
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$FZF_ROWS")" -eq 2 ]
  assert_contains "$(head -1 "$FZF_ROWS")" "/proj/new"
}

# --- machine-readable output ------------------------------------------------

@test "--json is a well-formed document" {
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy the widget"
  run_ccfind --json deploy
  assert_equal "$status" 0
  run python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["version"], d["total"], len(d["results"]), d["results"][0]["id"], d["results"][0]["cwd"])' <<<"$output"
  assert_equal "$status" 0
  assert_equal "$output" "1 1 1 s1 /proj/a"
}

@test "--json stays well-formed when nothing matched" {
  # The case that matters most for a consumer: "No matching sessions." where a
  # document belongs is indistinguishable from a crash.
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy"
  run_ccfind --json zzzznope
  assert_equal "$status" 0
  run python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["total"], d["results"])' <<<"$output"
  assert_equal "$status" 0
  assert_equal "$output" "0 []"
}

@test "--json escapes quotes and backslashes in a snippet" {
  mk_session "$FIXHOME/.claude" '/proj/a' s1 'deploy a \"quoted\" thing'
  run_ccfind --json deploy
  assert_equal "$status" 0
  # The point is not the exact bytes but that a real parser gets the text back.
  run python3 -c 'import json,sys; d=json.load(sys.stdin); s=d["results"][0]["snippet"]; print("quote" if chr(34) in s else "-", "backslash" if chr(92) in s else "-")' <<<"$output"
  assert_equal "$status" 0
  assert_equal "$output" "quote backslash"
}

@test "--json carries the profile and its config dir" {
  mk_session "$BATS_TEST_TMPDIR/personal" "/p/a" p1 "term"
  export CCFIND_PROFILES="personal:$BATS_TEST_TMPDIR/personal"
  run_ccfind --json term
  run python3 -c 'import json,sys; r=json.load(sys.stdin)["results"][0]; print(r["host"], r["profile"], r["config_dir"])' <<<"$output"
  assert_equal "$output" "local personal $BATS_TEST_TMPDIR/personal"
}

@test "--tsv emits the wire record: epoch first, no host column" {
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy the widget"
  run_ccfind --tsv deploy
  assert_equal "$status" 0
  # epoch, profile, cfgdir, id, cwd, mtime, snippet, path
  assert_equal "$(awk -F'\t' '{print NF}' <<<"$output")" 8
  assert_equal "$(cut -f4 <<<"$output")" "s1"
  assert_equal "$(cut -f5 <<<"$output")" "/proj/a"
}

@test "--tsv prints nothing at all when nothing matched" {
  # The remote worker decides on exit status, but an empty body still has to be
  # empty — a sentence here would be parsed as a record by the caller.
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy"
  run_ccfind --tsv zzzznope
  assert_equal "$status" 0
  assert_equal "$output" ""
}

@test "machine output never opens the picker, even with -i" {
  install_fzf_stub
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy"
  run_ccfind -i --json deploy
  assert_equal "$status" 0
  [ ! -f "$FZF_ROWS" ]
  assert_contains "$output" '"id": "s1"'
}

# --- remote multi-profile ---------------------------------------------------
# These run a REAL ccfind on the far end of the stubbed ssh, so the wire format
# is pinned by both sides of it rather than by a canned fixture.

@test "a remote host running ccfind reports its own profiles" {
  install_ssh_stub_real_host
  mk_session "$REMOTE_HOME/.claude"          "/srv/app"  R1 "remote deploy work"
  mk_session "$REMOTE_HOME/.claude-personal" "/srv/side" R2 "remote deploy personal"
  run_ccfind -H nas -N deploy
  assert_equal "$status" 0
  # Labels the caller has never heard of — they come from the host's own config.
  assert_contains "$output" "nas:rwork:/srv/app"
  assert_contains "$output" "nas:rpersonal:/srv/side"
}

@test "resuming a remote profile hit pins that host's config dir" {
  install_ssh_stub_real_host
  mk_session "$REMOTE_HOME/.claude-personal" "/srv/side" R2 "remote deploy personal"
  run_ccfind -H nas -N deploy
  assert_equal "$status" 0
  assert_contains "$output" "ssh -t nas"
  assert_contains "$output" "CLAUDE_CONFIG_DIR=$REMOTE_HOME/.claude-personal"
  assert_contains "$output" "claude\\ --resume\\ R2"
}

# remote_resume_inner — the command the emitted `ssh -t <host> …` line would
# hand to the shell on the far end, unquoted one layer at a time by the shell
# that quoted it. Lets a test RUN the far-end command under the remote $HOME
# instead of only string-matching the line.
remote_resume_inner() {
  local line rcmd
  line="$(printf '%s\n' "$output" | grep -m1 -- 'ssh -t ')"
  rcmd="$(bash -c "printf '%s' ${line#ssh -t * }")"
  printf '%s' "${rcmd#*-ic }"
}

@test "a remote hit on the host's own default seat is labelled but never exported" {
  # The dir travels with the command, but behind a test the HOST resolves —
  # only it knows what its $HOME is. Naming its default seat would relocate
  # .claude.json to ~/.claude/.claude.json, a file that has never been through
  # onboarding, so the resume would open the setup wizard instead of the
  # session. (rwork is exactly that seat: $REMOTE_HOME/.claude.)
  install_ssh_stub_real_host
  install_claude_stub
  mk_session "$REMOTE_HOME/.claude" "/srv/app" R1 "remote deploy work"
  run_ccfind -H nas -N deploy
  assert_equal "$status" 0
  assert_contains "$output" "nas:rwork:/srv/app"
  local inner; inner="$(remote_resume_inner)"
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" HOME="$REMOTE_HOME" bash -c "eval $inner"
  assert_equal "$status" 0
  assert_contains "$output" "argv=[--resume R1]"
  assert_contains "$output" "dir=[<unset>]"
}

@test "a remote hit on a non-default seat really does export it over there" {
  install_ssh_stub_real_host
  install_claude_stub
  mk_session "$REMOTE_HOME/.claude-personal" "/srv/side" R2 "remote deploy personal"
  run_ccfind -H nas -N deploy
  assert_equal "$status" 0
  local inner; inner="$(remote_resume_inner)"
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" HOME="$REMOTE_HOME" bash -c "eval $inner"
  assert_equal "$status" 0
  assert_contains "$output" "argv=[--resume R2]"
  assert_contains "$output" "dir=[$REMOTE_HOME/.claude-personal]"
}

@test "a remote host without ccfind falls back to ~/.claude, quietly" {
  install_ssh_stub_bare_host
  mk_session "$REMOTE_HOME/.claude"          "/srv/app"  R1 "remote deploy work"
  mk_session "$REMOTE_HOME/.claude-personal" "/srv/side" R2 "remote deploy personal"
  run_ccfind -H nas -N deploy
  assert_equal "$status" 0
  assert_contains "$output" "nas:/srv/app"        # the default seat, unlabelled
  refute_contains "$output" "/srv/side"           # the other seat is invisible
  refute_contains "$output" "no usable ccfind"    # and it says nothing about it
}

@test "-v says which hosts were searched with what" {
  install_ssh_stub_bare_host
  mk_session "$REMOTE_HOME/.claude" "/srv/app" R1 "remote deploy work"
  run_ccfind -H nas -N -v deploy
  assert_equal "$status" 0
  assert_contains "$output" "nas — no usable ccfind"
  assert_contains "$output" "searched ~/.claude only"
}

@test "-v names the ccfind-capable host as such" {
  install_ssh_stub_real_host
  mk_session "$REMOTE_HOME/.claude" "/srv/app" R1 "remote deploy work"
  run_ccfind -H nas -N -v deploy
  assert_contains "$output" "nas — searched with its own ccfind"
}

@test "a host whose own .env names hosts does not fan out again" {
  # A second hop would multiply the search per host, per hop. The far end is
  # told -l explicitly to make that impossible.
  #
  # Asserting on the hop's *name* would be a test with no teeth: --tsv carries
  # no host column, so a hit fetched by the far end comes back attributed to
  # the host we dialled, and "somewhere-else" never appears in the output
  # whatever happens. What a second hop actually produces is the SAME session
  # twice — so count the hits. (Verified by mutation: swapping the far end's
  # -l for -r fails this, and did not fail the name-based version.)
  install_ssh_stub_real_host
  printf 'typeset CCFIND_HOSTS="somewhere-else"\n' >> "$REMOTE_CCFIND_DIR/.env"
  mk_session "$REMOTE_HOME/.claude" "/srv/app" R1 "remote deploy work"
  run_ccfind -H nas -N deploy
  assert_equal "$status" 0
  assert_contains "$output" "/srv/app"
  # one location line per hit: "<mtime>  nas:<cwd>"
  assert_equal "$(grep -c 'nas:' <<<"$output")" 1
}

# --- multi-profile via claude-profile ---------------------------------------
# The second way a machine can be multi-profile: claude-profile manages the
# seats, and listing them again in ccfind's .env would be a copy that drifts.

@test "profiles are discovered from claude-profile when none are configured" {
  install_claude_profile_stub
  mk_session "$FIXHOME/.claude"      "/a/one" D1 "deploy daily"
  mk_session "$FIXHOME/.claude-work" "/a/two" C1 "deploy client"
  run_ccfind -N deploy
  assert_equal "$status" 0
  assert_contains "$output" "daily:/a/one"
  assert_contains "$output" "client:/a/two"
}

@test "a discovered profile resumes into its own config dir" {
  install_claude_profile_stub
  mk_session "$FIXHOME/.claude-work" "/a/two" C1 "deploy client"
  run_ccfind -N deploy
  assert_contains "$output" "CLAUDE_CONFIG_DIR=$FIXHOME/.claude-work claude --resume C1"
}

@test "a discovered profile that IS the default seat resumes without exporting it" {
  # The shape that actually shipped broken: claude-profile reports one seat,
  # `daily -> ~/.claude`, so every hit is labelled and the old rule ("labelled
  # => export") pinned CLAUDE_CONFIG_DIR at the dir claude would have used
  # anyway. That is not a no-op — it moves the global .claude.json to
  # ~/.claude/.claude.json, which has never been onboarded — so every resume
  # opened the first-run setup wizard instead of the session.
  install_claude_profile_stub
  install_claude_stub
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR/proj" D1 "deploy daily"
  run_ccfind -N deploy
  assert_equal "$status" 0
  assert_contains "$output" "daily:$BATS_TEST_TMPDIR/proj"   # still labelled
  refute_contains "$output" "CLAUDE_CONFIG_DIR"
  local line; line="$(resume_line_from_output)"
  run_resume "$line"
  assert_equal "$status" 0
  assert_contains "$output" "argv=[--resume D1]"
  assert_contains "$output" "dir=[<unset>]"
}

@test "a profile dir with a trailing slash is still recognised as the default seat" {
  # ~/.claude/ and ~/.claude are the same seat; only a string compare thinks
  # otherwise, and getting that wrong reopens the setup-wizard bug.
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR/proj" s1 "term"
  export CCFIND_PROFILES="work:$FIXHOME/.claude/"
  run_ccfind -N term
  assert_equal "$status" 0
  assert_contains "$output" "work:$BATS_TEST_TMPDIR/proj"
  refute_contains "$output" "CLAUDE_CONFIG_DIR"
}

@test "CCFIND_PROFILES wins over claude-profile" {
  install_claude_profile_stub
  mk_session "$FIXHOME/.claude"      "/a/one" D1 "deploy daily"
  mk_session "$BATS_TEST_TMPDIR/own" "/a/own" O1 "deploy own"
  export CCFIND_PROFILES="mine:$BATS_TEST_TMPDIR/own"
  run_ccfind -N deploy
  assert_equal "$status" 0
  assert_contains "$output" "mine:/a/own"
  refute_contains "$output" "daily:"        # not consulted at all
}

@test "a claude-profile seat that is absent here is skipped" {
  # The stub names two seats; only one exists. A machine must not invent the
  # other — the same degradation an .env shared across a fleet relies on.
  install_claude_profile_stub
  mk_session "$FIXHOME/.claude" "/a/one" D1 "deploy daily"
  run_ccfind -N deploy
  assert_equal "$status" 0
  assert_contains "$output" "daily:/a/one"
  refute_contains "$output" "client:"
}

@test "-v names where the profiles came from" {
  install_claude_profile_stub
  mk_session "$FIXHOME/.claude" "/a/one" D1 "deploy daily"
  run_ccfind -N -v deploy
  assert_contains "$output" "profiles: claude-profile"
}

@test "a remote host multi-profile via claude-profile reports its seats" {
  # The far end has no CCFIND_PROFILES at all — only claude-profile. The whole
  # chain has to work out there: worker finds ccfind, that ccfind finds
  # claude-profile, and its seats come back tagged with the host.
  install_ssh_stub_real_host
  rm -f "$REMOTE_CCFIND_DIR/.env"                    # no .env: claude-profile only
  install_claude_profile_stub "$BATS_TEST_TMPDIR/bin"
  mk_session "$REMOTE_HOME/.claude"      "/srv/one" R1 "remote deploy daily"
  mk_session "$REMOTE_HOME/.claude-work" "/srv/two" R2 "remote deploy client"
  run_ccfind -H nas -N deploy
  assert_equal "$status" 0
  assert_contains "$output" "nas:daily:/srv/one"
  assert_contains "$output" "nas:client:/srv/two"
  assert_contains "$output" "CLAUDE_CONFIG_DIR=$REMOTE_HOME/.claude-work"
}

# --- tab views (CCFIND_TABS=1) ----------------------------------------------
# The picker's tab bar is built from the pre-cap row list and filtered per view.
# Local profiles and remote hosts match on DIFFERENT fields — (host=local,
# profile=<label>) vs field 1 — which is exactly the sort of thing that breaks
# silently when the record schema changes, and did not have a test before.

@test "tabs: one view per profile and host, All first" {
  install_fzf_stub
  install_ssh_stub_real_host
  mk_session "$BATS_TEST_TMPDIR/work"     "/w/a"    W1 "termx"
  mk_session "$BATS_TEST_TMPDIR/personal" "/p/a"    P1 "termx"
  mk_session "$REMOTE_HOME/.claude"       "/srv/a"  R1 "termx"
  export CCFIND_PROFILES="work:$BATS_TEST_TMPDIR/work personal:$BATS_TEST_TMPDIR/personal"
  export CCFIND_TABS=1
  run_ccfind -i -H nas termx
  assert_equal "$status" 0
  assert_equal "$(cat "$FZF_TABS/views" | tr '\n' ' ')" "All work personal nas "
}

@test "tabs: a profile view holds only that profile's rows" {
  install_fzf_stub
  mk_session "$BATS_TEST_TMPDIR/work"     "/w/a" W1 "termx"
  mk_session "$BATS_TEST_TMPDIR/personal" "/p/a" P1 "termx"
  export CCFIND_PROFILES="work:$BATS_TEST_TMPDIR/work personal:$BATS_TEST_TMPDIR/personal"
  export CCFIND_TABS=1
  run_ccfind -i termx
  assert_equal "$status" 0
  # view-1 is All; 2 and 3 follow the order the profiles are configured in
  assert_equal "$(wc -l < "$FZF_TABS/view-2.rows" | tr -d ' ')" 1
  assert_contains "$(cat "$FZF_TABS/view-2.rows")" "/w/a"
  refute_contains "$(cat "$FZF_TABS/view-2.rows")" "/p/a"
  assert_contains "$(cat "$FZF_TABS/view-3.rows")" "/p/a"
  refute_contains "$(cat "$FZF_TABS/view-3.rows")" "/w/a"
}

@test "tabs: a host view holds every seat on that host" {
  # A host tab is not split by profile: it is that machine, whatever seats it
  # turned out to have.
  install_fzf_stub
  install_ssh_stub_real_host
  mk_session "$REMOTE_HOME/.claude"          "/srv/one" R1 "termx"
  mk_session "$REMOTE_HOME/.claude-personal" "/srv/two" R2 "termx"
  export CCFIND_TABS=1
  run_ccfind -i -H nas termx
  assert_equal "$status" 0
  assert_equal "$(cat "$FZF_TABS/views" | tr '\n' ' ')" "All nas "
  assert_contains "$(cat "$FZF_TABS/view-2.rows")" "/srv/one"
  assert_contains "$(cat "$FZF_TABS/view-2.rows")" "/srv/two"
}

@test "tabs: no tab for a profile with no hits" {
  install_fzf_stub
  mkdir -p "$BATS_TEST_TMPDIR/personal/projects"      # configured, but nothing matches
  mk_session "$BATS_TEST_TMPDIR/work" "/w/a" W1 "termx"
  export CCFIND_PROFILES="work:$BATS_TEST_TMPDIR/work personal:$BATS_TEST_TMPDIR/personal"
  export CCFIND_TABS=1
  run_ccfind -i termx
  assert_equal "$(cat "$FZF_TABS/views" | tr '\n' ' ')" "All work "
}

@test "tabs: unset means no tab machinery at all" {
  install_fzf_stub
  mk_session "$BATS_TEST_TMPDIR/work"     "/w/a" W1 "termx"
  mk_session "$BATS_TEST_TMPDIR/personal" "/p/a" P1 "termx"
  export CCFIND_PROFILES="work:$BATS_TEST_TMPDIR/work personal:$BATS_TEST_TMPDIR/personal"
  run_ccfind -i termx
  assert_equal "$status" 0
  [ ! -d "$FZF_TABS" ]
  refute_contains "$(cat "$FZF_ARGV")" "tab:transform"
}

# --- the preview pane -------------------------------------------------------
# Rendered into fzf's pane rather than to stdout, so it colours unconditionally
# (the -t 1 rule the rest of the tool follows would switch it off exactly where
# it is wanted) and had no coverage at all until now.

@test "preview renders the last messages with role labels" {
  mk_transcript "$FIXHOME/t.jsonl" \
    "the deploy fails" "check the pooler port" "ok trying"
  run_preview local "$FIXHOME/t.jsonl"
  assert_equal "$status" 0
  assert_contains "$output" "USER"
  assert_contains "$output" "ASSISTANT"
  assert_contains "$output" "check the pooler port"
}

@test "preview highlights the search term" {
  mk_transcript "$FIXHOME/t.jsonl" "the deploy is DePlOyed twice"
  run_preview local "$FIXHOME/t.jsonl" "deploy"
  # case-insensitive, original casing preserved, in the same colour the list uses
  assert_contains "$output" $'\033[1;33mdeploy\033[0m'
  assert_contains "$output" $'\033[1;33mDePlOy\033[0m'
}

@test "preview says how much of the session it is showing" {
  local -a msgs; local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do msgs+=("message $i"); done
  mk_transcript "$FIXHOME/t.jsonl" "${msgs[@]}"
  run_preview local "$FIXHOME/t.jsonl"
  assert_contains "$output" "last 8 of 12 messages"
  assert_contains "$output" "message 12"
  refute_contains "$output" "message 3"      # older than the window
}

@test "preview honours NO_COLOR" {
  mk_transcript "$FIXHOME/t.jsonl" "the deploy fails"
  run env HOME="$FIXHOME" NO_COLOR=1 CCFIND_PV_QUERY="deploy" \
      zsh -fc 'src=$1; shift; source "$src"; _ccfind_preview "$@"' _ "$CCFIND_ZSH" \
      local "$FIXHOME/t.jsonl"
  assert_equal "$status" 0
  assert_contains "$output" "the deploy fails"
  refute_contains "$output" $'\033['
}

@test "preview reduces tool calls rather than dumping them" {
  printf '%s\n' \
    '{"type":"user","message":{"role":"user","content":"run it"}}' \
    '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"on it"},{"type":"tool_use","name":"Bash"},{"type":"thinking","thinking":"secret reasoning"}]}}' \
    > "$FIXHOME/t.jsonl"
  run_preview local "$FIXHOME/t.jsonl"
  assert_contains "$output" "[tool: Bash]"
  refute_contains "$output" "secret reasoning"     # thinking blocks are omitted
}

@test "preview of a remote hit fetches over ssh and caches it" {
  install_ssh_stub_real_host
  mk_transcript "$REMOTE_HOME/t.jsonl" "remote side conversation"
  run env HOME="$FIXHOME" CCFIND_PV_CACHE="$BATS_TEST_TMPDIR/pv" \
      CCFIND_LOCAL_LABELS="local" CCFIND_PV_QUERY="" \
      REMOTE_HOME="$REMOTE_HOME" REMOTE_CCFIND_DIR="$REMOTE_CCFIND_DIR" \
      zsh -fc 'mkdir -p "$CCFIND_PV_CACHE"; src=$1; shift; source "$src"; _ccfind_preview "$@"' \
      _ "$CCFIND_ZSH" nas "$REMOTE_HOME/t.jsonl"
  assert_equal "$status" 0
  assert_contains "$output" "remote side conversation"
  assert_contains "$output" "nas"                       # labelled with its host
  [ -s "$BATS_TEST_TMPDIR/pv/ccfind-pv-nas-t.jsonl" ]   # and cached for the toggle
}

@test "preview says so rather than failing when a file is unreadable" {
  run_preview local "$FIXHOME/does-not-exist.jsonl"
  assert_equal "$status" 0
  assert_contains "$output" "cannot read"
}

# --- the remote protocol's edges --------------------------------------------

@test "a remote ccfind too old for --tsv falls back instead of erroring" {
  # Version skew is a live scenario in a fleet that updates at different times:
  # the old ccfind rejects the flag and exits non-zero, and that has to land in
  # the same fallback as having no ccfind at all.
  install_ssh_stub_real_host
  cat > "$REMOTE_CCFIND_DIR/ccfind.zsh" <<'OLD'
# an older ccfind: knows nothing about --tsv
function ccfind() { print -u2 "ccfind: unknown option $1"; return 2 }
OLD
  mk_session "$REMOTE_HOME/.claude" "/srv/app" R1 "termx"
  run_ccfind -H nas -N -v termx
  assert_equal "$status" 0
  assert_contains "$output" "no usable ccfind (incompatible)"
  assert_contains "$output" "nas:/srv/app"        # still searched, the old way
}

@test "the caller's CCFIND_* does not follow the search onto a host" {
  # Regression: an exported CCFIND_PROFILES reached the remote invocation, so
  # the host searched the CALLER's profile directories and reported them under
  # its own name. Real ssh forwards nothing, but a transport that does must not
  # be able to reintroduce it.
  install_ssh_stub_real_host
  mk_session "$BATS_TEST_TMPDIR/local-only" "/only/here" L1 "termx"
  mk_session "$REMOTE_HOME/.claude"         "/srv/app"   R1 "termx"
  export CCFIND_PROFILES="sneaky:$BATS_TEST_TMPDIR/local-only"
  run_ccfind -H nas -N termx
  assert_equal "$status" 0
  assert_contains "$output" "nas:rwork:/srv/app"    # the host's own seat, its own label
  refute_contains "$output" "nas:sneaky"            # never the caller's
  refute_contains "$output" "nas:/only/here"
}

@test "-d scopes the remote search too" {
  install_ssh_stub_real_host
  mk_session "$REMOTE_HOME/.claude" "/srv/keep"  K1 "termx"
  mk_session "$REMOTE_HOME/.claude" "/srv/other" O1 "termx"
  run_ccfind -H nas -N -d /srv/keep termx
  assert_equal "$status" 0
  assert_contains "$output" "/srv/keep"
  refute_contains "$output" "/srv/other"
}

@test "-x scopes the remote search too" {
  install_ssh_stub_real_host
  mk_session "$REMOTE_HOME/.claude" "/srv/keep"     K1 "termx"
  mk_session "$REMOTE_HOME/.claude" "/srv/keep/sub" S1 "termx"
  run_ccfind -H nas -N -x -d /srv/keep termx
  assert_equal "$status" 0
  assert_contains "$output" "/srv/keep"
  refute_contains "$output" "/srv/keep/sub"
}

@test "-x narrows on a host whose ccfind is too old for the flag" {
  # The stub host answers from the worker's own fallback path (no ccfind
  # there at all), which is the same code an old ccfind degrades into.
  install_ssh_stub_real_host
  rm -f "$REMOTE_CCFIND_DIR/ccfind.zsh"
  mk_session "$REMOTE_HOME/.claude" "/srv/keep"     K1 "termx"
  mk_session "$REMOTE_HOME/.claude" "/srv/keep/sub" S1 "termx"
  run_ccfind -H nas -N -x -d /srv/keep termx
  assert_equal "$status" 0
  assert_contains "$output" "/srv/keep"
  refute_contains "$output" "/srv/keep/sub"
}

@test "--json reports a remote hit with its host and remote config dir" {
  install_ssh_stub_real_host
  mk_session "$REMOTE_HOME/.claude-personal" "/srv/side" R2 "termx"
  run_ccfind -H nas --json termx
  assert_equal "$status" 0
  run python3 -c 'import json,sys; r=json.load(sys.stdin)["results"][0]; print(r["host"], r["profile"], r["config_dir"], r["cwd"])' <<<"$output"
  assert_equal "$status" 0
  assert_equal "$output" "nas rpersonal $REMOTE_HOME/.claude-personal /srv/side"
}

@test "CCFIND_PROFILE_CMD overrides how the profile list is obtained" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/my-profiles" <<STUB
#!/bin/sh
[ "\$1" = list ] || exit 2
printf 'custom\t$BATS_TEST_TMPDIR/custom\n'
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/my-profiles"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export CCFIND_PROFILE_CMD="my-profiles"
  mk_session "$BATS_TEST_TMPDIR/custom" "/c/a" C1 "termx"
  run_ccfind -N termx
  assert_equal "$status" 0
  assert_contains "$output" "custom:/c/a"
}

# --- what the picker's display column actually shows ------------------------

@test "the display column contracts \$HOME but the resume keeps the full path" {
  install_fzf_stub
  mkdir -p "$FIXHOME/code/app"
  mk_session "$FIXHOME/.claude" "$FIXHOME/code/app" S1 "termx"
  run_ccfind -i termx
  assert_equal "$status" 0
  local row; row="$(head -1 "$FZF_ROWS")"
  assert_contains "$(cut -f9 <<<"$row")" "~/code/app"      # what you read
  assert_equal    "$(cut -f5 <<<"$row")" "$FIXHOME/code/app"   # what it cds to
}

@test "the display column leads with the match, not with 45 characters of JSON" {
  install_fzf_stub
  # The snippet arrives centred on the match with a long lead-in; in the last
  # column that lead is usually all that fits, so it is pulled forward.
  mk_session "$FIXHOME/.claude" "/proj/a" S1 \
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa NEEDLE bbbb"
  export CCFIND_COLOR=always
  run_ccfind -i NEEDLE
  assert_equal "$status" 0
  local disp; disp="$(cut -f9 < "$FZF_ROWS")"
  assert_contains "$disp" "…"                     # the lead-in was cut
  # the match sits within ~14 characters of where the snippet column starts
  run python3 -c '
import re, sys
d = re.sub(r"\033\[[0-9;]*m", "", sys.stdin.read())
lead = d.index("NEEDLE") - d.index("…")
print("close" if 0 < lead <= 14 else f"far:{lead}")' <<<"$disp"
  assert_equal "$output" "close"
}

# --- Enter: the picker's resume branch --------------------------------------
# The cancelling fzf stub never gets here. This one selects, so the real branch
# runs: parse the row, cd, and hand off to claude — locally or over ssh.

@test "Enter on a local hit cds there and resumes it" {
  install_fzf_stub_select
  install_claude_stub
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR/proj" S1 "termx"
  run_ccfind -i termx
  assert_equal "$status" 0
  assert_contains "$output" "argv=[--resume S1]"
  assert_contains "$output" "pwd=[$BATS_TEST_TMPDIR/proj]"
  assert_contains "$output" "dir=[<unset>]"        # unconfigured: nothing pinned
}

@test "Enter on a profile hit resumes into that profile's seat" {
  install_fzf_stub_select
  install_claude_stub
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  mk_session "$BATS_TEST_TMPDIR/personal" "$BATS_TEST_TMPDIR/proj" P1 "termx"
  export CCFIND_PROFILES="personal:$BATS_TEST_TMPDIR/personal"
  run_ccfind -i termx
  assert_equal "$status" 0
  assert_contains "$output" "argv=[--resume P1]"
  assert_contains "$output" "dir=[$BATS_TEST_TMPDIR/personal]"
}

@test "Enter on a profile hit whose seat is the default sets nothing" {
  # The picker builds its resume separately from the flat list, and the picker
  # is how this is reached in practice — so the default-seat rule is pinned at
  # BOTH call sites, not just the one that prints a line.
  install_fzf_stub_select
  install_claude_stub
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR/proj" P1 "termx"
  export CCFIND_PROFILES="personal:$FIXHOME/.claude"
  run_ccfind -i termx
  assert_equal "$status" 0
  assert_contains "$output" "argv=[--resume P1]"
  assert_contains "$output" "dir=[<unset>]"
}

@test "Enter on a remote hit goes over ssh with that host's seat" {
  # The row's own config dir travels with it, so the far end opens the seat the
  # session belongs to rather than whatever that host defaults to.
  install_fzf_stub_select
  install_ssh_stub_real_host
  mk_session "$REMOTE_HOME/.claude-personal" "/srv/side" R2 "termx"
  run_ccfind -i -H nas termx
  assert_equal "$status" 0
  local log; log="$(cat "$SSH_LOG")"
  assert_contains "$log" "-t nas"
  assert_contains "$log" "cd /srv/side"
  # the seat the hit belongs to on THAT machine, which is the whole point
  assert_contains "$log" "CLAUDE_CONFIG_DIR=$REMOTE_HOME/.claude-personal"
  assert_contains "$log" "claude"
}

@test "Enter refuses when the session's directory is gone" {
  install_fzf_stub_select
  install_claude_stub
  mk_session "$FIXHOME/.claude" "/vanished/dir" S1 "termx"
  run_ccfind -i termx
  assert_equal "$status" 1
  assert_contains "$output" "no longer exists"
  refute_contains "$output" "argv="              # and claude is never reached
}

# --- Tab: what the binding computes -----------------------------------------
# fzf's own redraw is fzf's business; what ccfind owns is the action string it
# hands back, and which view is next. Both are plain functions over a state dir.

@test "tab_shift advances the view and emits fzf's action chain" {
  mk_tabsdir "$BATS_TEST_TMPDIR/tabs" All work nas
  run env zsh -fc 'source "$1"; _ccfind_tab_shift "$2" 1' _ "$CCFIND_ZSH" "$BATS_TEST_TMPDIR/tabs"
  assert_equal "$status" 0
  assert_contains "$output" "reload(cat -- $BATS_TEST_TMPDIR/tabs/view-2.rows)"
  assert_contains "$output" "change-header{"
  assert_contains "$output" "+first"
  assert_equal "$(cat "$BATS_TEST_TMPDIR/tabs/cur")" 2
}

@test "tab_shift wraps around in both directions" {
  mk_tabsdir "$BATS_TEST_TMPDIR/tabs" All work nas
  # backwards from the first view lands on the last
  run env zsh -fc 'source "$1"; _ccfind_tab_shift "$2" -1' _ "$CCFIND_ZSH" "$BATS_TEST_TMPDIR/tabs"
  assert_equal "$(cat "$BATS_TEST_TMPDIR/tabs/cur")" 3
  # and forwards from the last comes back to the first
  run env zsh -fc 'source "$1"; _ccfind_tab_shift "$2" 1' _ "$CCFIND_ZSH" "$BATS_TEST_TMPDIR/tabs"
  assert_equal "$(cat "$BATS_TEST_TMPDIR/tabs/cur")" 1
}

@test "tab_header marks the current view and keeps the key hints" {
  mk_tabsdir "$BATS_TEST_TMPDIR/tabs" All work nas
  echo 2 > "$BATS_TEST_TMPDIR/tabs/cur"
  run env zsh -fc 'source "$1"; _ccfind_tab_header "$2"' _ "$CCFIND_ZSH" "$BATS_TEST_TMPDIR/tabs"
  assert_equal "$status" 0
  assert_contains "$output" $'\033[1;7m work \033[0m'   # current: reverse video
  assert_contains "$output" $'\033[2m All \033[0m'      # the others: dimmed
  assert_contains "$output" "keys here"
}

@test "a stale ccfind at an earlier path does not shadow a working one" {
  # Found on a real host: a pre-split clone at ~/ccfind sat ahead of the current
  # one at ~/.zsh/ccfind in the search order, rejected --tsv, and took the whole
  # machine down to the filesystem walk — reported as "incompatible" while a
  # perfectly good ccfind sat one path further down.
  install_ssh_stub_real_host
  rm -rf "$REMOTE_CCFIND_DIR"                     # no CCFIND_REMOTE_PATH hint
  mkdir -p "$REMOTE_HOME/ccfind" "$REMOTE_HOME/.zsh/ccfind"
  cat > "$REMOTE_HOME/ccfind/ccfind.zsh" <<'STALE'
# a clone from before --tsv existed
function ccfind() { print -u2 "ccfind: unknown option $1"; return 2 }
STALE
  cp "$CCFIND_SRC" "$REMOTE_HOME/.zsh/ccfind/ccfind.zsh"
  cat > "$REMOTE_HOME/.zsh/ccfind/.env" <<ENV
typeset CCFIND_PROFILES="rwork:$REMOTE_HOME/.claude"
ENV
  mk_session "$REMOTE_HOME/.claude" "/srv/app" R1 "termx"
  run_ccfind -H nas -N -v termx
  assert_equal "$status" 0
  assert_contains "$output" "searched with its own ccfind"   # the later path answered
  assert_contains "$output" "nas:rwork:/srv/app"             # under the host's own label
  refute_contains "$output" "incompatible"
}

@test "incompatible means every candidate was tried" {
  # Both paths hold something too old, so there is genuinely nothing to talk to.
  install_ssh_stub_real_host
  rm -rf "$REMOTE_CCFIND_DIR"
  mkdir -p "$REMOTE_HOME/ccfind" "$REMOTE_HOME/.zsh/ccfind"
  local d
  for d in "$REMOTE_HOME/ccfind" "$REMOTE_HOME/.zsh/ccfind"; do
    cat > "$d/ccfind.zsh" <<'STALE'
function ccfind() { print -u2 "ccfind: unknown option $1"; return 2 }
STALE
  done
  mk_session "$REMOTE_HOME/.claude" "/srv/app" R1 "termx"
  run_ccfind -H nas -N -v termx
  assert_equal "$status" 0
  assert_contains "$output" "no usable ccfind (incompatible)"
  assert_contains "$output" "nas:/srv/app"        # still searched, the old way
}

# --- the setup wizard, at the level a human notices it ----------------------
# Everything above asserts the MECHANISM (whether CLAUDE_CONFIG_DIR is set).
# These assert the SYMPTOM: whether the launched claude would find an onboarded
# global config or drop the user into the first-run theme picker. The fixture
# models a real machine's layout — ~/.claude.json beside ~/.claude, nothing
# inside ~/.claude — so the wizard is reachable in the suite without any real
# file being read or written.

@test "the fixture really can detect the wizard (negative control)" {
  # Guards the guard: if this ever stops failing, every RESUMED assertion below
  # has become vacuous and the suite is testing nothing.
  install_claude_stub
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" HOME="$FIXHOME" \
      CLAUDE_CONFIG_DIR="$FIXHOME/.claude" claude --resume X1
  assert_contains "$output" "config=[$FIXHOME/.claude/.claude.json]"
  assert_contains "$output" "verdict=[SETUP-WIZARD]"
}

@test "the same launch without the variable finds the real config (control)" {
  install_claude_stub
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" HOME="$FIXHOME" claude --resume X1
  assert_contains "$output" "config=[$FIXHOME/.claude.json]"
  assert_contains "$output" "verdict=[RESUMED]"
}

@test "resuming a default-seat hit lands in the session, not the setup wizard" {
  install_claude_profile_stub          # reports daily -> ~/.claude, the field shape
  install_claude_stub
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR/proj" D1 "deploy daily"
  run_ccfind -N deploy
  assert_equal "$status" 0
  local line; line="$(resume_line_from_output)"
  run_resume "$line"
  assert_equal "$status" 0
  assert_contains "$output" "argv=[--resume D1]"
  assert_contains "$output" "config=[$FIXHOME/.claude.json]"
  assert_contains "$output" "verdict=[RESUMED]"
}

@test "Enter in the picker on a default-seat hit lands in the session too" {
  install_fzf_stub_select
  install_claude_stub
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR/proj" P1 "termx"
  export CCFIND_PROFILES="personal:$FIXHOME/.claude"
  run_ccfind -i termx
  assert_equal "$status" 0
  assert_contains "$output" "argv=[--resume P1]"
  assert_contains "$output" "verdict=[RESUMED]"
}

@test "a genuine alternate seat resumes into its own onboarded config" {
  # The other half of the contract: not exporting the default seat must not
  # cost a real second seat its routing.
  install_claude_stub
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  mk_session "$BATS_TEST_TMPDIR/personal" "$BATS_TEST_TMPDIR/proj" P2 "termx"
  export CCFIND_PROFILES="personal:$BATS_TEST_TMPDIR/personal"
  run_ccfind -N termx
  local line; line="$(resume_line_from_output)"
  run_resume "$line"
  assert_equal "$status" 0
  assert_contains "$output" "config=[$BATS_TEST_TMPDIR/personal/.claude.json]"
  assert_contains "$output" "verdict=[RESUMED]"
}

@test "a remote default-seat hit lands in the session on the far end" {
  install_ssh_stub_real_host
  install_claude_stub
  mk_session "$REMOTE_HOME/.claude" "/srv/app" R1 "remote deploy work"
  run_ccfind -H nas -N deploy
  assert_equal "$status" 0
  local inner; inner="$(remote_resume_inner)"
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" HOME="$REMOTE_HOME" bash -c "eval $inner"
  assert_equal "$status" 0
  assert_contains "$output" "config=[$REMOTE_HOME/.claude.json]"
  assert_contains "$output" "verdict=[RESUMED]"
}

# --- the harness itself -----------------------------------------------------
# The stubs shadow real commands on PATH, so a stub quietly replacing another
# stub means a test exercises something it never asked for — and the assertion
# that then fails points at ccfind rather than at the harness.

@test "a second stub of the same name is a hard failure, not a silent overwrite" {
  install_fzf_stub                       # the cancelling fzf claims the name
  run install_fzf_stub_select            # the selecting one wants the same name
  assert_equal "$status" 1
  assert_contains "$output" "stub conflict"
  assert_contains "$output" "fzf"
  # ...and the first stub is still the one on PATH, unmodified: it cancels (130)
  # rather than selecting (0), which is what the conflicting stub would have done.
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash -c 'echo row | fzf'
  assert_equal "$status" 130
}

@test "the two ssh stubs cannot both claim the name either" {
  install_ssh_stub
  run install_ssh_stub_real_host
  assert_equal "$status" 1
  assert_contains "$output" "stub conflict"
  assert_contains "$output" "ssh"
}

@test "installing several different stubs puts the fake bin on PATH exactly once" {
  install_claude_stub
  install_fzf_stub
  install_claude_profile_stub
  local n; n="$(printf '%s' "$PATH" | tr ':' '\n' | grep -cxF "$BATS_TEST_TMPDIR/bin")"
  assert_equal "$n" "1"
}
