#!/usr/bin/env bash
set -euo pipefail

VERSION="v18.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

baseline_path="${ROOT_DIR}/fixtures/source-baseline.json"
trust_path="${ROOT_DIR}/fixtures/source-trust.json"
json_output=0
emit_baseline=0

errors=()
warnings=()
logs=()
source_specs=()

usage() {
  printf 'usage: %s [--baseline PATH] [--trust PATH] [--emit-baseline --source ID:PATH:ROLE:CLASS] [--json]\n' "${0##*/}" >&2
}

add_error() {
  errors+=("$1")
}

add_warning() {
  warnings+=("$1")
}

add_log() {
  logs+=("$1")
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    add_error "missing required command: $1"
  fi
}

sha256_file() {
  local file_path="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file_path" | awk '{print $1}'
    return
  fi

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file_path" | awk '{print $1}'
    return
  fi

  add_error "missing sha256 tool for ${file_path}"
  return 1
}

file_size_bytes() {
  local file_path="$1"
  local bytes

  bytes="$(wc -c <"$file_path")"
  bytes="${bytes//[[:space:]]/}"
  printf '%s\n' "$bytes"
}

json_array_from_lines() {
  if (($# == 0)); then
    printf '[]'
    return
  fi

  printf '%s\n' "$@" | jq -R . | jq -s .
}

json_error_array() {
  if ((${#errors[@]} == 0)); then
    printf '[]'
    return
  fi

  printf '%s\n' "${errors[@]}" |
    jq -R '{error_code:"source_trust_validation_failed",message:.}' |
    jq -s .
}

json_warning_array() {
  if ((${#warnings[@]} == 0)); then
    printf '[]'
    return
  fi

  printf '%s\n' "${warnings[@]}" |
    jq -R '{warning_code:"source_trust_warning",message:.}' |
    jq -s .
}

validate_json_file() {
  local file_path="$1"
  local label="$2"

  if [[ ! -f "$file_path" ]]; then
    add_error "${label} file not found: ${file_path}"
    return
  fi

  if ! jq empty "$file_path" >/dev/null 2>&1; then
    add_error "${label} is not valid JSON: ${file_path}"
  fi
}

validate_relative_path() {
  local source_id="$1"
  local rel_path="$2"

  case "$rel_path" in
    "" | "null")
      add_error "local source ${source_id} is missing path"
      return 1
      ;;
    /* | *".."* )
      add_error "local source ${source_id} path must be repo-relative and must not contain '..': ${rel_path}"
      return 1
      ;;
  esac

  return 0
}

validate_sha_literals() {
  local file_path="$1"
  local label="$2"
  local bad_values

  mapfile -t bad_values < <(
    jq -r '.. | strings | select(startswith("sha256:") and (test("^sha256:[0-9a-f]{64}$") | not))' "$file_path"
  )

  local bad_value
  for bad_value in "${bad_values[@]}"; do
    add_error "${label} contains malformed sha256 literal: ${bad_value}"
  done
}

validate_baseline_sources() {
  local source_count
  source_count="$(jq '.sources | length' "$baseline_path")"

  if [[ "$source_count" == "0" ]]; then
    add_error "source baseline must include at least one source"
  fi

  mapfile -t missing_required < <(
    jq -r '.sources[] | select((.id // "") == "" or (.kind // "") == "" or (.sha256 // "") == "") | (.id // "<missing-id>")' "$baseline_path"
  )

  local source_id
  for source_id in "${missing_required[@]}"; do
    add_error "baseline source is missing id, kind, or sha256: ${source_id}"
  done

  while IFS=$'\t' read -r source_id rel_path expected_hash expected_bytes logical_role; do
    [[ -n "$source_id" ]] || continue

    validate_relative_path "$source_id" "$rel_path" || continue

    local absolute_path="${ROOT_DIR}/${rel_path}"
    if [[ ! -f "$absolute_path" ]]; then
      add_error "local source ${source_id} path does not exist: ${rel_path}"
      continue
    fi

    local actual_hash
    actual_hash="sha256:$(sha256_file "$absolute_path")"
    if [[ "$actual_hash" != "$expected_hash" ]]; then
      add_error "local source ${source_id} sha256 mismatch: expected ${expected_hash}, got ${actual_hash}"
    fi

    if [[ "$expected_bytes" != "null" ]]; then
      local actual_bytes
      actual_bytes="$(file_size_bytes "$absolute_path")"
      if [[ "$actual_bytes" != "$expected_bytes" ]]; then
        add_error "local source ${source_id} byte_count mismatch: expected ${expected_bytes}, got ${actual_bytes}"
      fi
    else
      add_warning "local source ${source_id} has no byte_count"
    fi

    add_log "source_id=${source_id} path=${rel_path} logical_role=${logical_role} hash=${expected_hash}"
  done < <(
    jq -r '.sources[] | select(.kind == "local_file") | [.id, .path, .sha256, (.byte_count // null), (.logical_role // "unspecified")] | @tsv' "$baseline_path"
  )
}

emit_baseline_artifact() {
  local entries=()

  if ((${#source_specs[@]} == 0)); then
    add_error "--emit-baseline requires at least one --source ID:PATH:ROLE:CLASS"
  fi

  local spec
  for spec in "${source_specs[@]}"; do
    local source_id rel_path logical_role source_class extra
    IFS=':' read -r source_id rel_path logical_role source_class extra <<<"$spec"

    if [[ -n "${extra:-}" || -z "${source_id:-}" || -z "${rel_path:-}" || -z "${logical_role:-}" || -z "${source_class:-}" ]]; then
      add_error "invalid --source spec, expected ID:PATH:ROLE:CLASS: ${spec}"
      continue
    fi

    validate_relative_path "$source_id" "$rel_path" || continue

    local absolute_path="${ROOT_DIR}/${rel_path}"
    if [[ ! -f "$absolute_path" ]]; then
      add_error "local source ${source_id} path does not exist: ${rel_path}"
      continue
    fi

    local actual_hash actual_bytes entry_json
    actual_hash="sha256:$(sha256_file "$absolute_path")"
    actual_bytes="$(file_size_bytes "$absolute_path")"
    entry_json="$(
      jq -n \
        --arg id "$source_id" \
        --arg kind "local_file" \
        --arg path "$rel_path" \
        --arg logical_role "$logical_role" \
        --arg source_class "$source_class" \
        --arg sha256 "$actual_hash" \
        --argjson byte_count "$actual_bytes" \
        '{
          id: $id,
          kind: $kind,
          path: $path,
          logical_role: $logical_role,
          source_class: $source_class,
          sha256: $sha256,
          byte_count: $byte_count
        }'
    )"
    entries+=("$entry_json")
    add_log "source_id=${source_id} path=${rel_path} logical_role=${logical_role} hash=${actual_hash}"
  done

  local sources_json errors_json warnings_json logs_json ok=false
  if ((${#entries[@]} == 0)); then
    sources_json="[]"
  else
    sources_json="$(printf '%s\n' "${entries[@]}" | jq -s '.')"
  fi

  if ((${#errors[@]} == 0)); then
    ok=true
  fi

  errors_json="$(json_error_array)"
  warnings_json="$(json_warning_array)"
  logs_json="$(json_array_from_lines "${logs[@]}")"

  jq -n \
    --argjson ok "$ok" \
    --arg schema_version "json_envelope.v1" \
    --arg bundle_version "$VERSION" \
    --argjson sources "$sources_json" \
    --argjson source_count "${#entries[@]}" \
    --argjson errors "$errors_json" \
    --argjson warnings "$warnings_json" \
    --argjson logs "$logs_json" \
    '{
      ok: $ok,
      schema_version: $schema_version,
      data: {
        baseline_artifact: {
          schema_version: "source_baseline.v1",
          bundle_version: $bundle_version,
          artifact_name: "source-lock.json",
          policy: "baseline",
          mode: "baseline",
          sources: $sources
        },
        source_count: $source_count,
        logs: $logs
      },
      meta: {
        tool: "source-trust-check",
        mode: "emit-baseline",
        bundle_version: $bundle_version
      },
      warnings: $warnings,
      errors: $errors,
      commands: {
        next: "bash scripts/source-trust-check.sh --emit-baseline --source brief:fixtures/brief.md:authoritative_planning_brief:authoritative_user_input --json"
      },
      blocked_reason: (if $ok then null else "source_baseline_emit_failed" end),
      fix_command: (if $ok then null else "fix --source specs or source paths" end),
      retry_safe: true
    }'
}

validate_source_alignment() {
  mapfile -t missing_ids < <(
    jq -r --slurpfile baseline "$baseline_path" '
      ($baseline[0].sources | map(.id)) as $ids
      | .sources[]
      | select((.id as $id | $ids | index($id)) | not)
      | .id
    ' "$trust_path"
  )

  local source_id
  for source_id in "${missing_ids[@]}"; do
    add_error "source trust references source not present in baseline: ${source_id}"
  done
}

validate_provider_quarantine() {
  mapfile -t bad_provider_sources < <(
    jq -r '
      (.quarantined_instructions | map(.source_id)) as $quarantined
      | .sources[]
      | select(.source_class == "provider_result_untrusted_text")
      | select(
          (.trust_tier != "untrusted_provider_text")
          or (.instruction_policy != "quarantine_provider_instructions")
          or (.may_contain_instructions != true)
          or ((.id as $id | $quarantined | index($id)) | not)
        )
      | .id
    ' "$trust_path"
  )

  local source_id
  for source_id in "${bad_provider_sources[@]}"; do
    add_error "provider source must be untrusted data-only text with quarantine coverage: ${source_id}"
  done

  mapfile -t unquarantined_injection < <(
    jq -r '
      (.quarantined_instructions | map(.source_id)) as $quarantined
      | .sources[]
      | select((.text_excerpt // "") | test("(?i)(ignore (all )?(previous|prior) instructions|system prompt|developer message|api key|browser cookie|raw chain[- ]of[- ]thought|replace the route policy)"))
      | select((.id as $id | $quarantined | index($id)) | not)
      | .id
    ' "$trust_path"
  )

  for source_id in "${unquarantined_injection[@]}"; do
    add_error "prompt-injection-like text must be quarantined before prompt compilation: ${source_id}"
  done

  local quarantine_count
  quarantine_count="$(jq '.quarantined_instructions | length' "$trust_path")"
  add_log "quarantine_count=${quarantine_count}"
}

emit_json() {
  local ok=false
  if ((${#errors[@]} == 0)); then
    ok=true
  fi

  local errors_json warnings_json logs_json
  errors_json="$(json_error_array)"
  warnings_json="$(json_warning_array)"
  logs_json="$(json_array_from_lines "${logs[@]}")"

  jq -n \
    --argjson ok "$ok" \
    --arg schema_version "json_envelope.v1" \
    --arg bundle_version "$VERSION" \
    --arg baseline "$baseline_path" \
    --arg trust "$trust_path" \
    --argjson source_count "$(jq '.sources | length' "$baseline_path" 2>/dev/null || printf 0)" \
    --argjson trust_source_count "$(jq '.sources | length' "$trust_path" 2>/dev/null || printf 0)" \
    --argjson quarantine_count "$(jq '.quarantined_instructions | length' "$trust_path" 2>/dev/null || printf 0)" \
    --argjson errors "$errors_json" \
    --argjson warnings "$warnings_json" \
    --argjson logs "$logs_json" \
    '{
      ok: $ok,
      schema_version: $schema_version,
      data: {
        baseline: $baseline,
        trust: $trust,
        source_count: $source_count,
        trust_source_count: $trust_source_count,
        quarantine_count: $quarantine_count,
        logs: $logs
      },
      meta: {
        tool: "source-trust-check",
        bundle_version: $bundle_version
      },
      warnings: $warnings,
      errors: $errors,
      commands: {
        next: "bash scripts/source-trust-check.sh --json"
      },
      blocked_reason: (if $ok then null else "source_trust_validation_failed" end),
      fix_command: (if $ok then null else "fix source baseline/trust classification or quarantine metadata" end),
      retry_safe: true
    }'
}

while (($# > 0)); do
  case "$1" in
    --baseline)
      if (($# < 2)); then
        usage
        exit 2
      fi
      baseline_path="$2"
      shift 2
      ;;
    --trust)
      if (($# < 2)); then
        usage
        exit 2
      fi
      trust_path="$2"
      shift 2
      ;;
    --json)
      json_output=1
      shift
      ;;
    --emit-baseline)
      emit_baseline=1
      shift
      ;;
    --source)
      if (($# < 2)); then
        usage
        exit 2
      fi
      source_specs+=("$2")
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

case "$baseline_path" in
  /*) ;;
  *) baseline_path="${ROOT_DIR}/${baseline_path}" ;;
esac

case "$trust_path" in
  /*) ;;
  *) trust_path="${ROOT_DIR}/${trust_path}" ;;
esac

need_cmd jq
need_cmd awk

if ((emit_baseline)); then
  emit_baseline_artifact
  if ((${#errors[@]} == 0)); then
    exit 0
  fi
  exit 1
fi

if ((${#errors[@]} == 0)); then
  validate_json_file "$baseline_path" "source baseline"
  validate_json_file "$trust_path" "source trust"
fi

if ((${#errors[@]} == 0)); then
  validate_sha_literals "$baseline_path" "source baseline"
  validate_sha_literals "$trust_path" "source trust"
  validate_baseline_sources
  validate_source_alignment
  validate_provider_quarantine
fi

if ((json_output)); then
  emit_json
else
  if ((${#errors[@]} == 0)); then
    printf 'ok\n'
  else
    printf '%s\n' "${errors[@]}"
  fi
fi

if ((${#errors[@]} == 0)); then
  exit 0
fi

exit 1
