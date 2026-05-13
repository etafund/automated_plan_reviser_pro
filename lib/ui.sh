#!/usr/bin/env bash
# APR CLI design tokens, terminal capabilities, and responsive layout helpers.

if [[ -z "${APR_DEFAULT_DESKTOP_MIN_COLS:-}" ]]; then
    APR_DEFAULT_DESKTOP_MIN_COLS=100
fi
if [[ -z "${APR_DEFAULT_DESKTOP_MIN_ROWS:-}" ]]; then
    APR_DEFAULT_DESKTOP_MIN_ROWS=24
fi
readonly APR_DEFAULT_DESKTOP_MIN_COLS APR_DEFAULT_DESKTOP_MIN_ROWS

apr_term_width() {
    local width="${APR_TERM_COLUMNS:-${COLUMNS:-}}"

    if [[ "$width" =~ ^[0-9]+$ && "$width" -gt 0 ]]; then
        printf '%s\n' "$width"
        return 0
    fi

    if [[ -t 2 ]] && command -v tput &>/dev/null; then
        width=$(tput cols 2>/dev/null || true)
        if [[ "$width" =~ ^[0-9]+$ && "$width" -gt 0 ]]; then
            printf '%s\n' "$width"
            return 0
        fi
    fi

    printf '80\n'
}

apr_term_height() {
    local height="${APR_TERM_LINES:-${LINES:-}}"

    if [[ "$height" =~ ^[0-9]+$ && "$height" -gt 0 ]]; then
        printf '%s\n' "$height"
        return 0
    fi

    if [[ -t 2 ]] && command -v tput &>/dev/null; then
        height=$(tput lines 2>/dev/null || true)
        if [[ "$height" =~ ^[0-9]+$ && "$height" -gt 0 ]]; then
            printf '%s\n' "$height"
            return 0
        fi
    fi

    printf '24\n'
}

apr_color_enabled() {
    [[ -t 2 ]] || return 1
    [[ -z "${NO_COLOR:-}" ]] || return 1
    [[ "${TERM:-}" != "dumb" ]] || return 1
    return 0
}

apr_unicode_enabled() {
    [[ -t 2 ]] || return 1
    [[ -z "${APR_NO_UNICODE:-}" ]] || return 1
    [[ "${TERM:-}" != "dumb" ]] || return 1
    return 0
}

apr_layout_mode() {
    local override="${APR_LAYOUT:-auto}"
    local min_cols="${APR_DESKTOP_MIN_COLS:-$APR_DEFAULT_DESKTOP_MIN_COLS}"
    local min_rows="${APR_DESKTOP_MIN_ROWS:-$APR_DEFAULT_DESKTOP_MIN_ROWS}"
    local width height

    override="${override,,}"
    case "$override" in
        desktop|wide)
            printf 'desktop\n'
            return 0
            ;;
        compact|mobile)
            printf 'compact\n'
            return 0
            ;;
        auto|"")
            ;;
        *)
            printf 'compact\n'
            return 2
            ;;
    esac

    if [[ ! -t 2 ]]; then
        printf 'compact\n'
        return 0
    fi

    width=$(apr_term_width)
    height=$(apr_term_height)
    if (( width >= min_cols && height >= min_rows )); then
        printf 'desktop\n'
    else
        printf 'compact\n'
    fi
}

apr_ui_symbol() {
    local token="$1"
    local unicode=false
    if apr_unicode_enabled; then
        unicode=true
    fi

    case "$token:$unicode" in
        success:true) printf '✓' ;;
        success:false) printf '[ok]' ;;
        error:true) printf '✗' ;;
        error:false) printf '[error]' ;;
        warning:true) printf '⚠' ;;
        warning:false) printf '[warn]' ;;
        info:true) printf 'ℹ' ;;
        info:false) printf '[info]' ;;
        arrow:true) printf '→' ;;
        arrow:false) printf '->' ;;
        rule:true) printf '━' ;;
        rule:false) printf '=' ;;
        light_rule:true) printf '─' ;;
        light_rule:false) printf '-' ;;
        *) printf '%s' "$token" ;;
    esac
}

apr_set_layout_override() {
    local value="${1:-auto}"
    value="${value,,}"
    case "$value" in
        auto|desktop|wide|compact|mobile)
            APR_LAYOUT="$value"
            if [[ "$value" == "compact" || "$value" == "mobile" ]]; then
                # shellcheck disable=SC2034  # Consumed by apr after sourcing this helper.
                GUM_AVAILABLE=false
            fi
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}
