#!/usr/bin/env bats
# Behavioral suite for ccfind. Focus: the local search + profile logic, which is
# fully exercisable without fzf/ssh/TTY via the flat-list path (CCFIND_INTERACTIVE=0).
load helpers

setup() { ccfind_setup; }

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
  assert_contains "$output" "work:$BATS_TEST_TMPDIR/proj"
  assert_contains "$output" "CLAUDE_CONFIG_DIR=$FIXHOME/.claude claude --resume s1"
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
