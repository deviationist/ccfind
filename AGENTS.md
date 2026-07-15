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
  -N | -i      force flat-list / force picker (overrides CCFIND_INTERACTIVE)
  -r           also search CCFIND_HOSTS over ssh   (alias: ccfindr = ccfind -r)
  -H "<hosts>" search an explicit ssh-alias list (implies remote)
  -l           force local only (trumps -r / -H)
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
- **Tab views (`CCFIND_TABS=1`, multi-host picker, fzf ≥ 0.45):** header bar
  `All │ local │ <host>…`, Tab/Shift-Tab cycle; each host tab shows that host's own
  newest hits. Silently off below fzf 0.45.

## Env vars

| Var | Default | Purpose |
|---|---|---|
| `CCFIND_HOSTS` | unset | ssh aliases for `-r`/`ccfindr` (env or `.env`) |
| `CCFIND_TABS` | unset | `1` → per-host tab views (fzf ≥ 0.45) |
| `CCFIND_MAX` | 10 | max hits printed/pickable |
| `CCFIND_INTERACTIVE` | 1 | `0` → default to flat list |

## Conventions

- Deps: zsh always; `fzf` for the picker; `python3` for the rich preview (both soft).
- `.env` is sourced inside function scope with the keys pre-`typeset`ed local, so it
  never leaks into the interactive shell.
- Portable across macOS (BSD `stat`) and Linux (GNU `stat`); no bashisms.
