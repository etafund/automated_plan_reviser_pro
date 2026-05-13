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
        'meta': {'tool': 'enforce-review-quorum', 'bundle_version': VERSION},
        'warnings': warnings or [],
        'errors': errors or [],
        'commands': {'next': 'python3 scripts/enforce-review-quorum.py --json'},
        'next_command': next_command,
        'fix_command': fix_command,
        'blocked_reason': blocked_reason,
        'retry_safe': retry_safe
    }

def is_waiver_valid(waiver):
    expires_at = waiver.get('expires_at')
    if expires_at:
        try:
            exp = datetime.fromisoformat(expires_at.replace('Z', '+00:00'))
            if datetime.now(timezone.utc) > exp:
                return False
        except ValueError:
            waiver_id = waiver.get('waiver_id', '<unknown>')
            logging.warning(
                "Unparseable waiver expires_at for waiver_id=%s expires_at=%r; treating as expired",
                waiver_id,
                expires_at,
            )
            return False
    return waiver.get('synthesis_eligible_after_waiver', False)

def main():
    ap = argparse.ArgumentParser(description='Enforce v18 review quorum policy and degradation waivers.')
    ap.add_argument('--policy', required=True, help='Path to review-quorum policy json')
    ap.add_argument('--results', nargs='*', default=[], help='Paths to provider_result.json files')
    ap.add_argument('--waivers', nargs='*', default=[], help='Paths to fallback-waiver.json files')
    ap.add_argument('--json', action='store_true')
    args = ap.parse_args()

    logs_dir = Path('tests/logs/v18/routes/quorum')
    logs_dir.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    log_file = logs_dir / f"quorum_check_{timestamp}.log"
    logging.basicConfig(filename=log_file, level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')

    errors = []
    warnings = []
    data = {'synthesis_eligible': False, 'degraded_labels': []}
    
    try:
        policy = json.loads(Path(args.policy).read_text(encoding='utf-8'))
        
        provider_status = {}
        for r_path in args.results:
            res = json.loads(Path(r_path).read_text(encoding='utf-8'))
            slot = res.get('provider_slot')
            status = res.get('status')
            if slot and status:
                provider_status[slot] = status
                
        valid_waivers = {}
        for w_path in args.waivers:
            w = json.loads(Path(w_path).read_text(encoding='utf-8'))
            slot = w.get('provider_slot')
            if slot and is_waiver_valid(w):
                valid_waivers[slot] = w

        eligible_statuses = policy.get('eligible_statuses', ['success', 'cached'])
        
        req_slots = policy.get('independent_review_required_slots', [])
        opt_slots = policy.get('independent_review_optional_slots', [])
        min_opt = policy.get('optional_review_min_successes', 0)
        min_tot = policy.get('independent_review_min_total', 0)
        
        # Check required
        for req in req_slots:
            stat = provider_status.get(req, 'missing')
            if stat not in eligible_statuses:
                if req in valid_waivers:
                    data['degraded_labels'].append(f"Waived required reviewer: {req}")
                    logging.info(f"Required reviewer {req} is {stat}, but waived via {valid_waivers[req].get('waiver_id')}")
                else:
                    errors.append(f"Required reviewer {req} is missing or ineligible ({stat}) and has no valid waiver.")
                    
        # Check optional
        opt_successes = sum(1 for o in opt_slots if provider_status.get(o) in eligible_statuses)
        opt_waived = sum(1 for o in opt_slots if provider_status.get(o) not in eligible_statuses and o in valid_waivers)
        
        if opt_successes < min_opt:
            if opt_successes + opt_waived >= min_opt:
                data['degraded_labels'].append(f"Waived {min_opt - opt_successes} optional reviewers")
                logging.info(f"Optional reviewers short by {min_opt - opt_successes}, but satisfied via waivers.")
            else:
                errors.append(f"Optional reviewers: {opt_successes} eligible, {opt_waived} waived. Requires {min_opt}.")
                
        # Check total
        tot_successes = sum(1 for s in req_slots + opt_slots if provider_status.get(s) in eligible_statuses)
        tot_waived = sum(1 for s in req_slots + opt_slots if provider_status.get(s) not in eligible_statuses and s in valid_waivers)
        
        if tot_successes < min_tot:
            if tot_successes + tot_waived >= min_tot:
                if "Waived total reviewer count" not in data['degraded_labels']:
                    data['degraded_labels'].append("Waived total reviewer count")
                logging.info(f"Total reviewers short, but satisfied via waivers.")
            else:
                errors.append(f"Total independent reviewers: {tot_successes} eligible, {tot_waived} waived. Requires {min_tot}.")
                
        if not errors:
            data['synthesis_eligible'] = True
            
        logging.info(f"Quorum check complete. Synthesis eligible: {data['synthesis_eligible']}. Degraded labels: {data['degraded_labels']}")
        
    except Exception as exc:
        errors.append(str(exc))
        logging.error(f"Execution failed: {exc}")

    if errors:
        out = env(
            ok=False,
            errors=[{'error_code': 'quorum_not_met', 'message': e} for e in errors],
            blocked_reason='review_quorum_failed',
            data=data,
            retry_safe=True
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
            print(json.dumps(data, indent=2, sort_keys=True))
            sys.exit(0)

if __name__ == '__main__':
    main()
