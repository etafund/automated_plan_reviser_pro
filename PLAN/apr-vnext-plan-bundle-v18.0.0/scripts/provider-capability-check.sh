#!/usr/bin/env bash
set -euo pipefail

BUNDLE_VERSION="v18.0.0"
ENVELOPE_SCHEMA_VERSION="json_envelope.v1"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bundle_root="$(cd "${script_dir}/.." && pwd)"
policy_path="${bundle_root}/fixtures/provider-access-policy.json"
docs_snapshot_path="${bundle_root}/fixtures/provider-docs-snapshot.json"
fixtures_dir="${bundle_root}/fixtures"
now_epoch="$(date -u +%s)"

usage() {
  cat >&2 <<'USAGE'
Usage: provider-capability-check.sh [options]

Options:
  --bundle-root PATH     v18 bundle root. Defaults to this script's parent.
  --policy PATH          Provider access policy fixture.
  --docs-snapshot PATH   Provider docs snapshot fixture.
  --now-epoch SECONDS    Override current epoch for deterministic checks.
  --json                 Accepted for robot-call compatibility.
  --help                 Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-root)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      bundle_root="$2"
      fixtures_dir="${bundle_root}/fixtures"
      policy_path="${fixtures_dir}/provider-access-policy.json"
      docs_snapshot_path="${fixtures_dir}/provider-docs-snapshot.json"
      shift 2
      ;;
    --policy)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      policy_path="$2"
      shift 2
      ;;
    --docs-snapshot)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      docs_snapshot_path="$2"
      shift 2
      ;;
    --now-epoch)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      now_epoch="$2"
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

if ! command -v jq >/dev/null 2>&1; then
  printf 'jq is required for provider capability checks\n' >&2
  exit 1
fi

if [[ ! -f "$policy_path" ]]; then
  printf 'provider access policy not found: %s\n' "$policy_path" >&2
  exit 1
fi

if [[ ! -f "$docs_snapshot_path" ]]; then
  printf 'provider docs snapshot not found: %s\n' "$docs_snapshot_path" >&2
  exit 1
fi

capability_files=()
while IFS= read -r -d '' path; do
  capability_files+=("$path")
done < <(find "$fixtures_dir" -maxdepth 1 -type f -name 'provider-capability.*.json' -print0 | sort -z)

if [[ ${#capability_files[@]} -eq 0 ]]; then
  printf 'no provider capability fixtures found under %s\n' "$fixtures_dir" >&2
  exit 1
fi

jq -s \
  --slurpfile policy "$policy_path" \
  --slurpfile docs "$docs_snapshot_path" \
  --argjson now_epoch "$now_epoch" \
  --arg schema_version "$ENVELOPE_SCHEMA_VERSION" \
  --arg bundle_version "$BUNDLE_VERSION" \
  --arg tool "provider-capability-check" '
    def ts_epoch($value):
      try ($value | fromdateiso8601) catch 0;

    . as $capabilities
    | ($policy[0]) as $policy_doc
    | ($docs[0]) as $docs_doc
    | ($capabilities | map({key: .provider_slot, value: .}) | from_entries) as $cap_by_slot
    | ($policy_doc.live_routes | to_entries | map({
        provider_slot: .key,
        provider_family: .value.provider_family,
        access_path: .value.access_path,
        api_allowed: (.value.api_allowed // false),
        evidence_required: (.value.evidence_required // false),
        capability_probe_required: (.value.capability_probe_required // false),
        has_static_capability_fixture: ($cap_by_slot[.key] != null),
        runtime_probe_required: (($cap_by_slot[.key] == null) and ((.value.evidence_required // false) or (.value.capability_probe_required // false)))
      })) as $routes
    | ($docs_doc.expires_at | ts_epoch(.)) as $expires_epoch
    | ($expires_epoch >= $now_epoch) as $docs_fresh
    | ($routes | map(select(.has_static_capability_fixture | not))) as $missing_static
    | ($routes | map(select(.runtime_probe_required))) as $runtime_probe_required
    | {
        ok: $docs_fresh,
        schema_version: $schema_version,
        data: {
          bundle_version: $bundle_version,
          checked_at_epoch: $now_epoch,
          docs_snapshot: {
            checked_at: $docs_doc.checked_at,
            expires_at: $docs_doc.expires_at,
            max_age_days: $docs_doc.max_age_days,
            docs_fresh: $docs_fresh,
            refresh_required_before_live_provider_calls: ($docs_doc.refresh_required_before_live_provider_calls // true),
            source_count: ($docs_doc.sources | length)
          },
          capability_inventory: ($capabilities | map({
            provider_slot,
            provider_family,
            provider,
            access_path,
            status,
            checked_at,
            model,
            api_allowed: (.api_allowed // null),
            required_command: (.required_command // null),
            required_env: (.required_env // []),
            highest_reasoning_verified: (.highest_reasoning_verified // false)
          })),
          route_inventory: $routes,
          capability_gaps: $missing_static,
          runtime_probe_required: $runtime_probe_required
        },
        meta: {
          tool: $tool,
          bundle_version: $bundle_version
        },
        warnings: (
          (if $docs_fresh then [] else [
            "provider_docs_snapshot_stale: Provider docs snapshot is expired; refresh before live provider calls."
          ] end)
          + ($missing_static | map("provider_static_capability_missing: No static provider capability fixture exists for " + .provider_slot + "; route readiness must rely on runtime probe/evidence."))
        ),
        errors: (if $docs_fresh then [] else [{
          error_code: "provider_docs_snapshot_stale",
          message: "Provider docs snapshot is expired."
        }] end),
        commands: {
          next: "PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/provider-capability-check.sh --json"
        },
        next_command: null,
        blocked_reason: (if $docs_fresh then null else "provider_docs_snapshot_stale" end),
        fix_command: (if $docs_fresh then null else "refresh provider docs snapshot and rerun provider-capability-check.sh --json" end),
        retry_safe: true
      }' "${capability_files[@]}"
