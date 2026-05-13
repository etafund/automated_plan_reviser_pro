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
        'meta': {'tool': 'plan-export-beads', 'bundle_version': VERSION},
        'warnings': warnings or [],
        'errors': errors or [],
        'commands': {'next': 'python3 scripts/export-beads.py --json'},
        'next_command': next_command,
        'fix_command': fix_command,
        'blocked_reason': blocked_reason,
        'retry_safe': retry_safe
    }

def main():
    ap = argparse.ArgumentParser(description='Export v18 Plan IR items to beads.')
    ap.add_argument('--plan', required=True, help='Path to bead-export-ready plan-artifact.json')
    ap.add_argument('--dry-run', action='store_true', help='Preview proposed beads without creating them')
    ap.add_argument('--json', action='store_true')
    args = ap.parse_args()

    logs_dir = Path('tests/logs/v18/plan/export')
    logs_dir.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    log_file = logs_dir / f"export_{timestamp}.log"
    logging.basicConfig(filename=log_file, level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')

    errors = []
    warnings = []
    created_beads = []
    
    try:
        plan_path = Path(args.plan)
        if not plan_path.exists():
            raise FileNotFoundError(f"Plan file not found: {args.plan}")
            
        plan = json.loads(plan_path.read_text(encoding='utf-8'))
        
        if plan.get('stage') != 'bead_export_ready':
            warnings.append(f"Plan is in stage '{plan.get('stage')}', expected 'bead_export_ready'")

        plan_items = plan.get('plan_items', [])
        logging.info(f"Input artifact hash: {hash(plan_path.read_text())}") # Basic hash for logging
        
        for item in plan_items:
            title = item.get('title')
            body = item.get('description', '')
            priority = item.get('priority_suggestion', 1)
            item_id = item.get('item_id')
            
            # Format the body to include subtasks and metadata
            full_body = body + "\n\n"
            subtasks = item.get('subtasks', [])
            if subtasks:
                full_body += "## Subtasks\n"
                for st in subtasks:
                    full_body += f"- {st.get('title')}: {st.get('description')}\n"
            
            full_body += f"\n---\nItem ID: {item_id}\n"
            
            if args.dry_run:
                logging.info(f"DRY RUN: Proposed bead: {title} (P{priority})")
                created_beads.append({'title': title, 'priority': priority, 'item_id': item_id, 'status': 'proposed'})
            else:
                # Create the bead using `br create`
                # Usage: br create "title" --type task --description "..." --priority 1 --json
                try:
                    cmd = [
                        'br',
                        'create',
                        title,
                        '--type',
                        'task',
                        '--description',
                        full_body,
                        '--priority',
                        str(priority),
                        '--json',
                    ]
                    logging.info("Executing: br create %r --type task --description <body> --priority %s --json", title, priority)
                    result = subprocess.run(cmd, check=True, capture_output=True, text=True)
                    bead = json.loads(result.stdout)
                    created_beads.append({
                        'title': title,
                        'priority': priority,
                        'item_id': item_id,
                        'status': 'created',
                        'bead_id': bead.get('id'),
                    })
                except FileNotFoundError:
                    created_beads.append({'title': title, 'priority': priority, 'item_id': item_id, 'status': 'failed'})
                    errors.append(f"Failed to create bead '{title}': 'br' CLI not found in PATH")
                except subprocess.CalledProcessError as e:
                    created_beads.append({'title': title, 'priority': priority, 'item_id': item_id, 'status': 'failed'})
                    detail = e.stderr.strip() or e.stdout.strip() or f"exit code {e.returncode}"
                    errors.append(f"Failed to create bead '{title}': br exited {e.returncode}: {detail}")
                except json.JSONDecodeError as e:
                    created_beads.append({'title': title, 'priority': priority, 'item_id': item_id, 'status': 'failed'})
                    errors.append(f"Failed to parse br create output for bead '{title}': {e}")
                except Exception as e:
                    created_beads.append({'title': title, 'priority': priority, 'item_id': item_id, 'status': 'failed'})
                    errors.append(f"Failed to create bead '{title}': {e}")

        logging.info(f"Export complete. Items processed: {len(plan_items)}")

    except Exception as exc:
        errors.append(str(exc))
        logging.error(f"Export failed: {exc}")

    out = env(
        ok=not errors,
        data={'created_beads': created_beads},
        warnings=warnings,
        errors=[{'error_code': 'export_failed', 'message': e} for e in errors]
    )
    
    if args.json:
        print(json.dumps(out, indent=2, sort_keys=True))
        sys.exit(0 if out.get('ok') else 1)
    else:
        if errors:
            for e in errors: print(f"ERROR: {e}", file=sys.stderr)
            sys.exit(1)
        else:
            status = "Proposed" if args.dry_run else "Created"
            print(f"v18 Plan Export complete. {status} {len(created_beads)} beads.")
            sys.exit(0)

if __name__ == '__main__':
    main()
