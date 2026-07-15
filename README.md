# ccfind

**Fuzzy-find and resume past Claude Code sessions across every directory — with optional multi-host (fleet) and multi-profile search.**

`claude --resume` only lists sessions whose working directory matches the current
dir, so old conversations feel siloed by where you happened to be. In reality every
session is a `.jsonl` transcript under
`~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`. `ccfind` greps the whole tree
(or a chosen subtree), lists matches newest-first, and either drops you into an
`fzf` picker (the default) or prints the exact resume command for each hit.

## Install

```zsh
git clone <this-repo> ~/ccfind                     # or wherever you keep tools
echo 'source ~/ccfind/ccfind.zsh' >> ~/.zshrc
echo "alias ccfindr='ccfind -r'" >> ~/.zshrc       # optional: remote-search shorthand
exec zsh
```

- **Requires** zsh.
- **Soft dependency: `fzf`** — only the interactive picker uses it; the flat-list
  fallback needs just `grep` / `awk` / `ls`. `brew install fzf` (macOS) /
  `sudo apt install fzf` (Debian/Ubuntu) / <https://github.com/junegunn/fzf#installation>.
- **Preview pane** wants `python3` on PATH (preinstalled on macOS 12+ and Ubuntu
  22.04+); falls back to a raw `tail` of the transcript without it.

Optional per-machine config lives in a gitignored `.env` beside `ccfind.zsh` — copy
`.env.example` to `.env` and fill it in. See **Multi-host** below.

## Usage

```
ccfind <text...>                   # literal, case-insensitive search of all sessions
ccfind -d <dir> <text...>          # only sessions whose cwd is <dir> or below it
ccfind -d . <text...>              # scope to the current directory's subtree
ccfind -n <max> <text...>          # cap the number of hits shown (default 10)
ccfind -N <text...>                # force the flat-list output (opt out of the picker)
ccfind -i <text...>                # force the picker on (overrides CCFIND_INTERACTIVE=0)
ccfind [-d <dir>] [-n <max>]       # no query → just list the most recent sessions
ccfind -r <text...>                # also search the configured remote hosts (CCFIND_HOSTS)
ccfindr <text...>                  # alias for `ccfind -r` (define in ~/.zshrc)
ccfind -H "host-a host-b" <text...># search these ssh hosts (implies remote, overrides CCFIND_HOSTS)
ccfind -l <text...>                # force local only (trumps -r / -H)
ccfind <profile> <text...>         # scope local search to one CCFIND_PROFILES profile
ccfind -p <profile> <text...>      # same, explicit form
```

### Interactive picker (default)

When `fzf` is installed and both stdin and stdout are TTYs, `ccfind` shows an `fzf`
picker of the hits (timestamp · cwd · snippet, newest first).

| Key | Action |
|---|---|
| `↑` / `↓` | Move between hits |
| `Enter` | `cd` to the session's recorded cwd (when different from `$PWD`) and run `claude --resume <id>` in the current shell |
| `→` | Open the **preview pane** — last ~8 user + assistant messages of the highlighted session (text only; tool calls/results reduced to `[tool: <name>]` / `[tool result]`, thinking blocks omitted) |
| `←` | Hide the preview pane again |
| `Esc` | Cancel — no `cd`, no resume |

The `cd` persists because `ccfind` is a function, not a subshell.

### Flat-list fallback

Each hit prints the session's timestamp + working directory, a snippet centred on
the match, and the resume command (`cd <dir> && claude --resume <id>` when the
session lived elsewhere, so it reloads in its original project context — correct
`CLAUDE.md`, relative paths, git — else just `claude --resume <id>`). You get this
when `fzf` is absent, output is piped (no TTY), you pass `-N`/`--no-interactive`, or
`CCFIND_INTERACTIVE=0` is set.

```zsh
ccfind "connection refused"      # picker (if fzf+TTY) over the hits
ccfind -d ~/code/myproject       # everything done in that repo, newest first
ccfind -n 50 deploy              # show up to 50 hits (same as CCFIND_MAX=50)
ccfind -N deploy                 # flat-list output, copy/paste the resume command
ccfind deploy | less             # auto-flat-list (no TTY on stdout)
```

## Multi-profile search (opt-in)

If you run Claude Code under more than one config dir — e.g. separate work and
personal accounts (`CLAUDE_CONFIG_DIR`) — point `CCFIND_PROFILES` at them and
`ccfind` searches all of them at once, tagging each hit with its profile:

```zsh
# .env beside ccfind.zsh  (or export from ~/.zshrc)
typeset CCFIND_PROFILES="work:$HOME/.claude personal:$HOME/.claude-personal"
```

Format: space/comma-separated `label:configdir` pairs, where `<configdir>` is the
Claude config dir (the one containing a `projects/` subdir). Order sets the tab
order. Unset → a single `~/.claude` profile, exactly the previous behavior.

- **Union by default.** `ccfind foo` searches every configured profile; hits show a
  `work:` / `personal:` column (picker) or prefix (flat list).
- **Scope to one:** a leading label — `ccfind work foo` — or the explicit
  `-p work foo` restricts the local search to that profile. (Flags come before the
  label: `ccfind -N -n 20 work foo`.) The positional form only fires when the first
  word exactly matches a configured label, so ordinary searches are unaffected when
  multi-profile is off.
- **Correct resume.** Resuming a hit runs it under its own profile
  (`CLAUDE_CONFIG_DIR=<that dir> claude --resume <id>`), so a personal session
  reopens on the personal account regardless of where you launched `ccfind`.
- **Profiles + hosts compose.** With both `CCFIND_PROFILES` and `CCFIND_HOSTS` set,
  `ccfindr foo` searches every local profile *and* every remote host; tabs become
  `All │ work │ personal │ <host>…`.

## Multi-host search (opt-in per call)

Set `CCFIND_HOSTS` to a space/comma-separated list of ssh aliases — exported in the
environment, or as a `typeset` in the `.env` beside `ccfind.zsh` (see `.env.example`)
— then pass `-r`/`--remote` to fan the same search out to each host's
`~/.claude/projects` in parallel with the local one. Configuring the list alone
changes nothing: plain `ccfind` stays purely local, so you choose the scope on the
fly. The convenient way in is a `~/.zshrc` alias:

```zsh
# .env beside ccfind.zsh
typeset CCFIND_HOSTS="host-a host-b"

# ~/.zshrc
alias ccfindr='ccfind -r'    # ccfind incl. the remote hosts
```

- **The search runs remotely.** A small POSIX worker script is piped over
  `ssh <host> sh -s` (BatchMode, 6 s connect timeout) — nothing is installed on the
  hosts, and only per-hit metadata (id, cwd, mtime, snippet) comes back over the
  wire, never transcript bodies. Each host caps its hits at the same `-n` bound.
- **Merged display.** Remote hits interleave with local ones newest-first. The
  picker gains a host column (`local` / `<host>`); the flat list prefixes the cwd
  with `<host>:`.
- **Resuming a remote hit** runs
  `ssh -t <host> 'cd <cwd> && exec "$SHELL" -ic claude\ --resume\ <id>'` — the
  interactive shell is deliberate: non-interactive ssh PATH usually lacks `claude`,
  and the interactive rc also loads any `claude`-wrapper you have. The flat list
  prints that exact command, copy/paste-ready.
- **Remote preview** (`→` in the picker) fetches the highlighted transcript over ssh
  once into a per-invocation cache, then reuses it while you toggle the preview.
- **Per-call control:** `-r` opts in using the configured list; `-H "<hosts>"`
  searches an explicit list (implies remote, no `-r` needed); `-l`/`--local` forces
  local and trumps both. Host-list precedence: `-H` > exported `CCFIND_HOSTS` >
  `.env`. `-r` with no list configured warns on stderr and searches locally.
- **Failure is soft:** an unreachable host prints one
  `ccfind: remote search failed on: <host>` line to stderr and the rest still show.
- **`-d <dir>` scoping** applies to the remotes too, but the path is resolved
  *locally* and matched as-is on each host — useful when the path exists on the
  hosts, a no-op filter otherwise.

### Per-host tab views (`CCFIND_TABS=1`)

fzf has no native tab widget, so this emulates one: with `CCFIND_TABS=1` set (env or
`.env`, next to `CCFIND_HOSTS`), the multi-host/multi-profile picker grows a tab bar
in the header — e.g. `All │ work │ personal │ host-a` — and `Tab` / `Shift-Tab` cycle
the views (current tab inverse-video, `All` first, empty views omitted). Each tab shows
**that host's own newest hits, up to `-n <max>`** — so a host whose sessions are all
older than the global top-`max` still gets a full tab. Needs **fzf ≥ 0.45** (Jan
2024); older fzf silently gets the plain merged list. No effect on the flat list,
local-only runs, or when `CCFIND_TABS` is unset.

## Notes

- **Sort order:** newest first, by the transcript file's last-modified time
  (`ls -t`) — most recently active session first. Resuming a session appends to its
  file, so it pops back to the top.
- Search is a **literal substring** (not regex), case-insensitive.
- The encoded project-dir name is lossy (every `/` becomes `-`), so the displayed
  working directory is read from the `cwd` field *inside* each transcript (exact).
- `CCFIND_MAX` caps how many results are printed / pickable (default 10; `-n <max>`
  overrides per-call). `CCFIND_INTERACTIVE` (default `1`) controls picker-vs-flat-list.
- Works the same on macOS and Linux; the only platform-conditional bit is the `fzf`
  install path.

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `CCFIND_PROFILES` | *(unset)* | Space/comma-separated `label:configdir` pairs → search multiple local Claude profiles. Unset = just `~/.claude`. |
| `CCFIND_HOSTS` | *(unset)* | Space/comma-separated ssh aliases for `-r`/`ccfindr`. Env or `.env`. |
| `CCFIND_TABS` | *(unset)* | `1` → per-host tab views in the multi-host picker (fzf ≥ 0.45). |
| `CCFIND_MAX` | `10` | Max hits printed / pickable. `-n <max>` overrides per-call. |
| `CCFIND_INTERACTIVE` | `1` | `0` → default to the flat list instead of the fzf picker. |

## License

MIT — see [LICENSE](LICENSE).
