#!/usr/bin/env python3
# Bundle version: v18.0.0
import argparse, json, sys, os, time, uuid, logging
from pathlib import Path
from datetime import datetime, timezone

VERSION = 'v18.0.0'

VALID_STAGES = [
    'pending', 'ready', 'running', 'blocked', 'degraded', 'waiting', 
    'manual_import', 'failed', 'success', 'skipped', 'cached'
]

def generate_run_id():
    # Format: run-<timestamp>-<uuid4>
    return f"run-{datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S')}-{uuid.uuid4().hex[:8]}"

def init_run_layout(base_dir, run_id):
    run_dir = Path(base_dir) / 'runs' / 'planning' / run_id
    dirs = [
        'inputs',
        'provider_requests',
        'provider_results',
        'evidence',
        'normalized_plans',
        'comparison',
        'synthesis',
        'traceability',
        'reports',
        'logs'
    ]
    for d in dirs:
        (run_dir / d).mkdir(parents=True, exist_ok=True)
        
    # Init events.jsonl
    events_file = run_dir / 'events.jsonl'
    if not events_file.exists():
        events_file.touch()
        
    return run_dir

def append_event(run_dir, stage, action, artifact_ids=None, outcome=None, retry_safe=True):
    events_file = Path(run_dir) / 'events.jsonl'
    event = {
        'schema_version': 'run_event.v1',
        'timestamp': datetime.now(timezone.utc).isoformat(),
        'stage': stage,
        'action': action,
        'artifact_ids': artifact_ids or [],
        'outcome': outcome,
        'retry_safe': retry_safe
    }
    with open(events_file, 'a', encoding='utf-8') as f:
        f.write(json.dumps(event) + '\n')
    return event

def reconstruct_state(run_dir):
    events_file = Path(run_dir) / 'events.jsonl'
    state = {}
    if not events_file.exists():
        return state
        
    with open(events_file, 'r', encoding='utf-8') as f:
        for line in f:
            if not line.strip(): continue
            try:
                evt = json.loads(line)
                stage = evt.get('stage')
                if stage:
                    state[stage] = evt
            except json.JSONDecodeError:
                # Tolerate partial/corrupt trailing lines
                pass
    return state

def env(ok=True, data=None, warnings=None, errors=None, next_command=None, fix_command=None, blocked_reason=None):
    return {
        'ok': ok,
        'schema_version': 'json_envelope.v1',
        'data': data or {},
        'meta': {'tool': 'run-state-machine', 'bundle_version': VERSION},
        'warnings': warnings or [],
        'errors': errors or [],
        'commands': {'next': 'python3 scripts/run-state-machine.py --json'},
        'next_command': next_command,
        'fix_command': fix_command,
        'blocked_reason': blocked_reason,
        'retry_safe': True
    }

def main():
    ap = argparse.ArgumentParser(description='Manage v18 planning run state machine and layout.')
    ap.add_argument('--action', choices=['init', 'event', 'status'], required=True)
    ap.add_argument('--run-dir', help='Path to .apr directory or run directory')
    ap.add_argument('--stage', help='Stage name for event')
    ap.add_argument('--event-action', help='Action name for event')
    ap.add_argument('--outcome', help='Outcome state from VALID_STAGES')
    ap.add_argument('--json', action='store_true')
    args = ap.parse_args()

    logs_dir = Path('tests/logs/v18/run-state')
    logs_dir.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    log_file = logs_dir / f"run_state_{args.action}_{timestamp}.log"
    logging.basicConfig(filename=log_file, level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')

    errors = []
    warnings = []
    data = None
    
    try:
        if args.action == 'init':
            base_dir = args.run_dir or '.apr'
            run_id = generate_run_id()
            run_dir = init_run_layout(base_dir, run_id)
            append_event(run_dir, 'run_lifecycle', 'initialized', outcome='pending')
            data = {'run_id': run_id, 'run_dir': str(run_dir)}
            logging.info(f"Initialized run {run_id} at {run_dir}")
            
        elif args.action == 'event':
            if not args.run_dir or not args.stage or not args.event_action or not args.outcome:
                raise ValueError("--run-dir, --stage, --event-action, and --outcome required for event action")
            if args.outcome not in VALID_STAGES:
                raise ValueError(f"Invalid outcome. Must be one of {VALID_STAGES}")
                
            evt = append_event(args.run_dir, args.stage, args.event_action, outcome=args.outcome)
            data = {'event': evt}
            logging.info(f"Appended event: {args.stage} transition to {args.outcome} via {args.event_action}")
            
        elif args.action == 'status':
            if not args.run_dir:
                raise ValueError("--run-dir required for status action")
            state = reconstruct_state(args.run_dir)
            data = {'state': state}
            logging.info(f"Reconstructed state for {args.run_dir}")
            
    except Exception as exc:
        errors.append(str(exc))
        logging.error(f"Execution failed: {exc}")

    if errors:
        out = env(
            ok=False,
            errors=[{'error_code': 'state_machine_error', 'message': e} for e in errors],
            blocked_reason='state_machine_failed'
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
