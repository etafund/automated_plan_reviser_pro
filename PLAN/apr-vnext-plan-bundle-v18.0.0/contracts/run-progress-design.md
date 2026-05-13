# v18 Contracts: Run Progress and Cutover Design

## Objective
Provide durable, auditable state representation for multi-provider planning runs. Since v18 runs are expensive, long-running, and can be interrupted, these contracts guarantee we can safely resume, retry, or manually intervene without losing progress or corrupting state.

## Core Concepts

### Run Progress
The `run-progress.schema.json` defines the core state machine of an execution. It records:
- `current_stage`, `completed_stages`, and `pending_stages`
- Overall `progress_percent`
- Safe resume capability via `retry_safe` (boolean)
- `user_visible_message` for terminal/TUI reporting.

### Failure Mode Ledger
The `failure-mode-ledger.schema.json` acts as an active repository of known failure modes during cutover or planning. Each entry includes:
- `likelihood` and `impact`
- Early warning signals to detect the failure before it cascades
- `mitigations` and `acceptance_checks` to ensure the failure mode is addressed or resolved.

### Live Cutover Checklist
The `live-cutover-checklist.schema.json` ensures that all release gates are passed before pushing the finalized plan or changes to production/live routes. It tracks sequential `phases`, assigning owners and asserting `pass_criteria` and `failure_modes_addressed`.

### DeepSeek Search Tool
The `deepseek-search-tool.schema.json` governs the integration of `deepseek-v4-pro` reasoning with APR-owned web search. It strictly dictates that:
- `search_enabled` must be true.
- `reasoning_effort` must be `max`.
- Transient raw reasoning replay is allowed (`reasoning_content_transient_replay_allowed`), but persisted content is restricted to hashes (`reasoning_content_policy` = `transient_tool_replay_hash_only_persisted`).

## Usage
These schemas form the backbone of APR's state management and operational resilience. When runs fail, the run progress and failure ledger provide exact context on where the breakdown occurred and if it is safe to resume.
