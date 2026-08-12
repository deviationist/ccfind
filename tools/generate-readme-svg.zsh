#!/usr/bin/env zsh
# ---------------------------------------------------------------------------
# tools/generate-readme-svg.zsh — regenerate the README SVGs.
#
# Renders the REAL ccfind into SVG terminal windows: builds a hermetic sandbox
# (a fake $HOME with two seeded Claude profiles, a stub `ssh` standing in for
# the remote host, and a stub `fzf` that records the row list the picker feeds
# it), runs the tool **unmodified**, and lays its output out on a terminal
# grid. The text in the images is therefore genuine output — colour and all —
# not art. Only the window chrome around it, and fzf's own furniture, is drawn.
#
# Sibling of claude-profile's / claude-usage's / claude-statusline's
# tools/generate-readme-svg.zsh, from which the grid + emitter core here is
# borrowed; keep them roughly in sync. Three differences worth knowing:
#
#   * ccfind colours nearly everything it prints, so the ANSI→<tspan> converter
#     is on the main path here rather than a special case — and it grew reverse
#     video (SGR 7), which is how the tab bar marks the current view.
#   * the picker paints with cursor addressing an SVG grid cannot replay, so —
#     as in claude-profile — a stub `fzf` captures exactly the rows and the argv
#     the real picker is handed, and fzf's furniture (prompt, match counter,
#     pointer, preview border) is drawn around genuine rows.
#   * one image is animated: the same captured material, laid out as frames that
#     a CSS keyframe timeline steps through, so the README can show the ↓ ↓ →
#     interaction instead of describing it. Static twins of every frame ship
#     alongside it, so a renderer that ignores the animation still has the
#     stills — and prefers-reduced-motion freezes it on the preview frame.
#
# Usage:  zsh tools/generate-readme-svg.zsh
#           → assets/{demo,picker,preview,tabs,list}-<hash>.svg, older ones
#             deleted, README <img> references rewritten (the random hash busts
#             GitHub's camo image cache). Commit all five files.
#         zsh tools/generate-readme-svg.zsh OUTDIR
#           → fixed names in OUTDIR, README untouched (for eyeballing a change).
#
# Regenerate whenever the picker layout, the flat list, the colours, or these
# demo values change. Session timestamps are seeded relative to the run, so the
# clock times in the images track the day you run it — fine for a demo.
# ---------------------------------------------------------------------------
emulate -L zsh
setopt extended_glob

zmodload zsh/datetime          # $EPOCHSECONDS + strftime, portable across GNU/BSD

here=${0:a:h}
root=${here:h}

tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT

# ---- hermetic sandbox ------------------------------------------------------
# A fake $HOME with two Claude config dirs. Nothing here reads or writes your
# own ~/.claude, and no ssh connection is ever made.
fakehome="$tmp/home"
work="$fakehome/.claude"
personal="$fakehome/.claude-personal"
mkdir -p "$work/projects" "$personal/projects" "$tmp/bin"

# ccfind auto-loads a .env from beside its own file. Run from a COPY in the
# sandbox, so the operator's real .env — hosts, remote-resume hook, tab
# preference — cannot leak into the images. (Same trick as tests/helpers.bash.)
ccfind_zsh="$tmp/ccfind.zsh"
cp "$root/ccfind.zsh" "$ccfind_zsh"

export HOME="$fakehome"
export USER=demo
unset CLAUDE_CONFIG_DIR CCFIND_MAX CCFIND_TABS CCFIND_HOSTS CCFIND_PROFILES \
      CCFIND_REMOTE_RESUME CCFIND_INTERACTIVE NO_COLOR

# seed <config-dir> <cwd> <id> <age-seconds> <jsonl-body...>
# Writes a transcript where Claude Code would, then backdates it: ccfind orders
# by mtime, so the age is what puts these rows in a deliberate order.
seed() {
  local dir="$1" cwd="$2" id="$3" age="$4"; shift 4
  local enc="${cwd//\//-}"
  mkdir -p "$dir/projects/$enc"
  local f="$dir/projects/$enc/$id.jsonl"
  : > "$f"
  local ln
  for ln in "$@"; do print -r -- "$ln" >> "$f"; done
  touch -t "$(strftime '%Y%m%d%H%M.%S' $(( EPOCHSECONDS - age )))" "$f"
}

# Transcript lines in Claude Code's shape: one JSON object per line, the text
# inside message.content. ccfind greps these raw, so the snippets it shows are
# slices of exactly these lines.
u() { print -r -- "{\"type\":\"user\",\"cwd\":\"$1\",\"message\":{\"role\":\"user\",\"content\":\"$2\"}}" }
a() { print -r -- "{\"type\":\"assistant\",\"cwd\":\"$1\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"$2\"}]}}" }

C1="$fakehome/code/api-gateway"
C2="$fakehome/code-private/ccfind"
C3="$fakehome/code/infra"
mkdir -p "$C1" "$C2" "$C3"     # the recorded cwds have to exist: ccfind cds into one

seed "$work" "$C1" 4f2c9a1e 480 \
  "$(u "$C1" 'staging deploy is dead again — connection refused on every request to the pooler')" \
  "$(a "$C1" 'The gateway is dialing 6432 but pgbouncer moved to 5432 in the last chart bump.')" \
  "$(u "$C1" 'so the readiness probe was lying?')" \
  "$(a "$C1" 'Yes — it probes the container port, not the pooler. Pinning both to 5432 fixes it.')"

seed "$personal" "$C2" 7b3e05d4 3300 \
  "$(u "$C2" 'the remote preview says connection refused when the host is only reachable over the VPN')" \
  "$(a "$C2" 'ssh BatchMode gives up after ConnectTimeout=6 — the preview falls back to a message.')"

seed "$work" "$C3" 91ad7c60 10800 \
  "$(u "$C3" 'terraform apply keeps failing: connection refused talking to the vault sidecar')" \
  "$(a "$C3" 'The sidecar starts after the job container. Order it with a depends_on.')"

seed "$personal" "$fakehome/.zsh" c08f14b2 172800 \
  "$(u "$fakehome/.zsh" 'zle widget rebinding after a connection refused in the prompt hook')"

# ---- stub ssh: one remote host, without a network --------------------------
# The host is a whole fake machine rather than a canned reply: its own $HOME,
# its own ccfind install, and its own .env naming ITS profiles — which is the
# point, since those labels are something the caller cannot know and has to ask
# the host for. The stub runs the command locally under that HOME, so the
# worker script really travels over stdin, really finds that ccfind, and the
# rows really come from its --tsv emitter. The preview fetch (`cat <path>`)
# lands in the same place.
rhome="$tmp/remote-home"
rcc="$tmp/remote-ccfind"
mkdir -p "$rhome" "$rcc"
cp "$root/ccfind.zsh" "$rcc/ccfind.zsh"
cat > "$rcc/.env" <<ENV
typeset CCFIND_PROFILES="ops:$rhome/.claude media:$rhome/.claude-media"
ENV

R1=/srv/media-tools
R2=/srv/backup
# seed_at <config-dir> <cwd> <id> <age> <lines…> — seed(), but on the fake host.
seed_at() {
  local dir="$1" cwd="$2" id="$3" age="$4"; shift 4
  local enc="${cwd//\//-}"
  mkdir -p "$dir/projects/$enc"
  local f="$dir/projects/$enc/$id.jsonl" ln
  : > "$f"
  for ln in "$@"; do print -r -- "$ln" >> "$f"; done
  touch -t "$(strftime '%Y%m%d%H%M.%S' $(( EPOCHSECONDS - age )))" "$f"
}
seed_at "$rhome/.claude" "$R1" a1c6f83b 2400 \
  "$(u "$R1" 'rclone mount died overnight — connection refused from the metadata endpoint')" \
  "$(a "$R1" 'The token refresh runs at 04:00 and the mount is never retried after it.')"
seed_at "$rhome/.claude-media" "$R2" e5710b93 7200 \
  "$(u "$R2" 'restic check ends in connection refused halfway through the snapshot list')"

cat > "$tmp/bin/ssh" <<'STUB'
#!/bin/sh
# Stub ssh: run the remote command here, under the fake host's HOME. The last
# argument is the command, exactly as a real ssh would receive it.
for a in "$@"; do cmd="$a"; done
cmd="${cmd#CCFIND_REMOTE_PATH=* }"        # the caller's hint; we point at ours
HOME="$REMOTE_HOME" CCFIND_REMOTE_PATH="$REMOTE_CCFIND" exec sh -c "$cmd"
STUB
chmod +x "$tmp/bin/ssh"
export REMOTE_HOME="$rhome" REMOTE_CCFIND="$rcc/ccfind.zsh"

# ---- stub fzf: record what the picker is handed ---------------------------
# Written before PATH is exported: zsh hashes the contents of every PATH
# directory, so a command that appears in an already-hashed dir stays invisible
# until a `rehash` — creating this later would silently run the operator's real
# fzf against their own terminal.
cat > "$tmp/bin/fzf" <<'STUB'
#!/bin/sh
# --version is a real query: ccfind gates its tab views on fzf >= 0.45.
case "$1" in --version) echo "0.74.2 (stub)"; exit 0 ;; esac
printf '%s\n' "$@" > "$FZF_ARGS"
cat > "$FZF_CAPTURE"
exit 130          # fzf's "cancelled" — so nothing is selected and no resume runs
STUB
chmod +x "$tmp/bin/fzf"

export PATH="$tmp/bin:$PATH"
rehash

export CCFIND_PROFILES="work:$work personal:$personal"
export CCFIND_HOSTS="nas"
export CCFIND_COLOR=always
QUERY='connection refused'

# ---- capture the real output ----------------------------------------------
# The picker. -i is ccfind's documented "give me the picker regardless" flag,
# which is what lets this run with no terminal anywhere in sight; the stub fzf
# records the rows and exits 130, so ccfind returns having selected nothing.
run_picker() {   # <capture-file> <argv-file> [extra ccfind args...]
  # NB: not `local argv=` — in zsh $argv *is* $@, and assigning it here would
  # rewrite this function's own positional parameters out from under the shift.
  local cap="$1" argf="$2"; shift 2
  ( cd "$C1"
    export FZF_CAPTURE="$cap" FZF_ARGS="$argf"
    source "$ccfind_zsh"
    ccfind -i -r "$@" $QUERY ) >/dev/null 2>&1
}
run_picker "$tmp/rows" "$tmp/argv"
CCFIND_TABS=1 run_picker "$tmp/tab-rows" "$tmp/tab-argv"

# The flat list, from the same search.
list_out=$( cd "$C1"
            source "$ccfind_zsh"
            ccfind -N -r $QUERY 2>&1 )

# The preview pane, for the row the picker opens on.
pv_out=$( export CCFIND_LOCAL_LABELS="work personal" CCFIND_PV_QUERY="$QUERY"
          source "$ccfind_zsh"
          _ccfind_preview work "$work/projects/${C1//\//-}/4f2c9a1e.jsonl" 2>&1 )

# ...and the remote one, which the animation opens: the stub ssh answers the
# fetch, so this is the genuine "preview a session on another host" pane.
pv_nas=$( export CCFIND_LOCAL_LABELS="work personal" CCFIND_PV_QUERY="$QUERY" \
                 CCFIND_PV_CACHE="$tmp"
          source "$ccfind_zsh"
          _ccfind_preview nas "$rhome/.claude/projects/${R1//\//-}/a1c6f83b.jsonl" 2>&1 )

# The tool prints paths verbatim; contract the sandbox home the same way it
# would contract a real one, so the demo reads like a machine and not a
# mktemp dir. Display-only — nothing about the run depends on it.
enc_home="${fakehome//\//-}"      # Claude's cwd encoding: every / becomes -
list_out=${list_out//$fakehome/\~}
list_out=${list_out//$rhome/\~}
pv_out=${pv_out//$enc_home/-Users-demo}
pv_out=${pv_out//$fakehome/\~}
pv_nas=${pv_nas//$enc_home/-Users-demo}
pv_nas=${pv_nas//$fakehome/\~}
pv_nas=${pv_nas//$rhome/\~}          # the remote's own home, contracted alike

typeset -a rows fargs trows tfargs
rows=("${(@f)$(<"$tmp/rows")}");        rows=(${rows:#})
fargs=("${(@f)$(<"$tmp/argv")}")
trows=("${(@f)$(<"$tmp/tab-rows")}");   trows=(${trows:#})
tfargs=("${(@f)$(<"$tmp/tab-argv")}")

# Only field 7 — the display line ccfind composes — is ever drawn; the six data
# fields behind it are what fzf hides.
rows=("${(@)rows/*$'\t'/}")      # * is greedy: everything through the last tab
trows=("${(@)trows/*$'\t'/}")
rows=("${(@)rows//$fakehome/\~}")
trows=("${(@)trows//$fakehome/\~}")
rows=("${(@)rows//$rhome/\~}")
trows=("${(@)trows//$rhome/\~}")

header=''; theader=''
for a in "${fargs[@]}";  do [[ $a == --header=* ]] && header=${a#--header=};  done
for a in "${tfargs[@]}"; do [[ $a == --header=* ]] && theader=${a#--header=}; done

[[ -n $list_out && -n $pv_out && -n $pv_nas && ${#rows} -gt 0 && ${#trows} -gt 0 && -n $header ]] || {
  print -u2 "generate-readme-svg: sandbox produced no output — aborting"; exit 1
}
print -u2 "captured ${#rows} picker rows, ${#trows} tab rows"

# ---------------------------------------------------------------------------
# SVG
# ---------------------------------------------------------------------------
# Catppuccin Mocha chrome, matching the sibling generators.
BG='#1e1e2e'  BAR='#181825'  FG='#cdd6f4'  DIMC='#9399b2'
DOT1='#f38ba8' DOT2='#f9e2af' DOT3='#a6e3a1'
# fzf's own furniture, in its default roles.
ACC='#89dceb'   # prompt string
PTR='#f38ba8'   # current-line marker bar
INFO='#f9e2af'  # match counter
RULE='#45475a'  # the rule fzf draws on the info line, and the preview border
GUT='#313244'   # the gutter every list row carries
HL='#313244'    # current-line background
# The 8 normal + 8 bright ANSI foregrounds these images can contain.
typeset -a ANSI_N ANSI_B
ANSI_N=('#45475a' '#f38ba8' '#a6e3a1' '#f9e2af' '#89b4fa' '#f5c2e7' '#94e2d5' '#bac2de')
ANSI_B=('#585b70' '#f38ba8' '#a6e3a1' '#f9e2af' '#89b4fa' '#f5c2e7' '#94e2d5' '#a6adc8')
FONT="'Cascadia Code','Fira Code',SFMono-Regular,Consolas,Menlo,monospace"
integer FS=13 LH=20 TH=30 PX=20 PY=14 SLACK=24 MINCOLS=52

# Terminal grid: every character is pinned to its own cell, so a row occupies
# exactly (columns × cw) in whichever font the renderer falls back to — which
# is what keeps the columns aligned in a browser that has none of these fonts.
typeset -a XCOL
local -F cw=7.85
integer k; local v
for (( k = 0; k <= 400; k++ )); do printf -v v '%.2f' $(( PX + k * cw )); XCOL[k+1]=$v; done
integer PANE=0                      # column offset of the pane being drawn
xrun() { print -rn -- "${(j: :)XCOL[PANE+$1+1,PANE+$1+$2]}" }
xat()  { print -rn -- "$XCOL[PANE+$1+1]" }
xesc() { local s=$1; s=${s//\&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}; print -rn -- "$s" }

# Visible length of a line, ignoring SGR — what the grid must size to.
vlen() { local t=$1; t=${t//$'\e['[0-9;]#m/}; print -rn -- ${#t} }

# clip_ansi <line> <cols> — cut to <cols> *visible* columns, keeping the SGR
# runs that got us there (a terminal clips the drawing, not the state).
clip_ansi() {
  local s=$1 out="" pre esc; integer want=$2 seen=0 take
  while [[ -n $s ]]; do
    pre=${s%%$'\e'*}
    if [[ -n $pre ]]; then
      take=$(( want - seen ))
      (( take <= 0 )) && break
      if (( ${#pre} >= take )); then out+="${pre[1,take]}"; seen=$want; break; fi
      out+="$pre"; (( seen += ${#pre} ))
    fi
    s=${s[$(( ${#pre} + 1 )),-1]}
    [[ -n $s ]] || break
    esc=${s%%m*}m; out+="$esc"; s=${s[$(( ${#esc} + 1 )),-1]}
  done
  print -rn -- "$out"
}

# wrap_ansi <line> <cols> — split into ≤<cols>-wide pieces, carrying the active
# SGR state onto each continuation. fzf's preview window is opened with `wrap`,
# so this is what the pane actually does with a long line.
typeset -ga WRAPPED
wrap_ansi() {
  local s=$1 cur="" pre esc state=""
  integer want=$2 seen=0 take
  WRAPPED=()
  while [[ -n $s ]]; do
    pre=${s%%$'\e'*}
    s=${s[$(( ${#pre} + 1 )),-1]}
    while [[ -n $pre ]]; do
      take=$(( want - seen ))
      if (( ${#pre} > take )); then
        cur+="${pre[1,take]}"; pre=${pre[$(( take + 1 )),-1]}
        WRAPPED+=("$cur"); cur="$state"; seen=0
      else
        cur+="$pre"; (( seen += ${#pre} )); pre=""
      fi
    done
    [[ -n $s ]] || break
    esc=${s%%m*}m
    s=${s[$(( ${#esc} + 1 )),-1]}
    cur+="$esc"
    if [[ $esc == $'\e[0m' ]]; then state=""; else state+="$esc"; fi
  done
  WRAPPED+=("$cur")
}

# One SGR line → <tspan> runs, carrying bold/dim/reverse + colour across the
# line. Every run is pinned to its own columns so alignment survives font
# fallback. Reverse video (SGR 7) is drawn the way a terminal draws it: a filled
# rect in the foreground colour with the text knocked out in the background one
# — which is how ccfind marks the current tab.
# Sets two globals rather than printing: RENDERED (the <tspan> runs) and
# REV_RECTS (the rects behind any reverse-video run). It must NOT be called as
# $(render_ansi …) — a subshell would swallow the second one, which is exactly
# how the active tab first came out invisible: text knocked out in the
# background colour, with nothing drawn behind it.
typeset -g REV_RECTS RENDERED
render_ansi() {
  local s=$1 out="" pre tail params pcode fill=""
  integer col=${2:-0} bold=0 dim=0 rev=0
  local cidx=""
  local -a parts
  REV_RECTS=""
  recompute() {
    if [[ -n $cidx ]]; then (( bold )) && fill=$ANSI_B[cidx+1] || fill=$ANSI_N[cidx+1]
    elif (( dim )); then fill=$DIMC
    else fill=""; fi
  }
  while [[ -n $s ]]; do
    pre=${s%%$'\e'*}
    if [[ -n $pre ]]; then
      if (( rev )); then
        REV_RECTS+="<rect x=\"$(xat col)\" y=\"@Y@\" width=\"$(( ${#pre} * cw + 0.5 ))\" height=\"$LH\" fill=\"${fill:-$FG}\"/>"
        out+="<tspan x=\"$(xrun col ${#pre})\" fill=\"$BG\">$(xesc "$pre")</tspan>"
      else
        out+="<tspan x=\"$(xrun col ${#pre})\"${fill:+ fill=\"$fill\"}>$(xesc "$pre")</tspan>"
      fi
      (( col += ${#pre} ))
    fi
    s=${s[$(( ${#pre} + 1 )),-1]}
    [[ -n $s ]] || break
    if [[ ${s[2]} == '[' ]]; then
      tail=${s#$'\e['}; params=${tail%%m*}
      s=${tail[$(( ${#params} + 2 )),-1]}
      parts=(${(s:;:)params}); (( ${#parts} )) || parts=(0)
      for pcode in $parts; do
        case $pcode in
          0)  bold=0; dim=0; rev=0; cidx="" ;;
          1)  bold=1 ;;
          2)  dim=1 ;;
          7)  rev=1 ;;
          <30-37>) cidx=$(( pcode - 30 )) ;;
          <90-97>) cidx=$(( pcode - 90 )); bold=1 ;;
          39) cidx="" ;;
        esac
      done
      recompute
    else
      s=${s[3,-1]}
    fi
  done
  RENDERED="$out"
}

# emit_lines <array-name> <y0> <x-offset> — draw one pane's worth of lines,
# returning the SVG body. Entry format: TYPE|content, where
#   b = blank                     t = plain          c = dim
#   a = ANSI (terminal output)    h = fzf header     i = fzf match counter
#   n = list row                  p = current row    q = fzf prompt + cursor
#   x = shell input, block cursor parked after the last character
# Everything in the fzf frame except q sits at column 2, as fzf indents it.
emit_lines() {
  local -a _l=("${(@P)1}")
  integer y0=$2 W=$4
  PANE=$3
  local entry typ body T out=""
  integer i=0 y
  for entry in "${_l[@]}"; do
    typ=${entry%%\|*}; body=${entry#*|}
    y=$(( y0 + i * LH + FS ))
    T="  <text y=\"$y\" font-family=\"$FONT\" font-size=\"$FS\" xml:space=\"preserve\""
    case $typ in
      b) ;;
      t) out+="$T fill=\"$FG\"><tspan x=\"$(xrun 0 ${#body})\">$(xesc "$body")</tspan></text>"$'\n' ;;
      c) out+="$T fill=\"$DIMC\"><tspan x=\"$(xrun 0 ${#body})\">$(xesc "$body")</tspan></text>"$'\n' ;;
      a) render_ansi "$body"
         [[ -n $REV_RECTS ]] && out+="${REV_RECTS//@Y@/$(( y - FS - 3 ))}"$'\n'
         out+="$T fill=\"$FG\">$RENDERED</text>"$'\n' ;;
      h) render_ansi "$body" 2
         [[ -n $REV_RECTS ]] && out+="${REV_RECTS//@Y@/$(( y - FS - 3 ))}"$'\n'
         out+="$T fill=\"$FG\">$RENDERED</text>"$'\n' ;;
      i) # fzf's --separator draws the rule on the info line, from just past the
         # counter out to the right edge of the finder.
         integer rx=$(( PX + PANE * cw + (${#body} + 3) * cw ))
         out+="  <rect x=\"$rx\" y=\"$(( y - FS / 2 + 1 ))\" width=\"$(( W - rx - PX ))\" height=\"1\" fill=\"$RULE\"/>"$'\n'
         out+="$T fill=\"$INFO\"><tspan x=\"$(xrun 2 ${#body})\">$(xesc "$body")</tspan></text>"$'\n' ;;
      n) render_ansi "$body" 2
         out+="  <rect x=\"$(xat 0)\" y=\"$(( y - FS - 3 ))\" width=\"3\" height=\"$LH\" fill=\"$GUT\"/>"$'\n'
         out+="$T fill=\"$FG\">$RENDERED</text>"$'\n' ;;
      p) render_ansi "$body" 2
         out+="  <rect x=\"0\" y=\"$(( y - FS - 3 ))\" width=\"$W\" height=\"$LH\" fill=\"$HL\"/>"$'\n'
         out+="  <rect x=\"$(xat 0)\" y=\"$(( y - FS - 3 ))\" width=\"3\" height=\"$LH\" fill=\"$PTR\"/>"$'\n'
         out+="$T fill=\"$FG\">$RENDERED</text>"$'\n' ;;
      x) out+="  <rect x=\"$(xat ${#body})\" y=\"$(( y - FS + 1 ))\" width=\"8\" height=\"$(( FS + 3 ))\" fill=\"$FG\" opacity=\"0.75\"/>"$'\n'
         out+="$T fill=\"$FG\"><tspan x=\"$(xrun 0 ${#body})\">$(xesc "$body")</tspan></text>"$'\n' ;;
      q) out+="  <rect x=\"$(xat ${#body})\" y=\"$(( y - FS + 1 ))\" width=\"8\" height=\"$(( FS + 3 ))\" fill=\"$FG\" opacity=\"0.75\"/>"$'\n'
         out+="$T fill=\"$ACC\"><tspan x=\"$(xrun 0 ${#body})\">$(xesc "$body")</tspan></text>"$'\n' ;;
    esac
    (( i++ ))
  done
  PANE=0
  print -rn -- "$out"
}

# chrome <W> <H> <title> — the window: rounded body, title bar, traffic lights.
chrome() {
  integer W=$1 H=$2
  print -r -- "  <rect width=\"$W\" height=\"$H\" rx=\"10\" fill=\"$BG\"/>"
  print -r -- "  <rect width=\"$W\" height=\"$TH\" rx=\"10\" fill=\"$BAR\"/>"
  print -r -- "  <rect y=\"$(( TH - 6 ))\" width=\"$W\" height=\"6\" fill=\"$BAR\"/>"
  print -r -- "  <circle cx=\"18\" cy=\"$(( TH / 2 ))\" r=\"5.5\" fill=\"$DOT1\"/><circle cx=\"36\" cy=\"$(( TH / 2 ))\" r=\"5.5\" fill=\"$DOT2\"/><circle cx=\"54\" cy=\"$(( TH / 2 ))\" r=\"5.5\" fill=\"$DOT3\"/>"
  print -r -- "  <text x=\"$(( W / 2 ))\" y=\"$(( TH / 2 + 5 ))\" text-anchor=\"middle\" font-family=\"$FONT\" font-size=\"12\" fill=\"$DIMC\">$3</text>"
}

# svg_open <W> <H> <aria> / svg_close
svg_open() {
  print -r -- "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"$1\" height=\"$2\" viewBox=\"0 0 $1 $2\" role=\"img\" aria-label=\"$(xesc "$3")\">"
}
svg_close() { print -r -- "</svg>" }

# canvas_w <cols> — window width for a <cols>-wide terminal.
canvas_w() { print -rn -- $(( PX * 2 + $1 * cw + 6 + SLACK )) }
canvas_h() { print -rn -- $(( TH + PY + $1 * LH + PY )) }

# preview_box <x-col> <y0> <lines> — fzf's preview window border (rounded, its
# default) around a pane that starts at column <x-col>.
preview_box() {
  integer x=$(( PX + $1 * cw - 8 )) y=$(( $2 - 6 )) w=$3 h=$(( $4 * LH + 12 ))
  print -r -- "  <rect x=\"$x\" y=\"$y\" width=\"$w\" height=\"$h\" rx=\"6\" fill=\"none\" stroke=\"$RULE\" stroke-width=\"1\"/>"
}

# ---------------------------------------------------------------------------
# compose
# ---------------------------------------------------------------------------
# The width of the terminal these are drawn in. Rows longer than this are cut,
# exactly as fzf cuts them — the snippet column is the part that runs off, and
# that is what it looks like in a real window.
integer COLS=140
# The preview shot gets a wider one: a side pane is something you open on a wide
# terminal, and at 140 columns fzf's 60% preview would leave the list too narrow
# to show what it is previewing.
integer PVTOTAL=176
integer PVCOLS=$(( PVTOTAL * 60 / 100 ))       # --preview-window=right,60%
integer LSTCOLS=$(( PVTOTAL - PVCOLS - 2 ))

# fzf_frame <out-array> <rows-array> <header> <current-index> <width>
# The finder as it is laid out with --reverse: prompt, match counter, header,
# then the rows.
fzf_frame() {
  local -a _rows=("${(@P)2}")
  local hdr=$3; integer cur=$4 w=$5
  local -a out=("q|> " "i|${#_rows}/${#_rows}" "h|$(clip_ansi "$hdr" $(( w - 2 )))")
  integer j=1 ln
  for ln in {1..${#_rows}}; do
    if (( ln == cur )); then out+=("p|$(clip_ansi "${_rows[ln]}" $(( w - 2 )))")
    else                     out+=("n|$(clip_ansi "${_rows[ln]}" $(( w - 2 )))"); fi
  done
  set -A $1 "${out[@]}"
}

# The command line as a user would type it. ccfind is actually invoked with -i
# as well, so the stub fzf can stand in with no terminal present — an artefact
# of the harness, not something to show.
CMD_PICKER='% ccfind -r "connection refused"'
CMD_LIST='% ccfind -N -r "connection refused"'

typeset -a picker_lines tab_lines list_lines pv_lines
fzf_frame picker_lines rows "$header" 1 $COLS
picker_lines=("t|$CMD_PICKER" 'b|' "${picker_lines[@]}")

fzf_frame tab_lines trows "$theader" 1 $COLS
tab_lines=("t|$CMD_LIST" 'b|' "${tab_lines[@]}")
tab_lines[1]="t|% CCFIND_TABS=1 ccfind -r \"connection refused\""

list_lines=("t|$CMD_LIST" 'b|')
local ln
for ln in "${(@f)list_out}"; do
  [[ -z $ln ]] && { list_lines+=('b|'); continue }
  list_lines+=("a|$(clip_ansi "$ln" $COLS)")
done

# ---- write -----------------------------------------------------------------
# out <file> <lines-array> <aria> [<pv-array> <pv-start-line>]
out_svg() {
  local file=$1 arr=$2 aria=$3 pvarr=${4:-} ; integer pvstart=${5:-0}
  local -a _l=("${(@P)arr}")
  integer cols=0 n
  local e
  for e in "${_l[@]}"; do
    n=$(vlen "${e#*|}"); [[ ${e%%\|*} == (p|n|h|i) ]] && (( n += 2 ))
    (( n > cols )) && cols=$n
  done
  (( cols < MINCOLS )) && cols=$MINCOLS
  integer nlines=${#_l}
  local -a _pv
  if [[ -n $pvarr ]]; then
    _pv=("${(@P)pvarr}")
    cols=$(( LSTCOLS + 2 + PVCOLS ))
    (( pvstart + ${#_pv} > nlines )) && nlines=$(( pvstart + ${#_pv} ))
  fi
  integer W=$(canvas_w $cols) H=$(canvas_h $nlines)
  {
    svg_open $W $H "$aria"
    chrome $W $H 'ccfind'
    emit_lines $arr $(( TH + PY )) 0 $W
    if [[ -n $pvarr ]]; then
      preview_box $(( LSTCOLS + 2 )) $(( TH + PY + pvstart * LH )) \
                  $(( PVCOLS * cw + 10 )) ${#_pv}
      emit_lines $pvarr $(( TH + PY + pvstart * LH )) $(( LSTCOLS + 2 )) $W
    fi
    svg_close
  } > "$file"
}

# ---- the preview shot: two panes -------------------------------------------
typeset -a pvleft pvright
local w
fzf_frame pvleft rows "$header" 1 $LSTCOLS
pvleft=("t|$CMD_PICKER" 'b|' "${pvleft[@]}")
pvright=()
for ln in "${(@f)pv_out}"; do
  if [[ -z $ln ]]; then pvright+=('b|'); continue; fi
  wrap_ansi "$ln" $(( PVCOLS - 2 ))
  for w in "${WRAPPED[@]}"; do pvright+=("a|$w"); done
done

# ---------------------------------------------------------------------------
# the animated one
# ---------------------------------------------------------------------------
# Same captured material, laid out as frames on a CSS keyframe timeline: one
# <g> per frame, each visible for its slice of a looping cycle. No script — an
# SVG in an <img> (which is how GitHub serves a README asset, through camo) is
# rendered with scripting disabled but declarative animation live, so keyframes
# are the mechanism that actually survives the trip. prefers-reduced-motion
# freezes the whole thing on the last frame.
typeset -a a1 a2 a3 a4 a5
a1=("x|$CMD_PICKER")
# The one line here that is reconstructed rather than captured: ccfind prints
# this only when stderr is a terminal, which a sandbox has no way to be. It is
# the tool's own format string, filled with this run's host list.
a2=("t|$CMD_PICKER" 'b|' "c|⟳ searching 1 host(s): nas…")
fzf_frame a3 rows "$header" 1 $PVTOTAL
a3=("t|$CMD_PICKER" 'b|' "${a3[@]}")
fzf_frame a4 rows "$header" 2 $PVTOTAL
a4=("t|$CMD_PICKER" 'b|' "${a4[@]}")
typeset -a a5 a5pv
fzf_frame a5 rows "$header" 2 $LSTCOLS
a5=("t|$CMD_PICKER" 'b|' "${a5[@]}")
a5pv=()
for ln in "${(@f)pv_nas}"; do
  if [[ -z $ln ]]; then a5pv+=('b|'); continue; fi
  wrap_ansi "$ln" $(( PVCOLS - 2 ))
  for w in "${WRAPPED[@]}"; do a5pv+=("a|$w"); done
done

# The command types itself in: one frame per keystroke, with the block cursor
# parked after the last character. Same opacity mechanism as every other frame
# — no clip-path or transform — so the typing rides on exactly the machinery
# that is already known to survive the trip through GitHub. Each of these
# frames is a single short line, so 30 of them cost almost nothing.
# The "% " is the shell's prompt, not something the operator types.
typeset -a FR FR_PV FR_KEY FR_DUR
CMD_TYPED=${CMD_PICKER#'% '}
integer ci
for (( ci = 0; ci < ${#CMD_TYPED}; ci++ )); do
  set -A "type$ci" "x|% ${CMD_TYPED[1,ci]}"
  FR+=("type$ci"); FR_PV+=(''); FR_KEY+=(''); FR_DUR+=(55)
done

# …then the run itself. Durations in milliseconds.
FR+=(a1 a2 a3 a4 a5)
FR_PV+=('' '' '' '' a5pv)
# The keycap names the key that produced the frame you are looking at.
FR_KEY+=('' '⏎' '' '↓' '→')
FR_DUR+=(650 1000 1500 1200 4400)

# keycap <W> <glyph> — the little pressed-key badge, top right under the bar.
keycap() {
  integer W=$1 x=$(( $1 - 58 )) y=$(( TH + 10 ))
  print -r -- "  <rect x=\"$x\" y=\"$y\" width=\"38\" height=\"26\" rx=\"6\" fill=\"$HL\" stroke=\"$RULE\"/>"
  print -r -- "  <text x=\"$(( x + 19 ))\" y=\"$(( y + 18 ))\" text-anchor=\"middle\" font-family=\"$FONT\" font-size=\"14\" fill=\"$FG\">$2</text>"
}

anim_svg() {
  local file=$1 aria=$2
  integer nlines=0 cols=0 n i
  local e arr
  for arr in "${FR[@]}"; do
    local -a _l=("${(@P)arr}")
    (( ${#_l} > nlines )) && nlines=${#_l}
    for e in "${_l[@]}"; do
      n=$(vlen "${e#*|}"); [[ ${e%%\|*} == (p|n|h|i) ]] && (( n += 2 ))
      (( n > cols )) && cols=$n
    done
  done
  local pv
  for (( i = 1; i <= ${#FR}; i++ )); do
    pv=${FR_PV[i]}; [[ -n $pv ]] || continue
    local -a _p=("${(@P)pv}")
    (( 2 + ${#_p} > nlines )) && nlines=$(( 2 + ${#_p} ))
  done
  (( cols < LSTCOLS + 2 + PVCOLS )) && cols=$(( LSTCOLS + 2 + PVCOLS ))
  integer W=$(canvas_w $cols) H=$(canvas_h $nlines)

  integer total=0
  for n in "${FR_DUR[@]}"; do (( total += n )); done

  {
    svg_open $W $H "$aria"
    # The timeline. Each frame owns a window of the cycle, and the switch has to
    # be a hard cut — a terminal does not dissolve between states, and a frame
    # that fades leaves the one behind it showing through (the preview pane's
    # border ghosting over the list, most visibly).
    #
    # step-end is what guarantees that. Writing two stops at the same percentage
    # does NOT: duplicate stops collapse to the last declaration, so
    # `0%,50%{opacity:0} 50%,100%{opacity:1}` is really "0 at 0%, 1 at 50%" and
    # the browser interpolates the whole way — a half-cycle cross-fade. With
    # step-end each value simply holds until the next stop, so one stop per
    # switch says exactly what it means.
    print -r -- "  <style>"
    print -r -- "    .fr{opacity:0}"
    integer at=0 j
    local -F p0 p1
    for (( j = 1; j <= ${#FR}; j++ )); do
      p0=$(( at * 100.0 / total ))
      (( at += FR_DUR[j] ))
      p1=$(( at * 100.0 / total ))
      print -r -- "    #fr$j{animation:k$j ${total}ms step-end infinite}"
      if (( j == 1 )); then
        printf '    @keyframes k%d{0%%{opacity:1}%.3f%%{opacity:0}}\n' $j $p1
      elif (( j == ${#FR} )); then
        printf '    @keyframes k%d{0%%{opacity:0}%.3f%%{opacity:1}}\n' $j $p0
      else
        printf '    @keyframes k%d{0%%{opacity:0}%.3f%%{opacity:1}%.3f%%{opacity:0}}\n' $j $p0 $p1
      fi
    done
    print -r -- "    @media (prefers-reduced-motion:reduce){.fr{animation:none!important;opacity:0}#fr${#FR}{opacity:1}}"
    print -r -- "  </style>"
    chrome $W $H 'ccfind'
    for (( j = 1; j <= ${#FR}; j++ )); do
      # opacity="0" as a presentation attribute, on every frame but the LAST:
      # CSS (and therefore the animation) overrides it, so this changes nothing
      # where the timeline runs — but a renderer that ignores <style> altogether
      # then shows one frame instead of all of them stacked, and the one worth
      # showing is the final state, which is what prefers-reduced-motion picks
      # too. (First-frame-visible would now mean an empty prompt: the command
      # types itself in, so frame 1 is a bare "%".)
      print -r -- "  <g id=\"fr$j\" class=\"fr\"$( (( j < ${#FR} )) && print -n ' opacity=\"0\"')>"
      emit_lines ${FR[j]} $(( TH + PY )) 0 $W
      pv=${FR_PV[j]}
      if [[ -n $pv ]]; then
        local -a _p=("${(@P)pv}")
        preview_box $(( LSTCOLS + 2 )) $(( TH + PY + 2 * LH )) $(( PVCOLS * cw + 10 )) ${#_p}
        emit_lines $pv $(( TH + PY + 2 * LH )) $(( LSTCOLS + 2 )) $W
      fi
      [[ -n ${FR_KEY[j]} ]] && keycap $W "${FR_KEY[j]}"
      print -r -- "  </g>"
    done
    svg_close
  } > "$file"
}

# ---- output ----------------------------------------------------------------
DEMO_ARIA='ccfind running: a search across two local profiles and one remote host, the picker listing the hits newest first, the selection moving down a row, and the preview pane opening on a session that lives on another machine'
PICKER_ARIA='the ccfind fzf picker: five matching sessions, each row a timestamp, the profile or host it belongs to, its working directory and the matching text with the search term highlighted'
PREVIEW_ARIA='the ccfind picker with the preview pane open, showing the last messages of the highlighted session with the search term highlighted in them'
TABS_ARIA='the ccfind picker with CCFIND_TABS=1: a tab bar reading All, work, personal, nas, with All selected, above the merged list'
LIST_ARIA='the ccfind flat list: each hit as a timestamp and profile-tagged directory, the matching snippet beneath it, and the exact resume command to copy'

if [[ -n ${1:-} ]]; then
  outdir=$1; mkdir -p "$outdir"
  anim_svg "$outdir/demo.svg"      "$DEMO_ARIA"
  out_svg  "$outdir/picker.svg"  picker_lines "$PICKER_ARIA"
  out_svg  "$outdir/preview.svg" pvleft       "$PREVIEW_ARIA" pvright 2
  out_svg  "$outdir/tabs.svg"    tab_lines    "$TABS_ARIA"
  out_svg  "$outdir/list.svg"    list_lines   "$LIST_ARIA"
  print "wrote $outdir/{demo,picker,preview,tabs,list}.svg"
else
  mkdir -p "$root/assets"
  for old in "$root"/assets/*-*.svg(N); do rm -f "$old"; done
  hash=$(xxd -l3 -p /dev/urandom)
  anim_svg "$root/assets/demo-${hash}.svg"       "$DEMO_ARIA"
  out_svg  "$root/assets/picker-${hash}.svg"  picker_lines "$PICKER_ARIA"
  out_svg  "$root/assets/preview-${hash}.svg" pvleft       "$PREVIEW_ARIA" pvright 2
  out_svg  "$root/assets/tabs-${hash}.svg"    tab_lines    "$TABS_ARIA"
  out_svg  "$root/assets/list-${hash}.svg"    list_lines   "$LIST_ARIA"
  sed -i.bak \
    -e "s|assets/demo-[^)\"]*\.svg|assets/demo-${hash}.svg|" \
    -e "s|assets/picker-[^)\"]*\.svg|assets/picker-${hash}.svg|" \
    -e "s|assets/preview-[^)\"]*\.svg|assets/preview-${hash}.svg|" \
    -e "s|assets/tabs-[^)\"]*\.svg|assets/tabs-${hash}.svg|" \
    -e "s|assets/list-[^)\"]*\.svg|assets/list-${hash}.svg|" \
    "$root/README.md" && rm -f "$root/README.md.bak"
  print "wrote assets/{demo,picker,preview,tabs,list}-${hash}.svg and updated README.md"
fi
