#!/usr/bin/env python3
# Bundle version: v18.0.0
import argparse, json, sys, os, time, logging
from pathlib import Path
from datetime import datetime, timezone

VERSION = 'v18.0.0'

def env(ok=True, data=None, warnings=None, errors=None, next_command=None, fix_command=None, blocked_reason=None, retry_safe=True):
    return {
        'ok': ok,
        'schema_version': 'json_envelope.v1',
        'data': data or {},
        'meta': {'tool': 'v18-run-ops', 'bundle_version': VERSION},
        'warnings': warnings or [],
        'errors': errors or [],
        'commands': {'next': 'python3 scripts/v18-run-ops.py --json'},
        'next_command': next_command,
        'fix_command': fix_command,
        'blocked_reason': blocked_reason,
        'retry_safe': retry_safe
    }

def get_run_status(run_dir):
    events_file = Path(run_dir) / 'events.jsonl'
    if not events_file.exists():
        return None
    
    events = []
    with open(events_file, 'r', encoding='utf-8') as f:
        for line in f:
            if line.strip():
                try:
                    events.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    
    if not events:
        return None
        
    last_event = events[-1]
    completed_stages = [e['stage'] for e in events if e.get('outcome') == 'succeeded']
    failed_stages = [e['stage'] for e in events if e.get('outcome') == 'failed']
    
    return {
        'run_id': Path(run_dir).name,
        'current_stage': last_event['stage'],
        'last_action': last_event['action'],
        'last_outcome': last_event['outcome'],
        'completed_stages': completed_stages,
        'failed_stages': failed_stages,
        'last_event_at': last_event['timestamp']
    }

def generate_report(run_dir):
    status = get_run_status(run_dir)
    if not status:
        return None
        
    report = {
        'report_version': 'v1',
        'generated_at': datetime.now(timezone.utc).isoformat(),
        'run_status': status,
        'findings': []
    }
    
    # In a real impl, we'd pull findings from reports/ or normalized_plans/
    report_path = Path(run_dir) / 'reports' / 'run_report.json'
    report_path.write_text(json.dumps(report, indent=2))
    return report

def main():
    ap = argparse.ArgumentParser(description='v18 Planning Run Operations.')
    ap.add_argument('--action', choices=['status', 'report', 'resume', 'retry'], required=True)
    ap.add_argument('--run-dir', required=True, help='Path to the planning run directory')
    ap.add_argument('--json', action='store_true')
    args = ap.parse_args()

    logs_dir = Path('tests/logs/v18/run-ops')
    logs_dir.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    log_file = logs_dir / f"run_ops_{args.action}_{timestamp}.log"
    logging.basicConfig(filename=log_file, level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')

    errors = []
    warnings = []
    data = None
    
    try:
        run_dir = Path(args.run_dir)
        if not run_dir.exists():
            raise FileNotFoundError(f"Run directory not found: {args.run_dir}")
            
        if args.action == 'status':
            status = get_run_status(run_dir)
            if not status:
                errors.append("No events found in run directory")
            else:
                data = status
                
        elif args.action == 'report':
            report = generate_report(run_dir)
            if not report:
                errors.append("Could not generate report")
            else:
                data = report
                
        elif args.action == 'resume':
            status = get_run_status(run_dir)
            if not status:
                errors.append("Cannot resume: no state found")
            else:
                # Mock resume logic: find next stage
                data = {'action': 'resume', 'from_stage': status['current_stage'], 'next_steps': 'Execute next stage gate'}
                
        elif args.action == 'retry':
            status = get_run_status(run_dir)
            if not status:
                errors.append("Cannot retry: no state found")
            else:
                data = {'action': 'retry', 'stage': status['current_stage'], 'next_steps': 'Rerunning stage with fresh inputs'}
                
    except Exception as exc:
        errors.append(str(exc))
        logging.error(f"Operation failed: {exc}")

    if errors:
        out = env(ok=False, errors=[{'error_code': 'run_ops_error', 'message': e} for e in errors])
    else:
        out = env(ok=True, data=data, warnings=warnings)

    if args.json:
        print(json.dumps(out, indent=2, sort_keys=True))
    else:
        if errors:
            for e in errors: print(f"ERROR: {e}", file=sys.stderr)
            sys.exit(1)
        else:
            print(f"v18 Run {args.action.capitalize()} complete.")
            if data:
                print(json.dumps(data, indent=2))
            sys.exit(0)

if __name__ == '__main__':
    main()
