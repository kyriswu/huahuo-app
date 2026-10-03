<#
.SYNOPSIS
Exercises the authenticated user profile name and avatar APIs.

.DESCRIPTION
The script reads the current profile, proves invalid name and avatar updates
are rejected, updates the display name, uploads or selects an avatar Resource,
and reads the profile back. By default it restores the original profile after
a successful run. Uploaded test Resources remain immutable server Resources.

Use an existing access token when possible. If no token is supplied, the
script requests an SMS code and logs in with Phone and SmsCode.

.EXAMPLE
$env:HUAHUO_ACCESS_TOKEN = '<token>'
./source/scripts/test_user_profile_api.ps1 -DisplayName 'Profile Smoke User'

.EXAMPLE
./source/scripts/test_user_profile_api.ps1 `
  -Phone $env:HUAHUO_TEST_PHONE `
  -SmsCode $env:HUAHUO_TEST_SMS_CODE `
  -DisplayName 'Profile Smoke User' `
  -AvatarPath 'C:\test-data\avatar.png'

.EXAMPLE
./source/scripts/test_user_profile_api.ps1 `
  -AccessToken $env:HUAHUO_ACCESS_TOKEN `
  -DisplayName 'Persistent Test User' `
  -AvatarResourceId 'resource_0123456789abcdef0123456789abcdef' `
  -KeepChanges
#>
[CmdletBinding()]
param(
  [string]$ApiBase = 'http://39.107.250.25/api/v1',
  [string]$AccessToken = $env:HUAHUO_ACCESS_TOKEN,
  [string]$Phone = $env:HUAHUO_TEST_PHONE,
  [string]$SmsCode = $env:HUAHUO_TEST_SMS_CODE,
  [string]$DisplayName = '',
  [string]$AvatarPath = '',
  [string]$AvatarResourceId = '',
  [switch]$SkipAvatar,
  [switch]$KeepChanges,
  [switch]$AllowLoopback
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName System.Net.Http

$apiUri = [Uri]$ApiBase.TrimEnd('/')
$loopbackHosts = @('localhost', '127.0.0.1', '::1')
$authorizedHost = $apiUri.DnsSafeHost -eq '39.107.250.25'
$authorizedLoopback = $AllowLoopback -and $apiUri.DnsSafeHost -in $loopbackHosts
if ($apiUri.Scheme -notin @('http', 'https') -or
  (-not $authorizedHost -and -not $authorizedLoopback) -or
  $apiUri.AbsolutePath.TrimEnd('/') -ne '/api/v1' -or
  $apiUri.UserInfo -or $apiUri.Query -or $apiUri.Fragment) {
  throw 'ApiBase must be the authorized 39.107.250.25 API root. Use -AllowLoopback only for a local mock.'
}
if ($SkipAvatar -and (-not [string]::IsNullOrWhiteSpace($AvatarPath) -or -not [string]::IsNullOrWhiteSpace($AvatarResourceId))) {
  throw 'SkipAvatar cannot be combined with AvatarPath or AvatarResourceId.'
}
if (-not [string]::IsNullOrWhiteSpace($AvatarPath) -and -not [string]::IsNullOrWhiteSpace($AvatarResourceId)) {
  throw 'Specify AvatarPath or AvatarResourceId, not both.'
}

$DisplayName = $DisplayName.Trim()
if ([string]::IsNullOrWhiteSpace($DisplayName)) {
  $DisplayName = 'Profile API Smoke ' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
}
if ($DisplayName.Length -gt 64 -or [Text.Encoding]::UTF8.GetByteCount($DisplayName) -gt 256 -or $DisplayName -match '[\x00-\x1f\x7f]') {
  throw 'DisplayName must be 1-64 characters, at most 256 UTF-8 bytes, without control characters.'
}

$utf8 = [Text.UTF8Encoding]::new($false)
$deviceId = 'profile-api-smoke-' + [guid]::NewGuid().ToString('N')
$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(120)

function Get-ObjectValue {
  param(
    [AllowNull()][object]$Object,
    [Parameter(Mandatory = $true)][string[]]$Names
  )

  foreach ($name in $Names) {
    if ($null -eq $Object) {
      continue
    }
    if ($Object -is [Collections.IDictionary] -and $Object.Contains($name)) {
      return $Object[$name]
    }
    if ($Object.PSObject.Properties.Name -contains $name) {
      return $Object.$name
    }
  }
  return $null
}

function Get-NullableString {
  param([AllowNull()][object]$Value)

  if ($null -eq $Value) {
    return $null
  }
  $text = [string]$Value
  if ([string]::IsNullOrWhiteSpace($text)) {
    return $null
  }
  return $text.Trim()
}

function Get-ApiErrorCode {
  param([AllowNull()][object]$Payload)

  $errorObject = Get-ObjectValue -Object $Payload -Names @('error')
  $code = Get-ObjectValue -Object $errorObject -Names @('code', 'errorCode')
  if ([string]::IsNullOrWhiteSpace([string]$code)) {
    $code = Get-ObjectValue -Object $Payload -Names @('errorCode', 'code')
  }
  return [string]$code
}

function Invoke-ProfileApi {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST', 'PATCH')][string]$Method,
    [Parameter(Mandatory = $true)][string]$Path,
    [AllowNull()][object]$Body = $null,
    [AllowEmptyString()][string]$Token = '',
    [AllowEmptyString()][string]$IdempotencyKey = '',
    [AllowEmptyString()][string]$ExpectedErrorCode = ''
  )

  if (-not $Path.StartsWith('/')) {
    throw 'API path must be relative to the configured API root.'
  }
  $request = [System.Net.Http.HttpRequestMessage]::new(
    [System.Net.Http.HttpMethod]::new($Method),
    "$($apiUri.AbsoluteUri.TrimEnd('/'))/$($Path.TrimStart('/'))"
  )
  $request.Headers.TryAddWithoutValidation('Accept', 'application/json') | Out-Null
  $request.Headers.TryAddWithoutValidation('User-Agent', 'HuahuoAI-Profile-API-Smoke/1.0') | Out-Null
  $request.Headers.TryAddWithoutValidation('X-Trace-Id', 'profile-api-' + [guid]::NewGuid().ToString('N')) | Out-Null
  $request.Headers.TryAddWithoutValidation('X-Client-Version', 'profile-api-smoke-1.0') | Out-Null
  $request.Headers.TryAddWithoutValidation('X-Device-Id', $deviceId) | Out-Null
  $request.Headers.TryAddWithoutValidation('X-Platform', 'cli') | Out-Null
  $request.Headers.TryAddWithoutValidation('X-Locale', 'zh-CN') | Out-Null
  if (-not [string]::IsNullOrWhiteSpace($Token)) {
    $request.Headers.TryAddWithoutValidation('Authorization', "Bearer $Token") | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace($IdempotencyKey)) {
    $request.Headers.TryAddWithoutValidation('X-Idempotency-Key', $IdempotencyKey) | Out-Null
  }
  if ($Method -in @('POST', 'PATCH')) {
    $json = if ($null -eq $Body) { '{}' } else { $Body | ConvertTo-Json -Depth 30 -Compress }
    $request.Content = [System.Net.Http.StringContent]::new($json, $utf8, 'application/json')
  }

  $response = $null
  try {
    $response = $client.SendAsync($request).GetAwaiter().GetResult()
    $raw = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
  } finally {
    $request.Dispose()
  }

  try {
    $payload = $null
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
      try {
        $payload = $raw | ConvertFrom-Json
      } catch {
        throw "API returned non-JSON content for $Method $Path (HTTP $([int]$response.StatusCode))."
      }
    }
    $errorCode = Get-ApiErrorCode -Payload $payload
    $envelopeSuccess = Get-ObjectValue -Object $payload -Names @('success')

    if (-not [string]::IsNullOrWhiteSpace($ExpectedErrorCode)) {
      if ($response.IsSuccessStatusCode -and $envelopeSuccess -ne $false) {
        throw "API unexpectedly accepted $Method $Path; expected $ExpectedErrorCode."
      }
      if ($errorCode -cne $ExpectedErrorCode) {
        throw "API rejected $Method $Path with '$errorCode'; expected '$ExpectedErrorCode'."
      }
      return [pscustomobject][ordered]@{
        statusCode = [int]$response.StatusCode
        errorCode = $errorCode
      }
    }

    if (-not $response.IsSuccessStatusCode -or $envelopeSuccess -eq $false) {
      $safeCode = if ([string]::IsNullOrWhiteSpace($errorCode)) { 'UNKNOWN_API_ERROR' } else { $errorCode }
      throw "API request $Method $Path failed with HTTP $([int]$response.StatusCode), code $safeCode."
    }
    $data = Get-ObjectValue -Object $payload -Names @('data')
    if ($null -ne $data) {
      return $data
    }
    return $payload
  } finally {
    if ($null -ne $response) {
      $response.Dispose()
    }
  }
}

function Get-Sha256Hex {
  param([Parameter(Mandatory = $true)][byte[]]$Bytes)

  $sha256 = [Security.Cryptography.SHA256]::Create()
  try {
    return -join @($sha256.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') })
  } finally {
    $sha256.Dispose()
  }
}

function Get-AvatarPayload {
  param([AllowEmptyString()][string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return [pscustomobject][ordered]@{
      bytes = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2nWQAAAAASUVORK5CYII=')
      mimeType = 'image/png'
      fileName = 'profile-smoke.png'
      generated = $true
    }
  }

  $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
  if (-not [IO.File]::Exists($resolved)) {
    throw 'AvatarPath must identify a file.'
  }
  $extension = [IO.Path]::GetExtension($resolved).ToLowerInvariant()
  $mimeType = switch ($extension) {
    '.jpg' { 'image/jpeg' }
    '.jpeg' { 'image/jpeg' }
    '.png' { 'image/png' }
    '.webp' { 'image/webp' }
    default { throw 'AvatarPath must be a JPEG, PNG, or WebP file.' }
  }
  return [pscustomobject][ordered]@{
    bytes = [IO.File]::ReadAllBytes($resolved)
    mimeType = $mimeType
    fileName = [IO.Path]::GetFileName($resolved)
    generated = $false
  }
}

function Invoke-AvatarUpload {
  param(
    [Parameter(Mandatory = $true)][object]$UploadToken,
    [Parameter(Mandatory = $true)][byte[]]$Bytes
  )

  $uploadMode = [string](Get-ObjectValue -Object $UploadToken -Names @('uploadMode'))
  if ($uploadMode -eq 'multipart') {
    throw 'Avatar upload unexpectedly requested multipart mode.'
  }
  $method = [string](Get-ObjectValue -Object $UploadToken -Names @('method'))
  $uploadUrl = [string](Get-ObjectValue -Object $UploadToken -Names @('uploadUrl', 'url'))
  if ([string]::IsNullOrWhiteSpace($method) -or [string]::IsNullOrWhiteSpace($uploadUrl)) {
    throw 'Upload token did not contain a single-request upload target.'
  }
  $targetUri = $null
  if (-not [Uri]::TryCreate($uploadUrl, [UriKind]::Absolute, [ref]$targetUri)) {
    $origin = [Uri]$apiUri.GetLeftPart([UriPartial]::Authority)
    $targetUri = [Uri]::new($origin, $uploadUrl)
  }

  $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($method), $targetUri)
  $request.Content = [System.Net.Http.ByteArrayContent]::new($Bytes)
  $headers = Get-ObjectValue -Object $UploadToken -Names @('headers')
  if ($null -ne $headers) {
    foreach ($property in $headers.PSObject.Properties) {
      $name = [string]$property.Name
      $value = [string]$property.Value
      if ($name.StartsWith('Content-', [StringComparison]::OrdinalIgnoreCase)) {
        $request.Content.Headers.Remove($name) | Out-Null
        $request.Content.Headers.TryAddWithoutValidation($name, $value) | Out-Null
      } else {
        $request.Headers.TryAddWithoutValidation($name, $value) | Out-Null
      }
    }
  }

  $response = $null
  try {
    $response = $client.SendAsync($request).GetAwaiter().GetResult()
    if (-not $response.IsSuccessStatusCode) {
      throw "Object upload failed with HTTP $([int]$response.StatusCode)."
    }
  } finally {
    $request.Dispose()
    if ($null -ne $response) {
      $response.Dispose()
    }
  }
}

function Assert-PublicProfile {
  param(
    [Parameter(Mandatory = $true)][object]$Profile,
    [Parameter(Mandatory = $true)][string]$ExpectedDisplayName,
    [AllowNull()][object]$ExpectedAvatarResourceId,
    [Parameter(Mandatory = $true)][string]$Stage
  )

  $actualName = [string](Get-ObjectValue -Object $Profile -Names @('displayName'))
  $actualAvatar = Get-NullableString (Get-ObjectValue -Object $Profile -Names @('avatarResourceId'))
  $expectedAvatar = Get-NullableString $ExpectedAvatarResourceId
  if ($actualName -cne $ExpectedDisplayName -or $actualAvatar -cne $expectedAvatar) {
    throw "$Stage profile mismatch: displayName or avatarResourceId differs."
  }
  if ([string]::IsNullOrWhiteSpace([string](Get-ObjectValue -Object $Profile -Names @('userId')))) {
    throw "$Stage profile did not include userId."
  }
  foreach ($forbidden in @('storageRef', 'objectKey', 'uploadUrl', 'signedUrl')) {
    if ($Profile.PSObject.Properties.Name -contains $forbidden) {
      throw "$Stage profile leaked forbidden storage field '$forbidden'."
    }
  }
}

$baseline = $null
$baselineName = ''
$baselineAvatar = $null
$mutationStarted = $false
$testPassed = $false
$restoreAttempted = $false
$restoreComplete = $false
$restoreWarning = ''
$testAvatarResourceId = $null
$uploadedAvatarResourceId = $null
$workspaceId = ''
$checks = [ordered]@{}

try {
  if ([string]::IsNullOrWhiteSpace($AccessToken)) {
    if ([string]::IsNullOrWhiteSpace($Phone) -or $Phone -notmatch '^1[0-9]{10}$') {
      throw 'Supply AccessToken, or a valid Phone through parameters/environment variables.'
    }
    if ([string]::IsNullOrWhiteSpace($SmsCode)) {
      throw 'SmsCode is required when AccessToken is not supplied.'
    }
    $sms = Invoke-ProfileApi -Method POST -Path '/auth/sms-code' -Body @{ phone = $Phone; scene = 'login' } `
      -IdempotencyKey ('profile-sms-' + [guid]::NewGuid().ToString('N'))
    $smsRequestId = [string](Get-ObjectValue -Object $sms -Names @('smsRequestId'))
    if ([string]::IsNullOrWhiteSpace($smsRequestId)) {
      throw 'SMS request did not return smsRequestId.'
    }
    $login = Invoke-ProfileApi -Method POST -Path '/auth/login' -Body @{
      phone = $Phone
      code = $SmsCode
      smsRequestId = $smsRequestId
      deviceId = $deviceId
      agreementAccepted = $true
      agreementVersion = 'v0.1'
      privacyVersion = 'v0.1'
      clientVersion = 'profile-api-smoke-1.0'
      timeZone = 'Asia/Shanghai'
    } -IdempotencyKey ('profile-login-' + [guid]::NewGuid().ToString('N'))
    $AccessToken = [string](Get-ObjectValue -Object $login -Names @('accessToken'))
    if ([string]::IsNullOrWhiteSpace($AccessToken)) {
      throw 'Login did not return accessToken.'
    }
    $loginWorkspace = Get-ObjectValue -Object $login -Names @('workspace')
    $workspaceId = [string](Get-ObjectValue -Object $loginWorkspace -Names @('workspaceId', 'id'))
    $checks.authentication = 'sms_login_passed'
  } else {
    $checks.authentication = 'access_token_supplied'
  }

  $status = Invoke-ProfileApi -Method GET -Path '/me/status' -Token $AccessToken
  if ([string]::IsNullOrWhiteSpace($workspaceId)) {
    $workspaceId = [string](Get-ObjectValue -Object $status -Names @('workspaceId'))
  }

  $baseline = Invoke-ProfileApi -Method GET -Path '/me/profile' -Token $AccessToken
  $baselineName = [string](Get-ObjectValue -Object $baseline -Names @('displayName'))
  $baselineAvatar = Get-NullableString (Get-ObjectValue -Object $baseline -Names @('avatarResourceId'))
  Assert-PublicProfile -Profile $baseline -ExpectedDisplayName $baselineName -ExpectedAvatarResourceId $baselineAvatar -Stage 'baseline'
  $checks.baselineRead = 'passed'

  if (-not $KeepChanges -and [string]::IsNullOrWhiteSpace($baselineName)) {
    throw 'The original displayName is empty and the public API cannot restore it. Re-run with -KeepChanges on a disposable account.'
  }

  $invalidName = 'x' * 65
  $invalidNameResult = Invoke-ProfileApi -Method PATCH -Path '/me/profile' -Token $AccessToken `
    -IdempotencyKey ('profile-invalid-name-' + [guid]::NewGuid().ToString('N')) `
    -Body @{ displayName = $invalidName } -ExpectedErrorCode 'INVALID_ARGUMENT'
  $afterInvalidName = Invoke-ProfileApi -Method GET -Path '/me/profile' -Token $AccessToken
  Assert-PublicProfile -Profile $afterInvalidName -ExpectedDisplayName $baselineName -ExpectedAvatarResourceId $baselineAvatar -Stage 'invalid-name'
  $checks.invalidNameRejected = "passed_http_$($invalidNameResult.statusCode)"

  $mutationStarted = $true
  $updatedNameProfile = Invoke-ProfileApi -Method PATCH -Path '/me/profile' -Token $AccessToken `
    -IdempotencyKey ('profile-name-update-' + [guid]::NewGuid().ToString('N')) -Body @{ displayName = $DisplayName }
  Assert-PublicProfile -Profile $updatedNameProfile -ExpectedDisplayName $DisplayName -ExpectedAvatarResourceId $baselineAvatar -Stage 'name-update'
  $nameReadback = Invoke-ProfileApi -Method GET -Path '/me/profile' -Token $AccessToken
  Assert-PublicProfile -Profile $nameReadback -ExpectedDisplayName $DisplayName -ExpectedAvatarResourceId $baselineAvatar -Stage 'name-readback'
  $checks.displayNameUpdate = 'passed'

  if (-not $SkipAvatar) {
    $missingResourceId = 'resource_' + [guid]::NewGuid().ToString('N')
    $invalidAvatarResult = Invoke-ProfileApi -Method PATCH -Path '/me/profile' -Token $AccessToken `
      -IdempotencyKey ('profile-invalid-avatar-' + [guid]::NewGuid().ToString('N')) `
      -Body @{ avatarResourceId = $missingResourceId } -ExpectedErrorCode 'RESOURCE_NOT_AVAILABLE'
    $afterInvalidAvatar = Invoke-ProfileApi -Method GET -Path '/me/profile' -Token $AccessToken
    Assert-PublicProfile -Profile $afterInvalidAvatar -ExpectedDisplayName $DisplayName -ExpectedAvatarResourceId $baselineAvatar -Stage 'invalid-avatar'
    $checks.invalidAvatarRejected = "passed_http_$($invalidAvatarResult.statusCode)"

    if (-not [string]::IsNullOrWhiteSpace($AvatarResourceId)) {
      $testAvatarResourceId = $AvatarResourceId.Trim()
      $checks.avatarUpload = 'existing_resource_used'
    } else {
      $avatar = Get-AvatarPayload -Path $AvatarPath
      $avatarBytes = [byte[]]$avatar.bytes
      if ($avatarBytes.Length -lt 1 -or $avatarBytes.Length -gt 2 * 1024 * 1024) {
        throw 'Avatar payload must be between 1 byte and 2 MiB.'
      }
      $avatarHash = Get-Sha256Hex -Bytes $avatarBytes
      $uploadToken = Invoke-ProfileApi -Method POST -Path '/media/upload-token' -Token $AccessToken `
        -IdempotencyKey ('profile-avatar-token-' + [guid]::NewGuid().ToString('N')) -Body @{
          sourceScene = 'avatar'
          fileName = [string]$avatar.fileName
          mimeType = [string]$avatar.mimeType
          sizeBytes = $avatarBytes.Length
          sha256 = $avatarHash
        }
      $uploadId = [string](Get-ObjectValue -Object $uploadToken -Names @('uploadId'))
      $tokenResourceId = [string](Get-ObjectValue -Object $uploadToken -Names @('resourceId'))
      if ([string]::IsNullOrWhiteSpace($uploadId) -or [string]::IsNullOrWhiteSpace($tokenResourceId)) {
        throw 'Avatar upload token did not return uploadId and resourceId.'
      }
      Invoke-AvatarUpload -UploadToken $uploadToken -Bytes $avatarBytes
      $completed = Invoke-ProfileApi -Method POST -Path "/media/uploads/$uploadId/complete" -Token $AccessToken `
        -IdempotencyKey ('profile-avatar-complete-' + [guid]::NewGuid().ToString('N')) -Body @{}
      $completedResource = Get-ObjectValue -Object $completed -Names @('resource')
      $completedResourceId = [string](Get-ObjectValue -Object $completedResource -Names @('resourceId'))
      if ($completedResourceId -cne $tokenResourceId -or
        [string](Get-ObjectValue -Object $completedResource -Names @('sourceScene')) -cne 'avatar' -or
        [string](Get-ObjectValue -Object $completedResource -Names @('mimeType')) -cne [string]$avatar.mimeType -or
        [int64](Get-ObjectValue -Object $completedResource -Names @('sizeBytes')) -ne $avatarBytes.Length) {
        throw 'Completed avatar Resource did not match the frozen upload contract.'
      }
      $testAvatarResourceId = $completedResourceId
      $uploadedAvatarResourceId = $completedResourceId
      $checks.avatarUpload = if ($avatar.generated) { 'generated_png_passed' } else { 'supplied_image_passed' }
    }

    $avatarProfile = Invoke-ProfileApi -Method PATCH -Path '/me/profile' -Token $AccessToken `
      -IdempotencyKey ('profile-avatar-update-' + [guid]::NewGuid().ToString('N')) `
      -Body @{ avatarResourceId = $testAvatarResourceId }
    Assert-PublicProfile -Profile $avatarProfile -ExpectedDisplayName $DisplayName -ExpectedAvatarResourceId $testAvatarResourceId -Stage 'avatar-update'
    $avatarReadback = Invoke-ProfileApi -Method GET -Path '/me/profile' -Token $AccessToken
    Assert-PublicProfile -Profile $avatarReadback -ExpectedDisplayName $DisplayName -ExpectedAvatarResourceId $testAvatarResourceId -Stage 'avatar-readback'
    $checks.avatarSelection = 'passed'
  } else {
    $testAvatarResourceId = $baselineAvatar
    $checks.avatarSelection = 'skipped'
  }

  $repeatBody = [ordered]@{ displayName = $DisplayName }
  if (-not $SkipAvatar) {
    $repeatBody.avatarResourceId = $testAvatarResourceId
  }
  $repeatProfile = Invoke-ProfileApi -Method PATCH -Path '/me/profile' -Token $AccessToken `
    -IdempotencyKey ('profile-repeat-update-' + [guid]::NewGuid().ToString('N')) -Body $repeatBody
  Assert-PublicProfile -Profile $repeatProfile -ExpectedDisplayName $DisplayName -ExpectedAvatarResourceId $testAvatarResourceId -Stage 'idempotent-repeat'
  $finalReadback = Invoke-ProfileApi -Method GET -Path '/me/profile' -Token $AccessToken
  Assert-PublicProfile -Profile $finalReadback -ExpectedDisplayName $DisplayName -ExpectedAvatarResourceId $testAvatarResourceId -Stage 'final-readback'
  $checks.repeatUpdate = 'passed'
  $checks.finalReadback = 'passed'
  $testPassed = $true
} finally {
  $shouldRestore = $mutationStarted -and (-not $KeepChanges -or -not $testPassed)
  if ($shouldRestore -and $null -ne $baseline -and -not [string]::IsNullOrWhiteSpace($AccessToken)) {
    $restoreAttempted = $true
    try {
      $restoreBody = [ordered]@{ avatarResourceId = $baselineAvatar }
      if (-not [string]::IsNullOrWhiteSpace($baselineName)) {
        $restoreBody.displayName = $baselineName
      } else {
        $restoreWarning = 'Original empty displayName cannot be restored through the public API.'
      }
      $null = Invoke-ProfileApi -Method PATCH -Path '/me/profile' -Token $AccessToken `
        -IdempotencyKey ('profile-restore-' + [guid]::NewGuid().ToString('N')) -Body $restoreBody
      $restored = Invoke-ProfileApi -Method GET -Path '/me/profile' -Token $AccessToken
      $expectedRestoredName = if ([string]::IsNullOrWhiteSpace($baselineName)) { $DisplayName } else { $baselineName }
      Assert-PublicProfile -Profile $restored -ExpectedDisplayName $expectedRestoredName -ExpectedAvatarResourceId $baselineAvatar -Stage 'restore'
      $restoreComplete = -not [string]::IsNullOrWhiteSpace($baselineName)
    } catch {
      $restoreWarning = $_.Exception.Message
      Write-Warning "Profile restoration failed: $restoreWarning"
    }
  }
  $client.Dispose()
}

if ($testPassed -and -not $KeepChanges -and -not $restoreComplete) {
  throw "Profile checks passed, but the original profile was not restored: $restoreWarning"
}

[pscustomobject][ordered]@{
  result = 'passed'
  authorizedHost = $apiUri.DnsSafeHost
  userId = [string](Get-ObjectValue -Object $baseline -Names @('userId'))
  workspaceId = $workspaceId
  testedDisplayName = $DisplayName
  testedAvatarResourceId = $testAvatarResourceId
  uploadedAvatarResourceId = $uploadedAvatarResourceId
  changesRetained = [bool]$KeepChanges
  restoreAttempted = $restoreAttempted
  restoreComplete = $restoreComplete
  restoreWarning = $restoreWarning
  checks = $checks
} | ConvertTo-Json -Depth 20
