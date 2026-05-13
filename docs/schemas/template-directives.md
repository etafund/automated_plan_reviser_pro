# APR Safe Template Directives (`apr_template.v1`)

This document is the **design spec** for APR's safe template directive system.
The matching engine implementation is bd-1mf; tests are bd-ptx; opt-in toggle
wiring is bd-3uq. This bead (bd-2nq) is design-only.

## Why directives exist

APR workflows are pasted to ChatGPT verbatim. There is one catastrophic
failure mode: a workflow author writes `{{README}}` expecting APR to inline
the README, APR does not substitute it, and ChatGPT sees the literal text
`{{README}}` instead of 70 KB of context. The model then generates a
plausible-looking but wrong review.

APR has historically defended against this by refusing to run any prompt
containing `{{` or `}}` (see `prompt_quality_check` in `apr`). That defense
is correct but blunt: it forbids substitution entirely.

Some authors legitimately want substitution-style features:

- inline a file's contents
- inline a file's sha256 (for the model to ACK)
- inline a file's byte size
- inline a bounded excerpt of a file (for very large files)

The only safe way to grant those is a **small, allowlisted, opt-in** directive
language with strict grammar and post-expansion verification.

## Design goals (and explicit non-goals)

**Goals**

1. **Safe by construction.** Unknown directives, missing files, and traversal
   attempts are fatal errors before any text is sent to a model.
2. **Visually distinctive.** `[[APR:...]]` is improbable in human prose and
   trivially `grep`-able when auditing prompts.
3. **Parseable with pure Bash.** No external runtime. Single-pass parser.
4. **Deterministic.** Same inputs → byte-identical output.
5. **Off by default.** A workflow must explicitly opt in. Existing workflows
   keep behaving exactly as before.
6. **Catches its own residue.** Any `[[APR:` remnant after expansion is
   itself a fatal error. Combined with the existing `{{`/`}}` guard, this
   covers both syntaxes.

**Non-goals**

- No expression evaluation, math, conditionals, or loops.
- No environment variable expansion.
- No nested directive expansion (directive output is not re-scanned).
- No shell, no `eval`, no path-of-our-choice imports.
- No HTTP, no network, no subprocess outside the small handler set.

## Enablement

A workflow opts in by declaring:

```yaml
# .apr/workflows/example.yaml
template_directives:
  enabled: true
  # Optional knobs — defaults shown.
  allow_traversal: false      # if true, paths with `..` are permitted
  allow_absolute: false       # if true, absolute paths are permitted
```

When `template_directives.enabled` is missing or `false`:

- Directives in the template MUST trigger a **fatal lint error** with the
  exact yaml knob to set, plus the directive text and its line number.
- Workflows authored before this feature exists are therefore unaffected.

When `template_directives.enabled` is `true`:

- The expansion engine runs after `load_prompt_template` and before
  `prompt_quality_check`.
- Post-expansion QC runs unchanged.

## Grammar (`apr_template.v1`)

```
directive   := "[[APR:" SP* type SP+ args SP* "]]"
type        := UPPER+                  ; one of allowlisted TYPE tokens
args        := arg (SP+ arg)*          ; positional, type-specific
arg         := nonspace+               ; no whitespace, no "]]", no nul
SP          := " " | "\t"
```

Notes:

- `[[APR:` and `]]` are the literal opening/closing tokens. No alternatives.
- TYPE is case-sensitive uppercase ASCII. `[[apr:file ...]]` does NOT match.
- Args are split on ASCII whitespace; there is no quoting. Paths with spaces
  are not supported by `v1` (workflows can rename files).
- A directive that spans a newline is a **fatal parse error** (helps catch
  malformed templates rather than silently consuming text).
- The substring `]]` may not appear inside arguments.

### Escape hatch

A literal `[[APR:...]]` can be included in prompt text by writing:

```
[[APR:LIT [[APR:FILE README.md]]]]
```

The `LIT` directive returns its raw argument string with no expansion. This
exists so prompts can document the directive syntax to the model without
the engine attempting to expand the example.

### Allowlisted TYPE tokens (initial set)

| TYPE | Args | Semantics |
|---|---|---|
| `FILE <path>` | one path | Replace with the exact bytes of `<path>`. No surrounding fences. |
| `SHA <path>` | one path | Replace with lowercase hex sha256 of file bytes (64 chars). |
| `SIZE <path>` | one path | Replace with the decimal byte count (`wc -c`). |
| `EXCERPT <path> <n>` | path + positive integer | Replace with the first `<n>` bytes of `<path>`. If file is shorter, return the whole file (no error, no padding). |
| `LIT <text...>` | free-form | Replace with the literal argument text. Used as an escape hatch. |

The set is intentionally tiny. New TYPEs require:

- a new bead,
- a new test fixture,
- a documented threat model (e.g., why this can't be abused to read secrets).

### `EXCERPT` byte semantics

`<n>` is **bytes**, not characters. Reasoning:

- Bash has no portable codepoint-aware truncation.
- Hashes/sizes elsewhere in APR are byte-counted; consistency wins.
- Truncating mid-codepoint is acceptable for the model; modern chat models
  handle a trailing partial UTF-8 sequence gracefully.

No truncation marker is appended. The bead would change here if real-world
usage shows the model needs an explicit `... [truncated]` hint.

## Path resolution

All `<path>` arguments are resolved relative to the **project root**, defined
as the directory containing the workflow's `.apr/` folder. This is the same
base used by `workflow.documents.*`.

Rejected by default (each rejection is fatal, never silent):

| Pattern | Reason |
|---|---|
| Absolute path (`/etc/passwd`, `/tmp/x`) | Prevents exfil of system files. Toggle via `allow_absolute: true`. |
| Any `..` segment | Prevents traversal above the project. Toggle via `allow_traversal: true`. |
| Contains `]]` | Would terminate the directive prematurely. |
| Contains a NUL byte | Hard reject; no toggle. |
| Empty / whitespace-only | Hard reject; no toggle. |
| Symlink that resolves outside the project | Hard reject when `allow_traversal=false`; the engine resolves symlinks before comparing to project root. |

Workflows that need to reference parent-repo files should copy them into the
project or set the explicit opt-in. `allow_traversal=true` MUST emit a warning
in lint output even when the run succeeds; operators should see it.

## Error model

Every directive failure raises a **fatal** error (engine returns nonzero).
The error envelope matches the core validator findings (bd-30c):

```
code:    template_engine_error
message: <one human-readable sentence>
hint:    <short remediation>
source:  <template-name>:<line>
details: { directive: "...", type: "FILE", arg: "...", reason: "..." }
```

Specific reasons and the canonical error code used in robot-mode JSON
(per bd-3tj):

| Situation | `outcome.code` | `details.reason` |
|---|---|---|
| Unknown TYPE | `template_engine_error` | `unknown_type` |
| Wrong arg count | `template_engine_error` | `bad_args` |
| Missing `]]` | `template_engine_error` | `unterminated_directive` |
| Directive spans newline | `template_engine_error` | `newline_in_directive` |
| Absolute path without opt-in | `template_engine_error` | `absolute_path_blocked` |
| Traversal without opt-in | `template_engine_error` | `traversal_blocked` |
| File missing | `template_engine_error` | `file_not_found` |
| File unreadable | `template_engine_error` | `file_unreadable` |
| `EXCERPT <n>` not a positive integer | `template_engine_error` | `bad_arg_excerpt_n` |
| Post-expansion residue | `prompt_qc_failed` | `directive_residue` |
| Post-expansion mustache residue | `prompt_qc_failed` | `mustache_residue` |

Note that residue codes are **not** `template_engine_error` — they're caught
by `prompt_quality_check`, after expansion, and reuse the existing
`prompt_qc_failed` code so robot consumers don't see a churning taxonomy.

## Interaction with prompt QC

Order of operations during prompt assembly:

1. `load_prompt_template` reads the raw template from the workflow yaml.
2. **If** `template_directives.enabled=true`: the engine scans for and
   replaces every `[[APR:...]]` occurrence. Each replacement is recorded
   for verbose-mode debug output (without leaking file contents).
3. `prompt_quality_check` runs on the expanded text:
   - rejects any remaining `{{` / `}}` (existing behavior).
   - rejects any remaining `[[APR:` substring (new behavior, gated on the
     same flag — disabled workflows skip this check too since their
     templates may legitimately discuss the syntax).
4. The expanded, QC-passed prompt is the input to oracle.

The engine does **not** rescan its own output. `[[APR:LIT [[APR:FILE x]]]]`
expands to `[[APR:FILE x]]` once and that's where it stops. Combined with
step 3, this makes accidental nesting visible as a fatal QC error.

## Determinism

Given identical inputs (template bytes, file bytes, knob values), the
engine MUST emit byte-identical output. Concretely:

- File reads use straight byte copies (no encoding conversion, no BOM
  stripping, no line-ending normalization).
- `EXCERPT` uses `head -c <n>` byte semantics.
- Hash output is fixed-format lowercase hex.
- Size output is decimal with no leading zeros and no thousands separators.

A `--dry-run` rendering MUST yield a prompt with the same `prompt_hash` (bd-246)
as a real run with the same inputs.

## Observability

In verbose mode, the engine emits one line to stderr per directive expanded:

```
[apr] template: expanded [[APR:SHA README.md]] → 9f86d081… (64-byte sha256)
[apr] template: expanded [[APR:FILE README.md]] → 72847 bytes
[apr] template: expanded [[APR:EXCERPT SPEC.md 2000]] → 2000 bytes (truncated)
```

No file contents are ever logged. Hashes are summarized with the first 8
chars + ellipsis to keep logs readable.

## Acceptance criteria for the implementation bead (bd-1mf)

A future implementer of bd-1mf can build to this spec without ambiguity if
they can answer "yes" to every item:

1. Parsing yields, for each match, a `(type, args[], template_line_no)`
   record.
2. Unknown TYPE produces a fatal error listing the **exact** allowed TYPEs.
3. The five listed TYPE handlers (`FILE`, `SHA`, `SIZE`, `EXCERPT`, `LIT`)
   are implemented with the byte semantics above.
4. Path safety checks fire **before** any file open: absolute, traversal,
   `]]`, NUL, empty.
5. Symlink resolution is done before the traversal check.
6. Post-expansion residue (`[[APR:` left over) is a fatal QC error with the
   line number of the offending residue in the **expanded** text.
7. Verbose-mode logging follows the format above and never leaks contents.
8. The `prompt_hash` from a `--dry-run` matches a real-run hash.

## Future extensions (deliberately out of scope for v1)

- Quoting/escaping inside args.
- Conditional directives (`[[APR:IF_FILE x]] ... [[APR:ENDIF]]`).
- Network-fetching directives.
- `JSON_PATH` / extract-by-pointer directives.
- Per-directive caching.

Each would require its own bead and threat model. v1 keeps the surface
small on purpose.
