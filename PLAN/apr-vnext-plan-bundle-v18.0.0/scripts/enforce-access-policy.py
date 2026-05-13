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
        'meta': {'tool': 'enforce-access-policy', 'bundle_version': VERSION},
        'warnings': warnings or [],
        'errors': errors or [],
        'commands': {'next': 'python3 scripts/enforce-access-policy.py --json'},
        'next_command': next_command,
        'fix_command': fix_command,
        'blocked_reason': blocked_reason,
        'retry_safe': retry_safe
    }

def main():
    ap = argparse.ArgumentParser(description='Enforce v18 provider access policy.')
    ap.add_argument('--route', required=True, help='The provider route slot requested (e.g., chatgpt_pro_first_plan)')
    ap.add_argument('--access-path', required=True, help='The access path to use (e.g., oracle_browser_remote, openai_api)')
    ap.add_argument('--formal-first-plan', action='store_true', help='Flag if this request is intended to satisfy the formal first plan requirement')
    ap.add_argument('--policy-file', default='PLAN/apr-vnext-plan-bundle-v18.0.0/fixtures/provider-access-policy.json', help='Path to the policy file')
    ap.add_argument('--json', action='store_true', help='Output structured JSON')
    args = ap.parse_args()

    logs_dir = Path('tests/logs/v18/providers/access-policy')
    logs_dir.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    log_file = logs_dir / f"access_enforcement_{args.route}_{timestamp}.log"
    logging.basicConfig(filename=log_file, level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')

    errors = []
    
    try:
        policy_path = Path(args.policy_file)
        if not policy_path.exists():
            raise FileNotFoundError(f"Policy file not found: {args.policy_file}")
            
        with open(policy_path, 'r', encoding='utf-8') as f:
            policy = json.load(f)
            
        routes = policy.get('live_routes', {})
        if args.route not in routes:
            errors.append(f"Route '{args.route}' is not defined in the access policy.")
        else:
            route_policy = routes[args.route]
            allowed_access = route_policy.get('access_path')
            
            # Check access path
            if allowed_access == 'oracle_browser_remote_or_local':
                valid_paths = ['oracle_browser_remote', 'oracle_browser_local']
                if args.access_path not in valid_paths:
                    errors.append(f"Access path '{args.access_path}' is prohibited for route '{args.route}'. Allowed: {valid_paths}.")
            elif args.access_path != allowed_access:
                errors.append(f"Access path '{args.access_path}' is prohibited for route '{args.route}'. Allowed: {allowed_access}.")
                
            # Check formal first plan constraint
            if args.formal_first_plan and not route_policy.get('eligible_for_synthesis', False):
                errors.append(f"Route '{args.route}' is not eligible for synthesis and cannot satisfy formal first plan requirements.")
                
        decision = "DENIED" if errors else "ALLOWED"
        logging.info(f"Policy check: Route={args.route}, AccessPath={args.access_path}, FormalFirstPlan={args.formal_first_plan} -> {decision}")
        if errors:
            for e in errors:
                logging.error(f"Reason: {e}")
                
    except Exception as exc:
        errors.append(str(exc))
        logging.error(f"Execution failed: {exc}")

    if errors:
        out = env(
            ok=False,
            errors=[{'error_code': 'policy_violation', 'message': e} for e in errors],
            blocked_reason='provider_access_prohibited',
            fix_command='Review allowed access paths in fixtures/provider-access-policy.json',
            retry_safe=False
        )
    else:
        out = env(ok=True, data={'route': args.route, 'access_path': args.access_path, 'decision': 'ALLOWED'})

    if args.json:
        print(json.dumps(out, indent=2, sort_keys=True))
    else:
        if errors:
            for e in errors:
                print(f"ERROR: {e}", file=sys.stderr)
            sys.exit(1)
        else:
            print(f"OK: Access allowed for route {args.route} via {args.access_path}")
            sys.exit(0)

if __name__ == '__main__':
    main()
