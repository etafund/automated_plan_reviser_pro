#!/usr/bin/env bash
set -euo pipefail

BUNDLE_VERSION="v18.0.0"
ENVELOPE_SCHEMA_VERSION="json_envelope.v1"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bundle_root="$(cd "${script_dir}/.." && pwd)"
policy_path="${bundle_root}/fixtures/context-serialization-policy.json"
context_json_path="${bundle_root}/fixtures/prompt-context-packet.json"
requested_format="auto"
license_approved="${APR_TOON_LICENSE_APPROVED:-0}"
explicit_enablement="${APR_TOON_ENABLED:-0}"

usage() {
  cat >&2 <<'USAGE'
Usage: context-serialization-check.sh [options]

Options:
  --policy PATH              Context serialization policy fixture.
  --context-json PATH        Canonical JSON context packet.
  --requested-format FORMAT  json, auto, or toon. Default: auto.
  --license-approved BOOL    true/false, 1/0, yes/no.
  --toon-enabled BOOL        true/false, 1/0, yes/no.
  --json                     Accepted for robot-call compatibility.
  --help                     Show this help.
USAGE
}

boolish_true() {
  case "$1" in
    1 | true | TRUE | yes | YES | y | Y)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --policy)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      policy_path="$2"
      shift 2
      ;;
    --context-json)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      context_json_path="$2"
      shift 2
      ;;
    --requested-format)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      requested_format="$2"
      shift 2
      ;;
    --license-approved)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      license_approved="$2"
      shift 2
      ;;
    --toon-enabled)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      explicit_enablement="$2"
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

case "$requested_format" in
  json | auto | toon)
    ;;
  *)
    usage
    exit 2
    ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  printf 'jq is required for context serialization checks\n' >&2
  exit 1
fi

if [[ ! -f "$policy_path" ]]; then
  printf 'context serialization policy not found: %s\n' "$policy_path" >&2
  exit 1
fi

if [[ ! -f "$context_json_path" ]]; then
  printf 'canonical context JSON not found: %s\n' "$context_json_path" >&2
  exit 1
fi

canonical_json="$(jq -S -c . "$context_json_path")"
canonical_hash="$(printf '%s' "$canonical_json" | sha256_text)"

toon_binary=""
for candidate in $(jq -r '.toon_rust.cli_candidates[]' "$policy_path"); do
  if command -v "$candidate" >/dev/null 2>&1; then
    toon_binary="$(command -v "$candidate")"
    break
  fi
done

policy_status="$(jq -r '.policy_status' "$policy_path")"
canonical_storage_format="$(jq -r '.canonical_storage_format' "$policy_path")"
fallback_format="$(jq -r '.fallback_format' "$policy_path")"
policy_toon_enabled="$(jq -r '.toon_rust.enabled' "$policy_path")"
policy_toon_required="$(jq -r '.toon_rust.required' "$policy_path")"
legal_review_required="$(jq -r '.legal_review_required' "$policy_path")"
toon_reason=""
selected_format="json"
roundtrip_status="not_attempted"
toon_payload_hash=""

if [[ "$requested_format" == "json" ]]; then
  toon_reason="json_explicitly_requested"
elif [[ "$canonical_storage_format" != "json" || "$fallback_format" != "json" ]]; then
  toon_reason="policy_requires_json_canonical_and_fallback"
elif [[ "$policy_toon_required" != "false" ]]; then
  toon_reason="toon_must_not_be_required"
elif [[ "$policy_toon_enabled" != "true" ]]; then
  toon_reason="toon_disabled_by_policy_json_fallback"
elif [[ "$legal_review_required" == "true" ]] && ! boolish_true "$license_approved"; then
  toon_reason="license_review_not_approved_json_fallback"
elif ! boolish_true "$explicit_enablement"; then
  toon_reason="explicit_enablement_missing_json_fallback"
elif [[ -z "$toon_binary" ]]; then
  toon_reason="toon_unavailable_json_fallback"
else
  selected_format="toon"
  toon_reason="toon_transport_selected"
fi

warnings_json="[]"
if [[ "$selected_format" == "json" && "$requested_format" != "json" ]]; then
  warnings_json="$(jq -n --arg reason "$toon_reason" '["toon_json_fallback: " + $reason]')"
fi

if [[ "$selected_format" == "toon" ]]; then
  # The policy allows TOON only as a model-facing transport after a strict JSON
  # round-trip. The bundle checker verifies gates and reports the required
  # round-trip obligation; adapters own tool-specific encode/decode invocation.
  roundtrip_status="required_before_prompt_transport"
  toon_payload_hash="pending_adapter_encode"
fi

jq -n \
  --argjson warnings "$warnings_json" \
  --arg schema_version "$ENVELOPE_SCHEMA_VERSION" \
  --arg bundle_version "$BUNDLE_VERSION" \
  --arg policy_path "$policy_path" \
  --arg context_json_path "$context_json_path" \
  --arg requested_format "$requested_format" \
  --arg selected_format "$selected_format" \
  --arg canonical_storage_format "$canonical_storage_format" \
  --arg fallback_format "$fallback_format" \
  --arg canonical_json_sha256 "sha256:${canonical_hash}" \
  --arg toon_payload_sha256 "$toon_payload_hash" \
  --arg roundtrip_status "$roundtrip_status" \
  --arg toon_binary "$toon_binary" \
  --arg policy_status "$policy_status" \
  --arg toon_reason "$toon_reason" \
  --argjson toon_policy_enabled "$policy_toon_enabled" \
  --argjson toon_policy_required "$policy_toon_required" \
  --argjson license_approved "$(if boolish_true "$license_approved"; then printf true; else printf false; fi)" \
  --argjson explicit_enablement "$(if boolish_true "$explicit_enablement"; then printf true; else printf false; fi)" '
    {
      ok: true,
      schema_version: $schema_version,
      data: {
        policy_path: $policy_path,
        context_json_path: $context_json_path,
        requested_format: $requested_format,
        selected_format: $selected_format,
        canonical_storage_format: $canonical_storage_format,
        fallback_format: $fallback_format,
        canonical_json_sha256: $canonical_json_sha256,
        toon_payload_sha256: (if $toon_payload_sha256 == "" then null else $toon_payload_sha256 end),
        roundtrip_status: $roundtrip_status,
        toon_binary: (if $toon_binary == "" then null else $toon_binary end),
        policy_status: $policy_status,
        toon_policy_enabled: $toon_policy_enabled,
        toon_policy_required: $toon_policy_required,
        license_approved: $license_approved,
        explicit_enablement: $explicit_enablement,
        fallback_reason: (if $selected_format == "json" then $toon_reason else null end),
        forbidden_canonical_formats: ["toon", "tru"]
      },
      meta: {
        tool: "context-serialization-check",
        bundle_version: $bundle_version
      },
      warnings: $warnings,
      errors: [],
      commands: {
        next: "PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/context-serialization-check.sh --json"
      },
      next_command: null,
      blocked_reason: null,
      fix_command: null,
      retry_safe: true
    }'
