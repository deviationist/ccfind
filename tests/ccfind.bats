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

# --- case matching: -s / -I / -S and CCFIND_CASE ----------------------------
# Two sessions differing ONLY in the casing of the search term is the whole
# fixture: every mode below is a statement about which of the two comes back,
# so a mode that silently does nothing shows up as the wrong count, not as a
# passing test. mk_case_pair keeps that pair honest in one place.

mk_case_pair() {   # <config-dir>
  mk_session "$1" "/proj/upper" u1 "the FooBar widget"
  mk_session "$1" "/proj/lower" l1 "the foobar widget"
}

@test "case: the default folds case, as it always has" {
  mk_case_pair "$FIXHOME/.claude"
  run_ccfind -N FooBar
  assert_equal "$status" 0
  assert_contains "$output" "/proj/upper"
  assert_contains "$output" "/proj/lower"
}

@test "case: -s matches the query's own casing only" {
  mk_case_pair "$FIXHOME/.claude"
  run_ccfind -N -s FooBar
  assert_equal "$status" 0
  assert_contains "$output" "/proj/upper"
  refute_contains "$output" "/proj/lower"
}

@test "case: -s with a lowercase query skips the capitalised hit" {
  # The mirror image of the test above. Without it, a -s that quietly matched
  # everything-lowercase would still look right from the other direction.
  mk_case_pair "$FIXHOME/.claude"
  run_ccfind -N -s foobar
  assert_equal "$status" 0
  assert_contains "$output" "/proj/lower"
  refute_contains "$output" "/proj/upper"
}

@test "case: --case-sensitive is the long spelling of -s" {
  mk_case_pair "$FIXHOME/.claude"
  run_ccfind -N --case-sensitive FooBar
  assert_equal "$status" 0
  refute_contains "$output" "/proj/lower"
}

@test "case: -S is smart — a capital in the query makes case matter" {
  mk_case_pair "$FIXHOME/.claude"
  run_ccfind -N -S FooBar
  assert_equal "$status" 0
  assert_contains "$output" "/proj/upper"
  refute_contains "$output" "/proj/lower"
}

@test "case: -S on an all-lowercase query still folds" {
  mk_case_pair "$FIXHOME/.claude"
  run_ccfind -N -S foobar
  assert_equal "$status" 0
  assert_contains "$output" "/proj/upper"
  assert_contains "$output" "/proj/lower"
}

@test "case: smart reads only the query, never the transcript" {
  # A capital in the HAYSTACK must not make the search sensitive — only a
  # capital the user typed. Searching lowercase against a capitalised-only
  # corpus is exactly where the two readings diverge.
  mk_session "$FIXHOME/.claude" "/proj/upper" u1 "the FooBar widget"
  run_ccfind -N -S foobar
  assert_equal "$status" 0
  assert_contains "$output" "/proj/upper"
}

@test "case: a query with no ASCII letters is never smart-sensitive" {
  # "Has a capital" is the ASCII test, so a query that expresses no case at all
  # — an id, a path, a non-Latin script — has to land on folding rather than on
  # whatever the locale would have said about its bytes.
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "id 12-34 Ünïcödé here"
  run_ccfind -N -S "12-34"
  assert_equal "$status" 0
  assert_contains "$output" "/proj/a"
}

@test "case: CCFIND_CASE=sensitive sets the default for every call" {
  export CCFIND_CASE=sensitive
  mk_case_pair "$FIXHOME/.claude"
  run_ccfind -N FooBar
  assert_equal "$status" 0
  refute_contains "$output" "/proj/lower"
}

@test "case: -I overrides a sensitive default back to folding" {
  export CCFIND_CASE=sensitive
  mk_case_pair "$FIXHOME/.claude"
  run_ccfind -N -I FooBar
  assert_equal "$status" 0
  assert_contains "$output" "/proj/lower"
}

@test "case: -s overrides an insensitive default" {
  export CCFIND_CASE=insensitive
  mk_case_pair "$FIXHOME/.claude"
  run_ccfind -N -s FooBar
  assert_equal "$status" 0
  refute_contains "$output" "/proj/lower"
}

@test "case: CCFIND_CASE can be set in the .env beside the script" {
  printf 'typeset CCFIND_CASE="smart"\n' > "${CCFIND_ZSH%/*}/.env"
  mk_case_pair "$FIXHOME/.claude"
  run_ccfind -N FooBar
  assert_equal "$status" 0
  refute_contains "$output" "/proj/lower"
}

@test "case: an exported CCFIND_CASE wins over the .env" {
  printf 'typeset CCFIND_CASE="sensitive"\n' > "${CCFIND_ZSH%/*}/.env"
  export CCFIND_CASE=insensitive
  mk_case_pair "$FIXHOME/.claude"
  run_ccfind -N FooBar
  assert_equal "$status" 0
  assert_contains "$output" "/proj/lower"
}

@test "case: an unknown CCFIND_CASE says so instead of being ignored" {
  export CCFIND_CASE=yes
  mk_case_pair "$FIXHOME/.claude"
  run_ccfind -N FooBar
  assert_equal "$status" 0
  assert_contains "$output" "not one of sensitive|insensitive|smart"
  assert_contains "$output" "/proj/lower"      # and the fallback really does fold
}

@test "case: the highlight marks only what the search matched" {
  # One line carrying both casings: under -s exactly one of them is the hit, so
  # a highlighter still folding case would light up all three occurrences.
  export CCFIND_COLOR=always
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "first foobar then FooBar then foobar"
  run_ccfind -N -s FooBar
  assert_equal "$status" 0
  assert_contains "$output" $'\033[1;33mFooBar\033[0m'
  refute_contains "$output" $'\033[1;33mfoobar\033[0m'
}

@test "case: the snippet window is pulled to the occurrence that matched" {
  # The snippet is a 120-char window cut around the match, located by a second
  # pass that has to agree with the grep about what "the match" is. On a line
  # holding both casings far apart, a window still folding case would centre on
  # the earlier lowercase one and show nothing of what -s actually hit.
  local far
  far="$(printf 'x%.0s' {1..300})"
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "lead foobar ${far} tail FooBar end"
  run_ccfind -N -s FooBar
  assert_equal "$status" 0
  assert_contains "$output" "FooBar"
  refute_contains "$output" "lead foobar"
}

@test "case: -I and -S have long spellings too" {
  export CCFIND_CASE=sensitive
  mk_case_pair "$FIXHOME/.claude"
  run_ccfind -N --ignore-case FooBar
  assert_equal "$status" 0
  assert_contains "$output" "/proj/lower"
  run_ccfind -N --smart-case FooBar
  assert_equal "$status" 0
  refute_contains "$output" "/proj/lower"
}

@test "case: an empty result names case-sensitivity as a reason it might be" {
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "the foobar widget"
  run_ccfind -N -s FooBar
  assert_equal "$status" 0
  assert_contains "$output" "No matching sessions."
  assert_contains "$output" "case-sensitive"
}

@test "case: an insensitive empty result does not mention case at all" {
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "the foobar widget"
  run_ccfind -N zzzznope
  assert_equal "$status" 0
  refute_contains "$output" "case-sensitive"
}

@test "case: --json reports the resolved boolean and the mode it came from" {
  mk_case_pair "$FIXHOME/.claude"
  run_ccfind --json -S FooBar
  assert_equal "$status" 0
  run python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["case_sensitive"], d["case_mode"], d["total"])' <<<"$output"
  assert_equal "$status" 0
  assert_equal "$output" "True smart 1"
}

@test "case: --json says false for the default fold" {
  mk_case_pair "$FIXHOME/.claude"
  run_ccfind --json FooBar
  assert_equal "$status" 0
  run python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["case_sensitive"], d["case_mode"], d["total"])' <<<"$output"
  assert_equal "$status" 0
  assert_equal "$output" "False insensitive 2"
}

@test "case: -v names the resolved sensitivity and the mode behind it" {
  mk_case_pair "$FIXHOME/.claude"
  run_ccfind -N -v -S FooBar
  assert_equal "$status" 0
  assert_contains "$output" "case: sensitive (mode: smart)"
}

@test "case: -s scopes the remote search too" {
  install_ssh_stub_real_host
  mk_session "$REMOTE_HOME/.claude" "/srv/upper" U1 "the FooBar widget"
  mk_session "$REMOTE_HOME/.claude" "/srv/lower" L1 "the foobar widget"
  run_ccfind -H nas -N -s FooBar
  assert_equal "$status" 0
  assert_contains "$output" "/srv/upper"
  refute_contains "$output" "/srv/lower"
}

@test "case: smart resolves once, on the caller, before any host is dialled" {
  # The host is told sensitive-or-not, never "smart" — otherwise a fan-out
  # would depend on each host agreeing about what the query looks like.
  install_ssh_stub_real_host
  mk_session "$REMOTE_HOME/.claude" "/srv/upper" U1 "the FooBar widget"
  mk_session "$REMOTE_HOME/.claude" "/srv/lower" L1 "the foobar widget"
  run_ccfind -H nas -N -S FooBar
  assert_equal "$status" 0
  assert_contains "$output" "/srv/upper"
  refute_contains "$output" "/srv/lower"
  assert_contains "$(cat "$SSH_LOG")" " -s "
}

@test "case: the worker's own filesystem walk matches case too" {
  # A host with no ccfind at all is searched by the walk inside the worker
  # script, which has its own grep and so its own chance to ignore the flag.
  install_ssh_stub_bare_host
  mk_session "$REMOTE_HOME/.claude" "/srv/upper" U1 "the FooBar widget"
  mk_session "$REMOTE_HOME/.claude" "/srv/lower" L1 "the foobar widget"
  run_ccfind -H nas -N -s FooBar
  assert_equal "$status" 0
  assert_contains "$output" "/srv/upper"
  refute_contains "$output" "/srv/lower"
}

@test "case: -s narrows on a host whose ccfind is too old for the flag" {
  # Version skew, from the one direction that can give a WRONG answer rather
  # than a thin one: a ccfind new enough for --tsv but predating -s would fold
  # the query and hand back hits the caller did not ask for. Passing -s is what
  # makes it reject the call instead, dropping the host to the worker's own
  # walk — which matches case itself. So the host narrows, or it falls back;
  # what it must never do is answer the wrong question successfully.
  install_ssh_stub_real_host
  cat > "$REMOTE_CCFIND_DIR/ccfind.zsh" <<'OLD'
# a ccfind that knows --tsv but not -s, and therefore always folds case
function ccfind() {
  local a
  for a in "$@"; do
    [[ "$a" == -s ]] && { print -u2 "ccfind: unknown option -s"; return 2 }
  done
  local d="$HOME/.claude"
  printf '1700000000\t\t%s\tU1\t/srv/upper\t2024-01-01 12:00:00\tthe FooBar widget\t%s\n' \
    "$d" "$d/projects/-srv-upper/U1.jsonl"
  printf '1700000000\t\t%s\tL1\t/srv/lower\t2024-01-01 12:00:00\tthe foobar widget\t%s\n' \
    "$d" "$d/projects/-srv-lower/L1.jsonl"
}
OLD
  mk_session "$REMOTE_HOME/.claude" "/srv/upper" U1 "the FooBar widget"
  mk_session "$REMOTE_HOME/.claude" "/srv/lower" L1 "the foobar widget"
  run_ccfind -H nas -N -s FooBar
  assert_equal "$status" 0
  assert_contains "$output" "/srv/upper"
  refute_contains "$output" "/srv/lower"
}

@test "case: a host's own CCFIND_CASE does not override the caller's" {
  # The rest of the host's config is exactly what a remote search wants — its
  # profiles are the reason to ask it at all — but the QUESTION is the caller's.
  # A host defaulting to sensitive must not answer a folded search sensitively.
  install_ssh_stub_real_host
  printf 'typeset CCFIND_CASE="sensitive"\n' >> "$REMOTE_CCFIND_DIR/.env"
  mk_session "$REMOTE_HOME/.claude" "/srv/upper" U1 "the FooBar widget"
  mk_session "$REMOTE_HOME/.claude" "/srv/lower" L1 "the foobar widget"
  run_ccfind -H nas -N FooBar
  assert_equal "$status" 0
  assert_contains "$output" "/srv/upper"
  assert_contains "$output" "/srv/lower"
}

@test "case: the preview highlights only the casing the search matched" {
  export CCFIND_COLOR=always
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "x"
  local enc="-proj-a"
  cat > "$FIXHOME/.claude/projects/$enc/s1.jsonl" <<'JSONL'
{"cwd":"/proj/a","type":"user","message":{"role":"user","content":"first foobar then FooBar"}}
JSONL
  run env HOME="$FIXHOME" CCFIND_PV_QUERY=FooBar CCFIND_PV_CASE=1 \
    zsh -fc 'source "$1"; _ccfind_preview local "$2"' _ "$CCFIND_ZSH" \
    "$FIXHOME/.claude/projects/$enc/s1.jsonl"
  assert_equal "$status" 0
  assert_contains "$output" $'\033[1;33mFooBar\033[0m'
  refute_contains "$output" $'\033[1;33mfoobar\033[0m'
}

@test "case: the picker tells the preview which casing to mark" {
  install_fzf_stub
  mk_case_pair "$FIXHOME/.claude"
  run_ccfind -i -s FooBar
  assert_contains "$(cat "$FZF_ARGV")" "CCFIND_PV_CASE=1"
}

@test "_ccfind_hl folds case by default and stops folding on request" {
  run env CCFIND_COLOR=always zsh -fc 'source "$1"
                   _CCF_HIT=$'"'"'\033[1;33m'"'"'; _CCF_OFF=$'"'"'\033[0m'"'"'
                   _ccfind_hl "aB ab" "ab" "" ; print
                   _ccfind_hl "aB ab" "ab" "" 1' _ "$CCFIND_ZSH"
  assert_equal "$status" 0
  assert_equal "${lines[0]}" $'\033[1;33maB\033[0m \033[1;33mab\033[0m'
  assert_equal "${lines[1]}" $'aB \033[1;33mab\033[0m'
}

@test "remote (stubbed ssh): host column + default ssh resume command" {
  install_ssh_stub
  run_ccfind -H fakehost -N anything
  [ "$status" -eq 0 ]
  assert_contains "$output" "fakehost:/remote/proj"
  assert_contains "$output" "ssh -t fakehost"
}

# --- -R/--remote-only: the hosts INSTEAD of local ---------------------------
# -r/-H widen the search (hosts + local); -R substitutes (hosts, no local). The
# pair of tests below is the contract: the same fixture, the same host, and the
# only difference is whether the local hit comes back.

@test "-H alone widens: the local hit comes back alongside the remote one" {
  install_ssh_stub
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR/proj" LOCAL1 "anything"
  run_ccfind -H fakehost -N anything
  [ "$status" -eq 0 ]
  assert_contains "$output" "fakehost:/remote/proj"
  assert_contains "$output" "LOCAL1"
}

@test "-R searches the named host and NOT local" {
  install_ssh_stub
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR/proj" LOCAL1 "anything"
  run_ccfind -R -H fakehost -N anything
  [ "$status" -eq 0 ]
  assert_contains "$output" "fakehost:/remote/proj"
  refute_contains "$output" "LOCAL1"
}

@test "-R with no query lists that host's sessions only" {
  install_ssh_stub
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR/proj" LOCAL1 "anything"
  run_ccfind -R -H fakehost -N
  [ "$status" -eq 0 ]
  assert_contains "$output" "fakehost:/remote/proj"
  refute_contains "$output" "LOCAL1"
}

@test "-R takes CCFIND_HOSTS when -H is absent" {
  install_ssh_stub
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR/proj" LOCAL1 "anything"
  export CCFIND_HOSTS="fakehost"
  run_ccfind -R -N anything
  [ "$status" -eq 0 ]
  assert_contains "$output" "fakehost:/remote/proj"
  refute_contains "$output" "LOCAL1"
}

@test "-R skips the local walk even when every local profile is configured" {
  install_ssh_stub
  mkdir -p "$BATS_TEST_TMPDIR/work/projects" "$BATS_TEST_TMPDIR/personal/projects"
  mk_session "$BATS_TEST_TMPDIR/work" "$BATS_TEST_TMPDIR/proj" WORK1 "anything"
  mk_session "$BATS_TEST_TMPDIR/personal" "$BATS_TEST_TMPDIR/proj" PERS1 "anything"
  export CCFIND_PROFILES="work:$BATS_TEST_TMPDIR/work personal:$BATS_TEST_TMPDIR/personal"
  run_ccfind -R -H fakehost -N anything
  [ "$status" -eq 0 ]
  assert_contains "$output" "fakehost:/remote/proj"
  refute_contains "$output" "WORK1"
  refute_contains "$output" "PERS1"
}

# -R with nothing to dial searches precisely nothing. Reporting that as "No
# matching sessions" would read as "the host has none" — the one conclusion it
# cannot support — so it is an error instead.
@test "-R with no hosts configured is an error, not an empty list" {
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR/proj" LOCAL1 "anything"
  run_ccfind -R -N anything
  [ "$status" -eq 2 ]
  assert_contains "$output" "no hosts to search"
  refute_contains "$output" "No matching sessions"
  refute_contains "$output" "LOCAL1"
}

@test "-R and -l are mutually exclusive" {
  install_ssh_stub
  export CCFIND_HOSTS="fakehost"
  run_ccfind -R -l -N anything
  [ "$status" -eq 2 ]
  assert_contains "$output" "mutually exclusive"
}

# A profile is a local seat, so -p under -R filters a set nobody is searching.
@test "-p under -R warns that it scopes the local search" {
  install_ssh_stub
  mkdir -p "$BATS_TEST_TMPDIR/work/projects"
  export CCFIND_PROFILES="work:$BATS_TEST_TMPDIR/work"
  run_ccfind -R -H fakehost -p work -N anything
  [ "$status" -eq 0 ]
  assert_contains "$output" "has no effect with -R"
  assert_contains "$output" "fakehost:/remote/proj"
}

@test "-R reports what it covered when a host has no match" {
  install_ssh_stub_bare_host
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR/proj" LOCAL1 "anything"
  run_ccfind -R -H fakehost -N zzz-no-such-text
  [ "$status" -eq 0 ]
  assert_contains "$output" "No matching sessions"
  assert_contains "$output" "local not searched"
  refute_contains "$output" "profiles:"
}

@test "-R -v says local was skipped" {
  install_ssh_stub
  run_ccfind -R -H fakehost -v -N anything
  [ "$status" -eq 0 ]
  assert_contains "$output" "local not searched (-R)"
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
  assert_contains "$(cat "$FZF_ARGV")" "--with-nth=11"
}

@test "picker rows keep the data fields plain behind the display field" {
  install_fzf_stub
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy the widget"
  export CCFIND_COLOR=always
  run_ccfind -i deploy
  [ "$status" -eq 0 ]
  local row; row="$(head -1 "$FZF_ROWS")"
  # 12 fields: host, profile, cfgdir, id, cwd, ts, snippet, path, epoch, title,
  # display, and where it is running (for the preview; empty when it is not)
  [ "$(awk -F'\t' '{print NF}' <<<"$row")" -eq 12 ]
  assert_equal "$(cut -f12 <<<"$row")" ""
  # the data fields are what the resume and the preview read — no SGR in them,
  # or a host stops matching and a path stops opening.
  [ "$(cut -f1 <<<"$row")" = "local" ]
  [ "$(cut -f2 <<<"$row")" = "" ]          # unconfigured: one nameless profile
  [ "$(cut -f4 <<<"$row")" = "s1" ]
  [ "$(cut -f5 <<<"$row")" = "/proj/a" ]
  assert_contains "$(cut -f8 <<<"$row")" "/projects/-proj-a/s1.jsonl"
  # field 9 is the epoch the age is measured from — a bare number, not a date
  assert_equal "$(cut -f9 <<<"$row" | grep -c '^[0-9][0-9]*$')" "1"
  # …while field 11, the one fzf shows, carries the colour and the columns
  assert_contains "$(cut -f11 <<<"$row")" $'\033['
  assert_contains "$(cut -f11 <<<"$row")" "/proj/a"
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
  # epoch, profile, cfgdir, id, cwd, mtime, snippet, path, title
  assert_equal "$(awk -F'\t' '{print NF}' <<<"$output")" 9
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

# --- the time column: mtime, age, or both -----------------------------------
# Every assertion here freezes the clock with CCFIND_NOW and backdates the
# fixture against it, so what is under test is the rendering and never the
# moment the suite ran.

@test "a hit shows both its timestamp and its age" {
  export CCFIND_NOW=1750000000
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy the widget"
  age_session "$FIXHOME/.claude" "/proj/a" s1 18000        # 5 hours
  run_ccfind -N deploy
  assert_equal "$status" 0
  assert_contains "$output" "(5h ago)"
  assert_contains "$output" ":"          # the clock time is still there too
  run_ccfind --json deploy
  assert_contains "$output" '"epoch": 1749982000'
}

@test "the age is a single truncated unit, all the way up the scale" {
  export CCFIND_NOW=1750000000
  local -a ids=(m1 h1 d1 w1 o1 y1)
  local -a agos=(2740 18000 259200 1814400 15552000 63072000)
  local -a want=("45m ago" "5h ago" "3d ago" "3w ago" "6mo ago" "2y ago")
  local i
  for (( i = 0; i < ${#ids[@]}; i++ )); do
    mk_session  "$FIXHOME/.claude" "/proj/${ids[i]}" "${ids[i]}" "deploy"
    age_session "$FIXHOME/.claude" "/proj/${ids[i]}" "${ids[i]}" "${agos[i]}"
  done
  run_ccfind -N -n 20 deploy
  assert_equal "$status" 0
  for (( i = 0; i < ${#want[@]}; i++ )); do
    assert_contains "$output" "(${want[i]})"
  done
  # 45m40s prints as 45m: truncation, not rounding — a row must never read
  # newer than it is. (Rounding would make this one 46m.)
  refute_contains "$output" "(46m ago)"
}

@test "an age under a minute is words, not a zero" {
  export CCFIND_NOW=1750000000
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy"
  age_session "$FIXHOME/.claude" "/proj/a" s1 12
  run_ccfind -N deploy
  assert_contains "$output" "(just now)"
  refute_contains "$output" "0m ago"
}

@test "a hit newer than the clock reads just now, not a negative age" {
  # A remote hit carries the HOST's epoch. A host whose clock runs fast would
  # otherwise produce "(-2m ago)", which reads as a bug in ccfind.
  export CCFIND_NOW=1750000000
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy"
  age_session "$FIXHOME/.claude" "/proj/a" s1 -120          # two minutes ahead
  run_ccfind -N deploy
  assert_contains "$output" "(just now)"
  refute_contains "$output" "(-"
}

@test "the age column is right-aligned so the column after it stays put" {
  export CCFIND_NOW=1750000000
  mk_session "$FIXHOME/.claude" "/proj/aaa" s1 "deploy"
  age_session "$FIXHOME/.claude" "/proj/aaa" s1 18000       # "(5h ago)"
  mk_session "$FIXHOME/.claude" "/proj/bbb" s2 "deploy"
  age_session "$FIXHOME/.claude" "/proj/bbb" s2 15552000    # "(6mo ago)", wider
  run_ccfind -N deploy
  assert_equal "$status" 0
  # Both location lines — the ones that open with the timestamp — put the cwd
  # at the same column, however wide each row's own age turned out to be.
  local cols; cols="$(awk '/^[0-9]/ { print index($0, "/proj/") }' <<<"$output")"
  assert_equal "$(wc -l <<<"$cols" | tr -d ' ')" "2"
  assert_equal "$(sort -u <<<"$cols" | wc -l | tr -d ' ')" "1"
}

@test "CCFIND_TIME=abs is the timestamp alone, as it was before ages" {
  export CCFIND_NOW=1750000000 CCFIND_TIME=abs
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy"
  age_session "$FIXHOME/.claude" "/proj/a" s1 18000
  run_ccfind -N deploy
  assert_equal "$status" 0
  refute_contains "$output" "ago"
  assert_contains "$output" "/proj/a"
}

@test "CCFIND_TIME=rel gives the age the whole column" {
  export CCFIND_NOW=1750000000 CCFIND_TIME=rel
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy"
  age_session "$FIXHOME/.claude" "/proj/a" s1 18000
  run_ccfind -N deploy
  assert_equal "$status" 0
  assert_contains "$output" "5h ago"
  refute_contains "$output" "(5h ago)"      # bare: nothing for it to trail
  # and no clock time left over anywhere — matched by shape, not by value, so
  # the assertion does not depend on the timezone the suite happens to run in
  assert_equal "$(grep -c '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' <<<"$output")" "0"
}

@test "CCFIND_TIME can be set in the .env beside the script" {
  export CCFIND_NOW=1750000000
  printf 'typeset CCFIND_TIME="rel"\n' > "${CCFIND_ZSH%/*}/.env"
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy"
  age_session "$FIXHOME/.claude" "/proj/a" s1 18000
  run_ccfind -N deploy
  assert_equal "$status" 0
  assert_contains "$output" "5h ago"
  refute_contains "$output" "(5h ago)"
}

@test "an unknown CCFIND_TIME says so instead of being ignored" {
  export CCFIND_NOW=1750000000 CCFIND_TIME=relative
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy"
  age_session "$FIXHOME/.claude" "/proj/a" s1 18000
  run_ccfind -N deploy
  assert_equal "$status" 0
  assert_contains "$output" "not one of abs|rel|both"
  assert_contains "$output" "(5h ago)"      # and the fallback really is both
}

@test "machine output carries the epoch, never a rendered age" {
  # The age is a display concern; a consumer has the epoch and its own clock,
  # and a "5h ago" baked into a document would be wrong the moment it is read.
  export CCFIND_NOW=1750000000
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy"
  age_session "$FIXHOME/.claude" "/proj/a" s1 18000
  run_ccfind --tsv deploy
  assert_equal "$status" 0
  assert_equal "$(awk -F'\t' '{print NF}' <<<"$output")" 9
  assert_equal "$(cut -f1 <<<"$output")" "1749982000"
  refute_contains "$output" "ago"
  run_ccfind --json deploy
  refute_contains "$output" "ago"
}

@test "the picker's display column carries the age as well" {
  install_fzf_stub
  export CCFIND_NOW=1750000000
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy"
  age_session "$FIXHOME/.claude" "/proj/a" s1 18000
  run_ccfind -i deploy
  assert_equal "$status" 0
  local row; row="$(head -1 "$FZF_ROWS")"
  assert_contains "$(cut -f11 <<<"$row")" "(5h ago)"
  assert_equal    "$(cut -f9  <<<"$row")" "1749982000"
}

# --- what the picker's display column actually shows ------------------------

@test "the display column contracts \$HOME but the resume keeps the full path" {
  install_fzf_stub
  mkdir -p "$FIXHOME/code/app"
  mk_session "$FIXHOME/.claude" "$FIXHOME/code/app" S1 "termx"
  run_ccfind -i termx
  assert_equal "$status" 0
  local row; row="$(head -1 "$FZF_ROWS")"
  assert_contains "$(cut -f11 <<<"$row")" "~/code/app"     # what you read
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
  local disp; disp="$(cut -f11 < "$FZF_ROWS")"
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

# --- session titles ----------------------------------------------------------
# The name `claude --resume` lists a session under, read from the title records
# Claude Code appends to the transcript. It is what tells two sessions in one
# directory apart, so it has to survive every path a hit can take.

@test "title: the flat list shows the session's generated title" {
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy the widget"
  title_session "$FIXHOME/.claude" "/proj/a" s1 ai "Widget deploy pipeline"
  run_ccfind deploy
  assert_equal "$status" 0
  assert_contains "$output" "   Widget deploy pipeline"
}

@test "title: an untitled session prints no title line" {
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy the widget"
  run_ccfind deploy
  assert_equal "$status" 0
  # time+cwd, snippet, resume — the three lines a hit has always had
  assert_equal "$(wc -l <<<"$output" | tr -d ' ')" 3
}

@test "title: the last generated title wins — it is re-written as the session grows" {
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy"
  title_session "$FIXHOME/.claude" "/proj/a" s1 ai "First guess"
  title_session "$FIXHOME/.claude" "/proj/a" s1 ai "Settled title"
  run_ccfind --json deploy
  run python3 -c 'import json,sys; print(json.load(sys.stdin)["results"][0]["title"])' <<<"$output"
  assert_equal "$output" "Settled title"
}

@test "title: a /rename beats the generated title, whichever came last" {
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy"
  title_session "$FIXHOME/.claude" "/proj/a" s1 custom "My name for it"
  title_session "$FIXHOME/.claude" "/proj/a" s1 ai "Generated later"
  run_ccfind --json deploy
  run python3 -c 'import json,sys; print(json.load(sys.stdin)["results"][0]["title"])' <<<"$output"
  assert_equal "$output" "My name for it"
}

@test "title: the legacy summary record is used when nothing newer exists" {
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy"
  title_session "$FIXHOME/.claude" "/proj/a" s1 summary "Old-style summary"
  run_ccfind deploy
  assert_contains "$output" "Old-style summary"
}

@test "title: a transcript that merely mentions a title record has no title" {
  # Inside a message the quotes are escaped, so only a real record may match.
  mk_session "$FIXHOME/.claude" "/proj/a" s1 'deploy {\"type\":\"ai-title\",\"aiTitle\":\"fake\"}'
  run_ccfind --json deploy
  run python3 -c 'import json,sys; print(repr(json.load(sys.stdin)["results"][0]["title"]))' <<<"$output"
  assert_equal "$output" "''"
}

@test "title: JSON escapes are decoded and nothing can break the record" {
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy"
  title_session "$FIXHOME/.claude" "/proj/a" s1 ai 'Fix \"quoted\" path C:\\tmp\there'
  run_ccfind --tsv deploy
  assert_equal "$(awk -F'\t' '{print NF}' <<<"$output")" 9
  assert_equal "$(cut -f9 <<<"$output")" 'Fix "quoted" path C:\tmp here'
}

@test "title: --tsv carries it last, so the first 8 fields keep their meaning" {
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy"
  title_session "$FIXHOME/.claude" "/proj/a" s1 ai "Wire title"
  run_ccfind --tsv deploy
  assert_contains "$(cut -f8 <<<"$output")" "/projects/-proj-a/s1.jsonl"
  assert_equal "$(cut -f9 <<<"$output")" "Wire title"
}

@test "title: the picker shows it, and keeps a plain copy in field 10" {
  install_fzf_stub
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "deploy the widget"
  title_session "$FIXHOME/.claude" "/proj/a" s1 ai "Picker title"
  export CCFIND_COLOR=always
  run_ccfind -i deploy
  assert_equal "$status" 0
  local row; row="$(head -1 "$FZF_ROWS")"
  assert_equal "$(cut -f10 <<<"$row")" "Picker title"
  assert_contains "$(cut -f11 <<<"$row")" "Picker title"
}

@test "title: a remote host running ccfind sends its titles back" {
  install_ssh_stub_real_host
  mk_session "$REMOTE_HOME/.claude" "/srv/app" R1 "remote deploy"
  title_session "$REMOTE_HOME/.claude" "/srv/app" R1 ai "Remote titled session"
  run_ccfind -R -H nas -N deploy
  assert_equal "$status" 0
  assert_contains "$output" "Remote titled session"
}

@test "title: a host without ccfind sends titles from the filesystem walk too" {
  install_ssh_stub_bare_host
  mk_session "$REMOTE_HOME/.claude" "/srv/app" R1 "remote deploy"
  title_session "$REMOTE_HOME/.claude" "/srv/app" R1 ai "Bare host title"
  run_ccfind -R -H nas -N deploy
  assert_equal "$status" 0
  assert_contains "$output" "Bare host title"
}

@test "title: a host too old to send titles still parses, path intact" {
  # The canned stub speaks the 8-field wire of a pre-title ccfind.
  install_ssh_stub
  run_ccfind -R -H fakehost --json anything
  assert_equal "$status" 0
  run python3 -c 'import json,sys; r=json.load(sys.stdin)["results"][0]; print(r["path"], repr(r["title"]), r["epoch"])' <<<"$output"
  assert_equal "$output" "/remote/proj/RID123.jsonl '' 1700000000"
}

# --- tmux: resume inside a tmux session ---------------------------------------
# -t / CCFIND_TMUX=1 wrap the resume in `tmux new-session -A`, named after the
# hit, so Enter on the same hit while its claude still runs reattaches instead
# of starting a second claude on one transcript. Already inside tmux ($TMUX
# set), it is skipped. The window runs claude via "$SHELL" -ic, because on a
# real machine `claude` is usually an rc function (install_login_shell models
# that, with a tripwire for the bare binary).

# remote_resume_cmd — the whole command the emitted `ssh -t <host> …` line
# hands the far end's login shell, unquoted the one layer the local shell owns.
remote_resume_cmd() {
  local line
  line="$(printf '%s\n' "$output" | grep -m1 -- 'ssh -t ' | sed 's/^ *//')"
  bash -c "printf '%s' ${line#ssh -t * }"
}

@test "tmux: -t prints a tmux line named after the session's dir and id" {
  install_tmux_stub
  mkdir -p "$BATS_TEST_TMPDIR/my.proj dir"
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR/my.proj dir" 1a2b3c4d-e5f6 "termx"
  run_ccfind -N -t termx
  assert_equal "$status" 0
  # tmux takes neither `.` nor `:` in a name; the id is cut to 8 characters
  assert_contains "$output" "tmux new-session -A -s cc-my-proj-dir-1a2b3c4d -c "
  assert_contains "$output" "claude --resume 1a2b3c4d-e5f6"
  refute_contains "$output" "&& claude"            # no cd: tmux -c does that
}

@test "tmux: off by default; CCFIND_TMUX=1 turns it on and -T back off" {
  install_tmux_stub
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "termx"
  run_ccfind -N termx
  refute_contains "$output" "tmux"
  export CCFIND_TMUX=1
  run_ccfind -N termx
  assert_contains "$output" "tmux new-session -A -s cc-a-s1 -c /proj/a"
  run_ccfind -N -T termx
  refute_contains "$output" "tmux"
  assert_contains "$output" "cd /proj/a && claude --resume s1"
}

@test "tmux: CCFIND_TMUX can be set in the .env beside the script" {
  install_tmux_stub
  printf 'typeset CCFIND_TMUX=1\n' > "${CCFIND_ZSH%/*}/.env"
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "termx"
  run_ccfind -N termx
  assert_equal "$status" 0
  assert_contains "$output" "tmux new-session -A -s cc-a-s1"
}

@test "tmux: an unknown CCFIND_TMUX value warns and stays off" {
  install_tmux_stub
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "termx"
  export CCFIND_TMUX=maybe
  run_ccfind -N termx
  assert_equal "$status" 0
  assert_contains "$output" "CCFIND_TMUX=maybe is not one of 1|0"
  refute_contains "$output" "tmux new-session"
}

@test "tmux: already inside tmux, -t creates the session detached and switches to it" {
  # Attaching from inside tmux nests one tmux in another, which tmux itself
  # refuses. Created with -d and switched to, it never nests.
  install_tmux_stub
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "termx"
  export TMUX="$(tmux_sock default),123,0"
  run_ccfind -N -t termx
  assert_equal "$status" 0
  assert_contains "$output" "tmux has-session -t '=cc-a-s1' 2>/dev/null || tmux new-session -d -s cc-a-s1 -c /proj/a "
  assert_contains "$output" "&& tmux switch-client -t '=cc-a-s1'"
  refute_contains "$output" "new-session -A"
}

@test "tmux: inside tmux, Enter on a session that is not running switches to its new session" {
  install_fzf_stub_select
  install_tmux_stub
  install_login_shell "$FIXHOME"
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR/proj" S1 "termx"
  local sock; sock="$(tmux_sock default)"
  export TMUX="$sock,123,0"
  run_ccfind -i -t termx
  assert_equal "$status" 0
  assert_contains "$output" "TMUX new session [cc-proj-S1] in [$BATS_TEST_TMPDIR/proj]"
  assert_contains "$output" "CLAUDE argv=[--resume S1]"
  assert_contains "$output" "TMUX switched to [=cc-proj-S1] on [$sock]"
}

@test "tmux: the printed line really resumes, through the rc's claude function" {
  install_tmux_stub
  install_login_shell "$FIXHOME"
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR/proj" S1 "termx"
  run_ccfind -N -t termx
  local line; line="$(resume_line_from_output)"
  run_resume "$line"
  assert_equal "$status" 0
  assert_contains "$output" "TMUX new session [cc-proj-S1] in [$BATS_TEST_TMPDIR/proj]"
  assert_contains "$output" "CLAUDE argv=[--resume S1]"
  assert_contains "$output" "pwd=[$BATS_TEST_TMPDIR/proj]"
  assert_contains "$output" "dir=[<unset>]"
  assert_contains "$output" "verdict=[RESUMED]"
}

@test "tmux: negative control: the same window without -i misses the rc's claude" {
  # The test above passes because of the interactive shell, not by luck: drop
  # the -i and the window must land on the bare binary, as the real one would.
  # If this ever passes through to the function, the login-shell model has
  # stopped modelling anything and the test above proves nothing.
  install_tmux_stub
  install_login_shell "$FIXHOME"
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR/proj" S1 "termx"
  run_ccfind -N -t termx
  local line; line="$(resume_line_from_output)"
  assert_contains "$line" " -ic "
  run_resume "${line/ -ic / -c }"
  assert_contains "$output" "CLAUDE-BARE argv=[--resume S1]"
  refute_contains "$output" "CLAUDE argv="
}

@test "tmux: a profile hit resumes into its own seat; the default seat stays unset" {
  install_tmux_stub
  install_login_shell "$FIXHOME"
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  mk_session "$BATS_TEST_TMPDIR/personal" "$BATS_TEST_TMPDIR/proj" P1 "termx one"
  mk_session "$FIXHOME/.claude"           "$BATS_TEST_TMPDIR/proj" D1 "termx two"
  export CCFIND_PROFILES="personal:$BATS_TEST_TMPDIR/personal daily:$FIXHOME/.claude"
  run_ccfind -N -t personal termx
  run_resume "$(resume_line_from_output)"
  assert_contains "$output" "CLAUDE argv=[--resume P1]"
  assert_contains "$output" "dir=[$BATS_TEST_TMPDIR/personal]"
  assert_contains "$output" "verdict=[RESUMED]"
  run_ccfind -N -t daily termx
  run_resume "$(resume_line_from_output)"
  assert_contains "$output" "CLAUDE argv=[--resume D1]"
  assert_contains "$output" "dir=[<unset>]"
  assert_contains "$output" "verdict=[RESUMED]"
}

@test "tmux: Enter opens the session in tmux and leaves the caller's shell where it was" {
  install_fzf_stub_select
  install_tmux_stub
  install_login_shell "$FIXHOME"
  mkdir -p "$BATS_TEST_TMPDIR/proj" "$BATS_TEST_TMPDIR/elsewhere"
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR/proj" S1 "termx"
  run env HOME="$FIXHOME" zsh -fc \
    'cd -- "$1" || exit 1; src=$2; shift 2; source "$src"; ccfind "$@"; echo "CALLER pwd=[$PWD]"' \
    _ "$BATS_TEST_TMPDIR/elsewhere" "$CCFIND_ZSH" -i -t termx
  assert_equal "$status" 0
  assert_contains "$output" "TMUX new session [cc-proj-S1] in [$BATS_TEST_TMPDIR/proj]"
  assert_contains "$output" "CLAUDE argv=[--resume S1]"
  assert_contains "$output" "pwd=[$BATS_TEST_TMPDIR/proj]"
  assert_contains "$output" "CALLER pwd=[$BATS_TEST_TMPDIR/elsewhere]"
}

@test "tmux: Enter on a hit whose claude still runs reattaches, never a second claude" {
  install_fzf_stub_select
  install_tmux_stub
  install_login_shell "$FIXHOME"
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR/proj" S1 "termx"
  run_ccfind -i -t termx
  assert_contains "$output" "CLAUDE argv=[--resume S1]"
  run_ccfind -i -t termx
  assert_equal "$status" 0
  assert_contains "$output" "TMUX attached to [cc-proj-S1]"
  refute_contains "$output" "argv="
}

@test "tmux: Enter refuses a vanished directory before tmux is ever called" {
  install_fzf_stub_select
  install_tmux_stub
  install_login_shell "$FIXHOME"
  mk_session "$FIXHOME/.claude" "/vanished/dir" S1 "termx"
  run_ccfind -i -t termx
  assert_equal "$status" 1
  assert_contains "$output" "no longer exists"
  assert_equal "$(cat "$TMUX_LOG" 2>/dev/null)" ""
}

@test "tmux: the picker header says where Enter goes" {
  install_fzf_stub
  install_tmux_stub
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "termx"
  run_ccfind -i -t termx
  assert_contains "$(cat "$FZF_ARGV")" "Enter resume in tmux"
  run_ccfind -i termx
  refute_contains "$(cat "$FZF_ARGV")" "resume in tmux"
}

@test "tmux: a machine without tmux says so once and resumes plainly" {
  mk_session "$FIXHOME/.claude" "/proj/a" s1 "termx one"
  mk_session "$FIXHOME/.claude" "/proj/b" s2 "termx two"
  local p; p="$(path_without_tmux)" || skip "tmux shares a dir with ccfind's own tools here"
  run env PATH="$p" HOME="$FIXHOME" zsh -fc 'src=$1; shift; source "$src"; ccfind "$@"' \
    _ "$CCFIND_ZSH" -N -t termx
  assert_equal "$status" 0
  assert_equal "$(grep -c 'tmux is not installed here' <<<"$output")" 1
  assert_contains "$output" "cd /proj/a && claude --resume s1"
  refute_contains "$output" "tmux new-session"
}

@test "tmux: a remote hit opens tmux on the HOST and resumes its seat there" {
  install_ssh_stub_real_host
  install_tmux_stub
  install_login_shell "$REMOTE_HOME"
  mkdir -p "$BATS_TEST_TMPDIR/srv/side"
  mk_session "$REMOTE_HOME/.claude-personal" "$BATS_TEST_TMPDIR/srv/side" R2abcdef99 "termx"
  run_ccfind -N -t -R -H nas termx
  assert_equal "$status" 0
  local rcmd; rcmd="$(remote_resume_cmd)"
  assert_contains "$rcmd" "cd $BATS_TEST_TMPDIR/srv/side && exec"
  run env HOME="$REMOTE_HOME" PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash -c "$rcmd"
  assert_equal "$status" 0
  assert_contains "$output" "TMUX new session [cc-side-R2abcdef] in [$BATS_TEST_TMPDIR/srv/side]"
  assert_contains "$output" "CLAUDE argv=[--resume R2abcdef99]"
  assert_contains "$output" "dir=[$REMOTE_HOME/.claude-personal]"
  assert_contains "$output" "verdict=[RESUMED]"
}

@test "tmux: a remote hit on the host's default seat exports nothing inside tmux" {
  # The default-seat test travels four shells deep here (ssh, the outer -ic,
  # tmux's -c, the window's -ic), so it is pinned at that depth too.
  install_ssh_stub_real_host
  install_tmux_stub
  install_login_shell "$REMOTE_HOME"
  mkdir -p "$BATS_TEST_TMPDIR/srv/app"
  mk_session "$REMOTE_HOME/.claude" "$BATS_TEST_TMPDIR/srv/app" R1 "termx"
  run_ccfind -N -t -R -H nas termx
  local rcmd; rcmd="$(remote_resume_cmd)"
  run env HOME="$REMOTE_HOME" PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash -c "$rcmd"
  assert_equal "$status" 0
  assert_contains "$output" "CLAUDE argv=[--resume R1]"
  assert_contains "$output" "dir=[<unset>]"
  assert_contains "$output" "verdict=[RESUMED]"
}

@test "tmux: a host without tmux resumes plainly and says why" {
  install_ssh_stub_real_host
  install_login_shell "$REMOTE_HOME"
  mkdir -p "$BATS_TEST_TMPDIR/srv/app"
  mk_session "$REMOTE_HOME/.claude" "$BATS_TEST_TMPDIR/srv/app" R1 "termx"
  local p; p="$(path_without_tmux)" || skip "tmux shares a dir with ccfind's own tools here"
  run_ccfind -N -t -R -H nas termx
  local rcmd; rcmd="$(remote_resume_cmd)"
  run env HOME="$REMOTE_HOME" PATH="$p" bash -c "$rcmd"
  assert_equal "$status" 0
  assert_contains "$output" "no tmux on this host, resuming without it"
  assert_contains "$output" "CLAUDE argv=[--resume R1]"
  refute_contains "$output" "CLAUDE-BARE"
}

@test "tmux: Enter on a remote hit sends exactly the line the list prints" {
  install_fzf_stub_select
  install_ssh_stub_real_host
  mk_session "$REMOTE_HOME/.claude" "/srv/app" R1 "termx"
  run_ccfind -N -t -R -H nas termx
  local printed; printed="$(remote_resume_cmd)"
  assert_contains "$printed" "tmux"
  run_ccfind -i -t -R -H nas termx
  assert_equal "$status" 0
  local sent; sent="$(tail -1 "$SSH_LOG")"
  assert_equal "${sent#-t nas }" "$printed"
}

@test "tmux: inside tmux, a remote hit tells the host, and its fallback stays plain" {
  # The host's ccfind decides, so it has to be told the person is in tmux
  # already ($TMUX is not sent over ssh). A host that cannot decide gets the
  # old command, which inside tmux never starts the host's tmux either.
  install_ssh_stub_real_host
  mk_session "$REMOTE_HOME/.claude" "/srv/app" R1 "termx"
  export TMUX="/private/sock,123,0"
  run_ccfind -N -t -R -H nas termx
  assert_equal "$status" 0
  assert_contains "$output" "ssh -t nas"
  local rcmd; rcmd="$(remote_resume_cmd)"
  assert_contains "$rcmd" "--from-tmux"
  refute_contains "$rcmd" "new-session"
}

@test "tmux: CCFIND_REMOTE_RESUME still wins for remote hits" {
  install_ssh_stub
  export CCFIND_REMOTE_RESUME="my-resume" CCFIND_TMUX=1
  run_ccfind -H fakehost -N anything
  assert_equal "$status" 0
  assert_contains "$output" "my-resume fakehost /remote/proj RID123"
  refute_contains "$output" "tmux"
}

# --- resuming a session that may already be running ---------------------------
# `ccfind --resume <id>` (and Enter, which goes through it) checks Claude Code's
# own record of running sessions first, so a session is never started twice:
#   running in a tmux pane → offer to attach (switch, inside that server)
#   running outside tmux   → refuse; -f/--force starts one anyway
#   not running            → resume (in tmux only if this machine opted in)
# tmux is never assumed: without it, "running" just means "outside tmux".
# The "claude" in these tests is a real process with a record written the way
# Claude Code writes it (mk_running), so liveness, start time and machine are
# all checked for real.

@test "resume: --capabilities answers resume (what a caller probes for)" {
  run_ccfind --capabilities
  assert_equal "$status" 0
  assert_equal "$output" "resume"
}

@test "resume: a session that is not running resumes as before" {
  install_claude_stub
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR/proj" S1 "termx"
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" HOME="$FIXHOME" zsh -fc \
    'src=$1; shift; source "$src"; ccfind "$@"' _ "$CCFIND_ZSH" --resume S1 </dev/null
  assert_equal "$status" 0
  assert_contains "$output" "CLAUDE argv=[--resume S1]"
  assert_contains "$output" "pwd=[$BATS_TEST_TMPDIR/proj]"
  assert_contains "$output" "dir=[<unset>]"
}

@test "resume: an unknown id says so and starts nothing" {
  install_claude_stub
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" HOME="$FIXHOME" zsh -fc \
    'src=$1; shift; source "$src"; ccfind "$@"' _ "$CCFIND_ZSH" --resume NOPE </dev/null
  assert_equal "$status" 1
  assert_contains "$output" "no session NOPE here"
  refute_contains "$output" "argv="
}

@test "resume: running outside tmux is refused, with its pid" {
  install_claude_stub
  _stub_path_add "$BATS_TEST_TMPDIR/bin"
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR" S1 "termx"
  mk_running "$FIXHOME/.claude" S1
  run_ccfind --resume S1
  assert_equal "$status" 1
  assert_contains "$output" "already running (pid $RUN_PID, no terminal), outside tmux"
  assert_contains "$output" "-f/--force"
  refute_contains "$output" "CLAUDE argv="
}

@test "resume: -f starts it anyway" {
  install_claude_stub
  _stub_path_add "$BATS_TEST_TMPDIR/bin"
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR" S1 "termx"
  mk_running "$FIXHOME/.claude" S1
  run_ccfind -f --resume S1
  assert_equal "$status" 0
  assert_contains "$output" "CLAUDE argv=[--resume S1]"
}

@test "resume: negative control: a record whose process is gone does not count" {
  install_claude_stub
  _stub_path_add "$BATS_TEST_TMPDIR/bin"
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR" S1 "termx"
  mk_running "$FIXHOME/.claude" S1
  kill "$RUN_PID" "$RUN_PANE_PID"; wait "$RUN_PANE_PID" 2>/dev/null || true
  run_ccfind --resume S1
  assert_equal "$status" 0
  assert_contains "$output" "CLAUDE argv=[--resume S1]"
}

@test "resume: negative control: a reused pid (other start time) does not count" {
  install_claude_stub
  _stub_path_add "$BATS_TEST_TMPDIR/bin"
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR" S1 "termx"
  mk_running "$FIXHOME/.claude" S1
  # The same live pid, recorded as having started at another moment.
  mk_session_record "$FIXHOME/.claude" "$RUN_PID" S1 "Mon Jan  1 00:00:00 2024" "$(this_pid_domain)"
  case "$(uname -s)" in Darwin) ;; *)
    mk_session_record "$FIXHOME/.claude" "$RUN_PID" S1 "1" "$(this_pid_domain)" ;; esac
  run_ccfind --resume S1
  assert_equal "$status" 0
  assert_contains "$output" "CLAUDE argv=[--resume S1]"
}

@test "resume: negative control: a record from another machine does not count" {
  install_claude_stub
  _stub_path_add "$BATS_TEST_TMPDIR/bin"
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR" S1 "termx"
  mk_running "$FIXHOME/.claude" S1
  mk_session_record "$FIXHOME/.claude" "$RUN_PID" S1 "$(this_proc_start "$RUN_PID")" \
    "linux:0000000000000000000000000000beef:pid:[1]"
  run_ccfind --resume S1
  assert_equal "$status" 0
  assert_contains "$output" "CLAUDE argv=[--resume S1]"
}

@test "resume: a record without a start time falls back to the pid being alive" {
  # A record with no procStart (an older Claude Code, say) can only be judged
  # by its pid. Alive counts; gone does not. Without this pair, the liveness
  # check is shadowed by the start-time check and nothing pins it.
  install_claude_stub
  _stub_path_add "$BATS_TEST_TMPDIR/bin"
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR" S1 "termx"
  mk_running "$FIXHOME/.claude" S1
  printf '{"pid":%s,"sessionId":"S1","kind":"interactive"}' "$RUN_PID" \
    > "$FIXHOME/.claude/sessions/$RUN_PID.json"
  run_ccfind --resume S1
  assert_equal "$status" 1
  assert_contains "$output" "already running (pid $RUN_PID"
  kill "$RUN_PID" "$RUN_PANE_PID"; wait "$RUN_PANE_PID" 2>/dev/null || true
  run_ccfind --resume S1
  assert_equal "$status" 0
  assert_contains "$output" "CLAUDE argv=[--resume S1]"
}

@test "resume: control: the same record with this machine's domain does count" {
  # Pairs with the two above: if this ever resumes, the start-time and domain
  # checks have stopped discriminating and those tests prove nothing.
  install_claude_stub
  _stub_path_add "$BATS_TEST_TMPDIR/bin"
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR" S1 "termx"
  mk_running "$FIXHOME/.claude" S1
  mk_session_record "$FIXHOME/.claude" "$RUN_PID" S1 "$(this_proc_start "$RUN_PID")" "$(this_pid_domain)"
  run_ccfind --resume S1
  assert_equal "$status" 1
  assert_contains "$output" "already running"
}

@test "resume: running in a tmux pane offers to attach; yes attaches to that pane" {
  install_claude_stub
  install_tmux_stub
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR" S1 "termx"
  local sock; sock="$(tmux_sock default)"
  mk_running "$FIXHOME/.claude" S1 "$sock" work 2 1
  run_ccfind_answer y --resume S1
  assert_equal "$status" 0
  assert_contains "$output" "already running in tmux session 'work' (window 2, pane 1). Attach to it instead? [Y/n]"
  assert_contains "$output" "TMUX attached to [=work] on [$sock]"
  assert_contains "$(cat "$TMUX_LOG")" "[select-pane] [-t] [work:2.1]"
  refute_contains "$output" "CLAUDE argv="
}

@test "resume: Enter accepts the default (an empty answer) as yes" {
  install_claude_stub
  install_tmux_stub
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR" S1 "termx"
  local sock; sock="$(tmux_sock default)"
  mk_running "$FIXHOME/.claude" S1 "$sock" work
  run_ccfind_answer "" --resume S1
  assert_equal "$status" 0
  assert_contains "$output" "TMUX attached to [=work]"
}

@test "resume: answering no leaves it alone and starts nothing" {
  install_claude_stub
  install_tmux_stub
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR" S1 "termx"
  mk_running "$FIXHOME/.claude" S1 "$(tmux_sock default)" work
  run_ccfind_answer n --resume S1
  assert_equal "$status" 0
  assert_contains "$output" "left it running where it is; nothing started"
  refute_contains "$output" "TMUX attached"
  refute_contains "$output" "CLAUDE argv="
}

@test "resume: with nobody to ask, it says how to attach and starts nothing" {
  install_claude_stub
  install_tmux_stub
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR" S1 "termx"
  mk_running "$FIXHOME/.claude" S1 "$(tmux_sock default)" work
  run_ccfind --resume S1
  assert_equal "$status" 1
  assert_contains "$output" "To attach: tmux attach -t '=work'"
  refute_contains "$output" "CLAUDE argv="
}

@test "resume: a pane on a named tmux server is found, and named with -L" {
  # A service that keeps claude in `tmux -L svc` runs a second tmux server
  # beside `default`, invisible to a plain `tmux ls`. A dead `default` socket
  # (server gone, file left behind) sits beside it, as it does in the wild.
  install_claude_stub
  install_tmux_stub
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR" S1 "termx"
  tmux_sock default >/dev/null
  local sock; sock="$(tmux_sock svc)"
  mk_running "$FIXHOME/.claude" S1 "$sock" svc
  run_ccfind --resume S1
  assert_equal "$status" 1
  assert_contains "$output" "To attach: tmux -L svc attach -t '=svc'"
  run_ccfind_answer y --resume S1
  assert_contains "$output" "TMUX attached to [=svc] on [$sock]"
}

@test "resume: without tmux installed, a running session is simply 'outside tmux'" {
  install_claude_stub
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR" S1 "termx"
  mk_running "$FIXHOME/.claude" S1
  local p; p="$(path_without_tmux)" || skip "tmux shares a dir with ccfind's own tools here"
  run env PATH="$BATS_TEST_TMPDIR/bin:$p" HOME="$FIXHOME" zsh -fc \
    'src=$1; shift; source "$src"; ccfind "$@"' _ "$CCFIND_ZSH" --resume S1 </dev/null
  assert_equal "$status" 1
  assert_contains "$output" "already running (pid $RUN_PID"
  assert_contains "$output" "outside tmux"
}

@test "resume: inside the same tmux server, yes switches to the pane" {
  install_claude_stub
  install_tmux_stub
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR" S1 "termx"
  local sock; sock="$(tmux_sock default)"
  mk_running "$FIXHOME/.claude" S1 "$sock" work 3 0
  export TMUX="$sock,123,0"
  run_ccfind_answer y --resume S1
  assert_equal "$status" 0
  assert_contains "$output" "Switch to it instead? [Y/n]"
  assert_contains "$output" "TMUX switched to [=work] on [$sock]"
  refute_contains "$output" "TMUX attached"
}

@test "resume: inside tmux, a session on ANOTHER tmux server is refused, with how to join" {
  install_claude_stub
  install_tmux_stub
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR" S1 "termx"
  local mine; mine="$(tmux_sock default)"
  mk_running "$FIXHOME/.claude" S1 "$(tmux_sock svc)" svc
  export TMUX="$mine,123,0"
  run_ccfind_answer y --resume S1
  assert_equal "$status" 1
  assert_contains "$output" "you are inside tmux, and this session is already running inside another active tmux session"
  assert_contains "$output" "From outside tmux, run:"
  assert_contains "$output" "tmux -L svc attach -t '=svc'"
  refute_contains "$output" "TMUX switched"
  refute_contains "$output" "TMUX attached"
}

@test "resume: asked from tmux on another machine, a session in a pane here is refused" {
  # --from-tmux is what the asking machine sends; --as is what it calls us.
  install_claude_stub
  install_tmux_stub
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR" S1 "termx"
  mk_running "$FIXHOME/.claude" S1 "$(tmux_sock default)" work
  run_ccfind_answer y --resume S1 --from-tmux --as host-b
  assert_equal "$status" 1
  assert_contains "$output" "already running inside another active tmux session: tmux session 'work' (window 0, pane 0) on host-b"
  assert_contains "$output" "ssh -t host-b tmux attach -t '=work'"
  refute_contains "$output" "TMUX attached"
}

@test "resume: asked from tmux on another machine, a session that is not running starts in that pane" {
  # This machine opted into tmux, but starting its tmux would nest it in the
  # asker's; the asker's own tmux already keeps this pane alive.
  install_tmux_stub
  install_claude_stub
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR/proj" S1 "termx"
  export CCFIND_TMUX=1
  run_ccfind --resume S1 --from-tmux
  assert_equal "$status" 0
  assert_contains "$output" "CLAUDE argv=[--resume S1]"
  refute_contains "$output" "TMUX new session"
}

@test "resume: Enter in the picker goes through the same check" {
  install_fzf_stub_select
  install_claude_stub
  _stub_path_add "$BATS_TEST_TMPDIR/bin"
  mk_session "$FIXHOME/.claude" "$BATS_TEST_TMPDIR" S1 "termx"
  mk_running "$FIXHOME/.claude" S1
  run_ccfind -i termx
  assert_equal "$status" 1
  assert_contains "$output" "already running (pid $RUN_PID"
  refute_contains "$output" "CLAUDE argv="
}

@test "resume: a record in another profile's seat is checked in that seat" {
  install_claude_stub
  _stub_path_add "$BATS_TEST_TMPDIR/bin"
  mk_session "$BATS_TEST_TMPDIR/personal" "$BATS_TEST_TMPDIR" P1 "termx"
  export CCFIND_PROFILES="personal:$BATS_TEST_TMPDIR/personal"
  mk_running "$BATS_TEST_TMPDIR/personal" P1
  run_ccfind --resume P1
  assert_equal "$status" 1
  assert_contains "$output" "already running"
}

# --- resuming on the machine the session lives on ------------------------------
# For a session on another host, ssh runs that host's OWN ccfind --resume, so
# the host checks its own processes and applies its own CCFIND_TMUX. A host
# without a ccfind that knows --resume gets the command ccfind always sent.

@test "remote resume: a capable host resumes it under its own CCFIND_TMUX" {
  install_ssh_stub_real_host
  install_tmux_stub
  install_login_shell "$REMOTE_HOME"
  login_shell_loads_ccfind "$REMOTE_HOME" "$REMOTE_CCFIND_DIR/ccfind.zsh"
  printf 'typeset CCFIND_TMUX=1\n' >> "$REMOTE_CCFIND_DIR/.env"
  mkdir -p "$BATS_TEST_TMPDIR/srv/side"
  mk_session "$REMOTE_HOME/.claude-personal" "$BATS_TEST_TMPDIR/srv/side" R2abcdef99 "termx"
  run_ccfind -N -R -H nas termx                 # the caller sets no tmux at all
  local rcmd; rcmd="$(remote_resume_cmd)"
  run env -u CCFIND_TMUX HOME="$REMOTE_HOME" PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash -c "$rcmd" </dev/null
  assert_equal "$status" 0
  assert_contains "$output" "TMUX new session [cc-side-R2abcdef] in [$BATS_TEST_TMPDIR/srv/side]"
  assert_contains "$output" "CLAUDE argv=[--resume R2abcdef99]"
  assert_contains "$output" "dir=[$REMOTE_HOME/.claude-personal]"
  assert_contains "$output" "verdict=[RESUMED]"
}

@test "remote resume: a capable host refuses a session already running there" {
  install_ssh_stub_real_host
  install_login_shell "$REMOTE_HOME"
  login_shell_loads_ccfind "$REMOTE_HOME" "$REMOTE_CCFIND_DIR/ccfind.zsh"
  mkdir -p "$BATS_TEST_TMPDIR/srv/app"
  mk_session "$REMOTE_HOME/.claude" "$BATS_TEST_TMPDIR/srv/app" R1 "termx"
  # The line is printed before the session starts (a printed list is a
  # snapshot); the host's check happens when it is run, which is the point.
  run_ccfind -N -R -H nas termx
  local rcmd; rcmd="$(remote_resume_cmd)"
  mk_running "$REMOTE_HOME/.claude" R1
  run env HOME="$REMOTE_HOME" PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash -c "$rcmd" </dev/null
  assert_equal "$status" 1
  assert_contains "$output" "already running on nas (pid $RUN_PID"
  refute_contains "$output" "CLAUDE argv="
}

@test "remote resume: a host whose ccfind predates --resume gets the old command" {
  install_ssh_stub_real_host
  install_login_shell "$REMOTE_HOME"
  # What an older ccfind does with an option it does not know.
  printf 'ccfind() { print -u2 "ccfind: unknown option $1"; return 2; }\n' >> "$REMOTE_HOME/.shrc"
  mkdir -p "$BATS_TEST_TMPDIR/srv/app"
  mk_session "$REMOTE_HOME/.claude" "$BATS_TEST_TMPDIR/srv/app" R1 "termx"
  run_ccfind -N -R -H nas termx
  local rcmd; rcmd="$(remote_resume_cmd)"
  mk_running "$REMOTE_HOME/.claude" R1       # it cannot know; the old command does not check
  run env HOME="$REMOTE_HOME" PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash -c "$rcmd" </dev/null
  assert_equal "$status" 0
  assert_contains "$output" "CLAUDE argv=[--resume R1]"
  refute_contains "$output" "unknown option"
}

@test "remote resume: Enter sends the line the list prints, flags included" {
  install_fzf_stub_select
  install_ssh_stub_real_host
  mk_session "$REMOTE_HOME/.claude" "/srv/app" R1 "termx"
  run_ccfind -N -T -f -R -H nas termx
  local printed; printed="$(remote_resume_cmd)"
  # What the host's interactive shell runs, unquoted the layer -ic adds.
  local l2; l2="$(bash -c "printf '%s' ${printed#*-ic }")"
  assert_contains "$l2" "then ccfind --resume R1 --as nas --cfgdir $REMOTE_HOME/.claude --cwd /srv/app -T -f; else"
  run_ccfind -i -T -f -R -H nas termx
  local sent; sent="$(tail -1 "$SSH_LOG")"
  assert_equal "${sent#-t nas }" "$printed"
}

@test "remote resume: -H <host> --resume <id> asks that host" {
  install_ssh_stub_real_host
  run_ccfind -H nas --resume R1
  local sent; sent="$(tail -1 "$SSH_LOG")"
  assert_contains "$sent" "-t nas"
  assert_contains "$sent" "--resume"
  assert_contains "$sent" "R1"
}

@test "remote resume: --resume takes exactly one host" {
  run_ccfind -H "a b" --resume R1
  assert_equal "$status" 2
  assert_contains "$output" "--resume takes one host"
}

# --- markers: running now (green) and recent activity (yellow) ----------------
# A green ● marks a session running right now (Claude Code's own records,
# checked as for --resume); a yellow ● one whose transcript changed in the last
# CCFIND_RECENT minutes (default 15). Running wins. Without colour, recent is a
# hollow ○ so the two still differ. In the flat list a running hit says where
# it runs and prints what reaches it, never a resume line.

@test "marker: activity in the last 15 minutes is marked recent (○ without colour)" {
  export CCFIND_NOW=1800000000
  mk_session "$FIXHOME/.claude" "/proj/new" s1 "termx"; age_session "$FIXHOME/.claude" "/proj/new" s1 300
  mk_session "$FIXHOME/.claude" "/proj/old" s2 "termx"; age_session "$FIXHOME/.claude" "/proj/old" s2 1800
  run_ccfind -N termx
  assert_equal "$status" 0
  assert_contains "$output" "○ "
  assert_equal "$(grep -c '^○ .*/proj/new$' <<<"$output")" 1
  assert_equal "$(grep -c '^  .*/proj/old$' <<<"$output")" 1   # the column, kept aligned
}

@test "marker: recent is yellow with colour on" {
  export CCFIND_NOW=1800000000 CCFIND_COLOR=always
  mk_session "$FIXHOME/.claude" "/proj/new" s1 "termx"; age_session "$FIXHOME/.claude" "/proj/new" s1 60
  run_ccfind -N termx
  assert_contains "$output" $'\033[1;33m●\033[0m '
  refute_contains "$output" "○"
}

@test "marker: CCFIND_RECENT widens the window, 0 turns it off" {
  export CCFIND_NOW=1800000000
  mk_session "$FIXHOME/.claude" "/proj/old" s2 "termx"; age_session "$FIXHOME/.claude" "/proj/old" s2 1800
  export CCFIND_RECENT=60
  run_ccfind -N termx
  assert_equal "$(grep -c '^○ .*/proj/old$' <<<"$output")" 1
  export CCFIND_RECENT=0
  run_ccfind -N termx
  refute_contains "$output" "○"
  assert_equal "$(grep -c '^20.*/proj/old$' <<<"$output")" 1  # no marker column at all
}

@test "marker: a running session outside tmux is green, says where, and prints no resume" {
  install_claude_stub
  _stub_path_add "$BATS_TEST_TMPDIR/bin"
  mk_session "$FIXHOME/.claude" "/proj/a" S1 "termx"
  mk_running "$FIXHOME/.claude" S1
  run_ccfind -N termx
  assert_equal "$status" 0
  assert_equal "$(grep -c '^● .*/proj/a$' <<<"$output")" 1
  refute_contains "$output" "○"                       # running wins over recent
  assert_contains "$output" "   ● running (pid $RUN_PID, no terminal), outside tmux"
  assert_contains "$output" "(finish it there; ccfind -f --resume S1 starts a second one)"
  refute_contains "$output" "claude --resume S1"
}

@test "marker: a running session in a tmux pane prints the attach command" {
  install_tmux_stub
  mk_session "$FIXHOME/.claude" "/proj/a" S1 "termx"
  mk_running "$FIXHOME/.claude" S1 "$(tmux_sock default)" work 2 1
  run_ccfind -N termx
  assert_contains "$output" "   ● running in tmux session 'work' (window 2, pane 1)"
  assert_contains "$output" "   tmux attach -t '=work'"
  refute_contains "$output" "claude --resume S1"
}

@test "marker: a pane on a named tmux server is attached with -L" {
  install_tmux_stub
  mk_session "$FIXHOME/.claude" "/proj/a" S1 "termx"
  mk_running "$FIXHOME/.claude" S1 "$(tmux_sock svc)" svc
  run_ccfind -N termx
  assert_contains "$output" "   tmux -L svc attach -t '=svc'"
}

@test "marker: inside that tmux server, the list prints switch-client instead" {
  install_tmux_stub
  mk_session "$FIXHOME/.claude" "/proj/a" S1 "termx"
  local sock; sock="$(tmux_sock default)"
  mk_running "$FIXHOME/.claude" S1 "$sock" work
  export TMUX="$sock,123,0"
  run_ccfind -N termx
  assert_contains "$output" "   tmux switch-client -t '=work'"
  refute_contains "$output" "attach -t"
}

@test "marker: negative control: a record whose process is gone is not marked running" {
  mk_session "$FIXHOME/.claude" "/proj/a" S1 "termx"
  mk_running "$FIXHOME/.claude" S1
  kill "$RUN_PID" "$RUN_PANE_PID"; wait "$RUN_PANE_PID" 2>/dev/null || true
  run_ccfind -N termx
  refute_contains "$output" "● running"
  assert_contains "$output" "claude --resume S1"
}

@test "marker: the picker marks the running row green and field 12 says where" {
  install_fzf_stub
  mk_session "$FIXHOME/.claude" "/proj/a" S1 "termx one"
  mk_session "$FIXHOME/.claude" "/proj/b" S2 "termx two"
  mk_running "$FIXHOME/.claude" S1
  export CCFIND_COLOR=always CCFIND_RECENT=0
  run_ccfind -i termx
  local r1 r2
  r1="$(grep -P '^[^\t]*\t[^\t]*\t[^\t]*\tS1\t' "$FZF_ROWS" 2>/dev/null || awk -F'\t' '$4 == "S1"' "$FZF_ROWS")"
  r2="$(awk -F'\t' '$4 == "S2"' "$FZF_ROWS")"
  assert_contains "$(cut -f11 <<<"$r1")" $'\033[1;32m●\033[0m '
  assert_equal "$(cut -f12 <<<"$r1")" "running (pid $RUN_PID, no terminal), outside tmux"
  assert_equal "$(cut -f11 <<<"$r2" | cut -c1-2)" "  "     # unmarked rows keep the column
  assert_equal "$(cut -f12 <<<"$r2")" ""
  assert_contains "$(cat "$FZF_ARGV")" "_ccfind_preview {1} {8} {12}"
}

@test "marker: the preview header says where the session is running" {
  local f="$FIXHOME/.claude/projects/-p/S1.jsonl"
  mk_transcript "$f" "hello" "hi"
  run env HOME="$FIXHOME" NO_COLOR=1 CCFIND_LOCAL_LABELS="local" \
      zsh -fc 'src=$1; shift; source "$src"; _ccfind_preview "$@"' _ "$CCFIND_ZSH" \
      local "$f" "running in tmux session 'work' (window 0, pane 0)"
  assert_contains "$output" "● running in tmux session 'work' (window 0, pane 0)"
  run env HOME="$FIXHOME" NO_COLOR=1 CCFIND_LOCAL_LABELS="local" \
      zsh -fc 'src=$1; shift; source "$src"; _ccfind_preview "$@"' _ "$CCFIND_ZSH" local "$f" ""
  refute_contains "$output" "●"
}

@test "marker: --json carries running (null when not running)" {
  install_tmux_stub
  mk_session "$FIXHOME/.claude" "/proj/a" S1 "termx one"
  mk_session "$FIXHOME/.claude" "/proj/b" S2 "termx two"
  mk_running "$FIXHOME/.claude" S1 "$(tmux_sock svc)" svc 1 0
  run_ccfind --json termx
  assert_equal "$status" 0
  run python3 -c '
import json, sys
r = {x["id"]: x["running"] for x in json.load(sys.stdin)["results"]}
print(r["S2"]); s = r["S1"]
print(s["in_tmux"], s["tmux_server"], s["tmux_session"], s["tmux_window"], s["tmux_pane"])' <<<"$output"
  assert_equal "${lines[0]}" "None"
  assert_equal "${lines[1]}" "True -L svc svc 1 0"
}

@test "marker: --running lists only running sessions" {
  mk_session "$FIXHOME/.claude" "/proj/a" S1 "termx one"
  mk_session "$FIXHOME/.claude" "/proj/b" S2 "termx two"
  mk_running "$FIXHOME/.claude" S2
  run_ccfind -N --running termx
  assert_equal "$status" 0
  assert_contains "$output" "/proj/b"
  refute_contains "$output" "/proj/a"
}

@test "marker: --running keeps a long-idle running session newer hits would cap away" {
  export CCFIND_NOW=1800000000
  mk_session "$FIXHOME/.claude" "/proj/idle" S1 "termx"; age_session "$FIXHOME/.claude" "/proj/idle" S1 7200
  mk_session "$FIXHOME/.claude" "/proj/new" S2 "termx";  age_session "$FIXHOME/.claude" "/proj/new" S2 60
  mk_running "$FIXHOME/.claude" S1
  run_ccfind -N -n 1 --running termx
  assert_contains "$output" "/proj/idle"
  refute_contains "$output" "/proj/new"
}

@test "marker: --running with nothing running says so" {
  mk_session "$FIXHOME/.claude" "/proj/a" S1 "termx"
  run_ccfind -N --running termx
  assert_contains "$output" "No matching sessions."
  assert_contains "$output" "running sessions only"
}

@test "marker: --tsv sends #running lines only when the caller asks" {
  mk_session "$FIXHOME/.claude" "/proj/a" S1 "termx"
  mk_running "$FIXHOME/.claude" S1
  run_ccfind --tsv termx
  refute_contains "$output" "#running"              # what an older caller gets: nothing new
  export CCFIND_STATUS=1
  run_ccfind --tsv termx
  assert_contains "$output" "#running"$'\t'"S1"$'\t'"term"$'\t'"$RUN_PID"$'\t'
}

@test "marker: a host's own ccfind reports what runs there" {
  install_ssh_stub_real_host
  mk_session "$REMOTE_HOME/.claude" "/srv/app" R1 "termx"
  mk_running "$REMOTE_HOME/.claude" R1
  run_ccfind -N -R -H nas termx
  assert_equal "$status" 0
  assert_contains "$output" "● running on nas (pid $RUN_PID, no terminal), outside tmux"
  assert_contains "$output" "(finish it there; ccfind -H nas -f --resume R1 starts a second one)"
}

@test "marker: a session in a host's tmux pane prints ssh + attach" {
  install_ssh_stub_real_host
  install_tmux_stub
  mk_session "$REMOTE_HOME/.claude-personal" "/srv/side" R2 "termx"
  mk_running "$REMOTE_HOME/.claude-personal" R2 "$(tmux_sock svc)" svc
  run_ccfind -N -R -H nas termx
  assert_contains "$output" "running in tmux session 'svc' (window 0, pane 0) on nas"
  assert_contains "$output" "   ssh -t nas tmux -L svc attach -t '=svc'"
}

@test "marker: --running asks the host to narrow, and --json carries its status" {
  install_ssh_stub_real_host
  mk_session "$REMOTE_HOME/.claude" "/srv/a" R1 "termx one"
  mk_session "$REMOTE_HOME/.claude" "/srv/b" R2 "termx two"
  mk_running "$REMOTE_HOME/.claude" R2
  run_ccfind -R -H nas --running --json termx
  run python3 -c '
import json, sys
d = json.load(sys.stdin)["results"]
print(len(d), d[0]["id"], d[0]["host"], d[0]["running"]["pid"])' <<<"$output"
  assert_equal "$output" "1 R2 nas $RUN_PID"
}

@test "marker: a host without ccfind sends no status; nothing breaks, --running shows none" {
  install_ssh_stub_bare_host
  mk_session "$REMOTE_HOME/.claude" "/srv/app" R1 "termx"
  mk_running "$REMOTE_HOME/.claude" R1
  run_ccfind -N -R -H nas termx
  assert_equal "$status" 0
  assert_contains "$output" "nas:/srv/app"
  refute_contains "$output" "● running"
  run_ccfind -N -R -H nas --running termx
  assert_contains "$output" "No matching sessions."
}

@test "marker: --running narrows ON the host, before its cap" {
  # With -n 1 the host only ever sends its newest hit. Only if it narrowed to
  # running sessions first can a long-idle running one arrive at all.
  install_ssh_stub_real_host
  export CCFIND_NOW=1800000000
  mk_session "$REMOTE_HOME/.claude" "/srv/idle" R1 "termx"; age_session "$REMOTE_HOME/.claude" "/srv/idle" R1 7200
  mk_session "$REMOTE_HOME/.claude" "/srv/new" R2 "termx";  age_session "$REMOTE_HOME/.claude" "/srv/new" R2 60
  mk_running "$REMOTE_HOME/.claude" R1
  run_ccfind -N -n 1 -R -H nas --running termx
  assert_contains "$output" "nas:rwork:/srv/idle"
  refute_contains "$output" "/srv/new"
}

# --- Remote Control server sessions ("anchors") are hidden ---------------------
# `claude remote-control` pre-creates one session for itself, not meant to be
# talked to. It is recognised while it runs: its record's bridgeSessionId is
# the claude.ai session named in a "standalone" bridge-pointer.json. Hidden by
# default everywhere; -a, or CCFIND_HIDE_RC=0, lists it. The fixture anchors
# here carry content on purpose: the rule must not be "empty transcript".

# mk_anchor <cfgdir> <cwd> <id> — a running Remote Control server session.
mk_anchor() {
  mk_session "$1" "$2" "$3" "termx anchor"
  mk_bridge_pointer "$1" "${2//[^a-zA-Z0-9]/-}" "session_ANCHOR_$3"
  RUN_BRIDGE="session_ANCHOR_$3" mk_running "$1" "$3"
}

@test "rc: a Remote Control server's own session is hidden by default" {
  mk_anchor "$FIXHOME/.claude" "/code" A1
  mk_session "$FIXHOME/.claude" "/proj/b" S2 "termx real"
  run_ccfind -N termx
  assert_equal "$status" 0
  assert_contains "$output" "/proj/b"
  refute_contains "$output" "A1"
}

@test "rc: -a lists it, labelled, with its running marker" {
  mk_anchor "$FIXHOME/.claude" "/code" A1
  run_ccfind -N -a termx
  assert_contains "$output" "Remote Control server"
  assert_contains "$output" "● running (pid $RUN_PID"
}

@test "rc: CCFIND_HIDE_RC=0 lists them for good, from the env or the .env" {
  mk_anchor "$FIXHOME/.claude" "/code" A1
  export CCFIND_HIDE_RC=0
  run_ccfind -N termx
  assert_contains "$output" "Remote Control server"
  unset CCFIND_HIDE_RC
  printf 'typeset CCFIND_HIDE_RC=0\n' > "${CCFIND_ZSH%/*}/.env"
  run_ccfind -N termx
  assert_contains "$output" "Remote Control server"
}

@test "rc: an unknown CCFIND_HIDE_RC warns and keeps hiding" {
  mk_anchor "$FIXHOME/.claude" "/code" A1
  export CCFIND_HIDE_RC=maybe
  run_ccfind -N termx
  assert_contains "$output" "CCFIND_HIDE_RC=maybe is not one of 1|0"
  refute_contains "$output" "Remote Control server"
}

@test "rc: a session started from claude.ai (its own claude.ai session) stays visible" {
  mk_anchor "$FIXHOME/.claude" "/code" A1
  mk_session "$FIXHOME/.claude" "/code" C1 "termx from claude.ai"
  RUN_BRIDGE="session_SOMETHING_ELSE" mk_running "$FIXHOME/.claude" C1
  run_ccfind -N termx
  assert_contains "$output" "termx from claude.ai"
  refute_contains "$output" "termx anchor"
}

@test "rc: negative control: a pointer that is not a server's (source != standalone) hides nothing" {
  mk_session "$FIXHOME/.claude" "/code" A1 "termx anchor"
  mk_bridge_pointer "$FIXHOME/.claude" "-code" "session_ANCHOR_A1" repl
  RUN_BRIDGE="session_ANCHOR_A1" mk_running "$FIXHOME/.claude" A1
  run_ccfind -N termx
  assert_contains "$output" "termx anchor"
}

@test "rc: negative control: once it stops running it is no longer recognised" {
  mk_anchor "$FIXHOME/.claude" "/code" A1
  kill "$RUN_PID" "$RUN_PANE_PID"; wait "$RUN_PANE_PID" 2>/dev/null || true
  run_ccfind -N termx
  assert_contains "$output" "termx anchor"
}

@test "rc: hidden before the cap, so it never takes a slot" {
  mk_session "$FIXHOME/.claude" "/proj/b" S2 "termx real"
  export CCFIND_NOW=1800000000
  age_session "$FIXHOME/.claude" "/proj/b" S2 600
  mk_anchor "$FIXHOME/.claude" "/code" A1      # newest
  run_ccfind -N -n 1 termx
  assert_contains "$output" "/proj/b"
}

@test "rc: --running leaves it out unless -a" {
  mk_anchor "$FIXHOME/.claude" "/code" A1
  run_ccfind -N --running termx
  assert_contains "$output" "No matching sessions."
  run_ccfind -N --running -a termx
  assert_contains "$output" "Remote Control server"
}

@test "rc: -v says how many it hid" {
  mk_anchor "$FIXHOME/.claude" "/code" A1
  run_ccfind -N -v termx
  assert_contains "$output" "hid 1 Remote Control server session(s) here (-a shows them)"
}

@test "rc: --json marks it with -a" {
  mk_anchor "$FIXHOME/.claude" "/code" A1
  mk_session "$FIXHOME/.claude" "/proj/b" S2 "termx real"
  run_ccfind --json -a termx
  run python3 -c '
import json, sys
r = {x["id"]: x["remote_control_server"] for x in json.load(sys.stdin)["results"]}
print(r["A1"], r["S2"])' <<<"$output"
  assert_equal "$output" "True False"
}

@test "rc: a host hides its own, and -a from the caller shows it, labelled" {
  install_ssh_stub_real_host
  mk_anchor "$REMOTE_HOME/.claude" "/srv/code" A1
  mk_session "$REMOTE_HOME/.claude" "/srv/b" S2 "termx real"
  run_ccfind -N -R -H nas termx
  assert_contains "$output" "nas:rwork:/srv/b"
  refute_contains "$output" "termx anchor"
  run_ccfind -R -H nas -a --json termx
  run python3 -c '
import json, sys
r = {x["id"]: (x["title"], x["remote_control_server"]) for x in json.load(sys.stdin)["results"]}
print(r["A1"])' <<<"$output"
  assert_equal "$output" "('Remote Control server', True)"
}

@test "rc: the caller decides for every host in the search" {
  # The host's own .env says list them; the caller hides them, so they stay
  # hidden. And a caller that lists them lists the host's too.
  install_ssh_stub_real_host
  printf 'typeset CCFIND_HIDE_RC=0\n' >> "$REMOTE_CCFIND_DIR/.env"
  mk_anchor "$REMOTE_HOME/.claude" "/srv/code" A1
  run_ccfind -N -R -H nas termx
  refute_contains "$output" "termx anchor"
  export CCFIND_HIDE_RC=0
  run_ccfind -N -R -H nas termx
  assert_contains "$output" "Remote Control server"
}
