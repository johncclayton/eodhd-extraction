#Requires -Version 7
<#
.SYNOPSIS
    Fetches the current Swiss Performance Index (SPI) constituents.

.DESCRIPTION
    Pulls the daily holdings file of the iShares Core SPI ETF (CHSPI,
    ISIN CH0237935652) directly from BlackRock's public data endpoint
    and emits one row per equity holding with ticker, ISIN, name,
    sector, weight, exchange, and currency.

    The ETF tracks the SPI with optimised replication, so the holdings
    list is a near-complete proxy for live SPI membership (typically
    ~200 equities, matching SIX/UBS factsheet counts). Tiny zero-weight
    residuals and corporate-action scrip ("... COUPON" entries with no
    ticker) are filtered out by default; pass -IncludeResiduals to keep
    them.

    No authentication required.

.PARAMETER OutputPath
    CSV destination. Defaults to .\output\spi_constituents.csv next to
    this script.

.PARAMETER IncludeResiduals
    Keep tiny zero-weight holdings and coupon scrip entries.

.NOTES
    Also writes output\spi_constituents_import_section.rts next to the CSV
    (under the same folder as -OutputPath): a minimal Import: block using
    CODE.SW>CODE aliases and ?scriptpath?\output\SW-syminfo-rt.csv, matching
    the EODHD Swiss pattern in example_schweiz.rts.

.EXAMPLE
    pwsh ./Get-SpiConstituents.ps1
    pwsh ./Get-SpiConstituents.ps1 -OutputPath C:\temp\spi.csv
#>
[CmdletBinding()]
param(
    [string]$OutputPath,
    [switch]$IncludeResiduals
)

$ErrorActionPreference = 'Stop'

$extractDir = Split-Path -Parent $PSCommandPath
. (Join-Path $extractDir 'Eodhd-RealTestSwImportSnippet.ps1')

$IsharesUrl = 'https://www.ishares.com/ch/individual/en/products/264107/' +
              'ishares-spi-ch-fund/1495092304805.ajax' +
              '?tab=all&fileType=json&dataType=fund'

# Column positions in the iShares "aaData" rows (schema as of 2026-05).
# If BlackRock changes the layout, adjust these indices.
$Col = @{
    Ticker     = 0
    Name       = 1
    Sector     = 2
    AssetClass = 3
    Weight     = 5
    Isin       = 8
    Exchange   = 11
    Currency   = 12
}

function Get-RawValue {
    param($Value)
    if ($Value -is [pscustomobject] -and $null -ne $Value.raw) {
        return [double]$Value.raw
    }
    return [double]$Value
}

if (-not $OutputPath) {
    $scriptDir = Split-Path -Parent $PSCommandPath
    $OutputPath = Join-Path $scriptDir 'output\spi_constituents.csv'
}

$outDir = Split-Path -Parent $OutputPath
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

Write-Verbose "Fetching iShares CHSPI holdings from $IsharesUrl"
# The endpoint serves JSON but with text/* content-type and a UTF-8 BOM,
# so Invoke-RestMethod returns a string. Fetch raw and parse explicitly.
$raw = Invoke-WebRequest -Uri $IsharesUrl -Method Get `
    -Headers @{ 'User-Agent' = 'Mozilla/5.0' } -TimeoutSec 30 |
    Select-Object -ExpandProperty Content

$response = $raw.TrimStart([char]0xFEFF) | ConvertFrom-Json

if (-not $response.aaData) {
    throw 'Unexpected response shape: aaData missing.'
}

$rows = foreach ($r in $response.aaData) {
    if ($r[$Col.AssetClass] -ne 'Equity') { continue }

    $ticker = [string]$r[$Col.Ticker]
    $weight = Get-RawValue $r[$Col.Weight]

    if (-not $IncludeResiduals) {
        if ([string]::IsNullOrWhiteSpace($ticker) -or $ticker -eq '-') { continue }
        if ($weight -le 0) { continue }
        if ($r[$Col.Name] -match '\bCOUPON\b') { continue }
    }

    [pscustomobject]@{
        Ticker    = $ticker
        Isin      = [string]$r[$Col.Isin]
        Name      = [string]$r[$Col.Name]
        Sector    = [string]$r[$Col.Sector]
        WeightPct = [math]::Round($weight, 4)
        Exchange  = [string]$r[$Col.Exchange]
        Currency  = [string]$r[$Col.Currency]
    }
}

$rows = $rows | Sort-Object -Property WeightPct -Descending

$rows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding utf8

$snippetInfo = Export-EodhdSwRealTestImportSnippet -OutputFolder $outDir `
    -Tickers @($rows | ForEach-Object Ticker) `
    -SnippetFileName 'spi_constituents_import_section.rts' `
    -SaveAsRtdName 'spi_constituents.rtd' `
    -ImportLogFileName 'spi_constituents_import.txt' `
    -GroupTag 'SPI'

Write-Host "Wrote $($rows.Count) SPI constituents to $OutputPath"
Write-Host "Wrote $($snippetInfo.SymbolCount)-symbol Import snippet to $($snippetInfo.Path)"
