<#
.SYNOPSIS
Runs the production smoke matrix for file-based topic generation.

.DESCRIPTION
The script is intentionally bound to the authorized 39.107.250.25 host. It
checks normal Chat first, then the existing Note File Agent, a targeted daily
topic delivery, and a bounded batch of four-Note topic-collision Runs. Account
and Admin credentials are accepted only through parameters or environment
variables and are never emitted in the structured report.
#>
[CmdletBinding()]
param(
  [string]$ApiBase = 'http://39.107.250.25/api/v1',
  [string]$AdminBase = 'http://39.107.250.25/admin/api/v1',
  [string[]]$Phones = @(),
  [string]$SmsCode = $env:HUAHUO_TEST_SMS_CODE,
  [string]$AdminLogin = $env:HUAHUO_ADMIN_LOGIN,
  [string]$AdminPassword = $env:HUAHUO_ADMIN_PASSWORD,
  [string]$BusinessDate = '',
  [ValidateRange(1, 40)][int]$CollisionCount = 20,
  [ValidateRange(1, 10)][int]$MinimumTopics = 10,
  [ValidateRange(60, 3600)][int]$MaxWaitSeconds = 1800,
  [ValidateRange(1, 30)][int]$PollSeconds = 4,
  [ValidateRange(0, 5)][int]$SampleOutputCount = 2,
  [string]$ReportPath = '',
  [switch]$SkipDailyTopic,
  [switch]$SkipNoteFileAgent,
  [switch]$SkipNormalChat
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

. (Join-Path $PSScriptRoot 'minutes_api_common.ps1')

function Assert-HuahuoAuthorizedRoot {
  param(
    [Parameter(Mandatory = $true)][string]$Value,
    [Parameter(Mandatory = $true)][string]$Path
  )

  $uri = [Uri]$Value.TrimEnd('/')
  if ($uri.Scheme -notin @('http', 'https') -or $uri.DnsSafeHost -ne '39.107.250.25' -or
    $uri.AbsolutePath.TrimEnd('/') -ne $Path -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
    throw "$Path must use the authorized 39.107.250.25 host."
  }
  return $uri
}

function Get-HuahuoRequiredString {
  param(
    [AllowNull()][object]$Object,
    [Parameter(Mandatory = $true)][string[]]$Names,
    [Parameter(Mandatory = $true)][string]$Label
  )

  $value = Get-HuahuoString (Get-HuahuoObjectValue -Object $Object -Names $Names)
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "$Label is missing."
  }
  return $value
}

function Get-HuahuoItems {
  param([AllowNull()][object]$Object)

  $items = Get-HuahuoObjectValue -Object $Object -Names @('items')
  if ($null -eq $items) {
    return @()
  }
  return @($items)
}

function Get-HuahuoPhoneHash {
  param([Parameter(Mandatory = $true)][string]$Phone)

  $bytes = [Text.Encoding]::UTF8.GetBytes('phone:' + $Phone.Trim())
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $sum = $sha.ComputeHash($bytes)
  } finally {
    $sha.Dispose()
  }
  return (($sum | ForEach-Object { $_.ToString('x2') }) -join '')
}

function New-HuahuoAdminApiClient {
  param([Parameter(Mandatory = $true)][Uri]$Root)

  Add-Type -AssemblyName System.Net.Http
  $client = [Net.Http.HttpClient]::new()
  $client.Timeout = [TimeSpan]::FromSeconds(120)
  return [pscustomobject]@{
    Root = $Root
    Client = $client
    Utf8 = [Text.UTF8Encoding]::new($false)
    Token = ''
  }
}

function Invoke-HuahuoAdminApi {
  param(
    [Parameter(Mandatory = $true)][object]$Api,
    [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST')][string]$Method,
    [Parameter(Mandatory = $true)][string]$Path,
    [AllowNull()][object]$Body = $null,
    [switch]$Anonymous
  )

  if (-not $Path.StartsWith('/')) {
    throw 'Admin API paths must be relative to the configured root.'
  }
  if (-not $Anonymous -and [string]::IsNullOrWhiteSpace($Api.Token)) {
    throw 'Admin access token is unavailable.'
  }
  $request = [Net.Http.HttpRequestMessage]::new(
    [Net.Http.HttpMethod]::new($Method),
    "$($Api.Root.AbsoluteUri.TrimEnd('/'))/$($Path.TrimStart('/'))"
  )
  $response = $null
  try {
    $request.Headers.TryAddWithoutValidation('Accept', 'application/json') | Out-Null
    $request.Headers.TryAddWithoutValidation('User-Agent', 'HuahuoAI-Topic-File-Smoke/1.0') | Out-Null
    $request.Headers.TryAddWithoutValidation('X-Trace-Id', 'topic-file-smoke-' + [guid]::NewGuid().ToString('N')) | Out-Null
    $request.Headers.TryAddWithoutValidation('X-Admin-Reason', 'authorized topic file production smoke') | Out-Null
    if (-not $Anonymous) {
      $request.Headers.TryAddWithoutValidation('Authorization', "Bearer $($Api.Token)") | Out-Null
    }
    if ($Method -eq 'POST') {
      $request.Headers.TryAddWithoutValidation('X-Idempotency-Key', 'topic-file-smoke-' + [guid]::NewGuid().ToString('N')) | Out-Null
      $json = if ($null -eq $Body) { '{}' } else { $Body | ConvertTo-Json -Depth 32 -Compress }
      $request.Content = [Net.Http.StringContent]::new($json, $Api.Utf8, 'application/json')
    }
    $response = $Api.Client.SendAsync($request).GetAwaiter().GetResult()
    $raw = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $payload = if ([string]::IsNullOrWhiteSpace($raw)) { $null } else { $raw | ConvertFrom-Json }
    $success = Get-HuahuoObjectValue -Object $payload -Names @('success')
    if (-not $response.IsSuccessStatusCode -or $success -eq $false) {
      $code = Get-HuahuoApiErrorCode -Payload $payload
      if ([string]::IsNullOrWhiteSpace($code)) {
        $code = 'UNKNOWN_ADMIN_API_ERROR'
      }
      throw "Admin API $Method $Path failed with HTTP $([int]$response.StatusCode), code $code."
    }
    $data = Get-HuahuoObjectValue -Object $payload -Names @('data')
    return $(if ($null -ne $data) { $data } else { $payload })
  } finally {
    $request.Dispose()
    if ($null -ne $response) {
      $response.Dispose()
    }
  }
}

function Connect-HuahuoAdminApi {
  param(
    [Parameter(Mandatory = $true)][object]$Api,
    [Parameter(Mandatory = $true)][string]$Login,
    [Parameter(Mandatory = $true)][string]$Password
  )

  $reply = Invoke-HuahuoAdminApi -Api $Api -Method POST -Path '/auth/login' -Anonymous -Body @{
    login = $Login
    password = $Password
  }
  $Api.Token = Get-HuahuoRequiredString -Object $reply -Names @('adminAccessToken', 'accessToken') -Label 'Admin access token'
}

function Add-HuahuoSmokeResult {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.List[object]]$Results,
    [Parameter(Mandatory = $true)][string]$Check,
    [Parameter(Mandatory = $true)][string]$Status,
    [AllowNull()][object]$Evidence = $null,
    [AllowEmptyString()][string]$Error = ''
  )

  $Results.Add([pscustomobject][ordered]@{
    check = $Check
    status = $Status
    evidence = $Evidence
    error = $Error
  })
}

function Wait-HuahuoTask {
  param(
    [Parameter(Mandatory = $true)][object]$Api,
    [Parameter(Mandatory = $true)][string]$TaskId,
    [Parameter(Mandatory = $true)][DateTime]$Deadline
  )

  do {
    $reply = Invoke-HuahuoMinutesApi -Api $Api -Method GET -Path "/tasks/$TaskId"
    $task = Get-HuahuoObjectValue -Object $reply -Names @('task')
    $status = Get-HuahuoString (Get-HuahuoObjectValue -Object $task -Names @('status'))
    if ($status -eq 'succeeded') {
      return $task
    }
    if ($status -in @('failed', 'timeout', 'cancelled', 'conflict')) {
      $summary = Get-HuahuoObjectValue -Object $task -Names @('errorSummary')
      $code = Get-HuahuoString (Get-HuahuoObjectValue -Object $summary -Names @('code', 'errorCode'))
      throw "Task $TaskId reached terminal state $status ($code)."
    }
    Start-Sleep -Seconds $PollSeconds
  } while ([DateTime]::UtcNow -lt $Deadline)
  throw "Task $TaskId did not complete before the smoke timeout."
}

function Test-HuahuoNormalChat {
  param(
    [Parameter(Mandatory = $true)][object]$Api,
    [Parameter(Mandatory = $true)][string]$WorkspaceId
  )

  $catalog = Invoke-HuahuoMinutesApi -Api $Api -Method GET -Path '/agent/meta-workspaces'
  $candidates = @(Get-HuahuoItems -Object $catalog | Where-Object {
    $policy = Get-HuahuoObjectValue -Object $_ -Names @('inputPolicy')
    (Get-HuahuoObjectValue -Object $policy -Names @('acceptsText')) -eq $true
  })
  if ($candidates.Count -eq 0) {
    throw 'No selectable text Meta Workspace is available for normal Chat.'
  }
  $selected = @($candidates | Where-Object {
    (Get-HuahuoString (Get-HuahuoObjectValue -Object $_ -Names @('metaWorkspaceKey'))) -eq 'self_media_creation'
  } | Select-Object -First 1)
  if ($selected.Count -eq 0) {
    $selected = @($candidates[0])
  }
  $metaWorkspaceKey = Get-HuahuoRequiredString -Object $selected[0] -Names @('metaWorkspaceKey') -Label 'Meta Workspace key'
  $agentProfileId = Get-HuahuoRequiredString -Object $selected[0] -Names @('agentProfileId') -Label 'Agent profile ID'
  $threadReply = Invoke-HuahuoMinutesApi -Api $Api -Method POST -Path '/chat/threads' `
    -Body @{ workspaceId = $WorkspaceId; scene = 'work_ai' } `
    -IdempotencyKey ('topic-file-chat-thread-' + [guid]::NewGuid().ToString('N'))
  $thread = Get-HuahuoObjectValue -Object $threadReply -Names @('thread')
  $threadId = Get-HuahuoRequiredString -Object $thread -Names @('threadId') -Label 'Chat thread ID'
  $messageBody = @{
    agentProfileId = $agentProfileId
    input = @{ content = @(@{ type = 'text'; text = 'Reply with one concise sentence confirming that normal Chat is available.' }) }
  }
  $messageReply = Invoke-HuahuoMinutesApi -Api $Api -Method POST -Path "/chat/threads/$threadId/messages" `
    -Body $messageBody -IdempotencyKey ('topic-file-chat-message-' + [guid]::NewGuid().ToString('N'))
  $taskId = Get-HuahuoRequiredString -Object $messageReply -Names @('taskId') -Label 'Chat task ID'
  $task = Wait-HuahuoTask -Api $Api -TaskId $taskId -Deadline ([DateTime]::UtcNow.AddSeconds($MaxWaitSeconds))
  $detail = Invoke-HuahuoMinutesApi -Api $Api -Method GET -Path "/chat/threads/$threadId"
  $assistant = @((Get-HuahuoItems -Object @{ items = (Get-HuahuoObjectValue -Object $detail -Names @('messages')) }) | Where-Object {
    (Get-HuahuoString (Get-HuahuoObjectValue -Object $_ -Names @('role'))) -eq 'assistant' -and
    -not [string]::IsNullOrWhiteSpace((Get-HuahuoString (Get-HuahuoObjectValue -Object $_ -Names @('content', 'text'))))
  } | Select-Object -Last 1)
  if ($assistant.Count -eq 0) {
    throw 'Normal Chat completed without a persisted Assistant response.'
  }
  $text = Get-HuahuoString (Get-HuahuoObjectValue -Object $assistant[0] -Names @('content', 'text'))
  return [pscustomobject][ordered]@{
    workspaceId = $WorkspaceId
    metaWorkspaceKey = $metaWorkspaceKey
    agentProfileId = $agentProfileId
    threadId = $threadId
    taskId = $taskId
    taskStatus = Get-HuahuoString (Get-HuahuoObjectValue -Object $task -Names @('status'))
    assistantCharacters = $text.Length
  }
}

function Ensure-HuahuoTopicSourceNotes {
  param(
    [Parameter(Mandatory = $true)][object]$Api,
    [Parameter(Mandatory = $true)][string]$WorkspaceId
  )

  $listed = Invoke-HuahuoMinutesApi -Api $Api -Method GET -Path "/workspaces/$WorkspaceId/notes"
  $eligible = [Collections.Generic.List[object]]::new()
  foreach ($note in (Get-HuahuoItems -Object $listed)) {
    if ((Get-HuahuoString (Get-HuahuoObjectValue -Object $note -Names @('sourceKind'))) -eq 'topic_collision') {
      continue
    }
    $noteId = Get-HuahuoString (Get-HuahuoObjectValue -Object $note -Names @('noteId'))
    if ([string]::IsNullOrWhiteSpace($noteId)) {
      continue
    }
    try {
      $part = Get-HuahuoNotePart -Api $Api -WorkspaceId $WorkspaceId -NoteId $noteId -Part raw
      if (-not [string]::IsNullOrWhiteSpace((Get-HuahuoNotePartMarkdown -PartResponse $part))) {
        $eligible.Add($note)
      }
    } catch {
      continue
    }
  }
  $created = 0
  while (($eligible.Count + $created) -lt 4) {
    $ordinal = $eligible.Count + $created + 1
    $title = "Topic collision smoke source $ordinal"
    $markdown = @(
      "# $title"
      ''
      'This Note is a durable smoke source about creator positioning, audience decisions, evidence boundaries, product trade-offs, and a concrete publishing workflow.'
      ''
      'It deliberately contains several independent claims so the topic-generation Agent can compare tensions across four sources without inventing private facts.'
    ) -join "`n"
    New-HuahuoManualNote -Api $Api -WorkspaceId $WorkspaceId -Title $title -ContentMarkdown $markdown | Out-Null
    $created++
  }
  return [pscustomobject]@{ eligibleBefore = $eligible.Count; created = $created; eligibleAfter = $eligible.Count + $created }
}

function Test-HuahuoNoteFileAgent {
  param(
    [Parameter(Mandatory = $true)][object]$Api,
    [Parameter(Mandatory = $true)][string]$WorkspaceId
  )

  $sourceMarkdown = @(
    '# File Agent smoke source'
    ''
    'The source has three facts: the file contract is the success boundary, the output must be persisted, and a terminal result must retain its revision identity.'
  ) -join "`n"
  $noteId = New-HuahuoManualNote -Api $Api -WorkspaceId $WorkspaceId -Title 'Note File Agent smoke' -ContentMarkdown $sourceMarkdown
  $before = Get-HuahuoNote -Api $Api -WorkspaceId $WorkspaceId -NoteId $noteId
  $rawRevisionId = Get-HuahuoNotePartRevision -Note $before -Part raw
  $outlineRevisionId = Get-HuahuoNotePartRevision -Note $before -Part outline
  $fileAgentBody = @{
    input = @{ part = 'raw'; partRevisionId = $rawRevisionId }
    target = @{ part = 'outline'; partRevisionId = $outlineRevisionId }
    instruction = 'Create a faithful concise outline. Do not invent facts.'
    agentProfileId = 'general_minutes'
    skillProfileIds = @('general_minutes')
  }
  $created = Invoke-HuahuoMinutesApi -Api $Api -Method POST -Path "/workspaces/$WorkspaceId/notes/$noteId/file-agent-runs" `
    -Body $fileAgentBody -IdempotencyKey ('topic-file-note-agent-' + [guid]::NewGuid().ToString('N'))
  $run = Get-HuahuoObjectValue -Object $created -Names @('fileAgentRun')
  $runId = Get-HuahuoRequiredString -Object $run -Names @('fileAgentRunId') -Label 'File Agent Run ID'
  $deadline = [DateTime]::UtcNow.AddSeconds($MaxWaitSeconds)
  do {
    $reply = Invoke-HuahuoMinutesApi -Api $Api -Method GET -Path "/workspaces/$WorkspaceId/notes/$noteId/file-agent-runs/$runId"
    $run = Get-HuahuoObjectValue -Object $reply -Names @('fileAgentRun')
    $status = Get-HuahuoString (Get-HuahuoObjectValue -Object $run -Names @('status'))
    if ($status -eq 'succeeded') { break }
    if ($status -in @('failed', 'conflict', 'cancelled')) {
      $failure = Get-HuahuoObjectValue -Object $run -Names @('failure')
      $code = Get-HuahuoString (Get-HuahuoObjectValue -Object $failure -Names @('code', 'errorCode'))
      throw "Note File Agent reached terminal state $status ($code)."
    }
    Start-Sleep -Seconds $PollSeconds
  } while ([DateTime]::UtcNow -lt $deadline)
  if ($status -ne 'succeeded') {
    throw 'Note File Agent did not complete before the smoke timeout.'
  }
  $outputRevisionId = Get-HuahuoRequiredString -Object $run -Names @('outputPartRevisionId') -Label 'File Agent output revision'
  $outline = Get-HuahuoNotePart -Api $Api -WorkspaceId $WorkspaceId -NoteId $noteId -Part outline
  $markdown = Get-HuahuoNotePartMarkdown -PartResponse $outline
  if ([string]::IsNullOrWhiteSpace($markdown) -or $outputRevisionId -eq $outlineRevisionId) {
    throw 'Note File Agent did not persist a new non-empty outline revision.'
  }
  return [pscustomobject]@{ noteId = $noteId; fileAgentRunId = $runId; outputPartRevisionId = $outputRevisionId; outputBytes = [Text.Encoding]::UTF8.GetByteCount($markdown) }
}

function New-HuahuoCollisionRun {
  param(
    [Parameter(Mandatory = $true)][object]$Account,
    [Parameter(Mandatory = $true)][string]$Key
  )

  $reply = Invoke-HuahuoMinutesApi -Api $Account.Api -Method POST -Path "/workspaces/$($Account.WorkspaceId)/note-topic-collision-runs" `
    -Body @{} -IdempotencyKey $Key
  $run = Get-HuahuoObjectValue -Object $reply -Names @('topicCollisionRun')
  $runId = Get-HuahuoRequiredString -Object $run -Names @('topicCollisionRunId') -Label 'Topic collision Run ID'
  $sources = @(Get-HuahuoObjectValue -Object $run -Names @('sources'))
  if ([int](Get-HuahuoObjectValue -Object $run -Names @('selectedNoteCount')) -ne 4 -or $sources.Count -ne 4) {
    throw "Topic collision Run $runId did not freeze exactly four sources."
  }
  return [pscustomobject]@{ Account = $Account; RunId = $runId; Key = $Key; Initial = $run }
}

function Wait-HuahuoCollisionBatch {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Runs,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.List[object]]$Results,
    [Parameter(Mandatory = $true)][DateTime]$Deadline
  )

  $pending = [Collections.Generic.List[object]]::new()
  foreach ($run in $Runs) { $pending.Add($run) }
  $completed = [Collections.Generic.List[object]]::new()
  while ($pending.Count -gt 0 -and [DateTime]::UtcNow -lt $Deadline) {
    for ($index = $pending.Count - 1; $index -ge 0; $index--) {
      $item = $pending[$index]
      try {
        $reply = Invoke-HuahuoMinutesApi -Api $item.Account.Api -Method GET -Path "/workspaces/$($item.Account.WorkspaceId)/note-topic-collision-runs/$($item.RunId)"
        $run = Get-HuahuoObjectValue -Object $reply -Names @('topicCollisionRun')
        $status = Get-HuahuoString (Get-HuahuoObjectValue -Object $run -Names @('status'))
        if ($status -eq 'succeeded') {
          $completed.Add([pscustomobject]@{ Account = $item.Account; Run = $run })
          $pending.RemoveAt($index)
        } elseif ($status -in @('failed', 'dead_letter')) {
          $code = Get-HuahuoString (Get-HuahuoObjectValue -Object $run -Names @('failureCode'))
          Add-HuahuoSmokeResult -Results $Results -Check "collision:$($item.RunId)" -Status 'failed' -Evidence @{ terminalStatus = $status; failureCode = $code } -Error "Collision terminal failure $status ($code)."
          $pending.RemoveAt($index)
        }
      } catch {
        Add-HuahuoSmokeResult -Results $Results -Check "collision:$($item.RunId)" -Status 'failed' -Error $_.Exception.Message
        $pending.RemoveAt($index)
      }
    }
    if ($pending.Count -gt 0) { Start-Sleep -Seconds $PollSeconds }
  }
  foreach ($item in @($pending)) {
    Add-HuahuoSmokeResult -Results $Results -Check "collision:$($item.RunId)" -Status 'failed' -Error 'Collision Run timed out.'
  }
  return @($completed)
}

function Test-HuahuoCollisionOutput {
  param(
    [Parameter(Mandatory = $true)][object]$Completed,
    [switch]$IncludeSample
  )

  $run = $Completed.Run
  $account = $Completed.Account
  $noteId = Get-HuahuoRequiredString -Object $run -Names @('outputNoteId') -Label 'Collision output Note ID'
  $outputRevisionId = Get-HuahuoRequiredString -Object $run -Names @('outputPartRevisionId') -Label 'Collision output Part revision'
  $outputHash = Get-HuahuoRequiredString -Object $run -Names @('outputHash') -Label 'Collision output content identity'
  $note = Get-HuahuoNote -Api $account.Api -WorkspaceId $account.WorkspaceId -NoteId $noteId
  if ((Get-HuahuoString (Get-HuahuoObjectValue -Object $note -Names @('sourceKind'))) -ne 'topic_collision') {
    throw 'Collision output is not a visible topic_collision HNote.'
  }
  $part = Get-HuahuoNotePart -Api $account.Api -WorkspaceId $account.WorkspaceId -NoteId $noteId -Part raw
  $markdown = Get-HuahuoNotePartMarkdown -PartResponse $part
  $partRevisionId = Get-HuahuoString (Get-HuahuoObjectValue -Object $part -Names @('partRevisionId'))
  $partHash = Get-HuahuoString (Get-HuahuoObjectValue -Object $part -Names @('contentSha256'))
  $topicMatches = [regex]::Matches($markdown, '(?m)^##\s+\d+\.\s+').Count
  $collisionHeading = '### ' + (-join @([char]0x78b0, [char]0x649e, [char]0x5173, [char]0x7cfb))
  $evidenceHeading = '### ' + (-join @([char]0x8bc1, [char]0x636e, [char]0x8fb9, [char]0x754c))
  if ($partRevisionId -ne $outputRevisionId -or $partHash -ne $outputHash -or $topicMatches -lt $MinimumTopics -or
    $markdown -notmatch [regex]::Escape($collisionHeading) -or $markdown -notmatch [regex]::Escape($evidenceHeading) -or
    @('note-01', 'note-02', 'note-03', 'note-04').Where({ $markdown -notmatch [regex]::Escape($_) }).Count -gt 0) {
    throw "Collision output Note failed quality validation (topics=$topicMatches)."
  }
  $evidence = [ordered]@{
    topicCollisionRunId = Get-HuahuoString (Get-HuahuoObjectValue -Object $run -Names @('topicCollisionRunId'))
    workspaceId = $account.WorkspaceId
    outputNoteId = $noteId
    outputPartRevisionId = $outputRevisionId
    topicCount = $topicMatches
    outputCharacters = $markdown.Length
  }
  if ($IncludeSample) {
    $evidence.contentSample = $markdown.Substring(0, [Math]::Min(2000, $markdown.Length))
  }
  return [pscustomobject]$evidence
}

function Get-HuahuoDailyTopicDiagnostic {
  param([Parameter(Mandatory = $true)][object]$Status)

  $failures = Get-HuahuoObjectValue -Object $Status -Names @('failures')
  return [ordered]@{
    campaign = Get-HuahuoObjectValue -Object $Status -Names @('campaign')
    counts = Get-HuahuoObjectValue -Object $Status -Names @('counts')
    errorCounts = Get-HuahuoObjectValue -Object $Status -Names @('errorCounts')
    failureTotal = Get-HuahuoObjectValue -Object $Status -Names @('failureTotal')
    failuresTruncated = Get-HuahuoObjectValue -Object $Status -Names @('failuresTruncated')
    failures = @($failures | Select-Object -First 20)
  }
}

function Invoke-HuahuoTargetedDailyTopic {
  param(
    [Parameter(Mandatory = $true)][object]$AdminApi,
    [Parameter(Mandatory = $true)][object[]]$Accounts
  )

  $dates = [Collections.Generic.List[string]]::new()
  if (-not [string]::IsNullOrWhiteSpace($BusinessDate)) {
    $parsed = [DateTime]::ParseExact($BusinessDate, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $dates.Add($parsed.ToString('yyyy-MM-dd'))
  } else {
    $china = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, 'China Standard Time')
    for ($offset = 0; $offset -le 2; $offset++) { $dates.Add($china.AddDays(-$offset).ToString('yyyy-MM-dd')) }
  }
  $phoneHashes = @($Accounts | ForEach-Object { Get-HuahuoPhoneHash -Phone $_.Phone })
  $selectedDate = ''
  $trigger = $null
  foreach ($date in $dates) {
    try {
      $trigger = Invoke-HuahuoAdminApi -Api $AdminApi -Method POST -Path '/ops/daily-topic/targeted-run' -Body @{
        businessDate = $date
        targetPhoneHashes = $phoneHashes
      }
      $selectedDate = $date
      break
    } catch {
      if ($_.Exception.Message -notmatch 'DAILY_TOPIC_PACKAGE_NOT_READY|DAILY_TOPIC_AUDIENCE_CONFLICT') {
        throw
      }
      if ($_.Exception.Message -match 'DAILY_TOPIC_AUDIENCE_CONFLICT') {
        $selectedDate = $date
        $trigger = [pscustomobject]@{ status = 'existing_campaign'; businessDate = $date }
        break
      }
    }
  }
  if ([string]::IsNullOrWhiteSpace($selectedDate)) {
    throw 'No daily hotspot package was available for the requested date window.'
  }
  $deadline = [DateTime]::UtcNow.AddSeconds($MaxWaitSeconds)
  $deliveries = [Collections.Generic.List[object]]::new()
  foreach ($account in $Accounts) {
    $found = $null
    do {
      $listed = Invoke-HuahuoMinutesApi -Api $account.Api -Method GET -Path "/workspaces/$($account.WorkspaceId)/topic-recommendations?status=ready&limit=100"
      $found = @(Get-HuahuoItems -Object $listed | Where-Object {
        (Get-HuahuoString (Get-HuahuoObjectValue -Object $_ -Names @('businessDate'))) -eq $selectedDate
      } | Select-Object -First 1)
      if ($found.Count -gt 0) { break }

      $opsStatus = Invoke-HuahuoAdminApi -Api $AdminApi -Method GET -Path "/ops/daily-topic/status?businessDate=$selectedDate&failureLimit=200"
      $campaign = Get-HuahuoObjectValue -Object $opsStatus -Names @('campaign')
      $campaignStatus = Get-HuahuoString (Get-HuahuoObjectValue -Object $campaign -Names @('status'))
      $eligibleCount = [int](Get-HuahuoObjectValue -Object $campaign -Names @('eligibleCount'))
      $terminalCount = [int](Get-HuahuoObjectValue -Object $campaign -Names @('terminalCount'))
      if ($campaignStatus -in @('completed', 'completed_with_failures', 'expired') -or
        ($eligibleCount -gt 0 -and $terminalCount -ge $eligibleCount)) {
        $diagnostic = Get-HuahuoDailyTopicDiagnostic -Status $opsStatus
        $diagnosticJson = $diagnostic | ConvertTo-Json -Depth 16 -Compress
        throw "Daily topic campaign reached terminal status '$campaignStatus' without a ready recommendation for workspace $($account.WorkspaceId). diagnostics=$diagnosticJson"
      }
      Start-Sleep -Seconds $PollSeconds
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($found.Count -eq 0) {
      throw "Daily topic recommendation did not become ready for workspace $($account.WorkspaceId)."
    }
    $recommendationId = Get-HuahuoRequiredString -Object $found[0] -Names @('recommendationId') -Label 'Daily recommendation ID'
    $detail = Invoke-HuahuoMinutesApi -Api $account.Api -Method GET -Path "/workspaces/$($account.WorkspaceId)/topic-recommendations/$recommendationId"
    $topics = @(Get-HuahuoObjectValue -Object $detail -Names @('topics'))
    if ($topics.Count -lt $MinimumTopics -or (Get-HuahuoString (Get-HuahuoObjectValue -Object $detail -Names @('status'))) -ne 'ready') {
      throw "Daily recommendation $recommendationId failed content validation."
    }
    $deliveries.Add([pscustomobject]@{ workspaceId = $account.WorkspaceId; recommendationId = $recommendationId; topicCount = $topics.Count })
  }
  return [pscustomobject]@{ businessDate = $selectedDate; triggerStatus = Get-HuahuoString (Get-HuahuoObjectValue -Object $trigger -Names @('status')); deliveries = @($deliveries) }
}

$apiUri = Assert-HuahuoAuthorizedRoot -Value $ApiBase -Path '/api/v1'
$adminUri = Assert-HuahuoAuthorizedRoot -Value $AdminBase -Path '/admin/api/v1'
if ($Phones.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($env:HUAHUO_TOPIC_SMOKE_PHONES)) {
  $Phones = @($env:HUAHUO_TOPIC_SMOKE_PHONES -split ',')
}
$Phones = @($Phones | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } | Select-Object -Unique)
if ($Phones.Count -lt 1 -or @($Phones | Where-Object { $_ -notmatch '^1[0-9]{10}$' }).Count -gt 0) {
  throw 'Supply one or more valid test Phones through -Phones or HUAHUO_TOPIC_SMOKE_PHONES.'
}
if ([string]::IsNullOrWhiteSpace($SmsCode)) {
  throw 'Supply SmsCode through -SmsCode or HUAHUO_TEST_SMS_CODE.'
}
if (-not $SkipDailyTopic -and ([string]::IsNullOrWhiteSpace($AdminLogin) -or [string]::IsNullOrWhiteSpace($AdminPassword))) {
  throw 'Daily topic smoke requires AdminLogin and AdminPassword parameters or environment variables.'
}

$startedAt = [DateTime]::UtcNow
$results = [Collections.Generic.List[object]]::new()
$accounts = [Collections.Generic.List[object]]::new()
$admitted = [Collections.Generic.List[object]]::new()
$completed = [Collections.Generic.List[object]]::new()
$adminApi = $null
try {
  foreach ($phone in $Phones) {
    $api = $null
    try {
      $api = New-HuahuoMinutesApiClient -ApiBase $apiUri.AbsoluteUri
      Set-HuahuoMinutesAccessToken -Api $api -AccessToken '' -Phone $phone -SmsCode $SmsCode
      $workspaceId = Resolve-HuahuoWorkspaceId -Api $api -WorkspaceId ''
      $account = [pscustomobject]@{ Phone = $phone; WorkspaceId = $workspaceId; Api = $api }
      $accounts.Add($account)
      Add-HuahuoSmokeResult -Results $results -Check "login:$workspaceId" -Status 'passed' -Evidence @{ workspaceId = $workspaceId }
    } catch {
      if ($null -ne $api) { Close-HuahuoMinutesApiClient -Api $api }
      Add-HuahuoSmokeResult -Results $results -Check 'login' -Status 'failed' -Error $_.Exception.Message
    }
  }

  if (-not $SkipNormalChat) {
    foreach ($account in @($accounts)) {
      try {
        $chat = Test-HuahuoNormalChat -Api $account.Api -WorkspaceId $account.WorkspaceId
        Add-HuahuoSmokeResult -Results $results -Check "normal_chat:$($account.WorkspaceId)" -Status 'passed' -Evidence $chat
      } catch {
        Add-HuahuoSmokeResult -Results $results -Check "normal_chat:$($account.WorkspaceId)" -Status 'failed' -Error $_.Exception.Message
      }
    }
  }

  foreach ($account in @($accounts)) {
    try {
      $notes = Ensure-HuahuoTopicSourceNotes -Api $account.Api -WorkspaceId $account.WorkspaceId
      Add-HuahuoSmokeResult -Results $results -Check "source_notes:$($account.WorkspaceId)" -Status 'passed' -Evidence $notes
    } catch {
      Add-HuahuoSmokeResult -Results $results -Check "source_notes:$($account.WorkspaceId)" -Status 'failed' -Error $_.Exception.Message
    }
  }

  if (-not $SkipNoteFileAgent) {
    foreach ($account in @($accounts)) {
      try {
        $noteAgent = Test-HuahuoNoteFileAgent -Api $account.Api -WorkspaceId $account.WorkspaceId
        Add-HuahuoSmokeResult -Results $results -Check "note_file_agent:$($account.WorkspaceId)" -Status 'passed' -Evidence $noteAgent
      } catch {
        Add-HuahuoSmokeResult -Results $results -Check "note_file_agent:$($account.WorkspaceId)" -Status 'failed' -Error $_.Exception.Message
      }
    }
  }

  if (-not $SkipDailyTopic -and $accounts.Count -gt 0) {
    try {
      $adminApi = New-HuahuoAdminApiClient -Root $adminUri
      Connect-HuahuoAdminApi -Api $adminApi -Login $AdminLogin -Password $AdminPassword
      $daily = Invoke-HuahuoTargetedDailyTopic -AdminApi $adminApi -Accounts @($accounts)
      Add-HuahuoSmokeResult -Results $results -Check 'daily_topic_targeted' -Status 'passed' -Evidence $daily
    } catch {
      Add-HuahuoSmokeResult -Results $results -Check 'daily_topic_targeted' -Status 'failed' -Error $_.Exception.Message
    }
  }

  $collisionDeadline = [DateTime]::UtcNow.AddSeconds($MaxWaitSeconds)
  $sampleIndex = 0
  $index = 0
  while ($accounts.Count -gt 0 -and $index -lt $CollisionCount) {
    if ([DateTime]::UtcNow -ge $collisionDeadline) {
      while ($index -lt $CollisionCount) {
        Add-HuahuoSmokeResult -Results $results -Check "collision_admission:$index" -Status 'failed' -Error 'Collision suite reached its bounded deadline before admission.'
        $index++
      }
      break
    }

    # Admit at most one Run per Workspace, then wait for that round before the
    # next optimistic Workspace version is frozen.
    $round = [Collections.Generic.List[object]]::new()
    for ($accountIndex = 0; $accountIndex -lt $accounts.Count -and $index -lt $CollisionCount; $accountIndex++) {
      $account = $accounts[$accountIndex]
      $key = 'topic-file-collision-' + [guid]::NewGuid().ToString('N')
      try {
        $created = New-HuahuoCollisionRun -Account $account -Key $key
        $admitted.Add($created)
        $round.Add($created)
        if ($index -eq 0) {
          $replay = New-HuahuoCollisionRun -Account $account -Key $key
          if ($replay.RunId -ne $created.RunId) { throw 'Idempotent collision admission returned another Run ID.' }
          Add-HuahuoSmokeResult -Results $results -Check 'collision_idempotency' -Status 'passed' -Evidence @{ topicCollisionRunId = $created.RunId }
        }
      } catch {
        Add-HuahuoSmokeResult -Results $results -Check "collision_admission:$index" -Status 'failed' -Error $_.Exception.Message
      }
      $index++
    }

    foreach ($item in @(Wait-HuahuoCollisionBatch -Runs @($round) -Results $results -Deadline $collisionDeadline)) {
      $completed.Add($item)
      $runId = Get-HuahuoString (Get-HuahuoObjectValue -Object $item.Run -Names @('topicCollisionRunId'))
      try {
        $evidence = Test-HuahuoCollisionOutput -Completed $item -IncludeSample:($sampleIndex -lt $SampleOutputCount)
        Add-HuahuoSmokeResult -Results $results -Check "collision:$runId" -Status 'passed' -Evidence $evidence
        $sampleIndex++
      } catch {
        Add-HuahuoSmokeResult -Results $results -Check "collision:$runId" -Status 'failed' -Error $_.Exception.Message
      }
    }
  }
  Add-HuahuoSmokeResult -Results $results -Check 'collision_batch_admission' `
    -Status $(if ($admitted.Count -eq $CollisionCount) { 'passed' } else { 'failed' }) `
    -Evidence @{ requested = $CollisionCount; admitted = $admitted.Count } `
    -Error $(if ($admitted.Count -eq $CollisionCount) { '' } else { 'One or more collision admissions failed.' })

  if ($null -ne $adminApi) {
    try {
      $ops = Invoke-HuahuoAdminApi -Api $adminApi -Method GET -Path '/ops/note-topic-collision-runs?limit=200'
      $opsItems = Get-HuahuoItems -Object $ops
      $byId = @{}
      foreach ($item in $opsItems) {
        $id = Get-HuahuoString (Get-HuahuoObjectValue -Object $item -Names @('topicCollisionRunId'))
        if ($id -ne '') { $byId[$id] = $item }
      }
      $missing = @($admitted | Where-Object { -not $byId.ContainsKey($_.RunId) })
      if ($missing.Count -gt 0) { throw "$($missing.Count) admitted collision Runs are missing from Ops." }
      $failurePage = Invoke-HuahuoAdminApi -Api $adminApi -Method GET -Path '/ops/note-topic-collision-runs?failureOnly=true&limit=200'
      Add-HuahuoSmokeResult -Results $results -Check 'collision_ops_visibility' -Status 'passed' -Evidence @{
        batchVisible = $admitted.Count
        failureVisible = (Get-HuahuoItems -Object $failurePage).Count
      }
    } catch {
      Add-HuahuoSmokeResult -Results $results -Check 'collision_ops_visibility' -Status 'failed' -Error $_.Exception.Message
    }
  }
} finally {
  foreach ($account in @($accounts)) {
    Close-HuahuoMinutesApiClient -Api $account.Api
  }
  if ($null -ne $adminApi -and $null -ne $adminApi.Client) {
    $adminApi.Client.Dispose()
  }
}

$failed = @($results | Where-Object { $_.status -ne 'passed' })
$report = [pscustomobject][ordered]@{
  schemaVersion = 'huahuo.topic_file_smoke.v1'
  result = $(if ($failed.Count -eq 0) { 'passed' } else { 'failed' })
  authorizedHost = '39.107.250.25'
  startedAt = $startedAt.ToString('o')
  completedAt = [DateTime]::UtcNow.ToString('o')
  requestedCollisionCount = $CollisionCount
  admittedCollisionCount = $admitted.Count
  completedCollisionCount = $completed.Count
  passedChecks = @($results | Where-Object { $_.status -eq 'passed' }).Count
  failedChecks = $failed.Count
  checks = @($results)
}
$json = $report | ConvertTo-Json -Depth 32
if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
  $parent = Split-Path -Parent $ReportPath
  if (-not [string]::IsNullOrWhiteSpace($parent)) {
    [IO.Directory]::CreateDirectory($parent) | Out-Null
  }
  [IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath), $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}
$json
if ($failed.Count -gt 0) {
  throw "$($failed.Count) topic file smoke checks failed."
}
