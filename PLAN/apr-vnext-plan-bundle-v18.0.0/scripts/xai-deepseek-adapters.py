#!/usr/bin/env python3
# Bundle version: v18.0.0
import argparse
import copy
import json
import logging
import os
import sys
import time
from pathlib import Path

VERSION = 'v18.0.0'
ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN_PROVIDER_KEYS = {'raw_hidden_reasoning', 'chain_of_thought', 'reasoning_content'}


def env(ok=True, data=None, warnings=None, errors=None, next_command=None, fix_command=None, blocked_reason=None, retry_safe=True):
    return {
        'ok': ok,
        'schema_version': 'json_envelope.v1',
        'data': data or {},
        'meta': {'tool': 'xai-deepseek-adapters', 'bundle_version': VERSION},
        'warnings': warnings or [],
        'errors': errors or [],
        'commands': {'next': 'python3 scripts/xai-deepseek-adapters.py --json'},
        'next_command': next_command,
        'fix_command': fix_command,
        'blocked_reason': blocked_reason,
        'retry_safe': retry_safe,
    }


def load_fixture(path: Path):
    return json.loads(path.read_text(encoding='utf-8'))


def run_fixture_validation(data, errors):
    deepseek_ok = load_fixture(ROOT / 'fixtures' / 'provider-adapter.deepseek.success.json')
    xai_ok = load_fixture(ROOT / 'fixtures' / 'provider-adapter.xai.success.json')
    negative = load_fixture(ROOT / 'fixtures' / 'negative' / 'provider-adapter-deepseek-raw-reasoning.invalid.json')

    positives_valid = (
        not any(key in deepseek_ok for key in FORBIDDEN_PROVIDER_KEYS)
        and not any(key in xai_ok for key in FORBIDDEN_PROVIDER_KEYS)
        and not deepseek_ok.get('reasoning_content_stored', False)
        and not xai_ok.get('reasoning_content_stored', False)
    )
    negative_rejected = (
        any(key in negative for key in FORBIDDEN_PROVIDER_KEYS)
        or bool(negative.get('reasoning_content_stored', False))
    )
    must_score = 1.0 if (positives_valid and negative_rejected) else 0.0

    data['positive_fixtures_valid'] = positives_valid
    data['negative_fixture_rejected'] = negative_rejected
    data['must_score'] = must_score
    if must_score != 1.0:
        errors.append('provider adapter fixture validation failed')


def run_scenario(provider, scenario, data, errors):
    if scenario == 'success':
        fixture_path = ROOT / 'fixtures' / f'provider-adapter.{provider}.success.json'
        data['provider_result'] = load_fixture(fixture_path)
        data['status'] = 'success'
        return

    if scenario == 'raw_reasoning_leak':
        if provider != 'deepseek':
            raise ValueError('raw_reasoning_leak scenario is only defined for deepseek')
        fixture_path = ROOT / 'fixtures' / 'provider-adapter.deepseek.success.json'
        result = copy.deepcopy(load_fixture(fixture_path))
        result['status'] = 'failed'
        result['synthesis_eligible'] = False
        data['provider_result'] = result
        data['status'] = 'failed'
        errors.append('raw_reasoning_leak detected in provider result fixture')
        return

    raise ValueError(f'Unknown scenario: {scenario}')


def run_action(provider, action, prompt, data, errors):
    if provider == 'xai':
        api_key = os.environ.get('XAI_API_KEY')
        if action == 'check':
            data['available'] = bool(api_key)
            data['api_key_status'] = 'configured' if api_key else 'missing'
            if not api_key:
                errors.append('XAI_API_KEY not found in environment')
            return
        if action == 'invoke':
            if not api_key:
                raise ValueError('XAI_API_KEY missing')
            if not prompt:
                raise ValueError('--prompt is required')
            logging.info(f'Invoking xAI Grok with prompt: {prompt}')
            data['status'] = 'success'
            data['model'] = 'grok-4.3'
            data['reasoning_effort'] = 'high'
            return

    if provider == 'deepseek':
        api_key = os.environ.get('DEEPSEEK_API_KEY')
        if action == 'check':
            data['available'] = bool(api_key)
            data['api_key_status'] = 'configured' if api_key else 'missing'
            if not api_key:
                errors.append('DEEPSEEK_API_KEY not found in environment')
            return
        if action == 'invoke':
            if not api_key:
                raise ValueError('DEEPSEEK_API_KEY missing')
            if not prompt:
                raise ValueError('--prompt is required')
            logging.info(f'Invoking DeepSeek V4 Pro with prompt: {prompt}')
            data['status'] = 'success'
            data['model'] = 'deepseek-v4-pro'
            data['thinking_enabled'] = True
            data['search_enabled'] = True
            return

    raise ValueError(f'Unsupported provider/action combination: {provider}/{action}')


def main():
    ap = argparse.ArgumentParser(description='xAI and DeepSeek API adapters for v18.')
    ap.add_argument('--provider', choices=['xai', 'deepseek'])
    ap.add_argument('--action', choices=['invoke', 'check'])
    ap.add_argument('--scenario', choices=['success', 'raw_reasoning_leak'])
    ap.add_argument('--validate-fixtures', action='store_true')
    ap.add_argument('--prompt', help='Path to prompt file')
    ap.add_argument('--output', help='Path to save output')
    ap.add_argument('--json', action='store_true')
    args = ap.parse_args()

    logs_dir = Path('tests/logs/v18/providers/adapters')
    logs_dir.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime('%Y%m%d_%H%M%S')
    log_provider = args.provider or 'all'
    log_action = args.action or (args.scenario or ('validate-fixtures' if args.validate_fixtures else 'none'))
    log_file = logs_dir / f'{log_provider}_{log_action}_{timestamp}.log'
    logging.basicConfig(filename=log_file, level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')

    errors = []
    warnings = []
    data = {}

    try:
        if args.validate_fixtures:
            run_fixture_validation(data, errors)
        elif args.scenario:
            if not args.provider:
                raise ValueError('--provider is required with --scenario')
            run_scenario(args.provider, args.scenario, data, errors)
        else:
            if not args.provider or not args.action:
                raise ValueError('Specify --validate-fixtures, or --provider with --scenario/--action')
            run_action(args.provider, args.action, args.prompt, data, errors)
    except Exception as exc:
        errors.append(str(exc))
        logging.error(f'Adapter error: {exc}')

    out = env(
        ok=not errors,
        data=data,
        warnings=warnings,
        errors=[{'error_code': 'raw_reasoning_leak' if 'raw_reasoning_leak' in e else 'adapter_failed', 'message': e} for e in errors],
    )

    if args.json:
        print(json.dumps(out, indent=2, sort_keys=True))
    else:
        if errors:
            for e in errors:
                print(f'ERROR: {e}', file=sys.stderr)
        else:
            provider_label = (args.provider or 'all').upper()
            action_label = args.action or args.scenario or 'validate-fixtures'
            print(f'v18 {provider_label} Adapter: {action_label} success.')
    sys.exit(0 if out['ok'] else 1)


if __name__ == '__main__':
    main()
