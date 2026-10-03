[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$AccessToken,
  [Parameter(Mandatory)][string]$WorkspaceId,
  [Parameter(Mandatory)][string]$SshIdentityFile,
  [string]$BaseUrl = "http://39.107.250.25",
  [string]$EvidencePath = "",
  [ValidateRange(30, 600)][int]$IngestionTimeoutSeconds = 240
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$target = [Uri]$BaseUrl
if ($target.Host -cne "39.107.250.25" -or $target.Scheme -notin @("http", "https") -or
  $target.AbsolutePath -cne "/" -or $target.Query -ne "" -or $target.UserInfo -ne "") {
  throw "URL_TO_HNOTE_SMOKE_TARGET_NOT_AUTHORIZED"
}
$BaseUrl = $BaseUrl.TrimEnd("/")
if ([string]::IsNullOrWhiteSpace($WorkspaceId) -or $WorkspaceId.IndexOfAny(@([char]13, [char]10)) -ge 0) {
  throw "URL_TO_HNOTE_SMOKE_WORKSPACE_INVALID"
}
$AccessToken = $AccessToken.Trim()
if ([string]::IsNullOrWhiteSpace($AccessToken) -or $AccessToken.IndexOfAny(@([char]13, [char]10)) -ge 0) {
  throw "URL_TO_HNOTE_SMOKE_TOKEN_INVALID"
}
if (-not (Test-Path -LiteralPath $SshIdentityFile -PathType Leaf)) {
  throw "URL_TO_HNOTE_SMOKE_SSH_IDENTITY_MISSING"
}
$authorization = if ($AccessToken.StartsWith("Bearer ", [StringComparison]::OrdinalIgnoreCase)) {
  $AccessToken
} else {
  "Bearer $AccessToken"
}
$AccessToken = ""

function Get-SmokeProperty {
  param($Object, [Parameter(Mandatory)][string]$Name)
  if ($null -eq $Object) { return $null }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) { return $null }
  return $property.Value
}

function Unwrap-SmokeResponse {
  param($Response)
  $success = Get-SmokeProperty -Object $Response -Name "success"
  if ($null -ne $success -and $success -ne $true) {
    throw "URL_TO_HNOTE_SMOKE_API_ENVELOPE_FAILED"
  }
  $data = Get-SmokeProperty -Object $Response -Name "data"
  if ($null -ne $data) { return $data }
  return $Response
}

function Invoke-SmokeApi {
  param(
    [Parameter(Mandatory)][ValidateSet("GET", "POST")][string]$Method,
    [Parameter(Mandatory)][string]$Path,
    [AllowNull()]$Body = $null,
    [string]$IdempotencyKey = ""
  )
  $headers = @{
    Accept = "application/json"
    Authorization = $authorization
    "X-Trace-Id" = "url-to-hnote-smoke-$([Guid]::NewGuid().ToString('N'))"
  }
  if ($IdempotencyKey) { $headers["X-Idempotency-Key"] = $IdempotencyKey }
  $arguments = @{
    Uri = $BaseUrl + $Path
    Method = $Method
    Headers = $headers
    UseBasicParsing = $true
    TimeoutSec = 45
  }
  if ($null -ne $Body) {
    $arguments.ContentType = "application/json"
    $arguments.Body = ConvertTo-Json $Body -Depth 8 -Compress
  }
  try {
    return Unwrap-SmokeResponse (Invoke-RestMethod @arguments)
  } catch {
    $status = "unknown"
    $code = "unknown"
    if ($_.Exception.Response) {
      try { $status = [int]$_.Exception.Response.StatusCode } catch {}
    }
    if ($_.ErrorDetails.Message) {
      try {
        $errorBody = ConvertFrom-Json $_.ErrorDetails.Message
        $error = Get-SmokeProperty -Object $errorBody -Name "error"
        $candidate = Get-SmokeProperty -Object $error -Name "code"
        if ($candidate) { $code = [string]$candidate }
      } catch {}
    }
    throw "URL_TO_HNOTE_SMOKE_API_FAILED:${Method}:http=${status}:code=${code}"
  }
}

function New-URLIngestion {
  param([Parameter(Mandatory)][string]$SourceUrl, [Parameter(Mandatory)][string]$CaseId)
  $body = [ordered]@{ url = $SourceUrl }
  if (@($body.Keys).Count -ne 1 -or @($body.Keys)[0] -cne "url") {
    throw "URL_TO_HNOTE_SMOKE_REQUEST_FIELDS_INVALID"
  }
  $path = "/api/v1/workspaces/$([Uri]::EscapeDataString($WorkspaceId))/note-ingestions"
  $response = Invoke-SmokeApi -Method POST -Path $path -Body $body -IdempotencyKey "url-to-hnote-smoke-$CaseId"
  $ingestion = Get-SmokeProperty -Object $response -Name "ingestion"
  if ($null -eq $ingestion -or [string]::IsNullOrWhiteSpace([string]$ingestion.ingestionId)) {
    throw "URL_TO_HNOTE_SMOKE_CREATE_INCOMPLETE"
  }
  return $ingestion
}

function Wait-URLIngestion {
  param([Parameter(Mandatory)]$Initial)
  $ingestion = $Initial
  $deadline = [DateTime]::UtcNow.AddSeconds($IngestionTimeoutSeconds)
  $terminal = @("promoted", "failed", "quarantined", "expired")
  while ([string]$ingestion.status -notin $terminal -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Seconds 2
    $path = "/api/v1/workspaces/$([Uri]::EscapeDataString($WorkspaceId))/note-ingestions/$([Uri]::EscapeDataString([string]$ingestion.ingestionId))"
    $response = Invoke-SmokeApi -Method GET -Path $path
    $ingestion = Get-SmokeProperty -Object $response -Name "ingestion"
    if ($null -eq $ingestion) { throw "URL_TO_HNOTE_SMOKE_POLL_INCOMPLETE" }
  }
  if ([string]$ingestion.status -notin $terminal) {
    throw "URL_TO_HNOTE_SMOKE_TIMEOUT"
  }
  return $ingestion
}

function Get-URLHNote {
  param([Parameter(Mandatory)][string]$NoteId)
  $path = "/api/v1/workspaces/$([Uri]::EscapeDataString($WorkspaceId))/notes/$([Uri]::EscapeDataString($NoteId))"
  $response = Invoke-SmokeApi -Method GET -Path $path
  $nested = Get-SmokeProperty -Object $response -Name "note"
  if ($null -ne $nested) { return $nested }
  return $response
}

function Get-URLHNoteRawPart {
  param([Parameter(Mandatory)][string]$NoteId)
  $path = "/api/v1/workspaces/$([Uri]::EscapeDataString($WorkspaceId))/notes/$([Uri]::EscapeDataString($NoteId))/parts/raw"
  return Invoke-SmokeApi -Method GET -Path $path
}

function Assert-URLWorkerConfiguration {
  $remoteScript = @'
set -euo pipefail
unit='huahuo-worker.service'
pid=$(systemctl show -p MainPID --value "$unit")
test -n "$pid" && test "$pid" -gt 1
environment_path="/proc/$pid/environ"
test -r "$environment_path"
categories=$(tr '\0' '\n' < "$environment_path" | sed -n 's/^WORKER_CATEGORIES=//p' | tail -n 1)
workers=$(tr '\0' '\n' < "$environment_path" | sed -n 's/^HUAHUO_URL_NOTE_IMPORT_WORKERS=//p' | tail -n 1)
case ",$categories," in
  *,note_url_import,*) ;;
  *) exit 41 ;;
esac
test "$workers" = '24'
printf '{"unit":"huahuo-worker.service","category":"note_url_import","workers":24}\n'
'@
  $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remoteScript.Replace("`r", "")))
  $output = & ssh -i $SshIdentityFile -o BatchMode=yes -o ConnectTimeout=10 "root@39.107.250.25" "echo $payload | base64 -d | bash" 2>&1
  if ($LASTEXITCODE -ne 0) { throw "URL_TO_HNOTE_SMOKE_WORKER_CONFIG_INVALID" }
  try {
    return ($output -join "`n") | ConvertFrom-Json
  } catch {
    throw "URL_TO_HNOTE_SMOKE_WORKER_CONFIG_INVALID"
  }
}

$startedAt = [DateTime]::UtcNow
$nonce = [Guid]::NewGuid().ToString("N")
$publicUrl = "https://example.com/?huahuo_smoke=$nonce"
$privateUrl = "http://127.0.0.1/?huahuo_smoke=$nonce"

try {
  $publicIngestion = Wait-URLIngestion -Initial (New-URLIngestion -SourceUrl $publicUrl -CaseId "public-$nonce")
  if ([string]$publicIngestion.status -cne "promoted" -or [string]::IsNullOrWhiteSpace([string]$publicIngestion.promotedNoteId)) {
    throw "URL_TO_HNOTE_SMOKE_PUBLIC_NOT_PROMOTED:$([string]$publicIngestion.status)"
  }
  $note = Get-URLHNote -NoteId ([string]$publicIngestion.promotedNoteId)
  if ([string]$note.noteId -cne [string]$publicIngestion.promotedNoteId -or [string]$note.sourceKind -cne "url_import") {
    throw "URL_TO_HNOTE_SMOKE_NOTE_INVALID"
  }
  $raw = Get-URLHNoteRawPart -NoteId ([string]$publicIngestion.promotedNoteId)
  $content = [string](Get-SmokeProperty -Object $raw -Name "contentMarkdown")
  if ([string]::IsNullOrWhiteSpace($content) -or
    $content.IndexOf($publicUrl, [StringComparison]::Ordinal) -lt 0 -or
    $content.IndexOf("Example Domain", [StringComparison]::OrdinalIgnoreCase) -lt 0) {
    throw "URL_TO_HNOTE_SMOKE_RAW_CONTENT_INVALID"
  }

  $privateIngestion = Wait-URLIngestion -Initial (New-URLIngestion -SourceUrl $privateUrl -CaseId "private-$nonce")
  if ([string]$privateIngestion.status -cne "failed" -or [string]$privateIngestion.failureCode -cne "URL_IMPORT_INVALID") {
    throw "URL_TO_HNOTE_SMOKE_PRIVATE_URL_NOT_REJECTED:$([string]$privateIngestion.status)"
  }
  $worker = Assert-URLWorkerConfiguration

  $evidence = [ordered]@{
    schemaVersion = "huahuo.url-to-hnote-product-smoke.v1"
    target = "authorized-host-39"
    status = "passed"
    requestFields = @("url")
    publicCase = [ordered]@{
      ingestionId = [string]$publicIngestion.ingestionId
      terminalStatus = [string]$publicIngestion.status
      noteId = [string]$publicIngestion.promotedNoteId
      sourceKind = [string]$note.sourceKind
      rawContentLength = $content.Length
      sourceUrlPreserved = $true
      exampleDomainContentPresent = $true
    }
    privateDestinationCase = [ordered]@{
      ingestionId = [string]$privateIngestion.ingestionId
      terminalStatus = [string]$privateIngestion.status
      failureCode = [string]$privateIngestion.failureCode
    }
    worker = [ordered]@{
      unit = [string]$worker.unit
      category = [string]$worker.category
      workers = [int]$worker.workers
    }
    startedAtUtc = $startedAt.ToString("o")
    completedAtUtc = [DateTime]::UtcNow.ToString("o")
  }
  $json = $evidence | ConvertTo-Json -Depth 10
  if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
    $absoluteEvidencePath = [IO.Path]::GetFullPath($EvidencePath)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($absoluteEvidencePath)) | Out-Null
    [IO.File]::WriteAllText($absoluteEvidencePath, $json, [Text.UTF8Encoding]::new($false))
  }
  $json
} finally {
  $authorization = ""
}
