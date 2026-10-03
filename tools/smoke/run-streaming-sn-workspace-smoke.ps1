[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^1[0-9]{10}$')]
  [string]$Phone,

  [Parameter(Mandatory = $true)]
  [ValidatePattern('^[0-9]{4,8}$')]
  [string]$SmsCode,

  [string]$ApiBase = 'http://39.107.250.25/api/v1',
  [string]$BackendSourceRoot = 'E:/huahuoai/.worktrees/recording-card-ownership-20260819/backend/source',
  [string]$AgentProfileId = 'renshe_content',
  [string]$Message = '你好',
  [ValidateRange(60, 1800)][int]$TimeoutSeconds = 600,
  [string]$EvidencePath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$commonPath = Join-Path $BackendSourceRoot 'scripts/minutes_api_common.ps1'
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
  throw "SMOKE_API_COMMON_MISSING:$commonPath"
}
. $commonPath

if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
  $EvidencePath = Join-Path $PSScriptRoot ('smoke-evidence-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '.json')
}
$EvidencePath = [IO.Path]::GetFullPath($EvidencePath)
$evidenceDirectory = Split-Path -Parent $EvidencePath
if (-not (Test-Path -LiteralPath $evidenceDirectory -PathType Container)) {
  [void][IO.Directory]::CreateDirectory($evidenceDirectory)
}

function Get-SmokeNestedValue {
  param(
    [AllowNull()][object]$Object,
    [Parameter(Mandatory = $true)][string[]]$Paths
  )

  foreach ($path in $Paths) {
    $value = $Object
    $found = $true
    foreach ($segment in $path.Split('.')) {
      $value = Get-HuahuoObjectValue -Object $value -Names @($segment)
      if ($null -eq $value) {
        $found = $false
        break
      }
    }
    if ($found) {
      return $value
    }
  }
  return $null
}

function Test-SmokeProperty {
  param(
    [AllowNull()][object]$Object,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if ($null -eq $Object) { return $false }
  if ($Object -is [Collections.IDictionary]) { return $Object.Contains($Name) }
  return $Object.PSObject.Properties.Name -contains $Name
}

function Read-AgentRunEventStream {
  param(
    [Parameter(Mandatory = $true)][object]$Api,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][int]$DeadlineSeconds
  )

  Add-Type -AssemblyName System.Net.Http
  $client = [System.Net.Http.HttpClient]::new()
  $client.Timeout = [TimeSpan]::FromSeconds($DeadlineSeconds)
  $requestUri = "$($Api.ApiUri.AbsoluteUri.TrimEnd('/'))/agent/runs/$RunId/events/stream?afterSequence=0"
  $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $requestUri)
  $response = $null
  $stream = $null
  $reader = $null
  $clock = [Diagnostics.Stopwatch]::StartNew()
  $events = [Collections.Generic.List[object]]::new()
  $draftText = ''
  $terminalSeen = $false
  $connectedAtMs = $null
  try {
    [void]$request.Headers.TryAddWithoutValidation('Accept', 'text/event-stream')
    [void]$request.Headers.TryAddWithoutValidation('Authorization', "Bearer $($Api.AccessToken)")
    [void]$request.Headers.TryAddWithoutValidation('User-Agent', 'HuahuoAI-Streaming-Smoke/1.0')
    [void]$request.Headers.TryAddWithoutValidation('X-Trace-Id', 'streaming-smoke-' + [guid]::NewGuid().ToString('N'))
    [void]$request.Headers.TryAddWithoutValidation('X-Client-Version', 'streaming-smoke-1.0')
    [void]$request.Headers.TryAddWithoutValidation('X-Device-Id', $Api.DeviceId)
    [void]$request.Headers.TryAddWithoutValidation('X-Platform', 'cli')
    [void]$request.Headers.TryAddWithoutValidation('X-Locale', 'zh-CN')

    $response = $client.SendAsync(
      $request,
      [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
    ).GetAwaiter().GetResult()
    $connectedAtMs = [Math]::Round($clock.Elapsed.TotalMilliseconds, 3)
    if (-not $response.IsSuccessStatusCode) {
      $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
      throw "SSE_HTTP_FAILURE:$([int]$response.StatusCode):$body"
    }
    $contentType = Get-HuahuoString $response.Content.Headers.ContentType.MediaType
    if ($contentType -cne 'text/event-stream') {
      throw "SSE_CONTENT_TYPE_INVALID:$contentType"
    }

    $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false), $true, 4096, $true)
    $eventId = ''
    $eventName = 'message'
    $dataLines = [Collections.Generic.List[string]]::new()
    while (-not $terminalSeen) {
      $line = $reader.ReadLineAsync().GetAwaiter().GetResult()
      if ($null -eq $line) { break }
      if ($line.Length -gt 0) {
        if ($line[0] -eq ':') { continue }
        $separator = $line.IndexOf(':')
        if ($separator -lt 0) {
          $field = $line
          $value = ''
        } else {
          $field = $line.Substring(0, $separator)
          $value = $line.Substring($separator + 1)
          if ($value.StartsWith(' ')) { $value = $value.Substring(1) }
        }
        switch ($field) {
          'id' { $eventId = $value }
          'event' { $eventName = $value }
          'data' { $dataLines.Add($value) }
        }
        continue
      }

      if ($dataLines.Count -eq 0) {
        $eventId = ''
        $eventName = 'message'
        continue
      }
      $payloadRaw = $dataLines -join "`n"
      try { $payload = $payloadRaw | ConvertFrom-Json } catch { throw 'SSE_EVENT_JSON_INVALID' }
      $receivedAt = [DateTimeOffset]::UtcNow
      $elapsedMs = [Math]::Round($clock.Elapsed.TotalMilliseconds, 3)
      $eventType = Get-HuahuoString (Get-HuahuoObjectValue -Object $payload -Names @('eventType'))
      if ([string]::IsNullOrWhiteSpace($eventType)) { $eventType = $eventName }
      $status = Get-HuahuoString (Get-HuahuoObjectValue -Object $payload -Names @('status'))
      $data = Get-HuahuoObjectValue -Object $payload -Names @('data')
      $deltaText = Get-HuahuoString (Get-HuahuoObjectValue -Object $data -Names @('deltaText'))
      $replace = [bool](Get-HuahuoObjectValue -Object $data -Names @('replace'))
      if ($eventType -eq 'draft_delta' -and -not [string]::IsNullOrEmpty($deltaText)) {
        if ($replace) { $draftText = $deltaText } else { $draftText += $deltaText }
      }
      $sequence = Get-HuahuoObjectValue -Object $payload -Names @('sequence')
      $events.Add([ordered]@{
        receivedAtUtc = $receivedAt.ToString('o')
        elapsedMs = $elapsedMs
        id = $eventId
        event = $eventName
        sequence = $sequence
        eventType = $eventType
        status = $status
        deltaLength = $deltaText.Length
        replace = $replace
      })

      if ($eventName -eq 'gap' -or $eventName -eq 'error') {
        throw "SSE_TERMINATED_WITH_$($eventName.ToUpperInvariant())"
      }
      if ($eventName -eq 'terminal' -or $eventType -in @('succeeded', 'failed', 'cancelled', 'timeout') -or
        $status -in @('succeeded', 'failed', 'cancelled', 'timeout')) {
        $terminalSeen = $true
      }
      $eventId = ''
      $eventName = 'message'
      $dataLines.Clear()
    }
    if (-not $terminalSeen) { throw 'SSE_TERMINAL_EVENT_MISSING' }
    return [pscustomobject][ordered]@{
      connectedAtMs = $connectedAtMs
      contentType = $contentType
      terminalAtMs = [Math]::Round($clock.Elapsed.TotalMilliseconds, 3)
      events = @($events)
      draftText = $draftText
    }
  } finally {
    $clock.Stop()
    if ($null -ne $reader) { $reader.Dispose() }
    if ($null -ne $stream) { $stream.Dispose() }
    if ($null -ne $response) { $response.Dispose() }
    $request.Dispose()
    $client.Dispose()
  }
}

$startedAt = [DateTimeOffset]::UtcNow
$api = $null
$secondaryApi = $null
$threadId = ''
$taskId = ''
$runId = ''
$workspaceId = ''
$streamResult = $null
$runtimeSmsCode = $SmsCode
try {
  $api = New-HuahuoMinutesApiClient -ApiBase $ApiBase
  Set-HuahuoMinutesAccessToken -Api $api -AccessToken '' -Phone $Phone -SmsCode $runtimeSmsCode
  $workspaceId = Resolve-HuahuoWorkspaceId -Api $api -WorkspaceId ''

  $threadReply = Invoke-HuahuoMinutesApi -Api $api -Method POST -Path '/chat/threads' `
    -IdempotencyKey ('streaming-smoke-thread-' + [guid]::NewGuid().ToString('N')) `
    -Body ([ordered]@{ scene = 'work_ai' })
  $thread = Get-HuahuoObjectValue -Object $threadReply -Names @('thread')
  $threadId = Get-HuahuoString (Get-SmokeNestedValue -Object $thread -Paths @('threadId', 'id'))
  if ([string]::IsNullOrWhiteSpace($threadId)) { throw 'THREAD_ID_MISSING' }

  $messageReply = Invoke-HuahuoMinutesApi -Api $api -Method POST -Path "/chat/threads/$threadId/messages" `
    -IdempotencyKey ('streaming-smoke-message-' + [guid]::NewGuid().ToString('N')) `
    -Body ([ordered]@{
      agentProfileId = $AgentProfileId
      input = [ordered]@{ content = @([ordered]@{ type = 'text'; text = $Message }) }
    })
  $taskId = Get-HuahuoString (Get-SmokeNestedValue -Object $messageReply -Paths @('taskId', 'task.taskId', 'nextAction.taskId'))
  $runId = Get-HuahuoString (Get-SmokeNestedValue -Object $messageReply -Paths @('agentRunId', 'task.agentRunId'))
  if ([string]::IsNullOrWhiteSpace($taskId) -or [string]::IsNullOrWhiteSpace($runId)) {
    throw 'CHAT_ADMISSION_IDENTITIES_MISSING'
  }

  $streamResult = Read-AgentRunEventStream -Api $api -RunId $runId -DeadlineSeconds $TimeoutSeconds
  $draftEvents = @($streamResult.events | Where-Object { $_.eventType -eq 'draft_delta' -and $_.deltaLength -gt 0 })
  if ($draftEvents.Count -lt 2) { throw "STREAM_INCREMENT_COUNT_TOO_LOW:$($draftEvents.Count)" }
  $firstDraftMs = [double]$draftEvents[0].elapsedMs
  $lastDraftMs = [double]$draftEvents[-1].elapsedMs
  $draftSpanMs = [Math]::Round($lastDraftMs - $firstDraftMs, 3)
  if ($draftSpanMs -le 0) { throw 'STREAM_DELTAS_NOT_SEPARATED_IN_TIME' }

  $run = Invoke-HuahuoMinutesApi -Api $api -Method GET -Path "/agent/runs/$runId"
  $runStatus = Get-HuahuoString (Get-HuahuoObjectValue -Object $run -Names @('status'))
  if ($runStatus -ne 'succeeded') { throw "AGENT_RUN_NOT_SUCCEEDED:$runStatus" }

  $threadDetail = Invoke-HuahuoMinutesApi -Api $api -Method GET -Path "/chat/threads/$threadId"
  $assistantText = ''
  foreach ($item in @((Get-HuahuoObjectValue -Object $threadDetail -Names @('messages')))) {
    if ((Get-HuahuoString (Get-HuahuoObjectValue -Object $item -Names @('role'))) -ne 'assistant') { continue }
    $messageTaskId = Get-HuahuoString (Get-SmokeNestedValue -Object $item -Paths @('taskId', 'payload.taskId'))
    if ($messageTaskId -ne $taskId) { continue }
    $assistantText = Get-HuahuoString (Get-SmokeNestedValue -Object $item -Paths @('content', 'payload.reply', 'payload.content', 'text'))
    if (-not [string]::IsNullOrWhiteSpace($assistantText)) { break }
  }
  if ([string]::IsNullOrWhiteSpace($assistantText)) { throw 'PERSISTED_ASSISTANT_MISSING' }

  $usage = Invoke-HuahuoMinutesApi -Api $api -Method GET -Path "/workspaces/$workspaceId/storage-usage"
  $limitBytes = [int64](Get-HuahuoObjectValue -Object $usage -Names @('limitBytes'))
  if ($limitBytes -ne 32212254720) { throw "WORKSPACE_LIMIT_INVALID:$limitBytes" }
  if (-not (Test-SmokeProperty -Object $usage -Name 'fileCountLimit') -or $null -ne (Get-HuahuoObjectValue -Object $usage -Names @('fileCountLimit'))) {
    throw 'WORKSPACE_FILE_COUNT_LIMIT_NOT_NULL'
  }

  $primaryBinding = Invoke-HuahuoMinutesApi -Api $api -Method GET -Path '/recording-card/device-binding'
  if (-not (Test-SmokeProperty -Object $primaryBinding -Name 'binding')) { throw 'SN_BINDING_FIELD_MISSING' }
  $secondaryApi = New-HuahuoMinutesApiClient -ApiBase $ApiBase -AccessToken $api.AccessToken
  $secondaryBinding = Invoke-HuahuoMinutesApi -Api $secondaryApi -Method GET -Path '/recording-card/device-binding'
  if (($primaryBinding | ConvertTo-Json -Depth 16 -Compress) -cne ($secondaryBinding | ConvertTo-Json -Depth 16 -Compress)) {
    throw 'SN_BINDING_DIFFERS_ACROSS_CLIENT_DEVICES'
  }

  $deltaLengths = @($draftEvents | ForEach-Object { [int]$_.deltaLength })
  $averageDelta = [Math]::Round((($deltaLengths | Measure-Object -Average).Average), 3)
  $maximumDelta = [int](($deltaLengths | Measure-Object -Maximum).Maximum)
  $bindingView = Get-HuahuoObjectValue -Object $primaryBinding -Names @('binding')
  $evidence = [ordered]@{
    schemaVersion = 'huahuo.runtime-streaming-sn-workspace-smoke-evidence.v1'
    result = 'passed'
    authorizedHost = '39.107.250.25'
    startedAtUtc = $startedAt.ToString('o')
    completedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    threadId = $threadId
    taskId = $taskId
    agentRunId = $runId
    streaming = [ordered]@{
      eventCount = @($streamResult.events).Count
      draftEventCount = $draftEvents.Count
      connectedAtMs = $streamResult.connectedAtMs
      firstDraftAtMs = $firstDraftMs
      lastDraftAtMs = $lastDraftMs
      draftSpanMs = $draftSpanMs
      terminalAtMs = $streamResult.terminalAtMs
      totalDraftCharacters = $streamResult.draftText.Length
      averageDeltaLength = $averageDelta
      maximumDeltaLength = $maximumDelta
      multipleNonterminalDeltasAcrossTime = $true
      events = @($streamResult.events)
    }
    persistence = [ordered]@{
      runStatus = $runStatus
      assistantPresent = $true
      assistantCharacters = $assistantText.Length
      draftEqualsPersistedAssistant = ($streamResult.draftText -ceq $assistantText)
    }
    workspaceStorage = [ordered]@{
      workspaceId = $workspaceId
      userLogicalTotalBytes = [int64](Get-HuahuoObjectValue -Object $usage -Names @('userLogicalTotalBytes'))
      limitBytes = $limitBytes
      remainingBytes = [int64](Get-HuahuoObjectValue -Object $usage -Names @('remainingBytes'))
      fileCountLimit = $null
    }
    recordingCard = [ordered]@{
      bindingState = if ($null -eq $bindingView) { 'unbound' } else { 'bound' }
      crossClientDeviceProjectionEqual = $true
      claimUnbindVerification = 'not_applicable_without_device_signature_and_reauthentication_verifiers'
    }
  }
  [IO.File]::WriteAllText($EvidencePath, ($evidence | ConvertTo-Json -Depth 32) + "`n", [Text.UTF8Encoding]::new($false))
  $evidence | ConvertTo-Json -Depth 32
} catch {
  $failure = [ordered]@{
    schemaVersion = 'huahuo.runtime-streaming-sn-workspace-smoke-evidence.v1'
    result = 'failed'
    authorizedHost = '39.107.250.25'
    startedAtUtc = $startedAt.ToString('o')
    completedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    threadId = $threadId
    taskId = $taskId
    agentRunId = $runId
    failure = $_.Exception.Message
    streaming = if ($null -eq $streamResult) { $null } else { [ordered]@{ events = @($streamResult.events) } }
  }
  [IO.File]::WriteAllText($EvidencePath, ($failure | ConvertTo-Json -Depth 32) + "`n", [Text.UTF8Encoding]::new($false))
  throw
} finally {
  $runtimeSmsCode = ''
  if ($null -ne $secondaryApi) { Close-HuahuoMinutesApiClient -Api $secondaryApi }
  if ($null -ne $api) { Close-HuahuoMinutesApiClient -Api $api }
}
