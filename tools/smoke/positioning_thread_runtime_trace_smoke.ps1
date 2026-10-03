[CmdletBinding()]
param(
  [ValidateSet("Plan", "Run")][string]$Mode = "Plan",
  [string]$BaseUri = "http://39.107.250.25",
  [string]$WorkspaceId = "",
  [ValidateRange(30, 1800)][int]$TimeoutSeconds = 600,
  [ValidateRange(1, 15)][int]$PollIntervalSeconds = 2,
  [string]$ReceiptPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:PositioningSmokeTargetHost = "39.107.250.25"
$script:PositioningSmokePhoneEnvironment = "HUAHUO_POSITIONING_SMOKE_PHONE"
$script:PositioningSmokeCodeEnvironment = "HUAHUO_POSITIONING_SMOKE_SMS_CODE"
$script:PositioningSmokeTerminalStates = @("succeeded", "failed", "cancelled", "timeout", "aborted", "rejected", "orphaned")
$script:PositioningSmokeForbiddenTraceFields = @(
  "prompt", "content", "text", "path", "logicalPath", "workspacePath",
  "arguments", "argument", "args", "request", "response", "raw",
  "credential", "credentials", "authorization", "headers", "secret",
  "token", "accessToken", "refreshToken", "apiKey", "providerPayload"
)

function Assert-PositioningSmoke {
  param([bool]$Condition, [Parameter(Mandatory)][string]$FailureCode)
  if (-not $Condition) { throw $FailureCode }
}

function Get-PositioningSmokeField {
  param([AllowNull()]$Value, [Parameter(Mandatory)][string]$Name)
  if ($null -eq $Value) { return $null }
  if ($Value -is [System.Collections.IDictionary]) { return $Value[$Name] }
  $property = $Value.PSObject.Properties[$Name]
  if ($null -eq $property) { return $null }
  return $property.Value
}

function Get-PositioningSmokeString {
  param([AllowNull()]$Value, [Parameter(Mandatory)][string]$Name)
  $field = Get-PositioningSmokeField -Value $Value -Name $Name
  if ($null -eq $field) { return "" }
  return ([string]$field).Trim()
}

function Get-PositioningSmokeArray {
  param([AllowNull()]$Value, [Parameter(Mandatory)][string]$Name)
  $field = Get-PositioningSmokeField -Value $Value -Name $Name
  if ($null -eq $field) { return @() }
  return @($field)
}

function New-PositioningSmokeKey {
  param([Parameter(Mandatory)][string]$Name)
  return "positioning-thread-trace-$Name-$([Guid]::NewGuid().ToString('N'))"
}

function Get-PositioningSmokeResponseHeader {
  param([Parameter(Mandatory)]$Response, [Parameter(Mandatory)][string]$Name)
  $headers = Get-PositioningSmokeField -Value $Response -Name "Headers"
  if ($null -eq $headers) { return "" }
  try { return ([string]$headers[$Name]).Trim() } catch { return "" }
}

function Copy-PositioningSmokeResponseHeaders {
  param([AllowNull()]$Headers)
  $copy = @{}
  if ($null -eq $Headers) { return $copy }
  if ($Headers -is [System.Collections.IDictionary]) {
    foreach ($name in $Headers.Keys) { $copy[[string]$name] = [string]$Headers[$name] }
    return $copy
  }
  foreach ($name in @($Headers.AllKeys)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$name)) { $copy[[string]$name] = [string]$Headers[$name] }
  }
  return $copy
}

function Invoke-PositioningSmokeRequest {
  param(
    [Parameter(Mandatory)][ValidateSet("GET", "POST", "PATCH")][string]$Method,
    [Parameter(Mandatory)][string]$Uri,
    [string]$AccessToken = "",
    [AllowNull()]$Body = $null,
    [string]$IdempotencyKey = "",
    [System.Collections.IDictionary]$AdditionalHeaders
  )

  $headers = @{ Accept = "application/json"; "X-Request-Id" = [Guid]::NewGuid().ToString() }
  if ($AccessToken -ne "") { $headers["Authorization"] = "Bearer $AccessToken" }
  if ($IdempotencyKey -ne "") { $headers["X-Idempotency-Key"] = $IdempotencyKey }
  if ($null -ne $AdditionalHeaders) {
    foreach ($name in $AdditionalHeaders.Keys) { $headers[[string]$name] = [string]$AdditionalHeaders[$name] }
  }

  try {
    if ($null -eq $Body) {
      $response = Invoke-WebRequest -Method $Method -Uri $Uri -Headers $headers -UseBasicParsing -TimeoutSec 60
    } else {
      $json = $Body | ConvertTo-Json -Depth 20 -Compress
      $response = Invoke-WebRequest -Method $Method -Uri $Uri -Headers $headers -ContentType "application/json" -Body $json -UseBasicParsing -TimeoutSec 60
    }
    $data = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$response.Content)) {
      $data = [string]$response.Content | ConvertFrom-Json
    }
    return [pscustomobject]@{ StatusCode = [int]$response.StatusCode; Body = $data; Headers = Copy-PositioningSmokeResponseHeaders -Headers $response.Headers }
  } catch {
    $webResponse = $_.Exception.Response
    if ($null -eq $webResponse) { throw "POSITIONING_SMOKE_HTTP_TRANSPORT_FAILED" }
    $raw = ""
    if ($null -ne $_.ErrorDetails -and -not [string]::IsNullOrWhiteSpace([string]$_.ErrorDetails.Message)) {
      $raw = [string]$_.ErrorDetails.Message
    }
    if ([string]::IsNullOrWhiteSpace($raw)) {
      try {
        $reader = New-Object IO.StreamReader($webResponse.GetResponseStream())
        try { $raw = $reader.ReadToEnd() } finally { $reader.Dispose() }
      } catch {}
    }
    $data = $null
    try { if (-not [string]::IsNullOrWhiteSpace($raw)) { $data = $raw | ConvertFrom-Json } } catch {}
    $responseHeaders = Copy-PositioningSmokeResponseHeaders -Headers $webResponse.Headers
    return [pscustomobject]@{ StatusCode = [int]$webResponse.StatusCode; Body = $data; Headers = $responseHeaders }
  }
}

function Get-PositioningSmokeEnvelopeData {
  param(
    [Parameter(Mandatory)]$Response,
    [Parameter(Mandatory)][int[]]$ExpectedStatus,
    [Parameter(Mandatory)][string]$FailureCode
  )
  if ([int]$Response.StatusCode -notin $ExpectedStatus -or $null -eq $Response.Body) { throw $FailureCode }
  if ((Get-PositioningSmokeField -Value $Response.Body -Name "success") -ne $true) { throw $FailureCode }
  $data = Get-PositioningSmokeField -Value $Response.Body -Name "data"
  if ($null -eq $data) { throw $FailureCode }
  return $data
}

function Get-PositioningSmokeErrorCode {
  param([Parameter(Mandatory)]$Response)
  $errorValue = Get-PositioningSmokeField -Value $Response.Body -Name "error"
  if ($errorValue -is [string]) { return ([string]$errorValue).Trim() }
  return Get-PositioningSmokeString -Value $errorValue -Name "code"
}

function Test-PositioningSmokeForbiddenTraceField {
  param([AllowNull()]$Value)
  if ($null -eq $Value) { return $false }
  if ($Value -is [System.Collections.IDictionary]) {
    foreach ($key in $Value.Keys) {
      if ([string]$key -in $script:PositioningSmokeForbiddenTraceFields) { return $true }
      if (Test-PositioningSmokeForbiddenTraceField -Value $Value[$key]) { return $true }
    }
    return $false
  }
  if ($Value -is [pscustomobject]) {
    foreach ($property in $Value.PSObject.Properties) {
      if ($property.Name -in $script:PositioningSmokeForbiddenTraceFields) { return $true }
      if (Test-PositioningSmokeForbiddenTraceField -Value $property.Value) { return $true }
    }
    return $false
  }
  if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
    foreach ($item in $Value) {
      if (Test-PositioningSmokeForbiddenTraceField -Value $item) { return $true }
    }
  }
  return $false
}

function Write-PositioningSmokeReceipt {
  param([Parameter(Mandatory)]$Receipt, [string]$RequestedPath)
  if ([string]::IsNullOrWhiteSpace($RequestedPath)) { return "" }
  $fullPath = [IO.Path]::GetFullPath($RequestedPath)
  $parent = Split-Path -Parent $fullPath
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    [void][IO.Directory]::CreateDirectory($parent)
  }
  if ((Test-Path -LiteralPath $fullPath) -and (Get-Item -LiteralPath $fullPath).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
    throw "POSITIONING_SMOKE_RECEIPT_PATH_INVALID"
  }
  $json = $Receipt | ConvertTo-Json -Depth 20
  [IO.File]::WriteAllText($fullPath, $json + "`n", [Text.UTF8Encoding]::new($false))
  return $fullPath
}

function Wait-PositioningSmokeRun {
  param(
    [Parameter(Mandatory)][string]$Base,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$AgentRunId,
    [Parameter(Mandatory)][int]$Timeout,
    [Parameter(Mandatory)][int]$PollInterval
  )
  $deadline = (Get-Date).AddSeconds($Timeout)
  do {
    $response = Invoke-PositioningSmokeRequest -Method GET -Uri "$Base/api/v1/agent/runs/$([Uri]::EscapeDataString($AgentRunId))" -AccessToken $AccessToken
    $run = Get-PositioningSmokeEnvelopeData -Response $response -ExpectedStatus @(200) -FailureCode "POSITIONING_SMOKE_RUN_READ_FAILED"
    $status = Get-PositioningSmokeString -Value $run -Name "status"
    if ($status -in $script:PositioningSmokeTerminalStates) { return $run }
    Start-Sleep -Seconds $PollInterval
  } while ((Get-Date) -lt $deadline)
  throw "POSITIONING_SMOKE_RUN_TIMEOUT"
}

function Wait-PositioningSmokeInvocation {
  param(
    [Parameter(Mandatory)][string]$Base,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$ThreadId,
    [Parameter(Mandatory)][int]$Timeout,
    [Parameter(Mandatory)][int]$PollInterval
  )
  $uri = "$Base/api/v1/chat/threads/$([Uri]::EscapeDataString($ThreadId))/runtime-invocations/latest"
  $deadline = (Get-Date).AddSeconds($Timeout)
  do {
    $response = Invoke-PositioningSmokeRequest -Method GET -Uri $uri -AccessToken $AccessToken
    if ([int]$response.StatusCode -eq 200) {
      $data = Get-PositioningSmokeEnvelopeData -Response $response -ExpectedStatus @(200) -FailureCode "POSITIONING_SMOKE_INVOCATION_READ_FAILED"
      return [pscustomobject]@{ Data = $data; ETag = Get-PositioningSmokeResponseHeader -Response $response -Name "ETag"; Uri = $uri }
    }
    if ([int]$response.StatusCode -ne 404 -or (Get-PositioningSmokeErrorCode -Response $response) -notin @("RUNTIME_INVOCATION_NOT_FOUND", "THREAD_NOT_FOUND")) {
      throw "POSITIONING_SMOKE_INVOCATION_READ_FAILED"
    }
    Start-Sleep -Seconds $PollInterval
  } while ((Get-Date) -lt $deadline)
  throw "POSITIONING_SMOKE_INVOCATION_TIMEOUT"
}

function Wait-PositioningSmokeInvocationNotModified {
  param(
    [Parameter(Mandatory)]$Initial,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][int]$Timeout,
    [Parameter(Mandatory)][int]$PollInterval
  )
  $data = $Initial.Data
  $etag = [string]$Initial.ETag
  $uri = [string]$Initial.Uri
  $deadline = (Get-Date).AddSeconds($Timeout)
  do {
    $response = Invoke-PositioningSmokeRequest -Method GET -Uri $uri -AccessToken $AccessToken -AdditionalHeaders @{ "If-None-Match" = $etag }
    if ([int]$response.StatusCode -eq 304) {
      $responseETag = Get-PositioningSmokeResponseHeader -Response $response -Name "ETag"
      if ($responseETag -cne $etag) {
        throw "POSITIONING_SMOKE_INVOCATION_NOT_MODIFIED_FAILED:status=304:etagPresent=$($responseETag -ne ''):etagMatches=false"
      }
      return [pscustomobject]@{ Data = $data; ETag = $etag; NotModifiedStatus = 304 }
    }
    if ([int]$response.StatusCode -ne 200) { throw "POSITIONING_SMOKE_INVOCATION_NOT_MODIFIED_FAILED:status=$([int]$response.StatusCode)" }
    $data = Get-PositioningSmokeEnvelopeData -Response $response -ExpectedStatus @(200) -FailureCode "POSITIONING_SMOKE_INVOCATION_NOT_MODIFIED_FAILED"
    $etag = Get-PositioningSmokeResponseHeader -Response $response -Name "ETag"
    if ($etag -eq "") { throw "POSITIONING_SMOKE_INVOCATION_NOT_MODIFIED_FAILED:status=200:etagPresent=false" }
    Start-Sleep -Seconds $PollInterval
  } while ((Get-Date) -lt $deadline)
  throw "POSITIONING_SMOKE_INVOCATION_NOT_MODIFIED_TIMEOUT"
}

function Find-PositioningSmokeAssistantMessage {
  param([Parameter(Mandatory)]$ThreadDetail, [Parameter(Mandatory)][string]$TaskId)
  foreach ($message in (Get-PositioningSmokeArray -Value $ThreadDetail -Name "messages")) {
    if ((Get-PositioningSmokeString -Value $message -Name "role") -ne "assistant" -or
        (Get-PositioningSmokeString -Value $message -Name "status") -ne "succeeded") { continue }
    $payload = Get-PositioningSmokeField -Value $message -Name "payload"
    $messageTaskId = Get-PositioningSmokeString -Value $message -Name "taskId"
    if ($messageTaskId -eq "") { $messageTaskId = Get-PositioningSmokeString -Value $payload -Name "taskId" }
    if ($messageTaskId -ne $TaskId -or (Get-PositioningSmokeString -Value $message -Name "content") -eq "") { continue }
    return $message
  }
  throw "POSITIONING_SMOKE_ASSISTANT_NOT_PERSISTED"
}

function Invoke-PositioningThreadRuntimeTraceSmoke {
  param(
    [Parameter(Mandatory)][string]$RequestedBaseUri,
    [string]$RequestedWorkspaceId,
    [Parameter(Mandatory)][int]$Timeout,
    [Parameter(Mandatory)][int]$PollInterval
  )

  $startedAt = (Get-Date).ToUniversalTime()
  $base = $RequestedBaseUri.TrimEnd("/")
  try { $target = [Uri]$base } catch { throw "POSITIONING_SMOKE_TARGET_INVALID" }
  Assert-PositioningSmoke ($target.Host -ceq $script:PositioningSmokeTargetHost -and $target.Scheme -in @("http", "https") -and $target.PathAndQuery -eq "/") "POSITIONING_SMOKE_TARGET_INVALID"

  $phone = [Environment]::GetEnvironmentVariable($script:PositioningSmokePhoneEnvironment, "Process")
  $smsCode = [Environment]::GetEnvironmentVariable($script:PositioningSmokeCodeEnvironment, "Process")
  Assert-PositioningSmoke (-not [string]::IsNullOrWhiteSpace($phone) -and $phone -match "^[0-9]{11}$") "POSITIONING_SMOKE_PHONE_MISSING"
  Assert-PositioningSmoke (-not [string]::IsNullOrWhiteSpace($smsCode) -and $smsCode -match "^[0-9]{6}$") "POSITIONING_SMOKE_CODE_MISSING"

  $sms = Invoke-PositioningSmokeRequest -Method POST -Uri "$base/api/v1/auth/sms-code" -Body @{ phone = $phone; scene = "login" } -IdempotencyKey (New-PositioningSmokeKey "sms")
  $smsData = Get-PositioningSmokeEnvelopeData -Response $sms -ExpectedStatus @(200, 202) -FailureCode "POSITIONING_SMOKE_SMS_REQUEST_FAILED"
  $smsRequestId = Get-PositioningSmokeString -Value $smsData -Name "smsRequestId"
  Assert-PositioningSmoke ($smsRequestId -ne "") "POSITIONING_SMOKE_SMS_REQUEST_FAILED"

  $loginBody = @{
    phone = $phone; code = $smsCode; smsRequestId = $smsRequestId
    deviceId = "positioning-smoke-$([Guid]::NewGuid().ToString('N'))"
    agreementAccepted = $true; agreementVersion = "qa-20260703"; privacyVersion = "qa-20260703"
    clientVersion = "qa-positioning-thread-trace-20260816"; timeZone = "Asia/Shanghai"
  }
  $login = Invoke-PositioningSmokeRequest -Method POST -Uri "$base/api/v1/auth/login" -Body $loginBody -IdempotencyKey (New-PositioningSmokeKey "login")
  $loginData = Get-PositioningSmokeEnvelopeData -Response $login -ExpectedStatus @(200) -FailureCode "POSITIONING_SMOKE_LOGIN_FAILED"
  $accessToken = Get-PositioningSmokeString -Value $loginData -Name "accessToken"
  $workspace = Get-PositioningSmokeField -Value $loginData -Name "workspace"
  $loginWorkspaceId = Get-PositioningSmokeString -Value $workspace -Name "workspaceId"
  $workspaceId = if ([string]::IsNullOrWhiteSpace($RequestedWorkspaceId)) { $loginWorkspaceId } else { $RequestedWorkspaceId.Trim() }
  Assert-PositioningSmoke ($accessToken -ne "" -and $workspaceId -ne "") "POSITIONING_SMOKE_LOGIN_PROJECTION_INVALID"
  Assert-PositioningSmoke ($workspaceId -match '^[A-Za-z0-9][A-Za-z0-9_-]{2,127}$') "POSITIONING_SMOKE_WORKSPACE_ID_INVALID"

  $positioningUri = "$base/api/v1/workspaces/$([Uri]::EscapeDataString($workspaceId))/positioning/progress"
  $positioningResponse = Invoke-PositioningSmokeRequest -Method GET -Uri $positioningUri -AccessToken $accessToken
  $positioning = $null
  $positioningETag = ""
  $projectionVersion = [int64]0
  $completedPercent = 0
  $modules = @()
  $positioningAvailable = $false
  $positioningUnavailableCode = ""
  if ([int]$positioningResponse.StatusCode -eq 200) {
    $positioning = Get-PositioningSmokeEnvelopeData -Response $positioningResponse -ExpectedStatus @(200) -FailureCode "POSITIONING_SMOKE_PROGRESS_READ_FAILED"
    $positioningETag = Get-PositioningSmokeResponseHeader -Response $positioningResponse -Name "ETag"
    $projectionVersion = [int64](Get-PositioningSmokeField -Value $positioning -Name "projectionVersion")
    $completedPercent = [int](Get-PositioningSmokeField -Value $positioning -Name "completedPercent")
    $modules = @(Get-PositioningSmokeArray -Value $positioning -Name "modules")
    Assert-PositioningSmoke (
      (Get-PositioningSmokeString -Value $positioning -Name "schemaVersion") -ceq "huahuo.positioning-progress.v1" -and
      (Get-PositioningSmokeString -Value $positioning -Name "source") -ceq "workspace_file" -and
      (Get-PositioningSmokeField -Value $positioning -Name "available") -eq $true -and
      $projectionVersion -gt 0 -and $completedPercent -ge 0 -and $completedPercent -le 100 -and
      $modules.Count -gt 0 -and $positioningETag -ne ""
    ) "POSITIONING_SMOKE_PROGRESS_PROJECTION_INVALID"
    $positioningNotModified = Invoke-PositioningSmokeRequest -Method GET -Uri $positioningUri -AccessToken $accessToken -AdditionalHeaders @{ "If-None-Match" = $positioningETag }
    Assert-PositioningSmoke ([int]$positioningNotModified.StatusCode -eq 304 -and (Get-PositioningSmokeResponseHeader -Response $positioningNotModified -Name "ETag") -ceq $positioningETag) "POSITIONING_SMOKE_PROGRESS_NOT_MODIFIED_FAILED"
    $positioningAvailable = $true
  } else {
    $positioningUnavailableCode = Get-PositioningSmokeErrorCode -Response $positioningResponse
    Assert-PositioningSmoke (
      [int]$positioningResponse.StatusCode -eq 503 -and $positioningUnavailableCode -ceq "POSITIONING_PROGRESS_UNAVAILABLE"
    ) "POSITIONING_SMOKE_PROGRESS_READ_FAILED"
  }

  $threadResponse = Invoke-PositioningSmokeRequest -Method POST -Uri "$base/api/v1/chat/threads" -AccessToken $accessToken -Body @{ workspaceId = $workspaceId } -IdempotencyKey (New-PositioningSmokeKey "thread")
  $threadData = Get-PositioningSmokeEnvelopeData -Response $threadResponse -ExpectedStatus @(200) -FailureCode "POSITIONING_SMOKE_THREAD_CREATE_FAILED"
  $thread = Get-PositioningSmokeField -Value $threadData -Name "thread"
  $threadId = Get-PositioningSmokeString -Value $thread -Name "threadId"
  $initialTitleVersion = [int64](Get-PositioningSmokeField -Value $thread -Name "titleVersion")
  Assert-PositioningSmoke ($threadId -ne "" -and $initialTitleVersion -ge 1 -and (Get-PositioningSmokeString -Value $thread -Name "titleMode") -ceq "auto") "POSITIONING_SMOKE_THREAD_CREATE_PROJECTION_INVALID"

  $titleUri = "$base/api/v1/chat/threads/$([Uri]::EscapeDataString($threadId))"
  $renameKey = New-PositioningSmokeKey "rename"
  $renameBody = @{ titleMode = "custom"; title = "Positioning trace smoke"; expectedTitleVersion = $initialTitleVersion }
  $renamedResponse = Invoke-PositioningSmokeRequest -Method PATCH -Uri $titleUri -AccessToken $accessToken -Body $renameBody -IdempotencyKey $renameKey
  $renamedData = Get-PositioningSmokeEnvelopeData -Response $renamedResponse -ExpectedStatus @(200) -FailureCode "POSITIONING_SMOKE_TITLE_RENAME_FAILED"
  $renamed = Get-PositioningSmokeField -Value $renamedData -Name "thread"
  $renamedVersion = [int64](Get-PositioningSmokeField -Value $renamed -Name "titleVersion")
  Assert-PositioningSmoke ($renamedVersion -eq ($initialTitleVersion + 1) -and (Get-PositioningSmokeString -Value $renamed -Name "titleMode") -ceq "custom") "POSITIONING_SMOKE_TITLE_RENAME_INVALID"

  $replayResponse = Invoke-PositioningSmokeRequest -Method PATCH -Uri $titleUri -AccessToken $accessToken -Body $renameBody -IdempotencyKey $renameKey
  $replayData = Get-PositioningSmokeEnvelopeData -Response $replayResponse -ExpectedStatus @(200) -FailureCode "POSITIONING_SMOKE_TITLE_REPLAY_FAILED"
  $replayed = Get-PositioningSmokeField -Value $replayData -Name "thread"
  Assert-PositioningSmoke ([int64](Get-PositioningSmokeField -Value $replayed -Name "titleVersion") -eq $renamedVersion) "POSITIONING_SMOKE_TITLE_REPLAY_INVALID"

  $conflictResponse = Invoke-PositioningSmokeRequest -Method PATCH -Uri $titleUri -AccessToken $accessToken -Body @{ titleMode = "custom"; title = "Stale title"; expectedTitleVersion = $initialTitleVersion } -IdempotencyKey (New-PositioningSmokeKey "conflict")
  Assert-PositioningSmoke ([int]$conflictResponse.StatusCode -eq 409 -and (Get-PositioningSmokeErrorCode -Response $conflictResponse) -ceq "THREAD_TITLE_VERSION_CONFLICT") "POSITIONING_SMOKE_TITLE_CONFLICT_INVALID"

  $resetResponse = Invoke-PositioningSmokeRequest -Method PATCH -Uri $titleUri -AccessToken $accessToken -Body @{ titleMode = "auto"; expectedTitleVersion = $renamedVersion } -IdempotencyKey (New-PositioningSmokeKey "reset")
  $resetData = Get-PositioningSmokeEnvelopeData -Response $resetResponse -ExpectedStatus @(200) -FailureCode "POSITIONING_SMOKE_TITLE_RESET_FAILED"
  $reset = Get-PositioningSmokeField -Value $resetData -Name "thread"
  $resetVersion = [int64](Get-PositioningSmokeField -Value $reset -Name "titleVersion")
  Assert-PositioningSmoke ($resetVersion -eq ($renamedVersion + 1) -and (Get-PositioningSmokeString -Value $reset -Name "titleMode") -ceq "auto") "POSITIONING_SMOKE_TITLE_RESET_INVALID"

  $catalogResponse = Invoke-PositioningSmokeRequest -Method GET -Uri "$base/api/v1/agent-profiles" -AccessToken $accessToken
  $catalog = Get-PositioningSmokeEnvelopeData -Response $catalogResponse -ExpectedStatus @(200) -FailureCode "POSITIONING_SMOKE_AGENT_CATALOG_READ_FAILED"
  $matchingAgents = @(
    Get-PositioningSmokeArray -Value $catalog -Name "items" | Where-Object {
      (Get-PositioningSmokeString -Value $_ -Name "agentProfileId") -ceq "renshe_content"
    }
  )
  Assert-PositioningSmoke ($matchingAgents.Count -eq 1) "POSITIONING_SMOKE_AGENT_CATALOG_UNAVAILABLE"
  $agentProfileId = Get-PositioningSmokeString -Value $matchingAgents[0] -Name "agentProfileId"

  $messageBody = @{
    agentProfileId = $agentProfileId
    input = @{ content = @(@{ type = "text"; text = "Return one concise sentence confirming this smoke run." }) }
  }
  $messageResponse = Invoke-PositioningSmokeRequest -Method POST -Uri "$titleUri/messages" -AccessToken $accessToken -Body $messageBody -IdempotencyKey (New-PositioningSmokeKey "message")
  $messageData = Get-PositioningSmokeEnvelopeData -Response $messageResponse -ExpectedStatus @(200) -FailureCode "POSITIONING_SMOKE_MESSAGE_SUBMIT_FAILED"
  $agentRunId = Get-PositioningSmokeString -Value $messageData -Name "agentRunId"
  $taskId = Get-PositioningSmokeString -Value $messageData -Name "taskId"
  $runProjection = Get-PositioningSmokeField -Value $messageData -Name "run"
  if ($agentRunId -eq "") { $agentRunId = Get-PositioningSmokeString -Value $runProjection -Name "agentRunId" }
  if ($taskId -eq "") { $taskId = Get-PositioningSmokeString -Value $runProjection -Name "taskId" }
  Assert-PositioningSmoke ($agentRunId -ne "" -and $taskId -ne "") "POSITIONING_SMOKE_MESSAGE_PROJECTION_INVALID"

  $terminalRun = Wait-PositioningSmokeRun -Base $base -AccessToken $accessToken -AgentRunId $agentRunId -Timeout $Timeout -PollInterval $PollInterval
  $runStatus = Get-PositioningSmokeString -Value $terminalRun -Name "status"
  Assert-PositioningSmoke ($runStatus -ceq "succeeded") "POSITIONING_SMOKE_RUN_FAILED"

  $detailResponse = Invoke-PositioningSmokeRequest -Method GET -Uri $titleUri -AccessToken $accessToken
  $detail = Get-PositioningSmokeEnvelopeData -Response $detailResponse -ExpectedStatus @(200) -FailureCode "POSITIONING_SMOKE_THREAD_READ_FAILED"
  [void](Find-PositioningSmokeAssistantMessage -ThreadDetail $detail -TaskId $taskId)
  $detailThread = Get-PositioningSmokeField -Value $detail -Name "thread"
  Assert-PositioningSmoke ((Get-PositioningSmokeString -Value $detailThread -Name "titleMode") -ceq "auto" -and (Get-PositioningSmokeString -Value $detailThread -Name "title") -ne "") "POSITIONING_SMOKE_AUTO_TITLE_INVALID"

  $invocationResult = Wait-PositioningSmokeInvocation -Base $base -AccessToken $accessToken -ThreadId $threadId -Timeout $Timeout -PollInterval $PollInterval
  $stableInvocation = Wait-PositioningSmokeInvocationNotModified -Initial $invocationResult -AccessToken $accessToken -Timeout $Timeout -PollInterval $PollInterval
  $invocation = $stableInvocation.Data
  $invocationETag = [string]$stableInvocation.ETag
  $selection = Get-PositioningSmokeField -Value $invocation -Name "selection"
  $requestSummary = Get-PositioningSmokeField -Value $invocation -Name "requestSummary"
  $skills = @(Get-PositioningSmokeArray -Value $selection -Name "skillProfileIds")
  $files = @(Get-PositioningSmokeArray -Value $invocation -Name "files")
  $tools = @(Get-PositioningSmokeArray -Value $invocation -Name "tools")
  Assert-PositioningSmoke (
    (Get-PositioningSmokeString -Value $invocation -Name "schemaVersion") -ceq "huahuo.thread-runtime-invocation.v1" -and
    (Get-PositioningSmokeString -Value $invocation -Name "threadId") -ceq $threadId -and
    (Get-PositioningSmokeString -Value $invocation -Name "agentRunId") -ceq $agentRunId -and
    (Get-PositioningSmokeString -Value $invocation -Name "status") -ceq "succeeded" -and
    (Get-PositioningSmokeString -Value $selection -Name "agentProfileId") -ne "" -and
    (Get-PositioningSmokeString -Value $selection -Name "modelProfileId") -ne "" -and
    $skills.Count -gt 0 -and $files.Count -gt 0 -and
    @(Get-PositioningSmokeArray -Value $requestSummary -Name "contentTypes") -contains "text" -and
    $invocationETag -ne "" -and -not (Test-PositioningSmokeForbiddenTraceField -Value $invocation)
  ) "POSITIONING_SMOKE_INVOCATION_PROJECTION_INVALID"

  $missingThreadId = "thread_missing_$([Guid]::NewGuid().ToString('N'))"
  $ownershipResponse = Invoke-PositioningSmokeRequest -Method GET -Uri "$base/api/v1/chat/threads/$missingThreadId/runtime-invocations/latest" -AccessToken $accessToken
  Assert-PositioningSmoke ([int]$ownershipResponse.StatusCode -eq 404 -and (Get-PositioningSmokeErrorCode -Response $ownershipResponse) -ceq "THREAD_NOT_FOUND") "POSITIONING_SMOKE_INVOCATION_OWNERSHIP_INVALID"

  $receiptStatus = if ($positioningAvailable) { "passed" } else { "blocked" }
  return [ordered]@{
    schemaVersion = "huahuo.positioning-thread-runtime-trace-smoke-receipt.v1"
    status = $receiptStatus
    targetHost = $script:PositioningSmokeTargetHost
    startedAt = $startedAt.ToString("o")
    completedAt = (Get-Date).ToUniversalTime().ToString("o")
    positioning = [ordered]@{
      httpStatus = [int]$positioningResponse.StatusCode
      notModifiedStatus = if ($positioningAvailable) { 304 } else { $null }
      etag = $positioningETag; available = $positioningAvailable
      unavailableCode = $positioningUnavailableCode
      projectionVersion = $projectionVersion
      validationStatus = Get-PositioningSmokeString -Value $positioning -Name "validationStatus"
      completedPercent = $completedPercent; moduleCount = $modules.Count
    }
    title = [ordered]@{
      threadId = $threadId; initialVersion = $initialTitleVersion; renamedVersion = $renamedVersion
      replayVersion = [int64](Get-PositioningSmokeField -Value $replayed -Name "titleVersion")
      conflictCode = "THREAD_TITLE_VERSION_CONFLICT"; resetVersion = $resetVersion; finalMode = "auto"
    }
    runtime = [ordered]@{
      agentRunId = $agentRunId; status = $runStatus; assistantPersisted = $true
      invocationSchemaVersion = Get-PositioningSmokeString -Value $invocation -Name "schemaVersion"
      invocationETag = $invocationETag
      requestedAgentProfileId = $agentProfileId
      agentProfileId = Get-PositioningSmokeString -Value $selection -Name "agentProfileId"
      skillProfileIds = $skills
      modelProfileId = Get-PositioningSmokeString -Value $selection -Name "modelProfileId"
      fileCount = $files.Count; toolCount = $tools.Count; redactionChecked = $true
      notModifiedStatus = [int]$stableInvocation.NotModifiedStatus; ownershipStatus = 404
    }
  }
}

if ($Mode -eq "Plan") {
  [ordered]@{
    schemaVersion = "huahuo.positioning-thread-runtime-trace-smoke-plan.v1"
    targetHost = $script:PositioningSmokeTargetHost
    workspaceSelection = if ([string]::IsNullOrWhiteSpace($WorkspaceId)) { "login_default" } else { "explicit_owned" }
    credentialEnvironmentVariables = @($script:PositioningSmokePhoneEnvironment, $script:PositioningSmokeCodeEnvironment)
    steps = @("login", "positioning-200-304-or-503-fail-closed", "title-cas-replay-conflict-reset", "agent-catalog-selection", "new-run", "assistant-readback", "runtime-trace-200-304", "ownership-404", "safe-receipt")
  } | ConvertTo-Json -Depth 10
  return
}

$receipt = Invoke-PositioningThreadRuntimeTraceSmoke -RequestedBaseUri $BaseUri -RequestedWorkspaceId $WorkspaceId -Timeout $TimeoutSeconds -PollInterval $PollIntervalSeconds
$savedPath = Write-PositioningSmokeReceipt -Receipt $receipt -RequestedPath $ReceiptPath
$receipt | ConvertTo-Json -Depth 20
if ($savedPath -ne "") { Write-Output "POSITIONING_THREAD_RUNTIME_TRACE_SMOKE_RECEIPT=$savedPath" }
if ([string]$receipt.status -ne "passed") { throw "POSITIONING_SMOKE_PROGRESS_SOURCE_UNAVAILABLE" }
