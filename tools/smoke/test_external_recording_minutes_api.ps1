<#
.SYNOPSIS
Requests recording-style meeting minutes for an existing transcript Note.

.DESCRIPTION
Reads a transcript Note's current raw and outline revisions, submits the
recording postprocess selector through the public Note File-Agent API, and
verifies the Agent wrote a new non-empty outline revision. MarkdownPath creates
a fresh manual Note first, which is useful for an end-to-end local test.

This is the external equivalent of the recording postprocess selection. It
does not create a Recording object, perform ASR, or claim the internal
recording_minutes source type or meeting_minutes.result.v1 contract.

.EXAMPLE
./scripts/test_external_recording_minutes_api.ps1 `
  -Phone '18800000001' -SmsCode '123456' `
  -MarkdownPath 'E:\test-data\transcript.md'

.EXAMPLE
./scripts/test_external_recording_minutes_api.ps1 `
  -AccessToken $env:HUAHUO_ACCESS_TOKEN `
  -WorkspaceId 'workspace_example' -NoteId 'note_transcript'
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
  [string]$Instruction = 'Create factual meeting minutes from this transcript. Preserve speaker attributions when present. Do not invent speakers, decisions, or facts.',
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
  if ([string]::IsNullOrWhiteSpace($rawRevisionId) -or [string]::IsNullOrWhiteSpace($outlineRevisionId)) {
    throw 'The transcript Note must have current raw and outline part revisions.'
  }

  $request = [ordered]@{
    input = [ordered]@{ part = 'raw'; partRevisionId = $rawRevisionId }
    target = [ordered]@{ part = 'outline'; partRevisionId = $outlineRevisionId }
    instruction = $Instruction
    agentProfileId = 'recording_postprocess_agent'
    skillProfileIds = @('meeting_minutes')
  }
  if (-not [string]::IsNullOrWhiteSpace($ModelProfileId)) {
    $request.modelProfileId = $ModelProfileId
  }
  $created = Invoke-HuahuoMinutesApi -Api $api -Method POST -Path "/workspaces/$WorkspaceId/notes/$NoteId/file-agent-runs" `
    -Body $request -IdempotencyKey ('recording-minutes-note-' + [guid]::NewGuid().ToString('N'))
  $fileAgentRun = Get-HuahuoObjectValue -Object $created -Names @('fileAgentRun')
  $fileAgentRunId = Get-HuahuoString (Get-HuahuoObjectValue -Object $fileAgentRun -Names @('fileAgentRunId'))
  if ([string]::IsNullOrWhiteSpace($fileAgentRunId)) {
    throw 'File-Agent creation did not return fileAgentRunId.'
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
      throw "Recording-style File-Agent run reached terminal state '$status' ($code)."
    }
    Start-Sleep -Seconds $PollSeconds
  }

  if ($null -eq $completed -or (Get-HuahuoString (Get-HuahuoObjectValue -Object $completed -Names @('status'))) -ne 'succeeded') {
    throw "Recording-style File-Agent run did not complete within $MaxWaitSeconds seconds."
  }
  $selector = Get-HuahuoObjectValue -Object $completed -Names @('selector')
  $agentProfileId = Get-HuahuoString (Get-HuahuoObjectValue -Object $selector -Names @('agentProfileId'))
  $skillProfileIds = @(Get-HuahuoObjectValue -Object $selector -Names @('skillProfileIds'))
  if ($agentProfileId -ne 'recording_postprocess_agent' -or $skillProfileIds.Count -ne 1 -or [string]$skillProfileIds[0] -ne 'meeting_minutes') {
    throw 'The completed File-Agent run did not retain the requested recording minutes selector.'
  }

  $outputRevisionId = Get-HuahuoString (Get-HuahuoObjectValue -Object $completed -Names @('outputPartRevisionId'))
  $after = Get-HuahuoNote -Api $api -WorkspaceId $WorkspaceId -NoteId $NoteId
  $actualOutlineRevisionId = Get-HuahuoNotePartRevision -Note $after -Part outline
  $outline = Get-HuahuoNotePart -Api $api -WorkspaceId $WorkspaceId -NoteId $NoteId -Part outline
  $outlineMarkdown = Get-HuahuoNotePartMarkdown -PartResponse $outline
  if ([string]::IsNullOrWhiteSpace($outputRevisionId) -or $outputRevisionId -eq $outlineRevisionId -or
    $actualOutlineRevisionId -ne $outputRevisionId -or [string]::IsNullOrWhiteSpace($outlineMarkdown)) {
    throw 'Recording-style minutes completed without a verified non-empty outline writeback.'
  }

  [pscustomobject][ordered]@{
    result = 'passed'
    workflow = 'recording_minutes_from_transcript_note'
    createdNote = $createdNote
    workspaceId = $WorkspaceId
    noteId = $NoteId
    fileAgentRunId = $fileAgentRunId
    agentRunId = Get-HuahuoString (Get-HuahuoObjectValue -Object $completed -Names @('agentRunId'))
    selector = [ordered]@{ agentProfileId = $agentProfileId; skillProfileIds = $skillProfileIds }
    inputRawRevisionId = $rawRevisionId
    previousOutlineRevisionId = $outlineRevisionId
    outputOutlineRevisionId = $outputRevisionId
    outputBytes = [Text.Encoding]::UTF8.GetByteCount($outlineMarkdown)
  } | ConvertTo-Json -Depth 8
} finally {
  Close-HuahuoMinutesApiClient -Api $api
}
