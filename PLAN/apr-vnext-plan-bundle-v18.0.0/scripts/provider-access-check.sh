#!/usr/bin/env bash
set -euo pipefail

BUNDLE_VERSION="v18.0.0"
ENVELOPE_SCHEMA_VERSION="json_envelope.v1"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bundle_root="$(cd "${script_dir}/.." && pwd)"
policy_path="${bundle_root}/fixtures/provider-access-policy.json"
provider_slot=""
requested_access_path=""
observed_provider_family=""

usage() {
  cat >&2 <<'USAGE'
Usage: provider-access-check.sh --slot SLOT --access-path ACCESS_PATH [options]

Options:
  --policy PATH              Provider access policy fixture path.
  --slot SLOT                Provider slot, e.g. chatgpt_pro_first_plan.
  --access-path ACCESS_PATH  Requested execution path, e.g. xai_api.
  --provider-family FAMILY   Optional observed provider family.
  --json                     Accepted for robot-call compatibility.
  --help                     Show this help.
USAGE
}

json_string() {
  jq -Rn --arg value "$1" '$value'
}

json_envelope() {
  local ok="$1"
  local code="$2"
  local message="$3"
  local retry_safe="$4"
  local required_access_path="$5"
  local policy_provider_family="$6"
  local api_allowed="$7"
  local eligible_for_synthesis="$8"
  local evidence_required="$9"
  local blocked_reason="${10}"
  local fix_command="${11}"

  jq -n \
    --argjson ok "$ok" \
    --arg schema_version "$ENVELOPE_SCHEMA_VERSION" \
    --arg bundle_version "$BUNDLE_VERSION" \
    --arg tool "provider-access-check" \
    --arg provider_slot "$provider_slot" \
    --arg requested_access_path "$requested_access_path" \
    --arg required_access_path "$required_access_path" \
    --arg observed_provider_family "$observed_provider_family" \
    --arg policy_provider_family "$policy_provider_family" \
    --arg policy_path "$policy_path" \
    --argjson api_allowed "$api_allowed" \
    --argjson eligible_for_synthesis "$eligible_for_synthesis" \
    --argjson evidence_required "$evidence_required" \
    --arg code "$code" \
    --arg message "$message" \
    --argjson retry_safe "$retry_safe" \
    --arg blocked_reason "$blocked_reason" \
    --arg fix_command "$fix_command" '
      {
        ok: $ok,
        schema_version: $schema_version,
        data: {
          provider_slot: $provider_slot,
          requested_access_path: $requested_access_path,
          required_access_path: $required_access_path,
          observed_provider_family: $observed_provider_family,
          policy_provider_family: $policy_provider_family,
          api_allowed: $api_allowed,
          eligible_for_synthesis: $eligible_for_synthesis,
          evidence_required: $evidence_required,
          policy_path: $policy_path
        },
        meta: {
          tool: $tool,
          bundle_version: $bundle_version
        },
        warnings: [],
        errors: (if $ok then [] else [{error_code: $code, message: $message}] end),
        commands: {
          next: "PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/provider-access-check.sh --json"
        },
        next_command: null,
        blocked_reason: (if $blocked_reason == "" then null else $blocked_reason end),
        fix_command: (if $fix_command == "" then null else $fix_command end),
        retry_safe: $retry_safe
      }'
}

is_api_access_path() {
  case "$1" in
    *api* | openai_* | gemini_* | anthropic_*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --policy)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      policy_path="$2"
      shift 2
      ;;
    --slot)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      provider_slot="$2"
      shift 2
      ;;
    --access-path)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      requested_access_path="$2"
      shift 2
      ;;
    --provider-family)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      observed_provider_family="$2"
      shift 2
      ;;
    --json)
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$provider_slot" || -z "$requested_access_path" ]]; then
  usage
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'jq is required for provider access policy enforcement\n' >&2
  exit 1
fi

if [[ ! -f "$policy_path" ]]; then
  printf 'provider access policy not found: %s\n' "$policy_path" >&2
  exit 1
fi

route_json="$(jq -c --arg slot "$provider_slot" '.live_routes[$slot] // empty' "$policy_path")"
if [[ -z "$route_json" ]]; then
  provider_slot_json="$(json_string "$provider_slot")"
  json_envelope false \
    "unknown_provider_slot" \
    "No live route exists for provider slot ${provider_slot_json}." \
    false \
    "" \
    "" \
    false \
    false \
    false \
    "unknown_provider_slot" \
    "apr providers readiness --json"
  exit 1
fi

required_access_path="$(jq -r '.access_path // ""' <<<"$route_json")"
policy_provider_family="$(jq -r '.provider_family // ""' <<<"$route_json")"
api_allowed="$(jq -r '.api_allowed // false' <<<"$route_json")"
eligible_for_synthesis="$(jq -r '.eligible_for_synthesis // false' <<<"$route_json")"
evidence_required="$(jq -r '.evidence_required // false' <<<"$route_json")"

if [[ -n "$observed_provider_family" && "$observed_provider_family" != "$policy_provider_family" ]]; then
  json_envelope false \
    "provider_family_mismatch" \
    "Provider family ${observed_provider_family} cannot satisfy ${provider_slot}; expected ${policy_provider_family}." \
    false \
    "$required_access_path" \
    "$policy_provider_family" \
    "$api_allowed" \
    "$eligible_for_synthesis" \
    "$evidence_required" \
    "provider_family_mismatch" \
    "apr providers readiness --json"
  exit 1
fi

access_path_allowed=false
if [[ "$requested_access_path" == "$required_access_path" ]]; then
  access_path_allowed=true
elif [[ "$required_access_path" == "oracle_browser_remote_or_local" ]]; then
  case "$requested_access_path" in
    oracle_browser_remote | oracle_browser_local)
      access_path_allowed=true
      ;;
  esac
fi

if [[ "$access_path_allowed" != "true" ]]; then
  error_code="prohibited_provider_access"
  blocked_reason="provider_access_path_mismatch"
  if [[ "$api_allowed" == "false" ]] && is_api_access_path "$requested_access_path"; then
    error_code="prohibited_api_substitution"
    blocked_reason="direct_api_substitution_forbidden"
  fi
  json_envelope false \
    "$error_code" \
    "${requested_access_path} cannot satisfy ${provider_slot}; required access path is ${required_access_path}." \
    false \
    "$required_access_path" \
    "$policy_provider_family" \
    "$api_allowed" \
    "$eligible_for_synthesis" \
    "$evidence_required" \
    "$blocked_reason" \
    "apr providers readiness --json"
  exit 1
fi

json_envelope true \
  "ok" \
  "Provider access path is allowed for ${provider_slot}." \
  true \
  "$required_access_path" \
  "$policy_provider_family" \
  "$api_allowed" \
  "$eligible_for_synthesis" \
  "$evidence_required" \
  "" \
  ""
