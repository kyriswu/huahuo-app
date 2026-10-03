<#
.SYNOPSIS
Requests a Faya viewpoint germination write for an existing Note.

.DESCRIPTION
Reads the Note's current raw and germination revisions, requests the public
faya_germination Agent Profile plus viewpoint_germination Skill Profile,
waits for completion, and verifies that the Agent wrote a new non-empty
germination revision instead of changing the outline.

.EXAMPLE
./scripts/test_external_faya_germination_api.ps1 `
  -Phone $env:HUAHUO_TEST_PHONE -SmsCode $env:HUAHUO_TEST_SMS_CODE `
  -MarkdownPath 'E:\test-data\article.md'

.EXAMPLE
./scripts/test_external_faya_germination_api.ps1 `
  -AccessToken $env:HUAHUO_ACCESS_TOKEN `
  -WorkspaceId 'workspace_example' -NoteId 'note_example'
#>
[CmdletBinding()]
param(
  [string]$ApiBase = 'http://39.107.250.25/api/v1',
  [string]$AccessToken = $env:HUAHUO_ACCESS_TOKEN,
  [string]$Phone = $env:HUAHUO_TEST_PHONE,
  [string]$SmsCode = $env:HUAHUO_TEST_SMS_CODE,
  [string]$WorkspaceId = '',
  [string]$NoteId = '',
  [string]$MarkdownPath = '',
  [string]$Title = '',
  [string]$Instruction = 'Read the source faithfully and grow one genuinely new, well-supported viewpoint from it. Write the complete Markdown result to the germination file.',
  [string]$ModelProfileId = '',
  [ValidateRange(30, 1800)][int]$MaxWaitSeconds = 600,
  [ValidateRange(1, 30)][int]$PollSeconds = 3,
  [switch]$AllowLoopback
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

. (Join-Path $PSScriptRoot 'minutes_api_common.ps1')

$NoteId = Get-HuahuoString $NoteId
$MarkdownPath = Get-HuahuoString $MarkdownPath
$Title = Get-HuahuoString $Title
$Instruction = Get-HuahuoString $Instruction
$ModelProfileId = Get-HuahuoString $ModelProfileId
if (($NoteId -eq '') -eq ($MarkdownPath -eq '') -or [string]::IsNullOrWhiteSpace($Instruction)) {
  throw 'Specify exactly one of NoteId or MarkdownPath, and provide Instruction.'
}
if ($MarkdownPath -ne '' -and -not (Test-Path -LiteralPath $MarkdownPath -PathType Leaf)) {
  throw 'MarkdownPath must name an existing file.'
}

$api = New-HuahuoMinutesApiClient -ApiBase $ApiBase -AccessToken $AccessToken -AllowLoopback:$AllowLoopback
try {
  Set-HuahuoMinutesAccessToken -Api $api -AccessToken $AccessToken -Phone $Phone -SmsCode $SmsCode
  $WorkspaceId = Resolve-HuahuoWorkspaceId -Api $api -WorkspaceId $WorkspaceId
  $createdNote = $false
  if ($MarkdownPath -ne '') {
    $content = Get-Content -LiteralPath $MarkdownPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($Title)) {
      $Title = [IO.Path]::GetFileNameWithoutExtension($MarkdownPath)
    }
    $NoteId = New-HuahuoManualNote -Api $api -WorkspaceId $WorkspaceId -Title $Title -ContentMarkdown $content
    $createdNote = $true
  }

  $before = Get-HuahuoNote -Api $api -WorkspaceId $WorkspaceId -NoteId $NoteId
  $rawRevisionId = Get-HuahuoNotePartRevision -Note $before -Part raw
  $outlineRevisionId = Get-HuahuoNotePartRevision -Note $before -Part outline
  $germinationRevisionId = Get-HuahuoNotePartRevision -Note $before -Part germination
  if ([string]::IsNullOrWhiteSpace($rawRevisionId) -or [string]::IsNullOrWhiteSpace($germinationRevisionId)) {
    throw 'The Note must have current raw and germination part revisions.'
  }

  $request = [ordered]@{
    input = [ordered]@{ part = 'raw'; partRevisionId = $rawRevisionId }
    target = [ordered]@{ part = 'germination'; partRevisionId = $germinationRevisionId }
    instruction = $Instruction
    agentProfileId = 'faya_germination'
    skillProfileIds = @('viewpoint_germination')
  }
  if (-not [string]::IsNullOrWhiteSpace($ModelProfileId)) {
    $request.modelProfileId = $ModelProfileId
  }
  $created = Invoke-HuahuoMinutesApi -Api $api -Method POST -Path "/workspaces/$WorkspaceId/notes/$NoteId/file-agent-runs" `
    -Body $request -IdempotencyKey ('faya-germination-' + [guid]::NewGuid().ToString('N'))
  $fileAgentRun = Get-HuahuoObjectValue -Object $created -Names @('fileAgentRun')
  $fileAgentRunId = Get-HuahuoString (Get-HuahuoObjectValue -Object $fileAgentRun -Names @('fileAgentRunId'))
  if ([string]::IsNullOrWhiteSpace($fileAgentRunId)) {
    throw 'Faya File-Agent creation did not return fileAgentRunId.'
  }

  $deadline = [DateTime]::UtcNow.AddSeconds($MaxWaitSeconds)
  $completed = $null
  while ([DateTime]::UtcNow -lt $deadline) {
    $statusReply = Invoke-HuahuoMinutesApi -Api $api -Method GET -Path "/workspaces/$WorkspaceId/notes/$NoteId/file-agent-runs/$fileAgentRunId"
    $completed = Get-HuahuoObjectValue -Object $statusReply -Names @('fileAgentRun')
    $status = Get-HuahuoString (Get-HuahuoObjectValue -Object $completed -Names @('status'))
    if ($status -eq 'succeeded') {
      break
    }
    if ($status -in @('failed', 'conflict', 'cancelled')) {
      $failure = Get-HuahuoObjectValue -Object $completed -Names @('failure')
      $code = Get-HuahuoString (Get-HuahuoObjectValue -Object $failure -Names @('code', 'errorCode'))
      throw "Faya File-Agent run reached terminal state '$status' ($code)."
    }
    Start-Sleep -Seconds $PollSeconds
  }

  if ($null -eq $completed -or (Get-HuahuoString (Get-HuahuoObjectValue -Object $completed -Names @('status'))) -ne 'succeeded') {
    throw "Faya File-Agent run did not complete within $MaxWaitSeconds seconds."
  }
  $selector = Get-HuahuoObjectValue -Object $completed -Names @('selector')
  $agentProfileId = Get-HuahuoString (Get-HuahuoObjectValue -Object $selector -Names @('agentProfileId'))
  $skillProfileIds = @(Get-HuahuoObjectValue -Object $selector -Names @('skillProfileIds'))
  if ($agentProfileId -ne 'faya_germination' -or $skillProfileIds.Count -ne 1 -or [string]$skillProfileIds[0] -ne 'viewpoint_germination') {
    throw 'The completed File-Agent run did not retain the requested Faya selector.'
  }

  $outputRevisionId = Get-HuahuoString (Get-HuahuoObjectValue -Object $completed -Names @('outputPartRevisionId'))
  $after = Get-HuahuoNote -Api $api -WorkspaceId $WorkspaceId -NoteId $NoteId
  $actualOutlineRevisionId = Get-HuahuoNotePartRevision -Note $after -Part outline
  $actualGerminationRevisionId = Get-HuahuoNotePartRevision -Note $after -Part germination
  $germination = Get-HuahuoNotePart -Api $api -WorkspaceId $WorkspaceId -NoteId $NoteId -Part germination
  $germinationMarkdown = Get-HuahuoNotePartMarkdown -PartResponse $germination
  if ([string]::IsNullOrWhiteSpace($outputRevisionId) -or $outputRevisionId -eq $germinationRevisionId -or
    $actualGerminationRevisionId -ne $outputRevisionId -or [string]::IsNullOrWhiteSpace($germinationMarkdown)) {
    throw 'Faya completed without a verified non-empty germination writeback.'
  }
  if ($actualOutlineRevisionId -ne $outlineRevisionId) {
    throw 'Faya unexpectedly changed the Note outline revision.'
  }

  [pscustomobject][ordered]@{
    result = 'passed'
    workflow = 'faya_germination'
    createdNote = $createdNote
    workspaceId = $WorkspaceId
    noteId = $NoteId
    fileAgentRunId = $fileAgentRunId
    agentRunId = Get-HuahuoString (Get-HuahuoObjectValue -Object $completed -Names @('agentRunId'))
    selector = [ordered]@{ agentProfileId = $agentProfileId; skillProfileIds = $skillProfileIds }
    inputRawRevisionId = $rawRevisionId
    unchangedOutlineRevisionId = $actualOutlineRevisionId
    previousGerminationRevisionId = $germinationRevisionId
    outputGerminationRevisionId = $outputRevisionId
    outputBytes = [Text.Encoding]::UTF8.GetByteCount($germinationMarkdown)
  } | ConvertTo-Json -Depth 8
} finally {
  Close-HuahuoMinutesApiClient -Api $api
}
