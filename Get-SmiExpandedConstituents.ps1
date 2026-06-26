#Requires -Version 7
<#
.SYNOPSIS
    Fetches the approximate SMI Expanded (top 50 Swiss stocks) constituency.

.DESCRIPTION
    Pulls holdings from BlackRock public json endpoints for the iShares
    SMI ETF (CSSMI, SIX large caps ~20 equities) and iShares SMIM ETF
    (CSSMIM, mid caps ~30 equities). Their union matches the SIX SMI
    Expanded index definition (SMI + SMIM).

    Each row includes the weight within that sub-index only
    (WeightPctInIndex), not a combined SMI Expanded weight.

    Filtering matches Get-SpiConstituents.ps1: non-equity rows, empty
    tickers, zero weight, and COUPON scrip are dropped unless
    -IncludeResiduals.

    No authentication required.

.PARAMETER OutputPath
    CSV destination. Defaults to .\output\smi_expanded_constituents.csv
    next to this script.

.PARAMETER IncludeResiduals
    Keep tiny zero-weight holdings and coupon scrip entries.

.NOTES
    Also writes output\smi_expanded_constituents_import_section.rts next to
    the CSV (under the same folder as -OutputPath): a minimal Import: block
    using CODE.SW>CODE aliases and ?scriptpath?\output\SW-syminfo-rt.csv,
    matching the EODHD Swiss pattern in example_schweiz.rts.

.EXAMPLE
    pwsh ./Get-SmiExpandedConstituents.ps1
    pwsh ./Get-SmiExpandedConstituents.ps1 -OutputPath C:\temp\smi_exp.csv
#>
[CmdletBinding()]
param(
    [string]$OutputPath,
    [switch]$IncludeResiduals
)

$ErrorActionPreference = 'Stop'

$extractDir = Split-Path -Parent $PSCommandPath
. (Join-Path $extractDir 'Eodhd-RealTestSwImportSnippet.ps1')

$IsharesUrls = @{
    SMI  = 'https://www.ishares.com/ch/individual/en/products/261154/' +
           'ishares-smi-ch-fund/1495092304805.ajax' +
           '?tab=all&fileType=json&dataType=fund'
    SMIM = 'https://www.ishares.com/ch/individual/en/products/261155/' +
           'ishares-smim-ch-fund/1495092304805.ajax' +
           '?tab=all&fileType=json&dataType=fund'
}

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

function Get-IsharesEquityRows {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [Parameter(Mandatory = $true)]
        [string]$IndexKey
    )

    Write-Verbose "Fetching iShares $IndexKey holdings from $Url"
    $raw = Invoke-WebRequest -Uri $Url -Method Get `
        -Headers @{ 'User-Agent' = 'Mozilla/5.0' } -TimeoutSec 30 |
        Select-Object -ExpandProperty Content

    $response = $raw.TrimStart([char]0xFEFF) | ConvertFrom-Json

    if (-not $response.aaData) {
        throw "Unexpected response shape for $IndexKey : aaData missing."
    }

    foreach ($r in $response.aaData) {
        if ($r[$Col.AssetClass] -ne 'Equity') { continue }

        $ticker = [string]$r[$Col.Ticker]
        $weight = Get-RawValue $r[$Col.Weight]

        if (-not $IncludeResiduals) {
            if ([string]::IsNullOrWhiteSpace($ticker) -or $ticker -eq '-') { continue }
            if ($weight -le 0) { continue }
            if ($r[$Col.Name] -match '\bCOUPON\b') { continue }
        }

        [pscustomobject]@{
            Ticker             = $ticker
            Isin               = [string]$r[$Col.Isin]
            Name               = [string]$r[$Col.Name]
            Sector             = [string]$r[$Col.Sector]
            Index              = $IndexKey
            WeightPctInIndex   = [math]::Round($weight, 4)
            Exchange           = [string]$r[$Col.Exchange]
            Currency           = [string]$r[$Col.Currency]
        }
    }
}

if (-not $OutputPath) {
    $scriptDir = Split-Path -Parent $PSCommandPath
    $OutputPath = Join-Path $scriptDir 'output\smi_expanded_constituents.csv'
}

$outDir = Split-Path -Parent $OutputPath
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

$allRows = @(
    @(Get-IsharesEquityRows -Url $IsharesUrls.SMI -IndexKey 'SMI')
    @(Get-IsharesEquityRows -Url $IsharesUrls.SMIM -IndexKey 'SMIM')
)

# Prefer SMI row if same ISIN appears in both feeds (unexpected but guarded).
$rows = foreach ($g in ($allRows | Group-Object -Property Isin)) {
    $smi = @($g.Group | Where-Object { $_.Index -eq 'SMI' })
    if ($smi.Count -gt 0) {
        $smi | Select-Object -First 1
    }
    else {
        @($g.Group) | Select-Object -First 1
    }
}

$rows = $rows | Sort-Object `
    @{ Expression = { if ($_.Index -eq 'SMI') { 0 } else { 1 } } }, `
    @{ Expression = 'WeightPctInIndex'; Descending = $true }

$rows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding utf8

$snippetInfo = Export-EodhdSwRealTestImportSnippet -OutputFolder $outDir `
    -Tickers @($rows | ForEach-Object Ticker) `
    -SnippetFileName 'smi_expanded_constituents_import_section.rts' `
    -SaveAsRtdName 'smi_expanded_constituents.rtd' `
    -ImportLogFileName 'smi_expanded_constituents_import.txt' `
    -GroupTag 'SMI_EXPANDED'

$smiCount = @($rows | Where-Object { $_.Index -eq 'SMI' }).Count
$smimCount = @($rows | Where-Object { $_.Index -eq 'SMIM' }).Count

Write-Host (
    "Wrote {0} SMI Expanded constituents (SMI={1}, SMIM={2}) to {3}" -f `
        $rows.Count, $smiCount, $smimCount, $OutputPath
)

Write-Host "Wrote $($snippetInfo.SymbolCount)-symbol Import snippet to $($snippetInfo.Path)"
