# APR UX QA Matrix

This is APR's UX regression baseline. It pins the **non-negotiable invariants** that any redesign of the CLI (layout selector, color, gum, robot mode, error taxonomy) must preserve.

Two halves:

1. **Manual checklist** — short bullets per command, used during code review and pre-release smoke checks.
2. **Executable harness** — `tests/integration/test_ux_qa_matrix.bats` mechanically enforces every row of the matrix that can be checked by a non-interactive subprocess. Rows that can only be eyeballed (gum spinners, color in a real TTY) are flagged below as **manual**.

> Bead: `automated_plan_reviser_pro-ulu.11` — UX QA Matrix + Visual Regression Checklist.

---

## 1. Global stream-discipline invariants

| # | Invariant | Mechanism | Auto-enforced |
|---|-----------|-----------|----------------|
| G1 | Human output (banners, progress, errors, info) goes to **stderr** | redirect inspection | ✓ |
| G2 | Structured output (JSON, render bundle, integration prompt) goes to **stdout** | redirect inspection + `jq` | ✓ |
| G3 | `NO_COLOR=1` suppresses every ANSI escape sequence in **both** streams | grep for `\x1b[` | ✓ |
| G4 | `APR_NO_GUM=1` disables `gum` even when installed (no ANSI cursor moves, no spinners on stderr) | grep for `\x1b[` + spinner glyphs | ✓ |
| G5 | `APR_NO_UNICODE=1` uses ASCII status glyphs (`[ok]`, `[error]`, …) | `apr_ui_symbol` tests | ✓ (see `tests/unit/test_layout.bats`) |
| G6 | Fatal errors emit `APR_ERROR_CODE=<stable_code>` on stderr | grep for tag | ✓ (see `tests/integration/test_error_contract.bats`) |
| G7 | Exit codes follow the documented taxonomy (0/1/2/3/4/10/11/12) | table-driven exit assertions | ✓ (same file) |

## 2. Layout-mode invariants

| # | Invariant | Mechanism | Auto-enforced |
|---|-----------|-----------|----------------|
| L1 | `--compact` flag selects compact layout regardless of terminal size | CLI run + side-effect grep | ✓ |
| L2 | `--desktop` flag selects desktop layout regardless of terminal size | CLI run | ✓ |
| L3 | `--layout MODE` (auto/desktop/compact/wide/mobile) is accepted, case-insensitively | CLI run | ✓ (see `tests/unit/test_layout.bats`) |
| L4 | `--layout <invalid>` produces `APR_ERROR_CODE=usage_error` + exit 2 | CLI run | ✓ |
| L5 | Robot mode is byte-identical across `--compact` and `--desktop` (after scrubbing `.meta.ts` and `.meta.v`) | golden compare | ✓ |
| L6 | `--help` lists the same commands and same flags in both layouts | structural compare | ✓ |
| L7 | Non-TTY auto layout resolves to **compact** (deterministic for CI) | `apr_layout_mode` test | ✓ (see `tests/unit/test_layout.bats`) |

## 3. Per-command matrix

For each command we record:
- **stdout policy**: empty / json / render bundle / integration prompt
- **stderr policy**: human-readable (banner, progress, status) / silent
- **exit class**: 0 / non-zero (taxonomy)
- **layout sensitivity**: whether output varies between desktop/compact

| Command | stdout | stderr | exit | Layout-sensitive |
|---------|--------|--------|------|------------------|
| `apr --version` | `apr version <semver>` | empty | 0 | no |
| `apr --help` | empty | human help body | 0 | yes (decoration only) |
| `apr help` (no args, no `.apr/`) | empty | first-run welcome | 0 | yes |
| `apr list` (no `.apr/`) | empty | "no workflows" banner | 0 | yes |
| `apr list` (configured) | empty | workflow listing | 0 | yes |
| `apr <bogus-command>` | empty | error + `APR_ERROR_CODE=usage_error` | 2 | no |
| `apr run` (no round) | empty | error + tag | 2 | no |
| `apr run 1` (no Oracle) | empty | error + `APR_ERROR_CODE=dependency_missing` | 3 | no |
| `apr run 1 --dry-run` (valid) | empty | banner + "Would execute:" block | 0 | yes (decoration) |
| `apr run 1 --render` (valid) | rendered bundle (oracle stdout) | banner | 0 | yes |
| `apr robot help` | JSON envelope `{ok:true, code:"ok", data:{commands,...}, meta:{v,ts}}` | empty | 0 | no |
| `apr robot status` (no `.apr/`) | JSON envelope `{ok:true, code:"ok", data:{configured:false,…}}` | empty | 0 | no |
| `apr robot validate` (no round) | JSON envelope `{ok:false, code:"usage_error", …}` | `APR_ERROR_CODE=usage_error` | 2 | no |
| `apr robot validate 1` (no `.apr/`) | JSON envelope `{ok:false, code:"not_configured", …}` | `APR_ERROR_CODE=not_configured` | 4 | no |
| `apr robot run 1` (no Oracle) | JSON envelope `{ok:false, code:"dependency_missing", …}` | `APR_ERROR_CODE=dependency_missing` | 3 | no |
| `apr robot <bogus>` | JSON envelope `{ok:false, code:"usage_error", …}` | `APR_ERROR_CODE=usage_error` | 2 | no |
| `apr robot --bogus-flag` | JSON envelope `{ok:false, code:"usage_error", …}` | `APR_ERROR_CODE=usage_error` | 2 | no |

Layout-sensitive rows must still observe G1–G7 in **both** layouts. The harness verifies this by re-running every flagged row under `--compact` and `--desktop`.

## 4. Robot envelope contract

Every robot response (success **and** failure) MUST contain:

- `.ok` — boolean
- `.code` — stable string in the taxonomy (`ok`, `usage_error`, `not_configured`, `config_error`, `validation_failed`, `dependency_missing`, `network_error`, `update_error`, `busy`, `internal_error`, `not_implemented`, `attachment_mismatch`)
- `.data` — object, command-specific shape
- `.meta.v` — APR semver
- `.meta.ts` — RFC3339 UTC timestamp

Failure envelopes additionally include `.hint` (string).

The harness enforces this on a representative set of success and failure invocations.

## 5. Environment-flag matrix

| Env | Tested behavior | Auto-enforced |
|-----|-----------------|----------------|
| `NO_COLOR=1` | No ANSI escapes in any stream of any command | ✓ |
| `APR_NO_GUM=1` | No gum-only decorations; ANSI fallback still respects `NO_COLOR` | ✓ |
| `APR_NO_UNICODE=1` | ASCII-only status glyphs | ✓ (test_layout.bats) |
| `APR_LAYOUT=desktop\|compact\|auto\|wide\|mobile` | Layout selector overrides | ✓ (test_layout.bats) |
| `APR_TERM_COLUMNS`, `APR_TERM_LINES` | Width/height resolution honored | ✓ (test_layout.bats) |
| `CI=true` | Non-interactive paths chosen (no prompts, no spinners) | partial / manual |
| `APR_CHECK_UPDATES=1` | Daily update check; throttle file `~/.local/share/apr/.last_update_check` written | ✓ (test_update.bats) |

## 6. Manual-only rows

These can only be eyeballed in a real TTY and are out of scope for the harness, but should be checked before each release:

- M1. With `gum` installed and `APR_NO_GUM` unset: banners render with gum styles (no raw ANSI codes visible).
- M2. With `gum` installed: `apr setup` spinner / select widgets render correctly at 80 cols and at 140 cols.
- M3. Dashboard TUI (`apr dashboard`) is navigable with arrow keys, redraws cleanly on terminal resize, and exits cleanly on `q`.
- M4. `apr run 1 --wait` shows progress updates at the documented cadence.
- M5. Color palette is legible on both dark and light backgrounds (no `\x1b[38;5;240m` style faint text against light background).

## 7. Running the matrix

```bash
# Mechanically-checkable rows:
bash tests/run_tests.sh -f "ux:" integration

# Or via bats directly:
tests/lib/bats-core/bin/bats tests/integration/test_ux_qa_matrix.bats
```

Per-test artifacts (stdout/stderr/env/cmdline) land under `tests/logs/integration/<ts>__<test>/` and are uploaded by CI on failure.
