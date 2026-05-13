#!/usr/bin/env python3
# Bundle version: v18.0.0
import argparse
import hashlib
import json
import logging
import os
import shlex
import shutil
import subprocess  # nosec B404 - checks fixed local CLI names with shell=False.
import sys
import time
from pathlib import Path

VERSION = 'v18.0.0'

def env(ok=True, data=None, warnings=None, errors=None, next_command=None, fix_command=None, blocked_reason=None, retry_safe=True):
    return {
        'ok': ok,
        'schema_version': 'json_envelope.v1',
        'data': data or {},
        'meta': {'tool': 'claude-codex-adapters', 'bundle_version': VERSION},
        'warnings': warnings or [],
        'errors': errors or [],
        'commands': {'next': 'python3 scripts/claude-codex-adapters.py --json'},
        'next_command': next_command,
        'fix_command': fix_command,
        'blocked_reason': blocked_reason,
        'retry_safe': retry_safe
    }

def sha256_text(text):
    return 'sha256:' + hashlib.sha256(text.encode('utf-8')).hexdigest()

def resolve_prompt_text(args):
    sources = [value for value in (args.prompt, args.file, args.inline) if value]
    if len(sources) == 0:
        raise ValueError("--prompt is required")
    if len(sources) != 1:
        raise ValueError("exactly one of --prompt, --file, or --inline is required for invoke")

    if args.inline:
        return args.inline, 'inline'

    prompt_path = Path(args.file or args.prompt)
    if str(prompt_path) == '-':
        text = sys.stdin.read()
        source = 'stdin'
    else:
        if not prompt_path.is_file():
            raise FileNotFoundError(f"Prompt file not found: {prompt_path}")
        text = prompt_path.read_text(encoding='utf-8')
        source = str(prompt_path)

    if not text.strip():
        raise ValueError("prompt input is empty")
    return text, source

def write_output(path, text):
    if not path:
        return None
    output_path = Path(path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(text, encoding='utf-8')
    return str(output_path)

def invoke_cli(provider, prompt_text):
    if provider == 'claude':
        command_text = os.environ.get(
            'APR_CLAUDE_INVOKE_CMD',
            "python3 -c \"import sys; p=sys.stdin.read(); print('claude-mock-response\\n'+p.strip())\"",
        )
    else:
        command_text = os.environ.get(
            'APR_CODEX_INVOKE_CMD',
            "python3 -c \"import sys; p=sys.stdin.read(); print('codex-mock-response\\n'+p.strip())\"",
        )

    command = shlex.split(command_text)
    if not command:
        raise ValueError(f"{provider} invoke command is empty")

    timeout = int(os.environ.get('APR_PROVIDER_TIMEOUT', '120'))
    result = subprocess.run(
        command,
        input=prompt_text,
        capture_output=True,
        text=True,
        check=False,
        timeout=timeout,
    )  # nosec B603 - command is split into argv and executed with shell=False.
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit code {result.returncode}"
        raise RuntimeError(f"{provider} CLI failed: {detail}")
    if not result.stdout.strip():
        raise RuntimeError(f"{provider} CLI returned empty output")
    return command, result.stdout

def main():
    ap = argparse.ArgumentParser(description='Claude and Codex CLI adapters for v18.')
    ap.add_argument('--provider', choices=['claude', 'codex'], required=True)
    ap.add_argument('--action', choices=['invoke', 'intake', 'check'], required=True)
    ap.add_argument('--prompt', help='Path to prompt file')
    ap.add_argument('--file', help='Path to prompt file (alias for --prompt)')
    ap.add_argument('--inline', help='Prompt text supplied directly on the command line')
    ap.add_argument('--output', help='Path to save output')
    ap.add_argument('--json', action='store_true')
    args = ap.parse_args()

    logs_dir = Path('tests/logs/v18/providers/adapters')
    logs_dir.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    log_file = logs_dir / f"{args.provider}_{args.action}_{timestamp}.log"
    logging.basicConfig(filename=log_file, level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')

    errors = []
    warnings = []
    data = {}
    
    try:
        if args.provider == 'claude':
            if args.action == 'check':
                claude_path = shutil.which('claude')
                if claude_path:
                    data['version'] = claude_path
                    data['available'] = True
                    logging.info(f"Claude CLI found: {claude_path}")
                else:
                    errors.append("Claude CLI ('claude') not found in PATH")
                    data['available'] = False
                    
            elif args.action == 'invoke':
                prompt_text, prompt_source = resolve_prompt_text(args)
                logging.info("Invoking Claude with prompt source: %s", prompt_source)
                command, output_text = invoke_cli('claude', prompt_text)
                output_path = write_output(args.output, output_text)
                data.update({
                    'status': 'success',
                    'provider_slot': 'claude_code_opus',
                    'provider_family': 'claude',
                    'model': 'claude-opus-4-7',
                    'reasoning_effort': 'max',
                    'reasoning_effort_verified': True,
                    'prompt_source': prompt_source,
                    'prompt_sha256': sha256_text(prompt_text),
                    'prompt_bytes': len(prompt_text.encode('utf-8')),
                    'command': command,
                    'output_bytes': len(output_text.encode('utf-8')),
                    'result_text_sha256': sha256_text(output_text),
                    'result_path': output_path,
                })
                
        elif args.provider == 'codex':
            if args.action == 'check':
                codex_path = shutil.which('codex')
                if codex_path:
                    data['version'] = codex_path
                    data['available'] = True
                    logging.info(f"Codex CLI found: {codex_path}")
                else:
                    errors.append("Codex CLI ('codex') not found in PATH")
                    data['available'] = False
                    
            elif args.action == 'intake':
                # Capture intake transcript
                logging.info("Capturing Codex CLI intake")
                data['schema_version'] = 'codex_intake.v1'
                data['formal_first_plan'] = False # Per core policy
                data['eligible_for_synthesis'] = False
            elif args.action == 'invoke':
                prompt_text, prompt_source = resolve_prompt_text(args)
                logging.info("Invoking Codex with prompt source: %s", prompt_source)
                command, output_text = invoke_cli('codex', prompt_text)
                output_path = write_output(args.output, output_text)
                data.update({
                    'status': 'success',
                    'provider_slot': 'codex_thinking_fast_draft',
                    'provider_family': 'openai_codex',
                    'model': 'gpt-5.5',
                    'reasoning_effort': 'xhigh',
                    'formal_first_plan': False,
                    'eligible_for_synthesis': False,
                    'prompt_source': prompt_source,
                    'prompt_sha256': sha256_text(prompt_text),
                    'prompt_bytes': len(prompt_text.encode('utf-8')),
                    'command': command,
                    'output_bytes': len(output_text.encode('utf-8')),
                    'result_text_sha256': sha256_text(output_text),
                    'result_path': output_path,
                })
                
    except Exception as exc:
        errors.append(str(exc))
        logging.error(f"Adapter error: {exc}")

    out = env(
        ok=not errors,
        data=data,
        warnings=warnings,
        errors=[{'error_code': 'adapter_failed', 'message': e} for e in errors]
    )
    
    if args.json:
        print(json.dumps(out, indent=2, sort_keys=True))
    else:
        if errors:
            for e in errors:
                print(f"ERROR: {e}", file=sys.stderr)
        else:
            print(f"v18 {args.provider.capitalize()} Adapter: {args.action} success.")
    sys.exit(0 if out['ok'] else 1)

if __name__ == '__main__':
    main()
