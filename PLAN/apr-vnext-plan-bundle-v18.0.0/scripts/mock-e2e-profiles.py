#!/usr/bin/env python3
"""Black-box v18 mock E2E profile runner."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


VERSION = "v18.0.0"
ENVELOPE_VERSION = "json_envelope.v1"
PROFILES = ("fast", "balanced", "audit")
ARTIFACTS = {
    "source_baseline": "fixtures/source-baseline.json",
    "prompt_context": "fixtures/prompt-context-packet.json",
    "prompt_manifest": "fixtures/prompt-manifest.json",
    "plan_ir": "fixtures/plan-artifact.json",
    "synthesis": "fixtures/synthesis-finalization.json",
    "traceability": "fixtures/traceability.json",
    "review_packet": "fixtures/human-review-packet.json",
    "artifact_index": "fixtures/artifact-index.json",
    "approval_ledger": "fixtures/approval-ledger.json",
}
PROVIDER_RESULT_FIXTURES = {
    "chatgpt_pro_first_plan": "fixtures/provider-result.chatgpt.json",
    "chatgpt_pro_synthesis": "fixtures/provider-result.chatgpt-synthesis.json",
    "gemini_deep_think": "fixtures/provider-result.gemini.json",
    "claude_code_opus": "fixtures/provider-result.claude.json",
    "xai_grok_reasoning": "fixtures/provider-result.xai.json",
    "deepseek_v4_pro_reasoning_search": "fixtures/provider-result.deepseek.json",
}
EVIDENCE_FIXTURES = {
    "chatgpt_pro_first_plan": "fixtures/chatgpt-pro-evidence.json",
    "chatgpt_pro_synthesis": "fixtures/chatgpt-pro-evidence.json",
    "gemini_deep_think": "fixtures/gemini-deep-think-evidence.json",
}


def envelope(
    ok: bool,
    data: dict[str, Any],
    errors: list[dict[str, str]],
    warnings: list[str] | None = None,
) -> dict[str, Any]:
    return {
        "ok": ok,
        "schema_version": ENVELOPE_VERSION,
        "data": data,
        "meta": {"tool": "mock-e2e-profiles", "bundle_version": VERSION},
        "warnings": warnings or [],
        "errors": errors,
        "commands": {
            "next": "python3 scripts/mock-e2e-profiles.py --json",
            "profile": "python3 scripts/mock-e2e-profiles.py --json --profile balanced",
        },
        "blocked_reason": None if ok else "mock_e2e_profiles_failed",
        "next_command": None if ok else "python3 scripts/mock-e2e-profiles.py --json",
        "fix_command": None if ok else "inspect tests/logs/v18/e2e/<profile>/<run-id>/command-transcript.json",
        "retry_safe": True,
    }


def timestamp() -> str:
    return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return "sha256:" + digest.hexdigest()


def load_json(path: Path) -> dict[str, Any]:
    try:
        loaded = json.JSONDecoder().decode(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"{path}: failed to load JSON: {exc}") from exc
    if not isinstance(loaded, dict):
        raise RuntimeError(f"{path}: expected JSON object")
    return loaded


def write_json(path: Path, data: dict[str, Any] | list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def create_fixture_project(path: Path, profile: str) -> dict[str, str]:
    docs_dir = path / "docs"
    workflow_dir = path / ".apr" / "workflows"
    rounds_dir = path / ".apr" / "rounds" / f"v18-{profile}"
    templates_dir = path / ".apr" / "templates"
    for directory in [docs_dir, workflow_dir, rounds_dir, templates_dir]:
        directory.mkdir(parents=True, exist_ok=True)

    readme = path / "README.md"
    spec = path / "SPECIFICATION.md"
    impl = docs_dir / "implementation.md"
    workflow = workflow_dir / f"v18-{profile}.yaml"
    config = path / ".apr" / "config.yaml"

    readme.write_text(f"# APR v18 {profile} Mock Project\n\nA deterministic fixture project for mock E2E validation.\n", encoding="utf-8")
    spec.write_text("## Specification\n\nExercise source, prompt, provider, synthesis, and export contracts.\n", encoding="utf-8")
    impl.write_text("## Implementation Notes\n\nNo live providers are invoked by this fixture.\n", encoding="utf-8")
    workflow.write_text(
        "\n".join([
            f"name: v18-{profile}",
            f"description: v18 {profile} mock E2E workflow",
            "documents:",
            "  readme: README.md",
            "  spec: SPECIFICATION.md",
            "  implementation: docs/implementation.md",
            "oracle:",
            "  model: 5.2 Thinking",
            "rounds:",
            f"  output_dir: .apr/rounds/v18-{profile}",
            "template: |",
            "  Run the v18 mock planning profile.",
            "",
        ]),
        encoding="utf-8",
    )
    config.write_text(f"default_workflow: v18-{profile}\n", encoding="utf-8")

    return {
        "project_root": path.as_posix(),
        "readme": readme.as_posix(),
        "spec": spec.as_posix(),
        "implementation": impl.as_posix(),
        "workflow": workflow.as_posix(),
        "config": config.as_posix(),
    }


def run_command(command: list[str], cwd: Path, out_dir: Path) -> dict[str, Any]:
    command_id = f"{len(list(out_dir.glob('command-*.stdout.log'))) + 1:02d}-" + Path(command[1]).stem.replace("-", "_")
    stdout_path = out_dir / f"command-{command_id}.stdout.log"
    stderr_path = out_dir / f"command-{command_id}.stderr.log"
    started = timestamp()
    completed = subprocess.run(
        command,
        cwd=str(cwd),
        text=True,
        capture_output=True,
        check=False,
        timeout=120,
        env={**os.environ, "NO_COLOR": "1", "APR_NO_GUM": "1", "CI": "true", "APR_V18_FORCE_FIXTURES": "1"},
    )
    stdout_path.write_text(completed.stdout, encoding="utf-8")
    stderr_path.write_text(completed.stderr, encoding="utf-8")
    parsed: dict[str, Any] | None = None
    parse_error = None
    if completed.stdout.strip():
        try:
            decoded = json.JSONDecoder().decode(completed.stdout)
            if isinstance(decoded, dict):
                parsed = decoded
            else:
                parse_error = "stdout JSON is not an object"
        except json.JSONDecodeError as exc:
            parse_error = str(exc)
    return {
        "command": command,
        "exit_code": completed.returncode,
        "started_at": started,
        "completed_at": timestamp(),
        "stdout_log": stdout_path.as_posix(),
        "stderr_log": stderr_path.as_posix(),
        "json_ok": bool(parsed and parsed.get("schema_version") == ENVELOPE_VERSION),
        "ok": parsed.get("ok") if parsed else None,
        "meta_tool": parsed.get("meta", {}).get("tool") if parsed else None,
        "parse_error": parse_error,
    }


def command_matrix(bundle_root: Path, run_dir: Path, profile: str) -> list[list[str]]:
    script_dir = bundle_root / "scripts"
    python = sys.executable
    return [
        [python, str(script_dir / "apr-mock.py"), "capabilities", "--json"],
        [python, str(script_dir / "apr-mock.py"), "providers", "plan-routes", "--profile", profile, "--json"],
        [python, str(script_dir / "apr-mock.py"), "providers", "readiness", "--profile", profile, "--json"],
        [python, str(script_dir / "apr-mock.py"), "prompts", "compile", "--profile", profile, "--json"],
        [python, str(script_dir / "plan-pipeline.py"), "--action", "fanout", "--run-dir", str(run_dir), "--json"],
        [python, str(script_dir / "plan-pipeline.py"), "--action", "normalize", "--run-dir", str(run_dir), "--json"],
        [python, str(script_dir / "plan-pipeline.py"), "--action", "compare", "--run-dir", str(run_dir), "--json"],
        [python, str(script_dir / "plan-pipeline.py"), "--action", "synthesize", "--run-dir", str(run_dir), "--json"],
        [python, str(script_dir / "plan-export-beads.py"), "--plan", str(bundle_root / "fixtures/plan-artifact.json"), "--json"],
        [python, str(script_dir / "v18-run-ops.py"), "--action", "status", "--run-dir", str(run_dir), "--json"],
        [python, str(script_dir / "v18-run-ops.py"), "--action", "report", "--run-dir", str(run_dir), "--json"],
    ]


def artifact_summary(root: Path, profile: str) -> tuple[list[dict[str, Any]], list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []
    artifacts: list[dict[str, Any]] = []
    route = load_json(root / f"fixtures/provider-route.{profile}.json")
    slots = list(dict.fromkeys(route.get("required_slots", []) + route.get("optional_slots", [])))

    for kind, rel in ARTIFACTS.items():
        path = root / rel
        if not path.exists():
            errors.append(f"missing {kind} artifact: {rel}")
            continue
        artifacts.append({"kind": kind, "path": rel, "sha256": sha256_file(path)})

    for slot in slots:
        rel = PROVIDER_RESULT_FIXTURES.get(slot)
        if rel and (root / rel).exists():
            artifacts.append({"kind": "provider_result", "provider_slot": slot, "path": rel, "sha256": sha256_file(root / rel)})
        elif slot.startswith("codex_"):
            warnings.append(f"{slot}: codex intake route has no provider-result fixture")
        else:
            errors.append(f"{slot}: missing provider-result fixture")

        evidence_rel = EVIDENCE_FIXTURES.get(slot)
        if evidence_rel and (root / evidence_rel).exists():
            artifacts.append({"kind": "browser_evidence", "provider_slot": slot, "path": evidence_rel, "sha256": sha256_file(root / evidence_rel)})

    return artifacts, errors, warnings


def write_events(run_dir: Path, commands: list[dict[str, Any]], profile: str) -> Path:
    events = []
    for index, command in enumerate(commands, start=1):
        events.append({
            "timestamp": command["completed_at"],
            "stage": command["meta_tool"] or f"command_{index}",
            "action": "mock_e2e_step",
            "outcome": "success" if command["exit_code"] == 0 and command["json_ok"] else "failed",
            "profile": profile,
            "command": " ".join(command["command"]),
        })
    path = run_dir / "events.jsonl"
    path.write_text("\n".join(json.dumps(event, sort_keys=True) for event in events) + "\n", encoding="utf-8")
    return path


def run_profile(bundle_root: Path, profile: str, log_root: Path) -> dict[str, Any]:
    run_id = f"mock-e2e-{profile}-{timestamp()}"
    profile_dir = log_root / profile / run_id
    run_dir = profile_dir / ".apr" / "runs" / run_id
    command_dir = profile_dir / "commands"
    for directory in [run_dir / "reports", command_dir]:
        directory.mkdir(parents=True, exist_ok=True)
    fixture_project = create_fixture_project(profile_dir / "fixture-project", profile)

    commands = []
    for command in command_matrix(bundle_root, run_dir, profile):
        if Path(command[1]).name == "v18-run-ops.py" and not (run_dir / "events.jsonl").exists():
            write_events(run_dir, commands, profile)
        commands.append(run_command(command, bundle_root.parents[1], command_dir))
    event_path = write_events(run_dir, commands, profile)
    route = load_json(bundle_root / f"fixtures/provider-route.{profile}.json")
    command_transcript = profile_dir / "command-transcript.json"
    write_json(command_transcript, commands)
    comparison_artifact = run_dir / "reports" / "comparison-summary.json"
    write_json(comparison_artifact, {
        "schema_version": "mock_e2e_comparison.v1",
        "bundle_version": VERSION,
        "profile": profile,
        "run_id": run_id,
        "summary": {
            "command_count": len(commands),
            "provider_slot_count": len(route.get("required_slots", [])) + len(route.get("optional_slots", [])),
            "all_commands_json": all(command["json_ok"] for command in commands),
        },
    })
    artifacts, artifact_errors, artifact_warnings = artifact_summary(bundle_root, profile)
    artifacts.extend([
        {"kind": "comparison", "path": comparison_artifact.as_posix(), "sha256": sha256_file(comparison_artifact)},
        {"kind": "events", "path": event_path.as_posix(), "sha256": sha256_file(event_path)},
        {"kind": "logs", "path": command_transcript.as_posix(), "sha256": sha256_file(command_transcript)},
    ])
    command_failures = [
        command
        for command in commands
        if command["exit_code"] != 0 or not command["json_ok"] or command["ok"] is not True
    ]
    required_kinds = {entry["kind"] for entry in artifacts}
    missing_kinds = sorted({"source_baseline", "prompt_context", "plan_ir", "comparison", "synthesis", "traceability", "review_packet", "artifact_index", "events", "logs"} - required_kinds)
    errors = artifact_errors[:]
    errors.extend(f"command failed: {' '.join(command['command'])}" for command in command_failures)
    errors.extend(f"missing required artifact kind: {kind}" for kind in missing_kinds)
    status = "pass" if not errors else "fail"

    summary = {
        "profile": profile,
        "run_id": run_id,
        "status": status,
        "log_bundle": profile_dir.as_posix(),
        "fixture_project": fixture_project,
        "run_dir": run_dir.as_posix(),
        "event_log": event_path.as_posix(),
        "route": {
            "profile": route.get("profile"),
            "required_slots": route.get("required_slots", []),
            "optional_slots": route.get("optional_slots", []),
            "route_count": len(route.get("routes", [])),
            "review_quorum": route.get("review_quorum"),
        },
        "commands": commands,
        "artifacts": artifacts,
        "artifact_tree": sorted(str(path.relative_to(profile_dir)) for path in profile_dir.rglob("*") if path.is_file()),
        "warnings": artifact_warnings,
        "errors": errors,
        "rerun_command": f"python3 scripts/mock-e2e-profiles.py --json --profile {profile}",
    }
    write_json(profile_dir / "profile-summary.json", summary)
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description="Run deterministic v18 mock E2E profiles.")
    parser.add_argument("--json", action="store_true", help="Emit v18 JSON envelope.")
    parser.add_argument("--profile", choices=PROFILES + ("all",), default="all", help="Profile to run.")
    parser.add_argument("--bundle-root", default=str(Path(__file__).resolve().parents[1]), help="Path to v18 bundle root.")
    parser.add_argument("--log-root", default="tests/logs/v18/e2e", help="Root for profile log bundles.")
    args = parser.parse_args()

    bundle_root = Path(args.bundle_root).resolve()
    log_root = Path(args.log_root).resolve()
    selected = list(PROFILES if args.profile == "all" else (args.profile,))
    warnings: list[str] = []
    errors: list[dict[str, str]] = []
    profiles: list[dict[str, Any]] = []
    for profile in selected:
        try:
            result = run_profile(bundle_root, profile, log_root)
        except RuntimeError as exc:
            result = {"profile": profile, "status": "fail", "errors": [str(exc)]}
        profiles.append(result)
        warnings.extend(f"{profile}: {warning}" for warning in result.get("warnings", []))
        for error in result.get("errors", []):
            errors.append({"error_code": "mock_e2e_profile_failed", "message": f"{profile}: {error}"})

    passed = sum(1 for profile in profiles if profile.get("status") == "pass")
    data = {
        "bundle_version": VERSION,
        "checked_root": bundle_root.as_posix(),
        "log_root": log_root.as_posix(),
        "profile_count": len(profiles),
        "profiles_passed": passed,
        "coverage": {
            "profile_cases": len(profiles),
            "must_clauses": len(profiles),
            "should_clauses": 0,
            "tested": len(profiles),
            "passing": passed,
            "divergent": 0,
            "score": passed / len(profiles) if profiles else 0,
        },
        "profiles": profiles,
    }
    output = envelope(not errors, data, errors, warnings)
    print(json.dumps(output, indent=2, sort_keys=True) if args.json else ("ok" if not errors else "\n".join(error["message"] for error in errors)))
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
