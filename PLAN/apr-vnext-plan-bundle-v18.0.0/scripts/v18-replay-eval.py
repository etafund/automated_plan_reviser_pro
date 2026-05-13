#!/usr/bin/env python3
# Bundle version: v18.0.0
import argparse, json, sys, subprocess, logging, time
from pathlib import Path

VERSION = 'v18.0.0'

def env(ok=True, data=None, warnings=None, errors=None, next_command=None, fix_command=None, blocked_reason=None, retry_safe=True):
    return {
        'ok': ok,
        'schema_version': 'json_envelope.v1',
        'data': data or {},
        'meta': {'tool': 'v18-replay-eval', 'bundle_version': VERSION},
        'warnings': warnings or [],
        'errors': errors or [],
        'commands': {'next': 'python3 scripts/v18-replay-eval.py --json'},
        'next_command': next_command,
        'fix_command': fix_command,
        'blocked_reason': blocked_reason,
        'retry_safe': retry_safe
    }

def run_script(script_name, args):
    script_path = Path(__file__).parent / script_name
    cmd = [sys.executable, str(script_path)] + args + ['--json']
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        return None, f"Script {script_name} failed: {result.stderr or result.stdout}"
    try:
        return json.loads(result.stdout), None
    except json.JSONDecodeError:
        return None, f"Failed to parse JSON from {script_name}: {result.stdout}"

def main():
    ap = argparse.ArgumentParser(description='v18 Replay and Evaluation Harness.')
    ap.add_argument('--input', help='Path to provider_result.json or a planning run directory')
    ap.add_argument('--eval-only', action='store_true', help='Only run plan quality evals')
    ap.add_argument('--json', action='store_true')
    args = ap.parse_args()

    logs_dir = Path('tests/logs/v18/run-state/replay')
    logs_dir.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    log_file = logs_dir / f"replay_{timestamp}.log"
    logging.basicConfig(filename=log_file, level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')

    errors = []
    warnings = []
    replay_data = {'steps': []}
    
    try:
        if not args.input:
            raise ValueError("--input is required")
            
        input_path = Path(args.input)
        
        if input_path.is_file():
            # Assume it's a provider_result.json
            logging.info(f"Replaying from provider result: {input_path}")
            
            # Step 1: Normalize
            norm_res, err = run_script('normalize-plan-ir.py', [str(input_path), '--stage', 'export'])
            if err:
                errors.append(err)
            else:
                replay_data['steps'].append({'stage': 'normalization', 'result': norm_res})
                
                # Step 2: Quality Eval (mocked for now)
                plan_ir = norm_res.get('data', {})
                eval_results = {
                    'traceability_score': 1.0,
                    'ac_coverage': 1.0,
                    'risk_mitigation_score': 1.0,
                    'passed': True
                }
                
                # Basic heuristic check
                if not plan_ir.get('acceptance_criteria'):
                    eval_results['ac_coverage'] = 0.0
                    eval_results['passed'] = False
                    warnings.append("Plan IR missing acceptance criteria")
                
                replay_data['steps'].append({'stage': 'eval', 'result': eval_results})
                logging.info("Quality evaluation complete")

        elif input_path.is_dir():
            # Assume it's a planning run directory
            logging.info(f"Replaying from run directory: {input_path}")
            # Reconstruct state
            state_res, err = run_script('run-state-machine.py', ['--action', 'status', '--run-dir', str(input_path)])
            if err:
                errors.append(err)
            else:
                replay_data['steps'].append({'stage': 'state_reconstruction', 'result': state_res})
        else:
            raise FileNotFoundError(f"Input not found: {args.input}")
            
    except Exception as exc:
        errors.append(str(exc))
        logging.error(f"Replay failed: {exc}")

    out = env(
        ok=not errors,
        data=replay_data,
        warnings=warnings,
        errors=[{'error_code': 'replay_failed', 'message': e} for e in errors]
    )
    
    if args.json:
        print(json.dumps(out, indent=2, sort_keys=True))
    else:
        if errors:
            for e in errors: print(f"ERROR: {e}", file=sys.stderr)
            sys.exit(1)
        else:
            print("v18 Replay and Evaluation complete.")
            print(f"Steps: {[s['stage'] for s in replay_data['steps']]}")
            sys.exit(0)

if __name__ == '__main__':
    main()
