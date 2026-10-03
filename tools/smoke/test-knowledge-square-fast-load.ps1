[CmdletBinding()]
param(
    [string]$BaseUrl = 'https://chuda.cc',
    [string]$Phone = '',
    [string]$SmsCode = '',
    [ValidateRange(1, 100)]
    [int]$FirstScreenSamples = 10,
    [ValidateRange(1, 30)]
    [int]$CompleteSamples = 5,
    [ValidateRange(1, 100)]
    [int]$PageLimit = 100,
    [string]$OutputDirectory = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

if ([string]::IsNullOrWhiteSpace($Phone)) {
    $Phone = [string]$env:HUAHUO_KNOWLEDGE_PROBE_PHONE
}
if ([string]::IsNullOrWhiteSpace($SmsCode)) {
    $SmsCode = [string]$env:HUAHUO_KNOWLEDGE_PROBE_CODE
}
$Phone = $Phone -replace '\s', ''
$SmsCode = $SmsCode -replace '\s', ''
if ([string]::IsNullOrWhiteSpace($Phone) -or [string]::IsNullOrWhiteSpace($SmsCode)) {
    throw 'Pass -Phone and -SmsCode, or set HUAHUO_KNOWLEDGE_PROBE_PHONE and HUAHUO_KNOWLEDGE_PROBE_CODE.'
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $PSScriptRoot 'results'
}

$baseUri = $null
if (-not [Uri]::TryCreate($BaseUrl.TrimEnd('/'), [UriKind]::Absolute, [ref]$baseUri)) {
    throw 'BaseUrl must be an absolute URL.'
}
if ($baseUri.Scheme -ne 'https' -or $baseUri.Host -notin @('chuda.cc', '39.107.250.25')) {
    throw 'This test is restricted to the authorized Huahuo validation endpoint.'
}

function Get-Percentile {
    param(
        [double[]]$Values,
        [double]$Percentile
    )

    if ($Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    $index = [Math]::Ceiling($Percentile * $sorted.Count) - 1
    if ($index -lt 0) { $index = 0 }
    return [Math]::Round([double]$sorted[$index], 2)
}

function New-GetOperation {
    param(
        [Parameter(Mandatory)][System.Net.Http.HttpClient]$Client,
        [Parameter(Mandatory)][string]$Path
    )

    $request = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::Get,
        [Uri]::new($baseUri, $Path)
    )
    return [pscustomobject]@{
        Request = $request
        Task = $Client.SendAsync(
            $request,
            [System.Net.Http.HttpCompletionOption]::ResponseContentRead
        )
    }
}

function Complete-GetOperation {
    param([Parameter(Mandatory)]$Operation)

    try {
        $response = $Operation.Task.GetAwaiter().GetResult()
        try {
            if (-not $response.IsSuccessStatusCode) {
                throw "GET failed with HTTP $([int]$response.StatusCode)."
            }
            $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            try {
                return $text | ConvertFrom-Json
            } catch {
                throw 'GET returned invalid JSON.'
            }
        } finally {
            $response.Dispose()
        }
    } finally {
        $Operation.Request.Dispose()
    }
}

function Assert-Page {
    param(
        [Parameter(Mandatory)]$Response,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Response.PSObject.Properties['data'] -or
        $null -eq $Response.data.PSObject.Properties['items']) {
        throw "$Name response is not a valid page."
    }
}

function Get-OptionalProperty {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

$loginBody = [ordered]@{
    phone = $Phone
    code = $SmsCode
    deviceId = 'knowledge-square-fast-load'
    agreementAccepted = $true
    agreementVersion = 'v0.1'
    privacyVersion = 'v0.1'
    clientVersion = 'knowledge-square-fast-load-20260818'
    timeZone = 'Asia/Shanghai'
} | ConvertTo-Json -Compress

$loginTimer = [Diagnostics.Stopwatch]::StartNew()
$login = Invoke-RestMethod -Uri ([Uri]::new($baseUri, '/api/v1/auth/login')) `
    -Method Post -ContentType 'application/json' -Body $loginBody -TimeoutSec 30
$loginTimer.Stop()
$token = [string]$login.data.accessToken
$workspaceId = [string]$login.data.workspace.workspaceId
if ([string]::IsNullOrWhiteSpace($token) -or [string]::IsNullOrWhiteSpace($workspaceId)) {
    throw 'Login succeeded without accessToken or workspaceId.'
}

$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.AutomaticDecompression =
    [System.Net.DecompressionMethods]::GZip -bor
    [System.Net.DecompressionMethods]::Deflate
$client = [System.Net.Http.HttpClient]::new($handler, $true)
$client.Timeout = [TimeSpan]::FromSeconds(30)
$client.DefaultRequestHeaders.Authorization =
    [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
[void]$client.DefaultRequestHeaders.TryAddWithoutValidation('Accept', 'application/json')
[void]$client.DefaultRequestHeaders.TryAddWithoutValidation('X-Client-Version', 'knowledge-square-fast-load-20260818')
[void]$client.DefaultRequestHeaders.TryAddWithoutValidation('X-Device-Id', 'knowledge-square-fast-load')
[void]$client.DefaultRequestHeaders.TryAddWithoutValidation('X-Platform', 'mobile')
[void]$client.DefaultRequestHeaders.TryAddWithoutValidation('X-Time-Zone', 'Asia/Shanghai')

$escapedWorkspaceId = [Uri]::EscapeDataString($workspaceId)
$publicationPath = "/api/v1/subscription/publications?limit=$PageLimit"
$libraryPath = "/api/v1/workspaces/$escapedWorkspaceId/subscription-library/publications?limit=$PageLimit"
$globalArticlePath = "/api/v1/subscription/articles?limit=$PageLimit"
$firstScreenResults = [System.Collections.Generic.List[object]]::new()
$completeResults = [System.Collections.Generic.List[object]]::new()

try {
    for ($sample = 1; $sample -le $FirstScreenSamples; $sample++) {
        $timer = [Diagnostics.Stopwatch]::StartNew()

        # Start all three requests before awaiting any result, matching the
        # fastest useful first-screen strategy supported by the current API.
        $publicationOperation = New-GetOperation -Client $client -Path $publicationPath
        $libraryOperation = New-GetOperation -Client $client -Path $libraryPath
        $articleOperation = New-GetOperation -Client $client -Path $globalArticlePath

        $publications = Complete-GetOperation $publicationOperation
        $library = Complete-GetOperation $libraryOperation
        $articles = Complete-GetOperation $articleOperation
        $timer.Stop()

        Assert-Page -Response $publications -Name 'publications'
        Assert-Page -Response $library -Name 'library'
        Assert-Page -Response $articles -Name 'articles'
        $publicationItems = @($publications.data.items)
        $countFieldsPresent = @(
            $publicationItems | Where-Object {
                $null -ne $_.PSObject.Properties['sectionCount'] -and
                $null -ne $_.PSObject.Properties['articleCount']
            }
        ).Count
        if ($publicationItems.Count -eq 0 -or @($articles.data.items).Count -eq 0) {
            throw 'First-screen response contains no displayable catalog data.'
        }
        if ($countFieldsPresent -ne $publicationItems.Count) {
            throw 'One or more Publications are missing sectionCount or articleCount.'
        }
        $firstScreenResults.Add([pscustomobject][ordered]@{
            sample = $sample
            totalMs = [Math]::Round($timer.Elapsed.TotalMilliseconds, 2)
            requestCount = 3
            publications = $publicationItems.Count
            libraryPublications = @($library.data.items).Count
            firstPageArticles = @($articles.data.items).Count
        })
    }

    for ($sample = 1; $sample -le $CompleteSamples; $sample++) {
        $timer = [Diagnostics.Stopwatch]::StartNew()

        # Publications and library are independent of the Article cursor
        # chain, so keep them in flight while all global Article pages load.
        $publicationOperation = New-GetOperation -Client $client -Path $publicationPath
        $libraryOperation = New-GetOperation -Client $client -Path $libraryPath

        $articleCount = 0
        $articlePages = 0
        $cursor = ''
        $observedCursors = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        do {
            $path = $globalArticlePath
            if (-not [string]::IsNullOrWhiteSpace($cursor)) {
                $path += '&cursor=' + [Uri]::EscapeDataString($cursor)
            }
            $page = Complete-GetOperation (New-GetOperation -Client $client -Path $path)
            Assert-Page -Response $page -Name 'articles'
            $articlePages++
            if ($articlePages -gt 100) { throw 'Global Article pagination exceeded its safety bound.' }
            $articleCount += @($page.data.items).Count
            $nextCursor = [string](Get-OptionalProperty -InputObject $page.data -Name 'nextCursor')
            if ([string]::IsNullOrWhiteSpace($nextCursor)) { break }
            if (-not $observedCursors.Add($nextCursor)) {
                throw 'Global Article pagination returned a repeated cursor.'
            }
            $cursor = $nextCursor
        } while ($true)

        $publications = Complete-GetOperation $publicationOperation
        $library = Complete-GetOperation $libraryOperation
        $timer.Stop()
        Assert-Page -Response $publications -Name 'publications'
        Assert-Page -Response $library -Name 'library'

        $completeResults.Add([pscustomobject][ordered]@{
            sample = $sample
            totalMs = [Math]::Round($timer.Elapsed.TotalMilliseconds, 2)
            requestCount = 2 + $articlePages
            publications = @($publications.data.items).Count
            libraryPublications = @($library.data.items).Count
            articlePages = $articlePages
            articles = $articleCount
        })
    }
} finally {
    $client.Dispose()
}

$firstScreenValues = [double[]]@($firstScreenResults | ForEach-Object { $_.totalMs })
$completeValues = [double[]]@($completeResults | ForEach-Object { $_.totalMs })
$summary = [ordered]@{
    schemaVersion = 'huahuo.knowledge-square-fast-load-test.v1'
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    result = 'passed'
    target = $baseUri.GetLeftPart([UriPartial]::Authority)
    loginMs = [Math]::Round($loginTimer.Elapsed.TotalMilliseconds, 2)
    firstScreen = [ordered]@{
        samples = $firstScreenResults.Count
        minMs = [Math]::Round([double](($firstScreenValues | Measure-Object -Minimum).Minimum), 2)
        p50Ms = Get-Percentile -Values $firstScreenValues -Percentile 0.50
        p95Ms = Get-Percentile -Values $firstScreenValues -Percentile 0.95
        results = @($firstScreenResults)
    }
    completeCatalog = [ordered]@{
        samples = $completeResults.Count
        minMs = [Math]::Round([double](($completeValues | Measure-Object -Minimum).Minimum), 2)
        p50Ms = Get-Percentile -Values $completeValues -Percentile 0.50
        p95Ms = Get-Percentile -Values $completeValues -Percentile 0.95
        results = @($completeResults)
    }
}

[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$resultPath = Join-Path $OutputDirectory "knowledge-square-fast-load-$stamp.json"
[IO.File]::WriteAllText(
    $resultPath,
    ($summary | ConvertTo-Json -Depth 10),
    [Text.UTF8Encoding]::new($false)
)

[pscustomobject]@{
    scenario = 'first-screen'
    samples = $summary.firstScreen.samples
    minMs = $summary.firstScreen.minMs
    p50Ms = $summary.firstScreen.p50Ms
    p95Ms = $summary.firstScreen.p95Ms
} | Format-Table -AutoSize
[pscustomobject]@{
    scenario = 'complete-catalog'
    samples = $summary.completeCatalog.samples
    minMs = $summary.completeCatalog.minMs
    p50Ms = $summary.completeCatalog.p50Ms
    p95Ms = $summary.completeCatalog.p95Ms
} | Format-Table -AutoSize
Write-Output "LOGIN_MS: $($summary.loginMs)"
Write-Output 'RESULT: passed'
Write-Output "JSON: $resultPath"
