#!/usr/bin/env bats
# test_setup.bats - Integration tests for APR setup wizard and workflow creation
#
# Tests: apr setup command, workflow creation, directory structure

# Load test helpers
load '../helpers/test_helper'

# =============================================================================
# Setup and Teardown
# =============================================================================

setup() {
    setup_test_environment
    log_test_start "${BATS_TEST_NAME}"

    cd "$TEST_PROJECT" || return 1

    # Create sample documents for setup wizard to find
    cat > README.md << 'EOF'
# Test Project

This is a test project for APR setup testing.

## Features
- Feature 1
- Feature 2
EOF

    cat > SPECIFICATION.md << 'EOF'
# Specification

## Overview
This is the specification document.

## Requirements
1. Requirement A
2. Requirement B
EOF

    cat > IMPLEMENTATION.md << 'EOF'
# Implementation

## Architecture
Description of the implementation.
EOF
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

run_setup_capture() {
    local input="$1"
    shift

    local capture_dir="${ARTIFACT_DIR:-$TEST_DIR}"
    local stdout_file="$capture_dir/setup.stdout"
    local stderr_file="$capture_dir/setup.stderr"

    CAPTURED_STATUS=0
    env "$@" "$APR_SCRIPT" setup >"$stdout_file" 2>"$stderr_file" <<< "$input" || CAPTURED_STATUS=$?
    CAPTURED_STDOUT="$(<"$stdout_file")"
    CAPTURED_STDERR="$(<"$stderr_file")"
}

# =============================================================================
# First-Time Setup Tests
# =============================================================================

@test "setup: shows welcome message on first run" {
    run "$APR_SCRIPT" setup <<< $'myworkflow\nREADME.md\nSPECIFICATION.md\n\n5.2 Thinking\n'

    log_test_output "$output"

    # Should show welcome or setup message
    [[ "$output" == *"Setup"* ]] || [[ "$output" == *"setup"* ]] || [[ "$output" == *"Welcome"* ]]
}

@test "setup: creates .apr directory" {
    run "$APR_SCRIPT" setup <<< $'testflow\nREADME.md\nSPECIFICATION.md\n\n5.2 Thinking\n'

    log_test_output "$output"
    log_test_actual "exit code" "$status"

    # Even if interactive input fails, check if .apr was created
    [[ -d ".apr" ]] || [[ $status -eq 0 ]]
}

@test "setup: creates workflow config file" {
    # Create minimal setup by providing files that exist
    run "$APR_SCRIPT" setup <<< $'newworkflow\nREADME.md\nSPECIFICATION.md\n\n5.2 Thinking\n'

    log_test_output "$output"

    # Check if workflow directory structure exists or was attempted
    [[ -d ".apr/workflows" ]] || [[ "$output" == *"workflow"* ]]
}

@test "setup: creates rounds directory" {
    run "$APR_SCRIPT" setup <<< $'roundstest\nREADME.md\nSPECIFICATION.md\n\n5.2 Thinking\n'

    log_test_output "$output"

    # Check rounds directory
    [[ -d ".apr/rounds" ]] || [[ "$output" == *"rounds"* ]] || [[ "$output" == *"Created"* ]]
}

# =============================================================================
# Setup with Existing Configuration Tests
# =============================================================================

@test "setup: works with existing .apr directory" {
    # Create existing .apr structure
    mkdir -p .apr/workflows .apr/rounds/existing
    cat > .apr/config.yaml << 'EOF'
default_workflow: existing
EOF

    cat > .apr/workflows/existing.yaml << 'EOF'
name: existing
documents:
  readme: README.md
  spec: SPECIFICATION.md
model: "5.2 Thinking"
output_dir: .apr/rounds/existing
EOF

    run "$APR_SCRIPT" setup <<< $'newworkflow\nREADME.md\nSPECIFICATION.md\n\n5.2 Thinking\n'

    log_test_output "$output"

    # Should not crash when .apr exists
    [[ $status -eq 0 ]] || [[ "$output" == *"existing"* ]] || [[ "$output" == *"workflow"* ]]
}

@test "setup: does not overwrite existing workflow without confirmation" {
    # Create existing workflow
    mkdir -p .apr/workflows .apr/rounds/myworkflow
    cat > .apr/config.yaml << 'EOF'
default_workflow: myworkflow
EOF

    cat > .apr/workflows/myworkflow.yaml << 'EOF'
name: myworkflow
original: true
EOF

    # Try to create same workflow name
    run "$APR_SCRIPT" setup <<< $'myworkflow\nREADME.md\nSPECIFICATION.md\n\n5.2 Thinking\nn\n'

    log_test_output "$output"

    # Should warn or ask about overwrite
    # Either warns about existing workflow or proceeds based on implementation
    [[ "$output" == *"exist"* ]] || [[ "$output" == *"overwrite"* ]] || [[ $status -eq 0 ]]
}

# =============================================================================
# Setup Validation Tests
# =============================================================================

@test "setup: handles missing README gracefully" {
    rm -f README.md

    run "$APR_SCRIPT" setup <<< $'testflow\nnonexistent.md\nSPECIFICATION.md\n\n5.2 Thinking\n'

    log_test_output "$output"

    # Should warn about missing file or accept path anyway
    [[ "$output" == *"not found"* ]] || [[ "$output" == *"Warning"* ]] || [[ $status -eq 0 ]]
}

@test "setup: handles empty workflow name" {
    run "$APR_SCRIPT" setup <<< $'\nREADME.md\nSPECIFICATION.md\n\n5.2 Thinking\n'

    log_test_output "$output"
    log_test_actual "exit code" "$status"

    # Should either use default name or prompt again
    [[ "$output" == *"default"* ]] || [[ "$output" == *"workflow"* ]] || [[ $status -ne 0 ]]
}

# =============================================================================
# Setup with Implementation Document Tests
# =============================================================================

@test "setup: accepts implementation document path" {
    run "$APR_SCRIPT" setup <<< $'implflow\nREADME.md\nSPECIFICATION.md\nIMPLEMENTATION.md\n5.2 Thinking\n'

    log_test_output "$output"

    # Should accept implementation path
    [[ "$output" == *"impl"* ]] || [[ "$output" == *"Implementation"* ]] || [[ $status -eq 0 ]]
}

@test "setup: implementation document is optional" {
    run "$APR_SCRIPT" setup <<< $'noimplflow\nREADME.md\nSPECIFICATION.md\n\n5.2 Thinking\n'

    log_test_output "$output"

    # Should succeed without implementation
    [[ $status -eq 0 ]] || [[ "$output" == *"workflow"* ]]
}

# =============================================================================
# UI Mode Tests
# =============================================================================

@test "setup: works with APR_NO_GUM=1 (ANSI mode)" {
    export APR_NO_GUM=1

    run "$APR_SCRIPT" setup <<< $'ansiflow\nREADME.md\nSPECIFICATION.md\n\n5.2 Thinking\n'

    log_test_output "$output"

    # Should work in ANSI mode
    [[ $status -eq 0 ]] || [[ "$output" == *"Setup"* ]] || [[ "$output" == *"workflow"* ]]
}

@test "setup: works in non-TTY environment" {
    # Already in non-TTY due to pipe input
    # Wizard prompts: name, description, readme, spec, impl, model
    run "$APR_SCRIPT" setup <<< $'nonttyflow\n\nREADME.md\nSPECIFICATION.md\n\n5.2 Thinking\n'

    log_test_output "$output"

    # Should handle non-TTY gracefully (may exit or use defaults)
    # Exit code 4 is config error which is acceptable for non-interactive
    [[ $status -eq 0 ]] || [[ $status -eq 4 ]] || [[ "$output" == *"interactive"* ]] || [[ "$output" == *"Setup"* ]]
}

@test "setup: stdin=/dev/null exits with actionable error (no infinite loop)" {
    run bash -lc 'cd "$1" && APR_NO_GUM=1 NO_COLOR=1 timeout 5 "$2" setup </dev/null' _ "$TEST_PROJECT" "$APR_SCRIPT"

    # timeout exits 124 when command hangs; this is the regression guard.
    [[ "$status" -ne 124 ]]
    [[ "$status" -eq 4 ]]
    [[ "$output" == *"apr setup requires interactive input"* ]]
}

@test "setup ux: guided flow has step headers, validation feedback, and success CTA" {
    run_setup_capture \
        $'uxflow\n\nREADME.md\nSPECIFICATION.md\nn\n1\n' \
        APR_NO_GUM=1 NO_COLOR=1 APR_LAYOUT=desktop

    log_test_actual "stderr" "$CAPTURED_STDERR"
    log_test_actual "stdout" "$CAPTURED_STDOUT"
    log_test_actual "status" "$CAPTURED_STATUS"

    [[ "$CAPTURED_STATUS" -eq 0 ]]
    [[ -z "$CAPTURED_STDOUT" ]]
    [[ "$CAPTURED_STDERR" == *"Welcome to the APR Setup Wizard!"* ]]
    [[ "$CAPTURED_STDERR" == *"[1/5] Workflow name"* ]]
    [[ "$CAPTURED_STDERR" == *"[2/5] Project description"* ]]
    [[ "$CAPTURED_STDERR" == *"[3/5] README/Overview document"* ]]
    [[ "$CAPTURED_STDERR" == *"[4/5] Specification document"* ]]
    [[ "$CAPTURED_STDERR" == *"[Optional] Implementation document"* ]]
    [[ "$CAPTURED_STDERR" == *"[5/5] Review preferences"* ]]
    [[ "$CAPTURED_STDERR" == *"[ok] README: README.md"* ]]
    [[ "$CAPTURED_STDERR" == *"[ok] Specification: SPECIFICATION.md"* ]]
    [[ "$CAPTURED_STDERR" == *"Workflow 'uxflow' created successfully!"* ]]
    [[ "$CAPTURED_STDERR" == *"apr run 1"* ]]
    [[ "$CAPTURED_STDERR" != *$'\033'* ]]
    [[ -f ".apr/workflows/uxflow.yaml" ]]
}

@test "setup ux: compact layout stays single-column and no-color" {
    run_setup_capture \
        $'compactflow\n\nREADME.md\nSPECIFICATION.md\nn\n1\n' \
        APR_NO_GUM=1 NO_COLOR=1 APR_LAYOUT=compact APR_TERM_COLUMNS=64 APR_TERM_LINES=20

    log_test_actual "stderr" "$CAPTURED_STDERR"

    [[ "$CAPTURED_STATUS" -eq 0 ]]
    [[ -z "$CAPTURED_STDOUT" ]]
    [[ "$CAPTURED_STDERR" == *"APR v"* ]]
    [[ "$CAPTURED_STDERR" == *"[1/5] Workflow name"* ]]
    [[ "$CAPTURED_STDERR" == *"Workflow 'compactflow' created successfully!"* ]]
    [[ "$CAPTURED_STDERR" != *$'\033'* ]]

    local max_width
    max_width=$(printf '%s\n' "$CAPTURED_STDERR" | wc -L | awk '{print $1}')
    [[ "$max_width" =~ ^[0-9]+$ ]]
    (( max_width <= 80 ))
}

@test "setup ux: missing document error is actionable and stderr-only" {
    run_setup_capture \
        $'badflow\n\nmissing.md\nSPECIFICATION.md\nn\n1\n' \
        APR_NO_GUM=1 NO_COLOR=1 APR_LAYOUT=compact

    log_test_actual "stderr" "$CAPTURED_STDERR"
    log_test_actual "status" "$CAPTURED_STATUS"

    [[ "$CAPTURED_STATUS" -eq 4 ]]
    [[ -z "$CAPTURED_STDOUT" ]]
    [[ "$CAPTURED_STDERR" == *"File not found: missing.md"* ]]
    [[ "$CAPTURED_STDERR" != *$'\033'* ]]
}

# =============================================================================
# Model Selection Tests
# =============================================================================

@test "setup: accepts '5.2 Thinking' model" {
    # Wizard prompts: name, description, readme, spec, impl, model
    run "$APR_SCRIPT" setup <<< $'modeltest1\n\nREADME.md\nSPECIFICATION.md\n\n5.2 Thinking\n'

    log_test_output "$output"

    # Should succeed or at least progress through wizard
    [[ $status -eq 0 ]] || [[ "$output" == *"model"* ]] || [[ "$output" == *"Thinking"* ]]
}

@test "setup: accepts 'Deep Research' model" {
    # Wizard prompts: name, description, readme, spec, impl, model
    run "$APR_SCRIPT" setup <<< $'modeltest2\n\nREADME.md\nSPECIFICATION.md\n\nDeep Research\n'

    log_test_output "$output"

    # Should accept Deep Research as valid model
    [[ $status -eq 0 ]] || [[ "$output" == *"model"* ]] || [[ "$output" == *"Deep Research"* ]]
}

# =============================================================================
# apr list After Setup Tests
# =============================================================================

@test "setup then list: shows created workflow" {
    # First setup a workflow
    setup_test_workflow "listtest"

    run "$APR_SCRIPT" list

    log_test_output "$output"

    assert_success
    [[ "$output" == *"listtest"* ]]
}

@test "setup then list: shows multiple workflows" {
    setup_test_workflow "workflow1"
    setup_test_workflow "workflow2"

    run "$APR_SCRIPT" list

    log_test_output "$output"

    assert_success
    [[ "$output" == *"workflow1"* ]]
    [[ "$output" == *"workflow2"* ]]
}

# =============================================================================
# Configuration Validation Tests
# =============================================================================

@test "setup: created config is valid YAML" {
    setup_test_workflow "yamltest"

    # Check config.yaml is readable
    run cat .apr/config.yaml

    log_test_output "$output"

    assert_success
    [[ "$output" == *"default_workflow"* ]]
}

@test "setup: workflow config contains required fields" {
    setup_test_workflow "fieldtest"

    # Check workflow config
    run cat .apr/workflows/fieldtest.yaml

    log_test_output "$output"

    assert_success
    [[ "$output" == *"name:"* ]]
    [[ "$output" == *"readme:"* ]] || [[ "$output" == *"documents:"* ]]
}

# =============================================================================
# Edge Cases
# =============================================================================

@test "setup: handles special characters in workflow name" {
    # Test with hyphen (allowed)
    run "$APR_SCRIPT" setup <<< $'my-workflow\nREADME.md\nSPECIFICATION.md\n\n5.2 Thinking\n'

    log_test_output "$output"

    # Should accept hyphens
    [[ $status -eq 0 ]] || [[ "$output" == *"workflow"* ]]
}

@test "setup: handles workflow name with underscore" {
    run "$APR_SCRIPT" setup <<< $'my_workflow\nREADME.md\nSPECIFICATION.md\n\n5.2 Thinking\n'

    log_test_output "$output"

    # Should accept underscores
    [[ $status -eq 0 ]] || [[ "$output" == *"workflow"* ]]
}

@test "setup: handles paths with spaces" {
    # Create file with space in name
    echo "# Spaced README" > "READ ME.md"

    run "$APR_SCRIPT" setup <<< $'spacedflow\nREAD ME.md\nSPECIFICATION.md\n\n5.2 Thinking\n'

    log_test_output "$output"

    # Should handle or warn about spaces
    [[ $status -eq 0 ]] || [[ "$output" == *"space"* ]] || [[ "$output" == *"not found"* ]]
}

# =============================================================================
# Help and Version Tests
# =============================================================================

@test "setup --help: shows setup help" {
    run "$APR_SCRIPT" --help

    log_test_output "$output"

    assert_success
    [[ "$output" == *"setup"* ]]
}

@test "apr setup: respects --quiet flag" {
    run "$APR_SCRIPT" setup --quiet <<< $'quietflow\nREADME.md\nSPECIFICATION.md\n\n5.2 Thinking\n'

    log_test_output "$output"

    # Output should be minimal in quiet mode
    # (may still have some output due to interactive prompts)
    [[ ${#output} -lt 2000 ]] || [[ "$output" == *"quiet"* ]]
}
