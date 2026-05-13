#!/usr/bin/env bats
# test_errors_golden.bats
#
# Golden-artifact pin for the APR error taxonomy table emitted by
# apr_error_code_table (lib/errors.sh).
#
# Bead automated_plan_reviser_pro-viak.
#
# This complements test_errors_metamorphic.bats (property layer) with a
# BYTE-EXACT SNAPSHOT layer: any add/remove/rename of a code, any
# exit-code reshuffle, any meaning rewrite will surface as a unified
# diff against tests/fixtures/errors/error_code_table.golden.
#
# Refresh procedure (when the taxonomy legitimately changes)
# ----------------------------------------------------------
#   bash -c 'source lib/errors.sh; apr_error_code_table' \
#       > tests/fixtures/errors/error_code_table.golden
#
# Then update test_errors_metamorphic.bats accordingly (the property
# layer enforces totality + canonical exit set) and commit both files
# in the same change so reviewers see the deliberate taxonomy edit.

load '../helpers/test_helper'

setup() {
    setup_test_environment
    start_test_artifacts "unit" "${BATS_TEST_NAME}"

    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../lib/errors.sh"

    GOLDEN_FILE="$BATS_TEST_DIRNAME/../fixtures/errors/error_code_table.golden"
    export GOLDEN_FILE

    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# ===========================================================================
# Byte-exact match of the canonical taxonomy snapshot.
# ===========================================================================

@test "apr_error_code_table output matches tests/fixtures/errors/error_code_table.golden byte-for-byte" {
    [[ -r "$GOLDEN_FILE" ]] || {
        echo "Golden file missing: $GOLDEN_FILE" >&2
        return 1
    }
    local actual_file
    actual_file="$TEST_DIR/error_code_table.actual"
    apr_error_code_table > "$actual_file"
    if ! diff -u "$GOLDEN_FILE" "$actual_file" >&2; then
        cat >&2 <<'HINT'

The APR error taxonomy has drifted from its golden snapshot.

If this drift is INTENTIONAL (a code was added/removed/renamed or an
exit code legitimately changed), refresh the golden:

    bash -c 'source lib/errors.sh; apr_error_code_table' \
        > tests/fixtures/errors/error_code_table.golden

Then update test_errors_metamorphic.bats CANONICAL_EXIT_SET if you
changed the exit-code domain, and commit BOTH files together so the
deliberate taxonomy edit is visible to reviewers.

If this drift is NOT intentional, see lib/errors.sh — something
upstream is silently changing the contract.
HINT
        return 1
    fi
}

# ===========================================================================
# Golden file itself has expected shape (defense-in-depth: prevents an
# empty/corrupted golden from masking real drift).
# ===========================================================================

@test "golden file has the documented shape: >=12 rows, 3 tab-separated fields each" {
    [[ -r "$GOLDEN_FILE" ]] || return 1
    local n_lines
    n_lines=$(wc -l < "$GOLDEN_FILE" | tr -d ' ')
    [[ "$n_lines" -ge 12 ]] || {
        echo "Golden has $n_lines lines; expected >=12 (the documented taxonomy size)" >&2
        return 1
    }
    local line tabs
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        tabs="${line//[^$'\t']/}"
        [[ ${#tabs} -eq 2 ]] || {
            echo "Golden row has ${#tabs} tabs (want 2): '$line'" >&2
            return 1
        }
    done < "$GOLDEN_FILE"
}
