# Absolute path to this file — captured at source time so the fzf preview
# subshell can source us back in to call _ccfind_preview without hardcoding.
typeset -g _CCFIND_SOURCE="${${(%):-%x}:A}"

# ---- colour ----------------------------------------------------------------
# One seam for every SGR ccfind emits. Colour is OFF when stdout is not a
# terminal, so a piped or redirected run stays byte-plain and greppable (the
# test suite leans on exactly that); $CCFIND_COLOR=always|never forces it
# either way — `always` is what the README-SVG generator uses — and NO_COLOR
# (https://no-color.org) wins over the auto case.
#
# The palette sticks to the 8 basic ANSI colours rather than 256-colour codes,
# so it inherits whatever the terminal theme has decided those mean instead of
# fighting it. Roles, not decoration: the label colour is the one thing that
# says local-profile (cyan) vs remote-host (magenta) at a glance, and the hit
# colour is what makes a snippet show *why* the session matched.
#
# Assigns into its caller's scope: every _CCF_* name is declared `local` in
# ccfind, so nothing here leaks into the interactive shell. Keep that `local`
# list in sync with the names set below.
function _ccfind_colors() {
  local on=0
  case "${CCFIND_COLOR:-auto}" in
    always) on=1 ;;
    never)  on=0 ;;
    *)      [[ -z "${NO_COLOR:-}" && -t 1 ]] && on=1 ;;
  esac
  if (( on )); then
    _CCF_OFF=$'\033[0m'    _CCF_DIM=$'\033[2m'     _CCF_TS=$'\033[1m'
    _CCF_PROF=$'\033[36m'  _CCF_HOST=$'\033[35m'   _CCF_SNIP=$'\033[2m'
    _CCF_HIT=$'\033[1;33m' _CCF_CMD=$'\033[32m'    _CCF_KEY=$'\033[1m'
    _CCF_WARN=$'\033[33m'  _CCF_ERR=$'\033[31m'
  else
    _CCF_OFF='' _CCF_DIM='' _CCF_TS='' _CCF_PROF='' _CCF_HOST='' _CCF_SNIP=''
    _CCF_HIT='' _CCF_CMD='' _CCF_KEY='' _CCF_WARN='' _CCF_ERR=''
  fi
}

# _ccfind_hl <text> <query> <ctx> [<case-sensitive>] — wrap every occurrence of
# <query> in <text> with the hit colour, restoring <ctx> (the colour the run
# sits inside) after each one, and print the result. Matching folds case unless
# arg 4 is 1, so the highlight marks exactly what the grep matched on.
#
# Literal, not regex — the search itself is literal, and a query may well hold
# glob metacharacters. `${hay%%$q*}` is the trick: a parameter expanded into
# a pattern position is NOT itself re-read as a pattern in zsh, so $q matches
# verbatim while the `*` written here stays a wildcard; `%%` takes the longest
# suffix, leaving the shortest prefix = the first occurrence.
function _ccfind_hl() {
  local s="$1" q="$2" ctx="$3" cs="${4:-0}" out="" pre rest hay lq
  if [[ -z "$s" || -z "$q" || -z "$_CCF_HIT" ]]; then print -rn -- "$s"; return; fi
  (( cs )) && lq="$q" || lq="${(L)q}"
  rest="$s"
  while [[ -n "$rest" ]]; do
    if (( cs )); then
      hay="$rest"
    else
      hay="${(L)rest}"
      (( ${#hay} == ${#rest} )) || break    # a case fold that changed the length
    fi                                      # (non-ASCII) breaks the 1:1 index map
    pre="${hay%%$lq*}"
    (( ${#pre} == ${#hay} )) && break        # no further occurrence
    out+="${rest[1,${#pre}]}${_CCF_HIT}${rest[${#pre}+1,${#pre}+${#lq}]}${_CCF_OFF}${ctx}"
    rest="${rest[${#pre}+${#lq}+1,-1]}"
  done
  print -rn -- "$out$rest"
}

# Strip SGR runs from a string. fzf --ansi returns a selected line with the
# escapes it parsed already removed, so this is a no-op on that path — but the
# picker is fed *coloured* rows, and a row that ever came back carrying escapes
# would turn a profile label into an unknown host (i.e. an ssh attempt at a
# machine named "\033[36mwork"). Cheap enough to rule out rather than trust.
# Written as a loop, not a glob: the `#` quantifier needs extended_glob, which
# ccfind deliberately does not turn on.
function _ccfind_strip_sgr() {
  local s="$1" out="" pre
  while [[ "$s" == *$'\033['* ]]; do
    pre="${s%%$'\033['*}"; out+="$pre"
    s="${s#*$'\033['}"; s="${s#*m}"
  done
  print -rn -- "$out$s"
}

# ---- age -------------------------------------------------------------------
# "when" and "how long ago" are different questions. The mtime answers the
# first and is what you want once you know which session you mean; the age
# answers the second and is what you want while scanning a list, where doing
# date arithmetic in your head is the whole cost. Both come off the epoch the
# record already carries, so showing them together costs nothing but columns.

# _ccfind_now — the clock, as one seam. $CCFIND_NOW freezes it, which is what
# lets the tests and the README-SVG generator produce the same bytes twice.
function _ccfind_now() {
  [[ -n "${CCFIND_NOW:-}" ]] && { print -rn -- "$CCFIND_NOW"; return 0 }
  zmodload -F zsh/datetime p:EPOCHSECONDS 2>/dev/null
  if [[ -n "${EPOCHSECONDS:-}" ]]; then print -rn -- "$EPOCHSECONDS"
  else                                  print -rn -- "$(date +%s)"; fi
}

# _ccfind_rel <epoch> <now> — render an age: "just now", "42m ago", "5h ago".
#
# One unit, always, and truncated rather than rounded: this column is scanned,
# not read, so "1h ago" beats "1h 12m ago" and a row must never claim to be
# newer than it is. Months and years are the average-length kind — an age past
# a month is being read as "ages ago", not as a date.
#
# A remote hit carries the *host's* epoch, so a host whose clock runs fast makes
# the delta negative. No clamp is needed for that: the first bucket is `d < 60`,
# which a negative delta satisfies, so a fast clock reads "just now" — which is
# what it should say — rather than "-1m ago".
function _ccfind_rel() {
  local -i now="$2" d
  [[ "$1" == <-> ]] || return 0        # no epoch (or not a number): no age
  (( d = now - $1 ))
  if   (( d <       60 )); then print -rn -- "just now"
  elif (( d <     3600 )); then print -rn -- "$(( d / 60 ))m ago"
  elif (( d <    86400 )); then print -rn -- "$(( d / 3600 ))h ago"
  elif (( d <   604800 )); then print -rn -- "$(( d / 86400 ))d ago"
  elif (( d <  2592000 )); then print -rn -- "$(( d / 604800 ))w ago"
  elif (( d < 31536000 )); then print -rn -- "$(( d / 2592000 ))mo ago"
  else                          print -rn -- "$(( d / 31536000 ))y ago"
  fi
}

# _ccfind_claude_profiles — print "<label>\t<dir>" for every profile
# claude-profile knows about, or nothing if it is not installed here.
#
# The other way to be multi-profile. `claude-profile list` prints exactly
# "<name>\t<dir>[\tactive]", which is already the shape ccfind wants, and it is
# porcelain claude-profile keeps byte-identical for consumers — so this parses
# the sanctioned interface rather than reaching into its config.json.
#
# Three ways to reach it, in order of how much they can be trusted to exist:
# an explicit $CCFIND_PROFILE_CMD; the command itself, which in an interactive
# shell is the function claude-profile.zsh defines; and finally the .py at the
# conventional install paths — needed because the remote worker runs `zsh -f`,
# where no rc has run and no function exists (the same reason ccfind itself has
# to be found by path out there).
function _ccfind_claude_profiles() {
  local out=""
  if [[ -n "${CCFIND_PROFILE_CMD:-}" ]]; then
    out="$(${(z)CCFIND_PROFILE_CMD} list 2>/dev/null)"
  fi
  if [[ -z "$out" ]] && (( ${+commands[claude-profile]} + ${+functions[claude-profile]} )); then
    out="$(claude-profile list 2>/dev/null)"
  fi
  if [[ -z "$out" ]] && command -v python3 >/dev/null 2>&1; then
    local _c
    for _c in "${CCFIND_PROFILE_PATH:-}" "$HOME/claude-profile/claude-profile.py" \
              "$HOME/.zsh/claude-profile/claude-profile.py" \
              "$HOME/.config/claude-profile/claude-profile.py"; do
      [[ -n "$_c" && -r "$_c" ]] || continue
      out="$(python3 "$_c" list 2>/dev/null)" && [[ -n "$out" ]] && break
    done
  fi
  print -rn -- "$out"
}

# _ccfind_json_str <text> — print <text> as a JSON string literal, quotes and
# all. Everything JSON forbids raw inside a string, escaped in the one order
# that works: backslashes first (or every escape added below would be escaped
# again), then quotes, then the whitespace controls by name, then whatever
# control characters are left dropped — a path may legally contain any of them,
# and one unescaped byte would make the whole document unparseable.
# UTF-8 passes through untouched: JSON strings are Unicode, \u escapes optional.
function _ccfind_json_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//[[:cntrl:]]/}"
  print -rn -- "\"$s\""
}

# Render the last few user/assistant messages of a transcript file for the
# fzf preview pane. Defined at top level (not nested in ccfind) so the
# preview subshell can source-and-call it cleanly.
#
# args: <host> <file>  — host "local" reads the file directly; any other
# host fetches the transcript over ssh into $CCFIND_PV_CACHE (one fetch per
# session per ccfind invocation, then reused while toggling the preview).
# Single-arg form `_ccfind_preview <file>` is accepted and treated as local.
function _ccfind_preview() {
  local host="$1" f="$2"
  if [[ -z "$f" ]]; then f="$host"; host="local"; fi
  local label="$f"
  # Local if the host tag is "local" or one of the configured profile labels
  # (passed in via CCFIND_LOCAL_LABELS); otherwise it's a remote host to ssh to.
  local -a _locals=(local ${(s: :)CCFIND_LOCAL_LABELS})
  if [[ -n "$host" && ${_locals[(Ie)$host]} -eq 0 ]]; then
    label="$host:$f"
    local cdir="${CCFIND_PV_CACHE:-${TMPDIR:-/tmp}}"
    local cache="$cdir/ccfind-pv-${host//\//_}-${f:t}"
    if [[ ! -s "$cache" ]]; then
      command ssh -o BatchMode=yes -o ConnectTimeout=6 -- "$host" \
        "cat ${(q)f}" >"$cache" 2>/dev/null
    fi
    [[ -s "$cache" ]] || { echo "preview: cannot fetch $label"; return 0; }
    f="$cache"
  fi
  [[ -r "$f" ]] || { echo "preview: cannot read $label"; return 0; }
  # The preview only ever renders into fzf's pane, so it colours unconditionally
  # (its stdout is a pipe — the -t 1 rule the rest of the tool uses would switch
  # colour off exactly where it is wanted). NO_COLOR is still honoured, here and
  # in the python below.
  if [[ -n "${NO_COLOR:-}" ]]; then
    printf '%s\n\n' "$label"
  elif [[ "$label" == *:* && "$label" != "$f" ]]; then
    printf '\033[35m%s\033[0m\033[2m:\033[0m\033[1m%s\033[0m\n\n' "${label%%:*}" "${label#*:}"
  else
    printf '\033[1m%s\033[0m\n\n' "$label"
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    tail -n 40 -- "$f" 2>/dev/null
    return 0
  fi
  python3 - "$f" <<'PYEOF'
import sys, json
try:
    with open(sys.argv[1], encoding='utf-8', errors='replace') as fh:
        lines = fh.readlines()
except Exception as e:
    print(f"preview error: {e}")
    sys.exit(0)

import os

# Colour is on unless NO_COLOR: this renders into fzf's preview pane, never
# into a pipe a script would parse.
_C = "NO_COLOR" not in os.environ
def sgr(code):
    return f"\033[{code}m" if _C else ""
BOLD, DIM, RESET = sgr(1), sgr(2), sgr(0)
USERC, ASSTC = sgr("1;36"), sgr("1;35")   # cyan / magenta role labels
HIT = sgr("1;33")                          # the search term, as in the list

# The query ccfind matched on, so the preview can show *where* it hit rather
# than leaving you to spot it. Empty for a no-query listing. CCFIND_PV_CASE is
# the resolved case mode of the run that produced the hit ("1" = case-sensitive),
# so the preview marks exactly what the grep matched and not a near-miss.
QUERY = os.environ.get("CCFIND_PV_QUERY", "")
CASE = os.environ.get("CCFIND_PV_CASE", "") == "1"


def hl(text, ctx=""):
    """Wrap occurrences of QUERY in the hit colour, restoring `ctx` after each —
    the literal-substring twin of the shell's _ccfind_hl. Folds case unless the
    run was case-sensitive."""
    if not QUERY or not HIT:
        return text
    if CASE:
        hay, lq = text, QUERY
    else:
        hay, lq = text.lower(), QUERY.lower()
        if len(hay) != len(text) or len(lq) != len(QUERY):
            return text        # a case fold changed the length: indices no longer map
    out, i = [], 0
    while True:
        j = hay.find(lq, i)
        if j < 0:
            break
        out.append(text[i:j])
        out.append(HIT + text[j:j + len(lq)] + RESET + ctx)
        i = j + len(lq)
    out.append(text[i:])
    return "".join(out)


MAX_MSGS = 8       # show this many most-recent user+assistant messages
MAX_CHARS = 1200   # per-message text cap

records = []
for line in lines:
    try:
        m = json.loads(line)
    except Exception:
        continue
    t = m.get("type")
    if t not in ("user", "assistant"):
        continue
    msg = m.get("message") if isinstance(m.get("message"), dict) else {}
    content = msg.get("content")
    parts = []
    if isinstance(content, str):
        parts.append(content)
    elif isinstance(content, list):
        for b in content:
            if not isinstance(b, dict):
                continue
            bt = b.get("type")
            if bt == "text":
                parts.append(b.get("text", ""))
            elif bt == "tool_use":
                parts.append(f"{DIM}[tool: {b.get('name','?')}]{RESET}")
            elif bt == "tool_result":
                parts.append(f"{DIM}[tool result]{RESET}")
            elif bt == "thinking":
                continue  # internal reasoning — skip
            else:
                parts.append(f"{DIM}[{bt}]{RESET}")
    text = "\n".join(p for p in parts if p).strip()
    if not text:
        continue
    if len(text) > MAX_CHARS:
        text = text[:MAX_CHARS] + f"{DIM}…[truncated]{RESET}"
    records.append((t, text))

total = len(records)
records = records[-MAX_MSGS:]
if not records:
    print(f"{DIM}(no user/assistant messages with text content){RESET}")
    sys.exit(0)

# How much of the session you are actually looking at — without this the pane
# reads like the whole transcript.
shown = f"last {len(records)} of {total} messages" if total > len(records) \
        else f"{total} message" + ("s" if total != 1 else "")
print(f"{DIM}{shown}{RESET}\n")

for t, text in records:
    label, col = ("USER", USERC) if t == "user" else ("ASSISTANT", ASSTC)
    print(f"{col}── {label} ──{RESET}")
    print(hl(text))
    print()
PYEOF
}

# Tab-bar helpers for the optional per-host picker views (CCFIND_TABS=1,
# multi-host mode, fzf ≥ 0.45). fzf has no native tabs — this emulates them
# with transform bindings: Tab/Shift-Tab rotate a 1-based index in a state
# dir and emit a reload(...)+change-header{...} action chain back to fzf.
# State dir layout: views (one name per line), cur (current index), help
# (static key-hint text), view-<i>.rows (per-view fzf input, same TSV).
function _ccfind_tab_header() {
  local dir="$1"
  local -a v; v=("${(@f)$(<"$dir/views")}")
  local cur; cur="$(<"$dir/cur")"
  local out="" i
  for (( i = 1; i <= ${#v}; i++ )); do
    if (( i == cur )); then
      out+=$'\033[1;7m '"${v[i]}"$' \033[0m '
    else
      out+=$'\033[2m '"${v[i]}"$' \033[0m '
    fi
  done
  print -rn -- "$out $(<"$dir/help")"
}

function _ccfind_tab_shift() {
  local dir="$1" step="${2:-1}"
  local -a v; v=("${(@f)$(<"$dir/views")}")
  local n=${#v}
  local cur; cur="$(<"$dir/cur")"
  cur=$(( (cur - 1 + step + n) % n + 1 ))
  print -r -- "$cur" >"$dir/cur"
  print -rn -- "reload(cat -- ${(q)dir}/view-$cur.rows)+change-header{$(_ccfind_tab_header "$dir")}+first"
}

# ccfind — search Claude Code session transcripts across working dirs.
#
# `claude --resume` only lists sessions whose cwd matches the current dir, so
# past conversations feel siloed. Every session is actually a .jsonl transcript
# under ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl — this greps the
# whole tree (or a chosen subtree), newest first, and either drops into an
# fzf picker (default when fzf + TTY are available) or prints the exact
# resume command for each hit.
#
#   ccfind <text...>            literal, case-insensitive search of all sessions
#   ccfind -d <dir> <text...>   only sessions whose cwd is <dir> or below it
#   ccfind -d . <text...>       scope to the current directory's subtree
#   ccfind -x <text...>         only sessions whose cwd is EXACTLY $PWD —
#                               no subdirectories (`-x -d <dir>` for another dir)
#   ccfind -s <text...>         match case-sensitively; -I forces insensitive
#   ccfind -S <text...>         smart-case: sensitive only if <text> has a capital
#   ccfind [-d <dir>]           no query → list the most recent sessions
#   ccfind -N <text...>         force the flat-list output (skip the picker)
#   ccfind -r <text...>         also search the configured remote hosts
#   ccfindr <text...>           alias for `ccfind -r` (defined in ~/.zshrc)
#   ccfind -l <text...>         force local only (trumps -r / -H)
#   ccfind -H "host-a host-b" ... search these ssh hosts (implies remote,
#                               overrides CCFIND_HOSTS)
#   ccfind <profile> <text...>  scope the LOCAL search to one CCFIND_PROFILES
#   ccfind -p <profile> <text>  profile (e.g. `ccfind work foo`); omit it to
#                               search every configured profile at once
#
# Case matching (CCFIND_CASE, env or the .env beside this file) picks the
# default the flags then override per call: `insensitive` (the default, and what
# ccfind has always done), `sensitive`, or `smart` — insensitive until the query
# itself carries a capital, the convention rg/fzf/vim share. Smart is resolved
# once, against the query, BEFORE any host is dialled, so every machine in a
# fan-out matches identically instead of each re-reading the query for itself.
#
# Multi-host search (opt-in per call): set CCFIND_HOSTS to a space/comma-
# separated list of ssh aliases (exported, or in the .env beside this file), then pass
# -r/--remote — or use the ccfindr alias — to fan the same search out to
# each host's ~/.claude/projects in parallel — the grep runs remotely, only
# per-hit metadata comes back. Remote hits are merged newest first with the
# local ones and get a host column; Enter resumes over `ssh -t <host>` (via
# an interactive shell, so PATH + any `claude` wrapper apply), and the
# → preview fetches the remote transcript on demand.
# Without -r/-H (the default) the search is purely local.
# Remote resume is overridable: set CCFIND_REMOTE_RESUME to a command/function and
# ccfind calls `<cmd> <host> <cwd> <session-id>` instead of its built-in ssh — e.g.
# to attach the session inside tmux/screen so it survives a dropped connection.
# Bonus (multi-host + picker only): CCFIND_TABS=1 adds per-host tab views —
# Tab/Shift-Tab cycle All → local → <host>, shown as a bar in the header
# (needs fzf ≥ 0.45; silently ignored below that).
#
# In the picker: ↑/↓ navigates, Enter cds to the session's recorded cwd
# (when different from $PWD) and runs `claude --resume <id>`, → opens a
# preview of the session's last user+assistant messages (← / Esc-the-preview
# hides it again), Esc cancels.
# Set CCFIND_INTERACTIVE=0 to make the flat list the persistent default.
function ccfind() {
  emulate -L zsh   # consistent zsh defaults (glob qualifiers) regardless of caller
  setopt local_options no_notify no_monitor   # silent background ssh fan-out
  local max="${CCFIND_MAX:-10}"
  local scope="" exact=0
  local interactive="${CCFIND_INTERACTIVE:-1}" interactive_forced=0
  local hosts_override="" local_only=0 remote=0 prof_filter="" color_override=""
  local emit="" verbose=0 case_override=""
  # Every colour slot _ccfind_colors fills. Declared local here (it assigns into
  # its caller's scope) so no SGR variable ever leaks into the interactive shell.
  local _CCF_OFF _CCF_DIM _CCF_TS _CCF_PROF _CCF_HOST _CCF_SNIP _CCF_HIT \
        _CCF_CMD _CCF_KEY _CCF_WARN _CCF_ERR
  # The fields a parsed row unpacks into, and the search scope — declared here
  # because the parser and the emitter below close over them and are defined
  # (and called) before the code that fills them in.
  local _f _id _cwd _ts _snippet _host _profile _cfgdir _path _epoch _rest
  local abs="" enc="" query=""

  while [[ "$1" == -* ]]; do
    case "$1" in
      -d|--dir) scope="$2"; shift 2 ;;
      -x|--exact) exact=1; shift ;;
      -n|--max) max="$2"; shift 2 ;;
      -i|--interactive) interactive=1; interactive_forced=1; shift ;;
      -N|--no-interactive) interactive=0; shift ;;
      -r|--remote) remote=1; shift ;;
      -l|--local) local_only=1; shift ;;
      -H|--hosts) hosts_override="$2"; shift 2 ;;
      -p|--profile) prof_filter="$2"; shift 2 ;;
      -s|--case-sensitive) case_override=sensitive; shift ;;
      -I|--ignore-case) case_override=insensitive; shift ;;
      -S|--smart-case) case_override=smart; shift ;;
      -C|--no-color|--no-colour) color_override=never; shift ;;
      -j|--json) emit=json; shift ;;
      --tsv) emit=tsv; shift ;;
      -v|--verbose) verbose=1; shift ;;
      -h|--help)
        echo "usage: ccfind [-d <dir>] [-x] [-n <max>] [-i|-N] [-s|-I|-S] [-r|-l] [-H <hosts>] [-p <profile>] [-C] [-v] [-j|--tsv] [<profile>] [text...]"
        echo "  -d <dir> scopes to that dir AND everything below it; -x/--exact narrows to"
        echo "  that one dir only (no subdirectories), and defaults the dir to \$PWD"
        echo "  matching is case-insensitive by default: -s/--case-sensitive forces case to"
        echo "  matter, -I/--ignore-case forces it not to, -S/--smart-case makes it matter"
        echo "  only when the query itself has a capital (CCFIND_CASE sets the default)"
        echo "  remote search is opt-in: -r (or the ccfindr alias) uses CCFIND_HOSTS"
        echo "  (env or the .env beside ccfind.zsh); -H <hosts> searches an explicit list; -l forces local"
        echo "  multi-profile (CCFIND_PROFILES): -p <label>, or a leading <label> arg, scopes to one profile"
        echo "  -C/--no-color strips the colour (as do NO_COLOR=1 and CCFIND_COLOR=never); output is"
        echo "  plain whenever stdout is not a terminal, so piping is unaffected either way"
        echo "  -j/--json prints the hits as JSON (--tsv for the same records tab-separated);"
        echo "  -v/--verbose notes on stderr what each host was actually searched with"
        return 0 ;;
      --) shift; break ;;
      *) echo "ccfind: unknown option $1" >&2; return 2 ;;
    esac
  done

  # Machine-readable output is never a picker and never coloured: it is data.
  if [[ -n "$emit" ]]; then interactive=0; interactive_forced=0; color_override=never; fi

  # Resolve the palette once the flags are known: -C is the loudest voice, then
  # $CCFIND_COLOR / NO_COLOR, then whether stdout is a terminal at all.
  [[ -n "$color_override" ]] && local CCFIND_COLOR="$color_override"
  _ccfind_colors

  # ---- Config. Exported env wins over the repo's .env (ccfind-only, so it is
  # safe to source on every call). Keys read: CCFIND_PROFILES/HOSTS/TABS; they
  # are pre-declared local before sourcing so nothing leaks to the shell.
  local _cfg_profiles="${CCFIND_PROFILES-}" _cfg_hosts="${CCFIND_HOSTS-}" _cfg_tabs="${CCFIND_TABS-}" _cfg_remote_resume="${CCFIND_REMOTE_RESUME-}" _cfg_remote_path="${CCFIND_REMOTE_PATH-}" _cfg_profile_path="${CCFIND_PROFILE_PATH-}" _cfg_time="${CCFIND_TIME-}" _cfg_case="${CCFIND_CASE-}"
  if [[ -z "$_cfg_profiles" || -z "$_cfg_hosts" || -z "$_cfg_tabs" || -z "$_cfg_remote_resume" || -z "$_cfg_remote_path" || -z "$_cfg_profile_path" || -z "$_cfg_time" || -z "$_cfg_case" ]]; then
    local _envf="${_CCFIND_SOURCE:h}/.env"
    if [[ -r "$_envf" ]]; then
      typeset CCFIND_PROFILES="" CCFIND_HOSTS="" CCFIND_TABS="" CCFIND_REMOTE_RESUME="" CCFIND_REMOTE_PATH="" CCFIND_PROFILE_PATH="" CCFIND_TIME="" CCFIND_CASE=""
      source "$_envf"
      [[ -z "$_cfg_profiles" ]]      && _cfg_profiles="$CCFIND_PROFILES"
      [[ -z "$_cfg_hosts" ]]         && _cfg_hosts="$CCFIND_HOSTS"
      [[ -z "$_cfg_tabs" ]]          && _cfg_tabs="$CCFIND_TABS"
      [[ -z "$_cfg_remote_resume" ]] && _cfg_remote_resume="$CCFIND_REMOTE_RESUME"
      [[ -z "$_cfg_remote_path" ]]   && _cfg_remote_path="$CCFIND_REMOTE_PATH"
      [[ -z "$_cfg_profile_path" ]]  && _cfg_profile_path="$CCFIND_PROFILE_PATH"
      [[ -z "$_cfg_time" ]]          && _cfg_time="$CCFIND_TIME"
      [[ -z "$_cfg_case" ]]          && _cfg_case="$CCFIND_CASE"
    fi
  fi

  # ---- Case matching. The flags are the loudest voice, then CCFIND_CASE, then
  # the historical default: fold case. `smart` cannot be resolved yet — it reads
  # the query, which the option loop has not reached — so this settles the MODE
  # here and the boolean further down, once $query exists. A typo falls back to
  # the default but says so: silently ignoring the setting looks identical to
  # the feature not working.
  local _case_mode="${case_override:-${_cfg_case:-insensitive}}"
  if [[ "$_case_mode" != (sensitive|insensitive|smart) ]]; then
    print -u2 -r -- "${_CCF_WARN}ccfind: CCFIND_CASE=${_cfg_case} is not one of sensitive|insensitive|smart — using insensitive${_CCF_OFF}"
    _case_mode=insensitive
  fi

  # ---- Time column. `both` (the default) prints the mtime and its age; `abs`
  # is the mtime alone, as ccfind printed it before ages existed; `rel` is the
  # age alone, for a narrow terminal where the snippet is worth more than the
  # date. A typo falls back to `both` — but says so, because silently ignoring
  # the setting looks identical to the feature not working.
  local _time_mode="${_cfg_time:-both}"
  if [[ "$_time_mode" != (abs|rel|both) ]]; then
    print -u2 -r -- "${_CCF_WARN}ccfind: CCFIND_TIME=${_cfg_time} is not one of abs|rel|both — using both${_CCF_OFF}"
    _time_mode=both
  fi
  # One clock reading for the whole run, so every age on screen is measured
  # from the same instant and a long listing cannot straddle a minute boundary.
  local _now=""
  [[ "$_time_mode" == abs ]] || _now="$(_ccfind_now)"

  # _ccfind_rel_token <epoch> — the row's age as it will be shown, plain: empty
  # in abs mode, bare ("5h ago") when it stands alone, parenthesised when it
  # trails a date. Plain because it gets padded to a column width first, and
  # padding a coloured string counts SGR bytes that draw nothing.
  local _rtok
  _ccfind_rel_token() {
    _rtok=""
    [[ "$_time_mode" == abs || -z "$1" ]] && return 0
    _rtok="$(_ccfind_rel "$1" "$_now")"
    [[ -n "$_rtok" && "$_time_mode" == both ]] && _rtok="($_rtok)"
  }

  # _ccfind_time_cell <width> <abs-colour> — the finished, coloured time cell
  # for the row currently parsed. Ages are right-aligned in <width> so the
  # column after them stays put whatever units the rows happen to land in.
  local _tcell
  _ccfind_time_cell() {
    _ccfind_rel_token "$_epoch"
    case "$_time_mode" in
      abs) _tcell="${2}${_ts}${_CCF_OFF}" ;;
      rel) _tcell="${2}${(l:$1:)_rtok}${_CCF_OFF}" ;;
      *)   _tcell="${2}${_ts}${_CCF_OFF}  ${_CCF_DIM}${(l:$1:)_rtok}${_CCF_OFF}" ;;
    esac
  }

  # _ccfind_rel_width <rows...> — the widest age among the rows about to be
  # shown, i.e. the natural column width, the same first-pass measure the
  # picker already makes for its host and cwd columns.
  integer w_rel=0
  _ccfind_rel_width() {
    w_rel=0
    [[ "$_time_mode" == abs ]] && return 0
    local _rw
    for _rw in "$@"; do
      _ccfind_parse_row "$_rw"; _ccfind_rel_token "$_epoch"
      (( ${#_rtok} > w_rel )) && w_rel=${#_rtok}
    done
  }

  # Sequential field parser for a row:
  #   host \t profile \t cfgdir \t id \t cwd \t ts \t snippet \t path \t epoch
  # Sequential rather than a split so an empty field — an unconfigured machine
  # has no profile label — stays an empty field instead of vanishing.
  #
  # The epoch rides at the END rather than the front (where the sortable record
  # keeps it) so that fields 1-8 hold the positions the fzf bindings name. Rows
  # reach here in three lengths: 8 fields from the emitter, which reads the
  # epoch off the record itself; 9 as displayed; 10 back out of the picker, with
  # the composed display field appended. Hence path is taken non-greedily and a
  # missing 9th field leaves _epoch empty rather than a copy of the path.
  _ccfind_parse_row() {
    _rest="$1"
    [[ "$_rest" == *$'\033['* ]] && _rest="$(_ccfind_strip_sgr "$_rest")"
    _host="${_rest%%$'\t'*}";    _rest="${_rest#*$'\t'}"
    _profile="${_rest%%$'\t'*}"; _rest="${_rest#*$'\t'}"
    _cfgdir="${_rest%%$'\t'*}";  _rest="${_rest#*$'\t'}"
    _id="${_rest%%$'\t'*}";      _rest="${_rest#*$'\t'}"
    _cwd="${_rest%%$'\t'*}";     _rest="${_rest#*$'\t'}"
    _ts="${_rest%%$'\t'*}";      _rest="${_rest#*$'\t'}"
    _snippet="${_rest%%$'\t'*}"; _rest="${_rest#*$'\t'}"
    _path="${_rest%%$'\t'*}"
    if [[ "$_rest" == *$'\t'* ]]; then _epoch="${${_rest#*$'\t'}%%$'\t'*}"
    else                               _epoch=""; fi
  }

  # A row's own machine: "local" is this one, anything else is an ssh alias.
  _ccfind_is_local() { [[ "$1" == local ]] }

  # Whether a hit's config dir has to be named on the resume line. Naming
  # $HOME/.claude — the dir claude falls back to when the variable is unset —
  # is NOT the no-op it looks like: CLAUDE_CONFIG_DIR also relocates the global
  # .claude.json, from $HOME/.claude.json to $CLAUDE_CONFIG_DIR/.claude.json.
  # That second file has never been through onboarding, so pinning the default
  # seat drops you into the first-run setup wizard instead of the session. The
  # default seat therefore resumes with nothing set, exactly as a bare
  # `claude --resume` would — it keeps its label, it just stops being exported.
  _ccfind_pin_cfgdir() {   # <cfgdir> → true when it must be exported
    [[ -n "$1" && "${1%/}" != "${HOME%/}/.claude" ]]
  }

  # ---- machine-readable output ---------------------------------------------
  # Same records the picker and the list are built from, handed over verbatim.
  # --tsv is the wire format the remote worker speaks (and the reason a host
  # with ccfind can report profiles the caller has never heard of); --json is
  # the same thing for human consumption and jq.
  # Called at every exit that produces no rows as well as at the normal one, so
  # a consumer always gets a well-formed document: "No matching sessions." where
  # a document belongs is indistinguishable from a broken run — and the remote
  # worker would happily parse that sentence into a record.
  _ccfind_emit() {
    local _e_epoch _first=1
    # Take the slice once, and drop empties: in zsh — unlike bash — slicing an
    # array that was never assigned yields a single EMPTY element under quotes,
    # which is exactly the shape the no-results exits call this with, and it
    # would emit one blank record into an otherwise empty document.
    local -a _recs
    _recs=("${merged[@]:0:$max}")
    _recs=(${_recs:#})
    if [[ "$emit" == tsv ]]; then
      # epoch first, host dropped: the caller of a remote worker knows which
      # host it dialled, and a machine there cannot know what alias it answers to.
      for _r in "${_recs[@]}"; do
        _e_epoch="${_r%%$'\t'*}"
        _ccfind_parse_row "${_r#*$'\t'}"
        print -r -- "$_e_epoch"$'\t'"$_profile"$'\t'"$_cfgdir"$'\t'"$_id"$'\t'"$_cwd"$'\t'"$_ts"$'\t'"$_snippet"$'\t'"$_path"
      done
      return 0
    fi
    print -r -- '{'
    print -r -- '  "version": 1,'
    print -rn -- '  "query": '; _ccfind_json_str "$query"; print -r -- ','
    # The RESOLVED boolean, not the mode: a consumer wants to know how the hits
    # in front of it were matched, and "smart" would leave it re-deriving that
    # from the query. The mode rides along beside it for the same reason a log
    # line does — to explain where the boolean came from.
    print -r -- "  \"case_sensitive\": $( (( csens )) && print -n true || print -n false ),"
    print -rn -- '  "case_mode": '; _ccfind_json_str "$_case_mode"; print -r -- ','
    print -rn -- '  "scope": ';  _ccfind_json_str "$abs";   print -r -- ','
    print -r -- "  \"scope_exact\": $( (( exact )) && print -n true || print -n false ),"
    print -r -- "  \"total\": ${total:-0},"
    print -r -- "  \"shown\": $(( ${total:-0} < max ? ${total:-0} : max )),"
    print -r -- "  \"truncated\": $( (( ${truncated:-0} )) && print -n true || print -n false ),"
    print -r -- '  "results": ['
    for _r in "${_recs[@]}"; do
      _e_epoch="${_r%%$'\t'*}"
      _ccfind_parse_row "${_r#*$'\t'}"
      (( _first )) || print -r -- ','
      _first=0
      print -rn -- '    {'
      print -rn -- '"epoch": '"$_e_epoch"', "host": ';    _ccfind_json_str "$_host"
      print -rn -- ', "profile": ';                        _ccfind_json_str "$_profile"
      print -rn -- ', "config_dir": ';                     _ccfind_json_str "$_cfgdir"
      print -rn -- ', "id": ';                             _ccfind_json_str "$_id"
      print -rn -- ', "cwd": ';                            _ccfind_json_str "$_cwd"
      print -rn -- ', "mtime": ';                          _ccfind_json_str "$_ts"
      print -rn -- ', "snippet": ';                        _ccfind_json_str "$_snippet"
      print -rn -- ', "path": ';                           _ccfind_json_str "$_path"
      print -rn -- '}'
    done
    (( _first )) || print
    print -r -- '  ]'
    print -r -- '}'
    return 0
  }


  # ---- Local search profiles ----------------------------------------------
  # A machine is multi-profile in one of two ways, and both count:
  #
  #   1. CCFIND_PROFILES — "label:dir …" in the .env or the environment. This
  #      is the explicit answer and wins outright.
  #   2. claude-profile — if it manages the seats on this machine, it already
  #      knows them, and listing them again here is a second copy that drifts.
  #      Asked only when (1) yields nothing, so it costs nothing to anyone who
  #      configured ccfind directly.
  #
  # Either way a profile is only kept if its dir is actually present, so one
  # .env shared across a fleet degrades per host instead of inventing seats.
  # Nothing found → a single nameless profile at ~/.claude, byte-identical to
  # the behaviour before any of this existed.
  local -a prof_labels prof_roots
  local -A prof_cfgdir
  local profiles_on=0 prof_source=""
  local _tok _lbl _dir
  _ccfind_add_profile() {   # <label> <dir>
    _lbl="$1"; _dir="${2/#\~/$HOME}"              # expand a leading ~
    [[ -n "$_lbl" && -n "$_dir" ]] || return 0
    [[ -d "$_dir/projects" ]] || return 0          # not present on this machine
    [[ -n "${prof_cfgdir[$_lbl]+x}" ]] && return 0 # first definition wins
    prof_labels+=("$_lbl"); prof_roots+=("$_dir/projects"); prof_cfgdir[$_lbl]="$_dir"
  }

  if [[ -n "$_cfg_profiles" ]]; then
    for _tok in ${(s: :)${_cfg_profiles//,/ }}; do
      [[ "$_tok" == *:* ]] || continue
      _ccfind_add_profile "${_tok%%:*}" "${_tok#*:}"
    done
    (( ${#prof_labels} > 0 )) && { profiles_on=1; prof_source="CCFIND_PROFILES" }
  fi
  if (( ! profiles_on )); then
    local _cpline
    # .env-configured hint, handed to the helper the way it reads it
    local CCFIND_PROFILE_PATH="$_cfg_profile_path"
    for _cpline in ${(f)"$(_ccfind_claude_profiles)"}; do
      [[ -n "$_cpline" ]] || continue
      _ccfind_add_profile "${_cpline%%$'\t'*}" "${${_cpline#*$'\t'}%%$'\t'*}"
    done
    (( ${#prof_labels} > 0 )) && { profiles_on=1; prof_source="claude-profile" }
  fi
  if (( ! profiles_on )); then
    prof_labels=(local); prof_roots=("${HOME}/.claude/projects"); prof_cfgdir[local]="${HOME}/.claude"
  fi
  (( verbose )) && print -u2 -r -- "${_CCF_DIM}ccfind: profiles: ${prof_source:-none (~/.claude only)}${prof_source:+ → ${(j:, :)prof_labels}}${_CCF_OFF}"

  # ---- Positional profile selector: `ccfind <label> [text...]`. Only fires
  # when profiles are configured AND the first word exactly matches a label
  # (so plain searches are unaffected when multi-profile is off). The explicit
  # -p <label> form is always available and unambiguous.
  local -a _pos=("$@")
  if [[ -z "$prof_filter" ]] && (( profiles_on )) && (( ${#_pos} > 0 )) \
     && [[ -n "${prof_cfgdir[${_pos[1]}]+x}" ]]; then
    prof_filter="${_pos[1]}"; _pos=("${_pos[@]:1}")
  fi
  query="${_pos[*]}"

  # ---- Case, resolved. Now that the query is known, `smart` can collapse into
  # the boolean everything downstream actually uses: grep's -i, the snippet
  # window, the highlighter, the preview, and the flag the remote workers get.
  # Resolving it HERE — once, on the caller — is what keeps a fan-out coherent:
  # every host is told sensitive-or-not rather than re-deciding from a query
  # whose capitals it would read the same way but need not.
  #
  # "Has a capital" is the ASCII test, deliberately: it is the one the fixed
  # A-Z range can answer without a locale, and a query with no ASCII letters at
  # all (a path, an id, a non-Latin script) reads as "no case was expressed",
  # which is exactly when folding is the safe answer.
  local -i csens=0
  case "$_case_mode" in
    sensitive)   csens=1 ;;
    smart)       [[ "$query" == *[A-Z]* ]] && csens=1 ;;
  esac
  # grep's case flag as an array, so "no flag" is genuinely no argument rather
  # than an empty string grep would take for the pattern.
  local -a _gcase=(-i)
  (( csens )) && _gcase=()
  if (( verbose )) && [[ -n "$query" ]]; then
    print -u2 -r -- "${_CCF_DIM}ccfind: case: $( (( csens )) && print -n sensitive || print -n insensitive ) (mode: $_case_mode)${_CCF_OFF}"
  fi

  # A profile filter (from -p or the positional) narrows the local set to one.
  if [[ -n "$prof_filter" ]]; then
    if [[ -z "${prof_cfgdir[$prof_filter]+x}" ]]; then
      print -u2 -r -- "${_CCF_ERR}ccfind: unknown profile '$prof_filter'${_CCF_OFF} (configured: ${prof_labels[*]})"
      return 2
    fi
    prof_labels=("$prof_filter"); prof_roots=("${prof_cfgdir[$prof_filter]}/projects")
  fi

  # ---- Remote hosts — opt-in per call: -H names an explicit list; -r pulls in
  # the configured CCFIND_HOSTS; neither → local only. -l trumps both.
  local hosts_raw="" tabs_cfg="$_cfg_tabs"
  if (( ! local_only )); then
    if [[ -n "$hosts_override" ]]; then
      hosts_raw="$hosts_override"
    elif (( remote )); then
      hosts_raw="$_cfg_hosts"
      [[ -z "$hosts_raw" ]] && print -u2 -r -- "${_CCF_WARN}ccfind: -r given but no CCFIND_HOSTS configured${_CCF_OFF} (env or the .env beside ccfind.zsh) — searching locally"
    fi
  fi
  local -a remote_hosts
  remote_hosts=(${(s: :)${hosts_raw//,/ }})

  local _any_local=0 _r0
  for _r0 in "${prof_roots[@]}"; do [[ -d "$_r0" ]] && { _any_local=1; break; }; done
  if (( ! _any_local && ${#remote_hosts} == 0 )); then
    print -u2 -r -- "${_CCF_ERR}❌ No Claude sessions directory found${_CCF_OFF} (looked in: ${prof_roots[*]})"
    [[ -n "$emit" ]] && _ccfind_emit      # a document, then the failure status
    return 1
  fi

  # Directory-scope encoding, shared by local and remote: Claude encodes a
  # session's cwd as the dir name with every character outside [a-zA-Z0-9]
  # turned into "-", so /home/user/code → -home-user-code. It is NOT just "/"
  # — a dot or an underscore is flattened the same way, which is why
  # ~/.zsh/ccfind lands in -Users-me--zsh-ccfind (two dashes: one for the "/",
  # one for the "."). Encoding only the slash silently matched nothing for
  # every dotted or underscored path, `-d .` in a dotfile repo included.
  #
  # Scope then matches that encoded name exactly (-x) or as a parent as well
  # (encoded + "-", the default subtree behaviour). Note the abs path is
  # resolved *locally* — with remote hosts, pass the path as it exists there.
  #
  # -x with no -d means "here": the flag's whole point is the current dir, and
  # requiring `-x -d .` would just be ceremony.
  (( exact )) && [[ -z "$scope" ]] && scope=.
  if [[ -n "$scope" ]]; then
    abs="${scope:A}"                     # resolve . / symlinks / relative
    enc="${abs//[^a-zA-Z0-9]/-}"
  fi

  # Kick off the remote fan-out first so it overlaps with the local grep.
  # The worker script goes over stdin (`sh -s`) — nothing is installed on the
  # hosts, and only per-hit TSV metadata comes back, never transcript bodies.
  local rtmpdir=""
  if (( ${#remote_hosts} > 0 )) || [[ "$tabs_cfg" == "1" ]]; then
    rtmpdir="$(mktemp -d "${TMPDIR:-/tmp}/ccfind.XXXXXX")" || return 1
    trap '[[ -n "$rtmpdir" ]] && rm -rf -- "$rtmpdir"' EXIT
  fi
  if (( ${#remote_hosts} > 0 )); then
    local _rscript
    _rscript="$(cat <<'RSEOF'
# ccfind remote worker — runs on each CCFIND_HOSTS host via `ssh <host> sh -s`.
# args: $1=query (may be empty)  $2=max  $3=encoded cwd-scope prefix (may be
#       empty)  $4=the -d path as typed (may be empty)  $5=1 for -x
#       $6=1 for a case-sensitive match, 0 to fold (already resolved by the
#       caller, so `smart` is decided once for the whole fan-out)
#
# Emits one header line, then records:
#   #ccfind mode=<remote|fallback> [reason=<why>]
#   epoch<TAB>profile<TAB>cfgdir<TAB>id<TAB>cwd<TAB>mtime<TAB>snippet<TAB>path
# newest first. The caller prefixes the host it dialled; it never appears here.
#
# Two ways to produce those records, tried in that order, in ONE connection —
# a separate capability probe would double the ssh cost of every host in a
# fan-out already bounded by a connect timeout:
#
#   remote   — the host has its own ccfind, so ask it: `ccfind --tsv -l` reads
#              that machine's OWN config, which is the only thing that knows
#              what profiles live there. This is what makes multi-profile work
#              across the fleet.
#   fallback — walk ~/.claude/projects the way this worker always has. One
#              nameless profile, because without ccfind there is nothing to
#              enumerate the others.
#
# `command -v ccfind` is useless here: ccfind is a zsh *function* sourced from
# an interactive rc, invisible to this shell. So look for the file, at the
# conventional locations and at $CCFIND_REMOTE_PATH if the caller set one.
# `zsh -f` skips the rc entirely (fast, and no surprises from someone's
# prompt), and sourcing the file still auto-loads the .env beside it — which
# is where that host's CCFIND_PROFILES lives.
q="$1"; max="${2:-10}"; enc="$3"; dpath="$4"; exact="$5"; csens="$6"
root="$HOME/.claude/projects"
# grep's fold flag, as a word that is empty when unwanted — this is POSIX sh,
# so there are no arrays; the unquoted expansions below are deliberate.
if [ "$csens" = 1 ]; then gi=""; cmode=sensitive; else gi="-i"; cmode=insensitive; fi

# The host's own config is the whole point of asking it, so make sure it is the
# ONLY config in play: drop any CCFIND_* the caller's environment managed to
# leak across. A real ssh forwards nothing by default, but a transport that does
# (SendEnv, or a stand-in during testing) would otherwise have this host
# searching the CALLER's profile directories under its own name.
unset CCFIND_PROFILES CCFIND_HOSTS CCFIND_TABS CCFIND_MAX CCFIND_INTERACTIVE \
      CCFIND_COLOR CCFIND_REMOTE_RESUME CCFIND_PROFILE_PATH CCFIND_PROFILE_CMD \
      CCFIND_CASE

# Try EVERY candidate, not just the first one that exists. A host can easily
# carry more than one clone — one left where the tool used to live, one where it
# lives now — and stopping at the first lets a stale copy that cannot answer
# shadow a current one at the very next path, taking the whole host down to the
# filesystem walk. (Seen in the field: a pre-split ~/ccfind shadowing
# ~/.zsh/ccfind, the host reporting itself incompatible while a perfectly good
# ccfind sat one line further down this list.) So "incompatible" means every
# candidate was tried and none of them answered.
cc_found=0
if command -v zsh >/dev/null 2>&1; then
  for c in $CCFIND_REMOTE_PATH "$HOME/ccfind/ccfind.zsh" "$HOME/.zsh/ccfind/ccfind.zsh" \
           "$HOME/.config/ccfind/ccfind.zsh"; do
    [ -n "$c" ] && [ -r "$c" ] || continue
    cc_found=1
    # -l pins it local: this host must not fan out to hosts of its own, whatever
    # its .env says. An older ccfind rejects --tsv and exits non-zero, which is
    # what moves us on to the next candidate — and, with none left, into the
    # fallback, so a fleet mid-upgrade degrades instead of erroring.
    # Rebuilding the arg list is safe here: every positional this worker was
    # given is already saved in a named variable above.
    set -- --tsv -l -n "$max"
    [ -n "$dpath" ] && set -- "$@" -d "$dpath"
    # A ccfind predating -x rejects it and exits 2 — which is exactly the
    # "try the next candidate, else fall back" path below, and the fallback
    # honours exact itself. So an old host narrows correctly instead of
    # quietly widening to the whole subtree.
    [ "$exact" = 1 ] && set -- "$@" -x
    # Case travels two ways on purpose. CCFIND_CASE in the environment beats the
    # host's own .env, so a host that has set a default cannot quietly answer a
    # different question than the one asked — and a ccfind too old to know the
    # variable simply ignores it, which is already the insensitive default.
    # The -s flag is what makes a SENSITIVE search safe on such a host: it is
    # rejected, the candidate exits non-zero, and we drop to the filesystem walk
    # below — which honours $csens itself. Without it an old host would silently
    # return insensitive hits under a sensitive search, which is the one failure
    # mode worth a fallback.
    [ "$csens" = 1 ] && set -- "$@" -s
    out=$(CCFIND_CASE="$cmode" zsh -fc 'source "$1"; shift; ccfind "$@"' _ "$c" "$@" -- "$q" 2>/dev/null)
    # Exit status alone decides, NOT whether anything came back: a search that
    # legitimately matched nothing is a successful remote search, and testing
    # for output would demote it to a fallback — a pointless second walk of the
    # disk, reported as a capability the host actually has.
    if [ $? -eq 0 ]; then
      echo "#ccfind mode=remote"
      [ -n "$out" ] && printf '%s\n' "$out"
      exit 0
    fi
  done
  if [ "$cc_found" = 1 ]; then
    echo "#ccfind mode=fallback reason=incompatible"
  else
    echo "#ccfind mode=fallback reason=not-installed"
  fi
else
  echo "#ccfind mode=fallback reason=no-zsh"
fi

[ -d "$root" ] || exit 0
if stat -c %Y "$root" >/dev/null 2>&1; then
  ep() { stat -c %Y "$1"; }                                    # GNU
  mt() { stat -c %y "$1" | cut -d. -f1; }
else
  ep() { stat -f %m "$1"; }                                    # BSD
  mt() { stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$1"; }
fi
if [ -n "$enc" ] && [ "$exact" = 1 ]; then
  files=$(find "$root/$enc" -maxdepth 1 -name '*.jsonl' -type f 2>/dev/null)
elif [ -n "$enc" ]; then
  files=$(find "$root/$enc" "$root/$enc"-* -maxdepth 1 -name '*.jsonl' -type f 2>/dev/null)
else
  files=$(find "$root" -mindepth 2 -maxdepth 2 -name '*.jsonl' -type f 2>/dev/null)
fi
[ -n "$files" ] || exit 0
if [ -n "$q" ]; then
  files=$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 grep -lF $gi -- "$q" 2>/dev/null)
  [ -n "$files" ] || exit 0
fi
tab=$(printf '\t')
printf '%s\n' "$files" | while IFS= read -r f; do
  [ -f "$f" ] && printf '%s\t%s\n' "$(ep "$f")" "$f"
done | sort -t "$tab" -k1,1rn | head -n "$max" | while IFS="$tab" read -r e f; do
  id=$(basename "$f" .jsonl)
  cwd=$(grep -m1 -o '"cwd":"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/.*"cwd":"//;s/"$//')
  [ -n "$cwd" ] || cwd="?"
  snippet=""
  if [ -n "$q" ]; then
    if [ "$csens" = 1 ]; then lq="$q"; else
      lq=$(printf '%s' "$q" | tr '[:upper:]' '[:lower:]'); fi
    snippet=$(grep $gi -m1 -F -- "$q" "$f" 2>/dev/null | tr -d '\000-\037' \
      | awk -v q="$lq" -v cs="$csens" '{l=(cs=="1"?$0:tolower($0)); p=index(l,q); if(p>0){s=p-45; if(s<1)s=1; print substr($0,s,120)}}')
  fi
  # profile and cfgdir: nameless, and the one dir this path knows about.
  printf '%s\t\t%s\t%s\t%s\t%s\t%s\t%s\n' "$e" "$HOME/.claude" "$id" "$cwd" "$(mt "$f")" "$snippet" "$f"
done
exit 0
RSEOF
)"
    # Each worker runs in a wrapper subshell that records ssh's exit code in a
    # per-host .rc file — zsh's `wait <pid>` returns 127 for already-reaped
    # children, so the status can't be collected from wait itself.
    local h
    for h in "${remote_hosts[@]}"; do
      (
        command ssh -o BatchMode=yes -o ConnectTimeout=6 -- "$h" \
          "CCFIND_REMOTE_PATH=${(q)_cfg_remote_path} sh -s -- ${(q)query} ${(q)max} ${(q)enc} ${(q)abs} ${(q)exact} ${(q)csens}" \
          <<<"$_rscript" >"$rtmpdir/${h//\//_}.tsv" 2>/dev/null
        echo $? >"$rtmpdir/${h//\//_}.rc"
      ) &
    done
  fi

  # mtime printers, portable across GNU (Linux) and BSD/macOS stat
  local _statfn _epochfn
  if stat -c %y "$HOME" >/dev/null 2>&1; then
    _statfn() { stat -c '%y' "$1" | cut -d. -f1; }                       # GNU
    _epochfn() { stat -c '%Y' "$1"; }
  else
    _statfn() { stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$1"; }             # BSD
    _epochfn() { stat -f '%m' "$1"; }
  fi

  # Per-hit field extractor (id, cwd, ts, snippet) — shared by both code
  # paths so the picker and the flat list see identical data.
  _ccfind_extract() {
    _f="$1"
    _id="${_f:t:r}"
    _cwd="$(grep -m1 -o '"cwd":"[^"]*"' "$_f" 2>/dev/null | head -1 | sed 's/.*"cwd":"//;s/"$//')"
    _ts="$(_statfn "$_f")"
    if [[ -n "$query" ]]; then
      # The awk pass pulls the 120-char window to the match instead of taking
      # the head of the line, so it has to locate the match the same way grep
      # just did — folding both sides, or neither.
      _snippet="$(grep $_gcase -m1 -F -- "$query" "$_f" 2>/dev/null | tr -d '\000-\037' \
        | awk -v q="$( (( csens )) && print -rn -- "$query" || print -rn -- "${(L)query}" )" -v cs="$csens" \
              '{l=(cs?$0:tolower($0)); p=index(l,q); if(p>0){s=p-45; if(s<1)s=1; print substr($0,s,120)}}')"
    else
      _snippet=""
    fi
  }

  # ---- the record schema ---------------------------------------------------
  #   epoch \t host \t profile \t cfgdir \t id \t cwd \t ts \t snippet \t path
  #
  # host is "local" or the ssh alias; profile is the label the session's config
  # dir goes by ("" when the machine it came from has no profiles configured);
  # cfgdir is that dir, on whichever machine `host` names. Carrying the dir on
  # the record is what lets a hit be resumed into its own seat without the
  # caller having to look the label up — which matters once labels can come
  # from a *remote* host's config, where the caller has no table to look in.
  #
  # Each profile is searched and capped at max independently; remote hosts cap
  # at max per host; the merge re-caps.
  local -a records
  local local_count=0 _projdir_total=0
  local _pi _plabel _proot _pfxlabel
  for (( _pi = 1; _pi <= ${#prof_labels}; _pi++ )); do
    _plabel="${prof_labels[$_pi]}"
    _proot="${prof_roots[$_pi]}"
    # An unconfigured machine has one nameless profile: the label stays empty so
    # nothing downstream prints a "local:" nobody asked for.
    (( profiles_on )) && _pfxlabel="$_plabel" || _pfxlabel=""
    [[ -d "$_proot" ]] || continue
    local -a projdirs
    if [[ -n "$enc" ]] && (( exact )); then
      # Just the one project dir. This is also the only scope mode that cannot
      # over-match: `-d ~/code` picks up ~/code-scratch too (both encode to
      # -Users-me-code-…, and the encoding cannot say which dash was a "/"),
      # whereas an exact name is unambiguous.
      projdirs=("$_proot/$enc"(N/))
    elif [[ -n "$enc" ]]; then
      projdirs=("$_proot/$enc"(N/) "$_proot/$enc"-*(N/))
    else
      projdirs=("$_proot"/*(N/))
    fi
    (( _projdir_total += ${#projdirs} ))
    local -a pjsonls phits pfiles
    # (N) so empty projdirs don't trip NOMATCH and grep is never handed 0 files.
    pjsonls=($^projdirs/*.jsonl(N))
    (( ${#pjsonls} == 0 )) && continue
    if [[ -n "$query" ]]; then
      phits=("${(@f)$(grep -lF $_gcase -- "$query" "${pjsonls[@]}" 2>/dev/null)}")
    else
      phits=("${pjsonls[@]}")
    fi
    phits=(${phits:#})
    (( ${#phits} == 0 )) && continue
    # newest first; ls -t with an explicit list works on GNU and BSD alike
    pfiles=("${(@f)$(ls -t -- $phits 2>/dev/null)}")
    pfiles=(${pfiles:#})
    (( local_count += ${#pfiles} ))
    for _f in "${pfiles[@]:0:$max}"; do
      _ccfind_extract "$_f"
      records+=("$(_epochfn "$_f")"$'\t'local$'\t'"$_pfxlabel"$'\t'"${prof_cfgdir[$_plabel]}"$'\t'"$_id"$'\t'"${_cwd:-?}"$'\t'"$_ts"$'\t'"${_snippet//$'\t'/ }"$'\t'"$_f")
    done
  done

  # A -d scope that matched no project dir in any profile (and no remote host).
  if [[ -n "$enc" ]] && (( _projdir_total == 0 && ${#remote_hosts} == 0 )); then
    [[ -n "$emit" ]] && { _ccfind_emit; return 0 }
    if (( exact )); then
      echo "No sessions recorded in $abs itself (-x excludes subdirectories)"
    else
      echo "No sessions recorded under $abs"
    fi
    return 0
  fi

  local remote_count=0
  if (( ${#remote_hosts} > 0 )); then
    # The ssh fan-out is the one step that can visibly stall (up to the 6 s
    # connect timeout per host), and until now it stalled silently. Say what is
    # being waited on, then erase the line — status, not output, so it goes to
    # stderr and only when there is a terminal there to redraw.
    local _busy=0
    if [[ -t 2 ]]; then
      _busy=1
      printf '%s⟳ searching %d host(s): %s…%s\r' \
        "$_CCF_DIM" ${#remote_hosts} "${(j:, :)remote_hosts}" "$_CCF_OFF" >&2
    fi
    wait   # all fan-out subshells; per-host status is in the .rc files
    (( _busy )) && printf '\033[2K\r' >&2
    local -a _rfailed
    local -A _rmode _rreason
    local line _hrc
    for h in "${remote_hosts[@]}"; do
      _hrc="$(cat -- "$rtmpdir/${h//\//_}.rc" 2>/dev/null)"
      if [[ "$_hrc" != "0" ]]; then
        _rfailed+=("$h")
        continue
      fi
      # First line is the worker's header: which of its two paths ran, and why.
      # Everything after it is records, which only need the host slotted in.
      while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        if [[ "$line" == '#ccfind '* ]]; then
          _rmode[$h]="${${line#*mode=}%% *}"
          [[ "$line" == *reason=* ]] && _rreason[$h]="${line#*reason=}"
          continue
        fi
        records+=("${line%%$'\t'*}"$'\t'"$h"$'\t'"${line#*$'\t'}")
        (( remote_count++ ))
      done <"$rtmpdir/${h//\//_}.tsv"
    done
    (( ${#_rfailed} > 0 )) && print -u2 -r -- "${_CCF_WARN}ccfind: remote search failed on:${_CCF_OFF} ${_rfailed[*]}"
    # A host without ccfind is searched anyway, just under its default profile
    # only — which is a quiet half-answer, not an error, so it is reported at
    # -v rather than in your face on every search.
    if (( verbose )); then
      for h in "${remote_hosts[@]}"; do
        case "${_rmode[$h]-}" in
          remote)   print -u2 -r -- "${_CCF_DIM}ccfind: $h — searched with its own ccfind (its profiles apply)${_CCF_OFF}" ;;
          fallback) print -u2 -r -- "${_CCF_DIM}ccfind: $h — no usable ccfind (${_rreason[$h]-unknown}); searched ~/.claude only, so any other profile on that host is invisible${_CCF_OFF}" ;;
        esac
      done
    fi
  fi

  if (( ${#records} == 0 )); then
    [[ -n "$emit" ]] && { _ccfind_emit; return 0 }
    echo "No matching sessions."
    # An empty result is ambiguous on its own — a typo'd query and a scope that
    # excluded everything look identical. Spell out what the search actually
    # covered so the next attempt is an informed one.
    local -a _what
    [[ -n "$query" ]] && _what+=("query \"$query\"")
    # Only when it is ON: an insensitive search is the default, and naming it
    # here would pad every empty result with a line that rules nothing out.
    (( csens )) && _what+=("case-sensitive")
    (( profiles_on )) && _what+=("profiles: ${(j:, :)prof_labels}")
    (( ${#remote_hosts} > 0 )) && _what+=("hosts: ${(j:, :)remote_hosts}")
    [[ -n "$abs" ]] && { (( exact )) && _what+=("in $abs only") || _what+=("under $abs") }
    (( ${#_what} > 0 )) && print -r -- "${_CCF_DIM}   ${(j: · :)_what}${_CCF_OFF}"
    return 0
  fi

  local -a merged
  merged=("${(@f)$(printf '%s\n' "${records[@]}" | sort -t$'\t' -k1,1rn)}")
  merged=(${merged:#})
  local total=$(( local_count + remote_count ))
  local truncated=0
  (( total > max )) && truncated=1
  # Rows for display/selection — the sortable record with its leading epoch
  # moved to the back, where it cannot shift the field numbers the fzf bindings
  # and the tab-view patterns are written against:
  # host \t profile \t cfgdir \t id \t cwd \t ts \t snippet \t path \t epoch
  # rows_all keeps the full sorted list — it feeds the per-host tab views,
  # where a host shows its own newest hits even when none crack the global
  # top-max. rows is the capped slice everything else displays.
  local -a rows_all rows
  local _r
  for _r in "${merged[@]}"; do
    rows_all+=("${_r#*$'\t'}"$'\t'"${_r%%$'\t'*}")
  done
  rows=("${rows_all[@]:0:$max}")

  [[ -n "$emit" ]] && { _ccfind_emit; return 0 }

  # Remote resume command: cd on the host, then exec an interactive shell for
  # the claude invocation — non-interactive ssh PATH usually lacks claude, and
  # the interactive rc also loads any `claude` wrapper where present.
  local _rcmd
  _ccfind_remote_cmd() {  # args: cwd id [profile] [cfgdir]
    # A profile means the hit came from a host that runs ccfind and told us
    # which of its seats this session lives in — so pin it, exactly as the
    # local path does. No profile means the default seat: set nothing.
    #
    # $4 is the *host's* config dir, so whether it names that host's default
    # seat is a question only that host can answer — hence the test travels
    # with the command and resolves against the remote $HOME. Same reason as
    # _ccfind_pin_cfgdir locally: naming the default dir would send claude to a
    # .claude.json that has never been onboarded.
    local _inner="claude --resume $2"
    [[ -n "${3:-}" && -n "${4:-}" ]] && \
      _inner="[ ${(q)4} = \"\$HOME/.claude\" ] || export CLAUDE_CONFIG_DIR=${(q)4}; $_inner"
    if [[ -n "$1" && "$1" != "?" ]]; then
      _rcmd="cd ${(q)1} && exec \"\$SHELL\" -ic ${(q)_inner}"
    else
      _rcmd="exec \"\$SHELL\" -ic ${(q)_inner}"
    fi
  }

  # Picker path: interactive requested AND fzf installed AND on a TTY — unless
  # -i was passed, which is the explicit "give me the picker" and so overrides
  # the TTY sniff as well as CCFIND_INTERACTIVE=0. (The default, TTY-sniffing
  # path is what makes `ccfind foo | less` fall back on its own; -i is for the
  # caller who knows better — a wrapper, or the README-SVG generator, which
  # drives the picker through a stub fzf with no terminal anywhere in sight.)
  if (( interactive )) && command -v fzf >/dev/null 2>&1 \
     && { (( interactive_forced )) || [[ -t 0 && -t 1 ]] }; then
    local _k="$_CCF_KEY" _o="$_CCF_OFF"
    local header="${_k}↑/↓${_o} navigate · ${_k}Enter${_o} resume · ${_k}→${_o} preview · ${_k}←${_o} hide · ${_k}Esc${_o} cancel"
    if (( truncated )); then
      header="$header   ${_CCF_DIM}(showing $max of $total; raise with -n <max> or \$CCFIND_MAX)${_o}"
    fi

    # ---- the display column --------------------------------------------
    # fzf has no column model: with --with-nth it concatenates the chosen
    # fields and leaves them on the terminal's 8-column tab stops, so the cwd
    # and the snippet start somewhere different on every row. So compose ONE
    # pre-padded, pre-coloured field and show only that (--with-nth).
    # Alignment we control; the data fields stay plain behind it, which is
    # what lets the tab views filter on a bare "<label>\t" prefix and the
    # resume path parse fields it can trust. fzf strips the colour back off
    # whatever it hands us on the way out.
    integer w_host=0 w_cwd=0
    _ccfind_rel_width "${rows[@]}"
    local _dcwd _dlabel
    local _showhost=0
    (( ${#remote_hosts} > 0 || ${#prof_labels} > 1 )) && _showhost=1
    # host:profile once both axes are in play — a session on another machine's
    # personal seat is a different thing from one on its default seat.
    _ccfind_row_label() {
      if _ccfind_is_local "$_host"; then _dlabel="${_profile:-local}"
      elif [[ -n "$_profile" ]];   then _dlabel="${_host}:${_profile}"
      else                              _dlabel="$_host"; fi
    }
    for _r in "${rows[@]}"; do            # first pass: natural column widths
      _ccfind_parse_row "$_r"; _ccfind_row_label
      (( ${#_dlabel} > w_host )) && w_host=${#_dlabel}
      _dcwd="${_cwd/#$HOME/~}"
      (( ${#_dcwd} > w_cwd )) && w_cwd=${#_dcwd}
    done
    (( w_cwd > 44 )) && w_cwd=44          # a deep path must not push the snippet off-screen

    local _crow _dhost
    _ccfind_disp_row() {   # <raw row> → the row plus a last field, its rendered line
      _ccfind_parse_row "$1"; _ccfind_row_label
      if _ccfind_is_local "$_host"; then _crow="$_CCF_PROF"; else _crow="$_CCF_HOST"; fi
      # $HOME is contracted for display only — the cd still uses field 3 — and a
      # path too long for the column keeps its tail, which is its telling half.
      _dcwd="${_cwd/#$HOME/~}"
      (( ${#_dcwd} > w_cwd )) && _dcwd="…${_dcwd[-(w_cwd-1),-1]}"
      # The snippet arrives with ~45 characters of lead-in before the match —
      # fine in the full-width flat list, but in the picker's last column that
      # lead is usually all you get, with the match itself off the right edge.
      # Pull the window forward so the reason the row matched leads the column.
      local _sn="$_snippet" _lsn _pre
      if [[ -n "$query" && -n "$_sn" ]]; then
        _lsn="${(L)_sn}"; _pre="${_lsn%%${(L)query}*}"
        (( ${#_pre} != ${#_lsn} && ${#_pre} > 14 )) && _sn="…${_sn[${#_pre}-11,-1]}"
      fi
      _ccfind_time_cell $w_rel "$_CCF_DIM"
      _dhost=""
      (( _showhost )) && _dhost="${_crow}${(r:$w_host:)_dlabel}${_CCF_OFF}  "
      # Pad on the plain text, colour after: an SGR run counts toward a string's
      # length but draws nothing, so padding a coloured field skews the column.
      print -rn -- "$1"$'\t'"${_tcell}  ${_dhost}${(r:$w_cwd:)_dcwd}  ${_CCF_SNIP}$(_ccfind_hl "$_sn" "$query" "$_CCF_SNIP" "$csens")${_CCF_OFF}"
    }

    # Field 10 is the composed display line (built below); 1-9 are the data
    # fields, hidden — 1 (host) and 8 (path) feed the preview command, 3/4/5 the
    # resume, 9 the epoch behind the age. Matching therefore runs over exactly
    # what you can see.
    local withnth='10' pvcache=''
    if (( ${#remote_hosts} > 0 )); then
      pvcache="$rtmpdir/pv"
      mkdir -p -- "$pvcache"
    fi

    # Optional tab views (CCFIND_TABS=1): Tab/Shift-Tab cycle
    # All → <each profile> → <each host with hits>, rendered as a header bar.
    # Enabled when there's more than one view to show (multiple local profiles
    # and/or remote hosts). Needs fzf ≥ 0.45 for the transform action.
    local -a fzf_extra
    if [[ "$tabs_cfg" == "1" && -n "$rtmpdir" ]] && (( ${#remote_hosts} > 0 || ${#prof_labels} > 1 )); then
      autoload -Uz is-at-least
      local _fzfv="${$(fzf --version 2>/dev/null)%% *}"
      if [[ -n "$_fzfv" ]] && is-at-least 0.45 "$_fzfv"; then
        local tabsdir="$rtmpdir/tabs"
        mkdir -p -- "$tabsdir"
        # Views come from the *pre-cap* rows_all: a tab shows that profile/host's
        # own newest hits (up to max) even when none made the globally-capped All
        # view. Profiles/hosts with zero hits get no tab.
        # NB: the match must land in an array variable first — a ${(M)...}
        # with $'\t' inside (( )) silently mismatches (zsh arith quoting).
        local -a views vrows crows
        views=(All)
        crows=(); for _r in "${rows[@]}"; do crows+=("$(_ccfind_disp_row "$_r")"); done
        printf '%s\n' "${crows[@]}" >"$tabsdir/view-1.rows"
        # One view per local profile, then one per host. The two are matched on
        # different fields — a local profile is (host=local, profile=<label>),
        # a host is field 1 whatever its profiles turn out to be — so a host
        # tab holds every seat on that machine rather than splitting it.
        local _v _pat
        for _v in "${prof_labels[@]}" "${remote_hosts[@]}"; do
          if [[ -n "${prof_cfgdir[$_v]+x}" ]]; then
            (( profiles_on )) || continue          # one nameless profile: no tab
            _pat="local"$'\t'"${_v}"$'\t'"*"
          else
            _pat="${_v}"$'\t'"*"
          fi
          vrows=(${(M)rows_all:#$~_pat})
          (( ${#vrows} > 0 )) || continue
          views+=("$_v")
          crows=(); for _r in "${vrows[@]:0:$max}"; do crows+=("$(_ccfind_disp_row "$_r")"); done
          printf '%s\n' "${crows[@]}" >"$tabsdir/view-${#views}.rows"
        done
        printf '%s\n' "${views[@]}" >"$tabsdir/views"
        print -r -- 1 >"$tabsdir/cur"
        local tabhelp="${_k}Tab/⇧Tab${_o} views · ${_k}Enter${_o} resume · ${_k}→${_o} preview · ${_k}Esc${_o}"
        (( truncated )) && tabhelp="$tabhelp  ${_CCF_DIM}(showing $max of $total)${_o}"
        print -r -- "$tabhelp" >"$tabsdir/help"
        header="$(_ccfind_tab_header "$tabsdir")"
        fzf_extra=(
          --bind "tab:transform:zsh -c 'source ${(q)_CCFIND_SOURCE}; _ccfind_tab_shift ${(q)tabsdir} 1'"
          --bind "btab:transform:zsh -c 'source ${(q)_CCFIND_SOURCE}; _ccfind_tab_shift ${(q)tabsdir} -1'"
        )
      fi
    fi

    local -a rows_disp
    for _r in "${rows[@]}"; do rows_disp+=("$(_ccfind_disp_row "$_r")"); done

    local selected
    selected="$(
      printf '%s\n' "${rows_disp[@]}" \
        | fzf \
            --delimiter=$'\t' --with-nth=$withnth \
            --no-sort --ansi --reverse --height=80% \
            --header="$header" \
            --preview "zsh -c 'export CCFIND_PV_CACHE=${(q)pvcache} CCFIND_LOCAL_LABELS=${(q)${(j: :)prof_labels}} CCFIND_PV_QUERY=${(q)query} CCFIND_PV_CASE=${(q)csens}; source ${(q)_CCFIND_SOURCE}; _ccfind_preview {1} {8}'" \
            --preview-window='hidden,right,60%,wrap' \
            --bind 'right:show-preview' \
            --bind 'left:hide-preview' \
            "${fzf_extra[@]}"
    )"
    [[ -z "$selected" ]] && return 0   # Esc / no match

    _ccfind_parse_row "$selected"
    if ! _ccfind_is_local "$_host"; then            # a session on another machine
      if [[ -n "$_cfg_remote_resume" ]]; then       # user override: fn <host> <cwd> <id>
        ${(z)_cfg_remote_resume} "$_host" "$_cwd" "$_id"
      else
        _ccfind_remote_cmd "$_cwd" "$_id" "$_profile" "$_cfgdir"
        ssh -t "$_host" "$_rcmd"
      fi
      return $?
    fi
    if [[ -n "$_cwd" && "$_cwd" != "?" && "$_cwd" != "$PWD" ]]; then
      if [[ ! -d "$_cwd" ]]; then
        echo "ccfind: session cwd no longer exists: $_cwd" >&2
        return 1
      fi
      cd "$_cwd" || { echo "ccfind: cd to $_cwd failed" >&2; return 1; }
    fi
    # The row carries its own config dir, so the seat comes off the hit rather
    # than off a lookup — and a hit on the default seat sets nothing, which is
    # what leaves claude-profile free to do its own launch-time routing.
    if _ccfind_pin_cfgdir "$_cfgdir"; then
      CLAUDE_CONFIG_DIR="$_cfgdir" claude --resume "$_id"
    else
      claude --resume "$_id"
    fi
    return $?
  fi

  # Flat-list path: original behaviour, plus a host tag on remote hits. Same
  # three lines per hit as before — timestamp + where, the matching snippet, the
  # resume command — now with the label colour carrying local-vs-remote and the
  # match lit inside the snippet. Every SGR here is empty when colour is off, so
  # a piped run emits exactly the bytes it always did.
  local resume shown=0 _tag
  _ccfind_rel_width "${rows[@]}"
  for _r in "${rows[@]}"; do
    (( shown > 0 )) && printf '%s%s%s\n' "$_CCF_DIM" '──────────────────────────────────────────' "$_CCF_OFF"
    _ccfind_parse_row "$_r"
    if ! _ccfind_is_local "$_host"; then                   # a session on another machine
      _tag="${_CCF_HOST}${_host}${_profile:+:$_profile}${_CCF_OFF}${_CCF_DIM}:${_CCF_OFF}"
      if [[ -n "$_cfg_remote_resume" ]]; then
        resume="$_cfg_remote_resume ${(q)_host} ${(q)_cwd} ${(q)_id}"
      else
        _ccfind_remote_cmd "$_cwd" "$_id" "$_profile" "$_cfgdir"
        resume="ssh -t $_host ${(qq)_rcmd}"
      fi
    else                                                   # local hit
      if [[ -n "$_profile" ]]; then
        _tag="${_CCF_PROF}${_profile}${_CCF_OFF}${_CCF_DIM}:${_CCF_OFF}"
      else
        _tag=""
      fi
      local _pfx=""
      _ccfind_pin_cfgdir "$_cfgdir" && _pfx="CLAUDE_CONFIG_DIR=${(q)_cfgdir} "
      if [[ -n "$_cwd" && "$_cwd" != "?" && "$_cwd" != "$PWD" ]]; then
        resume="cd ${(q)_cwd} && ${_pfx}claude --resume $_id"
      else
        resume="${_pfx}claude --resume $_id"
      fi
    fi
    # Display-only contraction, as in the picker; the resume line printed two
    # lines down still carries the path in full.
    _ccfind_time_cell $w_rel "$_CCF_TS"
    printf '%s  %s%s\n' "$_tcell" "$_tag" "${${_cwd:-?}/#$HOME/~}"
    [[ -n "$_snippet" ]] && \
      printf '   %s…%s…%s\n' "$_CCF_SNIP" "$(_ccfind_hl "$_snippet" "$query" "$_CCF_SNIP" "$csens")" "$_CCF_OFF"
    printf '   %s%s%s\n' "$_CCF_CMD" "$resume" "$_CCF_OFF"
    (( shown++ ))
  done
  (( truncated )) && printf '%s… (%s total; raise with -n <max> or $CCFIND_MAX)%s\n' \
    "$_CCF_DIM" "$total" "$_CCF_OFF"
  return 0
}
