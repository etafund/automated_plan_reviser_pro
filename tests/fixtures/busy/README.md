# Busy detection fixtures (bd-3pu)

Captured oracle stderr/log samples used by `tests/unit/test_busy.bats`
to exercise `lib/busy.sh`. Two categories:

| Prefix | Meaning |
|---|---|
| `busy_*` | MUST be detected as busy (positive). |
| `not_busy_*` | MUST NOT be detected as busy (negative — guards against false positives). |

When adding a new oracle busy signature to `lib/busy.sh`, also add at
least one `busy_*` fixture that triggers it. If the signature could
plausibly match unrelated text, add a `not_busy_*` fixture that almost
matches but should not (e.g. `busylight`, `busy_loop`).
