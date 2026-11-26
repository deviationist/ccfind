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
  # ...and the file a real machine actually has, in the place it actually has
  # it: the GLOBAL config lives at ~/.claude.json, BESIDE ~/.claude, not inside
  # it. Modelling that asymmetry is the whole point — ~/.claude/.claude.json is
  # the file that does NOT exist on a normal machine, and pointing
  # CLAUDE_CONFIG_DIR at ~/.claude is what conjures it and triggers the
  # first-run wizard. A fixture without this cannot tell the two apart.
  mk_global_config "$FIXHOME/.claude.json"

  export CCFIND_INTERACTIVE=0     # always the flat list — deterministic, no TTY
  unset CCFIND_PROFILES CCFIND_HOSTS CCFIND_TABS CCFIND_MAX CCFIND_TMUX
  # Run from inside tmux, the suite would inherit $TMUX, and ccfind skips its
  # tmux launch whenever that is set — so every tmux test would quietly take
  # the plain path. The tests that want "already inside tmux" set it themselves.
  unset TMUX
  # tmux keeps each server's socket in $TMUX_TMPDIR/tmux-<uid>/, and ccfind asks
  # every socket there whether a session runs in one of its panes. Pointing it
  # at a per-test dir means the suite can never see, let alone attach to, the
  # developer's real tmux servers, whatever tmux is on PATH.
  export TMUX_TMPDIR="$BATS_TEST_TMPDIR/tmuxtmp"
  mkdir -p "$TMUX_TMPDIR/tmux-$UID"
  export TMUX_PANES="$BATS_TEST_TMPDIR/tmux-panes"
  : > "$TMUX_PANES"
  # Anything running these tests from inside a Claude Code session (or any
  # profile-switching wrapper) has CLAUDE_CONFIG_DIR exported; it would be
  # inherited by an executed resume line and mask what ccfind actually emits.
  unset CLAUDE_CONFIG_DIR
}

# ccfind_teardown — the counterpart to ccfind_setup, run after every test.
# Every stub, fixture and fake HOME already lives under $BATS_TEST_TMPDIR, which
# bats creates and destroys per test, and PATH/CCFIND_*/FZF_* are process state
# that dies with the test — so this is a belt-and-braces sweep of the fake bin
# plus one assertion that the isolation held: a fixture HOME that ever escaped
# $BATS_TEST_TMPDIR would mean the suite had been writing into a real ~/.claude.
ccfind_teardown() {
  case "$FIXHOME" in
    "$BATS_TEST_TMPDIR"/*) ;;
    *) printf 'isolation breach: FIXHOME=%s is outside %s\n' "$FIXHOME" "$BATS_TEST_TMPDIR" >&2
       return 1 ;;
  esac
  # The stand-in claudes mk_running left running.
  if [ -s "$BATS_TEST_TMPDIR/bg-pids" ]; then
    xargs kill 2>/dev/null < "$BATS_TEST_TMPDIR/bg-pids" || true
  fi
  rm -rf "$BATS_TEST_TMPDIR/bin"
}

# mk_global_config <path> — Claude Code's global config, onboarded. Only the
# fields this suite reasons about; the real file carries ~90 more.
mk_global_config() {
  mkdir -p "${1%/*}"
  cat > "$1" <<'JSON'
{
  "hasCompletedOnboarding": true,
  "numStartups": 42,
  "userID": "fixture",
  "projects": {}
}
JSON
}

# mk_session <config-dir> <cwd> <id> <text>
# Writes <config-dir>/projects/<encoded-cwd>/<id>.jsonl carrying a cwd field and
# some searchable text (mirrors how Claude Code stores transcripts).
# The encoding is Claude Code's: EVERY character outside [a-zA-Z0-9] becomes a
# "-", not just the slash — so /home/me/.zsh/x → -home-me--zsh-x. Fixtures that
# only flatten the slash cannot catch a scope bug on any dotted path.
mk_session() {
  local root="$1" cwd="$2" id="$3" text="$4"
  local enc="${cwd//[^a-zA-Z0-9]/-}"
  mkdir -p "$root/projects/$enc"
  printf '{"cwd":"%s","text":"%s"}\n' "$cwd" "$text" > "$root/projects/$enc/$id.jsonl"
  # A seat that is NOT the default one was set up deliberately, so on a real
  # machine it has its own onboarded .claude.json inside it. A default seat
  # (<home>/.claude) does not — its global config sits beside it as
  # <home>/.claude.json. Getting this backwards is exactly the bug, so the
  # fixture reproduces the asymmetry rather than papering over it.
  case "$root" in
    */.claude) ;;
    *) [ -f "$root/.claude.json" ] || mk_global_config "$root/.claude.json" ;;
  esac
}

# title_session <root> <cwd> <id> <kind> <title> — append a title record to a
# fixture session, in the shape Claude Code writes it: <kind> is `ai` (the
# generated title, {"type":"ai-title","aiTitle":…}), `custom` (/rename,
# {"type":"custom-title","customTitle":…}) or `summary` (the legacy record).
# <title> goes in verbatim, so a test can hand it JSON escapes.
title_session() {
  local root="$1" cwd="$2" id="$3" kind="$4" title="$5"
  local f="$root/projects/${cwd//[^a-zA-Z0-9]/-}/$id.jsonl"
  case "$kind" in
    ai)      printf '{"type":"ai-title","aiTitle":"%s","sessionId":"%s"}\n' "$title" "$id" >> "$f" ;;
    custom)  printf '{"type":"custom-title","customTitle":"%s","sessionId":"%s"}\n' "$title" "$id" >> "$f" ;;
    summary) printf '{"type":"summary","summary":"%s","leafUuid":"u1"}\n' "$title" >> "$f" ;;
  esac
}

# age_session <root> <cwd> <id> <seconds-ago> — backdate a fixture session's
# mtime by <seconds-ago> relative to $CCFIND_NOW, the clock the test froze. An
# assertion on "5h ago" is then about the formatter, not about when the suite
# happened to run. `date -r` takes an epoch on BSD and a FILE on GNU, so the
# GNU spelling is the fallback rather than a platform test.
age_session() {
  local root="$1" cwd="$2" id="$3" ago="$4"
  local enc="${cwd//[^a-zA-Z0-9]/-}" e stamp
  e=$(( ${CCFIND_NOW:?age_session needs CCFIND_NOW set and exported} - ago ))
  stamp="$(date -r "$e" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$e" +%Y%m%d%H%M.%S)"
  touch -t "$stamp" "$root/projects/$enc/$id.jsonl"
}

# run_ccfind <ccfind-args...> — run ccfind in an isolated zsh with the fixture
# HOME. Exported CCFIND_* vars set by the test propagate into the subprocess.
# stdin is closed: a question ccfind asks gets "nobody to ask" instead of
# waiting on the developer's terminal. run_ccfind_answer feeds it an answer.
run_ccfind() {
  run env HOME="$FIXHOME" zsh -fc 'src=$1; shift; source "$src"; ccfind "$@"' _ "$CCFIND_ZSH" "$@" </dev/null
}

# run_ccfind_answer <answer> <ccfind-args...> — the same, with <answer> typed
# at whatever ccfind asks.
run_ccfind_answer() {
  local ans="$1"; shift
  run env HOME="$FIXHOME" zsh -fc 'src=$1; shift; source "$src"; ccfind "$@"' _ "$CCFIND_ZSH" "$@" <<<"$ans"
}

# run_ccfind_in <dir> <ccfind-args...> — same, but from inside <dir>, for the
# flags whose scope defaults to $PWD.
run_ccfind_in() {
  local dir="$1"; shift
  run env HOME="$FIXHOME" zsh -fc 'cd -- "$1" || exit 1; src=$2; shift 2; source "$src"; ccfind "$@"' \
    _ "$dir" "$CCFIND_ZSH" "$@" </dev/null
}

# _stub_claim <path> — claim a name on the fake PATH, refusing to overwrite a
# stub that is already there. Two installers write `ssh` (canned host vs. real
# host) and two write `fzf` (cancel vs. select), so a test that calls both would
# silently get whichever ran last and quietly exercise a stub it never asked
# for. Bats runs test bodies under `set -e`, so failing here aborts the test
# with the conflict named instead of producing a confusing assertion later.
_stub_claim() {
  if [ -e "$1" ]; then
    printf 'stub conflict: %s already installed — a test may install only one %s stub\n' \
      "$1" "$(basename "$1")" >&2
    return 1
  fi
  mkdir -p "$(dirname "$1")"
}

# _stub_path_add <dir> — put the fake bin on PATH once, however many stubs a
# test installs.
_stub_path_add() {
  case ":$PATH:" in
    *":$1:"*) ;;
    *) export PATH="$1:$PATH" ;;
  esac
}

# install_ssh_stub — shadow `ssh` with a stub that answers as a host WITHOUT
# ccfind: the worker's fallback header, then one record in the wire format.
# ccfind calls `command ssh`, which honors PATH.
install_ssh_stub() {
  _stub_claim "$BATS_TEST_TMPDIR/bin/ssh" || return 1
  cat > "$BATS_TEST_TMPDIR/bin/ssh" <<'STUB'
#!/usr/bin/env bash
# header, then: epoch \t profile \t cfgdir \t id \t cwd \t ts \t snippet \t path
# No ccfind on this host, so the profile column is empty — one nameless seat.
printf '#ccfind mode=fallback reason=not-installed\n'
printf '1700000000\t\t/root/.claude\tRID123\t/remote/proj\t2024-01-01 12:00:00\tremote snippet\t/remote/proj/RID123.jsonl\n'
exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/ssh"
  _stub_path_add "$BATS_TEST_TMPDIR/bin"
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
  _stub_claim "$BATS_TEST_TMPDIR/bin/ssh" || return 1
  export REMOTE_HOME="$BATS_TEST_TMPDIR/remote-home"
  export REMOTE_CCFIND_DIR="$BATS_TEST_TMPDIR/remote-ccfind"
  mkdir -p "$REMOTE_HOME" "$REMOTE_CCFIND_DIR"
  mk_global_config "$REMOTE_HOME/.claude.json"   # as on a real host: beside ~/.claude
  cp "$CCFIND_SRC" "$REMOTE_CCFIND_DIR/ccfind.zsh"
  # The host's own profile config, where a real install keeps it: a .env beside
  # the script. This is the thing the caller cannot know and must ask for.
  cat > "$REMOTE_CCFIND_DIR/.env" <<ENV
typeset CCFIND_PROFILES="rwork:$REMOTE_HOME/.claude rpersonal:$REMOTE_HOME/.claude-personal"
ENV
  export SSH_LOG="$BATS_TEST_TMPDIR/ssh-log"
  cat > "$BATS_TEST_TMPDIR/bin/ssh" <<'STUB'
#!/usr/bin/env bash
# ccfind reaches a host three ways. The first two are run for real against the
# fake remote HOME; the third — a resume — is only recorded, because actually
# running it would exec an interactive shell.
cmd=""; for a in "$@"; do cmd="$a"; done       # the remote command is the last arg
printf '%s
' "$*" >> "$SSH_LOG"
cmd="${cmd#CCFIND_REMOTE_PATH=* }"             # drop the caller's hint; we set our own
case "$cmd" in
  *"sh -s"*|cat\ *)
    exec env HOME="$REMOTE_HOME" CCFIND_REMOTE_PATH="$REMOTE_CCFIND_DIR/ccfind.zsh" \
         sh -c "$cmd" ;;
  *) exit 0 ;;                                 # a resume: recorded, not run
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/ssh"
  _stub_path_add "$BATS_TEST_TMPDIR/bin"
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
# <dir> defaults to the fake bin, i.e. on PATH; install_login_shell puts it
# somewhere that is NOT, so only the rc's `claude` function can reach it.
install_claude_stub() {
  local bindir="${1:-$BATS_TEST_TMPDIR/bin}"
  _stub_claim "$bindir/claude" || return 1
  cat > "$bindir/claude" <<'STUB'
#!/usr/bin/env bash
# Where Claude Code looks for its GLOBAL config, as observed in the field:
# $CLAUDE_CONFIG_DIR/.claude.json when that variable is set, $HOME/.claude.json
# when it is not. A file that is missing, or present without
# hasCompletedOnboarding, is what puts the real thing into the first-run setup
# wizard (theme picker) instead of the session — the failure this suite exists
# to prevent. Reporting that verdict lets a test assert the SYMPTOM, not just
# the environment variable that causes it.
cfg="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
if [ ! -f "$cfg" ]; then
  verdict=SETUP-WIZARD
elif grep -q '"hasCompletedOnboarding"[[:space:]]*:[[:space:]]*true' "$cfg"; then
  verdict=RESUMED
else
  verdict=SETUP-WIZARD
fi
echo "CLAUDE argv=[$*] dir=[${CLAUDE_CONFIG_DIR-<unset>}] pwd=[$PWD] config=[$cfg] verdict=[$verdict]"
STUB
  chmod +x "$bindir/claude"
}

# install_login_shell <home...> — the user's login shell in miniature, made
# $SHELL: `-ic` reads ~/.shrc first and `-c` does not, the one property of a
# real shell the tmux launch depends on. Each <home> gets a ~/.shrc defining
# `claude` as a FUNCTION around the claude stub, which lives off PATH. That is
# the shape of the operator's own machine (`claude` is a zsh function from the
# rc, wrapping a binary that is also on PATH). The PATH copy here is a tripwire
# standing for that bare binary: a launch that skips the interactive shell
# reaches it, reports CLAUDE-BARE and fails — and the developer's REAL claude,
# which would otherwise be next on PATH, is never run by the suite.
install_login_shell() {
  _stub_claim "$BATS_TEST_TMPDIR/bin/loginsh" || return 1
  _stub_claim "$BATS_TEST_TMPDIR/bin/claude" || return 1
  install_claude_stub "$BATS_TEST_TMPDIR/rc-bin" || return 1
  cat > "$BATS_TEST_TMPDIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
echo "CLAUDE-BARE argv=[$*]: reached off PATH, the rc's claude wrapper was skipped"
exit 97
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  # zsh, as on the operator's machines: that is what lets a host's ~/.shrc
  # load ccfind (a zsh function), the way index.zsh does on a real server.
  cat > "$BATS_TEST_TMPDIR/bin/loginsh" <<'STUB'
#!/usr/bin/env zsh
case "$1" in
  -ic) [[ -r "$HOME/.shrc" ]] && source "$HOME/.shrc"; eval "$2" ;;
  -c)  eval "$2" ;;
  *)   print -u2 -r -- "loginsh: unexpected args: $*"; exit 2 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/loginsh"
  local h
  for h in "$@"; do
    mkdir -p "$h"
    printf 'claude() { %q "$@"; }\n' "$BATS_TEST_TMPDIR/rc-bin/claude" > "$h/.shrc"
  done
  export SHELL="$BATS_TEST_TMPDIR/bin/loginsh"
  _stub_path_add "$BATS_TEST_TMPDIR/bin"
}

# install_tmux_stub — shadow `tmux` with a model of the commands ccfind sends,
# keeping the behaviour the feature leans on:
#   - `-S <path>` / `-L <name>` pick the server; with neither, the server is the
#     one $TMUX names, else `default` in $TMUX_TMPDIR/tmux-<uid>/ (as tmux does);
#   - new-session runs its window as `$SHELL -c <shell-command>` in its -c dir
#     (tmux's default-shell is $SHELL), so the rc is NOT read there; -A on a
#     name that is still running attaches instead of starting a second claude;
#     -d starts it without attaching (run here in the foreground, to observe);
#   - list-panes -a answers from $TMUX_PANES (socket, pane pid, session, window,
#     pane per line). A socket with no panes answers like a socket file whose
#     server has exited: "no server running", status 1;
#   - has-session / switch-client / attach-session / select-window /
#     select-pane do what their names say, observably.
# $TMUX_STATE lists the sessions that are running. Real tmux drops a session
# when its claude exits; the model keeps it, standing for a claude still going,
# which is the case the reattach rule is about. Every call is logged to
# $TMUX_LOG, one argv per line, each arg in [brackets] so word splits show.
install_tmux_stub() {
  _stub_claim "$BATS_TEST_TMPDIR/bin/tmux" || return 1
  export TMUX_LOG="$BATS_TEST_TMPDIR/tmux-log" TMUX_STATE="$BATS_TEST_TMPDIR/tmux-state"
  : > "$TMUX_STATE"
  cat > "$BATS_TEST_TMPDIR/bin/tmux" <<'STUB'
#!/usr/bin/env bash
{ printf 'tmux'; printf ' [%s]' "$@"; printf '\n'; } >> "$TMUX_LOG"
sockdir="${TMUX_TMPDIR:-/tmp}/tmux-$UID"
if [ -n "$TMUX" ]; then sock="${TMUX%%,*}"; else sock="$sockdir/default"; fi
while :; do
  case "$1" in
    -S) sock="$2"; shift 2 ;;
    -L) sock="$sockdir/$2"; shift 2 ;;
    *)  break ;;
  esac
done
cmd="$1"; shift
target() { while [ $# -gt 0 ]; do [ "$1" = -t ] && { printf '%s' "$2"; return; }; shift; done; }
case "$cmd" in
  list-panes)
    out="$(awk -F'\t' -v s="$sock" '$1 == s { print $2 "\t" $3 "\t" $4 "\t" $5 }' "$TMUX_PANES")"
    [ -n "$out" ] || { echo "no server running on $sock" >&2; exit 1; }
    printf '%s\n' "$out"; exit 0 ;;
  has-session)
    t="$(target "$@")"; grep -qxF -- "${t#=}" "$TMUX_STATE"; exit $? ;;
  switch-client)   echo "TMUX switched to [$(target "$@")] on [$sock]"; exit 0 ;;
  attach-session|attach) echo "TMUX attached to [$(target "$@")] on [$sock]"; exit 0 ;;
  select-window|select-pane) exit 0 ;;
  new-session) ;;
  *) echo "tmux stub: unexpected command: $cmd" >&2; exit 2 ;;
esac
attach=0 name="" dir="$PWD"
while [ $# -gt 0 ]; do
  case "$1" in
    -A) attach=1 ;;
    -d) ;;
    -s) name="$2"; shift ;;
    -c) dir="$2"; shift ;;
    -*) echo "tmux stub: unexpected option: $1" >&2; exit 2 ;;
    *)  break ;;
  esac
  shift
done
[ $# -eq 1 ] || { echo "tmux stub: want one shell-command, got $#" >&2; exit 2; }
case "$name" in *[.:]*) echo "tmux stub: bad session name: $name" >&2; exit 1 ;; esac
if [ -n "$name" ] && grep -qxF -- "$name" "$TMUX_STATE"; then
  [ "$attach" = 1 ] && { echo "TMUX attached to [$name]"; exit 0; }
  echo "duplicate session: $name" >&2; exit 1
fi
printf '%s\n' "$name" >> "$TMUX_STATE"
echo "TMUX new session [$name] in [$dir]"
cd "$dir" || exit 1
"${SHELL:-/bin/sh}" -c "$1"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/tmux"
  _stub_path_add "$BATS_TEST_TMPDIR/bin"
}

# path_without_tmux — $PATH minus every dir that holds a tmux, for the tests
# about a machine that has none. Fails, so the caller can skip, when those dirs
# also hold what ccfind itself needs (on Linux, tmux sits in /usr/bin beside
# grep and awk, and no PATH can keep the one and lose the other).
path_without_tmux() {
  local d out="" t IFS=:
  for d in $PATH; do [ -x "$d/tmux" ] || out="${out:+$out:}$d"; done
  for t in zsh bash grep sed awk sort head stat mktemp; do
    PATH="$out" command -v "$t" >/dev/null 2>&1 || return 1
  done
  printf '%s' "$out"
}

# mk_session_record <cfgdir> <pid> <id> <procStart> <pidDomain> — the record
# Claude Code keeps for a running session, as it writes it: one line of
# compact JSON, no trailing newline, at <cfgdir>/sessions/<pid>.json. Only the
# fields ccfind reads plus a few neighbours; the real one carries ~20.
mk_session_record() {
  mkdir -p "$1/sessions"
  printf '{"pid":%s,"sessionId":"%s","cwd":"/somewhere","startedAt":1795649729270,"procStart":"%s","version":"2.1.332","kind":"interactive","entrypoint":"cli","pidDomain":"%s","status":"idle"}' \
    "$2" "$3" "$4" "$5" > "$1/sessions/$2.json"
}

# this_proc_start <pid> / this_pid_domain — procStart and pidDomain the way
# Claude Code computes them on this platform, as read off live records on
# 2026-11-26: on macOS the UTC `ps -o lstart` of the process and "darwin"; on
# Linux field 22 of /proc/<pid>/stat and "linux:<machine-id>:<pid namespace>".
this_proc_start() {
  case "$(uname -s)" in
    Darwin) TZ=UTC ps -o lstart= -p "$1" | sed 's/^ *//;s/ *$//' ;;
    *)      sed 's/.*) //' "/proc/$1/stat" | cut -d' ' -f20 ;;
  esac
}
this_pid_domain() {
  case "$(uname -s)" in
    Darwin) printf darwin ;;
    *)      printf 'linux:%s:%s' "$(cat /etc/machine-id 2>/dev/null)" "$(readlink /proc/self/ns/pid)" ;;
  esac
}

# mk_running <cfgdir> <id> [<socket> <tmux-session> [<window> <pane>]] — a
# claude that is running right now: a real process (sleep) under a bash that
# stays its parent, the way a tmux pane's process parents the real claude, plus
# the record Claude Code keeps for it. With a socket, that parent is registered
# as a pane of that tmux server. Sets RUN_PID (the "claude") and RUN_PANE_PID;
# teardown kills both.
mk_running() {
  local cfg="$1" id="$2" sock="${3:-}" sess="${4:-}" win="${5:-0}" pane="${6:-0}"
  local pf="$BATS_TEST_TMPDIR/run-$id.pid" i
  bash -c 'sleep 600 & echo $! > "$1"; wait' _ "$pf" </dev/null >/dev/null 2>&1 3>&- &
  RUN_PANE_PID=$!
  for i in $(seq 100); do [ -s "$pf" ] && break; sleep 0.05; done
  RUN_PID="$(cat "$pf")"
  printf '%s\n%s\n' "$RUN_PID" "$RUN_PANE_PID" >> "$BATS_TEST_TMPDIR/bg-pids"
  mk_session_record "$cfg" "$RUN_PID" "$id" "$(this_proc_start "$RUN_PID")" "$(this_pid_domain)"
  if [ -n "$sock" ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$sock" "$RUN_PANE_PID" "$sess" "$win" "$pane" >> "$TMUX_PANES"
  fi
}

# tmux_sock <name> — the path of tmux server <name>'s socket for this test
# (`default` is the plain `tmux` one), created as a file the way tmux leaves
# one behind, so a socket whose server is gone is modelled by simply giving
# it no panes.
tmux_sock() {
  local p="$TMUX_TMPDIR/tmux-$UID/$1"
  : > "$p"
  printf '%s' "$p"
}

# login_shell_loads_ccfind <home> <ccfind.zsh> — that home's interactive shell
# also loads ccfind, as index.zsh does on a real server.
login_shell_loads_ccfind() {
  printf 'source %q\n' "$2" >> "$1/.shrc"
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
  _stub_claim "$BATS_TEST_TMPDIR/bin/fzf" || return 1
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
  _stub_path_add "$BATS_TEST_TMPDIR/bin"
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
  _stub_claim "$bindir/claude-profile" || return 1
  cat > "$bindir/claude-profile" <<'STUB'
#!/bin/sh
[ "$1" = list ] || exit 2
printf 'daily\t%s/.claude\n' "$HOME"
printf 'client\t%s/.claude-work\tactive\n' "$HOME"
STUB
  chmod +x "$bindir/claude-profile"
  _stub_path_add "$bindir"
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

# install_fzf_stub_select — an fzf that SELECTS instead of cancelling: it prints
# the row at $FZF_PICK (default 1) and exits 0, the way fzf does on Enter. That
# takes ccfind past the picker and into the resume branch, which the cancelling
# stub never reaches. ANSI is stripped the way `fzf --ansi` strips it, so the
# row handed back is shaped exactly like the real one.
install_fzf_stub_select() {
  _stub_claim "$BATS_TEST_TMPDIR/bin/fzf" || return 1
  export FZF_PICK="${1:-1}"
  cat > "$BATS_TEST_TMPDIR/bin/fzf" <<'STUB'
#!/usr/bin/env bash
case "$1" in --version) echo "0.74.2 (stub)"; exit 0 ;; esac
sed -n "${FZF_PICK}p" | sed $'s/\033\\[[0-9;]*m//g'
exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/fzf"
  _stub_path_add "$BATS_TEST_TMPDIR/bin"
}

# mk_tabsdir <dir> <view...> — the state directory the tab bindings work over.
mk_tabsdir() {
  local d="$1"; shift
  mkdir -p "$d"
  printf '%s\n' "$@" > "$d/views"
  print 1 > "$d/cur" 2>/dev/null || echo 1 > "$d/cur"
  echo "keys here" > "$d/help"
  local i=1 v
  for v in "$@"; do echo "row for $v" > "$d/view-$i.rows"; i=$(( i + 1 )); done
}
