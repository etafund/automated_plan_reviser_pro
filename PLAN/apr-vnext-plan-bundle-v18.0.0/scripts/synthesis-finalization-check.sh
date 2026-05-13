#!/usr/bin/env bash
set -euo pipefail

VERSION="v18.0.0"
schema_version="json_envelope.v1"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bundle_root="$(cd "$script_dir/.." && pwd)"
finalization_file="$bundle_root/fixtures/synthesis-finalization.json"
output_json=0

usage() {
  cat >&2 <<'EOF'
Usage: synthesis-finalization-check.sh [options]

Validate the v18 synthesis finalization contract: pre-call readiness, review
quorum/waiver state, final synthesis provider result, final handoff evidence,
and cross-artifact traceability.

Options:
  --finalization <path>  Synthesis finalization fixture to validate.
  --root <path>          Bundle root used to resolve fixture paths.
  --json                 Emit v18 JSON envelope.
  --help                 Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --finalization)
      [[ $# -ge 2 ]] || { echo "missing value for --finalization" >&2; exit 2; }
      finalization_file="$2"
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

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 2
fi

errors=()
warnings=()
checks=()
final_artifact_count=0
degradation_count=0
synthesis_route_id=""
synthesis_provider_result_id=""
synthesis_evidence_id=""
prompt_sha256=""

add_error() {
  errors+=("$1")
}

add_warning() {
  warnings+=("$1")
}

record_check() {
  local requirement_id="$1"
  local level="$2"
  local status="$3"
  local summary="$4"
  checks+=("$requirement_id|$level|$status|$summary")
}

json_messages() {
  local code="$1"
  shift || true
  if [[ $# -eq 0 ]]; then
    printf '[]'
    return
  fi
  printf '%s\n' "$@" | jq -R -s --arg code "$code" 'split("\n")[:-1] | map({error_code: $code, message: .})'
}

json_checks() {
  if [[ ${#checks[@]} -eq 0 ]]; then
    printf '[]'
    return
  fi
  printf '%s\n' "${checks[@]}" | jq -R -s '
    split("\n")[:-1]
    | map(split("|") | {
        requirement_id: .[0],
        level: .[1],
        status: .[2],
        summary: .[3]
      })
  '
}

json_coverage() {
  local must_total must_pass should_total should_pass
  must_total="$(printf '%s\n' "${checks[@]}" | awk -F'|' '$2=="MUST"{c++} END{print c+0}')"
  must_pass="$(printf '%s\n' "${checks[@]}" | awk -F'|' '$2=="MUST" && $3=="pass"{c++} END{print c+0}')"
  should_total="$(printf '%s\n' "${checks[@]}" | awk -F'|' '$2=="SHOULD"{c++} END{print c+0}')"
  should_pass="$(printf '%s\n' "${checks[@]}" | awk -F'|' '$2=="SHOULD" && $3=="pass"{c++} END{print c+0}')"
  jq -n \
    --argjson must_total "$must_total" \
    --argjson must_pass "$must_pass" \
    --argjson should_total "$should_total" \
    --argjson should_pass "$should_pass" \
    '{
      spec_section: "synthesis_finalization.v1",
      must_clauses: $must_total,
      should_clauses: $should_total,
      tested: ($must_total + $should_total),
      passing: ($must_pass + $should_pass),
      divergent: 0,
      must_score: (if $must_total == 0 then 1 else ($must_pass / $must_total) end)
    }'
}

resolve_path() {
  local rel="$1"
  if [[ "$rel" = /* ]]; then
    printf '%s\n' "$rel"
  else
    printf '%s/%s\n' "$bundle_root" "$rel"
  fi
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

has_artifact_id() {
  local artifact_index="$1"
  local artifact_id="$2"
  jq -e --arg artifact_id "$artifact_id" 'any(.artifacts[]?; .artifact_id == $artifact_id)' "$artifact_index" >/dev/null
}

if require_json_file "synthesis finalization" "$finalization_file"; then
  synthesis_route_id="$(jq -r '.synthesis_route_id // ""' "$finalization_file")"
  synthesis_provider_result_id="$(jq -r '.synthesis_result.provider_result_id // ""' "$finalization_file")"
  synthesis_evidence_id="$(jq -r '.synthesis_result.evidence_id // ""' "$finalization_file")"
  prompt_sha256="$(jq -r '.synthesis_prompt.prompt_sha256 // ""' "$finalization_file")"
  final_artifact_count="$(jq '.final_artifacts | length' "$finalization_file")"
  degradation_count="$(jq '.degradation_labels | length' "$finalization_file")"

  [[ "$(jq -r '.schema_version // ""' "$finalization_file")" == "synthesis_finalization.v1" ]] || add_error "schema_version must be synthesis_finalization.v1"
  [[ "$(jq -r '.bundle_version // ""' "$finalization_file")" == "$VERSION" ]] || add_error "bundle_version must be $VERSION"
  [[ "$synthesis_route_id" == "chatgpt_pro_synthesis" ]] || add_error "synthesis_route_id must be chatgpt_pro_synthesis"
  [[ "$prompt_sha256" =~ ^sha256:[0-9a-f]{64}$ ]] || add_error "synthesis_prompt.prompt_sha256 must be sha256:<64 lowercase hex>"

  if jq -e '.readiness_decision.ready == true and .readiness_decision.stage == "synthesis_prompt_submission"' "$finalization_file" >/dev/null; then
    record_check "SYN-MUST-READY" "MUST" "pass" "synthesis prompt submission gate is ready"
  else
    record_check "SYN-MUST-READY" "MUST" "fail" "synthesis prompt submission gate is not ready"
    add_error "readiness_decision must mark synthesis_prompt_submission ready before synthesis"
  fi

  route_readiness_path="$(resolve_path "$(jq -r '.readiness_decision.route_readiness_path // empty' "$finalization_file")")"
  if require_json_file "route readiness" "$route_readiness_path"; then
    if jq -e '(.synthesis_prompt_blocked_until_evidence_for // []) | index("chatgpt_pro_synthesis") | not' "$route_readiness_path" >/dev/null; then
      record_check "SYN-MUST-NON-CIRCULAR" "MUST" "pass" "synthesis prompt gate does not require synthesis evidence before synthesis"
    else
      record_check "SYN-MUST-NON-CIRCULAR" "MUST" "fail" "synthesis prompt gate is circular"
      add_error "synthesis_prompt_blocked_until_evidence_for must not include chatgpt_pro_synthesis"
    fi
  else
    record_check "SYN-MUST-NON-CIRCULAR" "MUST" "fail" "route readiness fixture missing"
  fi

  if jq -e '
      (.review_quorum_state.state == "met" or .review_quorum_state.state == "waived")
      and (.review_quorum_state.required_independent_reviewers_satisfied == true or ((.review_quorum_state.waiver_ids // []) | length > 0))
      and (.review_quorum_state.optional_successes_observed >= .review_quorum_state.optional_successes_required or ((.review_quorum_state.waiver_ids // []) | length > 0))
    ' "$finalization_file" >/dev/null; then
    record_check "SYN-MUST-QUORUM" "MUST" "pass" "review quorum is met or explicitly waived"
  else
    record_check "SYN-MUST-QUORUM" "MUST" "fail" "review quorum is not met or waived"
    add_error "review_quorum_state must be met or explicitly waived before synthesis"
  fi

  traceability_path="$(resolve_path "$(jq -r '.traceability_path // empty' "$finalization_file")")"
  plan_path="$(resolve_path "$(jq -r '.final_artifacts[]? | select(.kind == "plan_artifact") | .path' "$finalization_file" | head -n 1)")"
  approval_path="$(resolve_path "$(jq -r '.final_artifacts[]? | select(.kind == "approval_ledger") | .path' "$finalization_file" | head -n 1)")"
  artifact_index_path="$(resolve_path "$(jq -r '.artifact_index_path // empty' "$finalization_file")")"
  synthesis_result_path="$(resolve_path "$(jq -r '.synthesis_result.path // empty' "$finalization_file")")"

  if require_json_file "plan artifact" "$plan_path"; then
    if jq -e '
        (.stage == "full_plan_ir" or .stage == "bead_export_ready")
        and ((.plan_items // []) | length > 0)
        and all(.plan_items[]; (((.source_refs // []) + (.provider_result_refs // []) + (.evidence_refs // []) + (.human_decision_ids // [])) | length) > 0)
      ' "$plan_path" >/dev/null; then
      record_check "SYN-MUST-PLAN-TRACEABLE" "MUST" "pass" "final plan items retain traceability anchors"
    else
      record_check "SYN-MUST-PLAN-TRACEABLE" "MUST" "fail" "final plan items lack traceability anchors"
      add_error "plan artifact must be full_plan_ir or bead_export_ready and every plan item needs traceability anchors"
    fi

    if jq -e '((.acceptance_criteria // []) | length > 0) and ((.test_matrix // []) | length > 0) and ((.rollback_points // []) | length > 0)' "$plan_path" >/dev/null; then
      record_check "SYN-MUST-HANDOFF-SECTIONS" "MUST" "pass" "final plan includes acceptance criteria, test matrix, and rollback points"
    else
      record_check "SYN-MUST-HANDOFF-SECTIONS" "MUST" "fail" "final plan misses handoff sections"
      add_error "plan artifact must include acceptance_criteria, test_matrix, and rollback_points"
    fi
  else
    record_check "SYN-MUST-PLAN-TRACEABLE" "MUST" "fail" "plan artifact missing"
    record_check "SYN-MUST-HANDOFF-SECTIONS" "MUST" "fail" "plan artifact missing"
  fi

  if require_json_file "traceability matrix" "$traceability_path"; then
    if jq -e '((.requirements // []) | length > 0) and ((.final_plan_items // []) | length > 0) and ((.tests // []) | length > 0) and ((.contradiction_resolutions // []) | length > 0)' "$traceability_path" >/dev/null; then
      record_check "SYN-MUST-TRACEABILITY" "MUST" "pass" "traceability matrix covers requirements, final items, tests, and contradiction resolutions"
    else
      record_check "SYN-MUST-TRACEABILITY" "MUST" "fail" "traceability matrix is incomplete"
      add_error "traceability matrix must include requirements, final_plan_items, tests, and contradiction_resolutions"
    fi
  else
    record_check "SYN-MUST-TRACEABILITY" "MUST" "fail" "traceability matrix missing"
  fi

  if require_json_file "synthesis provider result" "$synthesis_result_path"; then
    if jq -e --arg route "$synthesis_route_id" --arg result_id "$synthesis_provider_result_id" --arg evidence_id "$synthesis_evidence_id" '
        .provider_slot == $route
        and .provider_result_id == $result_id
        and .evidence_id == $evidence_id
        and .status == "success"
        and .synthesis_eligible == true
        and .reasoning_effort_verified == true
      ' "$synthesis_result_path" >/dev/null; then
      record_check "SYN-MUST-SYNTHESIS-RESULT" "MUST" "pass" "synthesis provider result is successful, eligible, and evidence-linked"
    else
      record_check "SYN-MUST-SYNTHESIS-RESULT" "MUST" "fail" "synthesis provider result is not eligible"
      add_error "synthesis provider result must be successful, synthesis_eligible, effort-verified, and evidence-linked"
    fi
  else
    record_check "SYN-MUST-SYNTHESIS-RESULT" "MUST" "fail" "synthesis provider result missing"
  fi

  if jq -e --arg evidence_id "$synthesis_evidence_id" '.final_handoff_gate.state == "ready" and ((.final_handoff_gate.required_evidence_ids // []) | index($evidence_id))' "$finalization_file" >/dev/null; then
    record_check "SYN-MUST-FINAL-HANDOFF" "MUST" "pass" "final handoff gate includes synthesis evidence after the synthesis call"
  else
    record_check "SYN-MUST-FINAL-HANDOFF" "MUST" "fail" "final handoff gate lacks synthesis evidence"
    add_error "final_handoff_gate must be ready and require the synthesis evidence id"
  fi

  if require_json_file "approval ledger" "$approval_path"; then
    if jq -e --slurpfile finalization "$finalization_file" '
        . as $ledger
        | ($finalization[0].final_handoff_gate.approval_ids // []) as $ids
        | ($ids | length > 0)
        and all($ids[]; . as $id | any($ledger.approvals[]?; .approval_id == $id and .decision == "approved"))
      ' "$approval_path" >/dev/null; then
      record_check "SYN-MUST-APPROVAL" "MUST" "pass" "handoff approval ids resolve to approved ledger entries"
    else
      record_check "SYN-MUST-APPROVAL" "MUST" "fail" "handoff approval ids are missing or unresolved"
      add_error "final_handoff_gate.approval_ids must resolve to approved approval-ledger entries"
    fi
  else
    record_check "SYN-MUST-APPROVAL" "MUST" "fail" "approval ledger missing"
  fi

  if require_json_file "artifact index" "$artifact_index_path"; then
    missing_artifacts=()
    while IFS= read -r artifact_id; do
      if [[ "$artifact_id" != "" ]] && ! has_artifact_id "$artifact_index_path" "$artifact_id"; then
        missing_artifacts+=("$artifact_id")
      fi
    done < <(jq -r '.final_artifacts[]?.artifact_id // empty' "$finalization_file")
    if [[ ${#missing_artifacts[@]} -eq 0 ]]; then
      record_check "SYN-MUST-ARTIFACT-INDEX" "MUST" "pass" "all final artifacts are indexed"
    else
      record_check "SYN-MUST-ARTIFACT-INDEX" "MUST" "fail" "final artifacts are missing from artifact index"
      add_error "final artifacts missing from artifact index: ${missing_artifacts[*]}"
    fi
  else
    record_check "SYN-MUST-ARTIFACT-INDEX" "MUST" "fail" "artifact index missing"
  fi

  if jq -e '((.implementation_notes // []) | length > 0)' "$finalization_file" >/dev/null; then
    record_check "SYN-SHOULD-IMPLEMENTATION-NOTES" "SHOULD" "pass" "implementation notes are present"
  else
    record_check "SYN-SHOULD-IMPLEMENTATION-NOTES" "SHOULD" "fail" "implementation notes are missing"
    add_warning "implementation_notes should be present for handoff"
  fi
fi

errors_json="$(json_messages "synthesis_finalization_failed" "${errors[@]}")"
warnings_json="$(json_messages "synthesis_finalization_warning" "${warnings[@]}")"
checks_json="$(json_checks)"
coverage_json="$(json_coverage)"
ok=false
if [[ ${#errors[@]} -eq 0 ]]; then
  ok=true
fi

envelope_json="$(jq -n \
  --argjson ok "$ok" \
  --arg schema_version "$schema_version" \
  --arg bundle_version "$VERSION" \
  --arg finalization_path "$finalization_file" \
  --arg route_id "$synthesis_route_id" \
  --arg provider_result_id "$synthesis_provider_result_id" \
  --arg evidence_id "$synthesis_evidence_id" \
  --arg prompt_sha256 "$prompt_sha256" \
  --argjson final_artifact_count "$final_artifact_count" \
  --argjson degradation_count "$degradation_count" \
  --argjson checks "$checks_json" \
  --argjson coverage "$coverage_json" \
  --argjson errors "$errors_json" \
  --argjson warnings "$warnings_json" \
  '{
    ok: $ok,
    schema_version: $schema_version,
    data: {
      finalization_path: $finalization_path,
      synthesis_route_id: $route_id,
      synthesis_provider_result_id: $provider_result_id,
      synthesis_evidence_id: $evidence_id,
      synthesis_prompt_sha256: $prompt_sha256,
      final_artifact_count: $final_artifact_count,
      degradation_label_count: $degradation_count,
      conformance_checks: $checks,
      conformance_coverage: $coverage
    },
    meta: {
      tool: "synthesis-finalization-check",
      bundle_version: $bundle_version
    },
    warnings: $warnings,
    errors: $errors,
    commands: {
      next: "PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/synthesis-finalization-check.sh --json",
      fix: (if $ok then null else "fix listed synthesis readiness, quorum, traceability, artifact index, or handoff violations" end)
    },
    blocked_reason: (if $ok then null else "synthesis_finalization_failed" end),
    next_command: (if $ok then null else "PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/synthesis-finalization-check.sh --json" end),
    fix_command: (if $ok then null else "fix listed synthesis readiness, quorum, traceability, artifact index, or handoff violations" end),
    retry_safe: true
  }')"

if [[ "$output_json" -eq 1 ]]; then
  printf '%s\n' "$envelope_json"
else
  if [[ "$ok" == "true" ]]; then
    printf 'synthesis finalization ok: route %s, result %s, artifacts %s\n' "$synthesis_route_id" "$synthesis_provider_result_id" "$final_artifact_count"
  else
    jq -r '.errors[].message' <<<"$envelope_json" >&2
  fi
fi

if [[ "$ok" == "true" ]]; then
  exit 0
fi
exit 1
