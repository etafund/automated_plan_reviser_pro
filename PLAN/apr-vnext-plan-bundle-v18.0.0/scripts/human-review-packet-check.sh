#!/usr/bin/env bash
set -euo pipefail

schema_version="json_envelope.v1"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bundle_root="$(cd "$script_dir/.." && pwd)"
packet_file="$bundle_root/fixtures/human-review-packet.json"
plan_file="$bundle_root/fixtures/plan-artifact.json"
approval_file="$bundle_root/fixtures/approval-ledger.json"
artifact_index_file="$bundle_root/fixtures/artifact-index.json"
output_json=0

usage() {
  cat >&2 <<'EOF'
Usage: human-review-packet-check.sh [options]

Validate v18 human review packet handoff contracts.

Options:
  --packet <path>          Human review packet JSON.
  --plan <path>            Plan artifact JSON used for reference checks.
  --approval-ledger <path> Approval ledger JSON.
  --artifact-index <path>  Artifact index JSON.
  --root <path>            Bundle root used to resolve packet_path.
  --json                   Emit v18 JSON envelope.
  --help                   Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --packet)
      [[ $# -ge 2 ]] || { echo "missing value for --packet" >&2; exit 2; }
      packet_file="$2"
      shift 2
      ;;
    --plan)
      [[ $# -ge 2 ]] || { echo "missing value for --plan" >&2; exit 2; }
      plan_file="$2"
      shift 2
      ;;
    --approval-ledger)
      [[ $# -ge 2 ]] || { echo "missing value for --approval-ledger" >&2; exit 2; }
      approval_file="$2"
      shift 2
      ;;
    --artifact-index)
      [[ $# -ge 2 ]] || { echo "missing value for --artifact-index" >&2; exit 2; }
      artifact_index_file="$2"
      shift 2
      ;;
    --root)
      [[ $# -ge 2 ]] || { echo "missing value for --root" >&2; exit 2; }
      bundle_root="$2"
      shift 2
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
checks=()

add_error() {
  errors+=("$1")
}

add_warning() {
  warnings+=("$1")
}

record_check() {
  checks+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"$4")
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

warnings_json() {
  if [[ $# -eq 0 ]]; then
    printf '[]'
    return
  fi
  printf '%s\n' "$@" | jq -R -s 'split("\n")[:-1]'
}

checks_json() {
  if [[ ${#checks[@]} -eq 0 ]]; then
    printf '[]'
    return
  fi
  printf '%s\n' "${checks[@]}" |
    jq -R -s '
      split("\n")[:-1]
      | map(split("\t") | {
          requirement_id: .[0],
          level: .[1],
          status: .[2],
          detail: .[3]
        })'
}

require_json_file() {
  local label="$1"
  local path="$2"
  if [[ ! -f "$path" ]]; then
    add_error "$label not found: $path"
    return 1
  fi
  if ! jq empty "$path" >/dev/null 2>&1; then
    add_error "$label is not valid JSON: $path"
    return 1
  fi
  return 0
}

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 2
fi

require_json_file "human review packet" "$packet_file" || true
require_json_file "plan artifact" "$plan_file" || true
require_json_file "approval ledger" "$approval_file" || true
require_json_file "artifact index" "$artifact_index_file" || true

packet_path=""
if [[ ${#errors[@]} -eq 0 ]]; then
  if jq -e '.schema_version == "human_review_packet.v1" and .bundle_version == "v18.0.0"' "$packet_file" >/dev/null; then
    record_check "HRP-MUST-SCHEMA" "MUST" "pass" "packet schema and bundle version match v18"
  else
    record_check "HRP-MUST-SCHEMA" "MUST" "fail" "packet schema or bundle version mismatch"
    add_error "human review packet must use schema_version=human_review_packet.v1 and bundle_version=v18.0.0"
  fi

  if jq -e '.executive_summary.text != "" and (.executive_summary.implementation_handoff_eligible | type == "boolean") and (.executive_summary.degradation_label != null)' "$packet_file" >/dev/null; then
    record_check "HRP-MUST-SUMMARY" "MUST" "pass" "executive summary includes handoff eligibility and degradation label"
  else
    record_check "HRP-MUST-SUMMARY" "MUST" "fail" "executive summary is incomplete"
    add_error "executive_summary must include text, implementation_handoff_eligible, and degradation_label"
  fi

  if jq -e '(.implementation_sequence | length) > 0 and all(.implementation_sequence[]; ((.plan_item_ids // []) | length) > 0 and ((.test_ids // []) | length) > 0 and ((.rollback_point_ids // []) | length) > 0)' "$packet_file" >/dev/null; then
    record_check "HRP-MUST-SEQUENCE" "MUST" "pass" "implementation sequence includes plan, test, and rollback anchors"
  else
    record_check "HRP-MUST-SEQUENCE" "MUST" "fail" "implementation sequence misses trace anchors"
    add_error "implementation_sequence entries must include plan_item_ids, test_ids, and rollback_point_ids"
  fi

  if jq -e '(.high_risk_decisions | length) > 0 and all(.high_risk_decisions[]; (.approval_id // "") != "" and ((.evidence_ids // []) | length) > 0)' "$packet_file" >/dev/null; then
    record_check "HRP-MUST-RISK-DECISIONS" "MUST" "pass" "high-risk decisions include approvals and evidence ids"
  else
    record_check "HRP-MUST-RISK-DECISIONS" "MUST" "fail" "high-risk decisions miss approvals or evidence"
    add_error "high_risk_decisions must include approval_id and evidence_ids"
  fi

  if jq -e '
      . as $packet
      | ($packet.source_artifact_ids.waiver_ids // []) as $waivers
      | if ($waivers | length) == 0 then true
        else
          (($packet.waivers_and_degradations // []) | length) > 0
          and all($waivers[]; . as $id | any($packet.waivers_and_degradations[]?; .waiver_id == $id and .must_surface_in_handoff == true))
        end
    ' "$packet_file" >/dev/null; then
    record_check "HRP-MUST-WAIVER-VISIBILITY" "MUST" "pass" "waivers are surfaced in handoff"
  else
    record_check "HRP-MUST-WAIVER-VISIBILITY" "MUST" "fail" "waivers are hidden or lack must_surface_in_handoff"
    add_error "waiver_ids must resolve to visible waivers_and_degradations entries with must_surface_in_handoff=true"
  fi

  if jq -e '.executive_summary.unresolved_question_count == (.unresolved_questions | length)' "$packet_file" >/dev/null; then
    record_check "HRP-MUST-UNRESOLVED" "MUST" "pass" "unresolved question count matches packet section"
  else
    record_check "HRP-MUST-UNRESOLVED" "MUST" "fail" "unresolved question count is stale"
    add_error "executive_summary.unresolved_question_count must equal unresolved_questions length"
  fi

  if jq -e '(.test_plan | length) > 0 and all(.test_plan[]; (.test_id // "") != "" and (.command // "") != "" and ((.plan_item_ids // []) | length) > 0)' "$packet_file" >/dev/null; then
    record_check "HRP-MUST-TEST-PLAN" "MUST" "pass" "test plan entries include commands and plan anchors"
  else
    record_check "HRP-MUST-TEST-PLAN" "MUST" "fail" "test plan entries are incomplete"
    add_error "test_plan entries must include test_id, command, and plan_item_ids"
  fi

  if jq -e '(.rollback_points | length) > 0 and all(.rollback_points[]; (.rollback_point_id // "") != "" and (.verification_command // "") != "")' "$packet_file" >/dev/null; then
    record_check "HRP-MUST-ROLLBACK" "MUST" "pass" "rollback points include verification commands"
  else
    record_check "HRP-MUST-ROLLBACK" "MUST" "fail" "rollback points miss verification commands"
    add_error "rollback_points must include rollback_point_id and verification_command"
  fi

  if jq -e '
      def plan_item_ids: [ .plan_items[]?.item_id ];
      def test_ids: [ .test_matrix[]?.test_id ];
      def rollback_ids: [ .rollback_points[]?.rollback_point_id ];
      . as $plan
      | input as $packet
      | (plan_item_ids) as $plan_ids
      | (test_ids) as $plan_test_ids
      | (rollback_ids) as $plan_rollback_ids
      | all($packet.implementation_sequence[]?.plan_item_ids[]?; . as $id | $plan_ids | index($id))
        and all($packet.test_plan[]?.test_id; . as $id | $plan_test_ids | index($id))
        and all($packet.rollback_points[]?.rollback_point_id; . as $id | $plan_rollback_ids | index($id))
    ' "$plan_file" "$packet_file" >/dev/null; then
    record_check "HRP-MUST-PLAN-TRACE" "MUST" "pass" "packet plan/test/rollback ids resolve to plan artifact"
  else
    record_check "HRP-MUST-PLAN-TRACE" "MUST" "fail" "packet references missing plan artifact ids"
    add_error "packet plan_item_ids, test_ids, and rollback_point_ids must resolve to the plan artifact"
  fi

  if jq -e '
      [.approvals[]?.approval_id] as $approval_ids
      | input as $packet
      | all($packet.approval_records[]?.approval_id; . as $id | $approval_ids | index($id))
        and all($packet.high_risk_decisions[]?.approval_id; . as $id | $approval_ids | index($id))
    ' "$approval_file" "$packet_file" >/dev/null; then
    record_check "HRP-MUST-APPROVALS" "MUST" "pass" "packet approval ids resolve to approval ledger"
  else
    record_check "HRP-MUST-APPROVALS" "MUST" "fail" "packet approval ids are unresolved"
    add_error "approval_records and high_risk_decisions approval ids must resolve to approval-ledger entries"
  fi

  if jq -e '
      [.artifacts[]?.artifact_id] as $artifact_ids
      | input as $packet
      | [
          $packet.source_artifact_ids.final_plan_artifact_id,
          $packet.source_artifact_ids.traceability_id,
          $packet.source_artifact_ids.approval_ledger_id
        ] as $required
      | all($required[]; . as $id | $artifact_ids | index($id))
        and all($packet.source_artifact_ids.provider_result_ids[]?; . as $id | $artifact_ids | index($id))
        and all($packet.source_artifact_ids.waiver_ids[]?; . as $id | $artifact_ids | index($id))
    ' "$artifact_index_file" "$packet_file" >/dev/null; then
    record_check "HRP-MUST-ARTIFACT-INDEX" "MUST" "pass" "source artifact ids resolve to artifact index"
  else
    record_check "HRP-MUST-ARTIFACT-INDEX" "MUST" "fail" "source artifact ids are missing from artifact index"
    add_error "source_artifact_ids must resolve to artifact-index entries"
  fi

  if jq -e '(.bead_export_preview.ready | type == "boolean") and (.bead_export_preview.beads | length) > 0 and all(.bead_export_preview.beads[]; ((.plan_item_ids // []) | length) > 0 and ((.test_ids // []) | length) > 0)' "$packet_file" >/dev/null; then
    record_check "HRP-SHOULD-BEAD-PREVIEW" "SHOULD" "pass" "bead export preview includes plan and test anchors"
  else
    record_check "HRP-SHOULD-BEAD-PREVIEW" "SHOULD" "fail" "bead export preview lacks anchors"
    add_warning "bead_export_preview should include plan_item_ids and test_ids"
  fi

  packet_path="$(jq -r '.packet_path // ""' "$packet_file")"
  if [[ "$packet_path" != "" && -f "$bundle_root/$packet_path" ]]; then
    if grep -Fq "Degradation / Waiver Visibility" "$bundle_root/$packet_path" &&
       grep -Fq "Unresolved Questions" "$bundle_root/$packet_path" &&
       grep -Fq "fallback-waiver-demo" "$bundle_root/$packet_path"; then
      record_check "HRP-MUST-GOLDEN-MARKDOWN" "MUST" "pass" "golden packet surfaces waiver and unresolved question sections"
    else
      record_check "HRP-MUST-GOLDEN-MARKDOWN" "MUST" "fail" "golden packet hides waiver or unresolved question sections"
      add_error "rendered packet must include waiver visibility and unresolved question sections"
    fi
  else
    record_check "HRP-MUST-GOLDEN-MARKDOWN" "MUST" "fail" "packet_path is missing or does not exist"
    add_error "packet_path must resolve under bundle root"
  fi
fi

ok=true
if [[ ${#errors[@]} -gt 0 ]]; then
  ok=false
fi

if [[ "$output_json" -eq 1 ]]; then
  checks_payload="$(checks_json)"
  errors_payload="$(messages_json "human_review_packet_invalid" "${errors[@]}")"
  warnings_payload="$(warnings_json "${warnings[@]}")"
  jq -nc \
    --argjson ok "$ok" \
    --arg schema_version "$schema_version" \
    --arg packet_file "$packet_file" \
    --arg packet_path "$packet_path" \
    --argjson checks "$checks_payload" \
    --argjson errors "$errors_payload" \
    --argjson warnings "$warnings_payload" \
    '{
      ok: $ok,
      schema_version: $schema_version,
      data: {
        packet_file: $packet_file,
        packet_path: (if $packet_path == "" then null else $packet_path end),
        conformance_checks: $checks,
        conformance_coverage: {
          must_clauses: 12,
          should_clauses: 1,
          tested: ($checks | length),
          passing: ($checks | map(select(.status == "pass")) | length),
          divergent: 0,
          must_score: (($checks | map(select(.level == "MUST" and .status == "pass")) | length) / 12)
        }
      },
      meta: {
        tool: "human-review-packet-check",
        bundle_version: "v18.0.0"
      },
      blocked_reason: (if $ok then null else "human review packet contract violations" end),
      next_command: (if $ok then null else "fix the packet, approval ledger, artifact index, or golden Markdown packet" end),
      fix_command: (if $ok then null else "PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/human-review-packet-check.sh --json" end),
      retry_safe: true,
      errors: $errors,
      warnings: $warnings,
      commands: {
        validate: "PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/human-review-packet-check.sh --json"
      }
    }'
else
  if [[ "$ok" == "true" ]]; then
    echo "human review packet contract OK" >&2
  else
    printf 'human review packet contract FAILED\n' >&2
    printf '%s\n' "${errors[@]}" >&2
  fi
fi

if [[ "$ok" == "true" ]]; then
  exit 0
fi
exit 1
