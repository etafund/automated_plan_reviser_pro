#!/usr/bin/env python3
"""Opt-in v18 live cutover dress rehearsal.

The default mode is a dry-run checklist. Live execution requires both
--execute-live and APR_V18_LIVE_CUTOVER=1 so a CI or local validation run cannot
accidentally spend provider/browser capacity.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess  # nosec B404 - optional live path uses fixed argv, shell=False.
import time
from pathlib import Path


VERSION = "v18.0.0"
LIVE_ENV = "APR_V18_LIVE_CUTOVER"
TOKEN_ENV_NAMES = {
    "ORACLE_REMOTE_TOKEN",
    "ORACLE_REMOTE_TOKENS",
    "XAI_API_KEY",
    "DEEPSEEK_API_KEY",
}
FORBIDDEN_ARTIFACT_FIELDS = {
    "api_keys",
    "browser_cookies",
    "oauth_tokens",
    "raw_hidden_reasoning",
    "reasoning_content",
    "unredacted_dom",
    "unredacted_screenshot",
}


def envelope(
    ok: bool,
    data: dict | None = None,
    warnings: list[str] | None = None,
    errors: list[dict] | None = None,
    blocked_reason: str | None = None,
    next_command: str | None = None,
    fix_command: str | None = None,
    retry_safe: bool = True,
) -> dict:
    return {
        "ok": ok,
        "schema_version": "json_envelope.v1",
        "data": data or {},
        "meta": {"tool": "live-cutover-dress-rehearsal", "bundle_version": VERSION},
        "warnings": warnings or [],
        "errors": errors or [],
        "commands": {
            "next": "python3 scripts/live-cutover-dress-rehearsal.py --json --approval-id <id>",
            "execute_live": f"{LIVE_ENV}=1 python3 scripts/live-cutover-dress-rehearsal.py --json --approval-id <id> --execute-live",
        },
        "next_command": next_command,
        "fix_command": fix_command,
        "blocked_reason": blocked_reason,
        "retry_safe": retry_safe,
    }


def load_json(path: Path) -> dict:
    try:
        loaded = json.JSONDecoder().decode(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"failed to load JSON fixture {path}: {exc}") from exc
    if not isinstance(loaded, dict):
        raise RuntimeError(f"JSON fixture {path} must contain an object")
    return loaded


def exact_false(value: object) -> bool:
    return isinstance(value, bool) and not value


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return "sha256:" + digest.hexdigest()


def timestamp() -> str:
    return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())


def parse_utc(value: str | None) -> int | None:
    if not value:
        return None
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S.%fZ"):
        try:
            return int(time.mktime(time.strptime(value, fmt)))
        except ValueError:
            continue
    return None


def relpath(path: Path, root: Path) -> str:
    try:
        return path.relative_to(root).as_posix()
    except ValueError:
        return path.as_posix()


def make_log_dir(root: Path, rehearsal_id: str) -> Path:
    log_dir = root / rehearsal_id
    log_dir.mkdir(parents=True, exist_ok=True)
    return log_dir


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def token_presence() -> dict:
    return {
        name: {"present": bool(os.environ.get(name)), "value": "<redacted>" if os.environ.get(name) else None}
        for name in sorted(TOKEN_ENV_NAMES)
    }


def plain_remote_env() -> dict:
    return {
        "ORACLE_REMOTE_HOST": os.environ.get("ORACLE_REMOTE_HOST", ""),
        "ORACLE_REMOTE_POOL": os.environ.get("ORACLE_REMOTE_POOL", ""),
        "tokens": token_presence(),
    }


def checklist_summary(bundle_root: Path, errors: list[dict]) -> dict:
    path = bundle_root / "fixtures/live-cutover-checklist.json"
    if not path.exists():
        errors.append({"error_code": "live_cutover_checklist_missing", "message": f"Missing {relpath(path, bundle_root)}"})
        return {"path": relpath(path, bundle_root), "present": False}

    checklist = load_json(path)
    phases = checklist.get("phases", [])
    phase_ids = [phase.get("phase_id") for phase in phases]
    minimum_gate = checklist.get("minimum_release_gate")
    if minimum_gate != "phase_5_balanced_live_dress_rehearsal":
        errors.append({
            "error_code": "live_cutover_minimum_gate_invalid",
            "message": "minimum_release_gate must be phase_5_balanced_live_dress_rehearsal",
        })
    if minimum_gate not in phase_ids:
        errors.append({
            "error_code": "live_cutover_gate_phase_missing",
            "message": "balanced live dress rehearsal phase is absent from checklist",
        })

    required_phases = [
        "phase_2_oracle_remote_smoke",
        "phase_4_one_provider_live",
        "phase_5_balanced_live_dress_rehearsal",
    ]
    missing = [phase_id for phase_id in required_phases if phase_id not in phase_ids]
    if missing:
        errors.append({
            "error_code": "live_cutover_required_phase_missing",
            "message": "Missing required live cutover phase(s): " + ", ".join(missing),
        })

    return {
        "path": relpath(path, bundle_root),
        "present": True,
        "checklist_id": checklist.get("checklist_id"),
        "schema_version": checklist.get("schema_version"),
        "minimum_release_gate": minimum_gate,
        "phase_count": len(phases),
        "phase_ids": phase_ids,
        "sha256": sha256_file(path),
    }


def docs_snapshot_summary(bundle_root: Path, errors: list[dict], warnings: list[str]) -> dict:
    path = bundle_root / "fixtures/provider-docs-snapshot.json"
    if not path.exists():
        errors.append({"error_code": "provider_docs_snapshot_missing", "message": f"Missing {relpath(path, bundle_root)}"})
        return {"path": relpath(path, bundle_root), "present": False}

    snapshot = load_json(path)
    expires_at = snapshot.get("expires_at")
    expiry = parse_utc(expires_at)
    now = int(time.time())
    fresh = expiry is not None and expiry > now
    if not fresh:
        errors.append({"error_code": "provider_docs_snapshot_stale", "message": "Provider docs snapshot is expired or unparsable"})
    if not snapshot.get("refresh_required_before_live_provider_calls"):
        warnings.append("provider_docs_snapshot_refresh_flag_missing")

    return {
        "path": relpath(path, bundle_root),
        "present": True,
        "checked_at": snapshot.get("checked_at"),
        "expires_at": expires_at,
        "fresh_for_live": fresh,
        "source_count": len(snapshot.get("sources", [])),
        "sha256": sha256_file(path),
    }


def provider_capabilities(bundle_root: Path, execute_live: bool, errors: list[dict], warnings: list[str]) -> list[dict]:
    caps = []
    for path in sorted((bundle_root / "fixtures").glob("provider-capability*.json")):
        cap = load_json(path)
        required_env = cap.get("required_env") or []
        env_present = {name: bool(os.environ.get(name)) for name in required_env}
        if cap.get("status") != "ready":
            errors.append({
                "error_code": "provider_capability_not_ready",
                "message": f"{path.name} status is {cap.get('status')!r}",
            })
        missing_env = [name for name, present in env_present.items() if not present]
        if missing_env and execute_live:
            errors.append({
                "error_code": "provider_live_env_missing",
                "message": f"{path.name} missing required env for live execution: {', '.join(missing_env)}",
            })
        elif missing_env:
            warnings.append(f"{path.name}: live env not set for {', '.join(missing_env)}")
        caps.append({
            "path": relpath(path, bundle_root),
            "provider": cap.get("provider"),
            "provider_slot": cap.get("provider_slot"),
            "status": cap.get("status"),
            "checked_at": cap.get("checked_at"),
            "required_env": required_env,
            "required_env_present": env_present,
            "access_path": cap.get("access_path"),
            "api_allowed": cap.get("api_allowed"),
            "sha256": sha256_file(path),
        })
    if not caps:
        errors.append({"error_code": "provider_capability_snapshot_missing", "message": "No provider capability fixtures found"})
    return caps


def browser_artifacts(bundle_root: Path, errors: list[dict]) -> dict:
    lease_path = bundle_root / "fixtures/browser-lease.json"
    evidence_paths = [
        bundle_root / "fixtures/chatgpt-pro-evidence.json",
        bundle_root / "fixtures/gemini-deep-think-evidence.json",
    ]
    result: dict = {"lease": None, "evidence": []}

    if not lease_path.exists():
        errors.append({"error_code": "browser_lease_missing", "message": f"Missing {relpath(lease_path, bundle_root)}"})
    else:
        lease = load_json(lease_path)
        remote = lease.get("remote_browser", {})
        if remote.get("no_plaintext_secrets") is not True:
            errors.append({"error_code": "browser_lease_secret_boundary_invalid", "message": "Browser lease must forbid plaintext secrets"})
        result["lease"] = {
            "path": relpath(lease_path, bundle_root),
            "lease_id": lease.get("lease_id"),
            "provider": lease.get("provider"),
            "status": lease.get("status"),
            "remote_status": remote.get("status"),
            "host_env": remote.get("host_env"),
            "token_env": remote.get("token_env"),
            "host_configured": bool(os.environ.get(remote.get("host_env", ""))),
            "token_present": bool(os.environ.get(remote.get("token_env", ""))),
            "sha256": sha256_file(lease_path),
        }

    for path in evidence_paths:
        if not path.exists():
            errors.append({"error_code": "browser_evidence_missing", "message": f"Missing {relpath(path, bundle_root)}"})
            continue
        evidence = load_json(path)
        privacy = evidence.get("evidence_privacy", {})
        safe = (
            exact_false(privacy.get("stores_cookies"))
            and exact_false(privacy.get("stores_raw_dom"))
            and exact_false(privacy.get("stores_raw_screenshots"))
            and exact_false(privacy.get("stores_account_identifiers"))
            and evidence.get("redaction_policy") == "redacted"
        )
        if not safe:
            errors.append({"error_code": "browser_evidence_privacy_invalid", "message": f"{path.name} privacy/redaction policy is unsafe"})
        result["evidence"].append({
            "path": relpath(path, bundle_root),
            "evidence_id": evidence.get("evidence_id"),
            "provider": evidence.get("provider"),
            "provider_slot": evidence.get("provider_slot"),
            "mode_verified": evidence.get("mode_verified"),
            "reasoning_effort_verified": evidence.get("reasoning_effort_verified"),
            "redaction_policy": evidence.get("redaction_policy"),
            "stores_sensitive_material": not safe,
            "sha256": sha256_file(path),
        })

    return result


def artifact_index_summary(bundle_root: Path, errors: list[dict]) -> dict:
    path = bundle_root / "fixtures/artifact-index.json"
    if not path.exists():
        errors.append({"error_code": "artifact_index_missing", "message": f"Missing {relpath(path, bundle_root)}"})
        return {"path": relpath(path, bundle_root), "present": False}

    index = load_json(path)
    artifacts = index.get("artifacts", [])
    boundary = index.get("redaction_boundary", {})
    forbidden = set(boundary.get("forbidden_persisted_fields", []))
    boundary_ok = (
        FORBIDDEN_ARTIFACT_FIELDS.issubset(forbidden)
        and exact_false(boundary.get("private_browser_material_persisted"))
        and exact_false(boundary.get("raw_hidden_reasoning_persisted"))
        and exact_false(boundary.get("secret_material_persisted"))
    )
    if not boundary_ok:
        errors.append({"error_code": "artifact_redaction_boundary_invalid", "message": "Artifact index redaction boundary is not strict enough"})

    live_kinds = {"browser_evidence", "provider_result", "log_bundle", "approval_ledger"}
    present_kinds = {artifact.get("kind") for artifact in artifacts}
    missing = sorted(live_kinds - present_kinds)
    if missing:
        errors.append({"error_code": "artifact_index_live_kind_missing", "message": "Missing live evidence artifact kind(s): " + ", ".join(missing)})

    return {
        "path": relpath(path, bundle_root),
        "present": True,
        "artifact_count": len(artifacts),
        "live_artifact_kinds_present": sorted(present_kinds & live_kinds),
        "redaction_boundary_ok": boundary_ok,
        "sha256": sha256_file(path),
    }


def waiver_summary(bundle_root: Path, errors: list[dict]) -> dict:
    path = bundle_root / "fixtures/fallback-waiver.json"
    if not path.exists():
        errors.append({"error_code": "fallback_waiver_missing", "message": f"Missing {relpath(path, bundle_root)}"})
        return {"path": relpath(path, bundle_root), "present": False}

    waiver = load_json(path)
    non_waivable = set(waiver.get("non_waivable_slots", []))
    required = {"chatgpt_pro_first_plan", "chatgpt_pro_synthesis", "gemini_deep_think"}
    missing = sorted(required - non_waivable)
    if missing:
        errors.append({"error_code": "live_cutover_nonwaivable_slot_missing", "message": "Missing non-waivable slot(s): " + ", ".join(missing)})

    return {
        "path": relpath(path, bundle_root),
        "present": True,
        "non_waivable_slots": sorted(non_waivable),
        "sha256": sha256_file(path),
    }


def live_env_errors(execute_live: bool, approval_id: str, errors: list[dict]) -> None:
    if not approval_id:
        errors.append({
            "error_code": "live_cutover_approval_missing",
            "message": "--approval-id is required before live cutover can be considered ready",
        })
    if execute_live and os.environ.get(LIVE_ENV) != "1":
        errors.append({
            "error_code": "live_cutover_env_not_set",
            "message": f"{LIVE_ENV}=1 is required together with --execute-live",
        })
    if execute_live and not (os.environ.get("ORACLE_REMOTE_HOST") or os.environ.get("ORACLE_REMOTE_POOL")):
        errors.append({
            "error_code": "live_cutover_remote_not_configured",
            "message": "ORACLE_REMOTE_HOST or ORACLE_REMOTE_POOL must be configured for live browser smoke",
        })
    if execute_live and not (os.environ.get("ORACLE_REMOTE_TOKEN") or os.environ.get("ORACLE_REMOTE_TOKENS")):
        errors.append({
            "error_code": "live_cutover_remote_token_missing",
            "message": "ORACLE_REMOTE_TOKEN or ORACLE_REMOTE_TOKENS must be set for live browser smoke",
        })


def run_live_smoke(script: Path, log_dir: Path, errors: list[dict]) -> dict:
    result = {
        "script": script.as_posix(),
        "attempted": False,
        "exit_code": None,
        "stdout_log": "oracle-remote-smoke.stdout.log",
        "stderr_log": "oracle-remote-smoke.stderr.log",
    }
    if not script.exists():
        errors.append({"error_code": "oracle_remote_smoke_script_missing", "message": f"Missing smoke script: {script}"})
        return result

    env = os.environ.copy()
    env["APR_REMOTE_SMOKE_LOG_ROOT"] = str(log_dir / "oracle_remote_smoke")
    stdout_path = log_dir / result["stdout_log"]
    stderr_path = log_dir / result["stderr_log"]
    result["attempted"] = True
    with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
        completed = subprocess.run(  # nosec B603 - fixed executable path, shell=False.
            [str(script)],
            cwd=str(script.parents[2]),
            env=env,
            stdout=stdout,
            stderr=stderr,
            check=False,
            timeout=3600,
        )
    result["exit_code"] = completed.returncode
    if completed.returncode != 0:
        errors.append({
            "error_code": "oracle_remote_smoke_failed",
            "message": f"Oracle remote smoke exited {completed.returncode}; see log bundle",
        })
    return result


def main() -> int:
    default_bundle = Path(__file__).resolve().parents[1]
    default_repo = default_bundle.parents[1]
    parser = argparse.ArgumentParser(description="Run the v18 live cutover dress rehearsal checklist.")
    parser.add_argument("--json", action="store_true", help="Emit JSON envelope on stdout.")
    parser.add_argument("--bundle-root", default=str(default_bundle), help="Path to apr-vnext-plan-bundle-v18.0.0.")
    parser.add_argument("--approval-id", default="", help="Human approval id required before live execution.")
    parser.add_argument("--operator", default=os.environ.get("USER", "unknown"), help="Operator identity for audit metadata.")
    parser.add_argument("--route-id", default="balanced_live_dress_rehearsal", help="Route id being rehearsed.")
    parser.add_argument("--profile", default="balanced", choices=("balanced", "audit"), help="Controlled live profile.")
    parser.add_argument("--execute-live", action="store_true", help=f"Actually run the live smoke; also requires {LIVE_ENV}=1.")
    parser.add_argument("--log-root", default=str(default_repo / "tests/logs/v18/live"), help="Live cutover log root.")
    parser.add_argument("--oracle-smoke-script", default=str(default_repo / "tests/e2e/oracle_remote_smoke.sh"), help="Remote Oracle smoke script.")
    args = parser.parse_args()

    bundle_root = Path(args.bundle_root).resolve()
    rehearsal_id = f"live-cutover-{timestamp()}-{args.route_id}"
    log_dir = make_log_dir(Path(args.log_root).resolve(), rehearsal_id)

    warnings: list[str] = []
    errors: list[dict] = []
    live_env_errors(args.execute_live, args.approval_id, errors)

    if not bundle_root.exists():
        errors.append({"error_code": "bundle_root_missing", "message": f"Bundle root does not exist: {bundle_root}"})

    data = {
        "bundle_version": VERSION,
        "rehearsal_id": rehearsal_id,
        "live_mock_discriminator": "LIVE_EXECUTION_REQUESTED" if args.execute_live else "DRY_RUN_NOT_LIVE",
        "live_execution": args.execute_live,
        "live_env_required": LIVE_ENV,
        "log_bundle": log_dir.as_posix(),
        "approval": {
            "approval_id": args.approval_id or None,
            "operator": args.operator,
            "approved": bool(args.approval_id),
        },
        "route": {
            "route_id": args.route_id,
            "profile": args.profile,
            "provider_slots": [
                "chatgpt_pro_first_plan",
                "gemini_deep_think",
                "chatgpt_pro_synthesis",
            ],
            "max_live_invocations": 1,
            "live_output_label": "live-cutover" if args.execute_live else "dry-run-plan",
        },
        "environment": plain_remote_env(),
    }

    if bundle_root.exists():
        try:
            data["checklist"] = checklist_summary(bundle_root, errors)
            data["provider_docs_snapshot"] = docs_snapshot_summary(bundle_root, errors, warnings)
            data["provider_capabilities"] = provider_capabilities(bundle_root, args.execute_live, errors, warnings)
            data["browser"] = browser_artifacts(bundle_root, errors)
            data["artifact_index"] = artifact_index_summary(bundle_root, errors)
            data["waiver_policy"] = waiver_summary(bundle_root, errors)
        except RuntimeError as exc:
            errors.append({"error_code": "live_cutover_fixture_parse_failed", "message": str(exc)})

    data["live_smoke"] = {"attempted": False}
    if args.execute_live and not errors:
        data["live_smoke"] = run_live_smoke(Path(args.oracle_smoke_script).resolve(), log_dir, errors)
    elif args.execute_live:
        data["live_smoke"] = {
            "attempted": False,
            "blocked_before_provider_call": True,
            "reason": "pre_live_checks_failed",
        }

    write_json(log_dir / "rehearsal-report.json", data)
    write_json(log_dir / "environment.redacted.json", data["environment"])

    ok = not errors
    out = envelope(
        ok=ok,
        data=data,
        warnings=warnings,
        errors=errors,
        blocked_reason=None if ok else errors[0]["error_code"],
        next_command=None if ok else f"python3 scripts/live-cutover-dress-rehearsal.py --json --approval-id {args.approval_id or '<id>'}",
        fix_command=None if ok else f"Set --approval-id and, for live execution, export {LIVE_ENV}=1 with remote Oracle env.",
        retry_safe=not args.execute_live or not data.get("live_smoke", {}).get("attempted"),
    )

    print(json.dumps(out, indent=2, sort_keys=True))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
