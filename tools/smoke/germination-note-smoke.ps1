[CmdletBinding(DefaultParameterSetName = "ExistingNote")]
param(
    [Parameter(Mandatory = $true)][string]$Phone,
    [Parameter(Mandatory = $true)][Security.SecureString]$Code,
    [Parameter(Mandatory = $true, ParameterSetName = "ExistingNote")][string]$NoteId,
    [Parameter(Mandatory = $true, ParameterSetName = "SourceFile")][string]$SourceFile,
    [string]$AgentProfileId = "",
    [string]$BaseUrl = "http://39.107.250.25",
    [ValidateRange(30, 900)][int]$TimeoutSeconds = 420,
    [ValidateRange(1, 10)][int]$PollIntervalSeconds = 3,
    [string]$OutputPath = "",
    [switch]$AllowNoViableSeed
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
Add-Type -AssemblyName System.Net.Http

$baseUri = [Uri]$BaseUrl.TrimEnd("/")
if ($baseUri.Scheme -notin @("http", "https") -or
    $baseUri.DnsSafeHost -ne "39.107.250.25" -or
    $baseUri.UserInfo -or $baseUri.Query -or $baseUri.Fragment) {
    throw "BaseUrl must target the authorized host 39.107.250.25."
}
$BaseUrl = $baseUri.AbsoluteUri.TrimEnd("/")

$sourceFileFullPath = ""
if ($SourceFile) {
    $sourceFileFullPath = [IO.Path]::GetFullPath($SourceFile)
    if (-not [IO.File]::Exists($sourceFileFullPath)) {
        throw "SourceFile does not exist: $sourceFileFullPath"
    }
}

$script:AccessToken = ""
$script:Sequence = 0
$runKey = "germination-note-smoke-{0}-{1}" -f [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(), $PID
$utf8 = New-Object System.Text.UTF8Encoding($false)
$handler = New-Object System.Net.Http.HttpClientHandler
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds(100)
$plainCode = $null

function Write-Stage {
    param([string]$Stage, [hashtable]$Data = @{})
    $event = [ordered]@{ stage = $Stage; ok = $true }
    foreach ($key in $Data.Keys) { $event[$key] = $Data[$key] }
    [Console]::Out.WriteLine(($event | ConvertTo-Json -Compress -Depth 20))
}

function Fail-Smoke {
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
    [Console]::Out.WriteLine(($event | ConvertTo-Json -Compress -Depth 20))
    throw "Germination smoke failed at stage '$Stage': $Reason"
}

function ConvertTo-PlainText {
    param([Security.SecureString]$Value)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Get-Value {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-PathValue {
    param($Object, [string[]]$Paths)
    foreach ($path in $Paths) {
        $current = $Object
        $found = $true
        foreach ($part in $path.Split(".")) {
            $current = Get-Value -Object $current -Name $part
            if ($null -eq $current) { $found = $false; break }
        }
        if ($found -and -not [string]::IsNullOrWhiteSpace([string]$current)) { return $current }
    }
    return $null
}

function Get-Data {
    param($Json)
    $data = Get-Value -Object $Json -Name "data"
    if ($null -ne $data) { return $data }
    return $Json
}

function Get-ErrorCode {
    param($Json)
    return [string](Get-PathValue -Object $Json -Paths @("error.code", "code"))
}

function Invoke-Request {
    param(
        [string]$Method,
        [string]$Url,
        $Body = $null,
        [string]$IdempotencyKey = "",
        [bool]$UseAuth = $true
    )
    $script:Sequence++
    $traceId = "{0}-{1}" -f $runKey, $script:Sequence
    $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::new($Method), $Url)
    $null = $request.Headers.TryAddWithoutValidation("Accept", "application/json")
    $null = $request.Headers.TryAddWithoutValidation("X-Trace-Id", $traceId)
    $null = $request.Headers.TryAddWithoutValidation("X-Request-Id", $traceId)
    $null = $request.Headers.TryAddWithoutValidation("X-Device-Id", $runKey)
    $null = $request.Headers.TryAddWithoutValidation("X-Client-Version", "germination-note-smoke/1.0")
    if ($IdempotencyKey) { $null = $request.Headers.TryAddWithoutValidation("X-Idempotency-Key", $IdempotencyKey) }
    if ($UseAuth -and $script:AccessToken) {
        $null = $request.Headers.TryAddWithoutValidation("Authorization", "Bearer $($script:AccessToken)")
    }
    if ($null -ne $Body) {
        $json = $Body | ConvertTo-Json -Compress -Depth 40
        $request.Content = New-Object System.Net.Http.ByteArrayContent(,$utf8.GetBytes($json))
        $request.Content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("application/json; charset=utf-8")
    }

    try {
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        try { $raw = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() }
        finally { $status = [int]$response.StatusCode; $response.Dispose() }
    } catch {
        $request.Dispose()
        Fail-Smoke -Stage "transport" -Reason "HTTP transport failed" -Detail $_.Exception.Message
    }
    $request.Dispose()
    $parsed = $null
    if ($raw) {
        try { $parsed = $raw | ConvertFrom-Json } catch { $parsed = $null }
    }
    return [pscustomobject]@{ Status = $status; Raw = $raw; Json = $parsed }
}

function Require-Success {
    param([string]$Stage, $Result)
    if ($Result.Status -lt 200 -or $Result.Status -ge 300) {
        $preview = [string]$Result.Raw
        if ($preview.Length -gt 900) { $preview = $preview.Substring(0, 900) }
        Fail-Smoke -Stage $Stage -Reason "API request failed" -HttpStatus $Result.Status -ErrorCode (Get-ErrorCode $Result.Json) -Detail $preview
    }
    return (Get-Data $Result.Json)
}

function Get-NotePart {
    param([string]$WorkspaceId, [string]$Part, [bool]$Optional = $false)
    $result = Invoke-Request -Method "GET" -Url "$BaseUrl/api/v1/workspaces/$WorkspaceId/notes/$NoteId/parts/$Part"
    if ($Optional -and $result.Status -eq 404) {
        return [pscustomobject]@{ Exists = $false; Content = ""; PartRevisionId = "" }
    }
    $data = Require-Success "note-$Part-read" $result
    $revision = [string](Get-PathValue -Object $data -Paths @("partRevisionId", "part.partRevisionId", "revision.partRevisionId", "currentPartRevisionId"))
    $content = [string](Get-PathValue -Object $data -Paths @("contentMarkdown", "part.contentMarkdown", "revision.contentMarkdown"))
    if (-not $revision) { Fail-Smoke -Stage "note-$Part-read" -Reason "partRevisionId missing" }
    return [pscustomobject]@{ Exists = $true; Content = $content; PartRevisionId = $revision }
}

function Select-GerminationAgentProfile {
    param($CatalogData)
    $items = @(Get-Value -Object $CatalogData -Name "items")
    if ($items.Count -eq 0) { $items = @(Get-Value -Object $CatalogData -Name "agentProfiles") }
    if ($items.Count -eq 0) { Fail-Smoke -Stage "agent-catalog" -Reason "Agent catalog is empty" }

    if ($AgentProfileId) {
        $exact = @($items | Where-Object { [string](Get-Value $_ "agentProfileId") -eq $AgentProfileId })
        if ($exact.Count -eq 0) { Fail-Smoke -Stage "agent-catalog" -Reason "Requested Agent Profile is unavailable" -Detail $AgentProfileId }
        return $AgentProfileId
    }

    $preferred = @($items | Where-Object { [string](Get-Value $_ "agentProfileId") -eq "faya_agent" })
    if ($preferred.Count -gt 0) { return "faya_agent" }

    $matches = @($items | Where-Object {
        $json = $_ | ConvertTo-Json -Compress -Depth 12
        $json -match '(?i)faya_germination|work_ai_faya_germination|viewpoint_germination|faya_agent'
    })
    if ($matches.Count -ne 1) {
        Fail-Smoke -Stage "agent-catalog" -Reason "Could not uniquely resolve the Faya germination Agent" -Detail "matches=$($matches.Count)"
    }
    $resolved = [string](Get-Value $matches[0] "agentProfileId")
    if (-not $resolved) { Fail-Smoke -Stage "agent-catalog" -Reason "Resolved Agent Profile has no public ID" }
    return $resolved
}

function Get-AssistantReply {
    param([string]$ThreadId, [string]$AssistantMessageId)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(20)
    do {
        $result = Invoke-Request -Method "GET" -Url "$BaseUrl/api/v1/chat/threads/$ThreadId"
        $data = Require-Success "thread-readback" $result
        $messages = @(Get-Value -Object $data -Name "messages")
        $candidates = @($messages | Where-Object { [string](Get-Value $_ "role") -eq "assistant" })
        if ($AssistantMessageId) {
            $matched = @($candidates | Where-Object {
                [string](Get-PathValue $_ @("messageId", "id")) -eq $AssistantMessageId
            })
            if ($matched.Count -gt 0) { $candidates = $matched }
        }
        if ($candidates.Count -gt 0) {
            $message = $candidates[-1]
            $reply = [string](Get-PathValue -Object $message -Paths @("content", "payload.reply", "payload.content", "text"))
            if (-not [string]::IsNullOrWhiteSpace($reply)) { return $reply }
        }
        Start-Sleep -Seconds 1
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    Fail-Smoke -Stage "thread-readback" -Reason "Persisted Assistant reply missing"
}

try {
    $plainCode = ConvertTo-PlainText -Value $Code
    $loginBody = [ordered]@{
        phone = $Phone
        code = $plainCode
        smsRequestId = ""
        deviceId = $runKey
        agreementAccepted = $true
        agreementVersion = "v0.1"
        privacyVersion = "v0.1"
        clientVersion = "germination-note-smoke"
        timeZone = "Asia/Shanghai"
    }
    $loginResult = Invoke-Request -Method "POST" -Url "$BaseUrl/api/v1/auth/login" -Body $loginBody -IdempotencyKey "$runKey-login" -UseAuth $false
    $login = Require-Success "login" $loginResult
    $script:AccessToken = [string](Get-Value -Object $login -Name "accessToken")
    $workspaceId = [string](Get-PathValue -Object $login -Paths @("workspace.workspaceId", "workspaceId"))
    if (-not $script:AccessToken -or -not $workspaceId) { Fail-Smoke -Stage "login" -Reason "Login response is incomplete" }
    Write-Stage "login"

    if ($sourceFileFullPath) {
        $sourceContent = [IO.File]::ReadAllText($sourceFileFullPath, $utf8)
        if ([string]::IsNullOrWhiteSpace($sourceContent)) { Fail-Smoke -Stage "note-create" -Reason "SourceFile is empty" }
        $sourceTitle = [IO.Path]::GetFileNameWithoutExtension($sourceFileFullPath)
        $createNoteBody = [ordered]@{
            title = "[smoke] germination $sourceTitle $([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
            contentMarkdown = $sourceContent
        }
        $createNoteResult = Invoke-Request -Method "POST" -Url "$BaseUrl/api/v1/workspaces/$workspaceId/notes/manual" -Body $createNoteBody -IdempotencyKey "$runKey-note-create"
        $createdNote = Require-Success "note-create" $createNoteResult
        $NoteId = [string](Get-PathValue -Object $createdNote -Paths @("note.noteId", "noteId"))
        if (-not $NoteId) { Fail-Smoke -Stage "note-create" -Reason "noteId missing" }
        Write-Stage "note-created" @{ noteId = $NoteId; sourceFile = $sourceFileFullPath }
    }

    $catalogResult = Invoke-Request -Method "GET" -Url "$BaseUrl/api/v1/agent-profiles"
    $catalog = Require-Success "agent-catalog" $catalogResult
    $resolvedAgentProfileId = Select-GerminationAgentProfile -CatalogData $catalog
    Write-Stage "agent-catalog" @{ agentProfileId = $resolvedAgentProfileId }

    $rawPart = Get-NotePart -WorkspaceId $workspaceId -Part "raw"
    if ([string]::IsNullOrWhiteSpace($rawPart.Content)) { Fail-Smoke -Stage "note-raw-read" -Reason "The source Note is empty" }
    $germinationBefore = Get-NotePart -WorkspaceId $workspaceId -Part "germination" -Optional $true
    Write-Stage "note-frozen" @{ noteId = $NoteId; sourcePartRevisionId = $rawPart.PartRevisionId }

    $threadResult = Invoke-Request -Method "POST" -Url "$BaseUrl/api/v1/chat/threads" -Body @{} -IdempotencyKey "$runKey-thread"
    $threadData = Require-Success "thread-create" $threadResult
    $threadId = [string](Get-PathValue -Object $threadData -Paths @("thread.threadId", "threadId"))
    if (-not $threadId) { Fail-Smoke -Stage "thread-create" -Reason "threadId missing" }

    $prompt = "Use the attached Workspace Note raw revision as the source material. Perform the Faya viewpoint germination task and produce one independent Chinese Markdown insight article. Follow the canonical viewpoint_germination.result.v2 contract. This is a read-only generation test; do not modify the Note or any Workspace file."
    $messageBody = [ordered]@{
        agentProfileId = $resolvedAgentProfileId
        input = [ordered]@{
            content = @(
                [ordered]@{ type = "text"; text = $prompt },
                [ordered]@{
                    type = "workspace_document"
                    source = [ordered]@{
                        kind = "workspace_document"
                        ownerRef = [ordered]@{ kind = "hnote"; id = $NoteId }
                        part = "raw"
                        partRevisionId = $rawPart.PartRevisionId
                    }
                    usage = "reference"
                }
            )
        }
    }
    $submitResult = Invoke-Request -Method "POST" -Url "$BaseUrl/api/v1/chat/threads/$threadId/messages" -Body $messageBody -IdempotencyKey "$runKey-message"
    $submit = Require-Success "run-submit" $submitResult
    $runId = [string](Get-PathValue -Object $submit -Paths @("agentRunId", "run.agentRunId", "nextAction.agentRunId"))
    if (-not $runId) { Fail-Smoke -Stage "run-submit" -Reason "agentRunId missing" }
    Write-Stage "run-submitted" @{ agentRunId = $runId; threadId = $threadId }

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    $terminal = $null
    do {
        Start-Sleep -Seconds $PollIntervalSeconds
        $pollResult = Invoke-Request -Method "GET" -Url "$BaseUrl/api/v1/agent/runs/$runId"
        $pollData = Require-Success "run-poll" $pollResult
        $run = Get-Value -Object $pollData -Name "run"
        if ($null -eq $run) { $run = $pollData }
        $status = [string](Get-Value -Object $run -Name "status")
        if ($status -in @("succeeded", "failed", "timeout", "cancelled", "orphaned")) { $terminal = $run; break }
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    if ($null -eq $terminal) { Fail-Smoke -Stage "run-poll" -Reason "Run did not reach a terminal state" -Detail $runId }
    if ([string](Get-Value $terminal "status") -ne "succeeded") {
        $errorCode = [string](Get-PathValue -Object $terminal -Paths @("error.code", "errorCode"))
        $detail = $terminal | ConvertTo-Json -Compress -Depth 20
        if ($detail.Length -gt 1200) { $detail = $detail.Substring(0, 1200) }
        Fail-Smoke -Stage "run-terminal" -Reason "Agent Run failed" -ErrorCode $errorCode -Detail $detail
    }

    $assistantMessageId = [string](Get-PathValue -Object $terminal -Paths @("result.assistantMessageId", "assistantMessageId"))
    if (-not $assistantMessageId) { Fail-Smoke -Stage "run-terminal" -Reason "Terminal success omitted assistantMessageId" }
    $finalAnswer = [string](Get-PathValue -Object $terminal -Paths @("result.finalAnswer"))
    if ([string]::IsNullOrWhiteSpace($finalAnswer)) { Fail-Smoke -Stage "run-terminal" -Reason "Terminal success omitted finalAnswer" }

    try { $envelope = $finalAnswer | ConvertFrom-Json }
    catch { Fail-Smoke -Stage "result-contract" -Reason "finalAnswer is not a valid JSON envelope" -Detail $_.Exception.Message }
    $schemaVersion = [string](Get-Value $envelope "schemaVersion")
    $taskType = [string](Get-Value $envelope "taskType")
    $skillProfile = [string](Get-Value $envelope "skillProfile")
    $resultStatus = [string](Get-Value $envelope "status")
    $visibleReply = [string](Get-PathValue -Object $envelope -Paths @("data.reply"))
    if ($schemaVersion -ne "viewpoint_germination.result.v2" -or
        $taskType -ne "work_ai_faya_germination" -or
        $skillProfile -ne "viewpoint_germination" -or
        $resultStatus -notin @("succeeded", "no_viable_seed") -or
        [string]::IsNullOrWhiteSpace($visibleReply)) {
        Fail-Smoke -Stage "result-contract" -Reason "Faya V2 envelope is invalid" -Detail "schema=$schemaVersion taskType=$taskType skill=$skillProfile status=$resultStatus"
    }
    if ($resultStatus -eq "no_viable_seed" -and -not $AllowNoViableSeed) {
        Fail-Smoke -Stage "result-contract" -Reason "Faya returned no_viable_seed" -Detail $visibleReply
    }

    $assistantReply = Get-AssistantReply -ThreadId $threadId -AssistantMessageId $assistantMessageId
    if (-not ($assistantReply.Contains($visibleReply) -or $visibleReply.Contains($assistantReply))) {
        Fail-Smoke -Stage "assistant-projection" -Reason "Persisted Assistant reply does not match data.reply"
    }

    $germinationAfter = Get-NotePart -WorkspaceId $workspaceId -Part "germination" -Optional $true
    $writeDetected = ($germinationBefore.Exists -ne $germinationAfter.Exists) -or
        ($germinationBefore.Exists -and $germinationAfter.Exists -and $germinationBefore.PartRevisionId -ne $germinationAfter.PartRevisionId)
    if ($writeDetected) {
        Fail-Smoke -Stage "read-only-boundary" -Reason "Ordinary Faya Run changed the Note germination Part"
    }

    if (-not $OutputPath) {
        $safeNoteId = $NoteId -replace '[^A-Za-z0-9._-]', '_'
        $OutputPath = Join-Path $PSScriptRoot ("germination-result-{0}-{1}.md" -f $safeNoteId, [DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    }
    $fullOutputPath = [IO.Path]::GetFullPath($OutputPath)
    $outputDirectory = [IO.Path]::GetDirectoryName($fullOutputPath)
    if (-not [IO.Directory]::Exists($outputDirectory)) { Fail-Smoke -Stage "result-save" -Reason "Output directory does not exist" -Detail $outputDirectory }
    [IO.File]::WriteAllText($fullOutputPath, $visibleReply, $utf8)

    Write-Stage "complete" @{
        host = "39.107.250.25"
        noteId = $NoteId
        sourcePartRevisionId = $rawPart.PartRevisionId
        agentProfileId = $resolvedAgentProfileId
        agentRunId = $runId
        threadId = $threadId
        resultStatus = $resultStatus
        assistantPersisted = $true
        workspaceWriteDetected = $false
        outputPath = $fullOutputPath
    }
} finally {
    $script:AccessToken = ""
    $plainCode = $null
    $Code = $null
    $client.Dispose()
    $handler.Dispose()
}
