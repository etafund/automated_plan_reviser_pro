#!/usr/bin/env bats
# test_update.bats
#
# Bead automated_plan_reviser_pro-0fm:
# Unit tests for the self-update and update-check code paths in `apr`.
#
# We exercise the real apr script end-to-end but intercept curl/wget via
# PATH with a mock that returns canned responses keyed on the requested
# URL. This is a "real binary, fake transport" setup: the network layer is
# the only thing we mock, every other branch (version compare, shebang
# check, bash -n syntax check, checksum verify, temp cleanup, exit codes)
# is exercised against the actual code in `apr`.

load '../helpers/test_helper'

# ---------------------------------------------------------------------------
# Mock curl
# ---------------------------------------------------------------------------

# install_mock_curl - install a curl shim in $TEST_DIR/bin that:
#   - if MOCK_CURL_DIR is set, treats it as a URL->file map
#       (last path segment of the URL is the filename to serve)
#   - otherwise returns exit 22 to simulate a 404 / network failure
#
# Special env knobs:
#   MOCK_CURL_DIR        directory containing canned response files
#   MOCK_CURL_LOG        if set, every invocation appends a line here
#   MOCK_CURL_FORCE_FAIL if "1", always exit nonzero (simulate timeout)
install_mock_curl() {
    local bin_dir="$TEST_DIR/bin"
    mkdir -p "$bin_dir"

    cat > "$bin_dir/curl" <<'MOCK'
#!/usr/bin/env bash
# Test-only curl shim. Honors -o <file> and writes the canned response
# either to that file or to stdout. URL is taken to be the last positional
# argument that starts with http.
set -euo pipefail

log_line() {
    if [[ -n "${MOCK_CURL_LOG:-}" ]]; then
        printf '%s\n' "$*" >> "$MOCK_CURL_LOG"
    fi
}

if [[ "${MOCK_CURL_FORCE_FAIL:-}" == "1" ]]; then
    log_line "FAIL $*"
    exit 7   # arbitrary nonzero; curl(1) uses 7 for "could not connect"
fi

# Pull the URL and any -o target out of the argv.
url=""
out=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o)
            out="$2"; shift 2;;
        --)
            shift; break;;
        http*://*)
            url="$1"; shift;;
        *)
            shift;;
    esac
done

log_line "URL=$url OUT=${out:-stdout}"

if [[ -z "$url" ]]; then
    exit 6
fi

if [[ -z "${MOCK_CURL_DIR:-}" || ! -d "$MOCK_CURL_DIR" ]]; then
    exit 22
fi

# Map URL -> filename. Use last URL segment as the cache key.
name="${url##*/}"
file="$MOCK_CURL_DIR/$name"

if [[ ! -f "$file" ]]; then
    exit 22  # simulates HTTP 404
fi

if [[ -n "$out" ]]; then
    cp -- "$file" "$out"
else
    cat -- "$file"
fi
MOCK
    chmod +x "$bin_dir/curl"

    # Prepend so it wins over /usr/bin/curl.
    export PATH="$bin_dir:$PATH"

    # Hide wget so the apr code path falls through to curl deterministically.
    # If wget is in /usr/bin, drop a no-op shim that exits 1.
    cat > "$bin_dir/wget" <<'WGET'
#!/usr/bin/env bash
exit 1
WGET
    chmod +x "$bin_dir/wget"
}

# write_canned <name> <content> - drop a canned response file the mock
# curl shim will serve under that URL-last-segment name.
write_canned() {
    local name="$1"; shift
    local content="$*"
    [[ -d "${MOCK_CURL_DIR:-}" ]] || MOCK_CURL_DIR="$TEST_DIR/canned"
    mkdir -p "$MOCK_CURL_DIR"
    export MOCK_CURL_DIR
    printf '%s' "$content" > "$MOCK_CURL_DIR/$name"
}

# write_canned_file <name> <path>
write_canned_file() {
    local name="$1" src="$2"
    [[ -d "${MOCK_CURL_DIR:-}" ]] || MOCK_CURL_DIR="$TEST_DIR/canned"
    mkdir -p "$MOCK_CURL_DIR"
    export MOCK_CURL_DIR
    cp -- "$src" "$MOCK_CURL_DIR/$name"
}

# apr_local_version - current version baked into the real apr script.
apr_local_version() {
    grep -m1 '^VERSION=' "$APR_SCRIPT" | sed -E 's/.*"([^"]+)".*/\1/'
}

# install_apr_copy - clone apr into a writable temp location so update's
# mv-to-script-path branch can succeed without touching the real binary.
install_apr_copy() {
    local dest="$TEST_DIR/install"
    mkdir -p "$dest"
    cp -- "$APR_SCRIPT" "$dest/apr"
    chmod +x "$dest/apr"
    APR_UNDER_TEST="$dest/apr"
    export APR_UNDER_TEST
}

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
    setup_test_environment
    start_test_artifacts "unit" "${BATS_TEST_NAME}"
    install_mock_curl
    export MOCK_CURL_LOG="$TEST_DIR/curl.log"
    : > "$MOCK_CURL_LOG"

    # Make APR_HOME isolated so .last_update_check is per-test.
    export APR_HOME="$TEST_DIR/apr_home"
    mkdir -p "$APR_HOME"

    # cmd_update prints banners; force non-gum, non-color, non-interactive.
    export APR_NO_GUM=1
    export NO_COLOR=1
    export CI=true
    unset APR_CHECK_UPDATES 2>/dev/null || true

    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    save_artifact "$MOCK_CURL_LOG" "curl.log"
    [[ -d "${APR_HOME:-}" ]] && save_artifact "$APR_HOME" "apr_home"
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# ---------------------------------------------------------------------------
# version_gt (utility used by both check_for_updates and cmd_update)
# ---------------------------------------------------------------------------

@test "version_gt: 1.2.3 > 1.2.2" {
    load_apr_functions
    run version_gt "1.2.3" "1.2.2"
    [[ "$status" -eq 0 ]]
}

@test "version_gt: equal versions return 1" {
    load_apr_functions
    run version_gt "1.2.3" "1.2.3"
    [[ "$status" -eq 1 ]]
}

@test "version_gt: smaller is not greater" {
    load_apr_functions
    run version_gt "1.2.1" "1.2.2"
    [[ "$status" -eq 1 ]]
}

@test "version_gt: ignores trailing non-numeric suffix (1.2.3-beta vs 1.2.2)" {
    load_apr_functions
    run version_gt "1.2.3-beta" "1.2.2"
    [[ "$status" -eq 0 ]]
}

@test "version_gt: shorter version padded with zeros (2 > 1.9.9)" {
    load_apr_functions
    run version_gt "2" "1.9.9"
    [[ "$status" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# check_for_updates: opt-in + throttling
# ---------------------------------------------------------------------------

# Use `apr list` to exercise check_for_updates: --version short-circuits
# in the leading-flag loop before main() reaches the update check, so any
# test that needs to observe check_for_updates side effects must run a
# command that survives that loop. `list` is benign and exits 0 even with
# no configured workflows.

@test "check_for_updates: APR_CHECK_UPDATES unset is a no-op (no network call)" {
    # No APR_CHECK_UPDATES → must return without calling curl.
    run_with_artifacts "$APR_SCRIPT" list
    [[ "$status" -eq 0 ]]

    # Mock curl was never asked anything.
    [[ ! -s "$MOCK_CURL_LOG" ]] || {
        echo "curl was called but should not have been:" >&2
        cat "$MOCK_CURL_LOG" >&2
        return 1
    }

    # And no timestamp file should be written.
    [[ ! -f "$APR_HOME/.last_update_check" ]]
}

@test "check_for_updates: APR_CHECK_UPDATES=1 + no check file → network call + timestamp written" {
    write_canned "VERSION" "$(apr_local_version)"

    APR_CHECK_UPDATES=1 run_with_artifacts "$APR_SCRIPT" list
    [[ "$status" -eq 0 ]]

    # Mock curl was called at least once for the VERSION URL.
    grep -q 'URL=.*/main/VERSION' "$MOCK_CURL_LOG" || {
        echo "expected a VERSION fetch in curl.log:" >&2
        cat "$MOCK_CURL_LOG" >&2
        return 1
    }

    # Timestamp file was written.
    [[ -s "$APR_HOME/.last_update_check" ]]
}

@test "check_for_updates: recent timestamp short-circuits the network call" {
    # Stamp the check file as "just now".
    date +%s > "$APR_HOME/.last_update_check"

    APR_CHECK_UPDATES=1 run_with_artifacts "$APR_SCRIPT" list
    [[ "$status" -eq 0 ]]

    # No curl invocation for VERSION because we were throttled.
    if grep -q 'URL=.*/main/VERSION' "$MOCK_CURL_LOG"; then
        echo "throttling should have skipped the network call:" >&2
        cat "$MOCK_CURL_LOG" >&2
        return 1
    fi
}

@test "check_for_updates: stale timestamp (>24h) re-issues the network call" {
    write_canned "VERSION" "$(apr_local_version)"
    # Put the timestamp two days ago.
    local two_days_ago=$(( $(date +%s) - 172800 ))
    echo "$two_days_ago" > "$APR_HOME/.last_update_check"

    APR_CHECK_UPDATES=1 run_with_artifacts "$APR_SCRIPT" list
    [[ "$status" -eq 0 ]]

    grep -q 'URL=.*/main/VERSION' "$MOCK_CURL_LOG" || {
        echo "stale timestamp should have re-fetched VERSION:" >&2
        cat "$MOCK_CURL_LOG" >&2
        return 1
    }
}

@test "check_for_updates: newer remote prints 'Update available'" {
    # Pick a clearly larger version than whatever the local one is so
    # version_gt unambiguously fires.
    write_canned "VERSION" "99.0.0"

    APR_CHECK_UPDATES=1 run_with_artifacts "$APR_SCRIPT" list
    [[ "$status" -eq 0 ]]

    grep -Fq "Update available" "$ARTIFACT_DIR/stderr.log" || {
        echo "expected 'Update available' on stderr:" >&2
        cat "$ARTIFACT_DIR/stderr.log" >&2
        return 1
    }
}

@test "check_for_updates: identical remote does not announce an update" {
    write_canned "VERSION" "$(apr_local_version)"
    APR_CHECK_UPDATES=1 run_with_artifacts "$APR_SCRIPT" list
    [[ "$status" -eq 0 ]]
    ! grep -Fq "Update available" "$ARTIFACT_DIR/stderr.log"
}

@test "check_for_updates: older remote does not announce an update" {
    write_canned "VERSION" "0.0.1"
    APR_CHECK_UPDATES=1 run_with_artifacts "$APR_SCRIPT" list
    [[ "$status" -eq 0 ]]
    ! grep -Fq "Update available" "$ARTIFACT_DIR/stderr.log"
}

@test "check_for_updates: network failure does not crash apr" {
    # Force the mock curl to fail with a connection error.
    MOCK_CURL_FORCE_FAIL=1 APR_CHECK_UPDATES=1 \
        run_with_artifacts "$APR_SCRIPT" list

    [[ "$status" -eq 0 ]]
    # And the function still writes the throttle timestamp (best effort).
    [[ -s "$APR_HOME/.last_update_check" ]]
}

# ---------------------------------------------------------------------------
# cmd_update: error paths (network, version sanity, same/older)
# ---------------------------------------------------------------------------

@test "cmd_update: network error exits with EXIT_NETWORK_ERROR (10)" {
    install_apr_copy
    MOCK_CURL_FORCE_FAIL=1 \
        run_with_artifacts "$APR_UNDER_TEST" update
    [[ "$status" -eq 10 ]] || {
        echo "expected exit 10 (EXIT_NETWORK_ERROR), got $status" >&2
        cat "$ARTIFACT_DIR/stderr.log" >&2
        return 1
    }
    grep -Fq "network error" "$ARTIFACT_DIR/stderr.log"
}

@test "cmd_update: invalid remote version string exits with EXIT_UPDATE_ERROR (11)" {
    install_apr_copy
    # A bogus remote version that contains a forbidden character.
    write_canned "VERSION" "not a version"

    run_with_artifacts "$APR_UNDER_TEST" update
    [[ "$status" -eq 11 ]] || {
        echo "expected exit 11, got $status; stderr:" >&2
        cat "$ARTIFACT_DIR/stderr.log" >&2
        return 1
    }
    grep -Fq "invalid" "$ARTIFACT_DIR/stderr.log"
}

@test "cmd_update: same remote version reports 'Already up to date' and exits 0" {
    install_apr_copy
    write_canned "VERSION" "$(apr_local_version)"

    run_with_artifacts "$APR_UNDER_TEST" update
    [[ "$status" -eq 0 ]] || {
        echo "expected exit 0 on same version, got $status" >&2
        cat "$ARTIFACT_DIR/stderr.log" >&2
        return 1
    }
    grep -Fq "Already up to date" "$ARTIFACT_DIR/stderr.log"
}

@test "cmd_update: older remote version exits 0 without installing" {
    install_apr_copy
    write_canned "VERSION" "0.0.1"

    # Snapshot the file so we can prove it was not touched.
    local sha_before
    sha_before=$(sha256sum "$APR_UNDER_TEST" | cut -d' ' -f1)

    run_with_artifacts "$APR_UNDER_TEST" update
    [[ "$status" -eq 0 ]]
    grep -Fq "newer than remote" "$ARTIFACT_DIR/stderr.log"

    local sha_after
    sha_after=$(sha256sum "$APR_UNDER_TEST" | cut -d' ' -f1)
    [[ "$sha_before" == "$sha_after" ]] || {
        echo "apr was modified despite older-remote no-op" >&2
        return 1
    }
}

# ---------------------------------------------------------------------------
# cmd_update: shebang + syntax validation on downloaded payload
# ---------------------------------------------------------------------------

# write_fake_release - drop a "new apr" payload + version under canned/
write_fake_release() {
    local version="$1" payload="$2"
    write_canned "VERSION" "$version"
    write_canned "apr" "$payload"
}

@test "cmd_update: rejects download missing a bash shebang" {
    install_apr_copy
    # First line is a /bin/sh shebang → must be refused.
    local payload=$'#!/bin/sh\necho hi\n'
    write_fake_release "99.0.0" "$payload"

    run_with_artifacts "$APR_UNDER_TEST" update
    [[ "$status" -eq 11 ]]
    grep -Fq "not a valid apr script" "$ARTIFACT_DIR/stderr.log"
}

@test "cmd_update: rejects download with no shebang at all" {
    install_apr_copy
    write_fake_release "99.0.0" $'echo hi\n'

    run_with_artifacts "$APR_UNDER_TEST" update
    [[ "$status" -eq 11 ]]
    grep -Fq "not a valid apr script" "$ARTIFACT_DIR/stderr.log"
}

@test "cmd_update: accepts #!/bin/bash shebang" {
    install_apr_copy
    write_fake_release "99.0.0" $'#!/bin/bash\necho new\n'
    # No checksum URL → we expect "Checksum not available" warning + success.

    run_with_artifacts "$APR_UNDER_TEST" update
    [[ "$status" -eq 0 ]] || {
        echo "expected exit 0 on valid bash shebang, got $status" >&2
        cat "$ARTIFACT_DIR/stderr.log" >&2
        return 1
    }
    # File was replaced with the new bash payload.
    head -1 "$APR_UNDER_TEST" | grep -Fq '#!/bin/bash'
}

@test "cmd_update: accepts #!/usr/bin/env bash shebang" {
    install_apr_copy
    write_fake_release "99.0.0" $'#!/usr/bin/env bash\necho new env\n'

    run_with_artifacts "$APR_UNDER_TEST" update
    [[ "$status" -eq 0 ]]
    head -1 "$APR_UNDER_TEST" | grep -Fq '#!/usr/bin/env bash'
}

@test "cmd_update: rejects payload that fails bash -n syntax check" {
    install_apr_copy
    # Valid shebang but the body is not parseable bash.
    write_fake_release "99.0.0" $'#!/usr/bin/env bash\nif [[ then echo bad fi\n'

    run_with_artifacts "$APR_UNDER_TEST" update
    [[ "$status" -eq 11 ]]
    grep -Fq "failed bash syntax check" "$ARTIFACT_DIR/stderr.log"
}

# ---------------------------------------------------------------------------
# cmd_update: checksum verification
# ---------------------------------------------------------------------------

@test "cmd_update: matching checksum passes and installs" {
    install_apr_copy
    local payload=$'#!/usr/bin/env bash\necho new\n'
    write_fake_release "99.0.0" "$payload"

    # Serve a matching sha256 for the apr payload.
    local hash
    hash=$(printf '%s' "$payload" | sha256sum | cut -d' ' -f1)
    write_canned "apr.sha256" "$hash"

    run_with_artifacts "$APR_UNDER_TEST" update
    [[ "$status" -eq 0 ]] || {
        echo "expected exit 0; stderr:" >&2
        cat "$ARTIFACT_DIR/stderr.log" >&2
        return 1
    }
    grep -Fq "Checksum verified" "$ARTIFACT_DIR/stderr.log"
    grep -Fq "echo new" "$APR_UNDER_TEST"
}

@test "cmd_update: checksum mismatch refuses install and exits 11" {
    install_apr_copy
    local payload=$'#!/usr/bin/env bash\necho new\n'
    write_fake_release "99.0.0" "$payload"

    # Serve a sha256 for some *other* content.
    local bogus
    bogus=$(printf 'not the right file' | sha256sum | cut -d' ' -f1)
    write_canned "apr.sha256" "$bogus"

    # Snapshot original.
    local sha_before
    sha_before=$(sha256sum "$APR_UNDER_TEST" | cut -d' ' -f1)

    run_with_artifacts "$APR_UNDER_TEST" update
    [[ "$status" -eq 11 ]] || {
        echo "expected exit 11 on checksum mismatch, got $status" >&2
        cat "$ARTIFACT_DIR/stderr.log" >&2
        return 1
    }
    grep -Fq "Checksum verification failed" "$ARTIFACT_DIR/stderr.log"

    # And the install was NOT performed.
    local sha_after
    sha_after=$(sha256sum "$APR_UNDER_TEST" | cut -d' ' -f1)
    [[ "$sha_before" == "$sha_after" ]]
}

@test "cmd_update: checksum in 'hash  filename' format still works" {
    install_apr_copy
    local payload=$'#!/usr/bin/env bash\necho new sha\n'
    write_fake_release "99.0.0" "$payload"

    local hash
    hash=$(printf '%s' "$payload" | sha256sum | cut -d' ' -f1)
    write_canned "apr.sha256" "$hash  apr"

    run_with_artifacts "$APR_UNDER_TEST" update
    [[ "$status" -eq 0 ]] || {
        echo "expected exit 0; stderr:" >&2
        cat "$ARTIFACT_DIR/stderr.log" >&2
        return 1
    }
    grep -Fq "Checksum verified" "$ARTIFACT_DIR/stderr.log"
}

@test "cmd_update: missing checksum file is non-fatal" {
    install_apr_copy
    write_fake_release "99.0.0" $'#!/usr/bin/env bash\necho hi\n'
    # No apr.sha256 served. cmd_update should warn but still install.

    run_with_artifacts "$APR_UNDER_TEST" update
    [[ "$status" -eq 0 ]] || {
        echo "expected exit 0; stderr:" >&2
        cat "$ARTIFACT_DIR/stderr.log" >&2
        return 1
    }
    grep -Fq "Checksum not available" "$ARTIFACT_DIR/stderr.log"
}

# ---------------------------------------------------------------------------
# cmd_update: temp directory cleanup on failure
# ---------------------------------------------------------------------------

@test "cmd_update: temp dir is cleaned up after checksum failure" {
    install_apr_copy
    local payload=$'#!/usr/bin/env bash\necho new\n'
    write_fake_release "99.0.0" "$payload"
    write_canned "apr.sha256" "$(printf 'wrong' | sha256sum | cut -d' ' -f1)"

    # Use TMPDIR=$TEST_DIR/tmp so mktemp lands somewhere we can inspect.
    export TMPDIR="$TEST_DIR/tmp"
    mkdir -p "$TMPDIR"

    run_with_artifacts "$APR_UNDER_TEST" update
    [[ "$status" -eq 11 ]]

    # No `apr_test_failed` debris left behind in TMPDIR.
    # cmd_update either rm -rf's the dir directly or relies on the EXIT trap.
    # Either way, no tmp.*/apr file should still exist.
    if find "$TMPDIR" -maxdepth 2 -name 'apr' -type f 2>/dev/null | grep -q .; then
        echo "leftover apr download in TMPDIR:" >&2
        find "$TMPDIR" -maxdepth 2 -name 'apr' -type f >&2
        return 1
    fi
}
