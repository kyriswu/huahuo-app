[CmdletBinding()]
param(
    [string]$BaseUrl = 'https://chuda.cc',
    [string]$Phone = '',
    [string]$SmsCode = '',
    [ValidateRange(1, 20)]
    [int]$CatalogRuns = 1,
    [ValidateRange(1, 100)]
    [int]$PageLimit = 100,
    [ValidateRange(1, 500)]
    [int]$MaximumPages = 100,
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

function New-AppClient {
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AutomaticDecompression =
        [System.Net.DecompressionMethods]::GZip -bor
        [System.Net.DecompressionMethods]::Deflate
    $client = [System.Net.Http.HttpClient]::new($handler, $true)
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    return $client
}

function Get-EnvelopeData {
    param([Parameter(Mandatory)][string]$Text)

    $parsed = $Text | ConvertFrom-Json
    if ($null -ne $parsed.PSObject.Properties['data']) {
        return $parsed.data
    }
    return $parsed
}

function Get-PropertyValue {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function New-AppHeaders {
    param([string]$Token)

    $requestId = 'knowledge-square-app-load-' + [Guid]::NewGuid().ToString('N')
    $headers = [ordered]@{
        'Accept' = 'application/json'
        'X-Request-Id' = $requestId
        'X-Trace-Id' = $requestId
        'X-Client-Version' = 'knowledge-square-app-load-20260817'
        'X-Device-Id' = 'knowledge-square-app-load'
        'X-Platform' = 'mobile'
        'X-Locale' = 'zh-CN'
        'X-Time-Zone' = 'Asia/Shanghai'
    }
    if (-not [string]::IsNullOrWhiteSpace($Token)) {
        $headers['Authorization'] = "Bearer $Token"
    }
    return $headers
}

function Invoke-AppRequest {
    param(
        [Parameter(Mandatory)][System.Net.Http.HttpClient]$Client,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$PathTemplate,
        [string]$Token = '',
        [AllowNull()]$Body = $null,
        [Parameter(Mandatory)][string]$Phase,
        [int]$Run = 0,
        [int]$Ordinal = 0,
        [int]$Page = 1
    )

    $request = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::new($Method),
        [Uri]::new($baseUri, $Path)
    )
    try {
        foreach ($entry in (New-AppHeaders -Token $Token).GetEnumerator()) {
            [void]$request.Headers.TryAddWithoutValidation($entry.Key, [string]$entry.Value)
        }
        if ($null -ne $Body) {
            $payload = $Body | ConvertTo-Json -Depth 10 -Compress
            $request.Content = [System.Net.Http.StringContent]::new(
                $payload,
                [Text.Encoding]::UTF8,
                'application/json'
            )
        }

        $timer = [Diagnostics.Stopwatch]::StartNew()
        $response = $Client.SendAsync(
            $request,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
        ).GetAwaiter().GetResult()
        $headersMs = $timer.Elapsed.TotalMilliseconds
        try {
            $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            $timer.Stop()
            $text = [Text.Encoding]::UTF8.GetString($bytes)
            $metric = [pscustomobject][ordered]@{
                phase = $Phase
                run = $Run
                ordinal = $Ordinal
                page = $Page
                method = $Method
                pathTemplate = $PathTemplate
                status = [int]$response.StatusCode
                headersMs = [Math]::Round($headersMs, 2)
                totalMs = [Math]::Round($timer.Elapsed.TotalMilliseconds, 2)
                bytes = $bytes.Length
            }
            return [pscustomobject]@{
                Metric = $metric
                Text = $text
            }
        } finally {
            $response.Dispose()
        }
    } finally {
        $request.Dispose()
    }
}

function Assert-AppSuccess {
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$Phase
    )

    if ($Result.Metric.status -lt 200 -or $Result.Metric.status -ge 300) {
        throw "$Phase failed with HTTP $($Result.Metric.status)."
    }
    try {
        return Get-EnvelopeData -Text $Result.Text
    } catch {
        throw "$Phase returned invalid JSON."
    }
}

function Invoke-AppPageSequence {
    param(
        [Parameter(Mandatory)][System.Net.Http.HttpClient]$Client,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][scriptblock]$PathFactory,
        [Parameter(Mandatory)][string]$PathTemplate,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][System.Collections.Generic.List[object]]$Metrics,
        [int]$Run,
        [int]$Ordinal = 0
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $observedCursors = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $cursor = ''
    $page = 0
    do {
        $page++
        if ($page -gt $MaximumPages) {
            throw "$Phase exceeded the $MaximumPages page safety bound."
        }
        $path = & $PathFactory $cursor
        $result = Invoke-AppRequest -Client $Client -Method 'GET' -Path $path `
            -PathTemplate $PathTemplate -Token $Token -Phase $Phase -Run $Run `
            -Ordinal $Ordinal -Page $page
        $Metrics.Add($result.Metric)
        $data = Assert-AppSuccess -Result $result -Phase $Phase
        foreach ($item in @(Get-PropertyValue -InputObject $data -Name 'items')) {
            if ($null -ne $item) { $items.Add($item) }
        }
        $nextCursor = [string](Get-PropertyValue -InputObject $data -Name 'nextCursor')
        if ([string]::IsNullOrWhiteSpace($nextCursor)) { break }
        if (-not $observedCursors.Add($nextCursor)) {
            throw "$Phase returned a repeated cursor."
        }
        $cursor = $nextCursor
    } while ($true)

    return [pscustomobject]@{
        Items = @($items)
        Pages = $page
    }
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

$metrics = [System.Collections.Generic.List[object]]::new()
$runs = [System.Collections.Generic.List[object]]::new()
$client = New-AppClient
$token = ''
$workspaceId = ''
$testFailure = $null

try {
    $login = Invoke-AppRequest -Client $client -Method 'POST' -Path '/api/v1/auth/login' `
        -PathTemplate '/api/v1/auth/login' -Phase 'login' -Body ([ordered]@{
            phone = $Phone
            code = $SmsCode
            deviceId = 'knowledge-square-app-load'
            agreementAccepted = $true
            agreementVersion = 'v0.1'
            privacyVersion = 'v0.1'
            clientVersion = 'knowledge-square-app-load-20260817'
            timeZone = 'Asia/Shanghai'
        })
    $metrics.Add($login.Metric)
    $loginData = Assert-AppSuccess -Result $login -Phase 'login'
    $token = [string](Get-PropertyValue -InputObject $loginData -Name 'accessToken')
    $workspace = Get-PropertyValue -InputObject $loginData -Name 'workspace'
    $workspaceId = [string](Get-PropertyValue -InputObject $workspace -Name 'workspaceId')
    if ([string]::IsNullOrWhiteSpace($token) -or [string]::IsNullOrWhiteSpace($workspaceId)) {
        throw 'Login succeeded without accessToken or workspaceId.'
    }

    $homeResult = Invoke-AppRequest -Client $client -Method 'GET' -Path '/api/v1/home' `
        -PathTemplate '/api/v1/home' -Token $token -Phase 'home'
    $metrics.Add($homeResult.Metric)
    [void](Assert-AppSuccess -Result $homeResult -Phase 'home')

    for ($run = 1; $run -le $CatalogRuns; $run++) {
        $metricStart = $metrics.Count
        $timer = [Diagnostics.Stopwatch]::StartNew()

        $publications = Invoke-AppPageSequence -Client $client -Token $token `
            -PathFactory {
                param($cursor)
                $path = "/api/v1/subscription/publications?limit=$PageLimit"
                if (-not [string]::IsNullOrWhiteSpace($cursor)) {
                    $path += '&cursor=' + [Uri]::EscapeDataString($cursor)
                }
                return $path
            } -PathTemplate '/api/v1/subscription/publications?limit={limit}&cursor={cursor}' `
            -Phase 'catalog:publications' -Metrics $metrics -Run $run

        $escapedWorkspaceId = [Uri]::EscapeDataString($workspaceId)
        $library = Invoke-AppPageSequence -Client $client -Token $token `
            -PathFactory {
                param($cursor)
                $path = "/api/v1/workspaces/$escapedWorkspaceId/subscription-library/publications?limit=$PageLimit"
                if (-not [string]::IsNullOrWhiteSpace($cursor)) {
                    $path += '&cursor=' + [Uri]::EscapeDataString($cursor)
                }
                return $path
            } -PathTemplate '/api/v1/workspaces/{workspaceId}/subscription-library/publications?limit={limit}&cursor={cursor}' `
            -Phase 'catalog:library' -Metrics $metrics -Run $run

        $publicationValues = [ordered]@{}
        foreach ($publication in @($publications.Items)) {
            $publicationId = [string](Get-PropertyValue -InputObject $publication -Name 'publicationId')
            if ([string]::IsNullOrWhiteSpace($publicationId)) {
                throw 'Publication list contained an item without publicationId.'
            }
            $publicationValues[$publicationId] = $publication
        }
        $libraryValues = @{}
        foreach ($libraryItem in @($library.Items)) {
            $publication = Get-PropertyValue -InputObject $libraryItem -Name 'publication'
            $publicationId = [string](Get-PropertyValue -InputObject $publication -Name 'publicationId')
            if ([string]::IsNullOrWhiteSpace($publicationId)) {
                throw 'Library list contained an item without publication.publicationId.'
            }
            $libraryValues[$publicationId] = $libraryItem
            if (-not $publicationValues.Contains($publicationId)) {
                $publicationValues[$publicationId] = $publication
            }
        }

        $sectionTotal = 0
        $articleTotal = 0
        $unavailableCount = 0
        $countMismatches = [System.Collections.Generic.List[object]]::new()
        $ordinal = 0
        foreach ($entry in $publicationValues.GetEnumerator()) {
            $ordinal++
            $publicationId = [string]$entry.Key
            $publication = $entry.Value
            $libraryItem = $libraryValues[$publicationId]
            $availability = [string](Get-PropertyValue -InputObject $libraryItem -Name 'availability')
            if ($null -ne $libraryItem -and $availability -eq 'unavailable') {
                $unavailableCount++
                continue
            }
            $escapedPublicationId = [Uri]::EscapeDataString($publicationId)

            $sections = Invoke-AppPageSequence -Client $client -Token $token `
                -PathFactory {
                    param($cursor)
                    $path = "/api/v1/subscription/publications/$escapedPublicationId/sections?limit=$PageLimit"
                    if (-not [string]::IsNullOrWhiteSpace($cursor)) {
                        $path += '&cursor=' + [Uri]::EscapeDataString($cursor)
                    }
                    return $path
                } -PathTemplate '/api/v1/subscription/publications/{publicationId}/sections?limit={limit}&cursor={cursor}' `
                -Phase 'catalog:sections' -Metrics $metrics -Run $run -Ordinal $ordinal

            $articles = Invoke-AppPageSequence -Client $client -Token $token `
                -PathFactory {
                    param($cursor)
                    $path = "/api/v1/subscription/articles?publicationId=$escapedPublicationId&limit=$PageLimit"
                    if (-not [string]::IsNullOrWhiteSpace($cursor)) {
                        $path += '&cursor=' + [Uri]::EscapeDataString($cursor)
                    }
                    return $path
                } -PathTemplate '/api/v1/subscription/articles?publicationId={publicationId}&limit={limit}&cursor={cursor}' `
                -Phase 'catalog:articles' -Metrics $metrics -Run $run -Ordinal $ordinal

            $actualSections = @($sections.Items).Count
            $actualArticles = @($articles.Items).Count
            $sectionTotal += $actualSections
            $articleTotal += $actualArticles
            $expectedSections = Get-PropertyValue -InputObject $publication -Name 'sectionCount'
            $expectedArticles = Get-PropertyValue -InputObject $publication -Name 'articleCount'
            if (($null -ne $expectedSections -and [int]$expectedSections -ne $actualSections) -or
                ($null -ne $expectedArticles -and [int]$expectedArticles -ne $actualArticles)) {
                $countMismatches.Add([pscustomobject]@{
                    ordinal = $ordinal
                    expectedSections = $expectedSections
                    actualSections = $actualSections
                    expectedArticles = $expectedArticles
                    actualArticles = $actualArticles
                })
            }
        }

        $timer.Stop()
        $runMetrics = @($metrics | Select-Object -Skip $metricStart)
        $runs.Add([pscustomobject][ordered]@{
            run = $run
            result = if ($countMismatches.Count -eq 0) { 'passed' } else { 'failed' }
            totalMs = [Math]::Round($timer.Elapsed.TotalMilliseconds, 2)
            requestCount = $runMetrics.Count
            responseBytes = [long](($runMetrics.bytes | Measure-Object -Sum).Sum)
            publicationCount = $publicationValues.Count
            libraryPublicationCount = @($library.Items).Count
            unavailablePublicationCount = $unavailableCount
            sectionCount = $sectionTotal
            articleCount = $articleTotal
            countMismatchCount = $countMismatches.Count
            countMismatches = @($countMismatches)
        })
        if ($countMismatches.Count -ne 0) {
            throw "Run $run found $($countMismatches.Count) Publication count mismatches."
        }
    }
} catch {
    $testFailure = $_.Exception.Message
} finally {
    $client.Dispose()
}

$phaseSummary = @(
    $metrics |
        Group-Object phase |
        ForEach-Object {
            $values = [double[]]@($_.Group | ForEach-Object { $_.totalMs })
            [pscustomobject][ordered]@{
                phase = $_.Name
                samples = $values.Count
                p50Ms = Get-Percentile -Values $values -Percentile 0.50
                p95Ms = Get-Percentile -Values $values -Percentile 0.95
                maxMs = [Math]::Round([double](($values | Measure-Object -Maximum).Maximum), 2)
                statuses = (@($_.Group.status | Sort-Object -Unique) -join ',')
            }
        } |
        Sort-Object phase
)

[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$jsonPath = Join-Path $OutputDirectory "knowledge-square-app-load-$stamp.json"
$csvPath = Join-Path $OutputDirectory "knowledge-square-app-load-$stamp.csv"
$result = [ordered]@{
    schemaVersion = 'huahuo.knowledge-square-app-load-test.v1'
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    result = if ($null -eq $testFailure) { 'passed' } else { 'failed' }
    failure = $testFailure
    target = $baseUri.GetLeftPart([UriPartial]::Authority)
    catalogRunsRequested = $CatalogRuns
    catalogRunsCompleted = $runs.Count
    pageLimit = $PageLimit
    runs = @($runs)
    phaseSummary = $phaseSummary
    metrics = @($metrics)
}
[IO.File]::WriteAllText(
    $jsonPath,
    ($result | ConvertTo-Json -Depth 12),
    [Text.UTF8Encoding]::new($false)
)
$metrics | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

$phaseSummary | Format-Table -AutoSize
$runs | Format-Table run, result, totalMs, requestCount, publicationCount, sectionCount, articleCount, countMismatchCount -AutoSize
Write-Output "RESULT: $($result.result)"
if ($null -ne $testFailure) { Write-Output "FAILURE: $testFailure" }
Write-Output "JSON: $jsonPath"
Write-Output "CSV:  $csvPath"
if ($null -ne $testFailure) { exit 1 }
