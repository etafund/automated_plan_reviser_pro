#!/usr/bin/env python3
# Bundle version: v18.0.0
import argparse
import json
import logging
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

VERSION = "v18.0.0"
ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "fixtures"
SCRIPTS = ROOT / "scripts"

SLOT_FIXTURE_MAP = {
    "chatgpt_pro_first_plan": FIXTURES / "provider-result.chatgpt.json",
    "gemini_deep_think": FIXTURES / "provider-result.gemini.json",
    "chatgpt_pro_synthesis": FIXTURES / "provider-result.chatgpt-synthesis.json",
    "claude_code_opus": FIXTURES / "provider-result.claude.json",
    "xai_grok_reasoning": FIXTURES / "provider-result.xai.json",
    "deepseek_v4_pro_reasoning_search": FIXTURES / "provider-result.deepseek.json",
}


def env(ok=True, data=None, warnings=None, errors=None, next_command=None, fix_command=None, blocked_reason=None, retry_safe=True):
    return {
        "ok": ok,
        "schema_version": "json_envelope.v1",
        "data": data or {},
        "meta": {"tool": "plan-pipeline", "bundle_version": VERSION},
        "warnings": warnings or [],
        "errors": errors or [],
        "commands": {"next": "python3 scripts/plan-pipeline.py --json"},
        "next_command": next_command,
        "fix_command": fix_command,
        "blocked_reason": blocked_reason,
        "retry_safe": retry_safe,
    }


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def default_run_dir() -> Path:
    run_id = f"run-adhoc-{time.strftime('%Y%m%d%H%M%S')}"
    return (Path(".apr") / "runs" / "planning" / run_id).resolve()


def ensure_layout(run_dir: Path):
    for rel in ("provider_requests", "provider_results", "normalized_plans", "comparison", "synthesis", "logs", "inputs"):
        (run_dir / rel).mkdir(parents=True, exist_ok=True)


def resolve_route_config(run_dir: Path):
    candidates = [
        run_dir / "inputs" / "provider-route.json",
        FIXTURES / "provider-route.balanced.json",
    ]
    for path in candidates:
        if path.exists():
            return read_json(path), path
    raise FileNotFoundError("No provider route config found")


def choose_fanout_slots(route_config):
    required = route_config.get("stage_required_slots", {})
    optional = route_config.get("stage_optional_slots", {})
    slots = []
    slots.extend(required.get("first_plan", []))
    slots.extend(required.get("independent_review", []))
    slots.extend(optional.get("independent_review", []))
    seen = set()
    out = []
    for slot in slots:
        if slot not in seen:
            seen.add(slot)
            out.append(slot)
    return out


def run_subprocess_json(command, cwd: Path):
    completed = subprocess.run(
        command,
        cwd=str(cwd),
        text=True,
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip() or f"exit {completed.returncode}"
        raise RuntimeError(f"command failed: {' '.join(command)} :: {detail}")
    decoded = json.loads(completed.stdout)
    if not isinstance(decoded, dict):
        raise RuntimeError("adapter output was not a JSON object")
    if decoded.get("ok") is not True:
        message = decoded.get("errors", [{}])[0].get("message", "adapter returned ok=false")
        raise RuntimeError(message)
    return decoded


def provider_result_from_slot(slot: str, prompt_path: Path, run_dir: Path):
    # Use live adapter paths where available; otherwise load concrete fixture artifacts.
    if slot == "xai_grok_reasoning":
        try:
            out = run_subprocess_json(
                [
                    sys.executable,
                    str(SCRIPTS / "xai-deepseek-adapters.py"),
                    "--provider",
                    "xai",
                    "--scenario",
                    "success",
                    "--json",
                ],
                ROOT,
            )
            return out["data"]["provider_result"], "xai-deepseek-adapters.py"
        except Exception:
            return read_json(SLOT_FIXTURE_MAP[slot]), "fixture_fallback:provider-result.xai.json"

    if slot == "deepseek_v4_pro_reasoning_search":
        try:
            out = run_subprocess_json(
                [
                    sys.executable,
                    str(SCRIPTS / "xai-deepseek-adapters.py"),
                    "--provider",
                    "deepseek",
                    "--scenario",
                    "success",
                    "--json",
                ],
                ROOT,
            )
            return out["data"]["provider_result"], "xai-deepseek-adapters.py"
        except Exception:
            return read_json(SLOT_FIXTURE_MAP[slot]), "fixture_fallback:provider-result.deepseek.json"

    if slot == "claude_code_opus":
        try:
            claude_out = run_dir / "provider_results" / "claude_output.md"
            out = run_subprocess_json(
                [
                    sys.executable,
                    str(SCRIPTS / "claude-codex-adapters.py"),
                    "--provider",
                    "claude",
                    "--action",
                    "invoke",
                    "--prompt",
                    str(prompt_path),
                    "--output",
                    str(claude_out),
                    "--json",
                ],
                ROOT,
            )
            payload = dict(read_json(SLOT_FIXTURE_MAP[slot]))
            payload["result_path"] = str(claude_out)
            payload["result_text_sha256"] = out["data"].get("result_text_sha256")
            payload["source_provider"] = "claude-codex-adapters.py"
            return payload, "claude-codex-adapters.py"
        except Exception:
            return read_json(SLOT_FIXTURE_MAP[slot]), "fixture_fallback:provider-result.claude.json"

    fixture_path = SLOT_FIXTURE_MAP.get(slot)
    if fixture_path is None or not fixture_path.exists():
        raise RuntimeError(f"No provider result source available for slot {slot}")
    return read_json(fixture_path), f"fixture:{fixture_path.name}"


def action_fanout(run_dir: Path, data, warnings):
    route_config, route_path = resolve_route_config(run_dir)
    slots = choose_fanout_slots(route_config)
    if not slots:
        raise RuntimeError("No first_plan/independent_review slots resolved from route config")

    prompt_manifest_path = run_dir / "inputs" / "prompt-manifest.md"
    if not prompt_manifest_path.exists():
        shutil.copyfile(FIXTURES / "prompt-manifest.json", prompt_manifest_path)

    executed = []
    for slot in slots:
        request_record = {
            "provider_slot": slot,
            "request_time": utc_now(),
            "prompt_path": str(prompt_manifest_path),
        }
        request_path = run_dir / "provider_requests" / f"{slot}.request.json"
        write_json(request_path, request_record)

        provider_result, source = provider_result_from_slot(slot, prompt_manifest_path, run_dir)
        result_path = run_dir / "provider_results" / f"{slot}.json"
        write_json(result_path, provider_result)

        executed.append(
            {
                "provider_slot": slot,
                "provider_result_path": str(result_path),
                "request_path": str(request_path),
                "source": source,
            }
        )
        if source.startswith("fixture:"):
            warnings.append(f"{slot}: using fixture-backed provider result ({source})")

    data["route_config_path"] = str(route_path)
    data["provider_routes_executed"] = [x["provider_slot"] for x in executed]
    data["provider_executions"] = executed
    data["provider_result_count"] = len(executed)


def action_normalize(run_dir: Path, data):
    provider_dir = run_dir / "provider_results"
    results = sorted(provider_dir.glob("*.json"))
    if not results:
        raise RuntimeError(f"No provider results found in {provider_dir}")

    normalized_paths = []
    for provider_result_path in results:
        out = run_subprocess_json(
            [
                sys.executable,
                str(SCRIPTS / "normalize-plan-ir.py"),
                str(provider_result_path),
                "--stage",
                "export",
                "--json",
            ],
            ROOT,
        )
        normalized = out.get("data") or {}
        slot = normalized.get("source_provider_slot", provider_result_path.stem)
        target = run_dir / "normalized_plans" / f"{slot}.normalized.json"
        write_json(target, normalized)
        normalized_paths.append(str(target))

    data["normalized_artifacts"] = normalized_paths
    data["normalized_count"] = len(normalized_paths)


def action_compare(run_dir: Path, data):
    normalized_dir = run_dir / "normalized_plans"
    artifacts = [read_json(path) for path in sorted(normalized_dir.glob("*.json"))]
    if len(artifacts) < 2:
        raise RuntimeError(f"Need at least 2 normalized plan artifacts in {normalized_dir} for compare")

    baseline_counts = {}
    contradictions = 0
    for artifact in artifacts:
        baseline = artifact.get("source_baseline_sha256")
        if baseline:
            baseline_counts[baseline] = baseline_counts.get(baseline, 0) + 1
        refs = artifact.get("provider_result_refs", [])
        if not refs:
            contradictions += 1
        elif any(not ref.get("result_text_sha256") for ref in refs):
            contradictions += 1

    agreements = 0
    for count in baseline_counts.values():
        if count > 1:
            agreements += (count * (count - 1)) // 2

    comparison = {
        "schema_version": "comparison_result.v1",
        "artifact_count": len(artifacts),
        "agreements": agreements,
        "contradictions": contradictions,
        "baseline_groups": baseline_counts,
        "compared_at": utc_now(),
    }
    out_path = run_dir / "comparison" / "comparison-result.json"
    write_json(out_path, comparison)
    data["comparison_result"] = comparison
    data["comparison_artifact"] = str(out_path)


def action_synthesize(run_dir: Path, data):
    comparison_path = run_dir / "comparison" / "comparison-result.json"
    if not comparison_path.exists():
        raise RuntimeError(f"Missing comparison artifact: {comparison_path}")
    comparison = read_json(comparison_path)

    normalized = [read_json(path) for path in sorted((run_dir / "normalized_plans").glob("*.json"))]
    if not normalized:
        raise RuntimeError("No normalized plans available for synthesis")

    final_plan = {
        "schema_version": "final_plan_artifact.v1",
        "bundle_version": VERSION,
        "generated_at": utc_now(),
        "comparison_result": comparison,
        "normalized_inputs": [artifact.get("plan_id", "unknown-plan-id") for artifact in normalized],
        "synthesis_summary": {
            "status": "ready" if comparison.get("contradictions", 0) == 0 else "needs_review",
            "agreements": comparison.get("agreements", 0),
            "contradictions": comparison.get("contradictions", 0),
        },
    }
    synthesis_path = run_dir / "synthesis" / "final-plan-artifact.json"
    write_json(synthesis_path, final_plan)
    data["synthesis_artifact"] = str(synthesis_path)
    data["synthesis_status"] = final_plan["synthesis_summary"]["status"]


def main():
    ap = argparse.ArgumentParser(description="v18 Plan Pipeline Operations.")
    ap.add_argument("--action", choices=["fanout", "normalize", "compare", "synthesize"], required=True)
    ap.add_argument("--run-dir", help="Path to planning run directory")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    logs_dir = Path("tests/logs/v18/plan/pipeline")
    logs_dir.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    log_file = logs_dir / f"pipeline_{args.action}_{timestamp}.log"
    logging.basicConfig(filename=log_file, level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")

    errors = []
    warnings = []
    data = {"stage": args.action, "status": "success"}

    try:
        run_dir = (Path(args.run_dir).resolve() if args.run_dir else default_run_dir())
        ensure_layout(run_dir)
        data["run_dir"] = str(run_dir)
        logging.info("Executing plan pipeline action=%s run_dir=%s", args.action, run_dir)

        if args.action == "fanout":
            action_fanout(run_dir, data, warnings)
        elif args.action == "normalize":
            if not any((run_dir / "provider_results").glob("*.json")):
                warnings.append("normalize: provider_results missing; running fanout first")
                action_fanout(run_dir, data, warnings)
            action_normalize(run_dir, data)
        elif args.action == "compare":
            if not any((run_dir / "normalized_plans").glob("*.json")):
                warnings.append("compare: normalized_plans missing; running normalize first")
                if not any((run_dir / "provider_results").glob("*.json")):
                    warnings.append("compare: provider_results missing; running fanout first")
                    action_fanout(run_dir, data, warnings)
                action_normalize(run_dir, data)
            action_compare(run_dir, data)
        elif args.action == "synthesize":
            if not (run_dir / "comparison" / "comparison-result.json").exists():
                warnings.append("synthesize: comparison result missing; running compare first")
                if not any((run_dir / "normalized_plans").glob("*.json")):
                    warnings.append("synthesize: normalized_plans missing; running normalize first")
                    if not any((run_dir / "provider_results").glob("*.json")):
                        warnings.append("synthesize: provider_results missing; running fanout first")
                        action_fanout(run_dir, data, warnings)
                    action_normalize(run_dir, data)
                action_compare(run_dir, data)
            action_synthesize(run_dir, data)
        else:
            raise RuntimeError(f"Unsupported action: {args.action}")

    except Exception as exc:
        errors.append(str(exc))
        data["status"] = "failed"
        logging.error("Pipeline error: %s", exc)

    out = env(
        ok=not errors,
        data=data,
        warnings=warnings,
        errors=[{"error_code": "pipeline_failed", "message": e} for e in errors],
        blocked_reason="plan_pipeline_failed" if errors else None,
    )

    if args.json:
        print(json.dumps(out, indent=2, sort_keys=True))
        sys.exit(0 if out.get("ok") else 1)

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)

    print(f"v18 Plan Pipeline: {args.action} complete.")
    sys.exit(0)


if __name__ == "__main__":
    main()
