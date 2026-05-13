#!/usr/bin/env python3
# Bundle version: v18.0.0
import argparse
import json
import logging
import subprocess
import sys
import time
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
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        return None, f"Script {script_name} failed: {result.stderr or result.stdout}"
    try:
        return json.loads(result.stdout), None
    except json.JSONDecodeError:
        return None, f"Failed to parse JSON from {script_name}: {result.stdout}"

def append_error(errors, error_code, message):
    errors.append({'error_code': error_code, 'message': message})

def nonempty_list(value):
    return isinstance(value, list) and len(value) > 0

def evaluate_plan_ir(plan_ir):
    acceptance_criteria = plan_ir.get('acceptance_criteria_records') or plan_ir.get('acceptance_criteria')
    risks = plan_ir.get('risks')
    trace_refs = (
        plan_ir.get('provider_result_refs')
        or plan_ir.get('source_refs')
        or plan_ir.get('evidence_refs')
        or plan_ir.get('human_decision_ids')
    )

    failures = []
    if not nonempty_list(acceptance_criteria):
        failures.append('Plan IR missing acceptance criteria')
    if not nonempty_list(trace_refs):
        failures.append('Plan IR missing traceability references')
    if not nonempty_list(risks):
        failures.append('Plan IR missing risk mitigation data')

    return {
        'traceability_score': 1.0 if nonempty_list(trace_refs) else 0.0,
        'ac_coverage': 1.0 if nonempty_list(acceptance_criteria) else 0.0,
        'risk_mitigation_score': 1.0 if nonempty_list(risks) else 0.0,
        'passed': not failures,
        'failures': failures,
    }

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
            if args.eval_only:
                logging.info(f"Evaluating Plan IR directly: {input_path}")
                plan_ir = json.loads(input_path.read_text(encoding='utf-8'))
            else:
                # Assume it's a provider_result.json
                logging.info(f"Replaying from provider result: {input_path}")

                # Step 1: Normalize
                norm_res, err = run_script('normalize-plan-ir.py', [str(input_path), '--stage', 'export'])
                if err:
                    append_error(errors, 'normalization_failed', err)
                    plan_ir = None
                else:
                    replay_data['steps'].append({'stage': 'normalization', 'result': norm_res})
                    plan_ir = norm_res.get('data', {})

            if plan_ir is not None:
                eval_results = evaluate_plan_ir(plan_ir)
                for failure in eval_results['failures']:
                    warnings.append(failure)
                    append_error(errors, 'eval_failed', failure)

                replay_data['steps'].append({'stage': 'eval', 'result': eval_results})
                logging.info("Quality evaluation complete")

        elif input_path.is_dir():
            # Assume it's a planning run directory
            logging.info(f"Replaying from run directory: {input_path}")
            # Reconstruct state
            state_res, err = run_script('run-state-machine.py', ['--action', 'status', '--run-dir', str(input_path)])
            if err:
                append_error(errors, 'replay_failed', err)
            else:
                replay_data['steps'].append({'stage': 'state_reconstruction', 'result': state_res})
        else:
            raise FileNotFoundError(f"Input not found: {args.input}")
            
    except Exception as exc:
        append_error(errors, 'replay_failed', str(exc))
        logging.error(f"Replay failed: {exc}")

    out = env(
        ok=not errors,
        data=replay_data,
        warnings=warnings,
        errors=errors,
        blocked_reason=errors[0]['error_code'] if errors else None,
    )
    
    if args.json:
        print(json.dumps(out, indent=2, sort_keys=True))
        sys.exit(0 if out.get('ok') else 1)
    else:
        if errors:
            for error in errors:
                print(f"ERROR: {error['message']}", file=sys.stderr)
            sys.exit(1)
        else:
            print("v18 Replay and Evaluation complete.")
            print(f"Steps: {[s['stage'] for s in replay_data['steps']]}")
            sys.exit(0)

if __name__ == '__main__':
    main()
