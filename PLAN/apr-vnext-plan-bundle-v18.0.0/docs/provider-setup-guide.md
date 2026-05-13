# Provider Setup Guide

> Bundle version: v18.0.0

This guide lists the setup checks an operator should complete before attempting a v18 balanced or audit run. It separates mock readiness from live-provider eligibility.

## Oracle browser routes

ChatGPT Pro and Gemini Deep Think are browser routes. Configure Oracle browser automation before balanced or audit runs:

- Start or select the remote browser endpoint described by `fixtures/remote-browser-endpoint.json`.
- Provide `ORACLE_REMOTE_HOST` or `ORACLE_REMOTE_POOL` for remote browser execution.
- Provide `ORACLE_REMOTE_TOKEN` or `ORACLE_REMOTE_TOKENS` when the endpoint requires authentication.
- Verify browser lease and redacted evidence artifacts against `contracts/browser-lease.schema.json` and `contracts/browser-evidence.schema.json`.

Balanced and audit require these browser slots:

- `chatgpt_pro_first_plan`
- `gemini_deep_think`
- `chatgpt_pro_synthesis`

Do not substitute direct APIs for those slots.

## Claude Code Opus

Claude Code is a subscription CLI reviewer, not a browser route in this bundle. Use the highest available effort:

```bash
python3 scripts/apr-mock.py claude-code doctor --json
```

The real implementation should verify `claude --model claude-opus-4-7 --effort max` or `CLAUDE_CODE_EFFORT_LEVEL=max`, and include the documented ultrathink prompt cue.

## Codex intake

Codex CLI subscription intake supplies source context and fast drafts only:

- `codex_intake`
- `codex_thinking_fast_draft`

It must use `xhigh` effort, but it is not a formal first plan and is not synthesis-eligible for balanced or audit.

## xAI Grok

xAI is an API-allowed independent reviewer when `XAI_API_KEY` is present and the model/reasoning policy matches the fixture:

```bash
python3 scripts/apr-mock.py xai doctor --json
```

Expected route: `xai_grok_reasoning` with `grok-4.3` and `reasoning_effort=high`.

## DeepSeek V4 Pro reasoning search

DeepSeek is an API-allowed independent reviewer when `DEEPSEEK_API_KEY` is present, thinking is enabled, and APR-provided web-search tool calls are available:

```bash
python3 scripts/apr-mock.py deepseek doctor --json
```

Expected route: `deepseek_v4_pro_reasoning_search` with `deepseek-v4-pro`, `reasoning_effort=max`, and `search_enabled=true`. Raw `reasoning_content` is transient for tool-call replay and may be persisted only as hashes.

## Provider docs freshness

Before live provider calls, refresh or verify `fixtures/provider-docs-snapshot.json`. The snapshot must include `checked_at`, `expires_at`, `max_age_days`, and `refresh_required_before_live_provider_calls=true`.

If the snapshot is stale, block live cutover and rerun the provider docs capture step before spending browser/API capacity.

## TOON/tru optional setup

TOON/tru is optional prompt-context compression only. Canonical artifacts remain JSON and Markdown.

```bash
python3 scripts/apr-mock.py serialization doctor --format toon --json
```

If unavailable or unapproved, continue with JSON and surface `toon_unavailable_json_fallback`.
