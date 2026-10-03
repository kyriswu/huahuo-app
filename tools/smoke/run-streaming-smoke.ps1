param(
  [Parameter(Mandatory = $true)][string]$Phone,
  [Parameter(Mandatory = $true)][Security.SecureString]$Code,
  [ValidateRange(60, 1200)][int]$TimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'
$HostIp = '39.107.250.25'
$PublicBase = 'https://chuda.cc'
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
$Nonce = ([guid]::NewGuid().ToString('N')).Substring(0, 12)
$Suite = "assistant-streaming-20260818-$Nonce"
$SseLogPath = Join-Path $PSScriptRoot "$Suite-sse.log"
$SummaryPath = Join-Path $PSScriptRoot "$Suite-summary.json"

function ConvertTo-PlainText([Security.SecureString]$Value) {
  $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Invoke-PublicJson {
  param(
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Path,
    [object]$Body = $null,
    [string]$Token = '',
    [string]$IdempotencyKey = ''
  )
  $output = [IO.Path]::GetTempFileName()
  $input = $null
  try {
    $arguments = @(
      '--silent', '--show-error', '--resolve', "chuda.cc:443:$HostIp",
      '--connect-timeout', '10', '--max-time', '180', '--request', $Method,
      '--header', 'Content-Type: application/json', '--output', $output,
      '--write-out', '%{http_code}|%{remote_ip}'
    )
    if ($Token) { $arguments += @('--header', "Authorization: Bearer $Token") }
    if ($IdempotencyKey) { $arguments += @('--header', "X-Idempotency-Key: $IdempotencyKey") }
    if ($null -ne $Body) {
      $input = [IO.Path]::GetTempFileName()
      [IO.File]::WriteAllText($input, ($Body | ConvertTo-Json -Depth 30 -Compress), $Utf8NoBom)
      $arguments += @('--data-binary', "@$input")
    }
    $arguments += "$PublicBase$Path"
    $metadata = (& curl.exe @arguments)
    if ($LASTEXITCODE -ne 0) { throw "transport_failed:$Method`:$Path" }
    $parts = ([string]$metadata).Trim().Split('|')
    if ($parts.Count -ne 2 -or $parts[1] -ne $HostIp) { throw "route_mismatch:$Method`:$Path" }
    $raw = [IO.File]::ReadAllText($output, $Utf8NoBom)
    $json = if ($raw) { $raw | ConvertFrom-Json } else { $null }
    return [pscustomobject]@{ Status = [int]$parts[0]; Json = $json; Raw = $raw }
  } finally {
    Remove-Item -LiteralPath $output -Force -ErrorAction SilentlyContinue
    if ($input) { Remove-Item -LiteralPath $input -Force -ErrorAction SilentlyContinue }
  }
}

function Require-Http($Response, [int[]]$Expected, [string]$Label) {
  if ($Expected -notcontains $Response.Status) {
    $preview = [string]$Response.Raw
    if ($preview.Length -gt 800) { $preview = $preview.Substring(0, 800) }
    throw "$Label`_http_$($Response.Status):$preview"
  }
  if ($null -eq $Response.Json) { throw "$Label`_json_missing" }
}

$plainCode = ConvertTo-PlainText $Code
$login = Invoke-PublicJson POST '/api/v1/auth/login' @{
  phone = $Phone
  code = $plainCode
  deviceId = $Suite
  agreementAccepted = $true
  agreementVersion = 'v0.1'
  privacyVersion = 'v0.1'
  clientVersion = 'assistant-streaming-smoke'
  timeZone = 'Asia/Shanghai'
}
$plainCode = $null
Require-Http $login @(200) 'login'
$token = [string]$login.Json.data.accessToken
if (-not $token -or $login.Json.data.workspace.status -ne 'ready') { throw 'login_workspace_not_ready' }

$models = Invoke-PublicJson GET '/api/v1/agent-profiles/self_media_creation/models' $null $token
Require-Http $models @(200) 'models'
$selectable = @($models.Json.data.items | Where-Object { $_.selectable -ne $false })
$preferred = @($selectable | Where-Object { $_.modelProfileId -eq 'mimo-high-thinking' })
$model = if ($preferred.Count -gt 0) { [string]$preferred[0].modelProfileId } else { [string]$selectable[0].modelProfileId }
if (-not $model) { throw 'model_missing' }

$thread = Invoke-PublicJson POST '/api/v1/chat/threads' @{ scene = 'workspace_chat' } $token "$Suite-thread"
Require-Http $thread @(200) 'thread'
$threadId = [string]$thread.Json.data.thread.threadId
if (-not $threadId) { $threadId = [string]$thread.Json.data.threadId }
if (-not $threadId) { throw 'thread_id_missing' }

$requestBody = @{
  agentProfileId = 'self_media_creation'
  modelProfileId = $model
  input = @{ content = @(@{
    type = 'text'
    text = 'Reply with exactly three short sentences explaining why streaming improves perceived latency. Do not use tools.'
  }) }
}
$startedAtUtc = [DateTimeOffset]::UtcNow
$clock = [Diagnostics.Stopwatch]::StartNew()
$submit = Invoke-PublicJson POST "/api/v1/chat/threads/$threadId/messages" $requestBody $token "$Suite-message"
Require-Http $submit @(200) 'submit'
$submitAckMilliseconds = [Math]::Round($clock.Elapsed.TotalMilliseconds, 1)
$runId = [string]$submit.Json.data.agentRunId
$taskId = [string]$submit.Json.data.taskId
if (-not $runId -or -not $taskId) { throw 'run_identity_missing' }
Write-Output "submitted run=$runId ack_ms=$submitAckMilliseconds"

$streamArguments = @(
  '--silent', '--show-error', '--no-buffer', '--resolve', "chuda.cc:443:$HostIp",
  '--connect-timeout', '10', '--max-time', [string]$TimeoutSeconds,
  '--header', "Authorization: Bearer $token", '--header', 'Accept: text/event-stream',
  "$PublicBase/api/v1/agent/runs/$runId/events/stream?afterSequence=0"
)
$currentEvent = ''
$firstDraftMilliseconds = $null
$draftEventCount = 0
$terminalEventType = ''
$lastSequence = 0
$sseLines = [Collections.Generic.List[string]]::new()
& curl.exe @streamArguments | ForEach-Object {
  $line = [string]$_
  $sseLines.Add($line)
  if ($line.StartsWith('event: ')) {
    $currentEvent = $line.Substring(7).Trim()
    return
  }
  if (-not $line.StartsWith('data: ')) { return }
  $eventPayload = $line.Substring(6) | ConvertFrom-Json
  if ($eventPayload.sequence) { $lastSequence = [int64]$eventPayload.sequence }
  $eventType = [string]$eventPayload.eventType
  if ($eventType -eq 'draft_delta') {
    $deltaText = [string]$eventPayload.data.deltaText
    if ($deltaText.Trim().Length -gt 0) {
      $draftEventCount += 1
      if ($null -eq $firstDraftMilliseconds) {
        $firstDraftMilliseconds = [Math]::Round($clock.Elapsed.TotalMilliseconds, 1)
        Write-Output "first_draft_ms=$firstDraftMilliseconds sequence=$lastSequence"
      }
    }
  }
  if ($currentEvent -eq 'terminal') { $terminalEventType = $eventType }
}
$streamExitCode = $LASTEXITCODE
[IO.File]::WriteAllLines($SseLogPath, $sseLines, $Utf8NoBom)
if ($streamExitCode -ne 0) { throw "sse_transport_failed:$streamExitCode" }
if ($null -eq $firstDraftMilliseconds) { throw 'draft_delta_missing' }
if (-not $terminalEventType) { throw 'terminal_sse_missing' }

$poll = Invoke-PublicJson GET "/api/v1/agent/runs/$runId" $null $token
Require-Http $poll @(200) 'poll'
$terminalStatus = [string]$poll.Json.data.status
if ($terminalStatus -ne 'succeeded') { throw "terminal_status:$terminalStatus" }

$assistant = ''
for ($attempt = 0; $attempt -lt 60; $attempt++) {
  $readback = Invoke-PublicJson GET "/api/v1/chat/threads/$threadId" $null $token
  Require-Http $readback @(200) 'readback'
  $message = @($readback.Json.data.messages | Where-Object {
    $_.role -eq 'assistant' -and ($_.taskId -eq $taskId -or $_.task_id -eq $taskId)
  })[-1]
  if ($message) {
    $assistant = [string]$message.content
    if (-not $assistant -and $message.payload) { $assistant = [string]$message.payload.reply }
    if (-not $assistant -and $message.payload) { $assistant = [string]$message.payload.content }
    if (-not $assistant -and $message.payload) { $assistant = [string]$message.payload.text }
  }
  if ($assistant.Trim().Length -gt 0) { break }
  Start-Sleep -Seconds 1
}
if ($assistant.Trim().Length -eq 0) { throw 'assistant_message_missing' }

$summary = [ordered]@{
  schemaVersion = 'huahuo.assistant-streaming-smoke.v1'
  status = 'passed'
  authorizedHost = $HostIp
  platformReleaseId = 'huahuo-ai-0.1.0-20260818T045000Z-483b91491f41'
  startedAtUtc = $startedAtUtc.ToString('o')
  submitAckMilliseconds = $submitAckMilliseconds
  firstDraftMilliseconds = $firstDraftMilliseconds
  totalMilliseconds = [Math]::Round($clock.Elapsed.TotalMilliseconds, 1)
  draftEventCount = $draftEventCount
  lastSequence = $lastSequence
  terminalEventType = $terminalEventType
  terminalStatus = $terminalStatus
  assistantCharacters = $assistant.Length
  modelProfileId = $model
  threadId = $threadId
  agentRunId = $runId
  taskId = $taskId
  sseLogPath = $SseLogPath
}
[IO.File]::WriteAllText($SummaryPath, ($summary | ConvertTo-Json -Depth 10), $Utf8NoBom)
$summary | ConvertTo-Json -Depth 10
