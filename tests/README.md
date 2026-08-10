# ccfind tests

Behavioral [bats](https://github.com/bats-core/bats-core) suite for `ccfind`.

```sh
tests/run.sh          # or: bats tests/ccfind.bats
```

Requirements: `bats` and `zsh`.

## How it works

`ccfind.zsh` is **zsh-only** (glob qualifiers, `${(s)}`/`${(@f)}`/`${(q)}` flags,
associative arrays), so the tests don't source it under bash. Each test invokes
`ccfind` inside an isolated `zsh -f` subprocess (`run_ccfind` in `helpers.bash`).

Every test is hermetic:

- All state lives in `$BATS_TEST_TMPDIR` (bats creates + removes it per test).
- A fixture `HOME` is used, so the default profile is `$FIXHOME/.claude` — the
  real `~/.claude` is never read.
- `ccfind.zsh` is copied into the tmpdir before sourcing, so the auto-loaded
  `.env` (`${_CCFIND_SOURCE:h}/.env`) resolves to a dir with none — your real
  `.env` beside `ccfind.zsh` is never sourced. Config comes only from
  exported `CCFIND_*` vars each test sets.
- `CCFIND_INTERACTIVE=0` forces the flat-list path, so tests need no fzf/TTY.

Coverage is the local search + profile logic (union, positional/`-p` scoping,
profile-aware resume, `-d` scoping, caps, error paths). The fzf picker and the
preview pane are interactive paths left to manual verification; the remote
(`-r`/ssh) fan-out is covered against a stubbed `ssh`.

## The resume line as a contract

ccfind's real output is a *command*, and in practice it is handed to
claude-profile's `claude` wrapper, which honors a caller-set `CLAUDE_CONFIG_DIR`
verbatim. So the last group of tests does not just string-match the printed line
— it **executes** it against a stub `claude` (`install_claude_stub`) and asserts
where it actually landed: the right config dir per profile, no dir at all when
profiles are unconfigured, the assignment bound to `claude` rather than to the
preceding `cd`, and a cwd containing spaces still quoted into one argument.

Note `unset CLAUDE_CONFIG_DIR` in `ccfind_setup`: anything running this suite
from inside a Claude Code session has it exported, and an executed resume line
would inherit it and mask what ccfind actually emitted.

`mk_session <config-dir> <cwd> <id> <text>` writes a transcript fixture at
`<config-dir>/projects/<encoded-cwd>/<id>.jsonl`.
