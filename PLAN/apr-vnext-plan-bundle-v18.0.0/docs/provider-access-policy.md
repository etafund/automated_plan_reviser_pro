# Provider Access Policy and Runtime Invariants

> Bundle version: v18.0.0

This bundle includes `contracts/provider-access-policy.schema.json` and `fixtures/provider-access-policy.json`. Treat them as implementation contracts, not merely documentation.

## Live route policy

| Provider slot | Required access path | API allowed? | Notes |
|---|---|---:|---|
| `codex_intake` | Codex CLI subscription | No | User talks at GPT-5.5 Thinking xHigh or closest verified Codex CLI config. Context only. |
| `codex_thinking_fast_draft` | Codex CLI subscription | No | Fast exploratory draft only; never a formal first plan. |
| `chatgpt_pro_first_plan` | Oracle browser, preferably remote | No | Required for `balanced` and `audit`. Requires redacted same-session evidence. |
| `chatgpt_pro_synthesis` | Oracle browser, preferably remote | No | Required for `balanced` and `audit`. Requires redacted same-session evidence. |
| `gemini_deep_think` | Oracle browser, preferably remote | No | Requires Deep Think same-session evidence. |
| `claude_code_opus` | Claude Code CLI/subscription | No Anthropic API | Optional reviewer unless profile says otherwise. |
| `xai_grok_reasoning` | xAI API | Yes | Resolve current reasoning model at runtime. |

## Why this policy exists

The workflow is intentionally subscription/browser/CLI based for ChatGPT, Gemini, and Claude because the user's desired capabilities are tied to those product routes. Direct APIs may expose different model families, missing UI modes, different entitlements, or different behavior. Grok is the allowed API exception because the desired route is API-based.

## Implementation rule

Do not silently substitute one access path for another. If a route is unavailable, return a blocked or degraded JSON envelope with `blocked_reason`, `next_command`, `fix_command`, and `retry_safe`.


## v18 DeepSeek provider addition

Bundle version: v18.0.0

Adds `deepseek_v4_pro_reasoning_search` as a default optional independent comparison-review provider. This route uses the official DeepSeek API with `deepseek-v4-pro`, thinking enabled, `reasoning_effort=max`, and APR-provided web-search tool calls. It is an API-allowed exception like xAI/Grok; it does not weaken the ban on direct API substitution for ChatGPT, Gemini, or Claude.

## v18 API exceptions

The only live planning routes allowed to use direct APIs are:

- `xai_grok_reasoning` through xAI API.
- `deepseek_v4_pro_reasoning_search` through the official DeepSeek API.

This does not permit ChatGPT/OpenAI API, Gemini API, or Anthropic API substitution for their protected routes. DeepSeek must use `deepseek-v4-pro`, thinking enabled, `reasoning_effort=max`, and APR's search tool-call contract.

## Contract fields implementers must enforce

Provider policy enforcement is not a string match against provider names. Runtime code must evaluate the policy as a tuple:

| Field | Meaning |
|---|---|
| `provider_slot` | Stable route identity used by execution profiles and readiness gates. |
| `provider_family` | Provider family for prompt policy and result normalization. |
| `access_path` | Required transport: browser, subscription CLI, or official API. |
| `api_allowed` | Whether a direct API call can satisfy the slot. |
| `eligible_for_synthesis` | Whether a successful result may enter quorum or synthesis. |
| `evidence_required` | Whether same-session browser evidence is mandatory. |
| `reasoning_effort` / `requested_reasoning_effort` | Provider-specific highest-effort request. |

If a result contradicts any protected route field, the result must be blocked or synthesis-ineligible. The failure surface should include the provider slot, observed access path, required access path, prohibited substitution reason, and the remediation command.

## Negative fixture intent

`fixtures/negative/api-substitution-provider-result.invalid.json` represents the exact unsafe shortcut the contract prevents: using an OpenAI API-shaped result for `chatgpt_pro_first_plan`. That fixture is invalid because `chatgpt_pro_first_plan` requires Oracle browser access, same-session evidence, verified highest visible browser effort, and no direct API substitution.
