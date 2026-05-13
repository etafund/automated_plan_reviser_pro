#!/usr/bin/env python3
# Bundle version: v18.0.0
from __future__ import annotations
import argparse, json, hashlib
VERSION='v18.0.0'
def h(label): return 'sha256:'+hashlib.sha256(label.encode()).hexdigest()
def env(data=None, warnings=None, ok=True, errors=None, next_command=None, fix_command=None, blocked_reason=None, retry_safe=True):
    return {'ok': ok, 'schema_version': 'json_envelope.v1', 'data': data or {}, 'meta': {'tool':'apr-mock','failure_mode_ledger':'fixtures/failure-mode-ledger.json', 'live_cutover_checklist':'fixtures/live-cutover-checklist.json', 'run_progress':'fixtures/run-progress.json', 'bundle_version': VERSION}, 'warnings': warnings or ['mock output only'], 'errors': errors or [], 'commands': {}, 'next_command': next_command, 'fix_command': fix_command, 'blocked_reason': blocked_reason, 'retry_safe': retry_safe}
def main():
    p=argparse.ArgumentParser(description='APR v18 mock for contract development.')
    p.add_argument('argv', nargs='*')
    p.add_argument('--json', action='store_true')
    ns,unknown=p.parse_known_args()
    argv=ns.argv+unknown
    joined=' '.join(argv)
    if not argv or 'capabilities' in argv:
        data={'mock':True,'capabilities':['providers plan-routes','providers readiness','prompts compile','plan fanout','plan normalize','plan compare','plan synthesize','run report','plan handoff','provider_access_policy','evidence_gating','route_readiness','deepseek_v4_pro_reasoning_search','deepseek doctor','xai doctor','claude-code doctor','highest_reasoning_policy','review_quorum_policy','stage_scoped_fanout','provider_result_xai_fixture','context_serialization_policy','toon_prompt_context_compression','serialization doctor'],'bundle_version':VERSION}

    elif 'serialization' in argv and 'doctor' in argv:
        data={'mock':True,'schema_version':'context_serialization_policy.v1','format':'toon','available':False,'required':False,'canonical_storage':'json','prompt_context_preference':'json','default_effective_format':'json','fallback_format':'json','legal_review_required':True,'enabled_by_default':False,'cli_candidates':['toon','tru'],'warning':'mock does not require local toon_rust; real APR should detect toon/tru and fall back to JSON'}

    elif 'xai' in argv and 'doctor' in argv:
        data={'mock':True,'provider':'xai_grok','provider_slot':'xai_grok_reasoning','model':'grok-4.3','api_key_env':'XAI_API_KEY','reasoning_effort':'high','highest_reasoning_verified':True,'bundle_version':VERSION}
    elif 'claude-code' in argv and 'doctor' in argv:
        data={'mock':True,'provider':'claude','provider_slot':'claude_code_opus','model':'claude-opus-4-7','access_path':'claude_code_subscription_cli','effort':'max','thinking':{'type':'adaptive'},'claude_code_keyword':'ultrathink','cli_controls':['claude --model claude-opus-4-7 --effort max','CLAUDE_CODE_EFFORT_LEVEL=max','prompt includes ultrathink'],'highest_reasoning_verified':True,'bundle_version':VERSION}
    elif 'deepseek' in argv and 'doctor' in argv:
        data={'mock':True,'provider':'deepseek','provider_slot':'deepseek_v4_pro_reasoning_search','model':'deepseek-v4-pro','official_api':True,'api_key_env':'DEEPSEEK_API_KEY','thinking':{'type':'enabled'},'reasoning_effort':'max','reasoning_effort_verified':True,'reasoning_content_policy':'transient_tool_replay_hash_only_persisted','search_enabled':True,'search_mode':'tool_call_web_search','bundle_version':VERSION}
    elif 'plan-routes' in argv:
        fast='fast' in joined
        data={'mock':True,'schema_version':'provider_route.v1','profile':'fast' if fast else 'balanced','required_slots':['codex_thinking_fast_draft'] if fast else ['chatgpt_pro_first_plan','gemini_deep_think','chatgpt_pro_synthesis'], 'stage_required_slots': {'first_plan':['codex_thinking_fast_draft']} if fast else {'first_plan':['chatgpt_pro_first_plan'],'independent_review':['gemini_deep_think'],'synthesis':['chatgpt_pro_synthesis']}, 'optional_slots': [] if fast else ['claude_code_opus','xai_grok_reasoning','deepseek_v4_pro_reasoning_search'], 'codex_fast_draft_formal_first_plan': False,'remote_browser_primary': not fast, 'model_reasoning_policy':'fixtures/model-reasoning-policy.json', 'review_quorum_policy':'fixtures/review-quorum.balanced.json', 'review_quorum':{'independent_review_min_total':2,'optional_review_min_successes':1}, 'highest_reasoning_required': True,'bundle_version':VERSION}
    elif 'readiness' in argv:
        data={'mock':True,'schema_version':'route_readiness.v1','routes_ready':True,'ready_scope':'preflight','preflight_ready':True,'synthesis_prompt_ready':False,'synthesis_ready':False,'review_quorum_ready':False,'pending_browser_evidence_for':['chatgpt_pro_first_plan','gemini_deep_think'], 'synthesis_prompt_blocked_until_evidence_for':['chatgpt_pro_first_plan','gemini_deep_think'], 'final_handoff_blocked_until_evidence_for':['chatgpt_pro_first_plan','gemini_deep_think','chatgpt_pro_synthesis'],'blocked':[],'degraded':[],'policy_checked':'provider_access_policy.v1','evidence_required_for':['chatgpt_pro_first_plan','gemini_deep_think','chatgpt_pro_synthesis'], 'api_key_required_for':['deepseek_v4_pro_reasoning_search','xai_grok_reasoning'], 'search_tool_required_for':['deepseek_v4_pro_reasoning_search'], 'highest_reasoning_required_for':['chatgpt_pro_first_plan','gemini_deep_think','chatgpt_pro_synthesis','claude_code_opus','xai_grok_reasoning','deepseek_v4_pro_reasoning_search'],'bundle_version':VERSION}
    elif 'compile' in argv:
        data={'mock':True,'prompt_manifests':['chatgpt_pro_first_plan','gemini_deep_think','claude_code_opus','xai_grok_reasoning','deepseek_v4_pro_reasoning_search','chatgpt_pro_synthesis'],'prompt_manifest_sha256':h('prompt-manifest-demo'),'context_serialization':'auto','canonical_storage':'json','optional_toon_rust':True,'context_serialization_policy':'fixtures/context-serialization-policy.json','bundle_version':VERSION}
    elif 'fanout' in argv:
        data={'mock':True,'provider_results':['chatgpt_pro_first_plan','gemini_deep_think','claude_code_opus','xai_grok_reasoning','deepseek_v4_pro_reasoning_search'], 'planned_synthesis_provider':'chatgpt_pro_synthesis', 'fanout_stages':['first_plan','independent_review'], 'highest_reasoning_requested_for_all': True, 'review_quorum_policy':'fixtures/review-quorum.balanced.json','all_critical_browser_evidence_verified':True,'bundle_version':VERSION}
    elif 'report' in argv:
        data={'mock':True,'report_path':'.apr/runs/mock/report.md','human_review_packet':True,'bundle_version':VERSION}
    elif 'synthesize' in argv:
        data={'mock':True,'synthesis_provider':'chatgpt_pro_synthesis','evidence_required':True,'bundle_version':VERSION}
    else:
        out=env(ok=False, errors=[{'error_code':'unsupported_mock_command','message':'APR mock only supports capabilities, deepseek doctor, plan-routes, readiness, compile, fanout, synthesize, and report.'}], next_command='python3 scripts/apr-mock.py capabilities --json', fix_command='Use one of the documented mock commands in ROBOTS.md', blocked_reason='unsupported_mock_command', retry_safe=True)
        print(json.dumps(out, indent=2, sort_keys=True)); return 2
    print(json.dumps(env(data), indent=2, sort_keys=True)); return 0
if __name__=='__main__': raise SystemExit(main())
