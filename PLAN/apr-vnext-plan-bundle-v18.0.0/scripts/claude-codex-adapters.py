#!/usr/bin/env python3
# Bundle version: v18.0.0
import argparse, json, sys, subprocess, logging, time, os
from pathlib import Path

VERSION = 'v18.0.0'

def env(ok=True, data=None, warnings=None, errors=None, next_command=None, fix_command=None, blocked_reason=None, retry_safe=True):
    return {
        'ok': ok,
        'schema_version': 'json_envelope.v1',
        'data': data or {},
        'meta': {'tool': 'claude-codex-adapters', 'bundle_version': VERSION},
        'warnings': warnings or [],
        'errors': errors or [],
        'commands': {'next': 'python3 scripts/claude-codex-adapters.py --json'},
        'next_command': next_command,
        'fix_command': fix_command,
        'blocked_reason': blocked_reason,
        'retry_safe': retry_safe
    }

def main():
    ap = argparse.ArgumentParser(description='Claude and Codex CLI adapters for v18.')
    ap.add_argument('--provider', choices=['claude', 'codex'], required=True)
    ap.add_argument('--action', choices=['invoke', 'intake', 'check'], required=True)
    ap.add_argument('--prompt', help='Path to prompt file')
    ap.add_argument('--output', help='Path to save output')
    ap.add_argument('--json', action='store_true')
    args = ap.parse_args()

    logs_dir = Path('tests/logs/v18/providers/adapters')
    logs_dir.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    log_file = logs_dir / f"{args.provider}_{args.action}_{timestamp}.log"
    logging.basicConfig(filename=log_file, level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')

    errors = []
    warnings = []
    data = {}
    
    try:
        if args.provider == 'claude':
            if args.action == 'check':
                # Check for `claude` binary
                try:
                    res = subprocess.run(['claude', '--version'], capture_output=True, text=True)
                    data['version'] = res.stdout.strip()
                    data['available'] = True
                    logging.info(f"Claude CLI found: {data['version']}")
                except FileNotFoundError:
                    errors.append("Claude CLI ('claude') not found in PATH")
                    data['available'] = False
                    
            elif args.action == 'invoke':
                if not args.prompt: raise ValueError("--prompt is required for invoke")
                # Mock invocation of claude code
                logging.info(f"Invoking Claude with prompt: {args.prompt}")
                # We would run: claude --model claude-opus-4-7 --effort max ...
                data['status'] = 'success'
                data['provider_slot'] = 'claude_code_opus'
                
        elif args.provider == 'codex':
            if args.action == 'check':
                try:
                    res = subprocess.run(['codex', '--version'], capture_output=True, text=True)
                    data['version'] = res.stdout.strip()
                    data['available'] = True
                    logging.info(f"Codex CLI found: {data['version']}")
                except FileNotFoundError:
                    errors.append("Codex CLI ('codex') not found in PATH")
                    data['available'] = False
                    
            elif args.action == 'intake':
                # Capture intake transcript
                logging.info("Capturing Codex CLI intake")
                data['schema_version'] = 'codex_intake.v1'
                data['formal_first_plan'] = False # Per core policy
                data['eligible_for_synthesis'] = False
                
    except Exception as exc:
        errors.append(str(exc))
        logging.error(f"Adapter error: {exc}")

    out = env(
        ok=not errors,
        data=data,
        warnings=warnings,
        errors=[{'error_code': 'adapter_failed', 'message': e} for e in errors]
    )
    
    if args.json:
        print(json.dumps(out, indent=2, sort_keys=True))
    else:
        if errors:
            for e in errors: print(f"ERROR: {e}", file=sys.stderr)
            sys.exit(1)
        else:
            print(f"v18 {args.provider.capitalize()} Adapter: {args.action} success.")
            sys.exit(0)

if __name__ == '__main__':
    main()
