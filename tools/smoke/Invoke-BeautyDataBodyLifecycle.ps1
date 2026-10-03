[CmdletBinding()]
param(
  [string]$Phone = '18800000003',
  [string]$SmsCode = '123456',
  [string]$BaseUrl = 'http://39.107.250.25',
  [string]$ResumePositioningRunId = '',
  [switch]$SkipInitialTopicAgents,
  [switch]$SkipCreationAgent,
  [ValidateRange(120, 1200)][int]$TimeoutSeconds = 600
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Utf8 = [Text.UTF8Encoding]::new($false)
$RunKey = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$EvidenceRoot = Join-Path $PSScriptRoot "evidence-$RunKey"
New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null

function Save-Json([string]$Name, $Value) {
  [IO.File]::WriteAllText((Join-Path $EvidenceRoot $Name), ($Value | ConvertTo-Json -Depth 40), $Utf8)
}

function Save-Text([string]$Name, [string]$Value) {
  [IO.File]::WriteAllText((Join-Path $EvidenceRoot $Name), $Value, $Utf8)
}

function Api([string]$Method, [string]$Path, $Body = $null, [string]$Token = '', [string]$Key = '', [string]$IfMatch = '') {
  $headers = @{}
  if ($Token) { $headers.Authorization = "Bearer $Token" }
  if ($Key) { $headers['X-Idempotency-Key'] = $Key }
  if ($IfMatch) { $headers['If-Match'] = $IfMatch }
  $args = @{ Method = $Method; Uri = $BaseUrl.TrimEnd('/') + $Path; Headers = $headers; UseBasicParsing = $true; TimeoutSec = 60 }
  if ($null -ne $Body) {
    $args.ContentType = 'application/json'
    $args.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 30 -Compress))
  }
  try { $response = Invoke-RestMethod @args }
  catch {
    $detail = if ($_.ErrorDetails -and $_.ErrorDetails.PSObject.Properties['Message']) { [string]$_.ErrorDetails.Message } else { [string]$_.Exception.Message }
    throw "API_FAILED:${Method}:${Path}:$detail"
  }
  if ($null -ne $response -and $response.PSObject.Properties['data']) { return $response.data }
  return $response
}

function Assert-That([bool]$Condition, [string]$Name) {
  if (-not $Condition) { throw "ASSERTION_FAILED:$Name" }
  $script:Assertions.Add([ordered]@{ name = $Name; passed = $true })
}

function Wait-Run([string]$RunId, [string]$Token) {
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  do {
    $run = Api GET "/api/v1/agent/runs/$RunId" $null $Token
    if ([string]$run.status -in @('succeeded', 'failed', 'timeout', 'cancelled', 'aborted', 'rejected', 'orphaned')) { return $run }
    Start-Sleep -Seconds 2
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "RUN_TIMEOUT:$RunId"
}

function Wait-Task([string]$TaskId, [string]$Token) {
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  do {
    $view = Api GET "/api/v1/tasks/$TaskId" $null $Token
    $task = if ($view.PSObject.Properties['task']) { $view.task } else { $view }
    if ([string]$task.status -in @('succeeded', 'failed', 'timeout', 'dead_letter', 'cancelled')) { return $task }
    Start-Sleep -Seconds 2
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "TASK_TIMEOUT:$TaskId"
}

function Wait-Proposal([string]$ProposalId, [string]$Token, [string]$WorkspaceId) {
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  do {
    $proposal = Api GET "/api/v1/workspaces/$WorkspaceId/document-change-proposals/$ProposalId" $null $Token
    if ([string]$proposal.state -notin @('generating', 'applying')) { return $proposal }
    Start-Sleep -Seconds 2
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "PROPOSAL_TIMEOUT:$ProposalId"
}

function Wait-Assistant([string]$ThreadId, [string]$TaskId, [string]$Token) {
  $deadline = [DateTime]::UtcNow.AddSeconds(90)
  do {
    $thread = Api GET "/api/v1/chat/threads/$ThreadId" $null $Token
    $items = @($thread.messages | Where-Object {
      $messageTask = if ($_.PSObject.Properties['taskId']) { [string]$_.taskId } elseif ($_.PSObject.Properties['task_id']) { [string]$_.task_id } else { '' }
      [string]$_.role -eq 'assistant' -and $messageTask -eq $TaskId
    })
    if ($items.Count) {
      $message = $items[-1]
      foreach ($name in @('content', 'reply', 'text')) {
        if ($message.PSObject.Properties[$name] -and $message.$name -is [string] -and $message.$name) { return [string]$message.$name }
        if ($message.PSObject.Properties['payload'] -and $message.payload.PSObject.Properties[$name] -and $message.payload.$name -is [string] -and $message.payload.$name) { return [string]$message.payload.$name }
      }
    }
    Start-Sleep -Seconds 1
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "ASSISTANT_MISSING:$TaskId"
}

function Get-Invocation([string]$ThreadId, [string]$RunId, [string]$Token) {
  $deadline = [DateTime]::UtcNow.AddSeconds(90)
  do {
    try { return Api GET "/api/v1/chat/threads/$ThreadId/runtime-invocations/$RunId" $null $Token } catch { Start-Sleep -Seconds 1 }
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "INVOCATION_MISSING:$RunId"
}

function New-Thread([string]$Token, [string]$WorkspaceId, [string]$Label) {
  $value = Api POST '/api/v1/chat/threads' @{ workspaceId = $WorkspaceId; scene = 'workspace_chat' } $Token "beauty-$RunKey-$Label-thread"
  if ($value.PSObject.Properties['thread']) { return [string]$value.thread.threadId }
  return [string]$value.threadId
}

function Submit-Agent([string]$Agent, [string]$Prompt, [string]$ThreadId, [string]$Token, [string]$Label) {
  $value = Api POST "/api/v1/chat/threads/$ThreadId/messages" @{
    agentProfileId = $Agent
    input = @{ content = @(@{ type = 'text'; text = $Prompt }) }
  } $Token "beauty-$RunKey-$Label-message"
  $runId = [string]$value.agentRunId
  $taskId = [string]$value.taskId
  if (-not $runId -and $value.PSObject.Properties['run']) { $runId = [string]$value.run.agentRunId }
  if (-not $taskId -and $value.PSObject.Properties['run']) { $taskId = [string]$value.run.taskId }
  return [ordered]@{ runId = $runId; taskId = $taskId }
}

function Run-Agent([string]$Agent, [string]$Prompt, [string]$Token, [string]$WorkspaceId, [string]$Label) {
  $started = [DateTime]::UtcNow
  $threadId = New-Thread $Token $WorkspaceId $Label
  $submitted = Submit-Agent $Agent $Prompt $threadId $Token $Label
  $run = Wait-Run $submitted.runId $Token
  Assert-That ([string]$run.status -eq 'succeeded') "$Label-run-succeeded"
  $assistant = Wait-Assistant $threadId $submitted.taskId $Token
  $invocation = Get-Invocation $threadId $submitted.runId $Token
  Assert-That ([string]$invocation.selection.agentProfileId -eq $Agent) "$Label-agent-selected"
  Save-Text "$Label-assistant.md" $assistant
  Save-Json "$Label-invocation.json" $invocation
  return [ordered]@{
    agentProfileId = $Agent; threadId = $threadId; runId = $submitted.runId; taskId = $submitted.taskId
    elapsedSeconds = [Math]::Round(([DateTime]::UtcNow - $started).TotalSeconds, 3); assistant = $assistant; invocation = $invocation
  }
}

function Upload-Object($Upload, [string]$Path) {
  $headers = @{}
  $contentType = $null
  foreach ($property in @($Upload.headers.PSObject.Properties)) {
    if ($property.Name -ieq 'Content-Type') { $contentType = [string]$property.Value } else { $headers[$property.Name] = [string]$property.Value }
  }
  $args = @{ Method = $(if ($Upload.method) { [string]$Upload.method } else { 'PUT' }); Uri = [string]$Upload.uploadUrl; Headers = $headers; InFile = $Path; UseBasicParsing = $true; TimeoutSec = 120 }
  if ($contentType) { $args.ContentType = $contentType }
  $response = Invoke-WebRequest @args
  if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300) { throw 'OBJECT_UPLOAD_FAILED' }
}

function Wait-NewProposals([DateTime]$After, [string]$Token, [string]$WorkspaceId) {
  $stamp = [Uri]::EscapeDataString($After.ToUniversalTime().ToString('o'))
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  do {
    $page = Api GET "/api/v1/workspaces/$WorkspaceId/document-change-proposals?updatedAfter=$stamp&limit=50" $null $Token
    if (@($page.items).Count -ge 3) { return @($page.items) }
    Start-Sleep -Seconds 2
  } while ([DateTime]::UtcNow -lt $deadline)
  throw 'PROPOSAL_DISCOVERY_TIMEOUT'
}

function Wait-Confirmation([string]$ConfirmationId, [string]$Token, [string]$WorkspaceId) {
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  do {
    $value = Api GET "/api/v1/workspaces/$WorkspaceId/digital-twin/confirmations/$ConfirmationId" $null $Token
    if ([string]$value.state -eq 'report_ready') { return $value }
    if ([string]$value.state -in @('failed', 'cancelled')) { throw "CONFIRMATION_FAILED:$ConfirmationId" }
    Start-Sleep -Seconds 2
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "CONFIRMATION_TIMEOUT:$ConfirmationId"
}

function Distill-And-Confirm([string]$FileName, [string]$Content, [string]$Token, [string]$WorkspaceId, [string]$Label) {
  $path = Join-Path $EvidenceRoot $FileName
  Save-Text $FileName $Content
  $file = Get-Item -LiteralPath $path
  $started = [DateTime]::UtcNow.AddSeconds(-1)
  $upload = Api POST '/api/v1/media/upload-token' @{
    sourceScene = 'note_import'; fileName = $file.Name; mimeType = 'text/markdown'; sizeBytes = [int64]$file.Length
    sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant(); distillToDigitalTwin = $true
  } $Token "beauty-$RunKey-$Label-upload"
  Upload-Object $upload $path
  $complete = Api POST "/api/v1/media/uploads/$($upload.uploadId)/complete" @{} $Token "beauty-$RunKey-$Label-complete"
  $taskId = [string]$complete.digitalTwinDistillation.taskId
  $task = Wait-Task $taskId $Token
  Assert-That ([string]$task.status -eq 'succeeded') "$Label-distillation-succeeded"
  $found = @(Wait-NewProposals $started $Token $WorkspaceId)
  $ready = [Collections.Generic.List[object]]::new()
  $proposalEvidence = [Collections.Generic.List[object]]::new()
  foreach ($item in $found) {
    $proposal = Wait-Proposal ([string]$item.proposalId) $Token $WorkspaceId
    if ([string]$proposal.state -ne 'ready') { continue }
    $candidate = Api GET "/api/v1/workspaces/$WorkspaceId/document-change-proposals/$($proposal.proposalId)/versions/$($proposal.proposalVersion)/candidate" $null $Token
    $diff = Api GET "/api/v1/workspaces/$WorkspaceId/document-change-proposals/$($proposal.proposalId)/versions/$($proposal.proposalVersion)/diff" $null $Token
    $kind = if ($proposal.target.metadata.PSObject.Properties['profileKind']) { [string]$proposal.target.metadata.profileKind } else { 'positioning' }
    $proposalEvidence.Add([ordered]@{
      proposalId = [string]$proposal.proposalId; ownerKind = [string]$proposal.target.ownerRef.kind; profileKind = $kind
      proposalVersion = [int]$proposal.proposalVersion; hasChanges = [bool]$proposal.hasChanges; hunkCount = @($diff.items).Count
      sourceRefCount = @($proposal.target.metadata.sourceRefs).Count; candidateLength = ([string]$candidate.text).Length
    })
    if ($proposal.hasChanges -eq $true) {
      $ready.Add($proposal)
    } else {
      $etag = '"dcp:' + [string]$proposal.proposalId + ':' + [string]$proposal.rowVersion + '"'
      $null = Api POST "/api/v1/workspaces/$WorkspaceId/document-change-proposals/$($proposal.proposalId)/reject" @{ reasonCode = 'user_declined' } $Token "beauty-$RunKey-$Label-reject-$($proposal.proposalId)" $etag
    }
  }
  Assert-That ($proposalEvidence.Count -ge 3) "$Label-proposals-created"
  Assert-That ($ready.Count -ge 1) "$Label-has-reviewable-change"
  $refs = @($ready | ForEach-Object {
    [ordered]@{ proposalId = [string]$_.proposalId; proposalVersion = [int]$_.proposalVersion; etag = ('"dcp:' + [string]$_.proposalId + ':' + [string]$_.rowVersion + '"') }
  })
  $confirmation = Api POST "/api/v1/workspaces/$WorkspaceId/digital-twin/confirmations" @{
    proposals = $refs; sourceTaskId = $taskId; triggerId = [string]$upload.resourceId
  } $Token "beauty-$RunKey-$Label-confirm"
  $confirmation = Wait-Confirmation ([string]$confirmation.confirmationTaskId) $Token $WorkspaceId
  Assert-That ([int]$confirmation.appliedCount -ge 1 -and [bool]$confirmation.version.versionId) "$Label-confirmed"
  Save-Json "$Label-proposals.json" $proposalEvidence
  Save-Json "$Label-confirmation.json" $confirmation
  return [ordered]@{
    resourceId = [string]$upload.resourceId; taskId = $taskId; proposalCount = $proposalEvidence.Count
    appliedCount = [int]$confirmation.appliedCount; versionId = [string]$confirmation.version.versionId
    versionNumber = [int]$confirmation.version.versionNumber; proposals = @($proposalEvidence)
  }
}

$Assertions = [Collections.Generic.List[object]]::new()
$StartedAt = [DateTime]::UtcNow

$sms = Api POST '/api/v1/auth/sms-code' @{ phone = $Phone; scene = 'login' }
$login = Api POST '/api/v1/auth/login' @{
  phone = $Phone; smsRequestId = [string]$sms.smsRequestId; code = $SmsCode; deviceId = "beauty-lifecycle-$RunKey"
  agreementAccepted = $true; agreementVersion = 'qa-20260830'; privacyVersion = 'qa-20260830'
  clientVersion = 'qa-beauty-data-body-lifecycle'; timeZone = 'Asia/Shanghai'
}
$Token = [string]$login.accessToken
$WorkspaceId = [string]$login.workspace.workspaceId
Assert-That ([bool]$Token -and [bool]$WorkspaceId) 'login-resolved'
$before = Api GET "/api/v1/workspaces/$WorkspaceId/initial-positioning/current" $null $Token
if ($ResumePositioningRunId) {
  Assert-That ([string]$before.state -eq 'completed' -and [string]$before.agentRunId -eq $ResumePositioningRunId) 'positioning-resume-visible'
} else {
  Assert-That ([string]$before.state -eq 'not_started') 'initial-positioning-reset-visible'
}

$positionPrompt = @'
请作为账号定位智能体，根据下面的新用户启动问卷，生成一份可直接使用的用户定位报告，并完成 LV1 定位文件。

用户当前状态：

- 你的客户更偏向哪里？：主要在郑州及周边城市，28—45 岁的职场女性、宝妈和个体经营者。她们对轻医美有兴趣，但怕踩坑、怕做过头，也不喜欢被销售催着当场决定。
- 简单描述一下你的产品或服务：我是一名有护理背景的医美咨询从业者，提供面部状态沟通、项目选择科普、到店前决策梳理和术后恢复陪伴。我不替医生诊断，也不承诺效果，重点是帮助客户弄清自己需不需要做、先做什么、哪些项目不适合。
- 你最想要怎样的客户？：愿意理性沟通、重视安全和自然改善、可以接受长期管理而不是一次变脸的客户。她不一定预算最高，但愿意为专业判断负责，也愿意坦诚说自己的顾虑。
- 你能为客户持续讲什么？：可以持续讲医美项目怎么选、哪些营销话术容易让人冲动、恢复期真实是什么样、第一次到店该问什么、不同年龄如何做减法，以及我在门店见过的真实选择和职业经历。

补充信息：我希望账号像一个说实话的医美前辈，语气直接但不吓人，不制造容貌焦虑。内容可以拍咨询桌、皮肤检测仪、项目沟通单、下班复盘和经过授权的门店工作现场。请把典型客户、产品服务、可持续内容母题和第一批选题都写清楚。以上信息足以完成简单定位，请直接交付完整报告。
'@
if ($ResumePositioningRunId) {
  $positionRun = Wait-Run $ResumePositioningRunId $Token
  $positionThread = [string]$positionRun.threadId
  $positionSubmit = @{ runId = $ResumePositioningRunId; taskId = [string]$positionRun.taskId }
  $attempt = @{ attemptId = [string]$before.attemptId }
  $attemptView = Api GET "/api/v1/workspaces/$WorkspaceId/initial-positioning/attempts/$($attempt.attemptId)" $null $Token
} else {
  $positionThread = New-Thread $Token $WorkspaceId 'positioning'
  $positionSubmit = Submit-Agent 'positioning_lv1' $positionPrompt $positionThread $Token 'positioning'
  $attempt = Api POST "/api/v1/workspaces/$WorkspaceId/initial-positioning/attempts" @{ agentRunId = $positionSubmit.runId } $Token
  $positionRun = Wait-Run $positionSubmit.runId $Token
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  do {
    $attemptView = Api GET "/api/v1/workspaces/$WorkspaceId/initial-positioning/attempts/$($attempt.attemptId)" $null $Token
    if ([string]$attemptView.state -eq 'completed') { break }
    if ([string]$attemptView.state -in @('failed_retryable', 'failed_terminal', 'cancelled', 'superseded')) { throw "POSITIONING_ATTEMPT_FAILED:$($attemptView.state):$($attemptView.failureCode)" }
    Start-Sleep -Seconds 2
  } while ([DateTime]::UtcNow -lt $deadline)
}
Assert-That ([string]$positionRun.status -eq 'succeeded') 'positioning-run-succeeded'
Assert-That ([string]$attemptView.state -eq 'completed') 'positioning-attempt-completed'
$positionAssistant = Wait-Assistant $positionThread $positionSubmit.taskId $Token
$positionInvocation = Get-Invocation $positionThread $positionSubmit.runId $Token
$current = Api GET "/api/v1/workspaces/$WorkspaceId/initial-positioning/current" $null $Token
$status = Api GET '/api/v1/me/status' $null $Token
Assert-That ([string]$current.state -eq 'completed' -and [int]$current.progress.coldStartPercent -eq 100) 'positioning-current-completed'
Assert-That ($status.onboardingRequired -eq $false) 'onboarding-projection-completed'
Assert-That (@($positionInvocation.tools | Where-Object { $_.toolName -eq 'read' -and [string]$_.inputSummary.logicalTarget -eq 'profile/user-positioning/positioning-profile.md' }).Count -ge 1) 'positioning-read-initial-file'
Assert-That (@($positionInvocation.tools | Where-Object { $_.toolName -eq 'write' -and $_.status -eq 'succeeded' }).Count -ge 1) 'positioning-write-succeeded'
Save-Text 'positioning-assistant.md' $positionAssistant
Save-Json 'positioning-invocation.json' $positionInvocation
Save-Json 'positioning-current.json' $current

$topicRuns = @()
if (-not $SkipInitialTopicAgents) {
  $topicRuns += Run-Agent 'huoke_content' '请读取我的正式定位，围绕医美咨询账号生成12个差异明显的选题：项目选择、第一次到店、恢复期、职业故事、客户顾虑、行业观点各至少一个。每个选题给出标题、为什么适合我、需要调用的真实材料，不要编造案例。' $Token $WorkspaceId 'topics-huoke'
  $topicRuns += Run-Agent 'renshe_content' '请基于我的正式定位，为这个医美从业者账号设计6个人设型选题。重点寻找可以长期讲的人生经历、职业转折、门店现场和价值判断；没有证据的故事明确标为待补充，不要编造。' $Token $WorkspaceId 'topics-renshe-before-distill'
}
if (-not $SkipCreationAgent) {
  $topicRuns += Run-Agent 'self_media_creation' '请基于我的正式定位评审一组医美账号内容方向，给出8个可执行选题，并从中选择最值得先拍的3个。说明用户、材料、拍摄场景和风险边界，不要制造容貌焦虑。' $Token $WorkspaceId 'topics-creation'
}
foreach ($topic in $topicRuns) {
  Assert-That ([string]$topic.assistant -match '[\p{IsCJKUnifiedIdeographs}]') "$($topic.agentProfileId)-returned-chinese"
}

$meetingMinutes = @'
# 医美账号共创会议纪要

时间：2026-08-30
参与者：阿宁、内容同事

## 可核对的人生与职业材料

- 阿宁 2014 年读护理专业，2016 年先在皮肤科做护士，2018 年转到医美机构做咨询与术后随访。
- 2019 年她接待过一位化名“周姐”的客户。周姐此前在别处连续叠加项目，恢复期比预期长。阿宁没有继续推荐新项目，而是建议先停止、找医生复诊并记录恢复变化。这件事让她确定了“先判断需不需要，再讨论做什么”的工作原则。
- 她经历过门店把高客单当唯一目标的阶段，后来选择更重视长期随访的团队。这是她职业上的一次重要选择。
- 她最有成就感的不是客户一次买很多，而是客户隔半年回来仍敢把真实担忧告诉她。

## 稳定观点和方法

- 医美决策应该先排除不适合，再从最小必要方案开始；宁可少做，也不要用项目数量证明专业。
- 不用“再不做就晚了”制造焦虑，不承诺确定效果，不越过医生诊断边界。
- 第一次沟通使用三张清单：真实困扰、不可接受的风险、可以承担的恢复时间。

## 表达与现场

- 说话直接但不吓人，像一个见过很多案例、愿意把难听真话说清楚的前辈。
- 不喜欢“逆龄神话”“闭眼冲”“零风险”这类表达。
- 可拍摄咨询桌、皮肤检测仪、沟通单、下班复盘；客户和治疗画面必须明确授权并去标识化。
'@
$firstDistill = Distill-And-Confirm 'meeting-minutes.md' $meetingMinutes $Token $WorkspaceId 'meeting'

$behaviorReview = @'
# 医美账号第一轮选题复盘与用户行为记录

用户看完三组 Agent 选题后做了以下选择：

- 保留并优先拍：《我为什么劝周姐先停下来》《第一次去医美机构，先写下这三件事》《做得少不是保守，是给变化留余地》。
- 暂不拍：“年度必做项目清单”“所有人都适用的抗衰套餐”“用价格对比制造焦虑”。原因是容易把个体差异说成统一答案。
- 用户希望标题朴素具体，不使用“逆龄、封神、闭眼冲、零风险”等夸张词。
- 用户最自然的表达方式是先讲一个门店片段，再说明判断标准，最后给观众一张能自己使用的小清单。
- 用户希望与粉丝像专业前辈和长期联系人，而不是高高在上的专家，也不是催单销售。
- 用户愿意持续公开职业选择、工作方法和经匿名处理的客户故事；家庭隐私、未授权客户信息和医疗诊断不公开。
- 下周计划拍摄咨询桌前口述、沟通单手部特写、下班后的复盘独白三种画面。
'@
$secondDistill = Distill-And-Confirm 'content-behavior-review.md' $behaviorReview $Token $WorkspaceId 'behavior'

$twin = Api GET "/api/v1/workspaces/$WorkspaceId/digital-twin" $null $Token
$versions = Api GET "/api/v1/workspaces/$WorkspaceId/digital-twin/versions" $null $Token
$versionId = [string]$twin.currentVersion.versionId
$detail = Api GET "/api/v1/workspaces/$WorkspaceId/digital-twin/versions/$versionId" $null $Token
$preview = Api GET "/api/v1/workspaces/$WorkspaceId/digital-twin/versions/$versionId/preview" $null $Token
$previewText = $preview | ConvertTo-Json -Depth 30 -Compress
$markers = @('周姐', '护理专业', '皮肤科', '宁可少做', '不吓人', '三张清单', '专业前辈', '逆龄')
$matched = @($markers | Where-Object { $previewText.Contains($_) })
Assert-That (@($preview.files).Count -eq 6) 'digital-twin-six-files-visible'
Assert-That (@($preview.files | Where-Object { $_.exists }).Count -eq 6) 'digital-twin-six-files-populated'
Assert-That ($matched.Count -ge 6) 'digital-twin-preserved-key-evidence'
Assert-That (@($versions.items).Count -ge 4) 'digital-twin-history-advanced'
Assert-That (@($detail.profiles | Where-Object { @($_.sources).Count -ge 1 }).Count -ge 3) 'digital-twin-source-refs-visible'
Save-Json 'digital-twin-current.json' $twin
Save-Json 'digital-twin-versions.json' $versions
Save-Json 'digital-twin-final-detail.json' $detail
Save-Json 'digital-twin-final-preview.json' $preview

$after = Run-Agent 'renshe_content' '请只根据我的正式定位和数字孪生中已有材料，生成5个医美从业者人生故事选题。每个选题必须点出一个已存在的具体职业事件或选择；如果读不到就明确说缺失，不要编造。' $Token $WorkspaceId 'topics-renshe-after-distill'
Assert-That ([string]$after.assistant -match '周姐|护士|皮肤科|停止|长期随访|宁可少做') 'downstream-agent-used-enriched-story'

$dataBody = Run-Agent 'data_body' '请根据当前数字孪生，用三段话分别概括：我的职业转折、稳定判断标准、表达与隐私边界。只使用已经存在的材料，并指出仍然缺失的信息。' $Token $WorkspaceId 'data-body-readback'
Assert-That ([string]$dataBody.assistant -match '护理|护士|皮肤科|周姐') 'data-body-read-life-story'
Assert-That ([string]$dataBody.assistant -match '宁可少做|最小必要|先排除') 'data-body-read-viewpoint'

$fileEvidence = @($preview.files | ForEach-Object {
  $markdown = [string]$_.markdown
  [ordered]@{ id = [string]$_.id; name = [string]$_.name; exists = [bool]$_.exists; contentLength = $markdown.Length; matchedMarkers = @($markers | Where-Object { $markdown.Contains($_) }) }
})
$receipt = [ordered]@{
  schemaVersion = 'huahuo.data-body-beauty-lifecycle-evidence.v1'; result = 'passed'; targetHost = '39.107.250.25'
  startedAtUtc = $StartedAt.ToString('o'); completedAtUtc = [DateTime]::UtcNow.ToString('o')
  account = @{ phone = '188****0003'; workspaceId = $WorkspaceId }
  positioning = @{ attemptId = [string]$attempt.attemptId; runId = $positionSubmit.runId; state = [string]$attemptView.state; coldStartPercent = [int]$current.progress.coldStartPercent }
  topicRuns = @($topicRuns + @($after) | ForEach-Object { @{ agentProfileId = $_.agentProfileId; runId = $_.runId; elapsedSeconds = $_.elapsedSeconds } })
  distillations = @($firstDistill, $secondDistill)
  currentVersion = $twin.currentVersion; versionCount = @($versions.items).Count; matchedMarkers = $matched; files = $fileEvidence
  dataBodyReadback = @{ runId = $dataBody.runId; elapsedSeconds = $dataBody.elapsedSeconds }
  assertions = @($Assertions)
}
Save-Json 'receipt.json' $receipt
$receipt | ConvertTo-Json -Depth 30 -Compress
