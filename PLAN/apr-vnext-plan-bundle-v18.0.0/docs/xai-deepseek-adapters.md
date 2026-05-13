# xAI and DeepSeek Adapter Contract

`scripts/xai-deepseek-adapters.py` is the deterministic v18 adapter harness for the official API routes:

- `xai_grok_reasoning`
- `deepseek_v4_pro_reasoning_search`

The harness does not make live network calls. It models the request/result contract APR must satisfy before live adapter code invokes either API.

## Contract Invariants

| Requirement | Level | Coverage |
| --- | --- | --- |
| xAI uses the official API route, `xai_api`, and never a browser/API substitute for another provider. | MUST | `fixtures/provider-adapter.xai.success.json` |
| xAI requests `reasoning_effort=high` and records the provider-specific reasoning configuration. | MUST | `fixtures/provider-adapter.xai.success.json` |
| DeepSeek uses `deepseek-v4-pro`, thinking enabled, and `reasoning_effort=max`. | MUST | `fixtures/provider-adapter.deepseek.success.json` |
| DeepSeek search is APR-owned through `apr_web_search`, with search trace hash and citations. | MUST | `fixtures/provider-adapter.deepseek.success.json` |
| Raw reasoning fields such as `raw_hidden_reasoning`, `chain_of_thought`, and `reasoning_content` are never persisted. | MUST | `fixtures/negative/provider-adapter-deepseek-raw-reasoning.invalid.json` |
| DeepSeek may replay raw reasoning transiently only for tool-call continuity and persists at most a hash. | MUST | `scripts/xai-deepseek-adapters.py --validate-fixtures --json` |
| Auth, rate limit, model unavailable, disabled search, missing citations, and raw reasoning leakage are typed adapter failures. | MUST | `--scenario` matrix in the harness |
| Successful provider results validate against `contracts/provider-result.schema.json`. | MUST | `--validate-fixtures --json` |
| Request and response hashes are recorded in adapter logs. | SHOULD | success fixtures |
| Error responses are retry-classified where applicable. | SHOULD | `rate_limit` and `model_unavailable` scenarios |

Coverage score: 8/8 MUST, 2/2 SHOULD for the deterministic contract harness.

## Commands

```bash
python3 scripts/xai-deepseek-adapters.py --provider deepseek --scenario success --json
python3 scripts/xai-deepseek-adapters.py --provider xai --scenario success --json
python3 scripts/xai-deepseek-adapters.py --provider deepseek --scenario missing_citations --json
python3 scripts/xai-deepseek-adapters.py --validate-fixtures --json
```

Use `--check-env` to convert a missing `DEEPSEEK_API_KEY` or `XAI_API_KEY` into a typed `auth_missing` provider result without exposing the key value.
