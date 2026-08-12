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
profile-aware resume, `-d` scoping, caps, error paths). The remote (`-r`/ssh)
fan-out is covered against a stubbed `ssh`.

**Colour** is covered as a display layer: off when stdout is not a terminal (which
is what keeps every other assertion here working on plain bytes), on under
`CCFIND_COLOR=always`, off again under `-C` or `NO_COLOR`, with the search term
highlighted inside the snippet. The two helpers the picker leans on —
`_ccfind_hl` (literal, glob-safe highlighting) and `_ccfind_strip_sgr` — are
unit-tested directly.

**The picker** is reachable without a terminal because `-i` is the explicit
"give me the picker", overriding the TTY sniff as well as `CCFIND_INTERACTIVE=0`.
`install_fzf_stub` shadows `fzf` with a stub that records the rows and the argv
it is handed and exits 130 (cancelled), so the tests can assert the row contract:
seven tab-separated fields, colour only in field 7 (the composed display line
fzf shows via `--with-nth=7`), and fields 1/3/6 — the host, cwd and path the
resume and preview read back — left plain. The preview pane's rendering is still
left to manual verification (and to the README-SVG generator, which runs it for
real).

## Assertions: never a bare `[[ … ]]`

Use `assert_contains` / `refute_contains` / `assert_equal` from `helpers.bash`.

A false `[[ … ]]` in the **middle** of a bats test does not fail it. Only the last
command in the body is checked, and a plain `[ … ]` fails because it is an ordinary
command — but `[[ … ]]` mid-body is silently ignored. Verified against bats 1.13:

```bash
@test "false [[ ]] in the middle" { true; [[ x == y ]]; true; }   # → ok    (!)
@test "false [[ ]] at the end"    { true; [[ x == y ]]; }         # → not ok
@test "false [ ] in the middle"   { true; [ x = y ]; true; }      # → not ok
```

This was not theoretical here: two remote tests reported `ok` for months against
output whose fields had shifted, because their `[[ … ]]` assertions were decorative.
The helpers are functions, so a failure really does fail the test — and each prints
what it expected against what it got.

While writing a test, check it can actually fail. Break the thing it guards and
watch it go red; a test that passes either way reads like coverage and is worse than
none. The no-second-hop test in this suite is written the way it is for exactly that
reason — the obvious version of it passed even with the guard removed.

That check is cheap to run deliberately. Edit one guard in `ccfind.zsh`, run just
the test that covers it, and confirm it fails:

```sh
bats -f "follow the search onto a host" tests/ccfind.bats
```

Guards verified this way, each against the test named beside it:

| guard removed | test that catches it |
|---|---|
| the `unset CCFIND_*` before the remote ccfind call | the caller's `CCFIND_*` does not follow the search onto a host |
| exit-status check on the remote ccfind | a remote ccfind too old for `--tsv` falls back instead of erroring |
| `-d` forwarding to the remote | `-d` scopes the remote search too |
| `$HOME` contraction in the display column | the display column contracts `$HOME` … |
| pulling the snippet window to the match | the display column leads with the match … |
| the empty-document guard on no results | `--json` stays well-formed when nothing matched |
| profile tab views matching on `(local, label)` | tabs: one view per profile and host … (+2 more) |
| claude-profile discovery | 5 of the 6 discovery tests |

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
