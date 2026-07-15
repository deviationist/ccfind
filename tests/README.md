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
  `.env` (`${_CCFIND_SOURCE:h}/.env`) resolves to a dir with none — the operator's
  real `~/code-private/ccfind/.env` is never sourced. Config comes only from
  exported `CCFIND_*` vars each test sets.
- `CCFIND_INTERACTIVE=0` forces the flat-list path, so tests need no fzf/TTY.

Coverage is the local search + profile logic (union, positional/`-p` scoping,
profile-aware resume, `-d` scoping, caps, error paths). The fzf picker, remote
(`-r`/ssh) fan-out, and preview pane are interactive/network paths left to manual
verification.

`mk_session <config-dir> <cwd> <id> <text>` writes a transcript fixture at
`<config-dir>/projects/<encoded-cwd>/<id>.jsonl`.
