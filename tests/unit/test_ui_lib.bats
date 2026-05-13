#!/usr/bin/env bats
# test_ui_lib.bats
#
# Bead automated_plan_reviser_pro-y6d4 — direct unit + fuzz coverage
# for lib/ui.sh.
#
# lib/ui.sh ships the canonical CLI design-token / capability-detection
# / layout-selector / gum-policy / apr_terminal_capabilities helpers.
# `apr_source_optional_libs` (in apr) sources this file at startup, so
# lib/ui.sh's definitions are what actually run in production — but
# until now the only tests touching these helpers came through
# load_apr_functions (test_layout.bats), which is an indirect path and
# doesn't cover the lib-only public surface.
#
# This file sources lib/ui.sh DIRECTLY (no apr) so:
#   - regressions in lib/ui.sh surface in isolation
#   - apr_bool_word / apr_stderr_is_tty / apr_gum_allowed /
#     apr_terminal_capabilities (untouched by test_layout.bats) get
#     dedicated coverage
#   - the ecjo glob-leak regression stays pinned at the lib level
#
# Per-test artifacts under tests/logs/unit/ per the ufc Logging contract.

load '../helpers/test_helper'

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
    setup_test_environment
    start_test_artifacts "unit" "${BATS_TEST_NAME}"

    # Source lib/ui.sh directly. We deliberately do NOT load apr so any
    # regression sits in the lib file, not in upstream sourcing order.
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../lib/ui.sh"

    # Baseline env. Tests opt in to other knobs.
    unset APR_TERM_COLUMNS APR_TERM_LINES \
          COLUMNS LINES \
          APR_LAYOUT APR_DESKTOP_MIN_COLS APR_DESKTOP_MIN_ROWS \
          APR_NO_UNICODE APR_NO_GUM NO_COLOR CI 2>/dev/null || true
    export TERM=xterm
    # GUM_AVAILABLE is mutated by apr_set_layout_override; reset every test.
    GUM_AVAILABLE=true

    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# ===========================================================================
# apr_bool_word
# ===========================================================================

@test "apr_bool_word: returns 'true' for a successful command" {
    local out
    out=$(apr_bool_word true)
    [[ "$out" == "true" ]] || { echo "got: '$out'" >&2; return 1; }
}

@test "apr_bool_word: returns 'false' for a failing command" {
    local out
    out=$(apr_bool_word false)
    [[ "$out" == "false" ]] || { echo "got: '$out'" >&2; return 1; }
}

@test "apr_bool_word: no-args invocation returns 'false' (defensive default)" {
    local out
    out=$(apr_bool_word)
    [[ "$out" == "false" ]]
}

@test "apr_bool_word: passes positional args through to the wrapped command" {
    # Use grep as a predicate that reads its args; if the args don't
    # propagate, grep returns 1 and we get "false".
    local out
    out=$(apr_bool_word grep -q '^x$' <<<"x")
    [[ "$out" == "true" ]]
    out=$(apr_bool_word grep -q '^y$' <<<"x")
    [[ "$out" == "false" ]]
}

# ===========================================================================
# apr_stderr_is_tty
# ===========================================================================

@test "apr_stderr_is_tty: returns failure under bats (no TTY on fd 2)" {
    # bats captures stderr, so -t 2 is false here.
    if apr_stderr_is_tty; then
        echo "apr_stderr_is_tty returned 0 under bats — expected non-zero" >&2
        return 1
    fi
}

# ===========================================================================
# apr_gum_allowed
# ===========================================================================

@test "apr_gum_allowed: returns false when APR_NO_GUM is set" {
    export APR_NO_GUM=1
    if apr_gum_allowed; then
        echo "apr_gum_allowed wrongly returned 0 with APR_NO_GUM=1" >&2
        return 1
    fi
}

@test "apr_gum_allowed: returns false when CI is set" {
    export CI=true
    if apr_gum_allowed; then
        echo "apr_gum_allowed wrongly returned 0 with CI=true" >&2
        return 1
    fi
}

@test "apr_gum_allowed: returns false under bats (no TTY → color disabled)" {
    # Even with everything else permissive, apr_color_enabled fails
    # under bats so apr_gum_allowed must too.
    if apr_gum_allowed; then
        echo "apr_gum_allowed wrongly returned 0 with no TTY" >&2
        return 1
    fi
}

@test "apr_gum_allowed: returns false when gum binary is unreachable on PATH" {
    # Run the gate in a subshell with a PATH stripped of every gum
    # location. Doing the override in the subshell avoids leaking the
    # broken PATH into bats' teardown (which needs rm/mkdir/date).
    # Stub apr_color_enabled to remove the no-TTY confound.
    apr_color_enabled() { return 0; }
    export -f apr_color_enabled

    local empty_bin="$TEST_DIR/empty_bin"
    mkdir -p "$empty_bin"

    local rc=0
    ( PATH="$empty_bin"; hash -r; apr_gum_allowed ) || rc=$?

    [[ "$rc" -ne 0 ]] || {
        echo "apr_gum_allowed wrongly returned 0 when gum is absent" >&2
        return 1
    }
}

# ===========================================================================
# apr_terminal_capabilities — output shape
# ===========================================================================

@test "apr_terminal_capabilities: emits exactly 8 key=value lines, in the documented order" {
    local out
    out=$(apr_terminal_capabilities)

    local -a lines
    mapfile -t lines <<<"$out"
    [[ "${#lines[@]}" -eq 8 ]] || {
        echo "expected 8 lines, got ${#lines[@]}:" >&2
        printf '  %s\n' "${lines[@]}" >&2
        return 1
    }

    local expected_keys=(layout layout_status width height stderr_tty color unicode gum)
    local i
    for i in "${!expected_keys[@]}"; do
        local want_prefix="${expected_keys[$i]}="
        [[ "${lines[$i]}" == "$want_prefix"* ]] || {
            echo "line $i wrong key: want prefix '$want_prefix' got '${lines[$i]}'" >&2
            return 1
        }
    done
}

@test "apr_terminal_capabilities: all values are non-empty" {
    local out line val
    out=$(apr_terminal_capabilities)
    while IFS= read -r line; do
        val="${line#*=}"
        [[ -n "$val" ]] || {
            echo "empty value on line: '$line'" >&2
            return 1
        }
    done <<<"$out"
}

@test "apr_terminal_capabilities: stderr_tty/color/unicode/gum render as 'true' or 'false'" {
    local out
    out=$(apr_terminal_capabilities)
    local key val
    while IFS='=' read -r key val; do
        case "$key" in
            stderr_tty|color|unicode|gum)
                [[ "$val" == "true" || "$val" == "false" ]] || {
                    echo "$key has non-bool value '$val'" >&2
                    return 1
                }
                ;;
        esac
    done <<<"$out"
}

@test "apr_terminal_capabilities: width and height are positive integers" {
    local out width height
    out=$(apr_terminal_capabilities)
    width=$(awk -F= '$1=="width"{print $2}' <<<"$out")
    height=$(awk -F= '$1=="height"{print $2}' <<<"$out")
    [[ "$width" =~ ^[0-9]+$ ]] && [[ "$width" -gt 0 ]]
    [[ "$height" =~ ^[0-9]+$ ]] && [[ "$height" -gt 0 ]]
}

@test "apr_terminal_capabilities: APR_TERM_COLUMNS/LINES env overrides flow through" {
    export APR_TERM_COLUMNS=200
    export APR_TERM_LINES=80
    local out width height
    out=$(apr_terminal_capabilities)
    width=$(awk -F= '$1=="width"{print $2}' <<<"$out")
    height=$(awk -F= '$1=="height"{print $2}' <<<"$out")
    [[ "$width" -eq 200 ]] || { echo "width: got $width want 200" >&2; return 1; }
    [[ "$height" -eq 80 ]] || { echo "height: got $height want 80" >&2; return 1; }
}

# ===========================================================================
# apr_set_layout_override — side effects
# ===========================================================================

@test "apr_set_layout_override: compact forces GUM_AVAILABLE=false" {
    GUM_AVAILABLE=true
    apr_set_layout_override compact
    [[ "$GUM_AVAILABLE" == "false" ]]
}

@test "apr_set_layout_override: desktop preserves GUM_AVAILABLE" {
    GUM_AVAILABLE=true
    apr_set_layout_override desktop
    [[ "$GUM_AVAILABLE" == "true" ]]
}

@test "apr_set_layout_override: invalid value returns non-zero AND leaves APR_LAYOUT untouched" {
    APR_LAYOUT="desktop"
    if apr_set_layout_override "zigzag"; then
        echo "wrongly accepted 'zigzag'" >&2
        return 1
    fi
    [[ "$APR_LAYOUT" == "desktop" ]]
}

# ===========================================================================
# apr_ui_symbol — fuzz layer (ecjo regression + every documented token)
# ===========================================================================

@test "apr_ui_symbol: ASCII fallback table is complete and stable" {
    # apr_unicode_enabled returns false under bats (no TTY on fd 2),
    # so the ASCII branch is exercised. Pin every documented token.
    local cases=(
        "success [ok]"
        "error [error]"
        "warning [warn]"
        "info [info]"
        "arrow ->"
        "rule ="
        "light_rule -"
    )
    local entry token want got
    for entry in "${cases[@]}"; do
        token="${entry%% *}"
        want="${entry#* }"
        got=$(apr_ui_symbol "$token")
        [[ "$got" == "$want" ]] || {
            echo "apr_ui_symbol $token: want='$want' got='$got'" >&2
            return 1
        }
    done
}

@test "apr_ui_symbol: ecjo regression — '->' and '-' fallbacks survive printf without leaking glob expansion" {
    # The historical bug (bead ecjo): an earlier `printf '->'` /
    # `printf '-'` shape made bash interpret the dash as an option flag.
    # lib/ui.sh now uses `printf '%s' '->'` etc. Re-assert in a directory
    # that DOES have glob targets to catch the pathname-expansion variant.
    cd "$TEST_DIR"
    touch a.md b.md c.md
    local arrow rule
    arrow=$(apr_ui_symbol arrow)
    rule=$(apr_ui_symbol light_rule)

    [[ "$arrow" == "->" ]] || { echo "arrow: got='$arrow'" >&2; return 1; }
    [[ "$rule"  == "-"  ]] || { echo "light_rule: got='$rule'" >&2; return 1; }

    # And the same under APR_NO_UNICODE=1 explicit opt-out.
    APR_NO_UNICODE=1
    arrow=$(apr_ui_symbol arrow)
    [[ "$arrow" == "->" ]]
}

@test "apr_ui_symbol: unknown token returns the token unchanged" {
    local got
    got=$(apr_ui_symbol "never-defined-token-99")
    [[ "$got" == "never-defined-token-99" ]]
}

@test "apr_ui_symbol: empty token returns the empty string" {
    local got
    got=$(apr_ui_symbol "")
    [[ -z "$got" ]]
}

@test "apr_ui_symbol: glob metacharacter token returns verbatim (no pathname expansion)" {
    # Sit in a populated directory; pass `*` as the token. The unknown
    # branch emits the token verbatim. If unquoted expansion ever
    # creeps back in, we'd see filenames instead.
    cd "$TEST_DIR"
    touch x.md y.md z.md
    local got
    got=$(apr_ui_symbol "*")
    [[ "$got" == "*" ]] || {
        echo "glob leak from unknown branch: got='$got'" >&2
        return 1
    }
}

# ===========================================================================
# apr_layout_mode — direct lib coverage
# ===========================================================================
#
# test_layout.bats already covers the apr-sourced version. We re-assert
# here through the direct lib/ui.sh sourcing path so any drift between
# the two definitions surfaces.

@test "apr_layout_mode (direct lib): wide alias resolves to desktop" {
    export APR_LAYOUT=wide
    local out
    out=$(apr_layout_mode)
    [[ "$out" == "desktop" ]]
}

@test "apr_layout_mode (direct lib): mobile alias resolves to compact" {
    export APR_LAYOUT=mobile
    local out
    out=$(apr_layout_mode)
    [[ "$out" == "compact" ]]
}

@test "apr_layout_mode (direct lib): invalid override exits 2 with compact" {
    export APR_LAYOUT=zigzag
    local rc=0 out
    out=$(apr_layout_mode) || rc=$?
    [[ "$rc" -eq 2 ]]
    [[ "$out" == "compact" ]]
}

@test "apr_layout_mode (direct lib): non-TTY auto returns compact" {
    export APR_LAYOUT=auto
    local out
    out=$(apr_layout_mode)
    [[ "$out" == "compact" ]]
}

# ===========================================================================
# Cross-lib conformance: apr_terminal_capabilities reflects each underlying
# helper's verdict
# ===========================================================================

@test "apr_terminal_capabilities: layout matches apr_layout_mode" {
    local cap layout_in_cap layout_direct
    cap=$(apr_terminal_capabilities)
    layout_in_cap=$(awk -F= '$1=="layout"{print $2}' <<<"$cap")

    # Direct call may exit non-zero on invalid override; here we use
    # the default (no APR_LAYOUT) which falls through to compact under
    # bats' no-TTY environment.
    layout_direct=$(apr_layout_mode)
    [[ "$layout_in_cap" == "$layout_direct" ]] || {
        echo "layout drift: cap='$layout_in_cap' direct='$layout_direct'" >&2
        return 1
    }
}

@test "apr_terminal_capabilities: width/height match apr_term_width/height" {
    local cap w_cap h_cap w_direct h_direct
    cap=$(apr_terminal_capabilities)
    w_cap=$(awk -F= '$1=="width"{print $2}'  <<<"$cap")
    h_cap=$(awk -F= '$1=="height"{print $2}' <<<"$cap")
    w_direct=$(apr_term_width)
    h_direct=$(apr_term_height)
    [[ "$w_cap" == "$w_direct" ]]
    [[ "$h_cap" == "$h_direct" ]]
}
