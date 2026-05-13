# Execution Profile Route Compiler

> Bundle version: v18.0.0

The route compiler turns a profile, provider access policy, capability set, source baseline, and runtime budget into one deterministic `provider_route.v1` plan. The compiler is intentionally policy-only in this bundle: it does not call providers and it does not edit APR runtime state.

## Inputs

- `fixtures/execution-profile.fast.json`, `fixtures/execution-profile.balanced.json`, or `fixtures/execution-profile.audit.json`
- `fixtures/provider-access-policy.json`
- `fixtures/route-compiler.capabilities.json`
- `fixtures/source-baseline.json`
- `fixtures/runtime-budget.json`

Every compiled route records hashes for these inputs. Route ids, stage ids, and cache keys are derived from the selected profile and input hashes so identical inputs produce byte-stable output.

## Profile semantics

`fast` compiles a Codex CLI exploratory draft plus an optional ChatGPT Pro upgrade route. Codex output remains source context only and cannot satisfy formal first-plan or synthesis gates without explicit promotion or waiver.

`balanced` requires ChatGPT Pro first plan, Gemini Deep Think review, and ChatGPT Pro synthesis. Claude Code, xAI, and DeepSeek are quorum candidates; at least one optional reviewer must succeed or be waived before synthesis.

`audit` keeps the same required browser slots and requires every independent reviewer route: Gemini Deep Think, Claude Code Opus, xAI Grok reasoning, and DeepSeek reasoning with search. It also requires provider-doc freshness and human waiver review before live fanout.

## Local check

Run the compiler and golden fixture check from the bundle root:

```bash
bash scripts/route-compiler-check.sh --check-fixtures --json
```

To inspect one compiled plan:

```bash
bash scripts/route-compiler-check.sh --profile balanced --json
```

Golden compiler fixtures live at `fixtures/provider-route.fast.json`, `fixtures/provider-route.balanced.compiler.json`, and `fixtures/provider-route.audit.json`. The existing `fixtures/provider-route.balanced.json` remains the broad route contract fixture used by the contract smoke suite.
