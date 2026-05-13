#!/usr/bin/env bash
set -euo pipefail

VERSION="v18.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

manifest_path="${ROOT_DIR}/fixtures/intake-capture-manifest.json"
baseline_path="${ROOT_DIR}/fixtures/source-baseline.json"
trust_path="${ROOT_DIR}/fixtures/source-trust.json"
codex_path="${ROOT_DIR}/fixtures/codex-intake.json"
interactive_path="${ROOT_DIR}/fixtures/interactive-intake.json"
json_output=0

errors=()
warnings=()
logs=()

usage() {
  printf 'usage: %s [--manifest PATH] [--baseline PATH] [--trust PATH] [--codex PATH] [--interactive PATH] [--json]\n' "${0##*/}" >&2
}

add_error() {
  errors+=("$1")
}

add_log() {
  logs+=("$1")
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    add_error "missing required command: $1"
  fi
}

resolve_path() {
  local input="$1"
  case "$input" in
    /*) printf '%s\n' "$input" ;;
    *) printf '%s/%s\n' "$ROOT_DIR" "$input" ;;
  esac
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    add_error "missing sha256sum or shasum"
    return 1
  fi
}

file_size_bytes() {
  local path="$1"
  local bytes
  bytes="$(wc -c <"$path")"
  printf '%s\n' "${bytes//[[:space:]]/}"
}

json_array_from_lines() {
  if (($# == 0)); then
    printf '[]'
    return
  fi
  printf '%s\n' "$@" | jq -R . | jq -s .
}

json_errors() {
  if ((${#errors[@]} == 0)); then
    printf '[]'
    return
  fi
  printf '%s\n' "${errors[@]}" |
    jq -R '{error_code:"intake_capture_validation_failed",message:.}' |
    jq -s .
}

json_warnings() {
  if ((${#warnings[@]} == 0)); then
    printf '[]'
    return
  fi
  printf '%s\n' "${warnings[@]}" |
    jq -R '{warning_code:"intake_capture_warning",message:.}' |
    jq -s .
}

validate_json_file() {
  local path="$1"
  local label="$2"
  if [[ ! -f "$path" ]]; then
    add_error "${label} file not found: ${path}"
    return
  fi
  if ! jq empty "$path" >/dev/null 2>&1; then
    add_error "${label} is not valid JSON: ${path}"
  fi
}

validate_sha_literals() {
  local path="$1"
  local label="$2"
  local bad_value
  while IFS= read -r bad_value; do
    [[ -n "$bad_value" ]] || continue
    add_error "${label} contains malformed sha256 literal: ${bad_value}"
  done < <(
    jq -r '.. | strings | select(startswith("sha256:") and (test("^sha256:[0-9a-f]{64}$") | not))' "$path"
  )
}

validate_baseline_source() {
  local source_id="$1"
  local expected_path="$2"
  local expected_class="$3"
  local actual_path actual_class expected_hash actual_hash expected_bytes actual_bytes

  actual_path="$(jq -r --arg id "$source_id" '.sources[]? | select(.id == $id) | .path // ""' "$baseline_path")"
  actual_class="$(jq -r --arg id "$source_id" '.sources[]? | select(.id == $id) | .source_class // ""' "$baseline_path")"
  expected_hash="$(jq -r --arg id "$source_id" '.sources[]? | select(.id == $id) | .sha256 // ""' "$baseline_path")"
  expected_bytes="$(jq -r --arg id "$source_id" '.sources[]? | select(.id == $id) | .byte_count // ""' "$baseline_path")"

  if [[ -z "$actual_path" ]]; then
    add_error "source baseline missing intake source: ${source_id}"
    return
  fi
  if [[ "$actual_path" != "$expected_path" ]]; then
    add_error "source baseline ${source_id} path expected ${expected_path}, got ${actual_path}"
  fi
  if [[ "$actual_class" != "$expected_class" ]]; then
    add_error "source baseline ${source_id} source_class expected ${expected_class}, got ${actual_class}"
  fi

  local file_path="${ROOT_DIR}/${expected_path}"
  if [[ ! -f "$file_path" ]]; then
    add_error "source baseline ${source_id} file path does not exist: ${expected_path}"
    return
  fi
  actual_hash="sha256:$(sha256_file "$file_path")"
  actual_bytes="$(file_size_bytes "$file_path")"
  if [[ "$expected_hash" != "$actual_hash" ]]; then
    add_error "source baseline ${source_id} sha256 mismatch: expected ${expected_hash}, got ${actual_hash}"
  fi
  if [[ "$expected_bytes" != "$actual_bytes" ]]; then
    add_error "source baseline ${source_id} byte_count mismatch: expected ${expected_bytes}, got ${actual_bytes}"
  fi

  add_log "source_id=${source_id} path=${expected_path} source_class=${expected_class} hash=${actual_hash}"
}

validate_trust_entry() {
  local source_id="$1"
  local expected_class="$2"
  local expected_tier="$3"
  local expected_policy="$4"
  local actual_class actual_tier actual_policy formal_allowed synthesis_allowed

  actual_class="$(jq -r --arg id "$source_id" '.sources[]? | select(.id == $id) | .source_class // ""' "$trust_path")"
  actual_tier="$(jq -r --arg id "$source_id" '.sources[]? | select(.id == $id) | .trust_tier // ""' "$trust_path")"
  actual_policy="$(jq -r --arg id "$source_id" '.sources[]? | select(.id == $id) | .instruction_policy // ""' "$trust_path")"
  formal_allowed="$(jq -r --arg id "$source_id" '.sources[]? | select(.id == $id) | .may_satisfy_formal_first_plan // false' "$trust_path")"
  synthesis_allowed="$(jq -r --arg id "$source_id" '.sources[]? | select(.id == $id) | .eligible_for_synthesis // false' "$trust_path")"

  if [[ -z "$actual_class" ]]; then
    add_error "source trust missing intake source: ${source_id}"
    return
  fi
  if [[ "$actual_class" != "$expected_class" ]]; then
    add_error "source trust ${source_id} source_class expected ${expected_class}, got ${actual_class}"
  fi
  if [[ "$actual_tier" != "$expected_tier" ]]; then
    add_error "source trust ${source_id} trust_tier expected ${expected_tier}, got ${actual_tier}"
  fi
  if [[ "$actual_policy" != "$expected_policy" ]]; then
    add_error "source trust ${source_id} instruction_policy expected ${expected_policy}, got ${actual_policy}"
  fi
  if [[ "$formal_allowed" != "false" ]]; then
    add_error "source trust ${source_id} may_satisfy_formal_first_plan must be false"
  fi
  if [[ "$synthesis_allowed" != "false" ]]; then
    add_error "source trust ${source_id} eligible_for_synthesis must be false"
  fi
}

validate_codex_intake() {
  local formal eligible access_path subscription_route effort model_effort plan_effort
  formal="$(jq -r 'if has("formal_first_plan") then .formal_first_plan else null end' "$codex_path")"
  eligible="$(jq -r 'if has("eligible_for_synthesis") then .eligible_for_synthesis else null end' "$codex_path")"
  access_path="$(jq -r '.access_path // ""' "$codex_path")"
  subscription_route="$(jq -r '.subscription_route // null' "$codex_path")"
  effort="$(jq -r '.reasoning_effort // ""' "$codex_path")"
  model_effort="$(jq -r '.model_reasoning_effort // ""' "$codex_path")"
  plan_effort="$(jq -r '.plan_mode_reasoning_effort // ""' "$codex_path")"

  if [[ "$(jq -r '.schema_version // ""' "$codex_path")" != "codex_intake.v1" ]]; then
    add_error "codex intake schema_version must be codex_intake.v1"
  fi
  if [[ "$access_path" != "codex_cli_subscription" ]]; then
    add_error "codex intake access_path must be codex_cli_subscription"
  fi
  if [[ "$subscription_route" != "true" ]]; then
    add_error "codex intake must be subscription_route=true"
  fi
  if [[ "$formal" != "false" ]]; then
    add_error "codex intake formal_first_plan must be false"
  fi
  if [[ "$eligible" != "false" ]]; then
    add_error "codex intake eligible_for_synthesis must be false"
  fi
  if [[ "$effort" != "xhigh" || "$model_effort" != "xhigh" || "$plan_effort" != "xhigh" ]]; then
    add_error "codex intake must record xhigh effort fields"
  fi
  add_log "codex_intake formal_first_plan=${formal} eligible_for_synthesis=${eligible} access_path=${access_path}"
}

validate_interactive_intake() {
  if [[ "$(jq -r '.schema_version // ""' "$interactive_path")" != "interactive_intake.v1" ]]; then
    add_error "interactive intake schema_version must be interactive_intake.v1"
  fi
  if [[ "$(jq -r 'if has("api_used") then .api_used else null end' "$interactive_path")" != "false" ]]; then
    add_error "interactive intake api_used must be false"
  fi
  if [[ "$(jq -r 'if has("oracle_used") then .oracle_used else null end' "$interactive_path")" != "false" ]]; then
    add_error "interactive intake oracle_used must be false"
  fi
  if [[ "$(jq -r 'if has("formal_first_plan") then .formal_first_plan else false end' "$interactive_path")" != "false" ]]; then
    add_error "interactive intake formal_first_plan must be false"
  fi
  if [[ "$(jq -r 'if has("eligible_for_synthesis") then .eligible_for_synthesis else false end' "$interactive_path")" != "false" ]]; then
    add_error "interactive intake eligible_for_synthesis must be false"
  fi
  add_log "interactive_intake api_used=false oracle_used=false"
}

validate_manifest() {
  local codex_route_impact manifest_formal manifest_synthesis interactive_runtime
  codex_route_impact="$(jq -r '.captures[]? | select(.capture_id == "codex-intake") | .route_impact // ""' "$manifest_path")"
  manifest_formal="$(jq -r 'if .policy | has("codex_intake_formal_first_plan") then .policy.codex_intake_formal_first_plan else null end' "$manifest_path")"
  manifest_synthesis="$(jq -r 'if .policy | has("codex_intake_eligible_for_synthesis") then .policy.codex_intake_eligible_for_synthesis else null end' "$manifest_path")"
  interactive_runtime="$(jq -r 'if .policy | has("interactive_intake_is_runtime_instruction") then .policy.interactive_intake_is_runtime_instruction else null end' "$manifest_path")"

  if [[ "$(jq -r '.schema_version // ""' "$manifest_path")" != "intake_capture_manifest.v1" ]]; then
    add_error "intake capture manifest schema_version must be intake_capture_manifest.v1"
  fi
  if [[ "$codex_route_impact" != "cannot_satisfy_formal_first_plan_or_synthesis" ]]; then
    add_error "intake capture manifest must mark Codex route impact as cannot_satisfy_formal_first_plan_or_synthesis"
  fi
  if [[ "$manifest_formal" != "false" || "$manifest_synthesis" != "false" ]]; then
    add_error "intake capture manifest policy must keep Codex formal/synthesis eligibility false"
  fi
  if [[ "$interactive_runtime" != "false" ]]; then
    add_error "intake capture manifest policy must keep interactive intake out of runtime instruction tier"
  fi
}

emit_json() {
  local ok=false
  if ((${#errors[@]} == 0)); then
    ok=true
  fi
  local errors_json warnings_json logs_json
  errors_json="$(json_errors)"
  warnings_json="$(json_warnings)"
  logs_json="$(json_array_from_lines "${logs[@]}")"

  jq -n \
    --argjson ok "$ok" \
    --arg bundle_version "$VERSION" \
    --arg manifest "$manifest_path" \
    --arg baseline "$baseline_path" \
    --arg trust "$trust_path" \
    --arg codex "$codex_path" \
    --arg interactive "$interactive_path" \
    --argjson errors "$errors_json" \
    --argjson warnings "$warnings_json" \
    --argjson logs "$logs_json" \
    '{
      ok: $ok,
      schema_version: "json_envelope.v1",
      data: {
        manifest: $manifest,
        baseline: $baseline,
        trust: $trust,
        codex_intake: $codex,
        interactive_intake: $interactive,
        logs: $logs
      },
      meta: {
        tool: "intake-capture-check",
        bundle_version: $bundle_version
      },
      warnings: $warnings,
      errors: $errors,
      commands: {
        next: "bash scripts/intake-capture-check.sh --json"
      },
      blocked_reason: (if $ok then null else "intake_capture_validation_failed" end),
      fix_command: (if $ok then null else "fix intake capture manifest/source trust/Codex eligibility metadata" end),
      retry_safe: true
    }'
}

while (($# > 0)); do
  case "$1" in
    --manifest)
      (($# >= 2)) || { usage; exit 2; }
      manifest_path="$(resolve_path "$2")"
      shift 2
      ;;
    --baseline)
      (($# >= 2)) || { usage; exit 2; }
      baseline_path="$(resolve_path "$2")"
      shift 2
      ;;
    --trust)
      (($# >= 2)) || { usage; exit 2; }
      trust_path="$(resolve_path "$2")"
      shift 2
      ;;
    --codex)
      (($# >= 2)) || { usage; exit 2; }
      codex_path="$(resolve_path "$2")"
      shift 2
      ;;
    --interactive)
      (($# >= 2)) || { usage; exit 2; }
      interactive_path="$(resolve_path "$2")"
      shift 2
      ;;
    --json)
      json_output=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

need_cmd jq
need_cmd awk

validate_json_file "$manifest_path" "intake capture manifest"
validate_json_file "$baseline_path" "source baseline"
validate_json_file "$trust_path" "source trust"
validate_json_file "$codex_path" "codex intake"
validate_json_file "$interactive_path" "interactive intake"

if ((${#errors[@]} == 0)); then
  validate_sha_literals "$manifest_path" "intake capture manifest"
  validate_sha_literals "$baseline_path" "source baseline"
  validate_sha_literals "$trust_path" "source trust"
  validate_sha_literals "$codex_path" "codex intake"
  validate_sha_literals "$interactive_path" "interactive intake"
  validate_baseline_source "interactive-intake" "fixtures/interactive-intake.json" "authoritative_user_input"
  validate_baseline_source "codex-intake" "fixtures/codex-intake.json" "derived_summary"
  validate_trust_entry "interactive-intake" "authoritative_user_input" "source_material_not_instruction" "source_material_not_runtime_instruction"
  validate_trust_entry "codex-intake" "derived_summary" "derived_summary" "derived_summary_data_only"
  validate_codex_intake
  validate_interactive_intake
  validate_manifest
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
