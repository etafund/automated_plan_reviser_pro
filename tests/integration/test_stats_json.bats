#!/usr/bin/env bats
# test_stats_json.bats - Integration tests for stats JSON output
#
# Tests: apr stats --json and --export json

# Load test helpers
load '../helpers/test_helper'

# =============================================================================
# Setup and Teardown
# =============================================================================

setup() {
    setup_test_environment
    log_test_start "${BATS_TEST_NAME}"

    if ! command -v jq >/dev/null 2>&1; then
        skip "jq not available"
    fi

    cd "$TEST_PROJECT"
    setup_test_workflow "default"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# =============================================================================
# Tests
# =============================================================================

write_compact_stats_metrics() {
    local metrics_dir="$TEST_PROJECT/.apr/analytics/default"
    local ts="2026-01-13T04:00:00Z"
    mkdir -p "$metrics_dir"

    cat > "$metrics_dir/metrics.json" << EOF
{
  "schema_version": "1.0.0",
  "workflow": "default",
  "created_at": "$ts",
  "updated_at": "$ts",
  "rounds": [
    {
      "round": 1,
      "timestamp": "2026-01-13T04:00:00Z",
      "output": {"char_count": 9000},
      "changes_from_previous": null
    },
    {
      "round": 2,
      "timestamp": "2026-01-13T04:10:00Z",
      "output": {"char_count": 8200},
      "changes_from_previous": {
        "lines_added": 120,
        "lines_deleted": 30,
        "diff_ratio": 0.52,
        "similarity_score": 0.58
      }
    },
    {
      "round": 3,
      "timestamp": "2026-01-13T04:20:00Z",
      "output": {"char_count": 7100},
      "changes_from_previous": {
        "lines_added": 80,
        "lines_deleted": 42,
        "diff_ratio": 0.34,
        "similarity_score": 0.72
      }
    },
    {
      "round": 4,
      "timestamp": "2026-01-13T04:30:00Z",
      "output": {"char_count": 6900},
      "changes_from_previous": {
        "lines_added": 35,
        "lines_deleted": 18,
        "diff_ratio": 0.22,
        "similarity_score": 0.84
      }
    },
    {
      "round": 5,
      "timestamp": "2026-01-13T04:40:00Z",
      "output": {"char_count": 6600},
      "changes_from_previous": {
        "lines_added": 20,
        "lines_deleted": 12,
        "diff_ratio": 0.15,
        "similarity_score": 0.91
      }
    }
  ],
  "convergence": {
    "detected": true,
    "confidence": 0.78,
    "estimated_rounds_remaining": 2,
    "signals": {
      "output_size_trend": 0.82,
      "change_velocity": 0.76,
      "similarity_trend": 0.88
    }
  }
}
EOF
}

@test "apr stats --json: outputs empty object when metrics missing" {
    capture_streams "$APR_SCRIPT" stats --json

    log_test_actual "stdout" "$CAPTURED_STDOUT"
    log_test_actual "stderr" "$CAPTURED_STDERR"

    assert_valid_json "$CAPTURED_STDOUT"
    # Empty JSON object
    [[ "$(echo "$CAPTURED_STDOUT" | jq -r 'keys | length')" -eq 0 ]]
}

@test "apr stats --export json: outputs metrics JSON" {
    # Initialize metrics (--export requires metrics to exist)
    setup_test_metrics "default"

    run "$APR_SCRIPT" stats --export json

    log_test_output "$output"

    assert_success
    assert_valid_json "$output"
    assert_json_field_exists "$output" ".schema_version"
    assert_json_field_exists "$output" ".rounds"
}

@test "apr stats --compact: renders narrow single-column human layout" {
    write_compact_stats_metrics

    capture_streams "$APR_SCRIPT" stats --compact

    log_test_actual "stdout" "$CAPTURED_STDOUT"
    log_test_actual "stderr" "$CAPTURED_STDERR"

    [[ "$CAPTURED_STATUS" -eq 0 ]]
    [[ -z "$CAPTURED_STDOUT" ]]
    [[ "$CAPTURED_STDERR" == *"STATS: default"* ]]
    [[ "$CAPTURED_STDERR" == *"Rounds: 5"* ]]
    [[ "$CAPTURED_STDERR" == *"Confidence: 78%"* ]]
    [[ "$CAPTURED_STDERR" == *"Trends: size down, change flat, sim up"* ]]
    [[ "$CAPTURED_STDERR" == *"Recent rounds"* ]]
    [[ "$CAPTURED_STDERR" == *"#5 6.4K, changes +20-12, sim 0.91"* ]]
    [[ "$CAPTURED_STDERR" == *"Next: apr run 6"* ]]
    [[ "$CAPTURED_STDERR" != *"ROUND DETAILS"* ]]
    [[ "$CAPTURED_STDERR" != *"│"* ]]

    local line
    while IFS= read -r line; do
        [[ ${#line} -le 80 ]]
    done <<< "$CAPTURED_STDERR"
}
