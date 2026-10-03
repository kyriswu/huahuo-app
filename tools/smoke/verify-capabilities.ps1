Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$hostIp = "39.107.250.25"
$baseUrl = "https://chuda.cc"
$encoding = [Text.UTF8Encoding]::new($false)

function Invoke-Api {
  param(
    [Parameter(Mandatory)][string]$Method,
    [Parameter(Mandatory)][string]$Path,
    [object]$Body = $null,
    [string]$Token = "",
    [string]$IdempotencyKey = ""
  )
  $responsePath = [IO.Path]::GetTempFileName()
  $requestPath = ""
  try {
    $arguments = @(
      "--silent", "--show-error", "--resolve", "chuda.cc:443:$hostIp",
      "--connect-timeout", "10", "--max-time", "60", "--request", $Method,
      "--header", "Content-Type: application/json", "--output", $responsePath,
      "--write-out", "%{http_code}|%{remote_ip}"
    )
    if ($Token) { $arguments += @("--header", "Authorization: Bearer $Token") }
    if ($IdempotencyKey) { $arguments += @("--header", "X-Idempotency-Key: $IdempotencyKey") }
    if ($null -ne $Body) {
      $requestPath = [IO.Path]::GetTempFileName()
      [IO.File]::WriteAllText($requestPath, ($Body | ConvertTo-Json -Depth 20 -Compress), $encoding)
      $arguments += @("--data-binary", "@$requestPath")
    }
    $arguments += "$baseUrl$Path"
    $metadata = (& curl.exe @arguments)
    if ($LASTEXITCODE -ne 0) { throw "transport_failed:$Method`:$Path" }
    $parts = ([string]$metadata).Trim().Split("|")
    if ($parts.Count -ne 2 -or $parts[1] -ne $hostIp) { throw "route_mismatch:$Method`:$Path" }
    $raw = [IO.File]::ReadAllText($responsePath, $encoding)
    $json = if ($raw) { $raw | ConvertFrom-Json } else { $null }
    return [pscustomobject]@{ Status = [int]$parts[0]; Json = $json }
  } finally {
    Remove-Item -LiteralPath $responsePath -Force -ErrorAction SilentlyContinue
    if ($requestPath) { Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue }
  }
}

function Invoke-UploadBytes {
  param(
    [Parameter(Mandatory)][string]$UploadUrl,
    [Parameter(Mandatory)][object]$Headers,
    [Parameter(Mandatory)][byte[]]$Bytes
  )
  $bodyPath = [IO.Path]::GetTempFileName()
  $responsePath = [IO.Path]::GetTempFileName()
  try {
    [IO.File]::WriteAllBytes($bodyPath, $Bytes)
    $arguments = @(
      "--silent", "--show-error", "--connect-timeout", "10", "--max-time", "60",
      "--request", "PUT", "--data-binary", "@$bodyPath", "--output", $responsePath,
      "--write-out", "%{http_code}|%{remote_ip}"
    )
    $uri = [Uri]$UploadUrl
    if ($uri.Host -eq "chuda.cc") { $arguments += @("--resolve", "chuda.cc:443:$hostIp") }
    foreach ($property in $Headers.PSObject.Properties) {
      $arguments += @("--header", "$($property.Name): $($property.Value)")
    }
    $arguments += $UploadUrl
    $metadata = (& curl.exe @arguments)
    if ($LASTEXITCODE -ne 0) { throw "upload_transport_failed" }
    $parts = ([string]$metadata).Trim().Split("|")
    if ($parts.Count -ne 2 -or [int]$parts[0] -notin @(200, 201, 204)) { throw "upload_http_failed" }
    if ($uri.Host -eq "chuda.cc" -and $parts[1] -ne $hostIp) { throw "upload_route_mismatch" }
  } finally {
    Remove-Item -LiteralPath $bodyPath, $responsePath -Force -ErrorAction SilentlyContinue
  }
}

$nonce = [Guid]::NewGuid().ToString("N")
$login = $null
foreach ($phone in @("18800000001", "188000000001")) {
  $attempt = Invoke-Api POST "/api/v1/auth/login" ([ordered]@{
    phone = $phone
    code = "123456"
    deviceId = "backend-capability-smoke-$nonce"
    agreementAccepted = $true
    agreementVersion = "v0.1"
    privacyVersion = "v0.1"
    clientVersion = "backend-capability-production-smoke"
    timeZone = "Asia/Shanghai"
  })
  if ($attempt.Status -eq 200 -and $attempt.Json.data.accessToken) {
    $login = $attempt
    break
  }
}
if ($null -eq $login) { throw "test_account_login_failed" }

$token = [string]$login.Json.data.accessToken
$workspaceId = [string]$login.Json.data.workspace.workspaceId
if (-not $workspaceId) { throw "login_workspace_missing" }

$metrics = Invoke-Api GET "/api/v1/workspaces/$workspaceId/note-metrics?limit=2" $null $token
if ($metrics.Status -ne 200 -or -not $metrics.Json.success) { throw "metrics_request_failed" }
$metricData = $metrics.Json.data
if ($metricData.schemaVersion -ne "huahuo.workspace_note_daily_metrics.v2" -or
    $metricData.metricId -ne "new_note_count" -or @($metricData.days).Count -lt 1) {
  throw "metrics_contract_invalid"
}
if ([string]$metricData.days[0].date -ne [string]$metricData.coverage.currentDate) {
  throw "metrics_current_date_invalid"
}
$secondPageStatus = "not_applicable"
if ($metricData.hasMore) {
  if (-not $metricData.nextCursor) { throw "metrics_cursor_missing" }
  $cursor = [Uri]::EscapeDataString([string]$metricData.nextCursor)
  $secondPage = Invoke-Api GET "/api/v1/workspaces/$workspaceId/note-metrics?limit=2&cursor=$cursor" $null $token
  if ($secondPage.Status -ne 200 -or -not $secondPage.Json.success -or @($secondPage.Json.data.days).Count -lt 1) {
    throw "metrics_second_page_failed"
  }
  if ([string]$secondPage.Json.data.days[0].date -ge [string]$metricData.days[-1].date) {
    throw "metrics_pagination_order_invalid"
  }
  $secondPageStatus = "passed"
}

$imageBytes = [Convert]::FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
$hasher = [Security.Cryptography.SHA256]::Create()
try { $imageHash = ([BitConverter]::ToString($hasher.ComputeHash($imageBytes))).Replace("-", "").ToLowerInvariant() } finally { $hasher.Dispose() }
$uploadKey = "media-delete-upload-$nonce"
$upload = Invoke-Api POST "/api/v1/media/upload-token" ([ordered]@{
  sourceScene = "workspace_attachment"
  workspaceId = $workspaceId
  fileName = "delete-smoke-$nonce.png"
  mimeType = "image/png"
  sizeBytes = $imageBytes.Length
  sha256 = "sha256:$imageHash"
}) $token $uploadKey
if ($upload.Status -ne 200 -or -not $upload.Json.success) { throw "upload_token_failed" }
$uploadData = $upload.Json.data
if (-not $uploadData.uploadId -or -not $uploadData.resourceId -or -not $uploadData.uploadUrl) {
  throw "upload_token_contract_invalid"
}
Invoke-UploadBytes ([string]$uploadData.uploadUrl) $uploadData.headers $imageBytes

$complete = Invoke-Api POST "/api/v1/media/uploads/$($uploadData.uploadId)/complete" ([ordered]@{
  workspaceId = $workspaceId
}) $token "media-delete-complete-$nonce"
if ($complete.Status -ne 200 -or -not $complete.Json.success) { throw "upload_complete_failed" }
$resourceId = [string]$uploadData.resourceId

$playbackBefore = Invoke-Api GET "/api/v1/media/resources/$resourceId/playback" $null $token
if ($playbackBefore.Status -ne 200) { throw "playback_before_delete_failed" }

$deleteKey = "media-delete-$nonce"
$delete = Invoke-Api DELETE "/api/v1/workspaces/$workspaceId/media/resources/$resourceId" $null $token $deleteKey
if ($delete.Status -ne 200 -or -not $delete.Json.success -or $delete.Json.data.status -ne "deleted") {
  throw "media_delete_failed"
}
$replay = Invoke-Api DELETE "/api/v1/workspaces/$workspaceId/media/resources/$resourceId" $null $token $deleteKey
if ($replay.Status -ne 200 -or -not $replay.Json.success -or $replay.Json.data.status -ne "deleted") {
  throw "media_delete_replay_failed"
}
$playbackAfter = Invoke-Api GET "/api/v1/media/resources/$resourceId/playback" $null $token
if ($playbackAfter.Status -eq 200) { throw "playback_after_delete_still_available" }

[ordered]@{
  schemaVersion = "huahuo.backend-capability-smoke.v1"
  result = "passed"
  host = $hostIp
  noteMetrics = [ordered]@{
    status = "passed"
    schemaVersion = [string]$metricData.schemaVersion
    firstPageDayCount = @($metricData.days).Count
    secondPage = $secondPageStatus
    coverageStartDate = [string]$metricData.coverage.startDate
    historyComplete = [bool]$metricData.coverage.historyComplete
  }
  mediaDelete = [ordered]@{
    status = "passed"
    initialDeleteStatus = [string]$delete.Json.data.status
    replayDeleteStatus = [string]$replay.Json.data.status
    playbackBeforeStatus = $playbackBefore.Status
    playbackAfterStatus = $playbackAfter.Status
  }
} | ConvertTo-Json -Depth 10 -Compress
