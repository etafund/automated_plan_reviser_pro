#!/usr/bin/env python3
# Bundle version: v18.0.0
import argparse, json, sys, hashlib, logging, time
from pathlib import Path

VERSION = 'v18.0.0'

def env(ok=True, data=None, warnings=None, errors=None, next_command=None, fix_command=None, blocked_reason=None, retry_safe=True):
    return {
        'ok': ok,
        'schema_version': 'json_envelope.v1',
        'data': data or {},
        'meta': {'tool': 'run-cache-manager', 'bundle_version': VERSION},
        'warnings': warnings or [],
        'errors': errors or [],
        'commands': {'next': 'python3 scripts/manage-run-cache.py --json'},
        'next_command': next_command,
        'fix_command': fix_command,
        'blocked_reason': blocked_reason,
        'retry_safe': retry_safe
    }

def compute_cache_key(baseline_sha, manifest_sha, stage, profile):
    raw = f"{baseline_sha}:{manifest_sha}:{stage}:{profile}"
    return f"cache-{hashlib.sha256(raw.encode('utf-8')).hexdigest()[:16]}"

def main():
    ap = argparse.ArgumentParser(description='Manage v18 run cache and idempotency.')
    ap.add_argument('--action', choices=['get-key', 'check', 'save'], required=True)
    ap.add_argument('--baseline', help='Path to source-baseline.json')
    ap.add_argument('--manifest', help='Path to prompt-manifest.json')
    ap.add_argument('--stage', help='Current stage name')
    ap.add_argument('--profile', help='Execution profile')
    ap.add_argument('--run-dir', help='Path to the planning run directory')
    ap.add_argument('--json', action='store_true')
    args = ap.parse_args()

    logs_dir = Path('tests/logs/v18/run-state/cache')
    logs_dir.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    log_file = logs_dir / f"cache_{args.action}_{timestamp}.log"
    logging.basicConfig(filename=log_file, level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')

    errors = []
    warnings = []
    data = None
    
    try:
        if args.action == 'get-key':
            if not all([args.baseline, args.manifest, args.stage, args.profile]):
                raise ValueError("--baseline, --manifest, --stage, and --profile required for get-key")
            
            baseline_data = json.loads(Path(args.baseline).read_text())
            manifest_data = json.loads(Path(args.manifest).read_text())
            
            b_sha = baseline_data.get('source_baseline_sha256', 'unknown')
            m_sha = manifest_data.get('prompt_manifest_sha256', 'unknown')
            
            key = compute_cache_key(b_sha, m_sha, args.stage, args.profile)
            data = {'cache_key': key, 'baseline_sha': b_sha, 'manifest_sha': m_sha}
            logging.info(f"Generated cache key {key} for stage {args.stage}")
            
        elif args.action == 'check':
            if not all([args.run_dir, args.stage]):
                raise ValueError("--run-dir and --stage required for check")
            
            # Simple check: does a result artifact exist for this stage?
            # In a real impl, we'd check events.jsonl or an actual cache index
            results_dir = Path(args.run_dir) / 'provider_results'
            found = False
            for f in results_dir.glob('*.json'):
                res = json.loads(f.read_text())
                if res.get('stage') == args.stage and res.get('status') == 'success':
                    found = True
                    data = {'hit': True, 'artifact': str(f)}
                    break
            
            if not found:
                data = {'hit': False}
                
            logging.info(f"Cache check for {args.stage}: {'HIT' if data['hit'] else 'MISS'}")
            
    except Exception as exc:
        errors.append(str(exc))
        logging.error(f"Execution failed: {exc}")

    if errors:
        out = env(ok=False, errors=[{'error_code': 'cache_error', 'message': e} for e in errors])
    else:
        out = env(ok=True, data=data, warnings=warnings)

    if args.json:
        print(json.dumps(out, indent=2, sort_keys=True))
    else:
        if errors:
            for e in errors: print(f"ERROR: {e}", file=sys.stderr)
            sys.exit(1)
        else:
            print(json.dumps(data, indent=2, sort_keys=True))
            sys.exit(0)

if __name__ == '__main__':
    main()
