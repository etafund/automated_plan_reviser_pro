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
        'meta': {'tool': 'enforce-stage-readiness', 'bundle_version': VERSION},
        'warnings': warnings or [],
        'errors': errors or [],
        'commands': {'next': 'python3 scripts/enforce-stage-readiness.py --json'},
        'next_command': next_command,
        'fix_command': fix_command,
        'blocked_reason': blocked_reason,
        'retry_safe': retry_safe
    }

def main():
    ap = argparse.ArgumentParser(description='Evaluate v18 stage readiness.')
    ap.add_argument('--readiness', required=True, help='Path to route-readiness.json')
    ap.add_argument('--stage', required=True, help='Stage to check (e.g. preflight, synthesis, final_handoff, synthesis_prompt_submission)')
    ap.add_argument('--json', action='store_true')
    args = ap.parse_args()

    logs_dir = Path('tests/logs/v18/routes/readiness')
    logs_dir.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    log_file = logs_dir / f"readiness_check_{args.stage}_{timestamp}.log"
    logging.basicConfig(filename=log_file, level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')

    errors = []
    warnings = []
    data = {'ready': False, 'blocked_until': []}
    
    try:
        readiness_path = Path(args.readiness)
        if not readiness_path.exists():
            raise FileNotFoundError(f"Readiness file not found: {args.readiness}")
            
        with open(readiness_path, 'r', encoding='utf-8') as f:
            state = json.load(f)

        if args.stage == 'preflight':
            if state.get('preflight_ready'):
                data['ready'] = True
            else:
                errors.append("Preflight is not ready.")
                for b in state.get('blocked', []):
                    errors.append(f"Blocked: {b.get('message')}")
                    
        elif args.stage == 'synthesis':
            if state.get('synthesis_ready'):
                data['ready'] = True
            else:
                errors.append("Synthesis is not ready.")
                if state.get('ready_scope') == 'preflight':
                    errors.append("Scope is preflight-only. Synthesis cannot run from preflight-only scope.")
                
        else:
            stage_data = state.get('stage_readiness', {}).get(args.stage)
            if not stage_data:
                errors.append(f"Stage '{args.stage}' not found in stage_readiness.")
            elif stage_data.get('ready'):
                data['ready'] = True
            else:
                errors.append(f"Stage '{args.stage}' is not ready.")
                blocked_until = stage_data.get('blocked_until', [])
                data['blocked_until'] = blocked_until
                if blocked_until:
                    errors.append(f"Blocked until: {', '.join(blocked_until)}")

        # Check negative circular synthesis logic
        if args.stage == 'synthesis_prompt_submission' and 'chatgpt_pro_synthesis' in state.get('synthesis_prompt_blocked_until_evidence_for', []):
            errors.append("Circular synthesis condition detected.")
            data['ready'] = False
            
        logging.info(f"Checked readiness for stage {args.stage}. Ready: {data['ready']}")

    except Exception as exc:
        errors.append(str(exc))
        logging.error(f"Execution failed: {exc}")

    if errors:
        out = env(
            ok=False,
            errors=[{'error_code': 'stage_not_ready', 'message': e} for e in errors],
            blocked_reason='stage_not_ready',
            data=data,
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
