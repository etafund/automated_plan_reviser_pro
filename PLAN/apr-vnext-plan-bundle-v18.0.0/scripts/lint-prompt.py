#!/usr/bin/env python3
# Bundle version: v18.0.0
import argparse, json, sys, logging, time
from pathlib import Path

VERSION = 'v18.0.0'

def env(ok=True, data=None, warnings=None, errors=None, next_command=None, fix_command=None, blocked_reason=None, retry_safe=True):
    return {
        'ok': ok,
        'schema_version': 'json_envelope.v1',
        'data': data or {},
        'meta': {'tool': 'lint-prompt', 'bundle_version': VERSION},
        'warnings': warnings or [],
        'errors': errors or [],
        'commands': {'next': 'python3 scripts/lint-prompt.py --json'},
        'next_command': next_command,
        'fix_command': fix_command,
        'blocked_reason': blocked_reason,
        'retry_safe': retry_safe
    }

def main():
    ap = argparse.ArgumentParser(description='Lint v18 prompt context and source trust.')
    ap.add_argument('--baseline', help='Path to source-baseline.json')
    ap.add_argument('--trust', help='Path to source-trust.json')
    ap.add_argument('--policy', help='Path to prompting-policy.json')
    ap.add_argument('--json', action='store_true')
    args = ap.parse_args()

    logs_dir = Path('tests/logs/v18/prompts/lint')
    logs_dir.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    log_file = logs_dir / f"lint_{timestamp}.log"
    logging.basicConfig(filename=log_file, level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')

    errors = []
    warnings = []
    data = {'checked': []}
    
    try:
        # 1. Lint Source Baseline
        if args.baseline:
            p = Path(args.baseline)
            if p.exists():
                data['checked'].append('baseline')
                b = json.loads(p.read_text())
                if b.get('bundle_version') != VERSION:
                    warnings.append(f"Baseline version mismatch: {b.get('bundle_version')} != {VERSION}")
                if not b.get('source_baseline_sha256'):
                    errors.append("Baseline missing source_baseline_sha256")
            else:
                errors.append(f"Baseline file not found: {args.baseline}")

        # 2. Lint Source Trust
        if args.trust:
            p = Path(args.trust)
            if p.exists():
                data['checked'].append('trust')
                t = json.loads(p.read_text())
                if t.get('prompt_injection_detected'):
                    warnings.append("Prompt injection detected in source trust record")
                if not t.get('sources'):
                    warnings.append("No sources defined in trust record")
            else:
                errors.append(f"Trust file not found: {args.trust}")

        # 3. Lint Policy
        if args.policy:
            p = Path(args.policy)
            if p.exists():
                data['checked'].append('policy')
                pol = json.loads(p.read_text())
                if not pol.get('policies'):
                    errors.append("Policy file missing 'policies' object")
            else:
                errors.append(f"Policy file not found: {args.policy}")

        logging.info(f"Lint complete. Checked: {data['checked']}. Errors: {len(errors)}, Warnings: {len(warnings)}")
        
    except Exception as exc:
        errors.append(str(exc))
        logging.error(f"Execution failed: {exc}")

    if errors:
        out = env(
            ok=False,
            errors=[{'error_code': 'lint_failed', 'message': e} for e in errors],
            blocked_reason='prompt_lint_error',
            data=data
        )
    else:
        out = env(ok=True, data=data, warnings=warnings)

    if args.json:
        print(json.dumps(out, indent=2, sort_keys=True))
        sys.exit(0 if out.get('ok') else 1)
    else:
        if errors:
            for e in errors:
                print(f"ERROR: {e}", file=sys.stderr)
            sys.exit(1)
        else:
            if warnings:
                for w in warnings:
                    print(f"WARN: {w}")
            print(f"OK: Lint passed for {', '.join(data['checked'])}")
            sys.exit(0)

if __name__ == '__main__':
    main()
