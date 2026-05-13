# Tests

> Bundle version: v18.0.0

Run `python3 scripts/validate-subset.py --json`. Add real repo tests according to `spec.md`.

Operator documentation examples are smoke-tested locally with:

```bash
python3 tests/test_docs_examples.py
```

The docs smoke writes JSONL records under `tests/logs/docs-examples/` with the command, expected exit code, actual exit code, and fixture project path. It executes only local mock commands and does not invoke live providers.
