#!/usr/bin/env bash
set -euo pipefail

VERSION="v18.0.0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

PROFILE=""
CHECK_FIXTURES=0
RAW_ROUTE=0
JSON_OUTPUT=0
POLICY_PATH="${ROOT_DIR}/fixtures/provider-access-policy.json"
CAPABILITIES_PATH="${ROOT_DIR}/fixtures/route-compiler.capabilities.json"
SOURCE_BASELINE_PATH="${ROOT_DIR}/fixtures/source-baseline.json"
RUNTIME_BUDGET_PATH="${ROOT_DIR}/fixtures/runtime-budget.json"

usage() {
  cat <<'USAGE'
Usage:
  route-compiler-check.sh --check-fixtures [--json]
  route-compiler-check.sh --profile fast|balanced|audit [--json]
  route-compiler-check.sh --profile fast|balanced|audit --raw-route

Options:
  --policy PATH             Provider access policy fixture.
  --capabilities PATH       Route compiler capability-set fixture.
  --source-baseline PATH    Source baseline fixture.
  --runtime-budget PATH     Runtime budget fixture.
USAGE
}

die() {
  printf 'route-compiler-check: %s\n' "$*" >&2
  exit 2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

sha256_file() {
  local path="$1"
  local digest
  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(sha256sum "$path" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    digest="$(shasum -a 256 "$path" | awk '{print $1}')"
  else
    die "missing sha256sum or shasum"
  fi
  printf 'sha256:%s' "$digest"
}

sha256_text() {
  local digest
  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(printf '%s' "$1" | sha256sum | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    digest="$(printf '%s' "$1" | shasum -a 256 | awk '{print $1}')"
  else
    die "missing sha256sum or shasum"
  fi
  printf 'sha256:%s' "$digest"
}

short_hash() {
  local hash="${1#sha256:}"
  printf '%s' "${hash:0:12}"
}

profile_path() {
  printf '%s/fixtures/execution-profile.%s.json' "$ROOT_DIR" "$1"
}

route_fixture_path() {
  if [[ "$1" == "balanced" ]]; then
    printf '%s/fixtures/provider-route.balanced.compiler.json' "$ROOT_DIR"
  else
    printf '%s/fixtures/provider-route.%s.json' "$ROOT_DIR" "$1"
  fi
}

validate_profile_name() {
  case "$1" in
    fast|balanced|audit) ;;
    *) die "unknown profile: $1" ;;
  esac
}

json_errors_from_lines() {
  if (($# == 0)); then
    printf '[]'
    return
  fi
  printf '%s\n' "$@" | jq -R '{error_code:"validation_failed", message:.}' | jq -s .
}

emit_envelope() {
  local ok="$1"
  local data_json="$2"
  shift 2
  local errors=("$@")
  local warnings_json
  local errors_json
  local blocked_reason=""
  local next_command="bash scripts/route-compiler-check.sh --check-fixtures --json"
  local fix_command=""

  warnings_json="[]"
  errors_json="$(json_errors_from_lines "${errors[@]}")"
  if [[ "$ok" != "true" ]]; then
    blocked_reason="route_compiler_check_failed"
    fix_command="fix listed route compiler contract violations"
  fi

  jq -S -n \
    --arg ok "$ok" \
    --arg version "$VERSION" \
    --argjson data "$data_json" \
    --argjson warnings "$warnings_json" \
    --argjson errors "$errors_json" \
    --arg next_command "$next_command" \
    --arg fix_command "$fix_command" \
    --arg blocked_reason "$blocked_reason" '
      {
        ok: ($ok == "true"),
        schema_version: "json_envelope.v1",
        data: $data,
        meta: {
          tool: "route-compiler-check",
          bundle_version: $version
        },
        warnings: $warnings,
        errors: $errors,
        commands: {next: $next_command},
        next_command: (if $ok == "true" then null else $next_command end),
        fix_command: (if $fix_command == "" then null else $fix_command end),
        blocked_reason: (if $blocked_reason == "" then null else $blocked_reason end),
        retry_safe: ($ok == "true")
      }'
}

validate_input_files() {
  local profile="$1"
  local profile_file
  profile_file="$(profile_path "$profile")"
  local required_files=(
    "$POLICY_PATH"
    "$CAPABILITIES_PATH"
    "$SOURCE_BASELINE_PATH"
    "$RUNTIME_BUDGET_PATH"
    "$profile_file"
  )
  local path
  for path in "${required_files[@]}"; do
    [[ -r "$path" ]] || die "required input is not readable: $path"
    jq empty "$path" >/dev/null
  done
}

validate_capabilities() {
  local profile="$1"
  local profile_file
  profile_file="$(profile_path "$profile")"
  local errors=()
  local slot
  while IFS= read -r slot; do
    [[ -n "$slot" ]] || continue
    local status
    status="$(jq -r --arg slot "$slot" '
      .capabilities[]? | select(.provider_slot == $slot) | .status
    ' "$CAPABILITIES_PATH" | head -n 1)"
    if [[ "$status" != "ready" ]]; then
      errors+=("profile ${profile} slot ${slot} capability status must be ready, got ${status:-missing}")
    fi
  done < <(jq -r '.required_slots[]?, .optional_slots[]?' "$profile_file" | sort -u)

  if ((${#errors[@]} > 0)); then
    printf '%s\n' "${errors[@]}"
    return 1
  fi
}

compile_profile() {
  local profile="$1"
  validate_profile_name "$profile"
  validate_input_files "$profile"

  local profile_file
  profile_file="$(profile_path "$profile")"
  local profile_hash policy_hash capabilities_hash source_hash budget_hash compiler_input_hash
  profile_hash="$(sha256_file "$profile_file")"
  policy_hash="$(sha256_file "$POLICY_PATH")"
  capabilities_hash="$(sha256_file "$CAPABILITIES_PATH")"
  source_hash="$(sha256_file "$SOURCE_BASELINE_PATH")"
  budget_hash="$(sha256_file "$RUNTIME_BUDGET_PATH")"
  compiler_input_hash="$(sha256_text "${profile_hash}|${policy_hash}|${capabilities_hash}|${source_hash}|${budget_hash}")"

  local profile_hash_short policy_hash_short capabilities_hash_short source_hash_short budget_hash_short input_hash_short
  profile_hash_short="$(short_hash "$profile_hash")"
  policy_hash_short="$(short_hash "$policy_hash")"
  capabilities_hash_short="$(short_hash "$capabilities_hash")"
  source_hash_short="$(short_hash "$source_hash")"
  budget_hash_short="$(short_hash "$budget_hash")"
  input_hash_short="$(short_hash "$compiler_input_hash")"

  jq -S -n \
    --slurpfile policy "$POLICY_PATH" \
    --slurpfile profile_doc "$profile_file" \
    --slurpfile capabilities "$CAPABILITIES_PATH" \
    --slurpfile source_baseline "$SOURCE_BASELINE_PATH" \
    --slurpfile runtime_budget "$RUNTIME_BUDGET_PATH" \
    --arg bundle_version "$VERSION" \
    --arg profile "$profile" \
    --arg profile_hash "$profile_hash" \
    --arg policy_hash "$policy_hash" \
    --arg capabilities_hash "$capabilities_hash" \
    --arg source_hash "$source_hash" \
    --arg budget_hash "$budget_hash" \
    --arg compiler_input_hash "$compiler_input_hash" \
    --arg profile_hash_short "$profile_hash_short" \
    --arg policy_hash_short "$policy_hash_short" \
    --arg capabilities_hash_short "$capabilities_hash_short" \
    --arg source_hash_short "$source_hash_short" \
    --arg budget_hash_short "$budget_hash_short" \
    --arg input_hash_short "$input_hash_short" '
      def clean: with_entries(select(.value != null));
      def stage_order:
        ["intake","first_plan","independent_review","compare","synthesis","human_review","handoff"];
      def route_policy_projection($route):
        ($route | {
          access_path,
          api_allowed,
          api_equivalent_thinking_level,
          browser_effort_strategy,
          browser_mode,
          capability_probe_required,
          claude_code_keyword,
          effort,
          effort_rank_required,
          eligible_for_synthesis,
          evidence_required,
          model,
          model_selector,
          normalized_effort,
          official_api,
          oracle_allowed,
          provider_family,
          purpose,
          reasoning_content_policy,
          reasoning_effort,
          requested_reasoning_effort,
          search_enabled,
          search_mode,
          search_tool,
          thinking
        } | clean);
      def capability_for($slot):
        ($capabilities[0].capabilities // [] | map(select(.provider_slot == $slot)) | .[0] // {});
      def route_for($slot; $stage; $role; $required; $quorum; $depends):
        ($policy[0].live_routes[$slot] // {}) as $route |
        capability_for($slot) as $capability |
        ({
          route_id: ("route." + $profile + "." + $stage + "." + $slot),
          stage_id: ("stage." + $profile + "." + $stage),
          stage: $stage,
          slot: $slot,
          provider_role: $role,
          required: $required,
          quorum_candidate: $quorum,
          depends_on_stage_ids: $depends,
          invoke_after: (if $stage == "synthesis" then "compare_and_review_quorum" else null end),
          readiness_state: (if ($capability.status // "missing") == "ready" then "ready" else "blocked" end),
          capability_status: ($capability.status // "missing"),
          capability_ref: ($capability.input_ref // null),
          capability_checked_at: ($capability.checked_at // null),
          cache_key: ("route-cache.v1." + $profile + "." + $slot + "." + $policy_hash_short + "." + $capabilities_hash_short + "." + $source_hash_short + "." + $budget_hash_short)
        } | clean) + route_policy_projection($route);
      def shape($p):
        if $p == "fast" then {
          route_slots: [
            {slot:"codex_thinking_fast_draft", stage:"intake", role:"exploratory_context_draft", required:true, quorum:false, depends:[]},
            {slot:"chatgpt_pro_first_plan", stage:"first_plan", role:"optional_formal_first_plan_upgrade", required:false, quorum:false, depends:["stage.fast.intake"]}
          ],
          stage_required_slots: {intake:["codex_thinking_fast_draft"]},
          stage_optional_slots: {first_plan:["chatgpt_pro_first_plan"]},
          review_quorum: {
            independent_review_min_total: 0,
            independent_review_required_slots: [],
            independent_review_optional_slots: [],
            optional_review_min_successes: 0
          },
          fallback_policy: {
            fail_closed_for_required_browser_modes: true,
            codex_fast_draft_is_not_formal_first_plan: true,
            synthesis_requires_promotion_or_waiver: true
          },
          runtime_budget: {
            max_wall_minutes: 45,
            max_cost_usd: 0,
            browser_slots: ["chatgpt_pro_first_plan"],
            required_approvals: []
          },
          warnings: [
            "fast profile uses Codex CLI as exploratory context only; it cannot satisfy formal-first-plan or synthesis gates without explicit promotion or waiver"
          ]
        }
        elif $p == "balanced" then {
          route_slots: [
            {slot:"chatgpt_pro_first_plan", stage:"first_plan", role:"formal_first_plan", required:true, quorum:false, depends:[]},
            {slot:"gemini_deep_think", stage:"independent_review", role:"required_independent_review", required:true, quorum:true, depends:["stage.balanced.first_plan"]},
            {slot:"claude_code_opus", stage:"independent_review", role:"optional_independent_review", required:false, quorum:true, depends:["stage.balanced.first_plan"]},
            {slot:"xai_grok_reasoning", stage:"independent_review", role:"optional_independent_review", required:false, quorum:true, depends:["stage.balanced.first_plan"]},
            {slot:"deepseek_v4_pro_reasoning_search", stage:"independent_review", role:"optional_independent_review_with_search", required:false, quorum:true, depends:["stage.balanced.first_plan"]},
            {slot:"chatgpt_pro_synthesis", stage:"synthesis", role:"synthesis", required:true, quorum:false, depends:["stage.balanced.compare"]}
          ],
          stage_required_slots: {
            first_plan:["chatgpt_pro_first_plan"],
            independent_review:["gemini_deep_think"],
            synthesis:["chatgpt_pro_synthesis"]
          },
          stage_optional_slots: {
            independent_review:["claude_code_opus","xai_grok_reasoning","deepseek_v4_pro_reasoning_search"]
          },
          review_quorum: {
            independent_review_min_total: 2,
            independent_review_required_slots: ["gemini_deep_think"],
            independent_review_optional_slots: ["claude_code_opus","xai_grok_reasoning","deepseek_v4_pro_reasoning_search"],
            optional_review_min_successes: 1
          },
          fallback_policy: {
            fail_closed_for_required_browser_modes: true,
            prompt_pack_for_optional: true,
            waiver_required_for_missing_optional_quorum: true
          },
          runtime_budget: {
            max_wall_minutes: 180,
            max_cost_usd: 50,
            browser_slots: ["chatgpt_pro_first_plan","gemini_deep_think","chatgpt_pro_synthesis"],
            required_approvals: ["live_fanout"]
          },
          warnings: [
            "v17: local mock route readiness is not live-provider readiness; run live-cutover checklist before release"
          ]
        }
        elif $p == "audit" then {
          route_slots: [
            {slot:"chatgpt_pro_first_plan", stage:"first_plan", role:"formal_first_plan", required:true, quorum:false, depends:[]},
            {slot:"gemini_deep_think", stage:"independent_review", role:"required_independent_review", required:true, quorum:true, depends:["stage.audit.first_plan"]},
            {slot:"claude_code_opus", stage:"independent_review", role:"required_independent_review", required:true, quorum:true, depends:["stage.audit.first_plan"]},
            {slot:"xai_grok_reasoning", stage:"independent_review", role:"required_independent_review", required:true, quorum:true, depends:["stage.audit.first_plan"]},
            {slot:"deepseek_v4_pro_reasoning_search", stage:"independent_review", role:"required_independent_review_with_search", required:true, quorum:true, depends:["stage.audit.first_plan"]},
            {slot:"chatgpt_pro_synthesis", stage:"synthesis", role:"synthesis", required:true, quorum:false, depends:["stage.audit.compare"]}
          ],
          stage_required_slots: {
            first_plan:["chatgpt_pro_first_plan"],
            independent_review:["gemini_deep_think","claude_code_opus","xai_grok_reasoning","deepseek_v4_pro_reasoning_search"],
            synthesis:["chatgpt_pro_synthesis"]
          },
          stage_optional_slots: {},
          review_quorum: {
            independent_review_min_total: 4,
            independent_review_required_slots: ["gemini_deep_think","claude_code_opus","xai_grok_reasoning","deepseek_v4_pro_reasoning_search"],
            independent_review_optional_slots: [],
            optional_review_min_successes: 0
          },
          fallback_policy: {
            fail_closed_for_required_browser_modes: true,
            optional_prompt_pack_allowed: false,
            waiver_requires_human_approval: true,
            provider_docs_refresh_required: true
          },
          runtime_budget: {
            max_wall_minutes: 360,
            max_cost_usd: 80,
            browser_slots: ["chatgpt_pro_first_plan","gemini_deep_think","chatgpt_pro_synthesis"],
            required_approvals: ["live_fanout","provider_docs_freshness","audit_waiver_review"]
          },
          warnings: [
            "audit profile requires fresh provider docs snapshots before live provider calls",
            "audit profile treats all independent reviewers as required unless a human-approved waiver is recorded"
          ]
        }
        else error("unknown profile " + $p)
        end;
      shape($profile) as $shape |
      {
        schema_version: "provider_route.v1",
        bundle_version: $bundle_version,
        profile: $profile,
        source_policy: ($profile_doc[0].source_policy // "baseline"),
        route_plan_id: ("route-plan." + $profile + "." + $input_hash_short),
        compiler: {
          schema_version: "route_compiler.v1",
          deterministic: true,
          input_hash: $compiler_input_hash,
          compile_rule: "profile+provider-policy+capability-set+source-baseline+runtime-budget -> provider-route"
        },
        input_hashes: {
          execution_profile: $profile_hash,
          provider_access_policy: $policy_hash,
          capability_set: $capabilities_hash,
          source_baseline: $source_hash,
          runtime_budget: $budget_hash
        },
        capability_set_id: ($capabilities[0].capability_set_id // null),
        required_slots: ($profile_doc[0].required_slots // []),
        optional_slots: ($profile_doc[0].optional_slots // []),
        stage_order: stage_order,
        stage_required_slots: $shape.stage_required_slots,
        stage_optional_slots: $shape.stage_optional_slots,
        routes: ($shape.route_slots | map(route_for(.slot; .stage; .role; .required; .quorum; .depends))),
        review_quorum: $shape.review_quorum,
        review_quorum_policy: "fixtures/review-quorum.balanced.json",
        fallback_policy: $shape.fallback_policy,
        runtime_budget: $shape.runtime_budget,
        resource_locks: (
          if $profile == "fast" then []
          else ["browser:shared-profile:chatgpt","browser:shared-profile:gemini"]
          end
        ),
        readiness_contract: {
          preflight_ready_scope: "profile_route_compiled",
          synthesis_requires: ["normalized_provider_results","compare_result","review_quorum_met_or_waived"],
          final_handoff_requires: ["verified_synthesis_evidence","human_review_packet","approval_ledger_final_handoff"]
        },
        warnings: $shape.warnings
      }'
}

profile_data_json() {
  local profile="$1"
  local route_json="$2"
  jq -S -n \
    --arg profile "$profile" \
    --arg fixture "fixtures/provider-route.${profile}.json" \
    --argjson route "$route_json" \
    '{profile: $profile, fixture: $fixture, route_plan: $route}'
}

check_fixtures() {
  local errors=()
  local profiles=(fast balanced audit)
  local profile
  for profile in "${profiles[@]}"; do
    local fixture
    fixture="$(route_fixture_path "$profile")"
    if [[ ! -r "$fixture" ]]; then
      errors+=("missing route fixture for ${profile}: ${fixture}")
      continue
    fi
    local capability_errors
    if ! capability_errors="$(validate_capabilities "$profile")"; then
      errors+=("$capability_errors")
      continue
    fi
    local actual expected
    actual="$(compile_profile "$profile")"
    expected="$(jq -S '.' "$fixture")"
    if [[ "$actual" != "$expected" ]]; then
      errors+=("provider-route ${profile} compiler golden is not byte-stable with compiler output; rerun: bash scripts/route-compiler-check.sh --profile ${profile} --raw-route")
    fi
  done

  local ok="true"
  if ((${#errors[@]} > 0)); then
    ok="false"
  fi
  local data_json
  data_json="$(jq -S -n --argjson count "${#profiles[@]}" '{checked_profiles: ["fast","balanced","audit"], fixture_count: $count}')"
  if [[ "$JSON_OUTPUT" == "1" ]]; then
    emit_envelope "$ok" "$data_json" "${errors[@]}"
  elif [[ "$ok" == "true" ]]; then
    printf 'ok\n'
  else
    printf '%s\n' "${errors[@]}"
  fi

  [[ "$ok" == "true" ]]
}

while (($# > 0)); do
  case "$1" in
    --profile)
      [[ $# -ge 2 ]] || die "--profile requires a value"
      PROFILE="$2"
      shift 2
      ;;
    --check-fixtures)
      CHECK_FIXTURES=1
      shift
      ;;
    --raw-route)
      RAW_ROUTE=1
      shift
      ;;
    --json)
      JSON_OUTPUT=1
      shift
      ;;
    --policy)
      [[ $# -ge 2 ]] || die "--policy requires a path"
      POLICY_PATH="$2"
      shift 2
      ;;
    --capabilities)
      [[ $# -ge 2 ]] || die "--capabilities requires a path"
      CAPABILITIES_PATH="$2"
      shift 2
      ;;
    --source-baseline)
      [[ $# -ge 2 ]] || die "--source-baseline requires a path"
      SOURCE_BASELINE_PATH="$2"
      shift 2
      ;;
    --runtime-budget)
      [[ $# -ge 2 ]] || die "--runtime-budget requires a path"
      RUNTIME_BUDGET_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

require_cmd jq

if [[ -z "$PROFILE" && "$CHECK_FIXTURES" == "0" ]]; then
  CHECK_FIXTURES=1
fi

if [[ "$CHECK_FIXTURES" == "1" ]]; then
  check_fixtures
  exit $?
fi

validate_profile_name "$PROFILE"
capability_errors=""
if ! capability_errors="$(validate_capabilities "$PROFILE")"; then
  if [[ "$JSON_OUTPUT" == "1" ]]; then
    emit_envelope "false" '{}' "$capability_errors"
  else
    printf '%s\n' "$capability_errors"
  fi
  exit 1
fi

route_json="$(compile_profile "$PROFILE")"
if [[ "$RAW_ROUTE" == "1" ]]; then
  printf '%s\n' "$route_json"
elif [[ "$JSON_OUTPUT" == "1" ]]; then
  data_json="$(profile_data_json "$PROFILE" "$route_json")"
  emit_envelope "true" "$data_json"
else
  printf 'ok\n'
fi
