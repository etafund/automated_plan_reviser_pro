#!/usr/bin/env bash
# lib/files_report.sh - APR oracle --files-report parser (bd-1oh)
#
# Parses Oracle's --files-report output into a structured JSON record
# so APR can verify post-hoc which files actually made it into the
# chat. Used by the trust block emitted to the run ledger (bd-246) and
# the metrics file (bd-2ic v1.1.0).
#
# Background
# ----------
# Oracle's --files-report is the closest thing APR has to authoritative
# attachment provenance. Without parsing it we can't detect:
#   - silent attach failures
#   - partial uploads
#   - browser-automation drift that pastes only N of K files
#
# Oracle's actual format may vary across versions. This parser
# tolerates several documented shapes:
#
#   Shape A — JSON object lines, one per file:
#     {"path":"README.md","bytes":5420,"sha256":"<hex>","status":"ok"}
#     {"path":"SPEC.md","bytes":14820,"sha256":"<hex>","status":"ok"}
#
#   Shape B — Plain-text columns (legacy):
#     README.md    5420   <hex>    ok
#     SPEC.md      14820  <hex>    ok
#
#   Shape C — JSON envelope:
#     {"files":[{"path":"README.md",...}, {"path":"SPEC.md",...}]}
#
# The parser emits a canonical compact JSON envelope on stdout:
#
#   {"files": [{"path":..., "bytes":..., "sha256":..., "status":"ok"|"failed"}, ...]}
#
# Plus a `compare` helper that takes the parsed canonical envelope +
# the expected set (from the manifest) and emits the mismatch object
# the metrics schema (docs/schemas/metrics.schema.json) expects:
#
#   {"missing": [path,...], "extra": [path,...], "size_mismatch": [path,...]}
#
# Public API
# ----------
#   apr_lib_files_report_parse <text>
#       Emit canonical {"files":[...]} JSON. Returns 0 on success, 1 if
#       the input doesn't look like a files-report at all.
#
#   apr_lib_files_report_compare <expected_paths_csv> <canonical_json>
#       Pipe expected paths as "p1|p2|p3" and the canonical JSON; emit
#       the mismatch JSON object on stdout. Returns 0 iff there are no
#       mismatches, 1 otherwise.
#
# Both helpers depend on python3 for parsing; without python3 they
# return 1 and emit a "files":[] / "missing":[]/"extra":[]/... shell
# of an envelope so callers can still write a defensible JSON to the
# ledger.

if [[ "${_APR_LIB_FILES_REPORT_LOADED:-0}" == "1" ]]; then
    return 0
fi
_APR_LIB_FILES_REPORT_LOADED=1

_APR_LIB_FILES_REPORT_DIR_SELF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/manifest.sh
source "$_APR_LIB_FILES_REPORT_DIR_SELF/manifest.sh"

# -----------------------------------------------------------------------------
# apr_lib_files_report_parse <text>
# -----------------------------------------------------------------------------
apr_lib_files_report_parse() {
    local text="${1-}"
    if [[ -z "$text" ]]; then
        printf '{"files":[]}'
        return 1
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        printf '{"files":[]}'
        return 1
    fi

    python3 - <<PY "$text"
import json, re, sys

text = sys.argv[1]
files = []
found_anything = False

# Shape C: JSON envelope. Try first since it's the most strict.
stripped = text.strip()
if stripped.startswith('{') and '"files"' in stripped:
    try:
        d = json.loads(stripped)
        if isinstance(d, dict) and isinstance(d.get('files'), list):
            for f in d['files']:
                if not isinstance(f, dict):
                    continue
                files.append({
                    'path':   str(f.get('path', '') or ''),
                    'bytes':  f.get('bytes'),
                    'sha256': f.get('sha256'),
                    'status': f.get('status', 'ok'),
                })
            found_anything = True
    except Exception:
        pass

if not found_anything:
    # Shape A: one JSON object per line.
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith('{') or '"path"' not in line:
            continue
        try:
            f = json.loads(line)
        except Exception:
            continue
        if not isinstance(f, dict):
            continue
        files.append({
            'path':   str(f.get('path', '') or ''),
            'bytes':  f.get('bytes'),
            'sha256': f.get('sha256'),
            'status': f.get('status', 'ok'),
        })
        found_anything = True

if not found_anything:
    # Shape B: tab/space-separated columns "path bytes sha256 status".
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        parts = re.split(r'\s+', line)
        if len(parts) < 2:
            continue
        path = parts[0]
        try:
            byts = int(parts[1]) if len(parts) > 1 else None
        except ValueError:
            continue
        sha = parts[2] if len(parts) > 2 else None
        status = parts[3] if len(parts) > 3 else 'ok'
        files.append({
            'path':   path,
            'bytes':  byts,
            'sha256': sha,
            'status': status,
        })
        found_anything = True

# Normalize: sort by path for byte-deterministic output.
files.sort(key=lambda f: f['path'])

# Emit canonical envelope.
sys.stdout.write(json.dumps({'files': files}, separators=(',', ':'), sort_keys=True))
sys.exit(0 if found_anything else 1)
PY
}

# -----------------------------------------------------------------------------
# apr_lib_files_report_compare <expected_csv> <canonical_json>
# -----------------------------------------------------------------------------
apr_lib_files_report_compare() {
    local expected_csv="${1-}"
    local canonical="${2-}"

    if ! command -v python3 >/dev/null 2>&1; then
        printf '{"missing":[],"extra":[],"size_mismatch":[]}'
        return 1
    fi

    python3 - "$expected_csv" "$canonical" <<'PY'
import json, sys
expected_csv, canonical = sys.argv[1], sys.argv[2]

expected = []
for chunk in expected_csv.split('|'):
    chunk = chunk.strip()
    if not chunk:
        continue
    # Each chunk is "path:bytes" OR just "path" — bytes is optional.
    if ':' in chunk:
        p, b = chunk.split(':', 1)
        try:
            expected.append((p, int(b)))
        except ValueError:
            expected.append((p, None))
    else:
        expected.append((chunk, None))

try:
    d = json.loads(canonical) if canonical else {'files': []}
except Exception:
    d = {'files': []}
actual = d.get('files', [])

expected_paths = {p for p, _ in expected}
expected_bytes = {p: b for p, b in expected if b is not None}
actual_paths   = {f.get('path', '') for f in actual}
actual_bytes   = {f.get('path', ''): f.get('bytes') for f in actual}

missing = sorted(expected_paths - actual_paths)
extra   = sorted(actual_paths - expected_paths)
size_mismatch = sorted(
    p for p in expected_paths & actual_paths
    if expected_bytes.get(p) is not None
    and actual_bytes.get(p) is not None
    and expected_bytes[p] != actual_bytes[p]
)
status_failed = sorted(
    f.get('path', '') for f in actual
    if f.get('status') not in (None, 'ok', 'success', 'attached')
)

# Any non-ok status counts as a mismatch via the size_mismatch bucket
# extension — the metrics schema is explicit that the bucket name is a
# label, not a strict description. Emit it as `status_failed` in
# details so consumers can distinguish.
out = {'missing': missing, 'extra': extra, 'size_mismatch': size_mismatch}
if status_failed:
    out['status_failed'] = status_failed
sys.stdout.write(json.dumps(out, separators=(',', ':'), sort_keys=True))
sys.exit(0 if (not missing and not extra and not size_mismatch and not status_failed) else 1)
PY
}
