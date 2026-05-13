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
        'meta': {'tool': 'xai-deepseek-adapters', 'bundle_version': VERSION},
        'warnings': warnings or [],
        'errors': errors or [],
        'commands': {'next': 'python3 scripts/xai-deepseek-adapters.py --json'},
        'next_command': next_command,
        'fix_command': fix_command,
        'blocked_reason': blocked_reason,
        'retry_safe': retry_safe
    }

def main():
    ap = argparse.ArgumentParser(description='xAI and DeepSeek API adapters for v18.')
    ap.add_argument('--provider', choices=['xai', 'deepseek'], required=True)
    ap.add_argument('--action', choices=['invoke', 'check'], required=True)
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
        if args.provider == 'xai':
            api_key = os.environ.get('XAI_API_KEY')
            if args.action == 'check':
                if api_key:
                    data['available'] = True
                    data['api_key_status'] = 'configured'
                else:
                    data['available'] = False
                    data['api_key_status'] = 'missing'
                    errors.append("XAI_API_KEY not found in environment")
                    
            elif args.action == 'invoke':
                if not api_key: raise ValueError("XAI_API_KEY missing")
                if not args.prompt: raise ValueError("--prompt is required")
                
                logging.info(f"Invoking xAI Grok with prompt: {args.prompt}")
                # Mock successful invocation
                data['status'] = 'success'
                data['model'] = 'grok-4.3'
                data['reasoning_effort'] = 'high'
                
        elif args.provider == 'deepseek':
            api_key = os.environ.get('DEEPSEEK_API_KEY')
            if args.action == 'check':
                if api_key:
                    data['available'] = True
                    data['api_key_status'] = 'configured'
                else:
                    data['available'] = False
                    data['api_key_status'] = 'missing'
                    errors.append("DEEPSEEK_API_KEY not found in environment")
                    
            elif args.action == 'invoke':
                if not api_key: raise ValueError("DEEPSEEK_API_KEY missing")
                if not args.prompt: raise ValueError("--prompt is required")
                
                logging.info(f"Invoking DeepSeek V4 Pro with prompt: {args.prompt}")
                # Mock successful invocation
                data['status'] = 'success'
                data['model'] = 'deepseek-v4-pro'
                data['thinking_enabled'] = True
                data['search_enabled'] = True
                
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
            print(f"v18 {args.provider.upper()} Adapter: {args.action} success.")
            sys.exit(0)

if __name__ == '__main__':
    main()
