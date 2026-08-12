# ccfind — agent index

`ccfind` fuzzy-finds and resumes past Claude Code sessions. `claude --resume` is
cwd-scoped and can't see sessions from other directories; `ccfind` greps the whole
`~/.claude/projects` tree (all cwds), newest-first, and resumes the chosen one.

**Entry point:** `ccfind.zsh` defines the `ccfind` function (sourced from `~/.zshrc`).
Config auto-loads from a gitignored `.env` beside the script (see `.env.example`).

## Command

```
ccfind [text...]                   literal, case-insensitive; newest-first
  -d <dir>     scope to sessions whose cwd is <dir> or below
  -n <max>     cap hits (default 10; = CCFIND_MAX)
  -N | -i      force flat-list / force picker (-i also overrides the TTY check)
  -C           no colour (= NO_COLOR=1 / CCFIND_COLOR=never)
  -v           note on stderr what each remote host was searched with
  -j | --tsv   machine output: JSON document / raw tab-separated records
  -r           also search CCFIND_HOSTS over ssh   (alias: ccfindr = ccfind -r)
  -H "<hosts>" search an explicit ssh-alias list (implies remote)
  -l           force local only (trumps -r / -H)
  -p <label>   scope local search to one CCFIND_PROFILES profile
  <label> ...  positional shorthand for -p (e.g. `ccfind work foo`; flags first)
```

- **Picker (default when `fzf` + TTY):** Enter cds to the session's cwd and runs
  `claude --resume <id>`; `→` previews the last user+assistant messages (`←` hides);
  Esc cancels. Falls back to a flat list (one resume command per hit) when `fzf` is
  absent, output is piped, `-N`, or `CCFIND_INTERACTIVE=0`.
- **Multi-host (`-r`/`-H`):** a self-contained POSIX worker runs over `ssh <host>
  sh -s` — nothing installed remotely, only per-hit metadata returns. Remote hits
  merge newest-first with a host column; resume becomes `ssh -t <host> 'cd <cwd> &&
  exec "$SHELL" -ic claude --resume <id>'`. Host precedence: `-H` > env `CCFIND_HOSTS`
  > `.env`. Unreachable host = one stderr line, rest still show.
- **Remote profiles:** the worker looks for a ccfind ON the host (`$CCFIND_REMOTE_PATH`,
  `~/ccfind/ccfind.zsh`, `~/.zsh/…`, `~/.config/…` — `command -v` can't see a shell
  function) and runs `ccfind --tsv -l` there — **every** candidate is tried until one answers, so a stale clone at an earlier path can't shadow a current one, so that host's own `.env` decides its
  profiles; hits tag `<host>:<profile>` and resume pins that host's `CLAUDE_CONFIG_DIR`.
  No ccfind (or one too old for `--tsv`, which exits non-zero) → the filesystem walk,
  default profile only, quiet; `-v` reports which path each host took. Both live in
  ONE connection — a capability probe would double the ssh cost. The remote call
  `unset`s inherited `CCFIND_*` so only the host's config applies.
- **Machine output:** `--json` (envelope: version/query/scope/total/shown/truncated/
  results[]) and `--tsv` (the wire record, host column dropped — the caller knows the
  alias it dialled). Both imply no picker and no colour, and stay well-formed with
  zero results: a sentence where a document belongs would be parsed as a record.
- **Multi-profile — two sources, checked in order:** `CCFIND_PROFILES="label:dir …"`
  (env or `.env`), else **claude-profile** (`claude-profile list`, its stable
  `name<TAB>dir[<TAB>active]` porcelain; found as command/function, else
  `python3 <path>/claude-profile.py` at `$CCFIND_PROFILE_PATH` / `~/claude-profile/`
  / `~/.zsh/claude-profile/` / `~/.config/claude-profile/`; `$CCFIND_PROFILE_CMD`
  overrides). A profile whose dir is absent here is skipped, so shared config
  degrades per machine. Neither → single nameless `~/.claude`. `-v` names the source.
  NB a profile is a config *dir*; claude-profile's *accounts* (subscriptions sharing
  one dir) are invisible here and not ccfind's concern — sessions are per-dir.
  Both work on remote hosts too, since the host runs its own ccfind and resolves its
  own seats. Unions the dirs, tags each hit with its label. `ccfind foo` = all profiles;
  `ccfind <label> foo` / `-p <label>` = one. Resume runs under that profile
  (`CLAUDE_CONFIG_DIR=<dir> claude --resume`). Unset → single `~/.claude` (unchanged).
- **Colour:** roles, not decoration — cyan = local profile label, magenta = remote
  host, bold yellow = the search term inside every snippet (list, picker and preview),
  green = the resume command, dim = timestamps/separators. Off whenever stdout is not
  a terminal, so piped output stays byte-plain; `CCFIND_COLOR=always|never`, `NO_COLOR`
  and `-C` override. The picker composes one pre-padded display field (TSV field 7,
  `--with-nth=7`) so columns align; fields 1-6 stay plain for the resume/preview/tabs.
- **Tab views (`CCFIND_TABS=1`, multi-host/multi-profile picker, fzf ≥ 0.45):** header
  bar `All │ <profile> │ <host>…`, Tab/Shift-Tab cycle; each tab shows its own newest
  hits. Silently off below fzf 0.45.

## Env vars

| Var | Default | Purpose |
|---|---|---|
| `CCFIND_PROFILES` | unset | `label:configdir` pairs → search multiple local profiles (env or `.env`) |
| `CCFIND_HOSTS` | unset | ssh aliases for `-r`/`ccfindr` (env or `.env`) |
| `CCFIND_REMOTE_RESUME` | unset | override remote resume: called `<cmd> <host> <cwd> <id>` (wrap in tmux/screen) |
| `CCFIND_TABS` | unset | `1` → per-host tab views (fzf ≥ 0.45) |
| `CCFIND_MAX` | 10 | max hits printed/pickable |
| `CCFIND_INTERACTIVE` | 1 | `0` → default to flat list |
| `CCFIND_COLOR` | auto | `always` / `never`; auto = colour only on a terminal |
| `CCFIND_REMOTE_PATH` | unset | where ccfind lives on remote hosts, if unconventional |

## Conventions

- Deps: zsh always; `fzf` for the picker; `python3` for the rich preview (both soft).
- `.env` is sourced inside function scope with the keys pre-`typeset`ed local, so it
  never leaks into the interactive shell.
- Portable across macOS (BSD `stat`) and Linux (GNU `stat`); no bashisms.
- Record schema (internal): `epoch \t host \t profile \t cfgdir \t id \t cwd \t ts \t
  snippet \t path`; the picker appends a 10th composed display field and shows only
  that (`--with-nth=9` on the row, epoch stripped). Colour lives in the display field
  ONLY — the data fields must stay parseable.
- Tests: `tests/run.sh` (bats; flat-list path, so no fzf/ssh/TTY needed). **Assert via
  `assert_contains`/`refute_contains`/`assert_equal`, never a bare `[[ … ]]`** — a
  false `[[ … ]]` mid-test does not fail a bats test (only a trailing one, or `[ … ]`). README
  images: `zsh tools/generate-readme-svg.zsh` — hermetic sandbox + stub `fzf`/`ssh`,
  runs the real tool with `CCFIND_COLOR=always`; commit the SVGs with the README.
