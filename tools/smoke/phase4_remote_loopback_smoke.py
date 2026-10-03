#!/usr/bin/env python3
"""Focused Tencent voiceprint and file-ASR smoke executed on host 39 only."""

import argparse
import hashlib
import json
import os
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone


API_BASE = "http://127.0.0.1:18080"
ADMIN_BASE = "http://127.0.0.1:18081"
DB_ENV = "/home/huahuo-runtime/config/database.env"
REPORT_SCHEMA = "huahuo.phase4.tencent-speech-smoke-report.v1"


class SmokeError(RuntimeError):
    pass


def payload(value):
    if isinstance(value, dict) and "data" in value:
        return value["data"]
    return value



def api_error_code(value):
    if not isinstance(value, dict):
        return ""
    error = value.get("error")
    if isinstance(error, dict):
        return str(error.get("code", ""))
    return ""


def request(method, url, *, body=None, raw_body=None, headers=None, expected=(200,)):
    actual_headers = dict(headers or {})
    data = raw_body
    if body is not None:
        data = json.dumps(body, separators=(",", ":")).encode("utf-8")
        actual_headers.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(url, data=data, headers=actual_headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=90) as response:
            status = response.status
            raw = response.read()
            response_headers = dict(response.headers.items())
    except urllib.error.HTTPError as exc:
        status = exc.code
        raw = exc.read()
        response_headers = dict(exc.headers.items()) if exc.headers else {}
    except Exception as exc:
        raise SmokeError("HTTP_TRANSPORT_FAILED:" + type(exc).__name__) from exc
    try:
        decoded = json.loads(raw.decode("utf-8")) if raw else None
    except (UnicodeDecodeError, json.JSONDecodeError):
        decoded = None
    if status not in expected:
        raise SmokeError("HTTP_FAILED:%s:%s:%s" % (method, urllib.parse.urlparse(url).path, status))
    if decoded is None and method != "PUT":
        raise SmokeError("HTTP_JSON_MISSING:%s:%s" % (method, urllib.parse.urlparse(url).path))
    return decoded, response_headers


def database(sql):
    command = (
        "set -a; . " + DB_ENV + "; set +a; "
        'PGPASSWORD="$HUAHUO_DB_PASSWORD" psql -X -v ON_ERROR_STOP=1 -q '
        '-h "$HUAHUO_DB_HOST" -p "$HUAHUO_DB_PORT" -U "$HUAHUO_DB_USER" '
        '-d "$HUAHUO_DB_NAME"'
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


def assert_value(condition, code):
    if not condition:
        raise SmokeError(code)


def new_key(name):
    return "phase4-loopback-%s-%s" % (name, secrets.token_hex(16))


def wait_for(probe, done, timeout_seconds, code):
    deadline = time.monotonic() + timeout_seconds
    last_value = None
    while time.monotonic() < deadline:
        last_value = probe()
        if done(last_value):
            return last_value
        time.sleep(10)
    raise SmokeError(code)


def run_smoke(voiceprint_path, recording_path, timeout_seconds):
    assertions = []
    suffix = secrets.token_hex(16)
    code = "640827"
    primary_phone = "198" + secrets.token_hex(4).translate(str.maketrans("abcdef", "123456"))[:8]
    fresh_phone = "199" + secrets.token_hex(4).translate(str.maketrans("abcdef", "654321"))[:8]
    # Hex digits are normalized above, so the test phones are numeric and unique enough for smoke isolation.
    primary_pattern = "%s %s %s" % (primary_phone[:3], primary_phone[3:7], primary_phone[7:])
    fresh_pattern = "%s %s %s" % (fresh_phone[:3], fresh_phone[3:7], fresh_phone[7:])
    rule_id = "sms_bypass_phase4_" + suffix
    operator_id = "phase4_loopback_operator_" + suffix
    login = "phase4_loopback_" + suffix
    password = secrets.token_hex(32)
    password_hash = "sha256:" + hashlib.sha256(("admin-password:" + password).encode("utf-8")).hexdigest()
    verifier = hashlib.sha256(("sms-bypass:%s:%s" % (rule_id, code)).encode("utf-8")).hexdigest()
    profile_id = ""
    user_auth = ""
    try:
        request("GET", API_BASE + "/healthz")
        request("GET", ADMIN_BASE + "/healthz")
        database(
            """
insert into admin_operators(operator_id, login, password_hash, roles, status)
values ('{operator}', '{login}', '{password_hash}', '["admin","ops_admin","ops_operator","ops_viewer","membership_operator"]'::jsonb, 'active');
insert into sms_bypass_rules(rule_id, rule_alias, scene, environment, scope_type, scope_values, code_hash, code_summary, skip_sms_send, status, expires_at, created_by)
values ('{rule}', 'phase4 loopback Tencent speech smoke', 'login', 'prelaunch', 'phone_pattern_list', '{patterns}'::jsonb, '{verifier}', 'len=6', true, 'active', now() + interval '1 hour', '{operator}');
""".format(
                operator=operator_id,
                login=login,
                password_hash=password_hash,
                rule=rule_id,
                patterns=json.dumps([primary_pattern, fresh_pattern]),
                verifier=verifier,
            )
        )
        admin_login, _ = request(
            "POST", ADMIN_BASE + "/admin/api/v1/auth/login", body={"login": login, "password": password}
        )
        admin_token = payload(admin_login).get("adminAccessToken", "")
        assert_value(bool(admin_token), "ADMIN_LOGIN_TOKEN_MISSING")
        admin_auth = {"Authorization": "Bearer " + admin_token}

        def sms_request(phone):
            response, _ = request(
                "POST",
                API_BASE + "/api/v1/auth/sms-code",
                body={"phone": phone, "scene": "login"},
                headers={"X-Idempotency-Key": new_key("sms")},
            )
            sms_id = payload(response).get("smsRequestId", "")
            assert_value(bool(sms_id), "SMS_REQUEST_ID_MISSING")
            return sms_id

        def login_user(phone, sms_id, device_label):
            response, _ = request(
                "POST",
                API_BASE + "/api/v1/auth/login",
                body={
                    "phone": phone,
                    "smsCode": code,
                    "smsRequestId": sms_id,
                    "deviceId": new_key(device_label),
                    "agreementAccepted": True,
                    "agreementVersion": "v0.1",
                    "privacyVersion": "v0.1",
                    "clientVersion": "phase4-loopback-smoke",
                    "timeZone": "Asia/Shanghai",
                },
            )
            return payload(response)

        primary_login = login_user(primary_phone, sms_request(primary_phone), "primary")
        user_auth = "Bearer " + str(primary_login.get("accessToken", ""))
        assert_value(user_auth != "Bearer ", "PRIMARY_LOGIN_TOKEN_MISSING")
        request("GET", API_BASE + "/api/v1/me/status", headers={"Authorization": user_auth})
        assertions.append("ordinary_account_authorized")

        first = login_user(fresh_phone, sms_request(fresh_phone), "fresh-first")
        assert_value(first.get("firstLogin") is True and bool(first.get("accessToken")), "FIRST_LOGIN_NEW_USER_INVALID")
        assertions.append("first_login_is_new_user")
        second = login_user(fresh_phone, sms_request(fresh_phone), "fresh-second")
        assert_value(second.get("firstLogin") is False and bool(second.get("accessToken")), "SECOND_LOGIN_NEW_USER_INVALID")
        assertions.append("second_login_not_new_user")

        user_auth = "Bearer " + str(second["accessToken"])
        user_id = str(second.get("userId", ""))
        workspace_id = str(second.get("workspaceId", ""))
        assert_value(bool(user_id) and bool(workspace_id), "LOGIN_SCOPE_INVALID")
        voiceprint_size = os.path.getsize(voiceprint_path)
        assert_value(0 < voiceprint_size <= 2 * 1024 * 1024, "VOICEPRINT_FIXTURE_INVALID")
        with open(voiceprint_path, "rb") as handle:
            voice_bytes = handle.read()
        speaker_display = "Phase4 Smoke Speaker"
        enroll, _ = request(
            "POST",
            API_BASE + "/voice-gateway/v1/voiceprints",
            raw_body=voice_bytes,
            expected=(200, 201),
            headers={
                "Authorization": user_auth,
                "X-Idempotency-Key": new_key("voiceprint-enroll"),
                "X-Speaker-Display-Name": urllib.parse.quote(speaker_display, safe=""),
                "X-Speaker-Nick": "phase4_smoke_speaker",
                "X-Consent-Version": "phase4-smoke-consent-v1",
                "Content-Type": "audio/wav",
            },
        )
        profile = payload(enroll).get("profile", {})
        profile_id = str(profile.get("profileId", ""))
        assert_value(bool(profile_id) and profile.get("status") == "active", "VOICEPRINT_ENROLL_INVALID")
        assertions.append("voiceprint_enrolled")
        listed, _ = request("GET", API_BASE + "/voice-gateway/v1/voiceprints", headers={"Authorization": user_auth})
        profiles = payload(listed).get("profiles", [])
        assert_value(any(item.get("profileId") == profile_id for item in profiles), "VOICEPRINT_LIST_INVALID")
        assertions.append("voiceprint_listed")

        recording_size = os.path.getsize(recording_path)
        recording_hash = hashlib.sha256(open(recording_path, "rb").read()).hexdigest()
        upload_token, _ = request(
            "POST",
            API_BASE + "/api/v1/media/upload-token",
            body={
                "sourceScene": "raw_material",
                "workspaceId": workspace_id,
                "fileName": "phase4-recording.m4a",
                "mimeType": "audio/x-m4a",
                "sizeBytes": recording_size,
                "durationSeconds": 695,
                "sha256": recording_hash,
            },
            headers={"Authorization": user_auth, "X-Idempotency-Key": new_key("recording-token")},
        )
        upload = payload(upload_token)
        upload_id = str(upload.get("uploadId", ""))
        resource_id = str(upload.get("resourceId", ""))
        upload_url = str(upload.get("uploadUrl", ""))
        assert_value(bool(upload_id) and bool(resource_id) and bool(upload_url), "UPLOAD_TOKEN_INVALID")
        with open(recording_path, "rb") as handle:
            recording_bytes = handle.read()
        request("PUT", upload_url, raw_body=recording_bytes, expected=(200, 201, 204), headers=upload.get("headers", {}))
        complete, _ = request(
            "POST",
            API_BASE + "/api/v1/media/uploads/%s/complete" % urllib.parse.quote(upload_id, safe=""),
            body={"workspaceId": workspace_id},
            headers={"Authorization": user_auth, "X-Idempotency-Key": new_key("recording-complete")},
        )
        completed_resource = payload(complete).get("resource", {}).get("resourceId", "")
        assert_value(completed_resource == resource_id, "UPLOAD_RESOURCE_INVALID")
        created, _ = request(
            "POST",
            API_BASE + "/api/v1/recordings",
            body={"audioResourceId": resource_id, "title": "phase4 Tencent speech smoke", "source": "local_upload"},
            headers={"Authorization": user_auth, "X-Idempotency-Key": new_key("recording-create")},
        )
        recording = payload(created)
        recording_id = str(recording.get("recording", {}).get("recordingId", ""))
        asr_id = str(recording.get("asrTask", {}).get("asrTaskId", ""))
        assert_value(bool(recording_id) and bool(asr_id), "RECORDING_CREATE_INVALID")

        def read_asr():
            value, _ = request("GET", API_BASE + "/api/v1/asr-tasks/%s" % urllib.parse.quote(asr_id, safe=""), headers={"Authorization": user_auth})
            return payload(value)

        asr = wait_for(read_asr, lambda value: value.get("asrTask", {}).get("status") in ("speaker_confirmed", "failed"), timeout_seconds, "ASR_TIMEOUT")
        assert_value(asr.get("asrTask", {}).get("status") == "speaker_confirmed", "VOICEPRINT_AUTO_CONFIRM_INVALID")
        assertions.append("tencent_file_asr_transcribed")

        def read_recording():
            value, _ = request("GET", API_BASE + "/api/v1/recordings/%s" % urllib.parse.quote(recording_id, safe=""), headers={"Authorization": user_auth})
            return payload(value)

        detail = wait_for(
            read_recording,
            lambda value: bool(value.get("recording", {}).get("noteId"))
            and bool(value.get("transcript", {}).get("finalTranscript"))
            and bool(value.get("generatedAssets", {}).get("summary"))
            and value.get("generatedAssets", {}).get("minutes") is not None,
            timeout_seconds,
            "DEPOSIT_TIMEOUT",
        )
        transcript = detail.get("transcript", {})
        self_speaker = str(transcript.get("selfSpeakerId", ""))
        names = transcript.get("speakerNameMap", {})
        matches = transcript.get("speakerIdentityMatches", [])
        segments = transcript.get("speakerSegments", [])
        assert_value(
            len(segments) >= 2
            and bool(self_speaker)
            and names.get(self_speaker) == speaker_display
            and speaker_display in str(transcript.get("finalTranscript", ""))
            and any(item.get("speakerId") == self_speaker for item in matches),
            "VOICEPRINT_IDENTITY_INVALID",
        )
        assertions.append("voiceprint_identity_projected")
        note_id = str(detail.get("recording", {}).get("noteId", ""))
        raw, _ = request(
            "GET",
            API_BASE + "/api/v1/workspaces/%s/notes/%s/parts/raw" % (urllib.parse.quote(workspace_id, safe=""), urllib.parse.quote(note_id, safe="")),
            headers={"Authorization": user_auth},
        )
        outline, _ = request(
            "GET",
            API_BASE + "/api/v1/workspaces/%s/notes/%s/parts/outline" % (urllib.parse.quote(workspace_id, safe=""), urllib.parse.quote(note_id, safe="")),
            headers={"Authorization": user_auth},
        )
        raw_markdown = str(payload(raw).get("contentMarkdown", ""))
        outline_markdown = str(payload(outline).get("contentMarkdown", ""))
        assert_value(speaker_display in raw_markdown and "## Summary" in outline_markdown and "## Minutes" in outline_markdown, "HNOTE_CONTENT_INVALID")
        assertions.append("hnote_raw_and_outline_content_present")
        usage, _ = request(
            "GET",
            ADMIN_BASE + "/admin/api/v1/usage-records?userId=%s&asrTaskId=%s"
            % (urllib.parse.quote(user_id, safe=""), urllib.parse.quote(asr_id, safe="")),
            headers=admin_auth,
        )
        usage_items = payload(usage).get("items", [])
        assert_value(any(item.get("meterType") == "asr_seconds" for item in usage_items), "ASR_USAGE_MISSING")
        assertions.append("file_asr_usage_recorded")
        request(
            "DELETE",
            API_BASE + "/voice-gateway/v1/voiceprints/%s" % urllib.parse.quote(profile_id, safe=""),
            headers={"Authorization": user_auth, "X-Idempotency-Key": new_key("voiceprint-delete")},
        )
        deleted_profile_id = profile_id
        listed_after, _ = request("GET", API_BASE + "/voice-gateway/v1/voiceprints", headers={"Authorization": user_auth})
        assert_value(not any(item.get("profileId") == deleted_profile_id for item in payload(listed_after).get("profiles", [])), "VOICEPRINT_DELETE_INVALID")
        profile_id = ""
        assertions.append("voiceprint_deleted")
        return assertions
    finally:
        if profile_id and user_auth:
            try:
                request(
                    "DELETE",
                    API_BASE + "/voice-gateway/v1/voiceprints/%s" % urllib.parse.quote(profile_id, safe=""),
                    headers={"Authorization": user_auth, "X-Idempotency-Key": new_key("voiceprint-finally-delete")},
                )
            except Exception:
                pass
        try:
            database(
                """
update sms_bypass_rules set status = 'deleted', deleted_by = '{operator}', deleted_reason = 'phase4 loopback smoke cleanup', deleted_at = now(), updated_at = now()
where rule_id = '{rule}' and status <> 'deleted';
delete from admin_sessions where operator_id = '{operator}';
delete from admin_operators where operator_id = '{operator}';
""".format(operator=operator_id, rule=rule_id)
            )
        except Exception:
            pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--voiceprint", required=True)
    parser.add_argument("--recording", required=True)
    parser.add_argument("--timeout-seconds", type=int, default=900)
    parser.add_argument("--report", required=True)
    args = parser.parse_args()
    report = {
        "schemaVersion": REPORT_SCHEMA,
        "mode": "run",
        "executionPerformed": True,
        "executedOn": "39.107.250.25-loopback",
    }
    try:
        report["assertions"] = [{"name": name, "passed": True} for name in run_smoke(args.voiceprint, args.recording, args.timeout_seconds)]
        report["result"] = "passed"
    except SmokeError as exc:
        report["result"] = "failed"
        report["errorCode"] = str(exc)
    with open(args.report, "w", encoding="utf-8") as handle:
        json.dump(report, handle, separators=(",", ":"))
        handle.write("\n")
    print(json.dumps(report, separators=(",", ":")))
    return 0 if report["result"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
