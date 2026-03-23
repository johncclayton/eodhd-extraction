<#
.SYNOPSIS
  Validates EODHD bulk EOD coverage for symbols in *-symbols-full.json (explicit config.exchanges[] only).

.DESCRIPTION
  For each configured exchange: resolves prior calendar date as the last day before the anchor that is not Saturday or Sunday (no exchange holiday API),
  fetches eod-bulk-last-day for that date. All tickers from the European stocks file (MustHaveListPath) are merged into one set; per exchange, any listing row whose Code is in that set is validated.
  All other listing rows are ignored. Writes missing\<EXCHANGE>-missing-YYYY-MM-DD.tsv only for those must-haves absent from bulk (UTF-8 TSV; header-only when none missing).
  No OrderClerk mapping. API token: EODHD_API_TOKEN in .env or env.

.PARAMETER ConfigPath
  Path to eodhd-config.json (default: alongside this script).

.PARAMETER MustHaveListPath
  Path to the European ticker file (default: 2026.02.25_European_Stocks.txt alongside this script). Every symbol from every index block in the file is unioned into one must-have set.

.PARAMETER AsOfDate
  Anchor calendar date (yyyy-MM-dd). Default: UTC today.

.PARAMETER Exchange
  Optional: process only this exchange code (must appear in config.exchanges).

.PARAMETER ResolveLastBarForMissing
  If set, calls per-symbol /eod for each missing row to fill LastBarDate (extra API usage).

.NOTES
  EODHD does not document a fixed time when bulk data for a session is complete; run after feeds have settled if needed.
#>
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "",

    [Parameter(Mandatory = $false)]
    [string]$MustHaveListPath = "",

    [Parameter(Mandatory = $false)]
    [string]$AsOfDate = "",

    [Parameter(Mandatory = $false)]
    [string]$Exchange = "",

    [Parameter(Mandatory = $false)]
    [switch]$ResolveLastBarForMissing
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:EodhdRepoRoot = $PSScriptRoot

function Resolve-ConfigRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$ConfigDirectory
    )
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $ConfigDirectory $Path)
}

function Get-DotEnvValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DotEnvPath,
        [Parameter(Mandatory = $true)]
        [string]$Key
    )
    if (-not (Test-Path -LiteralPath $DotEnvPath)) { return $null }
    foreach ($rawLine in (Get-Content -LiteralPath $DotEnvPath)) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) { continue }
        if ($line.StartsWith("export ")) { $line = $line.Substring(7).Trim() }
        $parts = $line.Split("=", 2)
        if ($parts.Count -ne 2) { continue }
        $name = $parts[0].Trim()
        if ($name -ne $Key) { continue }
        $value = $parts[1].Trim()
        if ($value.Length -ge 2) {
            $dq = $value.StartsWith('"') -and $value.EndsWith('"')
            $sq = $value.StartsWith("'") -and $value.EndsWith("'")
            if ($dq -or $sq) { $value = $value.Substring(1, $value.Length - 2) }
        }
        return $value
    }
    return $null
}

function ConvertTo-EodhdTsvField {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return "" }
    return ([string]$Value -replace "[\r\n\t]", " ").Trim()
}

function Invoke-EodhdGetWithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds,
        [Parameter(Mandatory = $false)]
        [int]$MaxAttempts = 5
    )
    $delaySec = 1
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return Invoke-RestMethod -Method Get -Uri $Uri -TimeoutSec $TimeoutSeconds
        }
        catch {
            $status = $null
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $status = [int]$_.Exception.Response.StatusCode
            }
            $retry = ($status -eq 429) -or ($status -ge 500)
            if (-not $retry -or $attempt -eq $MaxAttempts) { throw }
            Start-Sleep -Seconds $delaySec
            if ($delaySec -lt 30) { $delaySec = [Math]::Min(30, $delaySec * 2) }
        }
    }
    throw "Unreachable"
}

function Get-PriorSessionDate {
    param(
        [Parameter(Mandatory = $true)]
        [datetime]$AnchorUtcDate,
        [Parameter(Mandatory = $true)]
        [string]$ExchangeCode
    )

    $candidate = $AnchorUtcDate.Date.AddDays(-1)
    for ($i = 0; $i -lt 40; $i++) {
        $dow = $candidate.DayOfWeek
        if ($dow -eq [DayOfWeek]::Saturday -or $dow -eq [DayOfWeek]::Sunday) {
            $candidate = $candidate.AddDays(-1)
            continue
        }
        return $candidate.Date
    }
    throw "Could not resolve a weekday before anchor $($AnchorUtcDate.ToString('yyyy-MM-dd')) for exchange $ExchangeCode within 40 days."
}

function ConvertTo-BulkDataRows {
    param([AllowNull()] $BulkPayload)
    if ($null -eq $BulkPayload) { return @() }
    if ($BulkPayload -is [System.Array]) {
        $arr = @($BulkPayload)
        if ($arr.Count -eq 1 -and $null -ne $arr[0] -and $arr[0] -is [System.Array]) {
            return @($arr[0])
        }
        return $arr
    }
    if ($BulkPayload -is [pscustomobject]) {
        foreach ($prop in $BulkPayload.PSObject.Properties) {
            if ($prop.Name.Equals('data', [StringComparison]::OrdinalIgnoreCase) -and $prop.Value -is [System.Array]) {
                return @($prop.Value)
            }
        }
    }
    return @($BulkPayload)
}

function Get-BulkSymbolDictionary {
    param(
        [Parameter(Mandatory = $true)]
        $BulkPayload,
        [Parameter(Mandatory = $false)]
        [string]$ExchangeCode = ""
    )
    $dict = @{}
    $rows = ConvertTo-BulkDataRows -BulkPayload $BulkPayload
    $nameCandidates = @('code', 'Code', 'ticker', 'Ticker')
    foreach ($row in $rows) {
        if ($null -eq $row) { continue }
        $code = $null
        foreach ($n in $nameCandidates) {
            $p = $row.PSObject.Properties | Where-Object { $_.Name -eq $n } | Select-Object -First 1
            if ($null -ne $p -and -not [string]::IsNullOrWhiteSpace([string]$p.Value)) {
                $code = [string]$p.Value
                break
            }
        }
        if ([string]::IsNullOrWhiteSpace($code)) { continue }
        $trimmed = $code.Trim()
        $bareKey = $trimmed.ToUpperInvariant()
        if (-not $dict.ContainsKey($bareKey)) { $dict[$bareKey] = $row }
        $ex = $ExchangeCode.Trim()
        if (-not [string]::IsNullOrWhiteSpace($ex)) {
            $suffix = "." + $ex
            if (-not $bareKey.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase)) {
                $fullKey = ($trimmed + $suffix).ToUpperInvariant()
                if (-not $dict.ContainsKey($fullKey)) { $dict[$fullKey] = $row }
            }
        }
    }
    return [pscustomobject]@{
        Dictionary = $dict
        RowCount   = $rows.Count
    }
}

function Get-LastBarDateFromEod {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ApiSymbol,
        [Parameter(Mandatory = $true)]
        [string]$ApiBaseUrl,
        [Parameter(Mandatory = $true)]
        [string]$ApiToken,
        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )
    $tok = [uri]::EscapeDataString($ApiToken)
    $sym = [uri]::EscapeDataString($ApiSymbol)
    $base = $ApiBaseUrl.TrimEnd('/')
    $uri = "{0}/eod/{1}?api_token={2}&period=d&order=d&limit=1&fmt=json" -f $base, $sym, $tok
    try {
        $data = Invoke-EodhdGetWithRetry -Uri $uri -TimeoutSeconds $TimeoutSeconds
        $arr = @($data)
        if ($arr.Count -eq 0) { return "" }
        $first = $arr[0]
        if ($null -ne $first.date) { return [string]$first.date }
        if ($null -ne $first.Date) { return [string]$first.Date }
    }
    catch {
        return ""
    }
    return ""
}

function Expand-ExplicitExchangeCodes {
    param([Parameter(Mandatory = $true)]$Config)

    $codes = [System.Collections.Generic.List[string]]::new()
    foreach ($ex in @($Config.exchanges)) {
        if ($null -eq $ex) { continue }
        $cv = $ex.code
        if ($cv -is [System.Array]) {
            foreach ($c in @($cv)) {
                $s = [string]$c
                if (-not [string]::IsNullOrWhiteSpace($s)) { $codes.Add($s.Trim()) }
            }
        }
        else {
            $s = [string]$cv
            if (-not [string]::IsNullOrWhiteSpace($s)) { $codes.Add($s.Trim()) }
        }
    }
    return @($codes | Sort-Object -Unique)
}

function Read-EuropeanStocksMustHaveSet {
    param([Parameter(Mandatory = $true)][string]$FilePath)
    if (-not (Test-Path -LiteralPath $FilePath)) {
        throw "Must-have European stocks file not found: $FilePath"
    }
    $all = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($rawLine in Get-Content -LiteralPath $FilePath -Encoding UTF8) {
        $trim = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($trim)) { continue }
        if ($trim.StartsWith("//")) { continue }
        if ($trim -match '^.+:\s*$') { continue }
        foreach ($part in $trim.Split(',')) {
            $t = $part.Trim()
            if ([string]::IsNullOrWhiteSpace($t)) { continue }
            [void]$all.Add($t)
        }
    }
    return $all
}

# --- main ---
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot "eodhd-config.json"
}

. (Join-Path $script:EodhdRepoRoot "Eodhd-Config.ps1")

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}

$configDirectory = Split-Path -Path $ConfigPath -Parent
$config = Get-EodhdEffectiveConfig -ConfigPath $ConfigPath

$configuredCurrencies = @(
    @($config.currencies) |
    ForEach-Object { [string]$_ } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)
$configuredCountries = @(
    @($config.countries) |
    ForEach-Object { [string]$_ } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)
if ($configuredCurrencies.Count -gt 0 -or $configuredCountries.Count -gt 0) {
    throw "Invoke-EodhdBulkEodValidation only supports explicit config.exchanges[].code. Clear currencies/countries or use a config with exchanges[] only."
}

$exchangeCodes = @(Expand-ExplicitExchangeCodes -Config $config)
if ($exchangeCodes.Count -eq 0) {
    throw "No exchange codes found in config.exchanges."
}

if (-not [string]::IsNullOrWhiteSpace($Exchange)) {
    $want = $Exchange.Trim()
    if ($exchangeCodes -notcontains $want) {
        throw "Exchange '$want' is not listed in config.exchanges."
    }
    $exchangeCodes = @($want)
}

$apiBaseUrl = [string]$config.apiBaseUrl
if ([string]::IsNullOrWhiteSpace($apiBaseUrl)) {
    throw "Missing config value: apiBaseUrl"
}

$requestTimeoutSeconds = 60
if ($null -ne $config.requestTimeoutSeconds -and [int]$config.requestTimeoutSeconds -gt 0) {
    $requestTimeoutSeconds = [int]$config.requestTimeoutSeconds
}

$dotEnvPath = Resolve-ConfigRelativePath -Path ".env" -ConfigDirectory $configDirectory
$token = Get-DotEnvValue -DotEnvPath $dotEnvPath -Key "EODHD_API_TOKEN"
if ([string]::IsNullOrWhiteSpace($token)) {
    $token = [Environment]::GetEnvironmentVariable("EODHD_API_TOKEN")
}
if ([string]::IsNullOrWhiteSpace($token)) {
    throw "Missing API token. Provide EODHD_API_TOKEN in .env or set EODHD_API_TOKEN in environment."
}

$symbolFormat = [string]$config.symbolFormat
if ([string]::IsNullOrWhiteSpace($symbolFormat)) {
    $symbolFormat = "{Code}.{ExchangeCode}"
}

$outputDirectory = Resolve-ConfigRelativePath -Path ([string]$config.outputDirectory) -ConfigDirectory $configDirectory
if (-not (Test-Path -LiteralPath $outputDirectory)) {
    throw "Output directory not found: $outputDirectory (run symbol export first)."
}

if ([string]::IsNullOrWhiteSpace($AsOfDate)) {
    $anchor = [datetime]::UtcNow.Date
}
else {
    $anchor = [datetime]::ParseExact($AsOfDate.Trim(), "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal).Date
}

$missingRoot = Join-Path $PSScriptRoot "missing"
if (-not (Test-Path -LiteralPath $missingRoot)) {
    New-Item -Path $missingRoot -ItemType Directory -Force | Out-Null
}

if ([string]::IsNullOrWhiteSpace($MustHaveListPath)) {
    $mustHaveListResolved = Join-Path $PSScriptRoot "2026.02.25_European_Stocks.txt"
}
elseif ([System.IO.Path]::IsPathRooted($MustHaveListPath)) {
    $mustHaveListResolved = $MustHaveListPath
}
else {
    $mustHaveListResolved = Resolve-ConfigRelativePath -Path $MustHaveListPath.Trim() -ConfigDirectory $configDirectory
}

$europeanMustHaveAll = Read-EuropeanStocksMustHaveSet -FilePath $mustHaveListResolved
Write-Host "Loaded $($europeanMustHaveAll.Count) unique must-have tickers from `"$(Split-Path $mustHaveListResolved -Leaf)`"."

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
$headerLine = "ExchangeCode`tSymbol`tCurrency`tName`tLastBarDate"
$grandPresent = 0
$grandMustHave = 0

foreach ($exCode in $exchangeCodes) {
    Write-Host "Processing exchange: $exCode (anchor UTC $($anchor.ToString('yyyy-MM-dd')))"

    $symbolsPath = Join-Path $outputDirectory ("{0}-symbols-full.json" -f $exCode)
    if (-not (Test-Path -LiteralPath $symbolsPath)) {
        throw "Symbols file not found: $symbolsPath"
    }

    $listing = Get-Content -LiteralPath $symbolsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $listingRows = @($listing)

    $listingCodes = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($row in $listingRows) {
        $lc = [string]$row.Code
        if ([string]::IsNullOrWhiteSpace($lc)) { continue }
        [void]$listingCodes.Add($lc.Trim())
    }

    $mustHaveSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($lc in $listingCodes) {
        if ($europeanMustHaveAll.Contains($lc)) { [void]$mustHaveSet.Add($lc) }
    }

    if ($mustHaveSet.Count -eq 0) {
        Write-Host "  No symbols from the European must-have set appear in this export; skipping bulk API and missing output."
        continue
    }

    $priorSession = Get-PriorSessionDate -AnchorUtcDate $anchor -ExchangeCode $exCode
    $sessionStr = $priorSession.ToString("yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)
    Write-Host "  Prior session date used: $sessionStr"

    $tok = [uri]::EscapeDataString($token)
    $base = $apiBaseUrl.TrimEnd('/')
    $bulkUri = "{0}/eod-bulk-last-day/{1}?api_token={2}&date={3}&fmt=json" -f $base, $exCode, $tok, $sessionStr
    $bulk = Invoke-EodhdGetWithRetry -Uri $bulkUri -TimeoutSeconds $requestTimeoutSeconds
    $bulkParsed = Get-BulkSymbolDictionary -BulkPayload $bulk -ExchangeCode $exCode
    $bulkDict = $bulkParsed.Dictionary
    Write-Host "  Bulk rows in response: $($bulkParsed.RowCount) ; symbol lookup keys: $($bulkDict.Count)"

    $present = 0
    $missingRows = [System.Collections.Generic.List[object]]::new()

    foreach ($row in $listingRows) {
        $code = [string]$row.Code
        if ([string]::IsNullOrWhiteSpace($code)) { continue }
        $codeTrim = $code.Trim()
        if (-not $mustHaveSet.Contains($codeTrim)) { continue }

        $apiSymbol = $symbolFormat.Replace("{Code}", $codeTrim).Replace("{ExchangeCode}", $exCode)
        $lookupKey = $apiSymbol.ToUpperInvariant()
        if ($bulkDict.ContainsKey($lookupKey)) {
            $present++
        }
        else {
            $exListing = if ($null -ne $row.Exchange) { [string]$row.Exchange } else { $exCode }
            $cur = if ($null -ne $row.Currency) { [string]$row.Currency } else { "" }
            $nm = if ($null -ne $row.Name) { [string]$row.Name } else { "" }
            $missingRows.Add([pscustomobject]@{
                    ExchangeCode = $exListing
                    Symbol       = $apiSymbol
                    Currency     = $cur
                    Name         = $nm
                })
        }
    }

    $grandMustHave += $mustHaveSet.Count
    $grandPresent += $present
    $missCount = $missingRows.Count
    Write-Host "  Must-have in export: $($mustHaveSet.Count) ; Present in bulk: $present ; Missing: $missCount ; Listing rows (ignored if not must-have): $($listingRows.Count)"
    if ($bulkParsed.RowCount -eq 0 -and $mustHaveSet.Count -gt 0) {
        Write-Warning "Bulk returned zero data rows for $exCode on $sessionStr. If your plan does not include the Bulk EOD API (see EODHD pricing), the request may succeed with an empty payload — upgrade or use a token with bulk access."
    }

    $outPath = Join-Path $missingRoot ("{0}-missing-{1}.txt" -f $exCode, $sessionStr)
    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add($headerLine)

    foreach ($m in $missingRows) {
        $lastBar = "N/A"
        if ($ResolveLastBarForMissing) {
            $lb = Get-LastBarDateFromEod -ApiSymbol $m.Symbol -ApiBaseUrl $apiBaseUrl -ApiToken $token -TimeoutSeconds $requestTimeoutSeconds
            if (-not [string]::IsNullOrWhiteSpace($lb)) { $lastBar = $lb }
        }
        $line = "{0}`t{1}`t{2}`t{3}`t{4}" -f @(
            (ConvertTo-EodhdTsvField $m.ExchangeCode),
            (ConvertTo-EodhdTsvField $m.Symbol),
            (ConvertTo-EodhdTsvField $m.Currency),
            (ConvertTo-EodhdTsvField $m.Name),
            (ConvertTo-EodhdTsvField $lastBar)
        )
        [void]$lines.Add($line)
    }

    [System.IO.File]::WriteAllLines($outPath, $lines, $utf8NoBom)
    Write-Host "  Wrote: $outPath"
}

Write-Host ""
Write-Host "Must-have symbols with bulk data (all processed exchanges): $grandPresent of $grandMustHave"
Write-Host "Missing must-haves are listed under: $missingRoot"
