#!/usr/bin/env bash
set -euo pipefail

VERSION="v18.0.0"
schema_version="json_envelope.v1"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bundle_root="$(cd "$script_dir/.." && pwd)"
index_file="$bundle_root/fixtures/artifact-index.json"
output_json=0
verify_sha=0

usage() {
  cat >&2 <<'EOF'
Usage: artifact-index-check.sh [options]

Validate v18 artifact index discipline: atomic write metadata, run lock
metadata, redaction boundaries, relative artifact paths, and index entries.

Options:
  --index <path>   Artifact index JSON to validate.
  --root <path>    Bundle root used to resolve artifact paths.
  --verify-sha     Verify indexed sha256 digests against referenced files.
  --json           Emit v18 JSON envelope.
  --help           Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --index)
      [[ $# -ge 2 ]] || { echo "missing value for --index" >&2; exit 2; }
      index_file="$2"
      shift 2
      ;;
    --root)
      [[ $# -ge 2 ]] || { echo "missing value for --root" >&2; exit 2; }
      bundle_root="$2"
      shift 2
      ;;
    --verify-sha)
      verify_sha=1
      shift
      ;;
    --json)
      output_json=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

errors=()
warnings=()
required_kinds=(
  "approval_ledger"
  "browser_evidence"
  "fallback_waiver"
  "log_bundle"
  "normalized_plan"
  "plan_artifact"
  "provider_request"
  "provider_result"
  "synthesis_output"
  "traceability"
)
allowed_redaction_levels=("none" "redacted" "metadata_only" "secret_free")

add_error() {
  errors+=("$1")
}

has_value() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

messages_json() {
  local code="$1"
  shift || true
  if [[ $# -eq 0 ]]; then
    printf '[]'
    return
  fi
  printf '%s\n' "$@" | jq -R -s --arg code "$code" 'split("\n")[:-1] | map({error_code: $code, message: .})'
}

json_string_array() {
  if [[ $# -eq 0 ]]; then
    printf '[]'
    return
  fi
  printf '%s\n' "$@" | jq -R -s 'split("\n")[:-1]'
}

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 2
fi

if [[ ! -f "$index_file" ]]; then
  add_error "artifact index not found: $index_file"
elif ! jq empty "$index_file" >/dev/null 2>&1; then
  add_error "artifact index is not valid JSON: $index_file"
fi

artifact_count=0
forbidden_field_count=0
secret_value_count=0
index_update_id=""
run_lock_path=""
atomic_write_required=false

if [[ ${#errors[@]} -eq 0 ]]; then
  artifact_count="$(jq '.artifacts | length' "$index_file")"
  index_update_id="$(jq -r '.artifacts[0].atomic_write.index_update_id // ""' "$index_file")"
  run_lock_path="$(jq -r '.run_lock.path // ""' "$index_file")"
  atomic_write_required="$(jq -r '.write_policy.atomic_write_required // false' "$index_file")"

  [[ "$(jq -r '.schema_version // ""' "$index_file")" == "artifact_index.v1" ]] || add_error "schema_version must be artifact_index.v1"
  [[ "$(jq -r '.run_id // ""' "$index_file")" != "" ]] || add_error "run_id is required"
  [[ "$artifact_count" -gt 0 ]] || add_error "artifacts must contain at least one entry"

  [[ "$run_lock_path" != "" ]] || add_error "run_lock.path is required"
  [[ "$(jq -r '.run_lock.mode // ""' "$index_file")" == "exclusive_write_shared_read" ]] || add_error "run_lock.mode must be exclusive_write_shared_read"
  [[ "$(jq -r '.run_lock.status_reads_allowed // false' "$index_file")" == "true" ]] || add_error "run_lock.status_reads_allowed must be true"
  if ! jq -e '(.run_lock.stale_after_seconds // 0) >= 60' "$index_file" >/dev/null; then
    add_error "run_lock.stale_after_seconds must be at least 60"
  fi

  [[ "$atomic_write_required" == "true" ]] || add_error "write_policy.atomic_write_required must be true"
  [[ "$(jq -r '.write_policy.rename_required // false' "$index_file")" == "true" ]] || add_error "write_policy.rename_required must be true"
  [[ "$(jq -r '.write_policy.status_reads_must_tolerate_partial_writes // false' "$index_file")" == "true" ]] || add_error "write_policy.status_reads_must_tolerate_partial_writes must be true"
  [[ "$(jq -r '.write_policy.temp_path_pattern // ""' "$index_file")" != "" ]] || add_error "write_policy.temp_path_pattern is required"

  for field in api_keys browser_cookies oauth_tokens raw_hidden_reasoning reasoning_content unredacted_dom unredacted_screenshot; do
    if ! jq -e --arg field "$field" '(.redaction_boundary.forbidden_persisted_fields // []) | index($field)' "$index_file" >/dev/null; then
      add_error "redaction_boundary.forbidden_persisted_fields must include $field"
    fi
  done
  for field in secret_material_persisted private_browser_material_persisted raw_hidden_reasoning_persisted; do
    if ! jq -e --arg field "$field" '.redaction_boundary | has($field) and .[$field] == false' "$index_file" >/dev/null; then
      add_error "redaction_boundary.$field must be false"
    fi
  done

  duplicate_ids="$(jq -r '.artifacts[]?.artifact_id // empty' "$index_file" | sort | uniq -d)"
  if [[ "$duplicate_ids" != "" ]]; then
    add_error "artifact_id values must be unique: $duplicate_ids"
  fi

  for kind in "${required_kinds[@]}"; do
    if ! jq -e --arg kind "$kind" 'any(.artifacts[]?; .kind == $kind)' "$index_file" >/dev/null; then
      add_error "artifact index missing required kind: $kind"
    fi
  done

  forbidden_field_count="$(jq '[.artifacts[]? | paths(scalars) as $p | select(($p | map(tostring) | join(".")) | test("(^|\\.)(api[_-]?keys?|token|cookie|raw_hidden_reasoning|reasoning_content|unredacted_dom|unredacted_screenshot|secret)(\\.|$)"; "i"))] | length' "$index_file")"
  if [[ "$forbidden_field_count" -gt 0 ]]; then
    add_error "artifact entries contain forbidden persisted secret/raw-reasoning field names"
  fi

  secret_value_count="$(jq '[.. | strings | select(test("(sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|xox[baprs]-|-----BEGIN [A-Z ]*PRIVATE KEY-----)"))] | length' "$index_file")"
  if [[ "$secret_value_count" -gt 0 ]]; then
    add_error "artifact index contains values matching secret material patterns"
  fi

  while IFS=$'\t' read -r artifact_id kind artifact_path sha redaction_level write_state canonical_json via_temp_rename rename_result lock_id entry_update_id temp_path redacted_field_count; do
    [[ "$artifact_id" != "" ]] || add_error "artifact entry missing artifact_id"
    [[ "$kind" != "" ]] || add_error "artifact $artifact_id missing kind"
    [[ "$artifact_path" != "" ]] || add_error "artifact $artifact_id missing path"
    [[ "$sha" =~ ^sha256:[0-9a-f]{64}$ ]] || add_error "artifact $artifact_id sha256 must be sha256:<64 lowercase hex>"
    has_value "$redaction_level" "${allowed_redaction_levels[@]}" || add_error "artifact $artifact_id redaction_level is invalid: $redaction_level"
    [[ "$write_state" == "committed" ]] || add_error "artifact $artifact_id write_state must be committed"
    [[ "$canonical_json" == "true" ]] || add_error "artifact $artifact_id canonical_json must be true for v18 canonical artifacts"
    [[ "$via_temp_rename" == "true" ]] || add_error "artifact $artifact_id atomic_write.via_temp_rename must be true"
    [[ "$rename_result" == "committed" ]] || add_error "artifact $artifact_id atomic_write.rename_result must be committed"
    [[ "$lock_id" != "" ]] || add_error "artifact $artifact_id atomic_write.lock_id is required"
    [[ "$entry_update_id" != "" ]] || add_error "artifact $artifact_id atomic_write.index_update_id is required"
    [[ "$temp_path" != "" ]] || add_error "artifact $artifact_id atomic_write.temp_path is required"
    [[ "$redacted_field_count" =~ ^[0-9]+$ ]] || add_error "artifact $artifact_id redacted_field_count must be a non-negative integer"

    if [[ "$artifact_path" = /* || "$artifact_path" == *".."* ]]; then
      add_error "artifact $artifact_id path must be repo-relative without .. segments"
    elif [[ ! -f "$bundle_root/$artifact_path" ]]; then
      add_error "artifact $artifact_id path does not exist under bundle root: $artifact_path"
    elif [[ "$verify_sha" -eq 1 ]]; then
      actual_sha="sha256:$(sha256_file "$bundle_root/$artifact_path")"
      [[ "$actual_sha" == "$sha" ]] || add_error "artifact $artifact_id sha256 mismatch: expected $sha got $actual_sha"
    fi

    if [[ "$artifact_path" == *".tmp"* || "$artifact_path" == *".partial"* ]]; then
      add_error "artifact $artifact_id path must not index temp or partial files"
    fi
  done < <(
    jq -r '
      .artifacts[]? |
      [
        (.artifact_id // ""),
        (.kind // ""),
        (.path // ""),
        (.sha256 // ""),
        (.redaction_level // ""),
        (.write_state // ""),
        ((.canonical_json // false) | tostring),
        ((.atomic_write.via_temp_rename // false) | tostring),
        (.atomic_write.rename_result // ""),
        (.atomic_write.lock_id // ""),
        (.atomic_write.index_update_id // ""),
        (.atomic_write.temp_path // ""),
        ((.redacted_field_count // "") | tostring)
      ] | @tsv
    ' "$index_file"
  )
fi

errors_json="$(messages_json "artifact_index_validation_failed" "${errors[@]}")"
warnings_json="$(messages_json "artifact_index_warning" "${warnings[@]}")"
required_kinds_json="$(json_string_array "${required_kinds[@]}")"
ok=false
if [[ ${#errors[@]} -eq 0 ]]; then
  ok=true
fi

envelope_json="$(jq -n \
  --argjson ok "$ok" \
  --arg schema_version "$schema_version" \
  --arg bundle_version "$VERSION" \
  --arg index_path "$index_file" \
  --arg checked_root "$bundle_root" \
  --argjson artifact_count "$artifact_count" \
  --arg index_update_id "$index_update_id" \
  --arg run_lock_path "$run_lock_path" \
  --argjson atomic_write_required "$atomic_write_required" \
  --argjson required_kinds "$required_kinds_json" \
  --argjson forbidden_field_count "$forbidden_field_count" \
  --argjson secret_value_count "$secret_value_count" \
  --argjson errors "$errors_json" \
  --argjson warnings "$warnings_json" \
  '{
    ok: $ok,
    schema_version: $schema_version,
    data: {
      artifact_count: $artifact_count,
      index_path: $index_path,
      checked_root: $checked_root,
      required_kinds: $required_kinds,
      index_update_id: $index_update_id,
      run_lock_path: $run_lock_path,
      atomic_write_required: $atomic_write_required,
      forbidden_field_count: $forbidden_field_count,
      secret_value_count: $secret_value_count
    },
    meta: {
      tool: "artifact-index-check",
      bundle_version: $bundle_version
    },
    warnings: $warnings,
    errors: $errors,
    commands: {
      next: "PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/artifact-index-check.sh --json",
      fix: (if $ok then null else "fix listed artifact index, lock, atomic-write, or redaction invariant violations" end)
    },
    blocked_reason: (if $ok then null else "artifact_index_validation_failed" end),
    next_command: (if $ok then null else "PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/artifact-index-check.sh --json" end),
    fix_command: (if $ok then null else "fix listed artifact index, lock, atomic-write, or redaction invariant violations" end),
    retry_safe: true
  }')"

if [[ "$output_json" -eq 1 ]]; then
  printf '%s\n' "$envelope_json"
else
  if [[ "$ok" == "true" ]]; then
    printf 'artifact index ok: %s artifacts, lock %s, update %s\n' "$artifact_count" "$run_lock_path" "$index_update_id"
  else
    jq -r '.errors[].message' <<<"$envelope_json" >&2
  fi
fi

if [[ "$ok" == "true" ]]; then
  exit 0
fi
exit 1
