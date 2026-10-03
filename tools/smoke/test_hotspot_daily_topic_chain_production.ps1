<#
.SYNOPSIS
Tests the current Hotspot sync -> targeted Daily Topic -> Workspace recommendation chain.

.DESCRIPTION
This smoke test is bound to the authorized 39.107.250.25 host and accepts
exactly one target phone. It never invokes the deprecated /hotspot/* pipeline.
Admin credentials and access tokens are consumed only in memory and are never
included in the JSON report.
#>
[CmdletBinding()]
param(
  [string]$ApiBase = 'http://39.107.250.25/api/v1',
  [string]$AdminBase = 'http://39.107.250.25/admin/api/v1',
  [Parameter(Mandatory = $true)][string]$Phone,
  [Parameter(Mandatory = $true)][string]$SmsCode,
  [string]$BusinessDate = '',
  [string]$AdminAccessToken = $env:HUAHUO_ADMIN_ACCESS_TOKEN,
  [string]$AdminLogin = $env:HUAHUO_ADMIN_LOGIN,
  [string]$AdminPassword = $env:HUAHUO_ADMIN_PASSWORD,
  [ValidateRange(10, 900)][int]$HotspotSyncWaitSeconds = 180,
  [ValidateRange(60, 3600)][int]$RecommendationWaitSeconds = 1800,
  [ValidateRange(1, 30)][int]$PollSeconds = 4,
  [string]$ReportPath = '',
  [switch]$SkipHotspotSync,
  [switch]$RetryFailed,
  [switch]$VerifyExistingRecommendation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

. (Join-Path $PSScriptRoot 'minutes_api_common.ps1')

function Assert-HuahuoChainApiRoot {
  param(
    [Parameter(Mandatory = $true)][string]$Value,
    [Parameter(Mandatory = $true)][string]$ExpectedPath
  )

  $uri = [Uri]$Value.TrimEnd('/')
  if ($uri.Scheme -notin @('http', 'https') -or $uri.DnsSafeHost -ne '39.107.250.25' -or
    $uri.AbsolutePath.TrimEnd('/') -ne $ExpectedPath -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
    throw "$ExpectedPath must use the authorized 39.107.250.25 host."
  }
  return $uri
}

function Get-HuahuoChainPhoneHash {
  param([Parameter(Mandatory = $true)][string]$Value)

  $bytes = [Text.Encoding]::UTF8.GetBytes('phone:' + $Value.Trim())
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $sum = $sha.ComputeHash($bytes)
  } finally {
    $sha.Dispose()
  }
  return (($sum | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-HuahuoChainMaskedPhone {
  param([Parameter(Mandatory = $true)][string]$Value)

  return $Value.Substring(0, 3) + '****' + $Value.Substring(7, 4)
}

function Get-HuahuoChainItems {
  param([AllowNull()][object]$Object)

  $items = Get-HuahuoObjectValue -Object $Object -Names @('items')
  if ($null -eq $items) {
    return @()
  }
  return @($items)
}

function New-HuahuoChainAdminClient {
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

function Close-HuahuoChainAdminClient {
  param([AllowNull()][object]$Api)

  if ($null -ne $Api -and $null -ne $Api.Client) {
    $Api.Client.Dispose()
  }
}

function Invoke-HuahuoChainAdminRequest {
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
    $request.Headers.TryAddWithoutValidation('User-Agent', 'HuahuoAI-Hotspot-Chain-Smoke/1.0') | Out-Null
    $request.Headers.TryAddWithoutValidation('X-Trace-Id', 'hotspot-chain-smoke-' + [guid]::NewGuid().ToString('N')) | Out-Null
    $request.Headers.TryAddWithoutValidation('X-Admin-Reason', 'authorized targeted hotspot chain smoke') | Out-Null
    if (-not $Anonymous) {
      $request.Headers.TryAddWithoutValidation('Authorization', "Bearer $($Api.Token)") | Out-Null
    }
    if ($Method -eq 'POST') {
      $request.Headers.TryAddWithoutValidation('X-Idempotency-Key', 'hotspot-chain-smoke-' + [guid]::NewGuid().ToString('N')) | Out-Null
      $json = if ($null -eq $Body) { '{}' } else { $Body | ConvertTo-Json -Depth 16 -Compress }
      $request.Content = [Net.Http.StringContent]::new($json, $Api.Utf8, 'application/json')
    }

    $response = $Api.Client.SendAsync($request).GetAwaiter().GetResult()
    $raw = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $payload = $null
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
      try {
        $payload = $raw | ConvertFrom-Json
      } catch {
        return [pscustomobject][ordered]@{
          ok = $false
          httpStatus = [int]$response.StatusCode
          code = 'NON_JSON_RESPONSE'
          data = $null
        }
      }
    }
    $success = Get-HuahuoObjectValue -Object $payload -Names @('success')
    $data = Get-HuahuoObjectValue -Object $payload -Names @('data')
    if ($null -eq $data) {
      $data = $payload
    }
    return [pscustomobject][ordered]@{
      ok = $response.IsSuccessStatusCode -and $success -ne $false
      httpStatus = [int]$response.StatusCode
      code = Get-HuahuoApiErrorCode -Payload $payload
      data = $data
    }
  } finally {
    $request.Dispose()
    if ($null -ne $response) {
      $response.Dispose()
    }
  }
}

function Connect-HuahuoChainAdminClient {
  param(
    [Parameter(Mandatory = $true)][object]$Api,
    [AllowEmptyString()][string]$AccessToken,
    [AllowEmptyString()][string]$Login,
    [AllowEmptyString()][string]$Password
  )

  if (-not [string]::IsNullOrWhiteSpace($AccessToken)) {
    $Api.Token = $AccessToken.Trim()
  } else {
    if ([string]::IsNullOrWhiteSpace($Login) -or [string]::IsNullOrWhiteSpace($Password)) {
      throw 'Supply AdminAccessToken, or AdminLogin and AdminPassword.'
    }
    $reply = Invoke-HuahuoChainAdminRequest -Api $Api -Method POST -Path '/auth/login' -Anonymous -Body @{
      login = $Login
      password = $Password
    }
    if (-not $reply.ok) {
      throw "Admin login failed with HTTP $($reply.httpStatus), code $($reply.code)."
    }
    $Api.Token = Get-HuahuoString (Get-HuahuoObjectValue -Object $reply.data -Names @('adminAccessToken', 'accessToken'))
  }
  if ([string]::IsNullOrWhiteSpace($Api.Token)) {
    throw 'Admin access token is unavailable.'
  }

  $session = Invoke-HuahuoChainAdminRequest -Api $Api -Method GET -Path '/auth/session'
  if (-not $session.ok) {
    throw "Admin session validation failed with HTTP $($session.httpStatus), code $($session.code)."
  }
}

function Add-HuahuoChainCheck {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.List[object]]$Checks,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][ValidateSet('passed', 'failed', 'blocked', 'skipped')][string]$Status,
    [AllowNull()][object]$Evidence = $null,
    [AllowEmptyString()][string]$Code = ''
  )

  $Checks.Add([pscustomobject][ordered]@{
    name = $Name
    status = $Status
    code = $Code
    evidence = $Evidence
  })
}

function Wait-HuahuoHotspotSyncRun {
  param(
    [Parameter(Mandatory = $true)][object]$AdminApi,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][DateTime]$Deadline
  )

  do {
    $reply = Invoke-HuahuoChainAdminRequest -Api $AdminApi -Method GET -Path '/ops/hotspot-sync-runs?limit=100'
    if (-not $reply.ok) {
      throw "Hotspot sync run listing failed with HTTP $($reply.httpStatus), code $($reply.code)."
    }
    $matched = @(Get-HuahuoChainItems -Object $reply.data | Where-Object {
      (Get-HuahuoString (Get-HuahuoObjectValue -Object $_ -Names @('runId'))) -eq $RunId
    } | Select-Object -First 1)
    if ($matched.Count -eq 1) {
      $status = Get-HuahuoString (Get-HuahuoObjectValue -Object $matched[0] -Names @('status'))
      $failureCode = Get-HuahuoString (Get-HuahuoObjectValue -Object $matched[0] -Names @('safeFailureCode'))
      if ($status -in @('succeeded', 'failed', 'dead_letter', 'paused_cursor_expired')) {
        return $matched[0]
      }
      if ($status -eq 'retry_wait' -and $failureCode -eq 'HOTSPOT_DAY_NOT_AVAILABLE') {
        return $matched[0]
      }
    }
    Start-Sleep -Seconds $PollSeconds
  } while ([DateTime]::UtcNow -lt $Deadline)

  throw "Hotspot sync run $RunId did not reach a terminal state."
}

function Get-HuahuoRecommendationForDate {
  param(
    [Parameter(Mandatory = $true)][object]$Api,
    [Parameter(Mandatory = $true)][string]$WorkspaceId,
    [Parameter(Mandatory = $true)][string]$Date
  )

  $listed = Invoke-HuahuoMinutesApi -Api $Api -Method GET -Path "/workspaces/$WorkspaceId/topic-recommendations?status=ready&limit=100"
  return @(Get-HuahuoChainItems -Object $listed | Where-Object {
    (Get-HuahuoString (Get-HuahuoObjectValue -Object $_ -Names @('businessDate'))) -eq $Date -and
    (Get-HuahuoString (Get-HuahuoObjectValue -Object $_ -Names @('recommendationKind'))) -eq 'daily_topic_report'
  } | Select-Object -First 1)
}

function Test-HuahuoAppRecommendationSelection {
  param(
    [Parameter(Mandatory = $true)][object]$Api,
    [Parameter(Mandatory = $true)][string]$WorkspaceId,
    [Parameter(Mandatory = $true)][string]$BusinessDate,
    [Parameter(Mandatory = $true)][string]$ExpectedRecommendationId
  )

  # The first ready record is the App fallback. For a daily card, the App first
  # selects the record matching its business date and stable recommendation kind.
  $defaultPage = Invoke-HuahuoMinutesApi -Api $Api -Method GET -Path "/workspaces/$WorkspaceId/topic-recommendations?limit=20"
  $readyPage = Invoke-HuahuoMinutesApi -Api $Api -Method GET -Path "/workspaces/$WorkspaceId/topic-recommendations?status=ready&limit=20"
  $defaultItems = @(Get-HuahuoChainItems -Object $defaultPage)
  $readyItems = @(Get-HuahuoChainItems -Object $readyPage)
  if ($readyItems.Count -eq 0) {
    throw 'App recommendation enumeration returned no ready items.'
  }

  foreach ($item in $defaultItems) {
    if ((Get-HuahuoString (Get-HuahuoObjectValue -Object $item -Names @('status'))) -ne 'ready') {
      throw 'Default App recommendation enumeration returned a non-ready item.'
    }
  }
  foreach ($item in $readyItems) {
    if ((Get-HuahuoString (Get-HuahuoObjectValue -Object $item -Names @('status'))) -ne 'ready') {
      throw 'Ready-filtered App recommendation enumeration returned a non-ready item.'
    }
  }
  $defaultIds = @($defaultItems | ForEach-Object { Get-HuahuoString (Get-HuahuoObjectValue -Object $_ -Names @('recommendationId')) })
  $readyIds = @($readyItems | ForEach-Object { Get-HuahuoString (Get-HuahuoObjectValue -Object $_ -Names @('recommendationId')) })
  if ($defaultIds.Count -ne $readyIds.Count -or @($defaultIds | Where-Object { $_ -notin $readyIds }).Count -ne 0 -or
    @($readyIds | Where-Object { $_ -notin $defaultIds }).Count -ne 0) {
    throw 'Default App recommendation enumeration does not match the ready-filtered set.'
  }

  $selected = @($readyItems | Where-Object {
    (Get-HuahuoString (Get-HuahuoObjectValue -Object $_ -Names @('businessDate'))) -eq $BusinessDate -and
    (Get-HuahuoString (Get-HuahuoObjectValue -Object $_ -Names @('recommendationKind'))) -eq 'daily_topic_report'
  } | Select-Object -First 1)
  if ($selected.Count -ne 1) {
    throw "App recommendation enumeration did not contain the ready daily report for $BusinessDate."
  }

  $selectedId = Get-HuahuoString (Get-HuahuoObjectValue -Object $selected[0] -Names @('recommendationId'))
  if ($selectedId -ne $ExpectedRecommendationId) {
    throw "App recommendation selection resolved $selectedId instead of $ExpectedRecommendationId."
  }
  $detail = Invoke-HuahuoMinutesApi -Api $Api -Method GET -Path "/workspaces/$WorkspaceId/topic-recommendations/$selectedId"
  $detailId = Get-HuahuoString (Get-HuahuoObjectValue -Object $detail -Names @('recommendationId'))
  $detailWorkspaceId = Get-HuahuoString (Get-HuahuoObjectValue -Object $detail -Names @('workspaceId'))
  $detailDate = Get-HuahuoString (Get-HuahuoObjectValue -Object $detail -Names @('businessDate'))
  $detailKind = Get-HuahuoString (Get-HuahuoObjectValue -Object $detail -Names @('recommendationKind'))
  $detailStatus = Get-HuahuoString (Get-HuahuoObjectValue -Object $detail -Names @('status'))
  $title = Get-HuahuoString (Get-HuahuoObjectValue -Object $detail -Names @('title'))
  $topics = @(Get-HuahuoObjectValue -Object $detail -Names @('topics'))
  if ($detailId -ne $selectedId -or $detailWorkspaceId -ne $WorkspaceId -or $detailDate -ne $BusinessDate -or
    $detailKind -ne 'daily_topic_report' -or $detailStatus -ne 'ready' -or [string]::IsNullOrWhiteSpace($title) -or $topics.Count -eq 0) {
    throw "App recommendation detail readback failed for $selectedId."
  }
  return [pscustomobject][ordered]@{
    selection = 'businessDate+recommendationKind; fallback=first_ready_item'
    readyCount = $readyItems.Count
    defaultVisibleCount = $defaultItems.Count
    recommendationId = $selectedId
    businessDate = $detailDate
    recommendationKind = $detailKind
    title = $title
    topicCount = $topics.Count
  }
}

$apiUri = Assert-HuahuoChainApiRoot -Value $ApiBase -ExpectedPath '/api/v1'
$adminUri = Assert-HuahuoChainApiRoot -Value $AdminBase -ExpectedPath '/admin/api/v1'
$Phone = $Phone.Trim()
if ($Phone -notmatch '^1[0-9]{10}$') {
  throw 'Phone must contain exactly one valid mainland mobile number.'
}
if ($SmsCode -notmatch '^[0-9]{4,8}$') {
  throw 'SmsCode must contain 4 to 8 digits.'
}
if ([string]::IsNullOrWhiteSpace($BusinessDate)) {
  $china = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, 'China Standard Time')
  $BusinessDate = $china.AddDays(-1).ToString('yyyy-MM-dd')
} else {
  $parsedDate = [DateTime]::ParseExact($BusinessDate, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
  $BusinessDate = $parsedDate.ToString('yyyy-MM-dd')
}

$startedAt = [DateTime]::UtcNow
$checks = [Collections.Generic.List[object]]::new()
$userApi = $null
$adminApi = $null
$workspaceId = ''
try {
  $userApi = New-HuahuoMinutesApiClient -ApiBase $apiUri.AbsoluteUri
  Set-HuahuoMinutesAccessToken -Api $userApi -AccessToken '' -Phone $Phone -SmsCode $SmsCode
  $workspaceId = Resolve-HuahuoWorkspaceId -Api $userApi -WorkspaceId ''
  Add-HuahuoChainCheck -Checks $checks -Name 'target_login_and_workspace' -Status 'passed' -Evidence @{
    workspaceId = $workspaceId
  }

  if ($VerifyExistingRecommendation) {
    $recommendation = @(Get-HuahuoRecommendationForDate -Api $userApi -WorkspaceId $workspaceId -Date $BusinessDate)
    if ($recommendation.Count -ne 1) {
      Add-HuahuoChainCheck -Checks $checks -Name 'existing_recommendation_available' -Status 'failed' -Code 'RECOMMENDATION_NOT_FOUND'
      Add-HuahuoChainCheck -Checks $checks -Name 'app_recommendation_enumeration_and_detail' -Status 'failed' -Code 'RECOMMENDATION_NOT_FOUND'
    } else {
      $recommendationId = Get-HuahuoString (Get-HuahuoObjectValue -Object $recommendation[0] -Names @('recommendationId'))
      $recommendationStatus = Get-HuahuoString (Get-HuahuoObjectValue -Object $recommendation[0] -Names @('status'))
      if ($recommendationStatus -ne 'ready') {
        Add-HuahuoChainCheck -Checks $checks -Name 'existing_recommendation_available' -Status 'failed' -Code ('RECOMMENDATION_' + $recommendationStatus.ToUpperInvariant())
        Add-HuahuoChainCheck -Checks $checks -Name 'app_recommendation_enumeration_and_detail' -Status 'blocked' -Code ('RECOMMENDATION_' + $recommendationStatus.ToUpperInvariant())
      } else {
        Add-HuahuoChainCheck -Checks $checks -Name 'existing_recommendation_available' -Status 'passed' -Evidence @{
          recommendationId = $recommendationId
          businessDate = $BusinessDate
        }
        try {
          $appSelection = Test-HuahuoAppRecommendationSelection -Api $userApi -WorkspaceId $workspaceId -BusinessDate $BusinessDate -ExpectedRecommendationId $recommendationId
          Add-HuahuoChainCheck -Checks $checks -Name 'app_recommendation_enumeration_and_detail' -Status 'passed' -Evidence $appSelection
        } catch {
          Add-HuahuoChainCheck -Checks $checks -Name 'app_recommendation_enumeration_and_detail' -Status 'failed' -Code 'APP_RECOMMENDATION_ENUMERATION_FAILED' -Evidence @{ message = $_.Exception.Message }
        }
      }
    }
  } else {
    $adminApi = New-HuahuoChainAdminClient -Root $adminUri
    Connect-HuahuoChainAdminClient -Api $adminApi -AccessToken $AdminAccessToken -Login $AdminLogin -Password $AdminPassword
    Add-HuahuoChainCheck -Checks $checks -Name 'admin_authentication' -Status 'passed'

    if ($SkipHotspotSync) {
    Add-HuahuoChainCheck -Checks $checks -Name 'manual_hotspot_sync' -Status 'skipped'
  } else {
    $startReply = Invoke-HuahuoChainAdminRequest -Api $adminApi -Method POST -Path '/ops/hotspot-sync-runs' -Body @{
      businessDate = $BusinessDate
    }
    if (-not $startReply.ok) {
      Add-HuahuoChainCheck -Checks $checks -Name 'manual_hotspot_sync' -Status 'failed' -Code $startReply.code -Evidence @{
        httpStatus = $startReply.httpStatus
      }
    } else {
      $runId = Get-HuahuoString (Get-HuahuoObjectValue -Object $startReply.data -Names @('runId'))
      try {
        $terminal = Wait-HuahuoHotspotSyncRun -AdminApi $adminApi -RunId $runId -Deadline ([DateTime]::UtcNow.AddSeconds($HotspotSyncWaitSeconds))
        $syncStatus = Get-HuahuoString (Get-HuahuoObjectValue -Object $terminal -Names @('status'))
        $failureCode = Get-HuahuoString (Get-HuahuoObjectValue -Object $terminal -Names @('safeFailureCode'))
        $evidence = [ordered]@{
          runId = $runId
          businessDate = Get-HuahuoString (Get-HuahuoObjectValue -Object $terminal -Names @('businessDate'))
          observedStatus = $syncStatus
        }
        if ($syncStatus -eq 'succeeded') {
          Add-HuahuoChainCheck -Checks $checks -Name 'manual_hotspot_sync' -Status 'passed' -Evidence $evidence
        } elseif ($failureCode -eq 'HOTSPOT_DAY_NOT_AVAILABLE') {
          Add-HuahuoChainCheck -Checks $checks -Name 'manual_hotspot_sync' -Status 'blocked' -Code $failureCode -Evidence $evidence
        } else {
          Add-HuahuoChainCheck -Checks $checks -Name 'manual_hotspot_sync' -Status 'failed' -Code $failureCode -Evidence $evidence
        }
      } catch {
        Add-HuahuoChainCheck -Checks $checks -Name 'manual_hotspot_sync' -Status 'failed' -Code 'HOTSPOT_SYNC_TIMEOUT' -Evidence @{
          runId = $runId
          message = $_.Exception.Message
        }
      }
    }
  }

  $phoneHash = Get-HuahuoChainPhoneHash -Value $Phone
  $targetReply = Invoke-HuahuoChainAdminRequest -Api $adminApi -Method POST -Path '/ops/daily-topic/targeted-run' -Body @{
    businessDate = $BusinessDate
    targetPhoneHashes = @($phoneHash)
    retryFailed = [bool]$RetryFailed
  }
  if (-not $targetReply.ok) {
    $targetStatus = if ($targetReply.code -in @(
      'DAILY_TOPIC_PACKAGE_NOT_READY',
      'DAILY_TOPIC_AUDIENCE_CONFLICT',
      'DAILY_TOPIC_TARGET_INPUT_NOT_READY',
      'DAILY_TOPIC_RETRY_LIMIT_REACHED'
    )) { 'blocked' } else { 'failed' }
    Add-HuahuoChainCheck -Checks $checks -Name 'targeted_daily_topic_trigger' -Status $targetStatus -Code $targetReply.code -Evidence @{
      httpStatus = $targetReply.httpStatus
      targetCount = 1
    }
    Add-HuahuoChainCheck -Checks $checks -Name 'workspace_distribution' -Status 'blocked' -Code $targetReply.code
    Add-HuahuoChainCheck -Checks $checks -Name 'recommendation_ready' -Status 'blocked' -Code $targetReply.code
    Add-HuahuoChainCheck -Checks $checks -Name 'app_recommendation_enumeration_and_detail' -Status 'blocked' -Code $targetReply.code
  } else {
    Add-HuahuoChainCheck -Checks $checks -Name 'targeted_daily_topic_trigger' -Status 'passed' -Evidence @{
      campaignId = Get-HuahuoString (Get-HuahuoObjectValue -Object $targetReply.data -Names @('campaignId'))
      audienceScope = Get-HuahuoString (Get-HuahuoObjectValue -Object $targetReply.data -Names @('audienceScope'))
      targetCount = Get-HuahuoObjectValue -Object $targetReply.data -Names @('targetCount')
      deliveryCount = Get-HuahuoObjectValue -Object $targetReply.data -Names @('deliveryCount')
      retryFailed = Get-HuahuoObjectValue -Object $targetReply.data -Names @('retryFailed')
      recoveredCount = Get-HuahuoObjectValue -Object $targetReply.data -Names @('recoveredCount')
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($RecommendationWaitSeconds)
    $recommendation = @()
    do {
      $recommendation = @(Get-HuahuoRecommendationForDate -Api $userApi -WorkspaceId $workspaceId -Date $BusinessDate)
      if ($recommendation.Count -eq 1) {
        $status = Get-HuahuoString (Get-HuahuoObjectValue -Object $recommendation[0] -Names @('status'))
        if ($status -in @('ready', 'failed', 'dismissed', 'expired')) {
          break
        }
      }
      Start-Sleep -Seconds $PollSeconds
    } while ([DateTime]::UtcNow -lt $deadline)

    if ($recommendation.Count -ne 1) {
      Add-HuahuoChainCheck -Checks $checks -Name 'workspace_distribution' -Status 'failed' -Code 'RECOMMENDATION_NOT_FOUND'
      Add-HuahuoChainCheck -Checks $checks -Name 'recommendation_ready' -Status 'failed' -Code 'RECOMMENDATION_NOT_FOUND'
      Add-HuahuoChainCheck -Checks $checks -Name 'app_recommendation_enumeration_and_detail' -Status 'failed' -Code 'RECOMMENDATION_NOT_FOUND'
    } else {
      $recommendationId = Get-HuahuoString (Get-HuahuoObjectValue -Object $recommendation[0] -Names @('recommendationId'))
      $recommendationStatus = Get-HuahuoString (Get-HuahuoObjectValue -Object $recommendation[0] -Names @('status'))
      if ($recommendationStatus -eq 'ready') {
        $detail = Invoke-HuahuoMinutesApi -Api $userApi -Method GET -Path "/workspaces/$workspaceId/topic-recommendations/$recommendationId"
        $topics = @(Get-HuahuoObjectValue -Object $detail -Names @('topics'))
        Add-HuahuoChainCheck -Checks $checks -Name 'workspace_distribution' -Status 'passed' -Evidence @{
          businessDate = $BusinessDate
          recommendationId = $recommendationId
        }
        Add-HuahuoChainCheck -Checks $checks -Name 'recommendation_ready' -Status 'passed' -Evidence @{
          recommendationId = $recommendationId
          topicCount = $topics.Count
        }
        try {
          $appSelection = Test-HuahuoAppRecommendationSelection -Api $userApi -WorkspaceId $workspaceId -BusinessDate $BusinessDate -ExpectedRecommendationId $recommendationId
          Add-HuahuoChainCheck -Checks $checks -Name 'app_recommendation_enumeration_and_detail' -Status 'passed' -Evidence $appSelection
        } catch {
          Add-HuahuoChainCheck -Checks $checks -Name 'app_recommendation_enumeration_and_detail' -Status 'failed' -Code 'APP_RECOMMENDATION_ENUMERATION_FAILED' -Evidence @{ message = $_.Exception.Message }
        }
      } else {
        Add-HuahuoChainCheck -Checks $checks -Name 'workspace_distribution' -Status 'passed' -Evidence @{
          businessDate = $BusinessDate
          recommendationId = $recommendationId
        }
        Add-HuahuoChainCheck -Checks $checks -Name 'recommendation_ready' -Status 'failed' -Code ('RECOMMENDATION_' + $recommendationStatus.ToUpperInvariant()) -Evidence @{
          recommendationId = $recommendationId
          status = $recommendationStatus
        }
        Add-HuahuoChainCheck -Checks $checks -Name 'app_recommendation_enumeration_and_detail' -Status 'blocked' -Code ('RECOMMENDATION_' + $recommendationStatus.ToUpperInvariant())
      }
    }
    }
  }
} catch {
  Add-HuahuoChainCheck -Checks $checks -Name 'script_execution' -Status 'failed' -Code 'UNEXPECTED_ERROR' -Evidence @{
    message = $_.Exception.Message
  }
} finally {
  if ($null -ne $userApi) {
    Close-HuahuoMinutesApiClient -Api $userApi
  }
  Close-HuahuoChainAdminClient -Api $adminApi
}

$failed = @($checks | Where-Object { $_.status -in @('failed', 'blocked') })
$report = [pscustomobject][ordered]@{
  schemaVersion = 'huahuo.hotspot-daily-topic-chain-smoke.v2'
  authorizedHost = '39.107.250.25'
  startedAt = $startedAt.ToString('o')
  completedAt = [DateTime]::UtcNow.ToString('o')
  businessDate = $BusinessDate
  target = [ordered]@{
    phoneMasked = Get-HuahuoChainMaskedPhone -Value $Phone
    workspaceId = $workspaceId
    count = 1
  }
  success = $failed.Count -eq 0
  checks = @($checks)
}
$json = $report | ConvertTo-Json -Depth 12
if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
  $parent = Split-Path -Parent $ReportPath
  if (-not [string]::IsNullOrWhiteSpace($parent)) {
    [IO.Directory]::CreateDirectory($parent) | Out-Null
  }
  [IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath), $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}
$json
if (-not $report.success) {
  exit 1
}
