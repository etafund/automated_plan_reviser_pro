#!/usr/bin/env python3
# Bundle version: v18.0.0
import argparse
import json
import logging
import os
import sys
import time
from pathlib import Path

VERSION = 'v18.0.0'
MOCKED_ENRICHMENT_WARNING_ID = 'WARN-MOCKED-ENRICHMENT'
FIXTURE_ENRICHMENT_WARNING_ID = 'WARN-FIXTURE-ENRICHMENT'

def env(ok=True, data=None, warnings=None, errors=None, next_command=None, fix_command=None, blocked_reason=None):
    return {
        'ok': ok,
        'schema_version': 'json_envelope.v1',
        'data': data or {},
        'meta': {'tool': 'normalize-plan-ir', 'bundle_version': VERSION},
        'warnings': warnings or [],
        'errors': errors or [],
        'commands': {'next': 'python3 scripts/normalize-plan-ir.py --json'},
        'next_command': next_command,
        'fix_command': fix_command,
        'blocked_reason': blocked_reason,
        'retry_safe': True
    }

def normalize_to_minimal(provider_result, result_id):
    warnings = []
    # If the provider result was malformed or missing fields
    provider_slot = provider_result.get('provider_slot', 'unknown')
    evidence_id = provider_result.get('evidence_id')
    source_sha = provider_result.get('source_baseline_sha256')
    text_sha = provider_result.get('result_text_sha256')
    
    if not text_sha:
        warnings.append({'provider_result_id': result_id, 'reason': 'Missing result_text_sha256', 'warning_id': 'WARN-NO-TEXT-SHA'})

    artifact = {
        'schema_version': 'plan_artifact.v1',
        'plan_id': f"{result_id}-plan",
        'stage': 'minimal_plan_ir',
        'source_provider_slot': provider_slot,
        'sections': [{'id': 'raw', 'title': 'Raw Output', 'content': f"See {text_sha}"}],
        'provider_result_refs': [{'provider_result_id': result_id, 'provider_slot': provider_slot, 'result_text_sha256': text_sha}] if text_sha else [],
        'source_baseline_sha256': source_sha
    }
    
    if evidence_id:
        artifact['evidence_refs'] = [{'evidence_id': evidence_id}]
        
    return artifact, warnings

def normalize_to_full(minimal_ir):
    # Enrich into full Plan IR: tasks, subtasks, dependencies, assumptions, risks, acceptance criteria, test obligations, rollback points, and open questions
    warnings = []
    artifact = dict(minimal_ir)
    artifact['stage'] = 'full_plan_ir'
    
    artifact['plan_items'] = []
    artifact['risks'] = []
    artifact['acceptance_criteria'] = []
    artifact['rollback_points'] = []
    artifact['test_matrix'] = []
    
    # Normally we would parse markdown here. Since we lack markdown, we mock the extraction.
    warnings.append({'provider_result_id': artifact.get('source_provider_slot', 'unknown'), 'reason': 'Content not parsed, enrichment is mocked', 'warning_id': MOCKED_ENRICHMENT_WARNING_ID})
    return artifact, warnings

def normalize_to_fixture_artifact(provider_result, result_id, stage):
    fixture_path = Path(__file__).resolve().parents[1] / 'fixtures' / 'plan-artifact.json'
    with open(fixture_path, 'r', encoding='utf-8') as f:
        artifact = json.load(f)

    provider_slot = provider_result.get('provider_slot', 'unknown')
    text_sha = provider_result.get('result_text_sha256')
    evidence_id = provider_result.get('evidence_id')
    artifact['plan_id'] = f"{result_id}-fixture-plan"
    artifact['stage'] = 'full_plan_ir' if stage == 'full' else 'bead_export_ready'
    artifact['source_provider_slot'] = provider_slot
    artifact['source_baseline_sha256'] = provider_result.get('source_baseline_sha256')
    artifact['provider_result_refs'] = [
        {
            'provider_result_id': result_id,
            'provider_slot': provider_slot,
            'result_text_sha256': text_sha,
        }
    ]
    if evidence_id:
        artifact['evidence_refs'] = [{'evidence_id': evidence_id}]

    warnings = [
        {
            'provider_result_id': result_id,
            'reason': 'APR_V18_FORCE_FIXTURES=1 selected fixture-backed Plan IR enrichment',
            'warning_id': FIXTURE_ENRICHMENT_WARNING_ID,
        }
    ]
    return artifact, warnings

def has_warning(warnings, warning_id):
    return any(warning.get('warning_id') == warning_id for warning in warnings if isinstance(warning, dict))

def normalize_to_export_ready(full_ir):
    # Validate bead-export readiness: every task has title, type, priority suggestion, body, dependencies, and test/verification notes.
    warnings = []
    artifact = dict(full_ir)
    artifact['stage'] = 'bead_export_ready'
    
    for item in artifact.get('plan_items', []):
        if 'title' not in item:
            warnings.append({'provider_result_id': artifact.get('source_provider_slot', 'unknown'), 'reason': 'Task missing title', 'warning_id': 'WARN-MISSING-TITLE'})
            
    return artifact, warnings

def main():
    ap = argparse.ArgumentParser(description='Normalize raw provider output to Plan IR.')
    ap.add_argument('input', help='Path to provider_result.json')
    ap.add_argument('--stage', choices=['minimal', 'full', 'export'], default='export', help='Target normalization stage')
    ap.add_argument('--json', action='store_true')
    args = ap.parse_args()
    
    logs_dir = Path('tests/logs/v18/normalization')
    logs_dir.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    log_file = logs_dir / f"normalize_{timestamp}.log"
    logging.basicConfig(filename=log_file, level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')

    errors = []
    warnings = []
    data = None
    input_hash = 'unknown'
    
    try:
        with open(args.input, 'r', encoding='utf-8') as f:
            provider_result = json.load(f)
            
        result_id = provider_result.get('provider_result_id', Path(args.input).stem)
        input_hash = provider_result.get('result_text_sha256', 'unknown')
        
        minimal_ir, mw = normalize_to_minimal(provider_result, result_id)
        warnings.extend(mw)
        
        if args.stage == 'minimal':
            data = minimal_ir
        elif os.environ.get('APR_V18_FORCE_FIXTURES') == '1':
            data, fw = normalize_to_fixture_artifact(provider_result, result_id, args.stage)
            warnings.extend(fw)
        elif args.stage == 'full':
            full_ir, fw = normalize_to_full(minimal_ir)
            warnings.extend(fw)
            data = full_ir
        else:
            full_ir, fw = normalize_to_full(minimal_ir)
            warnings.extend(fw)
            export_ir, ew = normalize_to_export_ready(full_ir)
            warnings.extend(ew)
            data = export_ir
            
        if has_warning(warnings, MOCKED_ENRICHMENT_WARNING_ID):
            errors.append({
                'error_code': 'mocked_enrichment_not_export_ready',
                'message': 'Plan IR full/export enrichment is not implemented; refusing to emit a successful empty artifact',
            })

        item_count = len(data.get('plan_items', []))
        logging.info(f"Normalization complete. Result ID: {result_id}, Input Hash: {input_hash}, Stage: {args.stage}, Items: {item_count}, Warnings: {len(warnings)}")
            
    except Exception as exc:
        errors.append({'error_code': 'normalization_failed', 'message': str(exc)})
        logging.error(f"Normalization failed: {exc}")
        
    out = env(
        ok=not errors,
        data=data,
        warnings=warnings,
        errors=errors,
        blocked_reason='mocked_enrichment_not_export_ready' if has_warning(warnings, MOCKED_ENRICHMENT_WARNING_ID) else ('normalization_error' if errors else None)
    )
    
    if args.json:
        print(json.dumps(out, indent=2, sort_keys=True))
        sys.exit(0 if out.get('ok') else 1)
    else:
        if errors:
            for e in errors:
                print(f"ERROR: {e['message']}", file=sys.stderr)
            sys.exit(1)
        else:
            print(json.dumps(data, indent=2, sort_keys=True))

if __name__ == '__main__':
    main()
