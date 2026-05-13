# Provider Documentation Freshness Policy

> Bundle version: v18.0.0

Provider model names, browser UI labels, and reasoning-effort controls can change. The v18 bundles include `fixtures/provider-docs-snapshot.json` as a dated planning snapshot, not a permanent source of truth.

## Required implementation behavior

- Re-check provider capabilities at runtime before paid/live calls.
- Treat static model names and UI labels as aliases that must be resolved or verified.
- For browser providers, trust same-session Oracle evidence over static docs.
- For CLI/API providers, capture capability probes and exact request settings in provider results.
- Before an audit run, regenerate the provider docs snapshot and rerun validators.

The bundle-level capability inventory check is:

```bash
PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/provider-capability-check.sh --json
```

The checker reads `fixtures/provider-access-policy.json`, `fixtures/provider-docs-snapshot.json`, and all `fixtures/provider-capability.*.json` files. It emits a v18 JSON envelope with:

- docs snapshot freshness and refresh policy;
- discovered static capability fixtures;
- route inventory from the access policy;
- capability gaps that must be satisfied by runtime probes or browser evidence;
- `provider_docs_snapshot_stale` errors when the snapshot is expired.

Route readiness and future `apr capabilities` / `apr doctor` commands should use this output to distinguish policy blocks, missing capability probes, browser evidence requirements, stale provider docs, and temporarily unavailable provider surfaces.

## Why this helps

This prevents stale plan-bundle assumptions from becoming silent runtime downgrades. It also gives isolated coding agents a concrete document to update when provider docs change.
