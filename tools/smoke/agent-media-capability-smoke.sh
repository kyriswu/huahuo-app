#!/usr/bin/env bash
set -euo pipefail
umask 077

: "${PHONE:?PHONE is required}"
: "${CODE:?CODE is required}"
: "${SCENE:?SCENE is required}"
: "${PROFILE:?PROFILE is required}"
: "${PROMPT:?PROMPT is required}"
: "${SMS_REQUEST_ID:=}"
: "${TIME_ZONE:=Asia/Shanghai}"

base="${BASE:-https://chuda.cc}"
run_key="media-capability-${SCENE}-$(date +%s)-$$"

request() {
  local method="$1" path="$2" body="${3:-}" idem="${4:-}" raw
  local -a args=(--silent --show-error --connect-timeout 10 --max-time 180 --request "$method")
  [ -n "$idem" ] && args+=(--header "X-Idempotency-Key: $idem")
  [ -n "${access:-}" ] && args+=(--header "Authorization: Bearer $access")
  [ -n "$body" ] && args+=(--header "Content-Type: application/json" --data-binary "$body")
  raw="$(curl "${args[@]}" --write-out $'\n%{http_code}' "$base$path")"
  http_code="${raw##*$'\n'}"
  http_body="${raw%$'\n'*}"
}

fail() {
  jq -nc --arg stage "$1" --arg http "${2:-}" --arg detail "${3:-}" \
    '{ok:false,stage:$stage,http:$http,detail:$detail}'
  exit 1
}

login_body="$(jq -nc --arg phone "$PHONE" --arg code "$CODE" --arg request "$SMS_REQUEST_ID" --arg device "$run_key" --arg timeZone "$TIME_ZONE" '{phone:$phone,code:$code,smsRequestId:$request,deviceId:$device,agreementAccepted:true,agreementVersion:"v0.1",privacyVersion:"v0.1",clientVersion:"media-capability-smoke",timeZone:$timeZone}')"
request POST "/api/v1/auth/login" "$login_body" "$run_key-login"
[ "$http_code" = "200" ] || fail login "$http_code"
access="$(printf '%s' "$http_body" | jq -er '.data.accessToken')"

thread_body="$(jq -nc --arg scene "$SCENE" '{scene:$scene}')"
request POST "/api/v1/chat/threads" "$thread_body" "$run_key-thread"
[ "$http_code" = "200" ] || fail thread "$http_code"
thread_id="$(printf '%s' "$http_body" | jq -er '.data.thread.threadId // .data.threadId')"

message_body="$(jq -nc --arg profile "$PROFILE" --arg text "$PROMPT" '{agentProfileId:$profile,input:{content:[{type:"text",text:$text}]}}')"
request POST "/api/v1/chat/threads/$thread_id/messages" "$message_body" "$run_key-message"
[ "$http_code" = "200" ] || fail submit "$http_code"
run_id="$(printf '%s' "$http_body" | jq -er '.data.agentRunId')"

status=""
for _ in $(seq 1 240); do
  request GET "/api/v1/agent/runs/$run_id"
  [ "$http_code" = "200" ] || fail poll "$http_code"
  status="$(printf '%s' "$http_body" | jq -r '.data.status // ""')"
  case "$status" in
    succeeded|failed|timeout|cancelled|orphaned) break ;;
  esac
  sleep 2
done

request GET "/api/v1/chat/threads/$thread_id"
[ "$http_code" = "200" ] || fail readback "$http_code"
thread_json="$http_body"
task_status="$(printf '%s' "$thread_json" | jq -r --arg run "$run_id" '[.data.tasks[]? | select(.agentRunId==$run or .runId==$run)] | .[0].status // ""')"
assistant="$(printf '%s' "$thread_json" | jq -c '[.data.messages[]? | select(.role=="assistant")][-1] // {}')"
reply="$(printf '%s' "$assistant" | jq -r '(.content // .payload.reply // .payload.content // .payload.text // "") | if type=="string" then . else tostring end')"
evidence="$(printf '%s' "$assistant" | jq -c '[.. | objects | select((.type? == "image") or (.mimeType? | type == "string" and startswith("image/")) or (.contentType? | type == "string" and startswith("image/")) or has("imageUrl") or has("resourceId") or has("url"))]')"

jq -nc \
  --arg threadId "$thread_id" \
  --arg runId "$run_id" \
  --arg runStatus "$status" \
  --arg taskStatus "$task_status" \
  --arg reply "$reply" \
  --argjson evidence "$evidence" \
  '{ok:($runStatus=="succeeded" and $taskStatus=="succeeded" and ($reply|length)>0),threadId:$threadId,runId:$runId,runStatus:$runStatus,taskStatus:$taskStatus,reply:$reply,evidence:$evidence}'

unset access http_body login_body message_body PHONE CODE SMS_REQUEST_ID TIME_ZONE
