#!/usr/bin/env python3
# Bundle version: v18.0.0
import argparse, json, sys, logging, time
from pathlib import Path
from datetime import datetime, timezone

VERSION = 'v18.0.0'

def env(ok=True, data=None, warnings=None, errors=None, next_command=None, fix_command=None, blocked_reason=None, retry_safe=True):
    return {
        'ok': ok,
        'schema_version': 'json_envelope.v1',
        'data': data or {},
        'meta': {'tool': 'enforce-runtime-budget', 'bundle_version': VERSION},
        'warnings': warnings or [],
        'errors': errors or [],
        'commands': {'next': 'python3 scripts/enforce-runtime-budget.py --json'},
        'next_command': next_command,
        'fix_command': fix_command,
        'blocked_reason': blocked_reason,
        'retry_safe': retry_safe
    }

def main():
    ap = argparse.ArgumentParser(description='Enforce v18 runtime budgets and track progress.')
    ap.add_argument('--budget', required=True, help='Path to runtime-budget.json')
    ap.add_argument('--progress', required=True, help='Path to run-progress.json')
    ap.add_argument('--elapsed-minutes', type=float, default=0.0, help='Total elapsed wall minutes')
    ap.add_argument('--total-cost-usd', type=float, default=0.0, help='Total estimated cost in USD')
    ap.add_argument('--json', action='store_true')
    args = ap.parse_args()

    logs_dir = Path('tests/logs/v18/routes/budget')
    logs_dir.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    log_file = logs_dir / f"budget_check_{timestamp}.log"
    logging.basicConfig(filename=log_file, level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')

    errors = []
    warnings = []
    data = None
    
    try:
        budget_path = Path(args.budget)
        progress_path = Path(args.progress)
        
        if not budget_path.exists(): raise FileNotFoundError(f"Budget file not found: {args.budget}")
        if not progress_path.exists(): raise FileNotFoundError(f"Progress file not found: {args.progress}")
            
        with open(budget_path, 'r', encoding='utf-8') as f:
            budget = json.load(f)
        with open(progress_path, 'r', encoding='utf-8') as f:
            progress = json.load(f)

        max_wall = budget.get('max_wall_minutes', 180)
        max_cost = budget.get('max_cost_usd', 50.0)
        
        if args.elapsed_minutes > max_wall:
            errors.append(f"Runtime exceeded wall budget: {args.elapsed_minutes:.1f}m > {max_wall}m")
            
        if args.total_cost_usd > max_cost:
            errors.append(f"Runtime exceeded cost budget: ${args.total_cost_usd:.2f} > ${max_cost:.2f}")

        # Update progress snapshot (in-memory for this tool return)
        updated_progress = dict(progress)
        updated_progress['last_event_at'] = datetime.now(timezone.utc).isoformat()
        
        # Calculate progress percent if it was simple
        all_stages = progress.get('completed_stages', []) + progress.get('pending_stages', [])
        if all_stages:
            updated_progress['progress_percent'] = int((len(progress.get('completed_stages', [])) / len(all_stages)) * 100)

        data = {
            'budget_ok': len(errors) == 0,
            'elapsed_minutes': args.elapsed_minutes,
            'total_cost_usd': args.total_cost_usd,
            'remaining_wall_minutes': max(0.0, max_wall - args.elapsed_minutes),
            'remaining_cost_usd': max(0.0, max_cost - args.total_cost_usd),
            'updated_progress': updated_progress
        }
        
        logging.info(f"Budget Check: Wall={args.elapsed_minutes}/{max_wall}m, Cost=${args.total_cost_usd}/${max_cost} -> {'OK' if data['budget_ok'] else 'FAILED'}")

    except Exception as exc:
        errors.append(str(exc))
        logging.error(f"Execution failed: {exc}")

    if errors:
        out = env(
            ok=False,
            errors=[{'error_code': 'budget_exceeded', 'message': e} for e in errors],
            blocked_reason='runtime_budget_exceeded',
            data=data,
            retry_safe=False # Cost/Time limits are hard stops
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
            print(f"OK: Run is within budget. Progress: {data['updated_progress']['progress_percent']}%")
            sys.exit(0)

if __name__ == '__main__':
    main()
