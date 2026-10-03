[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Phone,
  [Parameter(Mandatory)][string]$SmsCode,
  [Parameter(Mandatory)][string]$FixtureRoot,
  [string]$BaseUrl = "http://39.107.250.25",
  [string]$VerifyExistingRunId = "",
  [ValidateRange(30, 600)][int]$IngestionTimeoutSeconds = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$target = [Uri]$BaseUrl
if ($target.Host -cne "39.107.250.25" -or $target.AbsolutePath -cne "/") {
  throw "MARKITDOWN_SMOKE_TARGET_NOT_AUTHORIZED"
}
$BaseUrl = $BaseUrl.TrimEnd("/")
$FixtureRoot = [IO.Path]::GetFullPath($FixtureRoot)
if (-not [IO.Directory]::Exists($FixtureRoot)) {
  throw "MARKITDOWN_SMOKE_FIXTURE_ROOT_MISSING"
}

function Unwrap-ApiResponse {
  param($Response)
  if ($null -ne $Response -and $Response.PSObject.Properties.Name -contains "data") {
    return $Response.data
  }
  return $Response
}

function Invoke-SmokeApi {
  param(
    [Parameter(Mandatory)][string]$Method,
    [Parameter(Mandatory)][string]$Path,
    $Body,
    [string]$AccessToken,
    [string]$IdempotencyKey
  )
  $headers = @{}
  if ($AccessToken) { $headers["Authorization"] = "Bearer $AccessToken" }
  if ($IdempotencyKey) { $headers["X-Idempotency-Key"] = $IdempotencyKey }
  try {
    $arguments = @{
      Uri = $BaseUrl + $Path
      Method = $Method
      Headers = $headers
      UseBasicParsing = $true
      TimeoutSec = 30
    }
    if ($null -ne $Body) {
      $arguments["ContentType"] = "application/json"
      $arguments["Body"] = ConvertTo-Json $Body -Depth 12 -Compress
    }
    return Unwrap-ApiResponse (Invoke-RestMethod @arguments)
  } catch {
    $httpStatus = "unknown"
    $errorCode = "unknown"
    if ($_.Exception.Response) {
      try { $httpStatus = [int]$_.Exception.Response.StatusCode } catch {}
    }
    if ($_.ErrorDetails.Message) {
      try {
        $errorBody = ConvertFrom-Json $_.ErrorDetails.Message
        if ($errorBody.error.code) { $errorCode = [string]$errorBody.error.code }
        elseif ($errorBody.errorCode) { $errorCode = [string]$errorBody.errorCode }
      } catch {}
    }
    throw "MARKITDOWN_SMOKE_API_FAILED:${Method}:${Path}:http=${httpStatus}:code=${errorCode}"
  }
}

function Write-SmokeUploadObject {
  param($Upload, [Parameter(Mandatory)][string]$FilePath)
  $headers = @{}
  $contentType = $null
  if ($Upload.headers) {
    foreach ($property in $Upload.headers.PSObject.Properties) {
      if ($property.Name -ieq "Content-Type") { $contentType = [string]$property.Value }
      else { $headers[$property.Name] = [string]$property.Value }
    }
  }
  $method = [string]$Upload.method
  if (-not $method) { $method = "PUT" }
  $arguments = @{
    Uri = [string]$Upload.uploadUrl
    Method = $method
    Headers = $headers
    InFile = $FilePath
    UseBasicParsing = $true
    TimeoutSec = 60
  }
  if ($contentType) { $arguments["ContentType"] = $contentType }
  try {
    $response = Invoke-WebRequest @arguments
    if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300) {
      throw "object upload returned non-success"
    }
  } catch {
    throw "MARKITDOWN_SMOKE_OBJECT_UPLOAD_FAILED"
  }
}

function New-TextFixtures {
  param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$RunMarker)
  [IO.Directory]::CreateDirectory($Root) | Out-Null
  $utf8 = New-Object Text.UTF8Encoding($false)
  $files = [ordered]@{
    text = Join-Path $Root "smoke.txt"
    markdown = Join-Path $Root "smoke.md"
    csv = Join-Path $Root "smoke.csv"
    json = Join-Path $Root "smoke.json"
  }
  [IO.File]::WriteAllText($files.text, "${RunMarker}_TEXT`nPlain text conversion smoke.", $utf8)
  [IO.File]::WriteAllText($files.markdown, "# ${RunMarker}_MARKDOWN`n`nMarkdown conversion smoke.", $utf8)
  [IO.File]::WriteAllText($files.csv, "name,value`nmarker,${RunMarker}_CSV`n", $utf8)
  [IO.File]::WriteAllText($files.json, "{`"marker`":`"${RunMarker}_JSON`",`"valid`":true}", $utf8)
  return $files
}

function Get-RequiredFixture {
  param([Parameter(Mandatory)][string]$Name)
  $path = Join-Path $FixtureRoot $Name
  if (-not [IO.File]::Exists($path)) { throw "MARKITDOWN_SMOKE_FIXTURE_MISSING:$Name" }
  return $path
}

function Invoke-FileCase {
  param(
    [Parameter(Mandatory)]$Case,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$WorkspaceId,
    [Parameter(Mandatory)][string]$RunId
  )
  $file = Get-Item -LiteralPath $Case.path
  $digest = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  $caseKey = $RunId + "-" + $Case.id
  $upload = Invoke-SmokeApi -Method "POST" -Path "/api/v1/media/upload-token" -Body ([ordered]@{
    sourceScene = "note_import"
    fileName = $file.Name
    mimeType = $Case.mimeType
    sizeBytes = [int64]$file.Length
    sha256 = $digest
  }) -AccessToken $AccessToken -IdempotencyKey ("markitdown-smoke-upload-" + $caseKey)
  if (-not $upload.uploadId -or -not $upload.resourceId -or -not $upload.uploadUrl) {
    throw "MARKITDOWN_SMOKE_UPLOAD_TOKEN_INCOMPLETE"
  }
  Write-SmokeUploadObject -Upload $upload -FilePath $file.FullName
  $complete = Invoke-SmokeApi -Method "POST" -Path ("/api/v1/media/uploads/" + $upload.uploadId + "/complete") -Body @{} -AccessToken $AccessToken -IdempotencyKey ("markitdown-smoke-complete-" + $caseKey)
  if ($complete.resource.resourceId -and [string]$complete.resource.resourceId -cne [string]$upload.resourceId) {
    throw "MARKITDOWN_SMOKE_RESOURCE_ID_MISMATCH"
  }

  $created = Invoke-SmokeApi -Method "POST" -Path ("/api/v1/workspaces/" + $WorkspaceId + "/note-ingestions") -Body @{ resourceId = [string]$upload.resourceId } -AccessToken $AccessToken -IdempotencyKey ("markitdown-smoke-ingestion-" + $caseKey)
  $ingestionId = [string]$created.ingestion.ingestionId
  $status = [string]$created.ingestion.status
  if (-not $ingestionId) { throw "MARKITDOWN_SMOKE_INGESTION_INCOMPLETE" }
  $deadline = [DateTime]::UtcNow.AddSeconds($IngestionTimeoutSeconds)
  while ($status -notin @("ready_to_promote", "failed", "quarantined", "expired", "promoted") -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Seconds 2
    $state = Invoke-SmokeApi -Method "GET" -Path ("/api/v1/workspaces/" + $WorkspaceId + "/note-ingestions/" + $ingestionId) -Body $null -AccessToken $AccessToken
    $status = [string]$state.ingestion.status
  }
  if ($status -cne "ready_to_promote") { throw "MARKITDOWN_SMOKE_INGESTION_NOT_READY:$status" }

  $title = "[Smoke] MarkItDown " + $Case.id.ToUpperInvariant() + " " + $RunId
  $promoted = Invoke-SmokeApi -Method "POST" -Path ("/api/v1/workspaces/" + $WorkspaceId + "/note-ingestions/" + $ingestionId + "/promote") -Body @{ title = $title } -AccessToken $AccessToken -IdempotencyKey ("markitdown-smoke-promote-" + $caseKey)
  $noteId = [string]$promoted.note.noteId
  if (-not $noteId) { throw "MARKITDOWN_SMOKE_PROMOTION_INCOMPLETE" }
  $raw = Invoke-SmokeApi -Method "GET" -Path ("/api/v1/workspaces/" + $WorkspaceId + "/notes/" + $noteId + "/parts/raw") -Body $null -AccessToken $AccessToken
  $content = [string]$raw.contentMarkdown
  if (-not $content -and $raw.part) { $content = [string]$raw.part.contentMarkdown }
  if (-not $content) { throw "MARKITDOWN_SMOKE_RAW_EMPTY" }
  $missing = @($Case.mustInclude | Where-Object { -not $content.Contains([string]$_) })
  if ($missing.Count -gt 0) { throw "MARKITDOWN_SMOKE_RAW_MARKER_MISSING:$($Case.id):$($missing.Count)" }
  return [ordered]@{
    fileType = $Case.id
    mimeType = $Case.mimeType
    status = "passed"
    ingestionStatus = $status
    rawLength = $content.Length
    assertedMarkerCount = @($Case.mustInclude).Count
    noteTitle = $title
  }
}

function Invoke-ExistingCaseVerification {
  param(
    [Parameter(Mandatory)]$Case,
    [Parameter(Mandatory)]$Notes,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$WorkspaceId,
    [Parameter(Mandatory)][string]$RunId
  )
  $title = "[Smoke] MarkItDown " + $Case.id.ToUpperInvariant() + " " + $RunId
  $matches = @($Notes | Where-Object { [string]$_.title -ceq $title })
  if ($matches.Count -ne 1 -or -not $matches[0].noteId) {
    throw "MARKITDOWN_SMOKE_EXISTING_NOTE_INVALID:$($Case.id):$($matches.Count)"
  }
  $raw = Invoke-SmokeApi -Method "GET" -Path ("/api/v1/workspaces/" + $WorkspaceId + "/notes/" + $matches[0].noteId + "/parts/raw") -Body $null -AccessToken $AccessToken
  $content = [string]$raw.contentMarkdown
  if (-not $content -and $raw.part) { $content = [string]$raw.part.contentMarkdown }
  if (-not $content) { throw "MARKITDOWN_SMOKE_RAW_EMPTY" }
  $missing = @($Case.mustInclude | Where-Object { -not $content.Contains([string]$_) })
  if ($missing.Count -gt 0) { throw "MARKITDOWN_SMOKE_RAW_MARKER_MISSING:$($Case.id):$($missing.Count)" }
  return [ordered]@{
    fileType = $Case.id
    mimeType = $Case.mimeType
    status = "passed"
    ingestionStatus = "promoted"
    rawLength = $content.Length
    assertedMarkerCount = @($Case.mustInclude).Count
    noteTitle = $title
  }
}

$startedAt = [DateTime]::UtcNow
$runId = $startedAt.ToString("yyyyMMddTHHmmssZ")
if ($VerifyExistingRunId) {
  if ($VerifyExistingRunId -cnotmatch '^[0-9]{8}T[0-9]{6}Z$') {
    throw "MARKITDOWN_SMOKE_EXISTING_RUN_ID_INVALID"
  }
  $runId = $VerifyExistingRunId
}
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("huahuo-markitdown-smoke-" + [Guid]::NewGuid().ToString("N"))
$results = New-Object System.Collections.Generic.List[object]
try {
  $login = Invoke-SmokeApi -Method "POST" -Path "/api/v1/auth/login" -Body ([ordered]@{
    phone = $Phone
    smsCode = $SmsCode
    deviceId = "markitdown-note-import-product-smoke"
    agreementAccepted = $true
    agreementVersion = "v0.1"
    privacyVersion = "v0.1"
    clientVersion = "markitdown-note-import-product-smoke-v1"
    timeZone = "Asia/Shanghai"
  })
  $accessToken = [string]$login.accessToken
  $workspaceId = [string]$login.workspace.workspaceId
  if (-not $accessToken -or -not $workspaceId) { throw "MARKITDOWN_SMOKE_LOGIN_INCOMPLETE" }

  $generated = New-TextFixtures -Root $temporaryRoot -RunMarker ("HUAHUO_" + $runId)
  $cases = @(
    [ordered]@{ id = "txt"; path = $generated.text; mimeType = "text/plain"; mustInclude = @("HUAHUO_${runId}_TEXT", "Plain text conversion smoke") },
    [ordered]@{ id = "md"; path = $generated.markdown; mimeType = "text/markdown"; mustInclude = @("HUAHUO_${runId}_MARKDOWN", "Markdown conversion smoke") },
    [ordered]@{ id = "csv"; path = $generated.csv; mimeType = "text/csv"; mustInclude = @("HUAHUO_${runId}_CSV") },
    [ordered]@{ id = "json"; path = $generated.json; mimeType = "application/json"; mustInclude = @("HUAHUO_${runId}_JSON") },
    [ordered]@{ id = "pdf"; path = Get-RequiredFixture "test.pdf"; mimeType = "application/pdf"; mustInclude = @("While there is contemporaneous exploration of multi-agent approaches") },
    [ordered]@{ id = "docx"; path = Get-RequiredFixture "test.docx"; mimeType = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"; mustInclude = @("AutoGen: Enabling Next-Gen LLM Applications via Multi-Agent Conversation", "Introduction") },
    [ordered]@{ id = "pptx"; path = Get-RequiredFixture "test.pptx"; mimeType = "application/vnd.openxmlformats-officedocument.presentationml.presentation"; mustInclude = @("AutoGen: Enabling Next-Gen LLM Applications via Multi-Agent Conversation", "2cdda5c8-e50e-4db4-b5f0-9722a649f455") },
    [ordered]@{ id = "xlsx"; path = Get-RequiredFixture "test.xlsx"; mimeType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"; mustInclude = @("09060124-b5e7-4717-9d07-3c046eb", "6ff4173b-42a5-4784-9b19-f49caff4d93d") }
  )
  $existingNotes = $null
  if ($VerifyExistingRunId) {
    $notePage = Invoke-SmokeApi -Method "GET" -Path ("/api/v1/workspaces/" + $workspaceId + "/notes") -Body $null -AccessToken $accessToken
    $existingNotes = @($notePage.items)
  }
  foreach ($case in $cases) {
    try {
      if ($VerifyExistingRunId) {
        $results.Add((Invoke-ExistingCaseVerification -Case $case -Notes $existingNotes -AccessToken $accessToken -WorkspaceId $workspaceId -RunId $runId))
      } else {
        $results.Add((Invoke-FileCase -Case $case -AccessToken $accessToken -WorkspaceId $workspaceId -RunId $runId))
      }
    } catch {
      $results.Add([ordered]@{
        fileType = $case.id
        mimeType = $case.mimeType
        status = "failed"
        error = $_.Exception.Message
      })
    }
  }
} finally {
  if ([IO.Directory]::Exists($temporaryRoot)) {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
  }
}

$failed = @($results | Where-Object { $_.status -cne "passed" })
$report = [ordered]@{
  schemaVersion = "huahuo.markitdown-note-import-product-smoke.v1"
  target = "authorized-host-39"
  startedAtUtc = $startedAt.ToString("o")
  completedAtUtc = [DateTime]::UtcNow.ToString("o")
  status = if ($failed.Count -eq 0) { "passed" } else { "failed" }
  passedCount = @($results | Where-Object { $_.status -ceq "passed" }).Count
  failedCount = $failed.Count
  results = $results.ToArray()
}
ConvertTo-Json $report -Depth 12
if ($failed.Count -gt 0) { throw "MARKITDOWN_SMOKE_FAILED:$($failed.Count)" }
