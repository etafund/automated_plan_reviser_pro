#!/usr/bin/env bats
# test_v18_model_policy.bats - Unit tests for model/thinking_time policy (bd-19x)

load '../helpers/test_helper'

setup() {
    setup_test_environment
    log_test_start "${BATS_TEST_NAME}"
    
    mkdir -p .apr/workflows
    echo "default_workflow: test" > .apr/config.yaml
    echo "test" > README.md
    echo "test" > SPEC.md
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

@test "apr lint warns on weak model" {
    cat > .apr/workflows/test.yaml <<EOF
readme: README.md
spec: SPEC.md
model: gpt-3.5-turbo
output_dir: rounds
EOF
    run "${PROJECT_ROOT}/apr" lint -w test 1
    assert_success
    assert_output --partial "Model 'gpt-3.5-turbo' may produce lower quality refinements"
}

@test "apr lint warns on missing thinking_time" {
    cat > .apr/workflows/test.yaml <<EOF
readme: README.md
spec: SPEC.md
model: o1-preview
output_dir: rounds
EOF
    run "${PROJECT_ROOT}/apr" lint -w test 1
    assert_success
    assert_output --partial "Thinking time not specified"
}

@test "apr lint warns on low thinking_time" {
    cat > .apr/workflows/test.yaml <<EOF
readme: README.md
spec: SPEC.md
model: o1-preview
thinking_time: 45
output_dir: rounds
EOF
    run "${PROJECT_ROOT}/apr" lint -w test 1
    assert_success
    assert_output --partial "Low thinking time: 45s"
}

@test "apr lint allows weak model with APR_ALLOW_NONPRO_MODELS=1" {
    cat > .apr/workflows/test.yaml <<EOF
readme: README.md
spec: SPEC.md
model: gpt-3.5-turbo
output_dir: rounds
EOF
    export APR_ALLOW_NONPRO_MODELS=1
    run "${PROJECT_ROOT}/apr" lint -w test 1
    assert_success
    refute_output --partial "Model 'gpt-3.5-turbo' may produce lower quality refinements"
}

@test "apr lint allows low thinking_time with APR_ALLOW_LIGHT_THINKING=1" {
    cat > .apr/workflows/test.yaml <<EOF
readme: README.md
spec: SPEC.md
model: o1-preview
thinking_time: 10
output_dir: rounds
EOF
    export APR_ALLOW_LIGHT_THINKING=1
    run "${PROJECT_ROOT}/apr" lint -w test 1
    assert_success
    refute_output --partial "Low thinking time: 10s"
}

@test "apr lint passes on high-quality config" {
    cat > .apr/workflows/test.yaml <<EOF
readme: README.md
spec: SPEC.md
model: "GPT Pro 5.2 Thinking"
thinking_time: 120
output_dir: rounds
EOF
    run "${PROJECT_ROOT}/apr" lint -w test 1
    assert_success
    assert_output --partial "Lint passed for workflow 'test'"
    refute_output --partial "WARN"
}
