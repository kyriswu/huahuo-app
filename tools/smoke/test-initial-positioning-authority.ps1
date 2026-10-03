[CmdletBinding()]
param(
  [string]$BaseUri = "http://39.107.250.25",
  [string]$Phone = "18800000001",
  [string]$SmsCode = "123456",
  [ValidateRange(30, 1200)][int]$TimeoutSeconds = 600,
  [string]$ReceiptPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-SmokeApi {
  param(
    [Parameter(Mandatory)][string]$Method,
    [Parameter(Mandatory)][string]$Path,
    [string]$AccessToken = "",
    [AllowNull()]$Body = $null,
    [string]$IdempotencyKey = ""
  )
  $headers = @{ Accept = "application/json"; "X-Request-Id" = [Guid]::NewGuid().ToString() }
  if ($AccessToken -ne "") { $headers.Authorization = "Bearer $AccessToken" }
  if ($IdempotencyKey -ne "") { $headers["X-Idempotency-Key"] = $IdempotencyKey }
  $uri = $BaseUri.TrimEnd("/") + $Path
  try {
    $parameters = @{ Method = $Method; Uri = $uri; Headers = $headers; UseBasicParsing = $true; TimeoutSec = 60 }
    if ($null -ne $Body) {
      $parameters.ContentType = "application/json"
      $jsonBody = $Body | ConvertTo-Json -Depth 20 -Compress
      $parameters.Body = [Text.UTF8Encoding]::new($false).GetBytes($jsonBody)
    }
    $response = Invoke-WebRequest @parameters
    $payload = if ([string]::IsNullOrWhiteSpace([string]$response.Content)) { $null } else { $response.Content | ConvertFrom-Json }
    return [pscustomobject]@{ StatusCode = [int]$response.StatusCode; Payload = $payload }
  } catch {
    if ($null -eq $_.Exception.Response) { throw }
    $raw = if ($null -ne $_.ErrorDetails) { [string]$_.ErrorDetails.Message } else { "" }
    $payload = $null
    try { if ($raw -ne "") { $payload = $raw | ConvertFrom-Json } } catch {}
    return [pscustomobject]@{ StatusCode = [int]$_.Exception.Response.StatusCode; Payload = $payload }
  }
}

function Get-Data {
  param([Parameter(Mandatory)]$Response, [Parameter(Mandatory)][int[]]$StatusCodes, [Parameter(Mandatory)][string]$Code)
  if ($Response.StatusCode -notin $StatusCodes -or $null -eq $Response.Payload -or $Response.Payload.success -ne $true) {
    throw "$Code`:status=$($Response.StatusCode)"
  }
  return $Response.Payload.data
}

function Get-ErrorCode {
  param([Parameter(Mandatory)]$Response)
  if ($null -eq $Response.Payload) { return "" }
  if ($Response.Payload.error -is [string]) { return [string]$Response.Payload.error }
  return [string]$Response.Payload.error.code
}

function New-Key([string]$Name) {
  return "initial-positioning-authority-$Name-$([Guid]::NewGuid().ToString('N'))"
}

function Login {
  $sms = Get-Data (Invoke-SmokeApi -Method POST -Path "/api/v1/auth/sms-code" -Body @{ phone = $Phone; scene = "login" } -IdempotencyKey (New-Key "sms")) @(200, 202) "SMS_FAILED"
  $body = @{
    phone = $Phone
    smsRequestId = [string]$sms.smsRequestId
    code = $SmsCode
    deviceId = "initial-positioning-authority-$([Guid]::NewGuid().ToString('N'))"
    agreementAccepted = $true
    agreementVersion = "qa-20260818"
    privacyVersion = "qa-20260818"
    clientVersion = "qa-initial-positioning-authority-20260818"
    timeZone = "Asia/Shanghai"
  }
  return Get-Data (Invoke-SmokeApi -Method POST -Path "/api/v1/auth/login" -Body $body -IdempotencyKey (New-Key "login")) @(200) "LOGIN_FAILED"
}

$startedAt = (Get-Date).ToUniversalTime()
$login = Login
$token = [string]$login.accessToken
$workspaceId = [string]$login.workspace.workspaceId
if ($token -eq "" -or $workspaceId -eq "") { throw "LOGIN_PROJECTION_INVALID" }

$threadData = Get-Data (Invoke-SmokeApi -Method POST -Path "/api/v1/chat/threads" -AccessToken $token -Body @{ workspaceId = $workspaceId } -IdempotencyKey (New-Key "thread")) @(200) "THREAD_CREATE_FAILED"
$threadId = [string]$threadData.thread.threadId
if ($threadId -eq "") { throw "THREAD_ID_MISSING" }

$messageBody = @{
  agentProfileId = "positioning_lv1"
  input = @{
    content = @(@{
      type = "text"
      text = "请完成初始定位，并将最终定位交给服务端写回正式定位文件。名称：花火初始定位服务端权威验收；行业：AI 内容创作；账号目标：验证服务端完成定位写回与状态收敛；目标受众：需要稳定内容定位的创作者；内容方向：讲解如何建立可持续的内容定位；可拍资源：电脑操作界面、定位分析过程和本人讲解画面。以上三项基础信息已经齐全，请直接交付可使用的完整初始定位报告。"
    })
  }
}
$message = Get-Data (Invoke-SmokeApi -Method POST -Path "/api/v1/chat/threads/$threadId/messages" -AccessToken $token -Body $messageBody -IdempotencyKey (New-Key "message")) @(200) "RUN_SUBMIT_FAILED"
$runId = [string]$message.agentRunId
$taskId = [string]$message.taskId
if ($runId -eq "" -and $null -ne $message.run) { $runId = [string]$message.run.agentRunId }
if ($taskId -eq "" -and $null -ne $message.run) { $taskId = [string]$message.run.taskId }
if ($runId -eq "" -or $taskId -eq "") { throw "RUN_BINDING_MISSING" }

$positioning = @{
  name = "花火初始定位服务端权威验收"
  industry = "AI 内容创作"
  accountGoal = "验证服务端完成定位写回与状态收敛"
  targetAudience = "需要稳定内容定位的创作者"
}
$attemptPath = "/api/v1/workspaces/$workspaceId/initial-positioning/attempts"
$attempt = Get-Data (Invoke-SmokeApi -Method POST -Path $attemptPath -AccessToken $token -Body @{ agentRunId = $runId; positioning = $positioning }) @(202) "ATTEMPT_CREATE_FAILED"
$attemptId = [string]$attempt.attemptId
if ($attemptId -eq "") { throw "ATTEMPT_ID_MISSING" }

$replay = Get-Data (Invoke-SmokeApi -Method POST -Path $attemptPath -AccessToken $token -Body @{ agentRunId = $runId; positioning = $positioning }) @(202) "ATTEMPT_REPLAY_FAILED"
if ([string]$replay.attemptId -cne $attemptId) { throw "ATTEMPT_REPLAY_CHANGED_ID" }

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$runStatus = ""
$attemptState = ""
do {
  $run = Get-Data (Invoke-SmokeApi -Method GET -Path "/api/v1/agent/runs/$runId" -AccessToken $token) @(200) "RUN_READ_FAILED"
  $runStatus = [string]$run.status
  $current = Get-Data (Invoke-SmokeApi -Method GET -Path "/api/v1/workspaces/$workspaceId/initial-positioning/attempts/$attemptId" -AccessToken $token) @(200) "ATTEMPT_READ_FAILED"
  $attemptState = [string]$current.state
  if ($attemptState -eq "completed") { break }
  if ($attemptState -in @("failed_retryable", "failed_terminal", "cancelled", "superseded")) {
    throw "ATTEMPT_TERMINAL_FAILURE:$attemptState`:$([string]$current.failureCode)"
  }
  Start-Sleep -Seconds 2
} while ((Get-Date) -lt $deadline)
if ($runStatus -ne "succeeded" -or $attemptState -ne "completed") { throw "ATTEMPT_TIMEOUT:run=$runStatus`:attempt=$attemptState" }

$thread = Get-Data (Invoke-SmokeApi -Method GET -Path "/api/v1/chat/threads/$threadId" -AccessToken $token) @(200) "THREAD_READ_FAILED"
$assistant = @($thread.messages | Where-Object { [string]$_.role -eq "assistant" -and [string]$_.status -eq "succeeded" -and ([string]$_.taskId -eq $taskId -or [string]$_.payload.taskId -eq $taskId) })
if ($assistant.Count -lt 1) { throw "ASSISTANT_NOT_PERSISTED" }

$current = Get-Data (Invoke-SmokeApi -Method GET -Path "/api/v1/workspaces/$workspaceId/initial-positioning/current" -AccessToken $token) @(200) "CURRENT_READ_FAILED"
if ([string]$current.state -ne "completed" -or [string]$current.attemptId -ne $attemptId) { throw "CURRENT_NOT_COMPLETED" }

$status = Get-Data (Invoke-SmokeApi -Method GET -Path "/api/v1/me/status" -AccessToken $token) @(200) "ME_STATUS_FAILED"
$loginAgain = Login
if ([string]$status.initialPositioning.state -ne "completed" -or $status.onboardingRequired -ne $false) { throw "ME_STATUS_PROJECTION_INVALID" }
if ([string]$loginAgain.initialPositioning.state -ne "completed" -or $loginAgain.onboardingRequired -ne $false) { throw "LOGIN_PROJECTION_INVALID" }

$legacy = Invoke-SmokeApi -Method POST -Path "/api/v1/onboarding/creative-positioning" -AccessToken $token -IdempotencyKey (New-Key "legacy") -Body @{
  name = [string]$positioning.name
  industry = [string]$positioning.industry
  accountGoal = [string]$positioning.accountGoal
  targetAudience = [string]$positioning.targetAudience
  commonExpressions = @()
}
if ($legacy.StatusCode -ne 409 -or (Get-ErrorCode $legacy) -ne "INITIAL_POSITIONING_SERVER_MANAGED") {
  throw "LEGACY_COMPLETION_NOT_GUARDED:status=$($legacy.StatusCode):code=$(Get-ErrorCode $legacy)"
}

$receipt = [ordered]@{
  schemaVersion = "huahuo.initial-positioning-smoke-receipt.v1"
  result = "passed"
  targetHost = "39.107.250.25"
  startedAt = $startedAt.ToString("o")
  completedAt = (Get-Date).ToUniversalTime().ToString("o")
  workspaceId = $workspaceId
  threadId = $threadId
  agentRunId = $runId
  taskId = $taskId
  attemptId = $attemptId
  runStatus = $runStatus
  attemptState = $attemptState
  assistantPersisted = $true
  loginAndStatusCompleted = $true
  legacyCompletionGuarded = $true
}
if ($ReceiptPath -ne "") {
  $json = $receipt | ConvertTo-Json -Depth 10
  [IO.File]::WriteAllText([IO.Path]::GetFullPath($ReceiptPath), $json + "`n", [Text.UTF8Encoding]::new($false))
}
$receipt | ConvertTo-Json -Depth 10 -Compress
