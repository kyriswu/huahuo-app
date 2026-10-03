param(
  [string]$BaseUri = 'https://chuda.cc',
  [Parameter(Mandatory = $true)][string]$AudioPath,
  [Parameter(Mandatory = $true)][string]$VoiceprintPath,
  [Parameter(Mandatory = $true)][string]$ReportPath,
  [ValidateRange(1, 86400)][int]$DurationSeconds = 1745,
  [ValidateRange(60, 3600)][int]$TimeoutSeconds = 2400,
  [ValidateRange(5, 60)][int]$PollIntervalSeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

$phone = [string]$env:HUAHUO_SMOKE_PHONE
$smsCode = [string]$env:HUAHUO_SMOKE_SMS_CODE
if ([string]::IsNullOrWhiteSpace($phone) -or [string]::IsNullOrWhiteSpace($smsCode)) {
  throw 'SMOKE_LOGIN_ENV_MISSING'
}

$audio = Get-Item -LiteralPath $AudioPath -ErrorAction Stop
$voiceprint = Get-Item -LiteralPath $VoiceprintPath -ErrorAction Stop
if ($audio.Length -lt 1 -or $voiceprint.Length -lt 44 -or $voiceprint.Length -gt 2MB) {
  throw 'SMOKE_AUDIO_INVALID'
}

$base = $BaseUri.TrimEnd('/')
$trace = 'recording-new-sample-' + [Guid]::NewGuid().ToString('N')
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(150)
$accessToken = ''
$profileId = ''
$profileDeleted = $false

function Get-EnvelopeData {
  param($Response)
  if ($null -ne $Response.Json -and $null -ne $Response.Json.data) {
    return $Response.Json.data
  }
  return $Response.Json
}

function Invoke-HuahuoRequest {
  param(
    [ValidateSet('GET', 'POST', 'PUT', 'DELETE')][string]$Method,
    [string]$Target,
    [AllowNull()]$Body,
    [AllowNull()][byte[]]$Bytes,
    [hashtable]$Headers = @{},
    [int[]]$Expected = @(200),
    [switch]$Anonymous
  )
  $uri = if ($Target -match '^https?://') { $Target } else { $base + '/' + $Target.TrimStart('/') }
  $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $uri)
  try {
    if (-not $Anonymous -and $accessToken) {
      $request.Headers.TryAddWithoutValidation('Authorization', 'Bearer ' + $accessToken) | Out-Null
    }
    $request.Headers.TryAddWithoutValidation('X-Trace-Id', $trace + '-' + [Guid]::NewGuid().ToString('N')) | Out-Null
    if ($null -ne $Bytes) {
      $request.Content = [System.Net.Http.ByteArrayContent]::new($Bytes)
    } elseif ($null -ne $Body) {
      $jsonBody = $Body | ConvertTo-Json -Depth 20 -Compress
      $request.Content = [System.Net.Http.StringContent]::new($jsonBody, [Text.Encoding]::UTF8, 'application/json')
    }
    foreach ($name in $Headers.Keys) {
      if ($name -ieq 'Content-Type' -and $null -ne $request.Content) {
        $request.Content.Headers.Remove('Content-Type') | Out-Null
        $request.Content.Headers.TryAddWithoutValidation('Content-Type', [string]$Headers[$name]) | Out-Null
      } else {
        $request.Headers.TryAddWithoutValidation([string]$name, [string]$Headers[$name]) | Out-Null
      }
    }
    $response = $client.SendAsync($request).GetAwaiter().GetResult()
    try {
      $raw = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
      $json = $null
      if ($raw) {
        try { $json = $raw | ConvertFrom-Json } catch { }
      }
      $status = [int]$response.StatusCode
      if ($status -notin $Expected) {
        $remoteCode = ''
        if ($null -ne $json -and $null -ne $json.error) {
          $remoteCode = [string]$json.error.code
        }
        throw "HTTP_${status}:${remoteCode}"
      }
      $responseHeaders = @{}
      foreach ($header in $response.Headers) { $responseHeaders[$header.Key] = $header.Value -join ',' }
      foreach ($header in $response.Content.Headers) { $responseHeaders[$header.Key] = $header.Value -join ',' }
      return [pscustomobject]@{ StatusCode = $status; Json = $json; Headers = $responseHeaders }
    } finally {
      $response.Dispose()
    }
  } finally {
    $request.Dispose()
  }
}

function New-IdempotencyKey {
  param([string]$Operation)
  return 'recording-new-sample-' + $Operation + '-' + [Guid]::NewGuid().ToString('N')
}

try {
  $loginBody = @{
    phone = $phone
    smsCode = $smsCode
    smsRequestId = 'sms-bypass-' + [Guid]::NewGuid().ToString('N')
    deviceId = $trace + '-device'
    agreementAccepted = $true
    agreementVersion = 'v0.1'
    privacyVersion = 'v0.1'
    clientVersion = 'recording-full-chain-smoke'
    timeZone = 'Asia/Shanghai'
  }
  $login = Get-EnvelopeData (Invoke-HuahuoRequest POST '/api/v1/auth/login' $loginBody $null @{} @(200) -Anonymous)
  $accessToken = [string]$login.accessToken
  $userId = [string]$login.userId
  $workspaceId = [string]$login.workspaceId
  if (-not $workspaceId -and $null -ne $login.workspace) { $workspaceId = [string]$login.workspace.workspaceId }
  if (-not $accessToken -or -not $userId -or -not $workspaceId) { throw 'SMOKE_LOGIN_INVALID' }
  Write-Output 'stage=login status=succeeded'

  $voiceHeaders = @{
    'X-Idempotency-Key' = New-IdempotencyKey 'voiceprint-enroll'
    'X-Speaker-Display-Name' = [Uri]::EscapeDataString('New Sample Speaker')
    'X-Speaker-Nick' = 'new_sample_speaker'
    'X-Consent-Version' = 'v1'
    'Content-Type' = 'audio/wav'
  }
  $enrolled = Get-EnvelopeData (Invoke-HuahuoRequest POST '/voice-gateway/v1/voiceprints' $null ([IO.File]::ReadAllBytes($voiceprint.FullName)) $voiceHeaders @(200, 201))
  $profileId = [string]$enrolled.profile.profileId
  if (-not $profileId -or [string]$enrolled.profile.status -ne 'active') { throw 'SMOKE_VOICEPRINT_INVALID' }
  Write-Output 'stage=voiceprint status=succeeded'

  $uploadBody = @{
    sourceScene = 'raw_material'
    workspaceId = $workspaceId
    fileName = $audio.Name
    mimeType = 'audio/mp4'
    sizeBytes = $audio.Length
    durationSeconds = $DurationSeconds
    sha256 = (Get-FileHash -LiteralPath $audio.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  $uploadToken = Get-EnvelopeData (Invoke-HuahuoRequest POST '/api/v1/media/upload-token' $uploadBody $null @{
      'X-Idempotency-Key' = New-IdempotencyKey 'upload-token'
    } @(200))
  $uploadId = [string]$uploadToken.uploadId
  $resourceId = [string]$uploadToken.resourceId
  $uploadUrl = [string]$uploadToken.uploadUrl
  if (-not $uploadId -or -not $resourceId -or -not $uploadUrl) { throw 'SMOKE_UPLOAD_TOKEN_INVALID' }
  $putHeaders = @{}
  if ($null -ne $uploadToken.headers) {
    foreach ($property in $uploadToken.headers.PSObject.Properties) { $putHeaders[$property.Name] = [string]$property.Value }
  }
  if (-not $putHeaders.ContainsKey('Content-Type')) { $putHeaders['Content-Type'] = 'audio/mp4' }
  [void](Invoke-HuahuoRequest PUT $uploadUrl $null ([IO.File]::ReadAllBytes($audio.FullName)) $putHeaders @(200, 201, 204) -Anonymous)
  $completed = Get-EnvelopeData (Invoke-HuahuoRequest POST ("/api/v1/media/uploads/{0}/complete" -f [Uri]::EscapeDataString($uploadId)) @{ workspaceId = $workspaceId } $null @{
      'X-Idempotency-Key' = New-IdempotencyKey 'upload-complete'
    } @(200))
  if ([string]$completed.resource.resourceId -ne $resourceId) { throw 'SMOKE_UPLOAD_COMPLETE_INVALID' }
  Write-Output 'stage=upload status=succeeded'

  $recordingCreated = Get-EnvelopeData (Invoke-HuahuoRequest POST '/api/v1/recordings' @{
      audioResourceId = $resourceId
      title = 'New recording full-chain smoke 2026-08-09'
      source = 'local_upload'
    } $null @{ 'X-Idempotency-Key' = New-IdempotencyKey 'recording-create' } @(200))
  $recordingId = [string]$recordingCreated.recording.recordingId
  $asrTaskId = [string]$recordingCreated.asrTask.asrTaskId
  if (-not $recordingId -or -not $asrTaskId) { throw 'SMOKE_RECORDING_CREATE_INVALID' }
  Write-Output "stage=recording-create status=succeeded recordingId=$recordingId"

  $asrStatus = ''
  while ([DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Seconds $PollIntervalSeconds
    $asr = Get-EnvelopeData (Invoke-HuahuoRequest GET ("/api/v1/asr-tasks/{0}" -f [Uri]::EscapeDataString($asrTaskId)) $null $null @{} @(200))
    $asrStatus = [string]$asr.asrTask.status
    Write-Output "stage=asr status=$asrStatus"
    if ($asrStatus -in @('transcribed', 'final_transcript_generated', 'failed', 'timeout')) { break }
  }
  if ($asrStatus -notin @('transcribed', 'final_transcript_generated')) { throw "SMOKE_ASR_TERMINAL:$asrStatus" }

  $detail = $null
  while ([DateTime]::UtcNow -lt $deadline) {
    $detail = Get-EnvelopeData (Invoke-HuahuoRequest GET ("/api/v1/recordings/{0}" -f [Uri]::EscapeDataString($recordingId)) $null $null @{} @(200))
    $transcriptStatus = [string]$detail.recording.transcriptStatus
    $minutesStatus = [string]$detail.recording.minutesStatus
    $summaryStatus = [string]$detail.recording.summaryStatus
    $depositStatus = [string]$detail.recording.depositStatus
    Write-Output "stage=recording transcript=$transcriptStatus minutes=$minutesStatus summary=$summaryStatus deposit=$depositStatus"
    if ($transcriptStatus -eq 'final_transcript_generated' -and $minutesStatus -eq 'succeeded' -and $summaryStatus -eq 'succeeded' -and $depositStatus -eq 'deposited') { break }
    if ($transcriptStatus -in @('failed', 'timeout') -or $minutesStatus -in @('failed', 'timeout') -or $summaryStatus -in @('failed', 'timeout') -or $depositStatus -in @('failed', 'timeout')) {
      throw "SMOKE_RECORDING_TERMINAL:$transcriptStatus/$minutesStatus/$summaryStatus/$depositStatus"
    }
    Start-Sleep -Seconds $PollIntervalSeconds
  }
  if ($null -eq $detail -or [string]$detail.recording.depositStatus -ne 'deposited') { throw 'SMOKE_RECORDING_TIMEOUT' }

  $noteId = [string]$detail.recording.noteId
  if (-not $noteId) { throw 'SMOKE_NOTE_ID_MISSING' }
  $rawPart = Get-EnvelopeData (Invoke-HuahuoRequest GET ("/api/v1/workspaces/{0}/notes/{1}/parts/raw" -f [Uri]::EscapeDataString($workspaceId), [Uri]::EscapeDataString($noteId)) $null $null @{} @(200))
  $outlinePart = Get-EnvelopeData (Invoke-HuahuoRequest GET ("/api/v1/workspaces/{0}/notes/{1}/parts/outline" -f [Uri]::EscapeDataString($workspaceId), [Uri]::EscapeDataString($noteId)) $null $null @{} @(200))
  if (-not [string]$rawPart.contentMarkdown -or -not [string]$outlinePart.contentMarkdown) { throw 'SMOKE_NOTE_CONTENT_MISSING' }

  $speakerNames = @{}
  if ($null -ne $detail.transcript.speakerNameMap) {
    foreach ($property in $detail.transcript.speakerNameMap.PSObject.Properties) { $speakerNames[$property.Name] = [string]$property.Value }
  }
  $identityMatches = @()
  foreach ($match in @($detail.transcript.speakerIdentityMatches)) {
    if ($null -ne $match) {
      $identityMatches += [ordered]@{ speakerId = [string]$match.speakerId; score = $match.score }
    }
  }
  $report = [ordered]@{
    schemaVersion = 'huahuo.recording-new-sample-full-chain.v1'
    authorizedHost = '39.107.250.25'
    traceId = $trace
    input = [ordered]@{ fileName = $audio.Name; sizeBytes = $audio.Length; durationSeconds = $DurationSeconds }
    ids = [ordered]@{ recordingId = $recordingId; asrTaskId = $asrTaskId; noteId = $noteId }
    statuses = [ordered]@{
      asr = $asrStatus
      transcript = [string]$detail.recording.transcriptStatus
      minutes = [string]$detail.recording.minutesStatus
      summary = [string]$detail.recording.summaryStatus
      deposit = [string]$detail.recording.depositStatus
    }
    voiceprint = [ordered]@{
      selfSpeakerId = [string]$detail.transcript.selfSpeakerId
      speakerNameMap = $speakerNames
      identityMatches = $identityMatches
      speakerSegmentCount = @($detail.transcript.speakerSegments).Count
    }
    output = [ordered]@{
      finalTranscript = [string]$detail.transcript.finalTranscript
      minutes = $detail.generatedAssets.minutes
      minutesMarkdown = [string]$detail.generatedAssets.minutesMarkdown
      summary = [string]$detail.generatedAssets.summary
      noteRawMarkdown = [string]$rawPart.contentMarkdown
      noteOutlineMarkdown = [string]$outlinePart.contentMarkdown
    }
    completedAtUtc = [DateTime]::UtcNow.ToString('o')
  }
  $fullReportPath = [IO.Path]::GetFullPath($ReportPath)
  [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullReportPath)) | Out-Null
  [IO.File]::WriteAllText($fullReportPath, (($report | ConvertTo-Json -Depth 30) + "`n"), [Text.UTF8Encoding]::new($false))
  Write-Output "stage=complete status=succeeded report=$fullReportPath"
} finally {
  if ($profileId -and $accessToken) {
    try {
      [void](Invoke-HuahuoRequest DELETE ("/voice-gateway/v1/voiceprints/{0}" -f [Uri]::EscapeDataString($profileId)) $null $null @{
          'X-Idempotency-Key' = New-IdempotencyKey 'voiceprint-delete'
        } @(200))
      $profileDeleted = $true
      Write-Output 'stage=voiceprint-cleanup status=succeeded'
    } catch {
      Write-Output 'stage=voiceprint-cleanup status=failed'
    }
  }
  $client.Dispose()
}
