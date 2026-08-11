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
- **Multi-profile (`CCFIND_PROFILES="label:configdir ..."`):** unions several local
  Claude config dirs, tags each hit with its label. `ccfind foo` = all profiles;
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

## Conventions

- Deps: zsh always; `fzf` for the picker; `python3` for the rich preview (both soft).
- `.env` is sourced inside function scope with the keys pre-`typeset`ed local, so it
  never leaks into the interactive shell.
- Portable across macOS (BSD `stat`) and Linux (GNU `stat`); no bashisms.
- Tests: `tests/run.sh` (bats; flat-list path, so no fzf/ssh/TTY needed). README
  images: `zsh tools/generate-readme-svg.zsh` — hermetic sandbox + stub `fzf`/`ssh`,
  runs the real tool with `CCFIND_COLOR=always`; commit the SVGs with the README.
