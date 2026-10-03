#!/usr/bin/env python3
"""Focused Agent Skill catalog and Run admission smoke for host 39."""

import argparse
import hashlib
import json
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


API_BASE = "http://127.0.0.1:18080"
ADMIN_BASE = "http://127.0.0.1:18081"
DB_ENV = "/home/huahuo-runtime/config/database.env"
REPORT_SCHEMA = "huahuo.backend.agent-skill-selection-smoke.v1"
TERMINAL_STATUSES = {"succeeded", "failed", "timeout", "cancelled"}


class SmokeError(RuntimeError):
    pass


def payload(value):
    if isinstance(value, dict) and "data" in value:
        return value["data"]
    return value


def request(method, url, *, body=None, headers=None, expected=(200,)):
    actual_headers = dict(headers or {})
    data = None
    if body is not None:
        data = json.dumps(body, separators=(",", ":")).encode("utf-8")
        actual_headers.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(url, data=data, headers=actual_headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=90) as response:
            status = response.status
            raw = response.read()
    except urllib.error.HTTPError as exc:
        status = exc.code
        raw = exc.read()
    except Exception as exc:
        raise SmokeError("HTTP_TRANSPORT_FAILED:" + type(exc).__name__) from exc
    try:
        decoded = json.loads(raw.decode("utf-8")) if raw else None
    except (UnicodeDecodeError, json.JSONDecodeError):
        decoded = None
    if status not in expected:
        error_code = ""
        if isinstance(decoded, dict) and isinstance(decoded.get("error"), dict):
            error_code = str(decoded["error"].get("code", ""))
        suffix = ":" + error_code if error_code else ""
        raise SmokeError(
            "HTTP_FAILED:%s:%s:%s%s"
            % (method, urllib.parse.urlparse(url).path, status, suffix)
        )
    if decoded is None:
        raise SmokeError(
            "HTTP_JSON_MISSING:%s:%s"
            % (method, urllib.parse.urlparse(url).path)
        )
    return decoded


def database_output(sql):
    command = (
        "set -a; . "
        + DB_ENV
        + "; set +a; "
        + 'PGPASSWORD="$HUAHUO_DB_PASSWORD" psql -X -v ON_ERROR_STOP=1 -qAt '
        + '-h "$HUAHUO_DB_HOST" -p "$HUAHUO_DB_PORT" -U "$HUAHUO_DB_USER" '
        + '-d "$HUAHUO_DB_NAME"'
    )
    completed = subprocess.run(
        ["/bin/bash", "-lc", command],
        input=sql.encode("utf-8"),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode:
        raise SmokeError("DATABASE_COMMAND_FAILED")
    return completed.stdout.decode("utf-8").strip()


def database(sql):
    database_output(sql)


def database_json(sql):
    raw = database_output(sql)
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise SmokeError("DATABASE_JSON_INVALID") from exc
    if not isinstance(value, dict):
        raise SmokeError("DATABASE_JSON_SHAPE_INVALID")
    return value


def sql_literal(value):
    return "'" + str(value).replace("'", "''") + "'"


def assert_value(condition, code):
    if not condition:
        raise SmokeError(code)


def new_key(name):
    return "agent-skill-smoke-%s-%s" % (name, secrets.token_hex(16))


def smoke_phone():
    digits = "".join(str(secrets.randbelow(10)) for _ in range(8))
    return "197" + digits


def wait_for_run(auth_headers, run_id, timeout_seconds):
    deadline = time.monotonic() + timeout_seconds
    last = None
    while time.monotonic() < deadline:
        response = request(
            "GET",
            API_BASE + "/api/v1/agent/runs/" + urllib.parse.quote(run_id, safe=""),
            headers=auth_headers,
        )
        last = payload(response)
        if isinstance(last, dict) and last.get("status") in TERMINAL_STATUSES:
            return last
        time.sleep(10)
    status = str(last.get("status", "unknown")) if isinstance(last, dict) else "unknown"
    raise SmokeError("AGENT_RUN_TIMEOUT:" + status)


def snapshot_evidence(run_id, workspace_id, default_skill_id, optional_skill_id):
    run = sql_literal(run_id)
    workspace = sql_literal(workspace_id)
    default_skill = sql_literal(default_skill_id)
    optional_skill = sql_literal(optional_skill_id)
    return database_json(
        """
with target as (
  select * from agent_run_release_snapshots where agent_run_id={run}
), expanded as (
  select skill
  from target cross join lateral jsonb_array_elements(snapshot_json->'finalSkills') skill
), installations as (
  select expanded.skill->>'publicSkillProfileId' as public_skill_profile_id,
         installation.state,installation.install_mode
  from expanded
  join skill_profiles profile
    on profile.public_skill_profile_id=expanded.skill->>'publicSkillProfileId'
  left join workspace_skill_installations installation
    on installation.workspace_id={workspace}
   and installation.skill_profile_id=profile.skill_profile_id
)
select jsonb_build_object(
  'snapshotCount',(select count(*) from target),
  'finalSkillCount',(select count(*) from expanded),
  'distinctPublicSkillCount',(select count(distinct skill->>'publicSkillProfileId') from expanded),
  'defaultOccurrences',(select count(*) from expanded where skill->>'publicSkillProfileId'={default_skill}),
  'optionalOccurrences',(select count(*) from expanded where skill->>'publicSkillProfileId'={optional_skill}),
  'admissionFactCount',coalesce((select jsonb_array_length(skill_admission_facts_json) from target limit 1),0),
  'enabledInstallationCount',(select count(*) from installations where state='enabled' and install_mode in ('system_managed','user_managed')),
  'publicSkillProfileIds',coalesce((select jsonb_agg(skill->>'publicSkillProfileId' order by skill->>'publicSkillProfileId') from expanded),'[]'::jsonb)
)::text;
""".format(
            run=run,
            workspace=workspace,
            default_skill=default_skill,
            optional_skill=optional_skill,
        )
    )


def terminal_binding_evidence(run_id):
    return database_json(
        """
select jsonb_build_object(
  'bindingCount',count(*),
  'terminalStatus',coalesce(max(terminal_status),''),
  'assistantMessagePresent',coalesce(bool_and(length(trim(assistant_message_id))>0),false),
  'persistedAndReadBack',coalesce(bool_and(persisted_at is not null and read_back_at is not null),false)
)::text
from agent_run_terminal_assistant_bindings
where agent_run_id={run};
""".format(run=sql_literal(run_id))
    )


def run_smoke(timeout_seconds, preferred_agent_id, include_optional):
    assertions = []
    suffix = secrets.token_hex(16)
    code = "640827"
    phone = smoke_phone()
    phone_pattern = "%s %s %s" % (phone[:3], phone[3:7], phone[7:])
    rule_id = "sms_bypass_agent_skill_" + suffix
    operator_id = "agent_skill_smoke_operator_" + suffix
    login = "agent_skill_smoke_" + suffix
    password = secrets.token_hex(32)
    password_hash = "sha256:" + hashlib.sha256(
        ("admin-password:" + password).encode("utf-8")
    ).hexdigest()
    verifier = hashlib.sha256(
        ("sms-bypass:%s:%s" % (rule_id, code)).encode("utf-8")
    ).hexdigest()
    result = {}
    try:
        request("GET", API_BASE + "/healthz")
        request("GET", ADMIN_BASE + "/healthz")
        assertions.append("api_admin_health")
        database(
            """
insert into admin_operators(operator_id,login,password_hash,roles,status)
values ({operator},{login},{password_hash},'["admin","ops_admin","ops_operator","ops_viewer"]'::jsonb,'active');
insert into sms_bypass_rules(rule_id,rule_alias,scene,environment,scope_type,scope_values,code_hash,code_summary,skip_sms_send,status,expires_at,created_by)
values ({rule},'Agent Skill selection smoke','login','prelaunch','phone_pattern_list',{patterns}::jsonb,{verifier},'len=6',true,'active',now()+interval '1 hour',{operator});
""".format(
                operator=sql_literal(operator_id),
                login=sql_literal(login),
                password_hash=sql_literal(password_hash),
                rule=sql_literal(rule_id),
                patterns=sql_literal(json.dumps([phone_pattern])),
                verifier=sql_literal(verifier),
            )
        )
        sms = payload(
            request(
                "POST",
                API_BASE + "/api/v1/auth/sms-code",
                body={"phone": phone, "scene": "login"},
                headers={"X-Idempotency-Key": new_key("sms")},
            )
        )
        sms_request_id = str(sms.get("smsRequestId", ""))
        assert_value(bool(sms_request_id), "SMS_REQUEST_ID_MISSING")
        login_response = payload(
            request(
                "POST",
                API_BASE + "/api/v1/auth/login",
                body={
                    "phone": phone,
                    "smsCode": code,
                    "smsRequestId": sms_request_id,
                    "deviceId": new_key("device"),
                    "agreementAccepted": True,
                    "agreementVersion": "v0.1",
                    "privacyVersion": "v0.1",
                    "clientVersion": "agent-skill-selection-smoke",
                    "timeZone": "Asia/Shanghai",
                },
            )
        )
        access_token = str(login_response.get("accessToken", ""))
        workspace_id = str(login_response.get("workspaceId", ""))
        assert_value(bool(access_token) and bool(workspace_id), "LOGIN_SCOPE_INVALID")
        auth_headers = {"Authorization": "Bearer " + access_token}
        assertions.append("isolated_user_authenticated")

        agents = payload(
            request("GET", API_BASE + "/api/v1/agent-profiles", headers=auth_headers)
        ).get("items", [])
        assert_value(bool(agents), "AGENT_CATALOG_EMPTY")
        selected = None
        fallback = None
        catalog_profiles = []
        for agent in agents:
            agent_id = str(agent.get("agentProfileId", ""))
            if not agent_id:
                continue
            skills = payload(
                request(
                    "GET",
                    API_BASE
                    + "/api/v1/agent-profiles/"
                    + urllib.parse.quote(agent_id, safe="")
                    + "/skills",
                    headers=auth_headers,
                )
            ).get("items", [])
            assert_value(
                all(item.get("selectionRole") in ("default", "optional") for item in skills),
                "SELECTION_ROLE_INVALID",
            )
            defaults = [item for item in skills if item.get("selectionRole") == "default"]
            optionals = [item for item in skills if item.get("selectionRole") == "optional"]
            catalog_profiles.append(
                {
                    "agentProfileId": agent_id,
                    "defaultCount": len(defaults),
                    "optionalCount": len(optionals),
                }
            )
            if defaults:
                candidate = (agent_id, defaults[0], optionals[0] if optionals else None)
                if fallback is None or agent_id == "self_media_creation":
                    fallback = candidate
                if agent_id == preferred_agent_id:
                    selected = candidate
                elif not preferred_agent_id and optionals and (
                    selected is None or agent_id == "self_media_creation"
                ):
                    selected = candidate
        if selected is None:
            selected = fallback
        assert_value(selected is not None, "DEFAULT_SKILL_MISSING")
        agent_id, default_skill, optional_skill = selected
        default_skill_id = str(default_skill.get("skillProfileId", ""))
        optional_skill_id = (
            str(optional_skill.get("skillProfileId", ""))
            if include_optional and optional_skill
            else ""
        )
        assert_value(bool(default_skill_id), "DEFAULT_SKILL_ID_MISSING")
        if include_optional:
            assert_value(bool(optional_skill_id), "OPTIONAL_SKILL_MISSING")
        assertions.append("catalog_selection_roles_valid")

        selected_skill_ids = [default_skill_id, default_skill_id]
        if optional_skill_id:
            selected_skill_ids.append(optional_skill_id)
        result = {
            "agentProfileId": agent_id,
            "defaultSkillProfileId": default_skill_id,
            "optionalSkillProfileId": optional_skill_id or None,
            "optionalSelectionExercised": bool(optional_skill_id),
            "catalogProfiles": catalog_profiles,
        }
        created = payload(
            request(
                "POST",
                API_BASE + "/api/v1/agent/runs",
                expected=(202,),
                headers={
                    "Authorization": "Bearer " + access_token,
                    "X-Idempotency-Key": new_key("run"),
                },
                body={
                    "workspaceId": workspace_id,
                    "agentProfileId": agent_id,
                    "skillProfileIds": selected_skill_ids,
                    "input": {
                        "content": [
                            {"type": "text", "text": "Please reply briefly to confirm."}
                        ]
                    },
                    "clientContext": {
                        "locale": "zh-CN",
                        "timezone": "Asia/Shanghai",
                    },
                },
            )
        )
        run_id = str(created.get("run", {}).get("agentRunId", ""))
        assert_value(bool(run_id), "AGENT_RUN_ID_MISSING")
        assertions.append("run_accepted_with_duplicate_default_selection")

        snapshot = snapshot_evidence(
            run_id, workspace_id, default_skill_id, optional_skill_id
        )
        final_count = int(snapshot.get("finalSkillCount", 0))
        assert_value(int(snapshot.get("snapshotCount", 0)) == 1, "SNAPSHOT_COUNT_INVALID")
        assert_value(final_count > 0, "SNAPSHOT_FINAL_SKILLS_EMPTY")
        assert_value(
            final_count == int(snapshot.get("distinctPublicSkillCount", 0)),
            "SNAPSHOT_SKILL_DUPLICATED",
        )
        assert_value(
            int(snapshot.get("defaultOccurrences", 0)) == 1,
            "DEFAULT_SKILL_FREEZE_INVALID",
        )
        if optional_skill_id:
            assert_value(
                int(snapshot.get("optionalOccurrences", 0)) == 1,
                "OPTIONAL_SKILL_FREEZE_INVALID",
            )
        assert_value(
            int(snapshot.get("admissionFactCount", 0)) == final_count,
            "SKILL_ADMISSION_FACTS_INVALID",
        )
        assert_value(
            int(snapshot.get("enabledInstallationCount", 0)) == final_count,
            "SKILL_INSTALLATION_ADMISSION_INVALID",
        )
        assertions.append("selected_skills_admitted_and_frozen_once")

        terminal = wait_for_run(auth_headers, run_id, timeout_seconds)
        terminal_status = str(terminal.get("status", ""))
        binding = terminal_binding_evidence(run_id)
        assert_value(int(binding.get("bindingCount", 0)) == 1, "TERMINAL_BINDING_MISSING")
        assert_value(
            binding.get("terminalStatus") == terminal_status,
            "TERMINAL_BINDING_STATUS_MISMATCH",
        )
        assert_value(
            binding.get("assistantMessagePresent") is True
            and binding.get("persistedAndReadBack") is True,
            "TERMINAL_ASSISTANT_NOT_PERSISTED",
        )
        assertions.append("terminal_assistant_persisted_and_read_back")
        result.update(
            {
                "agentRunId": run_id,
                "snapshotEvidence": snapshot,
                "terminalStatus": terminal_status,
                "terminalErrorCode": str((terminal.get("error") or {}).get("code", "")),
                "terminalBindingEvidence": binding,
            }
        )
        if terminal_status != "succeeded":
            raise SmokeError("AGENT_RUN_TERMINAL_" + terminal_status.upper())
        return assertions, result
    except SmokeError as exc:
        exc.evidence = result
        raise
    finally:
        try:
            database(
                """
update sms_bypass_rules
set status='deleted',deleted_by={operator},deleted_reason='Agent Skill smoke cleanup',deleted_at=now(),updated_at=now()
where rule_id={rule} and status<>'deleted';
delete from admin_sessions where operator_id={operator};
delete from admin_operators where operator_id={operator};
""".format(
                    operator=sql_literal(operator_id), rule=sql_literal(rule_id)
                )
            )
        except Exception:
            pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout-seconds", type=int, default=600)
    parser.add_argument("--agent-profile-id", default="self_media_creation")
    parser.add_argument("--include-optional", action="store_true")
    parser.add_argument("--report", required=True)
    args = parser.parse_args()
    report = {
        "schemaVersion": REPORT_SCHEMA,
        "mode": "run",
        "executionPerformed": True,
        "executedOn": "39.107.250.25-loopback",
    }
    try:
        assertions, evidence = run_smoke(
            args.timeout_seconds, args.agent_profile_id, args.include_optional
        )
        report["assertions"] = [
            {"name": name, "passed": True} for name in assertions
        ]
        report["evidence"] = evidence
        report["result"] = "passed"
    except SmokeError as exc:
        report["result"] = "failed"
        report["errorCode"] = str(exc)
        if getattr(exc, "evidence", None):
            report["evidence"] = exc.evidence
    except Exception as exc:
        report["result"] = "failed"
        report["errorCode"] = "UNEXPECTED:" + type(exc).__name__
    with open(args.report, "w", encoding="utf-8") as handle:
        json.dump(report, handle, separators=(",", ":"))
        handle.write("\n")
    print(json.dumps(report, separators=(",", ":")))
    return 0 if report["result"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
