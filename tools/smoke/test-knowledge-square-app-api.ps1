[CmdletBinding()]
param(
  [string]$Phone = "18888888888",
  [string]$SmsCode = "123456",
  [string]$ApiBaseUrl = "http://39.107.250.25",
  [string]$ResultPath = "",
  [switch]$SkipNoteEdit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AuthorizedHost = "39.107.250.25"
$BaseUri = [Uri]$ApiBaseUrl.TrimEnd("/")
if ($BaseUri.Host -cne $AuthorizedHost) {
  throw "This runner only permits the authorized host $AuthorizedHost."
}
if ($BaseUri.Scheme -notin @("http", "https")) {
  throw "ApiBaseUrl must use http or https."
}

$RunId = "ks_app_{0}_{1}" -f [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ"), ([Guid]::NewGuid().ToString("N").Substring(0, 8))
if ([string]::IsNullOrWhiteSpace($ResultPath)) {
  $ResultPath = Join-Path ([IO.Path]::GetTempPath()) "$RunId.json"
}

$script:AccessToken = ""
$script:PassCount = 0
$script:SkipCount = 0
$script:Results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
  param(
    [string]$Step,
    [string]$Result,
    [int]$HttpStatus = 0,
    [string]$Detail = ""
  )
  $script:Results.Add([ordered]@{
      step = $Step
      result = $Result
      httpStatus = $HttpStatus
      detail = $Detail
    })
  switch ($Result) {
    "passed" { $script:PassCount++ }
    "skipped" { $script:SkipCount++ }
  }
}

function Get-PathValue {
  param(
    [AllowNull()]$InputObject,
    [string[]]$Paths
  )
  foreach ($path in $Paths) {
    $value = $InputObject
    $found = $true
    foreach ($segment in $path.Split(".")) {
      if ($null -eq $value) {
        $found = $false
        break
      }
      $property = $value.PSObject.Properties[$segment]
      if ($null -eq $property) {
        $found = $false
        break
      }
      $value = $property.Value
    }
    if ($found -and $null -ne $value) {
      if ($value -isnot [string] -or -not [string]::IsNullOrWhiteSpace($value)) {
        return $value
      }
    }
  }
  return $null
}

function Get-ErrorCode {
  param([string]$Content)
  if ([string]::IsNullOrWhiteSpace($Content)) {
    return "unknown"
  }
  try {
    $json = $Content | ConvertFrom-Json
    $code = Get-PathValue $json @("error.code", "code", "error")
    if ($null -ne $code) { return [string]$code }
  } catch {}
  return "unknown"
}

function Get-FailedResponse {
  param($ErrorRecord)
  $status = 0
  $content = ""
  if ($null -ne $ErrorRecord.Exception.Response) {
    try { $status = [int]$ErrorRecord.Exception.Response.StatusCode } catch {}
  }
  if (-not [string]::IsNullOrWhiteSpace($ErrorRecord.ErrorDetails.Message)) {
    $content = $ErrorRecord.ErrorDetails.Message
  } elseif ($null -ne $ErrorRecord.Exception.Response) {
    try {
      $stream = $ErrorRecord.Exception.Response.GetResponseStream()
      $reader = [IO.StreamReader]::new($stream)
      $content = $reader.ReadToEnd()
      $reader.Dispose()
    } catch {}
  }
  return [pscustomobject]@{ Status = $status; Content = $content }
}

function New-AppHeaders {
  param(
    [string]$Step,
    [string]$IdempotencyKey = "",
    [hashtable]$ExtraHeaders = @{},
    [switch]$NoAuth
  )
  $headers = @{
    "Accept" = "application/json"
    "X-Request-Id" = "${RunId}_${Step}"
    "X-Trace-Id" = "${RunId}_${Step}"
    "X-Device-Id" = "codex-knowledge-square-local"
  }
  if (-not $NoAuth) {
    if ([string]::IsNullOrWhiteSpace($script:AccessToken)) {
      throw "Access token is unavailable before step $Step."
    }
    $headers["Authorization"] = "Bearer $($script:AccessToken)"
  }
  if (-not [string]::IsNullOrWhiteSpace($IdempotencyKey)) {
    $headers["X-Idempotency-Key"] = $IdempotencyKey
  }
  foreach ($name in $ExtraHeaders.Keys) {
    $headers[$name] = $ExtraHeaders[$name]
  }
  return $headers
}

function Invoke-JsonStep {
  param(
    [string]$Step,
    [string]$Method,
    [string]$Path,
    [AllowNull()]$Body = $null,
    [string]$IdempotencyKey = "",
    [hashtable]$ExtraHeaders = @{},
    [switch]$NoAuth
  )
  $headers = New-AppHeaders -Step $Step -IdempotencyKey $IdempotencyKey -ExtraHeaders $ExtraHeaders -NoAuth:$NoAuth
  $parameters = @{
    Uri = "$($BaseUri.AbsoluteUri.TrimEnd('/'))$Path"
    Method = $Method
    Headers = $headers
    TimeoutSec = 45
    UseBasicParsing = $true
  }
  if ($null -ne $Body) {
    $parameters.ContentType = "application/json; charset=utf-8"
    $parameters.Body = $Body | ConvertTo-Json -Depth 20 -Compress
  }
  try {
    $response = Invoke-WebRequest @parameters
  } catch {
    $failed = Get-FailedResponse $_
    $code = Get-ErrorCode $failed.Content
    Add-Result -Step $Step -Result "failed" -HttpStatus $failed.Status -Detail $code
    throw "FAIL step=$Step http=$($failed.Status) code=$code"
  }

  $json = $null
  if (-not [string]::IsNullOrWhiteSpace($response.Content)) {
    try { $json = $response.Content | ConvertFrom-Json } catch {
      Add-Result -Step $Step -Result "failed" -HttpStatus ([int]$response.StatusCode) -Detail "invalid_json"
      throw "FAIL step=$Step http=$($response.StatusCode) code=invalid_json"
    }
  }
  if ($null -eq $json -or (Get-PathValue $json @("success")) -ne $true) {
    $code = Get-ErrorCode $response.Content
    Add-Result -Step $Step -Result "failed" -HttpStatus ([int]$response.StatusCode) -Detail $code
    throw "FAIL step=$Step http=$($response.StatusCode) code=$code"
  }

  Add-Result -Step $Step -Result "passed" -HttpStatus ([int]$response.StatusCode)
  Write-Host "PASS step=$Step http=$($response.StatusCode)"
  return [pscustomobject]@{
    Status = [int]$response.StatusCode
    Json = $json
    Headers = $response.Headers
  }
}

function Invoke-BinaryStep {
  param(
    [string]$Step,
    [string]$Path
  )
  $headers = New-AppHeaders -Step $Step
  try {
    $response = Invoke-WebRequest -Uri "$($BaseUri.AbsoluteUri.TrimEnd('/'))$Path" -Method Get -Headers $headers -TimeoutSec 45 -UseBasicParsing
  } catch {
    $failed = Get-FailedResponse $_
    $code = Get-ErrorCode $failed.Content
    Add-Result -Step $Step -Result "failed" -HttpStatus $failed.Status -Detail $code
    throw "FAIL step=$Step http=$($failed.Status) code=$code"
  }
  Add-Result -Step $Step -Result "passed" -HttpStatus ([int]$response.StatusCode)
  Write-Host "PASS step=$Step http=$($response.StatusCode)"
}

function Add-SkippedStep {
  param([string]$Step, [string]$Reason)
  Add-Result -Step $Step -Result "skipped" -Detail $Reason
  Write-Host "SKIP step=$Step reason=$Reason"
}

function Test-PublicationInLibrary {
  param($LibraryJson, [string]$PublicationId)
  $itemsValue = Get-PathValue $LibraryJson @("data.items")
  if ($null -eq $itemsValue) { return $false }
  foreach ($item in @($itemsValue)) {
    $id = Get-PathValue $item @("publication.publicationId", "publicationId")
    if ([string]$id -ceq $PublicationId) { return $true }
  }
  return $false
}

function Redact-Id {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return "-" }
  if ($Value.Length -le 10) { return "[redacted]" }
  return "$($Value.Substring(0, 4))...$($Value.Substring($Value.Length - 4))"
}

$workspaceId = ""
$publicationId = ""
$articleId = ""
$articleRevisionId = ""
$noteId = ""
$relationKnown = $false
$initiallyFollowing = $false
$currentlyFollowing = $false
$completed = $false

try {
  $maskedPhone = if ($Phone.Length -ge 7) { "$($Phone.Substring(0, 3))****$($Phone.Substring($Phone.Length - 4))" } else { "[redacted]" }
  Write-Host "Knowledge Square App API test: host=$AuthorizedHost phone=$maskedPhone run=$RunId"

  $login = Invoke-JsonStep -Step "login" -Method Post -Path "/api/v1/auth/login" -NoAuth -Body ([ordered]@{
      phone = $Phone
      smsCode = $SmsCode
      agreementAccepted = $true
      agreementVersion = "v0.1"
      privacyVersion = "v0.1"
      clientVersion = "knowledge-square-local-test"
      deviceId = "codex-knowledge-square-local"
      timeZone = "Asia/Shanghai"
    })
  $script:AccessToken = [string](Get-PathValue $login.Json @("data.accessToken", "accessToken"))
  $workspaceId = [string](Get-PathValue $login.Json @("data.workspace.workspaceId", "data.workspaceId", "workspace.workspaceId", "workspaceId"))
  if ([string]::IsNullOrWhiteSpace($script:AccessToken) -or [string]::IsNullOrWhiteSpace($workspaceId)) {
    throw "Login succeeded without an access token or workspace ID."
  }

  [void](Invoke-JsonStep -Step "me_status" -Method Get -Path "/api/v1/me/status")

  $publications = Invoke-JsonStep -Step "publications" -Method Get -Path "/api/v1/subscription/publications?limit=1"
  $publicationItems = @(Get-PathValue $publications.Json @("data.items"))
  if ($publicationItems.Count -eq 0 -or $null -eq $publicationItems[0]) {
    throw "Catalog contains no visible Publication."
  }
  $publicationId = [string](Get-PathValue $publicationItems[0] @("publicationId"))
  if ([string]::IsNullOrWhiteSpace($publicationId)) { throw "Publication ID is missing." }

  $publicationCursor = [string](Get-PathValue $publications.Json @("data.nextCursor"))
  if (-not [string]::IsNullOrWhiteSpace($publicationCursor)) {
    [void](Invoke-JsonStep -Step "publications_cursor" -Method Get -Path "/api/v1/subscription/publications?limit=1&cursor=$([Uri]::EscapeDataString($publicationCursor))")
  } else {
    Add-SkippedStep -Step "publications_cursor" -Reason "single_page"
  }

  [void](Invoke-JsonStep -Step "publication" -Method Get -Path "/api/v1/subscription/publications/$([Uri]::EscapeDataString($publicationId))")
  [void](Invoke-JsonStep -Step "sections" -Method Get -Path "/api/v1/subscription/publications/$([Uri]::EscapeDataString($publicationId))/sections?limit=100")

  $articles = Invoke-JsonStep -Step "articles" -Method Get -Path "/api/v1/subscription/articles?publicationId=$([Uri]::EscapeDataString($publicationId))&limit=1"
  $articleItems = @(Get-PathValue $articles.Json @("data.items"))
  if ($articleItems.Count -eq 0 -or $null -eq $articleItems[0]) {
    throw "Selected Publication contains no visible Article."
  }
  $articleId = [string](Get-PathValue $articleItems[0] @("articleId"))
  $articleRevisionId = [string](Get-PathValue $articleItems[0] @("currentArticleRevisionId"))
  if ([string]::IsNullOrWhiteSpace($articleId)) { throw "Article ID is missing." }

  $articleCursor = [string](Get-PathValue $articles.Json @("data.nextCursor"))
  if (-not [string]::IsNullOrWhiteSpace($articleCursor)) {
    [void](Invoke-JsonStep -Step "articles_cursor" -Method Get -Path "/api/v1/subscription/articles?publicationId=$([Uri]::EscapeDataString($publicationId))&limit=1&cursor=$([Uri]::EscapeDataString($articleCursor))")
  } else {
    Add-SkippedStep -Step "articles_cursor" -Reason "single_page"
  }

  $article = Invoke-JsonStep -Step "article" -Method Get -Path "/api/v1/subscription/articles/$([Uri]::EscapeDataString($articleId))"
  if ([string]::IsNullOrWhiteSpace($articleRevisionId)) {
    $articleRevisionId = [string](Get-PathValue $article.Json @("data.article.currentArticleRevisionId", "data.revision.articleRevisionId", "data.currentArticleRevisionId"))
  }
  if ([string]::IsNullOrWhiteSpace($articleRevisionId)) { throw "Current Article revision ID is missing." }

  $revisions = Invoke-JsonStep -Step "revisions" -Method Get -Path "/api/v1/subscription/articles/$([Uri]::EscapeDataString($articleId))/revisions?limit=1"
  $revisionCursor = [string](Get-PathValue $revisions.Json @("data.nextCursor"))
  if (-not [string]::IsNullOrWhiteSpace($revisionCursor)) {
    [void](Invoke-JsonStep -Step "revisions_cursor" -Method Get -Path "/api/v1/subscription/articles/$([Uri]::EscapeDataString($articleId))/revisions?limit=1&cursor=$([Uri]::EscapeDataString($revisionCursor))")
  } else {
    Add-SkippedStep -Step "revisions_cursor" -Reason "single_page"
  }

  $revision = Invoke-JsonStep -Step "revision" -Method Get -Path "/api/v1/subscription/articles/$([Uri]::EscapeDataString($articleId))/revisions/$([Uri]::EscapeDataString($articleRevisionId))"
  $assetRefs = Get-PathValue $revision.Json @("data.assetRefs", "data.revision.assetRefs")
  $assetFileKey = ""
  $assetLogicalPath = ""
  if ($null -ne $assetRefs -and @($assetRefs).Count -gt 0) {
    $assetFileKey = [string](Get-PathValue @($assetRefs)[0] @("fileKey"))
    $assetLogicalPath = [string](Get-PathValue @($assetRefs)[0] @("logicalPath"))
  }
  if (-not [string]::IsNullOrWhiteSpace($assetFileKey)) {
    Invoke-BinaryStep -Step "article_asset" -Path "/api/v1/subscription/articles/$([Uri]::EscapeDataString($articleId))/revisions/$([Uri]::EscapeDataString($articleRevisionId))/assets/$([Uri]::EscapeDataString($assetFileKey))"
  } else {
    Add-SkippedStep -Step "article_asset" -Reason "revision_has_no_asset"
  }

  $libraryBefore = Invoke-JsonStep -Step "library_publications_before" -Method Get -Path "/api/v1/workspaces/$([Uri]::EscapeDataString($workspaceId))/subscription-library/publications?limit=100"
  $initiallyFollowing = Test-PublicationInLibrary $libraryBefore.Json $publicationId
  $currentlyFollowing = $initiallyFollowing
  $relationKnown = $true

  [void](Invoke-JsonStep -Step "follow" -Method Put -Path "/api/v1/workspaces/$([Uri]::EscapeDataString($workspaceId))/subscription-library/publications/$([Uri]::EscapeDataString($publicationId))" -IdempotencyKey "${RunId}_follow")
  $currentlyFollowing = $true

  $libraryPublications = Invoke-JsonStep -Step "library_publications" -Method Get -Path "/api/v1/workspaces/$([Uri]::EscapeDataString($workspaceId))/subscription-library/publications?limit=100"
  if (-not (Test-PublicationInLibrary $libraryPublications.Json $publicationId)) {
    throw "Followed Publication is not visible in the library."
  }

  $libraryArticles = Invoke-JsonStep -Step "library_articles" -Method Get -Path "/api/v1/workspaces/$([Uri]::EscapeDataString($workspaceId))/subscription-library/articles?limit=100"
  $libraryArticleItems = Get-PathValue $libraryArticles.Json @("data.items")
  $articleVisible = $false
  foreach ($item in @($libraryArticleItems)) {
    $candidate = [string](Get-PathValue $item @("article.articleId", "articleId"))
    if ($candidate -ceq $articleId) { $articleVisible = $true; break }
  }
  if (-not $articleVisible) { throw "Followed Article is not visible in the library." }

  $saveKey = "${RunId}_save_note"
  $saveBody = [ordered]@{ articleRevisionId = $articleRevisionId }
  $save = Invoke-JsonStep -Step "save_as_note" -Method Post -Path "/api/v1/workspaces/$([Uri]::EscapeDataString($workspaceId))/subscription-articles/$([Uri]::EscapeDataString($articleId))/save-as-note" -IdempotencyKey $saveKey -Body $saveBody
  $noteId = [string](Get-PathValue $save.Json @("data.noteId"))
  if ([string]::IsNullOrWhiteSpace($noteId)) { throw "save-as-note returned no canonical Note ID." }

  $saveReplay = Invoke-JsonStep -Step "save_as_note_replay" -Method Post -Path "/api/v1/workspaces/$([Uri]::EscapeDataString($workspaceId))/subscription-articles/$([Uri]::EscapeDataString($articleId))/save-as-note" -IdempotencyKey $saveKey -Body $saveBody
  $replayedNoteId = [string](Get-PathValue $saveReplay.Json @("data.noteId"))
  if ($replayedNoteId -cne $noteId) { throw "save-as-note idempotency replay returned a different Note ID." }

  $notes = Invoke-JsonStep -Step "notes" -Method Get -Path "/api/v1/workspaces/$([Uri]::EscapeDataString($workspaceId))/notes?limit=100"
  $noteListed = $false
  foreach ($item in @(Get-PathValue $notes.Json @("data.items"))) {
    if ([string](Get-PathValue $item @("noteId")) -ceq $noteId) { $noteListed = $true; break }
  }
  if (-not $noteListed) { throw "Deposited Note is not visible in the Note list." }

  $note = Invoke-JsonStep -Step "note" -Method Get -Path "/api/v1/workspaces/$([Uri]::EscapeDataString($workspaceId))/notes/$([Uri]::EscapeDataString($noteId))"
  $raw = Invoke-JsonStep -Step "raw_part" -Method Get -Path "/api/v1/workspaces/$([Uri]::EscapeDataString($workspaceId))/notes/$([Uri]::EscapeDataString($noteId))/parts/raw"
  $rawPartRevisionId = [string](Get-PathValue $raw.Json @("data.partRevisionId"))
  if ([string]::IsNullOrWhiteSpace($rawPartRevisionId)) {
    $rawPartRevisionId = [string](Get-PathValue $note.Json @("data.note.rawPartRevisionId", "data.rawPartRevisionId"))
  }

  if (-not [string]::IsNullOrWhiteSpace($assetLogicalPath)) {
    Invoke-BinaryStep -Step "note_asset" -Path "/api/v1/workspaces/$([Uri]::EscapeDataString($workspaceId))/notes/$([Uri]::EscapeDataString($noteId))/subscription-assets?logicalPath=$([Uri]::EscapeDataString($assetLogicalPath))"
  } else {
    Add-SkippedStep -Step "note_asset" -Reason "revision_has_no_asset"
  }

  if ($SkipNoteEdit) {
    Add-SkippedStep -Step "edit_note" -Reason "disabled_by_parameter"
  } else {
    $etag = [string](Get-PathValue $raw.Json @("data.etag"))
    if ([string]::IsNullOrWhiteSpace($etag)) { $etag = [string]$raw.Headers["ETag"] }
    $contentMarkdown = [string](Get-PathValue $raw.Json @("data.contentMarkdown", "data.part.contentMarkdown"))
    $originalMarkdown = [Regex]::Replace($contentMarkdown, '<!-- ks_app_[^>]+ -->', '').TrimEnd("`r", "`n") + "`n"
    if ([string]::IsNullOrWhiteSpace($etag) -or [string]::IsNullOrWhiteSpace($rawPartRevisionId)) {
      throw "Raw Note part did not return ETag and basePartRevisionId required for editing."
    }
    $testMarkdown = $originalMarkdown.TrimEnd("`r", "`n") + "`n`n<!-- $RunId -->`n"
    $edit = Invoke-JsonStep -Step "edit_note" -Method Put -Path "/api/v1/workspaces/$([Uri]::EscapeDataString($workspaceId))/notes/$([Uri]::EscapeDataString($noteId))/parts/raw" -IdempotencyKey "${RunId}_edit_note" -ExtraHeaders @{ "If-Match" = $etag } -Body ([ordered]@{
          contentMarkdown = $testMarkdown
          basePartRevisionId = $rawPartRevisionId
        })
    $editedRaw = Invoke-JsonStep -Step "raw_part_after_edit" -Method Get -Path "/api/v1/workspaces/$([Uri]::EscapeDataString($workspaceId))/notes/$([Uri]::EscapeDataString($noteId))/parts/raw"
    $editedPartRevisionId = [string](Get-PathValue $editedRaw.Json @("data.partRevisionId"))
    $editedEtag = [string](Get-PathValue $editedRaw.Json @("data.etag"))
    if ([string]::IsNullOrWhiteSpace($editedEtag)) { $editedEtag = [string]$editedRaw.Headers["ETag"] }
    if ([string]::IsNullOrWhiteSpace($editedPartRevisionId) -or [string]::IsNullOrWhiteSpace($editedEtag)) {
      throw "Edited raw Note part did not return the revision and ETag required to restore the original content."
    }
    [void](Invoke-JsonStep -Step "restore_note_content" -Method Put -Path "/api/v1/workspaces/$([Uri]::EscapeDataString($workspaceId))/notes/$([Uri]::EscapeDataString($noteId))/parts/raw" -IdempotencyKey "${RunId}_restore_note" -ExtraHeaders @{ "If-Match" = $editedEtag } -Body ([ordered]@{
          contentMarkdown = $originalMarkdown
          basePartRevisionId = $editedPartRevisionId
        }))
    $restoredRaw = Invoke-JsonStep -Step "raw_part_after_restore" -Method Get -Path "/api/v1/workspaces/$([Uri]::EscapeDataString($workspaceId))/notes/$([Uri]::EscapeDataString($noteId))/parts/raw"
    $restoredMarkdown = [string](Get-PathValue $restoredRaw.Json @("data.contentMarkdown", "data.part.contentMarkdown"))
    if ($restoredMarkdown -cne $originalMarkdown) {
      throw "Raw Note content was not restored after the edit test."
    }
  }

  [void](Invoke-JsonStep -Step "unfollow" -Method Delete -Path "/api/v1/workspaces/$([Uri]::EscapeDataString($workspaceId))/subscription-library/publications/$([Uri]::EscapeDataString($publicationId))" -IdempotencyKey "${RunId}_unfollow")
  $currentlyFollowing = $false

  $libraryAfter = Invoke-JsonStep -Step "library_publications_after" -Method Get -Path "/api/v1/workspaces/$([Uri]::EscapeDataString($workspaceId))/subscription-library/publications?limit=100"
  if (Test-PublicationInLibrary $libraryAfter.Json $publicationId) {
    throw "Unfollowed Publication is still visible as following."
  }

  if ($initiallyFollowing) {
    [void](Invoke-JsonStep -Step "restore_initial_follow" -Method Put -Path "/api/v1/workspaces/$([Uri]::EscapeDataString($workspaceId))/subscription-library/publications/$([Uri]::EscapeDataString($publicationId))" -IdempotencyKey "${RunId}_restore_follow")
    $currentlyFollowing = $true
  }

  $completed = $true
} finally {
  if ($relationKnown -and $currentlyFollowing -ne $initiallyFollowing -and -not [string]::IsNullOrWhiteSpace($script:AccessToken)) {
    try {
      $cleanupMethod = if ($initiallyFollowing) { "Put" } else { "Delete" }
      $cleanupHeaders = New-AppHeaders -Step "cleanup_relation" -IdempotencyKey "${RunId}_cleanup_relation"
      Invoke-WebRequest -Uri "$($BaseUri.AbsoluteUri.TrimEnd('/'))/api/v1/workspaces/$([Uri]::EscapeDataString($workspaceId))/subscription-library/publications/$([Uri]::EscapeDataString($publicationId))" -Method $cleanupMethod -Headers $cleanupHeaders -TimeoutSec 45 -UseBasicParsing | Out-Null
      Write-Host "PASS step=cleanup_relation restored=$initiallyFollowing"
    } catch {
      Write-Warning "Subscription cleanup failed; inspect the test account's library relation."
    }
  }

  $summary = [ordered]@{
    schemaVersion = "huahuo.knowledge-square-app-api-test.v1"
    result = if ($completed) { "passed" } else { "failed" }
    runId = $RunId
    authorizedHost = $AuthorizedHost
    phoneMasked = if ($Phone.Length -ge 7) { "$($Phone.Substring(0, 3))****$($Phone.Substring($Phone.Length - 4))" } else { "[redacted]" }
    passed = $script:PassCount
    skipped = $script:SkipCount
    publication = Redact-Id $publicationId
    article = Redact-Id $articleId
    note = Redact-Id $noteId
    noteRetainedByDesign = -not [string]::IsNullOrWhiteSpace($noteId)
    saveAsNoteRequestShape = "deployed_articleRevisionId_body"
    subscriptionStateRestored = $relationKnown -and ($currentlyFollowing -eq $initiallyFollowing)
    finishedAtUtc = [DateTime]::UtcNow.ToString("o")
    steps = $script:Results
  }
  $resultDirectory = Split-Path -Parent $ResultPath
  if (-not [string]::IsNullOrWhiteSpace($resultDirectory)) {
    [IO.Directory]::CreateDirectory($resultDirectory) | Out-Null
  }
  $summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
  Write-Host "RESULT path=$ResultPath"
  if ($completed) {
    Write-Host "SUMMARY result=pass passed=$($script:PassCount) skipped=$($script:SkipCount)"
  }
}
