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
        'meta': {'tool': 'compile-prompt', 'bundle_version': VERSION},
        'warnings': warnings or [],
        'errors': errors or [],
        'commands': {'next': 'python3 scripts/compile-prompt.py --json'},
        'next_command': next_command,
        'fix_command': fix_command,
        'blocked_reason': blocked_reason,
        'retry_safe': retry_safe
    }

def main():
    ap = argparse.ArgumentParser(description='Compile v18 provider-specific prompts.')
    ap.add_argument('--route', required=True, help='Route slot (e.g. chatgpt_pro_first_plan)')
    ap.add_argument('--baseline', help='Path to source-baseline.json')
    ap.add_argument('--manifest', help='Path to prompt-manifest.json')
    ap.add_argument('--policy', default='PLAN/apr-vnext-plan-bundle-v18.0.0/fixtures/prompting-policy.json', help='Path to prompting-policy.json')
    ap.add_argument('--json', action='store_true')
    args = ap.parse_args()

    logs_dir = Path('tests/logs/v18/prompts/compile')
    logs_dir.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    log_file = logs_dir / f"compile_{args.route}_{timestamp}.log"
    logging.basicConfig(filename=log_file, level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')

    errors = []
    warnings = []
    data = None
    
    try:
        policy_path = Path(args.policy)
        if not policy_path.exists():
            raise FileNotFoundError(f"Policy file not found: {args.policy}")
            
        with open(policy_path, 'r', encoding='utf-8') as f:
            policy_data = json.load(f)
            
        policies = policy_data.get('policies', {})
        
        # Map route to policy key
        policy_key = None
        if 'chatgpt' in args.route: policy_key = 'chatgpt_pro_browser'
        elif 'claude' in args.route: policy_key = 'claude_code'
        elif 'deepseek' in args.route: policy_key = 'deepseek_v4_pro_api'
        elif 'gemini' in args.route: policy_key = 'gemini_deep_think_browser'
        elif 'xai' in args.route: policy_key = 'xai_grok_api'
        
        if not policy_key or policy_key not in policies:
            if 'codex' in args.route:
                provider_rules = policy_data.get('codex_intake_policy', {}).get('recommended', [])
            else:
                raise ValueError(f"No prompt policy found for route: {args.route}")
        else:
            provider_rules = policies[policy_key].get('rules', [])
            
        # Compile prompt content
        prompt_parts = []
        prompt_parts.append(f"Role: You are an expert acting in the {args.route} capacity.")
        prompt_parts.append("Provider Rules:")
        for rule in provider_rules:
            prompt_parts.append(f"- {rule}")
            
        # Add baseline and manifest hashes just to make the prompt deterministic on inputs
        baseline_hash = "unknown"
        if args.baseline and Path(args.baseline).exists():
            baseline_hash = json.loads(Path(args.baseline).read_text()).get('source_baseline_sha256', 'unknown')
        
        manifest_hash = "unknown"
        if args.manifest and Path(args.manifest).exists():
            manifest_hash = json.loads(Path(args.manifest).read_text()).get('prompt_manifest_sha256', 'unknown')
            
        prompt_parts.append(f"Baseline Hash: {baseline_hash}")
        prompt_parts.append(f"Manifest Hash: {manifest_hash}")
        
        raw_prompt = "\n".join(prompt_parts)
        prompt_hash = f"sha256:{hashlib.sha256(raw_prompt.encode('utf-8')).hexdigest()}"
        
        # Redacted preview (just the rules and metadata, no sensitive source content in this mock)
        redacted_preview = raw_prompt
        
        data = {
            'route': args.route,
            'prompt_hash': prompt_hash,
            'redacted_preview': redacted_preview,
            'provider_rules': provider_rules
        }
        
        logging.info(f"Compiled prompt for {args.route}. Hash: {prompt_hash}")
        
    except Exception as exc:
        errors.append(str(exc))
        logging.error(f"Execution failed: {exc}")

    if errors:
        out = env(
            ok=False,
            errors=[{'error_code': 'compilation_failed', 'message': e} for e in errors],
            blocked_reason='prompt_compilation_error',
            retry_safe=True
        )
    else:
        out = env(ok=True, data=data, warnings=warnings)

    if args.json:
        print(json.dumps(out, indent=2, sort_keys=True))
    else:
        if errors:
            for e in errors:
                print(f"ERROR: {e}", file=sys.stderr)
            sys.exit(1)
        else:
            print(json.dumps(data, indent=2, sort_keys=True))
            sys.exit(0)

if __name__ == '__main__':
    main()
