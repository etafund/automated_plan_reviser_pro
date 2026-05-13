# v18 Artifact Index, Atomic Writes, Locks, and Redaction

Bundle version: v18.0.0

The artifact index is the run-local map of durable planning artifacts. It is not
a cache hint. It is the audit surface that lets status, replay, synthesis, and
human handoff explain which artifacts exist, which lock protected each write,
which provider/source records they derive from, and which redaction boundary was
applied.

## Write Discipline

Every canonical JSON or Markdown artifact in a planning run is written under the
planning run directory while the run lock is held. Writers use a temp file in the
same filesystem, validate the candidate bytes, then rename it into place. The
artifact index is updated after the artifact write commits.

Required index metadata:

- `run_lock.path`, `run_lock.mode=exclusive_write_shared_read`, and
  `run_lock.status_reads_allowed=true`.
- `write_policy.atomic_write_required=true`,
  `write_policy.rename_required=true`, and
  `write_policy.status_reads_must_tolerate_partial_writes=true`.
- Per artifact `atomic_write.lock_id`, `atomic_write.temp_path`,
  `atomic_write.via_temp_rename=true`, `atomic_write.rename_result=committed`,
  and `atomic_write.index_update_id`.
- Per artifact `write_state=committed`, `canonical_json=true`,
  `redaction_level`, `redacted_field_count`, `sha256`, `path`, `kind`, and
  traceability ids such as `provider_result_ids` or `approval_ids` where
  applicable.

Status and report readers may read while a writer is active, but they only trust
committed index entries. Temp and partial paths are never indexed as artifacts.

## Redaction Boundary

The index records redaction metadata, not secret material. These fields are
forbidden in persisted artifact entries: `api_keys`, `browser_cookies`,
`oauth_tokens`, `raw_hidden_reasoning`, `reasoning_content`, `unredacted_dom`,
and `unredacted_screenshot`.

The top-level redaction boundary must also record:

- `secret_material_persisted=false`
- `private_browser_material_persisted=false`
- `raw_hidden_reasoning_persisted=false`

Provider adapters may use transient hidden reasoning or browser material only
long enough to complete the provider protocol. The durable artifacts keep
hashes, citations, redaction counts, confidence flags, and evidence ids instead.

## Validator

Run the bundle-local checker:

```bash
PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/artifact-index-check.sh --json
```

The checker emits the v18 JSON envelope and validates:

- required artifact kinds are indexed: provider requests, provider results,
  browser evidence, normalized plans, synthesis outputs, traceability, fallback
  waivers, approval ledgers, plan artifacts, and log bundles;
- artifact ids are unique;
- artifact paths are repo-relative and point to existing bundle fixtures;
- lock and atomic-write metadata are present and committed;
- temp or partial paths are not indexed;
- redaction boundary booleans are false for persisted secret/browser/reasoning
  material;
- artifact entries do not contain forbidden raw secret or raw reasoning field
  names.

Use `--verify-sha` only when the fixture hashes are expected to match current
file bytes exactly. The default contract check validates digest shape because
some fixtures intentionally use stable illustrative hashes.

The negative fixture
`fixtures/negative/artifact-index-secret-leak.invalid.json` must fail this
checker because it persists `raw_hidden_reasoning`, disables atomic writes, and
omits a usable lock id.
