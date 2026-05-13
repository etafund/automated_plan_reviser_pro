#!/usr/bin/env bats
# test_v18_ledger_integration.bats - Integration tests for ledger provenance

load '../helpers/test_helper'

setup() {
    setup_test_environment
    log_test_start "${BATS_TEST_NAME}"
    
    # Setup mock workflow
    mkdir -p .apr/workflows
    echo "default_workflow: test" > .apr/config.yaml
    cat > .apr/workflows/test.yaml <<EOF
readme: README.md
spec: SPEC.md
model: gpt-4
output_dir: rounds
EOF
    echo "test" > README.md
    echo "test" > SPEC.md
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

@test "apr run 1 creates a started ledger entry" {
    mkdir -p bin
    echo "#!/bin/sh" > bin/oracle
    echo "exit 1" >> bin/oracle
    chmod +x bin/oracle
    
    PATH="./bin:$PATH" run "${PROJECT_ROOT}/apr" run 1 --wait --no-lint --no-preflight
    
    [ -f ".apr/rounds/test/round_1.meta.json" ]
    grep -q '"state":"' ".apr/rounds/test/round_1.meta.json"
}

@test "apr run 1 records finished state on Oracle success" {
    mkdir -p bin
    echo "#!/bin/sh" > bin/oracle
    echo "exit 0" >> bin/oracle
    chmod +x bin/oracle
    
    PATH="./bin:$PATH" run "${PROJECT_ROOT}/apr" run 1 --wait --no-lint --no-preflight
    
    [ -f ".apr/rounds/test/round_1.meta.json" ]
    grep -q '"state":"finished"' ".apr/rounds/test/round_1.meta.json"
    grep -q '"ok":true' ".apr/rounds/test/round_1.meta.json"
}
