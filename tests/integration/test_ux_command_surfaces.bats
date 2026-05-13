#!/usr/bin/env bats

load '../helpers/test_helper'

setup() {
    setup_test_environment
    start_test_artifacts "integration" "${BATS_TEST_NAME}"
    export APR_NO_GUM=1
    export NO_COLOR=1
    export CI=true
    cd "$TEST_PROJECT" || return
}

assert_no_ansi_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        if perl -ne 'exit 0 if /\x1b\[/; END { exit 1 }' "$file" 2>/dev/null; then
            printf 'ANSI escape sequence found in %s\n' "$file" >&2
            sed -n '1,5p' "$file" >&2
            return 1
        fi
    fi
}

assert_lines_at_most() {
    local file="$1"
    local max_width="$2"
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if ((${#line} > max_width)); then
            printf 'line exceeds %s columns: %s\n' "$max_width" "$line" >&2
            return 1
        fi
    done <"$file"
}

run_ux_case() {
    local label="$1"
    shift
    local case_dir="${ARTIFACT_DIR}/${label}"
    mkdir -p "$case_dir"
    {
        printf 'command:'
        printf ' %q' "$@"
        printf '\n'
    } >"${case_dir}/cmdline.txt"
    env | sort >"${case_dir}/env.txt"

    CASE_STATUS=0
    "$@" >"${case_dir}/stdout.log" 2>"${case_dir}/stderr.log" || CASE_STATUS=$?
    {
        cat "${case_dir}/stdout.log"
        cat "${case_dir}/stderr.log"
    } >"${case_dir}/combined.log"
}

run_ux_case_with_stdin() {
    local label="$1"
    local stdin_data="$2"
    shift 2
    local case_dir="${ARTIFACT_DIR}/${label}"
    mkdir -p "$case_dir"
    {
        printf 'command:'
        printf ' %q' "$@"
        printf '\n'
    } >"${case_dir}/cmdline.txt"
    env | sort >"${case_dir}/env.txt"
    printf '%s' "$stdin_data" >"${case_dir}/stdin.txt"

    CASE_STATUS=0
    printf '%s' "$stdin_data" | "$@" >"${case_dir}/stdout.log" 2>"${case_dir}/stderr.log" || CASE_STATUS=$?
    {
        cat "${case_dir}/stdout.log"
        cat "${case_dir}/stderr.log"
    } >"${case_dir}/combined.log"
}

write_ux_metrics() {
    local metrics_dir="$TEST_PROJECT/.apr/analytics/default"
    mkdir -p "$metrics_dir"
    cat >"${metrics_dir}/metrics.json" <<'JSON'
{
  "schema_version": "1.0.0",
  "workflow": "default",
  "created_at": "2026-01-13T04:00:00Z",
  "updated_at": "2026-01-13T04:40:00Z",
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
JSON
}

seed_setup_docs() {
    cat >README.md <<'EOF'
# UX Setup Fixture

Fixture README for APR setup command integration coverage.
EOF
    cat >SPECIFICATION.md <<'EOF'
# Specification

Fixture specification for APR setup command integration coverage.
EOF
    cat >IMPLEMENTATION.md <<'EOF'
# Implementation

Fixture implementation notes for APR setup command integration coverage.
EOF
}

@test "ux integration: stats desktop and compact render stable human layouts" {
    setup_test_workflow "default"
    write_ux_metrics

    run_ux_case "stats_desktop" env APR_TERM_COLUMNS=120 APR_TERM_LINES=32 "$APR_SCRIPT" --desktop stats
    [ "$CASE_STATUS" -eq 0 ]
    [ ! -s "${ARTIFACT_DIR}/stats_desktop/stdout.log" ]
    grep -F "REVISION STATISTICS: default" "${ARTIFACT_DIR}/stats_desktop/stderr.log"
    grep -F "TREND SPARKLINES" "${ARTIFACT_DIR}/stats_desktop/stderr.log"
    grep -F "ROUND DETAILS" "${ARTIFACT_DIR}/stats_desktop/stderr.log"
    assert_no_ansi_file "${ARTIFACT_DIR}/stats_desktop/stderr.log"
    assert_lines_at_most "${ARTIFACT_DIR}/stats_desktop/stderr.log" 120

    run_ux_case "stats_compact" env APR_TERM_COLUMNS=72 APR_TERM_LINES=18 "$APR_SCRIPT" --compact stats
    [ "$CASE_STATUS" -eq 0 ]
    [ ! -s "${ARTIFACT_DIR}/stats_compact/stdout.log" ]
    grep -F "STATS: default" "${ARTIFACT_DIR}/stats_compact/stderr.log"
    grep -F "Recent rounds" "${ARTIFACT_DIR}/stats_compact/stderr.log"
    grep -F "Next: apr run" "${ARTIFACT_DIR}/stats_compact/stderr.log"
    if grep -F "ROUND DETAILS" "${ARTIFACT_DIR}/stats_compact/stderr.log"; then
        false
    fi
    assert_no_ansi_file "${ARTIFACT_DIR}/stats_compact/stderr.log"
    assert_lines_at_most "${ARTIFACT_DIR}/stats_compact/stderr.log" 80
}

@test "ux integration: dashboard non-tty fallback is actionable in both layouts" {
    setup_test_workflow "default"
    write_ux_metrics

    run_ux_case "dashboard_desktop" env APR_TERM_COLUMNS=120 APR_TERM_LINES=32 "$APR_SCRIPT" --desktop dashboard
    [ "$CASE_STATUS" -ne 0 ]
    [ ! -s "${ARTIFACT_DIR}/dashboard_desktop/stdout.log" ]
    grep -F "Dashboard requires an interactive terminal" "${ARTIFACT_DIR}/dashboard_desktop/stderr.log"
    grep -F "Use 'apr stats' for non-interactive output" "${ARTIFACT_DIR}/dashboard_desktop/stderr.log"
    assert_no_ansi_file "${ARTIFACT_DIR}/dashboard_desktop/stderr.log"

    run_ux_case "dashboard_compact" env APR_TERM_COLUMNS=72 APR_TERM_LINES=18 "$APR_SCRIPT" --compact dashboard
    [ "$CASE_STATUS" -ne 0 ]
    [ ! -s "${ARTIFACT_DIR}/dashboard_compact/stdout.log" ]
    grep -F "Dashboard requires an interactive terminal" "${ARTIFACT_DIR}/dashboard_compact/stderr.log"
    grep -F "Use 'apr stats' for non-interactive output" "${ARTIFACT_DIR}/dashboard_compact/stderr.log"
    assert_no_ansi_file "${ARTIFACT_DIR}/dashboard_compact/stderr.log"
    assert_lines_at_most "${ARTIFACT_DIR}/dashboard_compact/stderr.log" 80
}

@test "ux integration: setup wizard stays plain and creates workflows in both layouts" {
    local layout project input

    for layout in desktop compact; do
        project="${TEST_DIR}/setup_${layout}"
        mkdir -p "$project"
        cd "$project"
        seed_setup_docs
        input="workflow_${layout}

README.md
SPECIFICATION.md
n
1
"

        run_ux_case_with_stdin "setup_${layout}" "$input" env APR_TERM_COLUMNS=80 APR_TERM_LINES=24 "$APR_SCRIPT" "--${layout}" setup
        [ "$CASE_STATUS" -eq 0 ]
        [ -f ".apr/workflows/workflow_${layout}.yaml" ]
        grep -F "Workflow 'workflow_${layout}' created successfully!" "${ARTIFACT_DIR}/setup_${layout}/combined.log"
        grep -F "workflow_${layout}" "${ARTIFACT_DIR}/setup_${layout}/combined.log"
        assert_no_ansi_file "${ARTIFACT_DIR}/setup_${layout}/combined.log"
        assert_lines_at_most "${ARTIFACT_DIR}/setup_${layout}/combined.log" 100
    done
}

@test "ux integration: help compact is dense and desktop is detailed" {
    run_ux_case "help_compact" env APR_TERM_COLUMNS=72 APR_TERM_LINES=18 "$APR_SCRIPT" --compact --help
    [ "$CASE_STATUS" -eq 0 ]
    [ ! -s "${ARTIFACT_DIR}/help_compact/stdout.log" ]
    grep -F "SYNOPSIS" "${ARTIFACT_DIR}/help_compact/stderr.log"
    grep -F "COMMANDS" "${ARTIFACT_DIR}/help_compact/stderr.log"
    grep -F "run <round>" "${ARTIFACT_DIR}/help_compact/stderr.log"
    grep -F "providers <cmd>" "${ARTIFACT_DIR}/help_compact/stderr.log"
    grep -F "(Run 'apr help --detailed' for full descriptions)" "${ARTIFACT_DIR}/help_compact/stderr.log"
    if grep -F "EXIT CODES" "${ARTIFACT_DIR}/help_compact/stderr.log"; then
        false
    fi
    assert_no_ansi_file "${ARTIFACT_DIR}/help_compact/stderr.log"
    assert_lines_at_most "${ARTIFACT_DIR}/help_compact/stderr.log" 80

    run_ux_case "help_desktop" env APR_TERM_COLUMNS=120 APR_TERM_LINES=32 "$APR_SCRIPT" --desktop --help
    [ "$CASE_STATUS" -eq 0 ]
    [ ! -s "${ARTIFACT_DIR}/help_desktop/stdout.log" ]
    grep -F "DESCRIPTION" "${ARTIFACT_DIR}/help_desktop/stderr.log"
    grep -F "COMMANDS" "${ARTIFACT_DIR}/help_desktop/stderr.log"
    grep -F "EXIT CODES" "${ARTIFACT_DIR}/help_desktop/stderr.log"
    grep -F "APR_ERROR_CODE=" "${ARTIFACT_DIR}/help_desktop/stderr.log"
    assert_no_ansi_file "${ARTIFACT_DIR}/help_desktop/stderr.log"
    assert_lines_at_most "${ARTIFACT_DIR}/help_desktop/stderr.log" 120
}
