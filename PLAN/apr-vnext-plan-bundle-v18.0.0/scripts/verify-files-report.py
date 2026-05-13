#!/usr/bin/env python3
# Bundle version: v18.0.0
import argparse, json, sys, re, logging, time
from pathlib import Path

VERSION = 'v18.0.0'

def env(ok=True, data=None, warnings=None, errors=None, next_command=None, fix_command=None, blocked_reason=None, retry_safe=True):
    return {
        'ok': ok,
        'schema_version': 'json_envelope.v1',
        'data': data or {},
        'meta': {'tool': 'verify-files-report', 'bundle_version': VERSION},
        'warnings': warnings or [],
        'errors': errors or [],
        'commands': {'next': 'python3 scripts/verify-files-report.py --json'},
        'next_command': next_command,
        'fix_command': fix_command,
        'blocked_reason': blocked_reason,
        'retry_safe': retry_safe
    }

def parse_oracle_report(text):
    """
    Parse the human-readable Oracle files report from stderr/log.
    Example lines:
    [oracle] Files report:
    [oracle]   - README.md: success (1234 bytes)
    [oracle]   - spec.md: failed (0 bytes)
    """
    reported = []
    # Match: [oracle]   - <path>: <status> (<N> bytes)
    pattern = re.compile(r'\[oracle\]\s+-\s+(.+):\s+(\w+)\s+\((\d+)\s+bytes\)')
    for line in text.splitlines():
        m = pattern.search(line)
        if m:
            reported.append({
                'path': m.group(1).strip(),
                'status': m.group(2).strip(),
                'bytes': int(m.group(3))
            })
    return reported

def main():
    ap = argparse.ArgumentParser(description='Verify Oracle files-report against expected manifest.')
    ap.add_argument('--expected-files', required=True, help='JSON array of expected file objects')
    ap.add_argument('--oracle-output', required=True, help='Path to Oracle output log/file')
    ap.add_argument('--json', action='store_true')
    args = ap.parse_args()

    logs_dir = Path('tests/logs/v18/provenance/files-report')
    logs_dir.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    log_file = logs_dir / f"verify_{timestamp}.log"
    logging.basicConfig(filename=log_file, level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')

    errors = []
    warnings = []
    
    try:
        expected = json.loads(args.expected_files)
        output_path = Path(args.oracle_output)
        if not output_path.exists():
            raise FileNotFoundError(f"Oracle output not found: {args.oracle_output}")
            
        output_text = output_path.read_text(encoding='utf-8', errors='ignore')
        reported = parse_oracle_report(output_text)
        
        if not reported:
            # Maybe it wasn't supported or no files were attached
            data = {
                'trust': {'files_report_ok': True, 'files_report_supported': False},
                'files_report': None
            }
            logging.info("No Oracle files report found in output.")
        else:
            # Compare
            expected_map = {f.get('path'): f for f in expected if f.get('inclusion_reason') != 'skipped'}
            reported_map = {r['path']: r for r in reported}
            
            missing = []
            for path, f in expected_map.items():
                if path not in reported_map:
                    missing.append(path)
                elif reported_map[path]['status'] != 'success':
                    missing.append(path) # Treat non-success as missing
                    
            extra = [r['path'] for r in reported if r['path'] not in expected_map]
            
            size_mismatches = []
            for path, r in reported_map.items():
                if path in expected_map:
                    exp_bytes = expected_map[path].get('bytes', 0)
                    # Allow 5% tolerance or 10 bytes for metadata injection
                    if abs(r['bytes'] - exp_bytes) > max(10, exp_bytes * 0.05):
                        size_mismatches.append(path)
            
            ok = (len(missing) == 0 and len(extra) == 0 and len(size_mismatches) == 0)
            
            data = {
                'trust': {
                    'files_report_ok': ok,
                    'files_report_supported': True
                },
                'files_report': {
                    'reported_files': reported,
                    'mismatches': {
                        'missing': missing,
                        'extra': extra,
                        'size_mismatch': size_mismatches
                    },
                    'parse_error': None
                }
            }
            
            if not ok:
                msg = f"Oracle files-report mismatch: {len(missing)} missing, {len(extra)} extra, {len(size_mismatches)} size diffs."
                warnings.append(msg)
                logging.warning(msg)
            else:
                logging.info("Oracle files-report verified successfully.")

    except Exception as exc:
        data = {
            'trust': {'files_report_ok': False, 'files_report_supported': True},
            'files_report': {'parse_error': str(exc)}
        }
        errors.append(str(exc))
        logging.error(f"Verification failed: {exc}")

    out = env(ok=not errors, data=data, warnings=warnings)
    if args.json:
        print(json.dumps(out, indent=2, sort_keys=True))
    else:
        if errors:
            for e in errors: print(f"ERROR: {e}", file=sys.stderr)
            sys.exit(1)
        else:
            if data['trust']['files_report_ok']:
                print("OK: Oracle files-report verified.")
            else:
                print("WARN: Oracle files-report mismatch detected.")
            sys.exit(0)

if __name__ == '__main__':
    main()
