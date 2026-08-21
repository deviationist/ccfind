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

**Case matching** (`-s`/`-I`/`-S`, `CCFIND_CASE`) rests on one fixture: two
sessions differing *only* in the casing of the search term (`mk_case_pair`). Every
mode is then a statement about which of the two comes back, so a mode that
silently does nothing reads as the wrong count rather than as a passing test. Both
directions are asserted — a sensitive search must skip the other casing, and it
must skip it whichever casing was typed — and the remote half is covered on all
three paths a host can take: its own ccfind, a ccfind too old for `-s` (a stub
that rejects the flag and would otherwise answer with both casings), and the
worker's filesystem walk.

**Colour** is covered as a display layer: off when stdout is not a terminal (which
is what keeps every other assertion here working on plain bytes), on under
`CCFIND_COLOR=always`, off again under `-C` or `NO_COLOR`, with the search term
highlighted inside the snippet. The two helpers the picker leans on —
`_ccfind_hl` (literal, glob-safe highlighting) and `_ccfind_strip_sgr` — are
unit-tested directly.

**The picker's two halves** are both reachable without a terminal. `install_fzf_stub`
cancels (exit 130), which pins what fzf is *handed*; `install_fzf_stub_select` prints
a row and exits 0, which takes ccfind into the resume branch — so `Enter` is covered
end to end, locally and over ssh, against a stub `claude` and a stub `ssh` that
records the command rather than running it. What `Tab` computes is covered by calling
`_ccfind_tab_shift` / `_ccfind_tab_header` directly, since both are plain functions
over a state directory.

What is *not* covered, deliberately: fzf's own rendering and key dispatch — whether
it really redraws on the action string we hand back. That needs a pty harness
(tmux-driven, as fzf's own suite does), which would be slow and flaky in CI to test
someone else's tool. The seam is exactly where ccfind's responsibility ends.

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
| pinning the remote seat on a remote resume | Enter on a remote hit goes over ssh … |
| pinning the local seat on a picker resume | Enter on a profile hit resumes into … |
| the "cwd is gone" check before resuming | Enter refuses when the session's directory is gone |
| tab wrap-around | tab_shift wraps around in both directions |
| the epoch riding along on the display row | 4 of the time-column tests (the age goes blank without it) |
| truncating the age instead of rounding it | the age is a single truncated unit … |
| right-aligning the age column | the age column is right-aligned … |
| the `abs` arm of the time cell | `CCFIND_TIME=abs` is the timestamp alone … |
| the `rel` arm of the time cell | `CCFIND_TIME=rel` gives the age the whole column |
| `CCFIND_TIME`'s `.env` fallback | `CCFIND_TIME` can be set in the `.env` beside the script |
| the `abs\|rel\|both` validation | an unknown `CCFIND_TIME` says so instead of being ignored |
| the case flag on the local grep | case: `-s` matches the query's own casing only |
| resolving `smart` against the query | case: `-S` is smart — a capital in the query makes case matter |
| `CCFIND_CASE`'s `.env` fallback | case: `CCFIND_CASE` can be set in the `.env` beside the script |
| the case flag in the worker's own walk | case: the worker's own filesystem walk matches case too |
| passing `-s` to the host's ccfind | case: `-s` narrows on a host whose ccfind is too old for the flag |
| `CCFIND_CASE` in the remote ccfind's env | case: a host's own `CCFIND_CASE` does not override the caller's |
| pulling the snippet window with the same fold | case: the snippet window is pulled to the occurrence that matched |
| the highlighter's case argument | case: the highlight marks only what the search matched |
| `CCFIND_PV_CASE` reaching the preview | case: the preview highlights only the casing … (+1 more) |
| the resolved boolean in the envelope | case: `--json` reports the resolved boolean and the mode it came from |
| naming case in the empty-result line | case: an empty result names case-sensitivity as a reason it might be |

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
