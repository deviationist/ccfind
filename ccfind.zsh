# Absolute path to this file — captured at source time so the fzf preview
# subshell can source us back in to call _ccfind_preview without hardcoding.
typeset -g _CCFIND_SOURCE="${${(%):-%x}:A}"

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
  if [[ -n "$host" && "$host" != "local" ]]; then
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
  printf '\033[1m%s\033[0m\n\n' "$label"
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

BOLD, DIM, RESET = "\033[1m", "\033[2m", "\033[0m"
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

records = records[-MAX_MSGS:]
if not records:
    print(f"{DIM}(no user/assistant messages with text content){RESET}")
    sys.exit(0)

for t, text in records:
    label = "USER" if t == "user" else "ASSISTANT"
    print(f"{BOLD}── {label} ──{RESET}")
    print(text)
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
#   ccfind [-d <dir>]           no query → list the most recent sessions
#   ccfind -N <text...>         force the flat-list output (skip the picker)
#   ccfind -r <text...>         also search the configured remote hosts
#   ccfindr <text...>           alias for `ccfind -r` (defined in ~/.zshrc)
#   ccfind -l <text...>         force local only (trumps -r / -H)
#   ccfind -H "host-a host-b" ... search these ssh hosts (implies remote,
#                               overrides CCFIND_HOSTS)
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
  local root="${HOME}/.claude/projects"
  local max="${CCFIND_MAX:-10}"
  local scope=""
  local interactive="${CCFIND_INTERACTIVE:-1}"
  local hosts_override="" local_only=0 remote=0

  while [[ "$1" == -* ]]; do
    case "$1" in
      -d|--dir) scope="$2"; shift 2 ;;
      -n|--max) max="$2"; shift 2 ;;
      -i|--interactive) interactive=1; shift ;;
      -N|--no-interactive) interactive=0; shift ;;
      -r|--remote) remote=1; shift ;;
      -l|--local) local_only=1; shift ;;
      -H|--hosts) hosts_override="$2"; shift 2 ;;
      -h|--help)
        echo "usage: ccfind [-d <dir>] [-n <max-hits>] [-i|-N] [-r|-l] [-H <hosts>] [search text...]"
        echo "  remote search is opt-in: -r (or the ccfindr alias) uses CCFIND_HOSTS"
        echo "  (env or the .env beside ccfind.zsh); -H <hosts> searches an explicit list; -l forces local"
        return 0 ;;
      --) shift; break ;;
      *) echo "ccfind: unknown option $1" >&2; return 2 ;;
    esac
  done
  local query="$*"

  # Remote hosts — opt-in per call: -H names an explicit list; -r pulls in
  # the configured CCFIND_HOSTS (exported env > the .env beside this file); neither → local
  # only, whatever is configured. -l trumps both. .env is sourced inside this
  # function scope with its keys pre-declared local, so its typeset values stay
  # function-local.
  local hosts_raw="" tabs_cfg="${CCFIND_TABS-}"
  if (( ! local_only )); then
    if [[ -n "$hosts_override" ]]; then
      hosts_raw="$hosts_override"
    elif (( remote )); then
      if [[ -n "${CCFIND_HOSTS-}" ]]; then
        hosts_raw="$CCFIND_HOSTS"
      else
        local _envf="${_CCFIND_SOURCE:h}/.env"
        if [[ -r "$_envf" ]]; then
          typeset CCFIND_HOSTS="" CCFIND_TABS=""
          source "$_envf"
          hosts_raw="$CCFIND_HOSTS"
          [[ -z "$tabs_cfg" ]] && tabs_cfg="$CCFIND_TABS"
        fi
      fi
      [[ -z "$hosts_raw" ]] && echo "ccfind: -r given but no CCFIND_HOSTS configured (env or the .env beside ccfind.zsh) — searching locally" >&2
    fi
  fi
  local -a remote_hosts
  remote_hosts=(${(s: :)${hosts_raw//,/ }})

  if [[ ! -d "$root" && ${#remote_hosts} -eq 0 ]]; then
    echo "❌ No Claude sessions directory at $root" >&2
    return 1
  fi

  # Directory-scope encoding, shared by local and remote: Claude encodes a
  # session's cwd as the dir name with every "/" turned into "-", so
  # /home/user/code → -home-user-code. Scope by matching that encoded prefix
  # exactly or as a parent (encoded + "-"). Note the abs path is resolved
  # *locally* — with remote hosts, pass the path as it exists on them.
  local abs="" enc=""
  if [[ -n "$scope" ]]; then
    abs="${scope:A}"                     # resolve . / symlinks / relative
    enc="${abs//\//-}"
  fi

  # Kick off the remote fan-out first so it overlaps with the local grep.
  # The worker script goes over stdin (`sh -s`) — nothing is installed on the
  # hosts, and only per-hit TSV metadata comes back, never transcript bodies.
  local rtmpdir=""
  if (( ${#remote_hosts} > 0 )); then
    rtmpdir="$(mktemp -d "${TMPDIR:-/tmp}/ccfind.XXXXXX")" || return 1
    trap '[[ -n "$rtmpdir" ]] && rm -rf -- "$rtmpdir"' EXIT
    local _rscript
    _rscript="$(cat <<'RSEOF'
# ccfind remote worker — runs on each CCFIND_HOSTS host via `ssh <host> sh -s`.
# args: $1=query (may be empty)  $2=max  $3=encoded cwd-scope prefix (may be empty)
# stdout: epoch<TAB>id<TAB>cwd<TAB>mtime<TAB>snippet<TAB>path, newest first
q="$1"; max="${2:-10}"; enc="$3"
root="$HOME/.claude/projects"
[ -d "$root" ] || exit 0
if stat -c %Y "$root" >/dev/null 2>&1; then
  ep() { stat -c %Y "$1"; }                                    # GNU
  mt() { stat -c %y "$1" | cut -d. -f1; }
else
  ep() { stat -f %m "$1"; }                                    # BSD
  mt() { stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$1"; }
fi
if [ -n "$enc" ]; then
  files=$(find "$root/$enc" "$root/$enc"-* -maxdepth 1 -name '*.jsonl' -type f 2>/dev/null)
else
  files=$(find "$root" -mindepth 2 -maxdepth 2 -name '*.jsonl' -type f 2>/dev/null)
fi
[ -n "$files" ] || exit 0
if [ -n "$q" ]; then
  files=$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 grep -liF -- "$q" 2>/dev/null)
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
    lq=$(printf '%s' "$q" | tr '[:upper:]' '[:lower:]')
    snippet=$(grep -im1 -F -- "$q" "$f" 2>/dev/null | tr -d '\000-\037' \
      | awk -v q="$lq" '{l=tolower($0); p=index(l,q); if(p>0){s=p-45; if(s<1)s=1; print substr($0,s,120)}}')
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$e" "$id" "$cwd" "$(mt "$f")" "$snippet" "$f"
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
          "sh -s -- ${(q)query} ${(q)max} ${(q)enc}" \
          <<<"$_rscript" >"$rtmpdir/${h//\//_}.tsv" 2>/dev/null
        echo $? >"$rtmpdir/${h//\//_}.rc"
      ) &
    done
  fi

  # Which local project dirs to look in.
  local -a projdirs
  if [[ -n "$enc" ]]; then
    projdirs=("$root/$enc"(N/) "$root/$enc"-*(N/))
    if (( ${#projdirs} == 0 && ${#remote_hosts} == 0 )); then
      echo "No sessions recorded under $abs"
      return 0
    fi
  else
    projdirs=("$root"/*(N/))
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

  local -a hits all_jsonls
  # Expand once with (N) so empty projdirs don't trip NOMATCH, and so we can
  # guard the grep call: passing zero files makes grep read stdin and hang.
  all_jsonls=($^projdirs/*.jsonl(N))
  if [[ -n "$query" ]]; then
    # -F: literal string, not a regex.  -l: filenames only.
    if (( ${#all_jsonls} > 0 )); then
      hits=("${(@f)$(grep -liF -- "$query" "${all_jsonls[@]}" 2>/dev/null)}")
    fi
  else
    hits=("${all_jsonls[@]}")
  fi
  hits=(${hits:#})   # drop empty elements

  # newest first; ls -t with an explicit list works on GNU and BSD alike
  local -a files
  if (( ${#hits} > 0 )); then
    files=("${(@f)$(ls -t -- $hits 2>/dev/null)}")
    files=(${files:#})
  fi

  # Per-hit field extractor (id, cwd, ts, snippet) — shared by both code
  # paths so the picker and the flat list see identical data.
  local _f _id _cwd _ts _snippet
  _ccfind_extract() {
    _f="$1"
    _id="${_f:t:r}"
    _cwd="$(grep -m1 -o '"cwd":"[^"]*"' "$_f" 2>/dev/null | head -1 | sed 's/.*"cwd":"//;s/"$//')"
    _ts="$(_statfn "$_f")"
    if [[ -n "$query" ]]; then
      _snippet="$(grep -im1 -F -- "$query" "$_f" 2>/dev/null | tr -d '\000-\037' \
        | awk -v q="${(L)query}" '{l=tolower($0); p=index(l,q); if(p>0){s=p-45; if(s<1)s=1; print substr($0,s,120)}}')"
    else
      _snippet=""
    fi
  }

  # Build merged records: epoch \t host \t id \t cwd \t ts \t snippet \t path.
  # Local extraction is capped at max up front (same bound the display uses),
  # remote workers cap at max per host — the merge re-sorts and caps again.
  local -a records
  local -a lcapped
  lcapped=("${files[@]:0:$max}")
  for _f in "${lcapped[@]}"; do
    _ccfind_extract "$_f"
    records+=("$(_epochfn "$_f")"$'\t'"local"$'\t'"$_id"$'\t'"${_cwd:-?}"$'\t'"$_ts"$'\t'"${_snippet//$'\t'/ }"$'\t'"$_f")
  done

  local remote_count=0
  if (( ${#remote_hosts} > 0 )); then
    wait   # all fan-out subshells; per-host status is in the .rc files
    local -a _rfailed
    local line _hrc
    for h in "${remote_hosts[@]}"; do
      _hrc="$(cat -- "$rtmpdir/${h//\//_}.rc" 2>/dev/null)"
      if [[ "$_hrc" != "0" ]]; then
        _rfailed+=("$h")
        continue
      fi
      while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        records+=("${line%%$'\t'*}"$'\t'"$h"$'\t'"${line#*$'\t'}")
        (( remote_count++ ))
      done <"$rtmpdir/${h//\//_}.tsv"
    done
    (( ${#_rfailed} > 0 )) && echo "ccfind: remote search failed on: ${_rfailed[*]}" >&2
  fi

  if (( ${#records} == 0 )); then
    echo "No matching sessions."
    return 0
  fi

  local -a merged
  merged=("${(@f)$(printf '%s\n' "${records[@]}" | sort -t$'\t' -k1,1rn)}")
  merged=(${merged:#})
  local total=$(( ${#files} + remote_count ))
  local truncated=0
  (( ${#merged} > max )) && truncated=1
  # Rows for display/selection, epoch stripped:
  # host \t id \t cwd \t ts \t snippet \t path
  # rows_all keeps the full sorted list — it feeds the per-host tab views,
  # where a host shows its own newest hits even when none crack the global
  # top-max. rows is the capped slice everything else displays.
  local -a rows_all rows
  local _r
  for _r in "${merged[@]}"; do
    rows_all+=("${_r#*$'\t'}")
  done
  rows=("${rows_all[@]:0:$max}")

  # Sequential TSV field parser for a selected/iterated row.
  local _host _path _rest
  _ccfind_parse_row() {
    _rest="$1"
    _host="${_rest%%$'\t'*}"; _rest="${_rest#*$'\t'}"
    _id="${_rest%%$'\t'*}";   _rest="${_rest#*$'\t'}"
    _cwd="${_rest%%$'\t'*}";  _rest="${_rest#*$'\t'}"
    _ts="${_rest%%$'\t'*}";   _rest="${_rest#*$'\t'}"
    _snippet="${_rest%%$'\t'*}"
    _path="${_rest#*$'\t'}"
  }

  # Remote resume command: cd on the host, then exec an interactive shell for
  # the claude invocation — non-interactive ssh PATH usually lacks claude, and
  # the interactive rc also loads any `claude` wrapper where present.
  local _rcmd
  _ccfind_remote_cmd() {  # args: cwd id
    if [[ -n "$1" && "$1" != "?" ]]; then
      _rcmd="cd ${(q)1} && exec \"\$SHELL\" -ic ${(q):-claude --resume $2}"
    else
      _rcmd="exec \"\$SHELL\" -ic ${(q):-claude --resume $2}"
    fi
  }

  # Picker path: interactive requested AND fzf installed AND on a TTY.
  if (( interactive )) && command -v fzf >/dev/null 2>&1 && [[ -t 0 && -t 1 ]]; then
    local header='↑/↓ navigate · Enter resume · → preview · ← hide · Esc cancel'
    if (( truncated )); then
      header="$header   (showing $max of $total; raise with -n <max> or \$CCFIND_MAX)"
    fi

    # Column 4 = mtime, 1 = host (only shown in multi-host mode), 3 = cwd,
    # 5 = snippet; columns 2 (id) and 6 (filepath) stay hidden — 6 feeds the
    # preview command together with 1.
    local withnth='4,3,5' pvcache=''
    if (( ${#remote_hosts} > 0 )); then
      withnth='4,1,3,5'
      pvcache="$rtmpdir/pv"
      mkdir -p -- "$pvcache"
    fi

    # Optional per-host tab views (CCFIND_TABS=1): Tab/Shift-Tab cycle
    # All → local → <each host with hits>, rendered as a bar in the header.
    # Needs fzf ≥ 0.45 for the transform action; silently off below that.
    local -a fzf_extra
    if [[ "$tabs_cfg" == "1" ]] && (( ${#remote_hosts} > 0 )); then
      autoload -Uz is-at-least
      local _fzfv="${$(fzf --version 2>/dev/null)%% *}"
      if [[ -n "$_fzfv" ]] && is-at-least 0.45 "$_fzfv"; then
        local tabsdir="$rtmpdir/tabs"
        mkdir -p -- "$tabsdir"
        # Views come from the *pre-cap* rows_all: a host tab shows that
        # host's own newest hits (up to max) even when none of them made
        # the globally-capped All view. Hosts with zero hits get no tab.
        # NB: the match must land in an array variable first — a ${(M)...}
        # with $'\t' inside (( )) silently mismatches (zsh arith quoting).
        local -a views vrows
        views=(All)
        printf '%s\n' "${rows[@]}" >"$tabsdir/view-1.rows"
        local _v
        for _v in local "${remote_hosts[@]}"; do
          vrows=(${(M)rows_all:#${_v}$'\t'*})
          (( ${#vrows} > 0 )) || continue
          views+=("$_v")
          printf '%s\n' "${vrows[@]:0:$max}" >"$tabsdir/view-${#views}.rows"
        done
        printf '%s\n' "${views[@]}" >"$tabsdir/views"
        print -r -- 1 >"$tabsdir/cur"
        local tabhelp='Tab/⇧Tab views · Enter resume · → preview · Esc'
        (( truncated )) && tabhelp="$tabhelp  (showing $max of $total)"
        print -r -- "$tabhelp" >"$tabsdir/help"
        header="$(_ccfind_tab_header "$tabsdir")"
        fzf_extra=(
          --bind "tab:transform:zsh -c 'source ${(q)_CCFIND_SOURCE}; _ccfind_tab_shift ${(q)tabsdir} 1'"
          --bind "btab:transform:zsh -c 'source ${(q)_CCFIND_SOURCE}; _ccfind_tab_shift ${(q)tabsdir} -1'"
        )
      fi
    fi

    local selected
    selected="$(
      printf '%s\n' "${rows[@]}" \
        | fzf \
            --delimiter=$'\t' --with-nth=$withnth \
            --no-sort --ansi --reverse --height=80% \
            --header="$header" \
            --preview "zsh -c 'export CCFIND_PV_CACHE=${(q)pvcache}; source ${(q)_CCFIND_SOURCE}; _ccfind_preview {1} {6}'" \
            --preview-window='hidden,right,60%,wrap' \
            --bind 'right:show-preview' \
            --bind 'left:hide-preview' \
            "${fzf_extra[@]}"
    )"
    [[ -z "$selected" ]] && return 0   # Esc / no match

    _ccfind_parse_row "$selected"
    if [[ "$_host" != "local" ]]; then
      _ccfind_remote_cmd "$_cwd" "$_id"
      ssh -t "$_host" "$_rcmd"
      return $?
    fi
    if [[ -n "$_cwd" && "$_cwd" != "?" && "$_cwd" != "$PWD" ]]; then
      if [[ ! -d "$_cwd" ]]; then
        echo "ccfind: session cwd no longer exists: $_cwd" >&2
        return 1
      fi
      cd "$_cwd" || { echo "ccfind: cd to $_cwd failed" >&2; return 1; }
    fi
    claude --resume "$_id"
    return $?
  fi

  # Flat-list path: original behaviour, plus a host tag on remote hits.
  local resume shown=0
  for _r in "${rows[@]}"; do
    (( shown > 0 )) && printf '\033[2m%s\033[0m\n' '──────────────────────────────────────────'
    _ccfind_parse_row "$_r"
    if [[ "$_host" != "local" ]]; then
      printf '\033[1m%s\033[0m  %s:%s\n' "$_ts" "$_host" "${_cwd:-?}"
    else
      printf '\033[1m%s\033[0m  %s\n' "$_ts" "${_cwd:-?}"
    fi
    [[ -n "$_snippet" ]] && printf '   \033[2m…%s…\033[0m\n' "$_snippet"
    if [[ "$_host" != "local" ]]; then
      _ccfind_remote_cmd "$_cwd" "$_id"
      resume="ssh -t $_host ${(qq)_rcmd}"
    elif [[ -n "$_cwd" && "$_cwd" != "?" && "$_cwd" != "$PWD" ]]; then
      resume="cd ${(q)_cwd} && claude --resume $_id"
    else
      resume="claude --resume $_id"
    fi
    printf '   %s\n' "$resume"
    (( shown++ ))
  done
  (( truncated )) && echo "… ($total total; raise with -n <max> or \$CCFIND_MAX)"
  return 0
}
