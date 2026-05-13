#!/usr/bin/env python3
# Bundle version: v18.0.0
from __future__ import annotations

import argparse
import json
import os
import shutil
import socket
import subprocess  # nosec B404 - probes fixed local commands with shell=False.
from pathlib import Path


VERSION = 'v18.0.0'
ORACLE_FLAGS = ['--engine', '--browser-attachments', '--write-output', '--notify', '--heartbeat']
REMOTE_HOST_ENV = 'ORACLE_REMOTE_HOST'
REMOTE_TOKEN_ENV = 'ORACLE_REMOTE_' + 'TOKEN'


def env(ok=True, data=None, warnings=None, errors=None, next_command=None, fix_command=None, blocked_reason=None, retry_safe=True):
    return {
        'ok': ok,
        'schema_version': 'json_envelope.v1',
        'data': data or {},
        'meta': {'tool': 'premortem-check', 'bundle_version': VERSION},
        'warnings': warnings or [],
        'errors': errors or [],
        'commands': {'next': 'python3 scripts/premortem-check.py --json'},
        'next_command': next_command,
        'fix_command': fix_command,
        'blocked_reason': blocked_reason,
        'retry_safe': retry_safe,
    }


def load(root, rel):
    path = root / rel
    try:
        return json.JSONDecoder().decode(path.read_text(encoding='utf-8'))
    except OSError as exc:
        raise RuntimeError(f'failed to read {rel}: {exc}') from exc
    except json.JSONDecodeError as exc:
        raise RuntimeError(f'failed to parse {rel}: {exc}') from exc


def command_probe(name, required=False):
    path = shutil.which(name)
    return {
        'name': name,
        'path': path,
        'available': path is not None,
        'required': required,
    }


def run_probe(cmd, timeout=5):
    try:
        completed = subprocess.run(  # nosec B603 - no shell; callers pass fixed diagnostic commands.
            cmd,
            capture_output=True,
            text=True,
            check=False,
            timeout=timeout,
        )
    except FileNotFoundError:
        return {'available': False, 'status': 'missing', 'exit_code': 127, 'stdout': '', 'stderr': ''}
    except subprocess.TimeoutExpired:
        return {'available': True, 'status': 'timeout', 'exit_code': None, 'stdout': '', 'stderr': ''}
    return {
        'available': True,
        'status': 'ok' if completed.returncode == 0 else 'failed',
        'exit_code': completed.returncode,
        'stdout': completed.stdout.strip(),
        'stderr': completed.stderr.strip(),
    }


def parse_host_port(value):
    raw = value.strip()
    if not raw:
        return None, None, 'empty'
    if '://' in raw:
        from urllib.parse import urlparse

        parsed = urlparse(raw)
        if not parsed.hostname:
            return None, None, 'invalid'
        default_port = 443 if parsed.scheme == 'https' else 80
        return parsed.hostname, parsed.port or default_port, 'ok'
    if raw.startswith('[') and ']' in raw:
        host, _, rest = raw[1:].partition(']')
        if rest.startswith(':') and rest[1:].isdigit():
            return host, int(rest[1:]), 'ok'
        return host, 80, 'ok'
    if ':' in raw:
        host, port_text = raw.rsplit(':', 1)
        if port_text.isdigit():
            return host, int(port_text), 'ok'
    return raw, 80, 'ok'


def tcp_probe(host, port, timeout=2.0):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return {'status': 'reachable', 'host': host, 'port': port}
    except OSError as exc:
        return {'status': 'unreachable', 'host': host, 'port': port, 'error': exc.__class__.__name__}


def environment_diagnostics():
    warnings = []
    errors = []
    commands = [
        command_probe('bash', required=True),
        command_probe('node', required=True),
        command_probe('jq', required=True),
        command_probe('curl', required=False),
        command_probe('wget', required=False),
        command_probe('shellcheck', required=False),
        command_probe('bats', required=False),
        command_probe('gum', required=False),
        command_probe('oracle', required=False),
        command_probe('npx', required=False),
    ]
    by_name = {entry['name']: entry for entry in commands}
    for entry in commands:
        if entry['required'] and not entry['available']:
            errors.append({
                'error_code': 'doctor_missing_required_tool',
                'message': f"{entry['name']} is not available in PATH",
            })

    oracle_available = by_name['oracle']['available']
    npx_available = by_name['npx']['available']
    if not oracle_available and not npx_available:
        warnings.append('oracle_missing: neither oracle nor npx fallback is available in PATH')
    elif not oracle_available:
        warnings.append('oracle_missing_using_npx_fallback: oracle is not installed globally; APR will rely on npx fallback')

    oracle = {
        'available': oracle_available,
        'npx_fallback_available': npx_available,
        'version': None,
        'status': None,
        'required_flags': {flag: None for flag in ORACLE_FLAGS},
    }
    if oracle_available:
        version = run_probe(['oracle', '--version'], timeout=5)
        oracle['version'] = {
            'status': version['status'],
            'exit_code': version['exit_code'],
            'text': (version['stdout'] or version['stderr']).splitlines()[:1],
        }
        help_probe = run_probe(['oracle', '--help'], timeout=5)
        help_text = f"{help_probe['stdout']}\n{help_probe['stderr']}"
        oracle['required_flags'] = {
            flag: (flag in help_text if help_probe['status'] != 'timeout' else None)
            for flag in ORACLE_FLAGS
        }
        status = run_probe(['oracle', 'status'], timeout=8)
        status_text = f"{status['stdout']}\n{status['stderr']}".lower()
        state = 'busy' if 'busy' in status_text else status['status']
        oracle['status'] = {'state': state, 'exit_code': status['exit_code']}

    remote_host = os.environ.get(REMOTE_HOST_ENV, '')
    remote_token_present = bool(os.environ.get(REMOTE_TOKEN_ENV))
    remote = {
        'configured': bool(remote_host),
        'host_env': REMOTE_HOST_ENV,
        'token_env': REMOTE_TOKEN_ENV,
        'token_present': remote_token_present,
        'connectivity': {'status': 'not_configured'},
        'identity': {'status': 'not_checked'},
    }
    if remote_host:
        host, port, parse_status = parse_host_port(remote_host)
        if parse_status != 'ok' or not host or not port:
            remote['connectivity'] = {'status': 'invalid_host'}
            errors.append({
                'error_code': 'remote_browser_host_invalid',
                'message': f'{REMOTE_HOST_ENV} is not a valid host[:port] or URL',
            })
        else:
            remote['connectivity'] = tcp_probe(host, port)
            remote['identity'] = {
                'status': 'best_effort_tcp_only',
                'message': 'oracle serve identity endpoint is not standardized; TCP reachability was checked',
            }
            if remote['connectivity']['status'] != 'reachable':
                errors.append({
                    'error_code': 'remote_browser_unreachable',
                    'message': f'{REMOTE_HOST_ENV} is unreachable at {host}:{port}',
                })
        if not remote_token_present:
            errors.append({
                'error_code': 'remote_browser_token_missing',
                'message': f'{REMOTE_TOKEN_ENV} must be set when {REMOTE_HOST_ENV} is configured',
            })

    return {
        'bash_version': os.environ.get('BASH_VERSION') or 'unknown',
        'commands': commands,
        'oracle': oracle,
        'remote': remote,
    }, warnings, errors

def main():
    ap=argparse.ArgumentParser(description='Validate v18 premortem hardening artifacts.')
    ap.add_argument('--json', action='store_true')
    ap.parse_args()
    root=Path(__file__).resolve().parents[1]
    errors=[]
    warnings=[]
    for rel in ['fixtures/failure-mode-ledger.json','fixtures/live-cutover-checklist.json','fixtures/fallback-waiver.json','fixtures/run-progress.json']:
        if not (root/rel).exists():
            errors.append(f'missing {rel}')
    if not errors:
        try:
            ledger=load(root,'fixtures/failure-mode-ledger.json')
            modes=ledger.get('failure_modes',[])
            if len(modes) < 10:
                errors.append('failure-mode ledger must include at least 10 concrete failure modes')
            owners={m.get('owner') for m in modes}
            for required in ['oracle','apr','vibe-planning','integration','all']:
                if required not in owners:
                    errors.append(f'failure-mode ledger missing owner {required}')
            checklist=load(root,'fixtures/live-cutover-checklist.json')
            if len(checklist.get('phases',[])) < 5:
                errors.append('live cutover checklist must include at least five phases')
            if checklist.get('minimum_release_gate') != 'phase_5_balanced_live_dress_rehearsal':
                errors.append('minimum release gate must be balanced live dress rehearsal')
            waiver=load(root,'fixtures/fallback-waiver.json')
            for slot in ['chatgpt_pro_first_plan','chatgpt_pro_synthesis','gemini_deep_think']:
                if slot not in waiver.get('non_waivable_slots',[]):
                    errors.append(f'waiver fixture must mark {slot} non-waivable')
            progress=load(root,'fixtures/run-progress.json')
            if not (0 <= progress.get('progress_percent',-1) <= 100):
                errors.append('progress_percent out of range')
            if not progress.get('user_visible_message'):
                errors.append('run progress must include user_visible_message')
        except RuntimeError as exc:
            errors.append(str(exc))
    diagnostics, env_warnings, env_errors = environment_diagnostics()
    warnings.extend(env_warnings)
    error_entries=[{'error_code':'premortem_validation_failed','message':e} for e in errors] + env_errors
    ok=not error_entries
    data={
        'bundle_version':VERSION,
        'error_count':len(error_entries),
        'checked':['failure-mode-ledger','live-cutover-checklist','fallback-waiver','run-progress','environment','oracle','remote-browser'],
        'environment': diagnostics,
    }
    out=env(
        ok=ok,
        data=data,
        warnings=warnings,
        errors=error_entries,
        blocked_reason=None if ok else (error_entries[0]['error_code'] if error_entries else 'premortem_artifact_validation_failed'),
        next_command=None if ok else 'apr doctor --json',
        fix_command=None if ok else 'fix reported environment or v18 premortem artifact issues',
        retry_safe=True,
    )
    print(json.dumps(out, indent=2, sort_keys=True))
    return 0 if ok else 1
if __name__ == '__main__':
    raise SystemExit(main())
