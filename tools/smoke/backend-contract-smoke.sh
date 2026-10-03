#!/usr/bin/env bash
set -euo pipefail
umask 077

api_base="${API_BASE:-http://127.0.0.1:18080}"
admin_base="${ADMIN_BASE:-http://127.0.0.1:18081}"
task_tag="backend-contract-smoke-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
stage="input"
token=""
admin_token=""
operator_id=""
operator_login=""
bypass_rule_id=""
bypass_revision=""
original_refresh_token=""
original_refresh_token_id=""
rotated_refresh_token=""
rotated_refresh_token_id=""
workspace_id=""
user_id=""
publication_id=""
publication_was_followed="false"
root_folder_id=""
nested_folder_id=""
note_id=""
note_etag=""
HTTP_BODY=""
HTTP_CODE=""

IFS= read -r phone
IFS= read -r code
phone="${phone%$'\r'}"
code="${code%$'\r'}"
[[ "$phone" =~ ^[0-9]{11}$ ]] || { printf '{"passed":false,"stage":"input","errorCode":"PHONE_INVALID"}\n'; exit 2; }
[[ "$code" =~ ^[0-9]{6}$ ]] || { printf '{"passed":false,"stage":"input","errorCode":"CODE_INVALID"}\n'; exit 2; }

stage="database_config"
set -a
# shellcheck disable=SC1091
. /home/huahuo-runtime/config/database.env
set +a
export PGHOST="${HUAHUO_DB_HOST:?}" PGPORT="${HUAHUO_DB_PORT:-5432}"
export PGDATABASE="${HUAHUO_DB_NAME:?}" PGUSER="${HUAHUO_DB_USER:?}"
export PGPASSWORD="${HUAHUO_DB_PASSWORD:?}" PGSSLMODE="${HUAHUO_DB_SSL_MODE:-prefer}"

tmp_dir="$(mktemp -d /var/lib/huahuo-release-staging/public-catalog-delta-20260815/.backend-smoke.XXXXXX)"
header_file="$tmp_dir/headers"
body_file="$tmp_dir/body"
auth_header_file="$tmp_dir/app-auth"
admin_auth_header_file="$tmp_dir/admin-auth"

set_auth_header() {
  if [ -n "$token" ]; then
    printf 'Authorization: Bearer %s\n' "$token" >"$auth_header_file"
  else
    : >"$auth_header_file"
  fi
}

set_admin_auth_header() {
  if [ -n "$admin_token" ]; then
    printf 'Authorization: Bearer %s\n' "$admin_token" >"$admin_auth_header_file"
  else
    : >"$admin_auth_header_file"
  fi
}

request() {
  local method="$1" path="$2" body="${3:-}" idem="${4:-}" if_match="${5:-}" if_none_match="${6:-}"
  local -a args=(--silent --show-error --connect-timeout 10 --max-time 90 --request "$method"
    --dump-header "$header_file" --output "$body_file" --write-out '%{http_code}')
  : >"$header_file"
  : >"$body_file"
  set_auth_header
  [ -n "$token" ] && args+=(--header @"$auth_header_file")
  [ -n "$idem" ] && args+=(--header "X-Idempotency-Key: $idem")
  [ -n "$if_match" ] && args+=(--header "If-Match: $if_match")
  [ -n "$if_none_match" ] && args+=(--header "If-None-Match: $if_none_match")
  [ -n "$body" ] && args+=(--header 'Content-Type: application/json' --data-binary "$body")
  HTTP_CODE="$(curl "${args[@]}" "$api_base$path")"
  HTTP_BODY="$(<"$body_file")"
}

admin_request() {
  local method="$1" path="$2" body="${3:-}" idem="${4:-}" reason="${5:-}"
  local -a args=(--silent --show-error --connect-timeout 10 --max-time 90 --request "$method"
    --dump-header "$header_file" --output "$body_file" --write-out '%{http_code}'
    --header 'Content-Type: application/json')
  : >"$header_file"
  : >"$body_file"
  set_admin_auth_header
  [ -n "$admin_token" ] && args+=(--header @"$admin_auth_header_file")
  [ -n "$idem" ] && args+=(--header "X-Idempotency-Key: $idem")
  [ -n "$reason" ] && args+=(--header "X-Admin-Reason: $reason")
  [ -n "$body" ] && args+=(--data-binary "$body")
  HTTP_CODE="$(curl "${args[@]}" "$admin_base$path")"
  HTTP_BODY="$(<"$body_file")"
}

response_etag() {
  awk 'tolower($1)=="etag:" {sub(/\r$/, "", $2); value=$2} END {print value}' "$header_file"
}

urlencode() {
  jq -rn --arg value "$1" '$value|@uri'
}

cleanup() {
  local status="$?"
  set +e
  if [ -n "$token" ] && [ -n "$workspace_id" ] && [ -n "$note_id" ]; then
    request GET "/api/v1/workspaces/$workspace_id/notes/$note_id"
    note_etag="$(jq -r '.data.etag // empty' <<<"$HTTP_BODY")"
    [ -n "$note_etag" ] && request DELETE "/api/v1/workspaces/$workspace_id/notes/$note_id" '' "$task_tag-note-delete" "$note_etag"
  fi
  if [ -n "$token" ] && [ -n "$workspace_id" ] && [ -n "$nested_folder_id" ]; then
    request GET "/api/v1/workspaces/$workspace_id/folders/$nested_folder_id"
    folder_etag="$(jq -r '.data.etag // empty' <<<"$HTTP_BODY")"
    [ -n "$folder_etag" ] && request DELETE "/api/v1/workspaces/$workspace_id/folders/$nested_folder_id" '' "$task_tag-nested-delete" "$folder_etag"
  fi
  if [ -n "$token" ] && [ -n "$workspace_id" ] && [ -n "$root_folder_id" ]; then
    request GET "/api/v1/workspaces/$workspace_id/folders/$root_folder_id"
    folder_etag="$(jq -r '.data.etag // empty' <<<"$HTTP_BODY")"
    [ -n "$folder_etag" ] && request DELETE "/api/v1/workspaces/$workspace_id/folders/$root_folder_id" '' "$task_tag-root-delete" "$folder_etag"
  fi
  if [ "$publication_was_followed" = false ] && [ -n "$token" ] && [ -n "$workspace_id" ] && [ -n "$publication_id" ]; then
    request DELETE "/api/v1/workspaces/$workspace_id/subscription-library/publications/$publication_id" '' "$task_tag-unfollow"
  fi
  for refresh_id in "$original_refresh_token_id" "$rotated_refresh_token_id"; do
    if [ -n "$refresh_id" ]; then
      psql -X -q -v ON_ERROR_STOP=1 -v token_id="$refresh_id" <<'SQL' >/dev/null || status=72
update refresh_tokens
set status='revoked',revoked_at=coalesce(revoked_at,now()),updated_at=now()
where token_id=:'token_id' and status in ('active','rotated');
SQL
    fi
  done
  if [ -n "$bypass_rule_id" ] && [ -n "$admin_token" ]; then
    admin_request DELETE "/admin/api/v1/auth/sms-bypass-rules/$bypass_rule_id" \
      "$(jq -nc --argjson revision "$bypass_revision" '{expectedRevision:$revision}')" \
      "$task_tag-bypass-delete" 'backend contract smoke cleanup'
    [ "$HTTP_CODE" = 200 ] || status=71
  fi
  if [ -n "$admin_token" ]; then
    admin_request POST '/admin/api/v1/auth/logout' '{}' '' 'backend contract smoke cleanup'
  fi
  if [ -n "$operator_id" ]; then
    psql -X -q -v ON_ERROR_STOP=1 -v operator_id="$operator_id" -v operator_login="$operator_login" <<'SQL' >/dev/null || status=73
begin;
delete from admin_operator_sessions where operator_id=:'operator_id';
delete from admin_operators where operator_id=:'operator_id' and login=:'operator_login';
commit;
SQL
  fi
  case "$tmp_dir" in
    /var/lib/huahuo-release-staging/public-catalog-delta-20260815/.backend-smoke.*) rm -rf -- "$tmp_dir" ;;
  esac
  unset token admin_token original_refresh_token rotated_refresh_token phone code PGPASSWORD HUAHUO_DB_PASSWORD HTTP_BODY operator_password
  exit "$status"
}
trap cleanup EXIT

report_error() {
  local status="$?"
  trap - ERR
  local error_code="ASSERTION_FAILED"
  if [ -n "${HTTP_BODY:-}" ]; then
    error_code="$(jq -r '.error.code // .code // "ASSERTION_FAILED"' <<<"$HTTP_BODY" 2>/dev/null || printf ASSERTION_FAILED)"
  fi
  jq -nc --arg stage "$stage" --arg http "$HTTP_CODE" --argjson exitCode "$status" \
    --arg errorCode "$error_code" --argjson bodyBytes "${#HTTP_BODY}" \
    '{passed:false,stage:$stage,httpStatus:$http,exitCode:$exitCode,errorCode:$errorCode,bodyBytes:$bodyBytes}' >&2
  exit "$status"
}
trap report_error ERR

stage="admin_operator_create"
nonce="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
operator_id="operator_${task_tag}_$nonce"
operator_login="${task_tag}_$nonce"
operator_password="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
password_hash="sha256:$(printf 'admin-password:%s' "$operator_password" | sha256sum | awk '{print $1}')"
psql -X -q -v ON_ERROR_STOP=1 -v operator_id="$operator_id" -v operator_login="$operator_login" -v password_hash="$password_hash" <<'SQL' >/dev/null
insert into admin_operators(operator_id,login,password_hash,roles,status)
values(:'operator_id',:'operator_login',:'password_hash',jsonb_build_array('admin','ops_admin','ops_operator','ops_viewer'),'active');
SQL
unset password_hash

stage="admin_login"
admin_request POST '/admin/api/v1/auth/login' \
  "$(jq -nc --arg login "$operator_login" --arg password "$operator_password" '{login:$login,password:$password}')"
unset operator_password
[ "$HTTP_CODE" = 200 ]
admin_token="$(jq -er 'select(.success==true) | .data.adminAccessToken' <<<"$HTTP_BODY")"

stage="sms_bypass_create"
scope_pattern="$(printf '%s %s %s' "${phone:0:3}" "${phone:3:4}" "${phone:7:4}")"
expires_at="$(date -u -d '+20 minutes' '+%Y-%m-%dT%H:%M:%SZ')"
bypass_body="$(jq -nc --arg code "$code" --arg scope "$scope_pattern" --arg expiry "$expires_at" \
  '{scene:"login",code:$code,scopeType:"phone_pattern_list",scopeValues:[$scope],environment:"prelaunch",expiresAt:$expiry,skipSmsSend:true}')"
admin_request POST '/admin/api/v1/auth/sms-bypass-rules' "$bypass_body" \
  "$task_tag-bypass-create" 'backend contract smoke authentication'
[ "$HTTP_CODE" = 200 ]
bypass_rule_id="$(jq -er '.data.ruleId' <<<"$HTTP_BODY")"
bypass_revision="$(jq -er '.data.revision' <<<"$HTTP_BODY")"
unset bypass_body scope_pattern expires_at

stage="app_login"
login_body="$(jq -nc --arg phone "$phone" --arg code "$code" --arg device "$task_tag" \
  '{phone:$phone,code:$code,smsRequestId:"",deviceId:$device,agreementAccepted:true,agreementVersion:"v0.1",privacyVersion:"v0.1",clientVersion:"backend-contract-smoke",timeZone:"Asia/Shanghai"}')"
request POST '/api/v1/auth/login' "$login_body" "$task_tag-login"
[ "$HTTP_CODE" = 200 ]
token="$(jq -er '.data.accessToken' <<<"$HTTP_BODY")"
original_refresh_token="$(jq -er '.data.refreshToken' <<<"$HTTP_BODY")"
original_refresh_token_id="$(jq -er '.data.refreshTokenId' <<<"$HTTP_BODY")"
workspace_id="$(jq -er '.data.workspace.workspaceId' <<<"$HTTP_BODY")"
user_id="$(jq -er '.data.userId' <<<"$HTTP_BODY")"
[ "$(jq -r '.data.smsBypassRuleId // ""' <<<"$HTTP_BODY")" = "$bypass_rule_id" ]
[ "$(jq -r '.data.workspace.status // ""' <<<"$HTTP_BODY")" = ready ]
unset login_body phone code

stage="catalog_checkpoint"
request GET '/api/v1/subscription/catalog-changes?limit=20'
[ "$HTTP_CODE" = 200 ]
catalog_head="$(jq -er 'select(.data.bootstrapRequired==true and (.data.items|length)==0) | .data.headCursor' <<<"$HTTP_BODY")"
[ -n "$catalog_head" ]
catalog_after="$(urlencode "$catalog_head")"
request GET "/api/v1/subscription/catalog-changes?after=$catalog_after&limit=20"
[ "$HTTP_CODE" = 200 ]
jq -e '.data.bootstrapRequired==false and (.data.items|length)==0 and .data.hasMore==false' <<<"$HTTP_BODY" >/dev/null
catalog_etag="$(response_etag)"
[ -n "$catalog_etag" ]
request GET "/api/v1/subscription/catalog-changes?after=$catalog_after&limit=20" '' '' '' "$catalog_etag"
[ "$HTTP_CODE" = 304 ]
[ -z "$HTTP_BODY" ]

stage="workspace_incremental_sync"
request GET "/api/v1/workspaces/$workspace_id/content-snapshot?limit=100"
[ "$HTTP_CODE" = 200 ]
snapshot_cursor="$(jq -er '.data.atCursor' <<<"$HTTP_BODY")"
snapshot_etag="$(response_etag)"
[ -n "$snapshot_etag" ]
request GET "/api/v1/workspaces/$workspace_id/content-snapshot?limit=100" '' '' '' "$snapshot_etag"
[ "$HTTP_CODE" = 304 ]
[ -z "$HTTP_BODY" ]
request GET "/api/v1/workspaces/$workspace_id/content-changes?after=$(urlencode "$snapshot_cursor")&limit=100"
[ "$HTTP_CODE" = 200 ]
jq -e --arg cursor "$snapshot_cursor" '.data.hasMore==false and (.data.events|length)==0 and .data.nextAfter==$cursor' <<<"$HTTP_BODY" >/dev/null

stage="subscription_publication_select"
request GET '/api/v1/subscription/publications?limit=100'
[ "$HTTP_CODE" = 200 ]
mapfile -t publication_candidates < <(jq -er '.data.items[].publicationId' <<<"$HTTP_BODY")
for publication_candidate in "${publication_candidates[@]}"; do
  request GET "/api/v1/subscription/articles?publicationId=$(urlencode "$publication_candidate")&limit=1"
  [ "$HTTP_CODE" = 200 ]
  if jq -e '(.data.items | length) > 0' <<<"$HTTP_BODY" >/dev/null; then
    publication_id="$publication_candidate"
    break
  fi
done
[ -n "$publication_id" ]
unset publication_candidates publication_candidate
stage="subscription_state_before"
request GET "/api/v1/workspaces/$workspace_id/subscription-library/publications?limit=100"
[ "$HTTP_CODE" = 200 ]
if jq -e --arg publication "$publication_id" '.data.items[]? | select(.publication.publicationId==$publication)' <<<"$HTTP_BODY" >/dev/null; then
  publication_was_followed="true"
fi
subscription_note_count_before="$(psql -X -qAt -v ON_ERROR_STOP=1 -v workspace_id="$workspace_id" -v user_id="$user_id" <<'SQL'
select count(*) from workspace_notes where workspace_id=:'workspace_id' and user_id=:'user_id' and source_kind='subscription_article';
SQL
)"
stage="subscription_follow_request"
request PUT "/api/v1/workspaces/$workspace_id/subscription-library/publications/$publication_id" '' "$task_tag-follow"
[ "$HTTP_CODE" = 200 ]
stage="subscription_follow_response"
jq -e --arg publication "$publication_id" '.data.publicationId==$publication and .data.lifecycle=="following"' <<<"$HTTP_BODY" >/dev/null
stage="subscription_state_after"
request GET "/api/v1/workspaces/$workspace_id/subscription-library/publications?limit=100"
[ "$HTTP_CODE" = 200 ]
jq -e --arg publication "$publication_id" '.data.items[] | select(.publication.publicationId==$publication)' <<<"$HTTP_BODY" >/dev/null
stage="subscription_articles"
request GET "/api/v1/workspaces/$workspace_id/subscription-library/articles?limit=100"
[ "$HTTP_CODE" = 200 ]
jq -e --arg publication "$publication_id" '.data.items[] | select(.publication.publicationId==$publication)' <<<"$HTTP_BODY" >/dev/null
subscription_note_count_after="$(psql -X -qAt -v ON_ERROR_STOP=1 -v workspace_id="$workspace_id" -v user_id="$user_id" <<'SQL'
select count(*) from workspace_notes where workspace_id=:'workspace_id' and user_id=:'user_id' and source_kind='subscription_article';
SQL
)"
stage="subscription_no_note_copy"
[ "$subscription_note_count_after" = "$subscription_note_count_before" ]

stage="folder_create"
request POST "/api/v1/workspaces/$workspace_id/folders" \
  "$(jq -nc --arg name "$task_tag-root" '{displayName:$name,parentFolderId:null}')" "$task_tag-root-create"
[ "$HTTP_CODE" = 200 ]
root_folder_id="$(jq -er '.data.folderId' <<<"$HTTP_BODY")"
request POST "/api/v1/workspaces/$workspace_id/folders" \
  "$(jq -nc --arg name "$task_tag-nested" --arg parent "$root_folder_id" '{displayName:$name,parentFolderId:$parent}')" "$task_tag-nested-create"
[ "$HTTP_CODE" = 200 ]
nested_folder_id="$(jq -er '.data.folderId' <<<"$HTTP_BODY")"

stage="note_create_rename"
request POST "/api/v1/workspaces/$workspace_id/notes" \
  "$(jq -nc --arg title "$task_tag-original" '{title:$title,sourceKind:"manual",parts:{raw:"backend contract smoke"}}')" "$task_tag-note-create"
[ "$HTTP_CODE" = 200 ]
note_id="$(jq -er '.data.noteId' <<<"$HTTP_BODY")"
note_etag="$(jq -er '.data.etag' <<<"$HTTP_BODY")"
request PATCH "/api/v1/workspaces/$workspace_id/notes/$note_id" \
  "$(jq -nc --arg title "$task_tag-renamed" '{title:$title}')" "$task_tag-note-rename" "$note_etag"
[ "$HTTP_CODE" = 200 ]
note_etag="$(jq -er '.data.etag' <<<"$HTTP_BODY")"
jq -e --arg title "$task_tag-renamed" '.data.title==$title' <<<"$HTTP_BODY" >/dev/null

stage="note_batch_move"
move_body="$(jq -nc --arg folder "$nested_folder_id" --arg note "$note_id" --arg etag "$note_etag" \
  '{folderId:$folder,notes:[{noteId:$note,etag:$etag}]}')"
request POST "/api/v1/workspaces/$workspace_id/notes/batch-move" "$move_body" "$task_tag-note-move"
[ "$HTTP_CODE" = 200 ]
note_etag="$(jq -er --arg note "$note_id" '.data.notes[] | select(.noteId==$note) | .etag' <<<"$HTTP_BODY")"
request GET "/api/v1/workspaces/$workspace_id/notes/$note_id"
[ "$HTTP_CODE" = 200 ]
jq -e --arg folder "$nested_folder_id" --arg title "$task_tag-renamed" '.data.folderId==$folder and .data.title==$title' <<<"$HTTP_BODY" >/dev/null
request GET "/api/v1/workspaces/$workspace_id/content-changes?after=$(urlencode "$snapshot_cursor")&limit=100"
[ "$HTTP_CODE" = 200 ]
jq -e --arg note "$note_id" '(.data.events|length)>=3 and ([.data.events[] | select(.objectId==$note)]|length)>=1' <<<"$HTTP_BODY" >/dev/null

stage="refresh_rotation"
request POST '/api/v1/auth/refresh' "$(jq -nc --arg refresh "$original_refresh_token" '{refreshToken:$refresh}')"
[ "$HTTP_CODE" = 200 ]
jq -e '.data.rotated==true and .data.expiresIn==7200' <<<"$HTTP_BODY" >/dev/null
rotated_refresh_token="$(jq -er '.data.refreshToken' <<<"$HTTP_BODY")"
rotated_refresh_token_id="$(jq -er '.data.refreshTokenId' <<<"$HTTP_BODY")"
[ "$rotated_refresh_token_id" != "$original_refresh_token_id" ]
refresh_facts="$(PGOPTIONS='-c default_transaction_read_only=on' psql -X -qAt -v ON_ERROR_STOP=1 \
  -v old_id="$original_refresh_token_id" -v new_id="$rotated_refresh_token_id" <<'SQL'
select jsonb_build_object(
  'oldStatus',(select status from refresh_tokens where token_id=:'old_id'),
  'newStatus',(select status from refresh_tokens where token_id=:'new_id'),
  'newExpiryAtLeast29Days',(select expires_at >= now()+interval '29 days' from refresh_tokens where token_id=:'new_id'),
  'newExpiryAtMost31Days',(select expires_at <= now()+interval '31 days' from refresh_tokens where token_id=:'new_id')
)::text;
SQL
)"
jq -e '.oldStatus=="rotated" and .newStatus=="active" and .newExpiryAtLeast29Days==true and .newExpiryAtMost31Days==true' <<<"$refresh_facts" >/dev/null
request POST '/api/v1/auth/refresh' "$(jq -nc --arg refresh "$original_refresh_token" '{refreshToken:$refresh}')"
[ "$HTTP_CODE" = 401 ]
[ "$(jq -r '.error.code // ""' <<<"$HTTP_BODY")" = UNAUTHORIZED ]

stage="result"
result="$(jq -nc \
  --argjson catalogItems 0 \
  --argjson workspaceDeltaEvents "$(PGOPTIONS='-c default_transaction_read_only=on' psql -X -qAt -v ON_ERROR_STOP=1 -v workspace_id="$workspace_id" -v cursor="$snapshot_cursor" <<'SQL'
select count(*) from workspace_content_changes where workspace_id=:'workspace_id' and sequence>:'cursor'::bigint;
SQL
)" \
  '{schemaVersion:"huahuo.backend_contract_smoke.v1",passed:true,assertions:{catalogCheckpoint:true,catalogNoChange304:true,workspaceSnapshot304:true,workspaceNoChangeDelta:true,subscriptionPersisted:true,subscriptionDidNotCreateNote:true,noteRename:true,rootAndNestedFolderCreate:true,noteBatchMove:true,refreshRotated:true,refreshThirtyDayExpiry:true,rotatedTokenRejected:true},catalogItems:$catalogItems,workspaceDeltaEvents:$workspaceDeltaEvents}')"
printf '%s\n' "$result"
