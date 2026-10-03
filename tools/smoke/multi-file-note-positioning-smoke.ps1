param(
    [Parameter(Mandatory = $true)][string]$Phone,
    [Parameter(Mandatory = $true)][string]$Code,
    [string]$BaseUrl = "http://39.107.250.25"
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Net.Http

$script:AccessToken = ""
$script:Sequence = 0
$runKey = "multi-file-smoke-{0}-{1}" -f [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(), $PID
$utf8 = New-Object System.Text.UTF8Encoding($false)
$handler = New-Object System.Net.Http.HttpClientHandler
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds(100)

function Write-Stage {
    param([string]$Stage, [hashtable]$Data = @{})
    $event = [ordered]@{ stage = $Stage; ok = $true }
    foreach ($key in $Data.Keys) { $event[$key] = $Data[$key] }
    [Console]::Out.WriteLine(($event | ConvertTo-Json -Compress -Depth 12))
}

function Stop-Smoke {
    param(
        [string]$Stage,
        [string]$Reason,
        [int]$HttpStatus = 0,
        [string]$ErrorCode = "",
        [string]$Detail = ""
    )
    $event = [ordered]@{
        stage = $Stage
        ok = $false
        reason = $Reason
        httpStatus = $HttpStatus
        errorCode = $ErrorCode
        detail = $Detail
    }
    [Console]::Out.WriteLine(($event | ConvertTo-Json -Compress -Depth 12))
    $client.Dispose()
    exit 1
}

function Get-ErrorCode {
    param($Json)
    if ($null -eq $Json) { return "" }
    if ($null -ne $Json.error -and $null -ne $Json.error.code) { return [string]$Json.error.code }
    if ($null -ne $Json.code) { return [string]$Json.code }
    return ""
}

function Get-Data {
    param($Json)
    if ($null -ne $Json -and $null -ne $Json.PSObject.Properties["data"]) { return $Json.data }
    return $Json
}

function Invoke-Request {
    param(
        [string]$Method,
        [string]$Url,
        $Body = $null,
        [string]$IdempotencyKey = "",
        [byte[]]$Bytes = $null,
        $ExtraHeaders = $null,
        [bool]$UseAuth = $true
    )
    $script:Sequence++
    $traceId = "{0}-{1}" -f $runKey, $script:Sequence
    $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::new($Method), $Url)
    $null = $request.Headers.TryAddWithoutValidation("Accept", "application/json")
    $null = $request.Headers.TryAddWithoutValidation("X-Trace-Id", $traceId)
    $null = $request.Headers.TryAddWithoutValidation("X-Request-Id", $traceId)
    $null = $request.Headers.TryAddWithoutValidation("X-Device-Id", $runKey)
    if ($IdempotencyKey) { $null = $request.Headers.TryAddWithoutValidation("X-Idempotency-Key", $IdempotencyKey) }
    if ($UseAuth -and $script:AccessToken) { $null = $request.Headers.TryAddWithoutValidation("Authorization", "Bearer $($script:AccessToken)") }

    if ($null -ne $Bytes) {
        $request.Content = New-Object System.Net.Http.ByteArrayContent(,$Bytes)
    } elseif ($null -ne $Body) {
        $jsonBody = $Body | ConvertTo-Json -Compress -Depth 40
        $request.Content = New-Object System.Net.Http.ByteArrayContent(,$utf8.GetBytes($jsonBody))
        $request.Content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("application/json; charset=utf-8")
    }

    if ($null -ne $ExtraHeaders) {
        foreach ($property in $ExtraHeaders.PSObject.Properties) {
            $name = [string]$property.Name
            $value = [string]$property.Value
            if (-not $request.Headers.TryAddWithoutValidation($name, $value)) {
                if ($null -eq $request.Content) { $request.Content = New-Object System.Net.Http.ByteArrayContent(,[byte[]]@()) }
                $null = $request.Content.Headers.TryAddWithoutValidation($name, $value)
            }
        }
    }

    try {
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $raw = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    } catch {
        $request.Dispose()
        Stop-Smoke -Stage "transport" -Reason "HTTP transport failed" -Detail $_.Exception.Message
    }
    $request.Dispose()
    $parsed = $null
    if ($raw) {
        try { $parsed = $raw | ConvertFrom-Json } catch { $parsed = $null }
    }
    return [pscustomobject]@{ Status = [int]$response.StatusCode; Raw = $raw; Json = $parsed }
}

function Require-Success {
    param([string]$Stage, $Result)
    if ($Result.Status -lt 200 -or $Result.Status -ge 300) {
        $preview = [string]$Result.Raw
        if ($preview.Length -gt 700) { $preview = $preview.Substring(0, 700) }
        Stop-Smoke -Stage $Stage -Reason "API request failed" -HttpStatus $Result.Status -ErrorCode (Get-ErrorCode $Result.Json) -Detail $preview
    }
    return (Get-Data $Result.Json)
}

function New-Thread {
    param([string]$Label)
    $result = Invoke-Request -Method "POST" -Url "$BaseUrl/api/v1/chat/threads" -Body @{} -IdempotencyKey "$runKey-thread-$Label"
    $data = Require-Success "thread-$Label" $result
    $threadId = ""
    if ($null -ne $data.thread -and $null -ne $data.thread.threadId) { $threadId = [string]$data.thread.threadId }
    elseif ($null -ne $data.threadId) { $threadId = [string]$data.threadId }
    if (-not $threadId) { Stop-Smoke -Stage "thread-$Label" -Reason "threadId missing" }
    return $threadId
}

function Get-RunStatusData {
    param($Data)
    if ($null -ne $Data.run) { return $Data.run }
    return $Data
}

function Get-AssistantReply {
    param([string]$ThreadId, [string]$Label)
    $result = Invoke-Request -Method "GET" -Url "$BaseUrl/api/v1/chat/threads/$ThreadId"
    $data = Require-Success "thread-readback-$Label" $result
    $messages = @($data.messages | Where-Object { [string]$_.role -eq "assistant" })
    if ($messages.Count -eq 0) { Stop-Smoke -Stage "thread-readback-$Label" -Reason "assistant message missing" }
    $message = $messages[-1]
    if ($message.content -is [string]) { return [string]$message.content }
    if ($null -ne $message.payload) {
        foreach ($name in @("reply", "content", "text")) {
            if ($null -ne $message.payload.PSObject.Properties[$name] -and [string]$message.payload.$name) { return [string]$message.payload.$name }
        }
    }
    if ($null -ne $message.content) { return ($message.content | ConvertTo-Json -Compress -Depth 20) }
    Stop-Smoke -Stage "thread-readback-$Label" -Reason "assistant content missing"
}

function Invoke-AgentRun {
    param(
        [string]$Label,
        [string]$AgentProfileId,
        [string]$Prompt,
        [string]$ThreadId = "",
        $WorkspaceDocument = $null,
        $Attachments = $null
    )
    if (-not $ThreadId) { $ThreadId = New-Thread $Label }
    $content = New-Object System.Collections.ArrayList
    $null = $content.Add([ordered]@{ type = "text"; text = $Prompt })
    if ($null -ne $WorkspaceDocument) {
        $null = $content.Add([ordered]@{
            type = "workspace_document"
            source = [ordered]@{
                kind = "workspace_document"
                ownerRef = [ordered]@{ kind = "hnote"; id = $WorkspaceDocument.NoteId }
                part = "raw"
                partRevisionId = $WorkspaceDocument.PartRevisionId
            }
            usage = "reference"
        })
    }
    if ($null -ne $Attachments) {
        foreach ($attachment in @($Attachments)) {
            $null = $content.Add([ordered]@{
                type = "file"
                source = [ordered]@{ kind = "resource"; resourceId = [string]$attachment.resourceId }
                usage = [string]$attachment.usage
            })
        }
    }
    $body = [ordered]@{
        agentProfileId = $AgentProfileId
        input = [ordered]@{ content = @($content) }
    }

    $submit = Invoke-Request -Method "POST" -Url "$BaseUrl/api/v1/chat/threads/$ThreadId/messages" -Body $body -IdempotencyKey "$runKey-message-$Label"
    $submitData = Require-Success "submit-$Label" $submit
    $runId = ""
    if ($null -ne $submitData.agentRunId) { $runId = [string]$submitData.agentRunId }
    elseif ($null -ne $submitData.run -and $null -ne $submitData.run.agentRunId) { $runId = [string]$submitData.run.agentRunId }
    elseif ($null -ne $submitData.run -and $null -ne $submitData.run.runId) { $runId = [string]$submitData.run.runId }
    if (-not $runId) { Stop-Smoke -Stage "submit-$Label" -Reason "agentRunId missing" }
    Write-Stage "run-submitted-$Label" @{ runId = $runId; threadId = $ThreadId }

    $terminal = $null
    for ($attempt = 0; $attempt -lt 180; $attempt++) {
        Start-Sleep -Seconds 2
        $poll = Invoke-Request -Method "GET" -Url "$BaseUrl/api/v1/agent/runs/$runId"
        $pollData = Require-Success "poll-$Label" $poll
        $run = Get-RunStatusData $pollData
        $status = [string]$run.status
        if ($status -in @("succeeded", "failed", "timeout", "cancelled", "orphaned")) { $terminal = $run; break }
    }
    if ($null -eq $terminal) { Stop-Smoke -Stage "run-$Label" -Reason "run did not reach terminal state" -Detail $runId }
    if ([string]$terminal.status -ne "succeeded") {
        $code = ""
        if ($null -ne $terminal.error -and $null -ne $terminal.error.code) { $code = [string]$terminal.error.code }
        elseif ($null -ne $terminal.errorCode) { $code = [string]$terminal.errorCode }
        $terminalPreview = $terminal | ConvertTo-Json -Compress -Depth 16
        if ($terminalPreview.Length -gt 1200) { $terminalPreview = $terminalPreview.Substring(0, 1200) }
        Stop-Smoke -Stage "run-$Label" -Reason "agent run failed" -ErrorCode $code -Detail $terminalPreview
    }
    $reply = Get-AssistantReply -ThreadId $ThreadId -Label $Label
    $preview = $reply -replace "[\r\n]+", " "
    if ($preview.Length -gt 320) { $preview = $preview.Substring(0, 320) }
    Write-Stage "run-succeeded-$Label" @{ runId = $runId; replyPreview = $preview }
    return [pscustomobject]@{ RunId = $runId; ThreadId = $ThreadId; Reply = $reply }
}

function Get-NotePart {
    param([string]$WorkspaceId, [string]$NoteId, [string]$Stage)
    $result = Invoke-Request -Method "GET" -Url "$BaseUrl/api/v1/workspaces/$WorkspaceId/notes/$NoteId/parts/raw"
    $data = Require-Success $Stage $result
    $content = [string]$data.contentMarkdown
    $revision = [string]$data.partRevisionId
    if (-not $revision -and $null -ne $data.part) { $revision = [string]$data.part.partRevisionId }
    if (-not $revision -and $null -ne $data.revision) { $revision = [string]$data.revision.partRevisionId }
    if (-not $revision) { $revision = [string]$data.currentPartRevisionId }
    if (-not $revision) { Stop-Smoke -Stage $Stage -Reason "partRevisionId missing" }
    return [pscustomobject]@{ Content = $content; PartRevisionId = $revision }
}

function Upload-Markdown {
    param([string]$WorkspaceId, [string]$Label, [string]$Content)
    $bytes = $utf8.GetBytes($Content)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join "" } finally { $sha.Dispose() }
    $tokenBody = [ordered]@{
        sourceScene = "workspace_attachment"
        workspaceId = $WorkspaceId
        fileName = "$Label.md"
        mimeType = "text/markdown"
        sizeBytes = $bytes.Length
        sha256 = "sha256:$hash"
    }
    $tokenResult = Invoke-Request -Method "POST" -Url "$BaseUrl/api/v1/media/upload-token" -Body $tokenBody -IdempotencyKey "$runKey-upload-token-$Label"
    $token = Require-Success "upload-token-$Label" $tokenResult
    $uploadId = [string]$token.uploadId
    $resourceId = [string]$token.resourceId
    $uploadUrl = [string]$token.uploadUrl
    if (-not $uploadId -or -not $resourceId -or -not $uploadUrl) { Stop-Smoke -Stage "upload-token-$Label" -Reason "upload credential incomplete" }

    $put = Invoke-Request -Method ([string]$token.method) -Url $uploadUrl -Bytes $bytes -ExtraHeaders $token.headers -UseAuth $false
    if ($put.Status -lt 200 -or $put.Status -ge 300) {
        Stop-Smoke -Stage "upload-bytes-$Label" -Reason "object upload failed" -HttpStatus $put.Status -Detail $put.Raw
    }
    $completeBody = [ordered]@{ workspaceId = $WorkspaceId }
    $completeResult = Invoke-Request -Method "POST" -Url "$BaseUrl/api/v1/media/uploads/$uploadId/complete" -Body $completeBody -IdempotencyKey "$runKey-upload-complete-$Label"
    $complete = Require-Success "upload-complete-$Label" $completeResult
    $completedResourceId = ""
    if ($null -ne $complete.resource) { $completedResourceId = [string]$complete.resource.resourceId }
    if (-not $completedResourceId) { $completedResourceId = $resourceId }
    if ($completedResourceId -ne $resourceId) { Stop-Smoke -Stage "upload-complete-$Label" -Reason "resource identity changed" }
    Write-Stage "upload-completed-$Label" @{ resourceId = $resourceId; sizeBytes = $bytes.Length }
    return $resourceId
}

try {
    $loginBody = [ordered]@{
        phone = $Phone
        code = $Code
        smsRequestId = ""
        deviceId = $runKey
        agreementAccepted = $true
        agreementVersion = "v0.1"
        privacyVersion = "v0.1"
        clientVersion = "multi-file-agent-smoke"
        timeZone = "Asia/Shanghai"
    }
    $loginResult = Invoke-Request -Method "POST" -Url "$BaseUrl/api/v1/auth/login" -Body $loginBody -IdempotencyKey "$runKey-login" -UseAuth $false
    $login = Require-Success "login" $loginResult
    $script:AccessToken = [string]$login.accessToken
    $workspaceId = ""
    if ($null -ne $login.workspace) { $workspaceId = [string]$login.workspace.workspaceId }
    if (-not $workspaceId) { $workspaceId = [string]$login.workspaceId }
    if (-not $script:AccessToken -or -not $workspaceId) { Stop-Smoke -Stage "login" -Reason "login response missing accessToken or workspaceId" }
    Write-Stage "login" @{ workspaceId = $workspaceId }

    $catalogResult = Invoke-Request -Method "GET" -Url "$BaseUrl/api/v1/agent-profiles"
    $catalog = Require-Success "agent-catalog" $catalogResult
    $items = @($catalog.items)
    $lv1 = @($items | Where-Object { [string]$_.agentProfileId -eq "positioning_lv1" } | Select-Object -First 1)
    $normal = @($items | Where-Object { [string]$_.agentProfileId -eq "self_media_creation_standard" } | Select-Object -First 1)
    if ($normal.Count -eq 0) { $normal = @($items | Where-Object { [string]$_.agentProfileId -eq "normal_agent" } | Select-Object -First 1) }
    if ($lv1.Count -eq 0 -or $normal.Count -eq 0) { Stop-Smoke -Stage "agent-catalog" -Reason "required Agent Profile missing" }
    $lv1ProfileId = [string]$lv1[0].agentProfileId
    $normalProfileId = [string]$normal[0].agentProfileId
    Write-Stage "agent-catalog" @{ normal = $normalProfileId; positioningLv1 = $lv1ProfileId }

    $noteMarker = "NOTE_$($runKey.Replace('-', '_'))"
    $alphaMarker = "ALPHA_$($runKey.Replace('-', '_'))"
    $betaMarker = "BETA_$($runKey.Replace('-', '_'))"
    $pendingMarker = "EDIT_STATUS=PENDING_$($runKey.Replace('-', '_'))"
    $completedMarker = "EDIT_STATUS=COMPLETED_$($runKey.Replace('-', '_'))"
    $noteBody = "# Multi-input smoke note`n`nNOTE_MARKER=$noteMarker`n$pendingMarker`n`nThis is a formal Workspace Note used for runtime read and writeback verification."
    $createNoteBody = [ordered]@{ title = "[smoke] multi-file note $runKey"; contentMarkdown = $noteBody }
    $createNoteResult = Invoke-Request -Method "POST" -Url "$BaseUrl/api/v1/workspaces/$workspaceId/notes/manual" -Body $createNoteBody -IdempotencyKey "$runKey-note-create"
    $createdNote = Require-Success "note-create" $createNoteResult
    $noteId = ""
    if ($null -ne $createdNote.note) { $noteId = [string]$createdNote.note.noteId }
    if (-not $noteId) { $noteId = [string]$createdNote.noteId }
    if (-not $noteId) { Stop-Smoke -Stage "note-create" -Reason "noteId missing" }
    $notePart = Get-NotePart -WorkspaceId $workspaceId -NoteId $noteId -Stage "note-read-before"
    if (-not $notePart.Content.Contains($noteMarker)) { Stop-Smoke -Stage "note-read-before" -Reason "created Note marker missing" }
    Write-Stage "note-selected" @{ noteId = $noteId; partRevisionId = $notePart.PartRevisionId }

    $alphaResource = Upload-Markdown -WorkspaceId $workspaceId -Label "alpha-$runKey" -Content "# External alpha`n`nALPHA_MARKER=$alphaMarker`nThis file is an external Markdown attachment."
    $betaResource = Upload-Markdown -WorkspaceId $workspaceId -Label "beta-$runKey" -Content "# External beta`n`nBETA_MARKER=$betaMarker`nThis is the second external Markdown attachment."
    $document = [pscustomobject]@{ NoteId = $noteId; PartRevisionId = $notePart.PartRevisionId }
    $attachments = @(
        [ordered]@{ resourceId = $alphaResource; usage = "reference" },
        [ordered]@{ resourceId = $betaResource; usage = "reference" }
    )
    $multiPrompt = "Read the attached Workspace Note and both external Markdown attachments. Return exactly three lines named NOTE, ALPHA, and BETA. Each value must be copied from the corresponding *_MARKER field in the files. Do not guess and do not omit any file."
    $multiRun = Invoke-AgentRun -Label "multi-file-read" -AgentProfileId $normalProfileId -Prompt $multiPrompt -WorkspaceDocument $document -Attachments $attachments
    foreach ($marker in @($noteMarker, $alphaMarker, $betaMarker)) {
        if (-not $multiRun.Reply.Contains($marker)) {
            $preview = $multiRun.Reply -replace "[\r\n]+", " "
            if ($preview.Length -gt 700) { $preview = $preview.Substring(0, 700) }
            Stop-Smoke -Stage "multi-file-marker-verification" -Reason "Agent did not return all file markers" -Detail $preview
        }
    }
    Write-Stage "multi-file-marker-verification" @{ runId = $multiRun.RunId; note = $true; markdownAlpha = $true; markdownBeta = $true }

    $editPrompt = "Edit the attached Workspace Note itself. Replace the exact line '$pendingMarker' with '$completedMarker'. Preserve all other content. Use the workspace edit or write tool, then reply WRITEBACK_DONE."
    $editRun = Invoke-AgentRun -Label "note-writeback" -AgentProfileId $normalProfileId -Prompt $editPrompt -WorkspaceDocument $document
    $updatedPart = $null
    for ($attempt = 0; $attempt -lt 15; $attempt++) {
        $updatedPart = Get-NotePart -WorkspaceId $workspaceId -NoteId $noteId -Stage "note-read-after-writeback"
        if ($updatedPart.Content.Contains($completedMarker)) { break }
        Start-Sleep -Seconds 2
    }
    if (-not $updatedPart.Content.Contains($completedMarker)) {
        Stop-Smoke -Stage "note-writeback-verification" -Reason "Run succeeded but formal Note content was not updated" -Detail $editRun.RunId
    }
    if ($updatedPart.PartRevisionId -eq $notePart.PartRevisionId) {
        Stop-Smoke -Stage "note-writeback-verification" -Reason "Note content changed without a new part revision" -Detail $editRun.RunId
    }
    Write-Stage "note-writeback-verification" @{ runId = $editRun.RunId; oldRevision = $notePart.PartRevisionId; newRevision = $updatedPart.PartRevisionId }

    $profileBeforeResult = Invoke-Request -Method "GET" -Url "$BaseUrl/api/v1/workspaces/current/profile"
    $profileBefore = ""
    if ($profileBeforeResult.Status -ge 200 -and $profileBeforeResult.Status -lt 300) { $profileBefore = $profileBeforeResult.Raw }
    $lv1Prompt = @"
Create and save a complete LV1 user positioning report from this onboarding questionnaire.

Current state: no stable business orders.
Clear audience: local women homeowners, renovation contractors, and small factory owners.
Direction: combine real aluminum-alloy factory operations with motherhood and family-business life.
Strengths: eight years of factory operation, quotations, material selection, production, installation, and customer communication.
Usual concerns: cash flow, delivery dates, quality control, local renovation needs, and parenting.
Reading habit: industry news and parenting articles.
Previous work: runs a local aluminum-alloy door and window factory while caring for children.
Education: marketing.
Distinctive durable fact: the main product is thermal-break aluminum doors and windows.

The report must include: initial positioning judgment; confirmed information; missing key information; best next questions; and account content/expression advice. Persist the resulting positioning to the current user's formal positioning profile before replying.
"@
    $lv1Run = Invoke-AgentRun -Label "positioning-lv1" -AgentProfileId $lv1ProfileId -Prompt $lv1Prompt
    $profileAfterResult = Invoke-Request -Method "GET" -Url "$BaseUrl/api/v1/workspaces/current/profile"
    $profileAfterData = Require-Success "profile-read-after-lv1" $profileAfterResult
    $profileAfter = $profileAfterData | ConvertTo-Json -Compress -Depth 30
    $personaRegex = "thermal[- ]break|factory|aluminum|mother|mom|\u65AD\u6865\u94DD|\u94DD\u5408\u91D1|\u5B9D\u5988"
    if ($profileAfter -notmatch $personaRegex) {
        Stop-Smoke -Stage "positioning-persistence-verification" -Reason "formal profile does not contain the submitted persona" -Detail $lv1Run.RunId
    }
    if ($profileAfter -eq $profileBefore) {
        Stop-Smoke -Stage "positioning-persistence-verification" -Reason "formal profile did not change after LV1" -Detail $lv1Run.RunId
    }
    Write-Stage "positioning-persistence-verification" @{ runId = $lv1Run.RunId; profileChanged = $true; personaFound = $true }

    $followPrompt = "Read the current user's saved formal positioning profile. Based only on that profile, propose three short-video topics. Start by stating the user's factory type, family role, and main product. If the profile is unavailable, say PROFILE_NOT_FOUND."
    $followRun = Invoke-AgentRun -Label "normal-profile-followup" -AgentProfileId $normalProfileId -Prompt $followPrompt
    if ($followRun.Reply -match "PROFILE_NOT_FOUND" -or $followRun.Reply -notmatch $personaRegex) {
        $preview = $followRun.Reply -replace "[\r\n]+", " "
        if ($preview.Length -gt 700) { $preview = $preview.Substring(0, 700) }
        Stop-Smoke -Stage "normal-profile-read-verification" -Reason "normal Agent did not use the saved positioning profile" -Detail $preview
    }
    Write-Stage "normal-profile-read-verification" @{ runId = $followRun.RunId; profileUsed = $true }

    Write-Output ([ordered]@{
        stage = "complete"
        ok = $true
        host = "39.107.250.25"
        workspaceId = $workspaceId
        noteId = $noteId
        runs = [ordered]@{
            multiFileRead = $multiRun.RunId
            noteWriteback = $editRun.RunId
            positioningLv1 = $lv1Run.RunId
            normalProfileFollowup = $followRun.RunId
        }
    } | ConvertTo-Json -Compress -Depth 12)
} finally {
    $script:AccessToken = ""
    $client.Dispose()
}
