[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$ApiBase,

  [string]$AccessToken = '',

  [Parameter(Mandatory = $true)]
  [string]$WorkspaceId,

  [Parameter(Mandatory = $true)]
  [ValidateSet('hnote', 'creation', 'book_section', 'work')]
  [string]$OwnerKind,

  [Parameter(Mandatory = $true)]
  [string]$OwnerId,

  [ValidateSet('raw', 'outline', 'germination')]
  [string]$Part = 'raw',

  [Parameter(Mandatory = $true)]
  [string]$PartRevisionId,

  [Parameter(Mandatory = $true)]
  [string]$Instruction,

  [string[]]$SkillProfileIds = @(),

  [string]$ThreadId = '',

  [switch]$Apply,

  [switch]$IncludeCandidateText,

  [ValidateRange(1, 30)]
  [int]$PollIntervalSeconds = 3,

  [ValidateRange(10, 1800)]
  [int]$TimeoutSeconds = 600
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName System.Net.Http

if ([string]::IsNullOrWhiteSpace($AccessToken)) {
  $AccessToken = [string]$env:HUAHUO_ACCESS_TOKEN
}
if ([string]::IsNullOrWhiteSpace($AccessToken)) {
  throw 'Set HUAHUO_ACCESS_TOKEN or pass -AccessToken. The token is never printed.'
}
if ([string]::IsNullOrWhiteSpace($WorkspaceId) -or
  [string]::IsNullOrWhiteSpace($OwnerId) -or
  [string]::IsNullOrWhiteSpace($PartRevisionId)) {
  throw 'WorkspaceId, OwnerId, and PartRevisionId must not be empty.'
}
if ([string]::IsNullOrWhiteSpace($Instruction)) {
  throw 'Instruction must not be empty.'
}

$utf8 = [Text.UTF8Encoding]::new($false)
if ($utf8.GetByteCount($Instruction) -gt 32768) {
  throw 'Instruction exceeds the DOC-DCP-01 32 KiB limit.'
}
$normalizedSkillProfileIds = [System.Collections.Generic.List[string]]::new()
foreach ($skillProfileId in $SkillProfileIds) {
  $normalizedSkillProfileId = ([string]$skillProfileId).Trim()
  if ([string]::IsNullOrWhiteSpace($normalizedSkillProfileId)) {
    throw 'SkillProfileIds cannot contain an empty value.'
  }
  if (-not $normalizedSkillProfileIds.Contains($normalizedSkillProfileId)) {
    $normalizedSkillProfileIds.Add($normalizedSkillProfileId)
  }
}

$apiUri = [Uri]$ApiBase.TrimEnd('/')
if (-not $apiUri.IsAbsoluteUri -or
  $apiUri.DnsSafeHost -ne '39.107.250.25' -or
  $apiUri.AbsolutePath.TrimEnd('/') -ne '/api/v1' -or
  $apiUri.UserInfo -or $apiUri.Query -or $apiUri.Fragment) {
  throw 'ApiBase must be the authorized host API root: http(s)://39.107.250.25/api/v1.'
}

$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(90)
$terminalGenerationStates = @('ready', 'generation_failed', 'stale', 'rejected', 'applied', 'apply_failed')
$proposalRoot = "/workspaces/$([Uri]::EscapeDataString($WorkspaceId))/document-change-proposals"

function Get-Value {
  param(
    [AllowNull()][object]$Object,
    [Parameter(Mandatory = $true)][string[]]$Names
  )

  foreach ($name in $Names) {
    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $name) {
      return $Object.$name
    }
  }
  return $null
}

function New-RequestId {
  param([Parameter(Mandatory = $true)][string]$Prefix)
  return "$Prefix-$([Guid]::NewGuid().ToString('N'))"
}

function Get-ErrorCode {
  param([AllowNull()][object]$Payload)

  $error = Get-Value -Object $Payload -Names @('error')
  $code = Get-Value -Object $error -Names @('code')
  if (-not [string]::IsNullOrWhiteSpace([string]$code)) {
    return [string]$code
  }
  return 'UNKNOWN_API_ERROR'
}

function Invoke-AppApi {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('GET', 'POST')]
    [string]$Method,

    [Parameter(Mandatory = $true)]
    [string]$Path,

    [AllowNull()][object]$Body = $null,

    [AllowEmptyString()][string]$IdempotencyKey = '',

    [AllowEmptyString()][string]$IfMatch = ''
  )

  $requestUri = "$($apiUri.AbsoluteUri.TrimEnd('/'))/$($Path.TrimStart('/'))"
  $request = [System.Net.Http.HttpRequestMessage]::new(
    [System.Net.Http.HttpMethod]::new($Method),
    $requestUri
  )
  $response = $null
  try {
    $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $AccessToken)
    $request.Headers.TryAddWithoutValidation('X-Request-Id', (New-RequestId -Prefix 'dcp-simulator')) | Out-Null
    $request.Headers.TryAddWithoutValidation('X-Trace-Id', (New-RequestId -Prefix 'dcp-simulator')) | Out-Null
    $request.Headers.TryAddWithoutValidation('X-Client-Version', 'dcp-simulator-1.0') | Out-Null
    $request.Headers.TryAddWithoutValidation('X-Platform', 'app-simulator') | Out-Null
    $request.Headers.TryAddWithoutValidation('X-Locale', 'zh-CN') | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($IdempotencyKey)) {
      $request.Headers.TryAddWithoutValidation('X-Idempotency-Key', $IdempotencyKey) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($IfMatch)) {
      $request.Headers.TryAddWithoutValidation('If-Match', $IfMatch) | Out-Null
    }
    if ($Method -eq 'POST' -and $null -ne $Body) {
      $json = $Body | ConvertTo-Json -Depth 12 -Compress
      $request.Content = [System.Net.Http.StringContent]::new($json, $utf8, 'application/json')
    }

    $response = $client.SendAsync($request).GetAwaiter().GetResult()
    $raw = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $payload = if ([string]::IsNullOrWhiteSpace($raw)) {
      [pscustomobject]@{}
    } else {
      try {
        $raw | ConvertFrom-Json
      } catch {
        throw "API returned non-JSON content for $Method $Path (HTTP $([int]$response.StatusCode))."
      }
    }
    if (-not $response.IsSuccessStatusCode) {
      throw "API request failed for $Method $Path (HTTP $([int]$response.StatusCode), $(Get-ErrorCode -Payload $payload))."
    }
    if ((Get-Value -Object $payload -Names @('success')) -eq $false) {
      throw "API returned an unsuccessful envelope for $Method $Path ($(Get-ErrorCode -Payload $payload))."
    }

    $etag = if ($null -ne $response.Headers.ETag) { $response.Headers.ETag.Tag } else { '' }
    [pscustomobject]@{
      data = Get-Value -Object $payload -Names @('data')
      etag = $etag
      statusCode = [int]$response.StatusCode
    }
  } finally {
    if ($null -ne $response) { $response.Dispose() }
    $request.Dispose()
  }
}

function Get-Proposal {
  param([Parameter(Mandatory = $true)][string]$ProposalId)

  return Invoke-AppApi -Method GET -Path "$proposalRoot/$([Uri]::EscapeDataString($ProposalId))"
}

function Wait-ForProposalState {
  param(
    [Parameter(Mandatory = $true)][string]$ProposalId,
    [Parameter(Mandatory = $true)][string[]]$TerminalStates,
    [Parameter(Mandatory = $true)][datetime]$Deadline
  )

  do {
    $response = Get-Proposal -ProposalId $ProposalId
    $proposal = $response.data
    $state = [string](Get-Value -Object $proposal -Names @('state'))
    if ($state -in $TerminalStates) {
      return $response
    }
    if ((Get-Date) -ge $Deadline) {
      throw "Timed out while waiting for Proposal $ProposalId; last state: $state. No cancel request was sent."
    }
    Start-Sleep -Seconds $PollIntervalSeconds
  } while ($true)
}

function Get-CandidateText {
  param([Parameter(Mandatory = $true)][string]$ProposalId)

  $candidatePath = "$proposalRoot/$([Uri]::EscapeDataString($ProposalId))/candidate"
  $chunks = [System.Collections.Generic.List[string]]::new()
  do {
    $response = Invoke-AppApi -Method GET -Path $candidatePath
    $chunk = $response.data
    $text = Get-Value -Object $chunk -Names @('text')
    if ($null -ne $text) { $chunks.Add([string]$text) }
    $cursor = [string](Get-Value -Object $chunk -Names @('nextCursor'))
    if (-not [string]::IsNullOrWhiteSpace($cursor)) {
      $candidatePath = "$proposalRoot/$([Uri]::EscapeDataString($ProposalId))/candidate?cursor=$([Uri]::EscapeDataString($cursor))"
    }
  } while (-not [string]::IsNullOrWhiteSpace($cursor))

  return [string]::Concat($chunks)
}

try {
  $createIdempotencyKey = New-RequestId -Prefix 'dcp-create'
  $createBody = [ordered]@{
    target = [ordered]@{
      ownerRef = [ordered]@{
        kind = $OwnerKind
        id = $OwnerId
      }
      part = $Part
      partRevisionId = $PartRevisionId
    }
    instruction = $Instruction
    agentProfileId = 'self_media_creation'
  }
  if ($normalizedSkillProfileIds.Count -gt 0) {
    $createBody.skillProfileIds = @($normalizedSkillProfileIds | Sort-Object)
  }
  if (-not [string]::IsNullOrWhiteSpace($ThreadId)) {
    $createBody.threadId = $ThreadId
  }

  $created = Invoke-AppApi -Method POST -Path $proposalRoot -Body $createBody -IdempotencyKey $createIdempotencyKey
  $proposal = $created.data
  $proposalId = [string](Get-Value -Object $proposal -Names @('proposalId'))
  if ([string]::IsNullOrWhiteSpace($proposalId)) {
    throw 'Proposal creation succeeded without proposalId.'
  }

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $completedGeneration = Wait-ForProposalState -ProposalId $proposalId -TerminalStates $terminalGenerationStates -Deadline $deadline
  $proposal = $completedGeneration.data
  $proposalEtag = [string]$completedGeneration.etag
  $state = [string](Get-Value -Object $proposal -Names @('state'))
  $diff = $null
  $candidateText = $null

  if ($state -eq 'ready') {
    $diff = (Invoke-AppApi -Method GET -Path "$proposalRoot/$([Uri]::EscapeDataString($proposalId))/diff?limit=50").data
    if ($IncludeCandidateText) {
      $candidateText = Get-CandidateText -ProposalId $proposalId
    }
  }

  if ($Apply -and $state -eq 'ready' -and (Get-Value -Object $proposal -Names @('hasChanges')) -eq $true) {
    if ([string]::IsNullOrWhiteSpace($proposalEtag)) {
      throw "Proposal $proposalId is ready but its strong ETag is missing; refusing to apply."
    }
    $applyKey = New-RequestId -Prefix 'dcp-apply'
    Invoke-AppApi -Method POST -Path "$proposalRoot/$([Uri]::EscapeDataString($proposalId))/apply" -IdempotencyKey $applyKey -IfMatch $proposalEtag | Out-Null
    $completedApply = Wait-ForProposalState -ProposalId $proposalId -TerminalStates @('applied', 'apply_failed', 'stale') -Deadline $deadline
    $proposal = $completedApply.data
    $state = [string](Get-Value -Object $proposal -Names @('state'))
  }

  [pscustomobject][ordered]@{
    apiBase = $apiUri.AbsoluteUri.TrimEnd('/')
    workspaceId = $WorkspaceId
    proposalId = $proposalId
    state = $state
    generationStage = [string](Get-Value -Object $proposal -Names @('generationStage'))
    run = Get-Value -Object $proposal -Names @('run')
    target = Get-Value -Object $proposal -Names @('target')
    hasChanges = Get-Value -Object $proposal -Names @('hasChanges')
    failure = Get-Value -Object $proposal -Names @('failure')
    applied = Get-Value -Object $proposal -Names @('applied')
    diffSummary = Get-Value -Object $diff -Names @('summary')
    candidateText = $candidateText
  } | ConvertTo-Json -Depth 20
} finally {
  $client.Dispose()
}
