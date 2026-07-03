#Requires -Version 7
<#
.SYNOPSIS
    Run spike-exch-liq once per nested EodhdSymbolExtractionRoots entry in operator strategies.json.

.EXAMPLE
    cd c:\Users\johnc\src\trading\eodhd-extraction
    .\Run-ExchLiqSpike.ps1 -OperatorRootPath ..\paper-john -EntryName EURO_DAX
#>
[CmdletBinding()]
param(
    [string]$OperatorRootPath = (Join-Path $PSScriptRoot '..\paper-john'),
    [string]$StrategyFile = '',
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'analysis\exch-liq-spike'),
    [int[]]$EntryIndex = @(),
    [string[]]$EntryName = @(),
    [int]$MaxSymbols = 0,
    [switch]$NoIbEnrich,
    [int]$IbPort,
    [string]$IbHost,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$operatorRoot = if ([System.IO.Path]::IsPathRooted($OperatorRootPath)) {
    $OperatorRootPath
} else {
    Join-Path $PSScriptRoot $OperatorRootPath
}
$operatorRoot = [System.IO.Path]::GetFullPath($operatorRoot)
if (-not (Test-Path -LiteralPath $operatorRoot -PathType Container)) {
    throw "Operator root not found: $operatorRoot"
}

$configPath = Join-Path $operatorRoot 'config.json'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "Config not found: $configPath"
}

if ([string]::IsNullOrWhiteSpace($StrategyFile)) {
    $StrategyFile = Join-Path $operatorRoot 'strategies.json'
}
$strategyPath = [System.IO.Path]::GetFullPath($StrategyFile)
if (-not (Test-Path -LiteralPath $strategyPath -PathType Leaf)) {
    throw "Strategy manifest not found: $strategyPath"
}

$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$strategyManifest = Get-Content -LiteralPath $strategyPath -Raw | ConvertFrom-Json
$automationRoot = [System.IO.Path]::GetFullPath((Join-Path $operatorRoot ([string]$config.AutomationRoot)))

. (Join-Path $automationRoot 'Config-Manager.ps1')
. (Join-Path $automationRoot 'Scripts\EodhdSymbolUniverseExport.ps1')
. (Join-Path $automationRoot 'Scripts\RtTradingEnvironment.ps1')

$ibConnect = $null
try {
    $ibConnect = Get-RtTradingEnvironment -OperatorRoot $operatorRoot
}
catch {
    Write-Warning "Could not read IB connection from OrderClerkConnect.xml: $($_.Exception.Message)"
}

$resolvedIbHost = if ($PSBoundParameters.ContainsKey('IbHost') -and -not [string]::IsNullOrWhiteSpace($IbHost)) {
    $IbHost.Trim()
}
elseif ($null -ne $ibConnect) {
    [string]$ibConnect.Host
}
else {
    '127.0.0.1'
}

$resolvedIbPort = if ($PSBoundParameters.ContainsKey('IbPort')) {
    $IbPort
}
elseif ($null -ne $ibConnect) {
    [int]$ibConnect.Port
}
else {
    7496
}

$roots = @(Resolve-EodhdSymbolExtractionRoots -Config $config -ConfigBaseDirectory $operatorRoot -StrategyManifest $strategyManifest)
if ($roots.Count -eq 0) {
    Write-Warning 'No nested EodhdSymbolExtractionRoots configured; nothing to run.'
    exit 0
}

$nameToIndex = @{}
for ($i = 0; $i -lt $roots.Count; $i++) {
    $n = [string]$roots[$i].Name
    if (-not [string]::IsNullOrWhiteSpace($n)) {
        $nameToIndex[$n] = $i
    }
}

$indices = @($EntryIndex | ForEach-Object { [int]$_ })
if ($EntryName.Count -gt 0) {
    foreach ($name in @($EntryName | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        if (-not $nameToIndex.ContainsKey($name)) {
            throw "EntryName '$name' not found in resolved extraction roots."
        }
        $indices += $nameToIndex[$name]
    }
}
$indices = @($indices | Sort-Object -Unique)
if ($indices.Count -eq 0) {
    $indices = @(0..($roots.Count - 1))
}

$spikeScript = Join-Path $PSScriptRoot 'spike-exch-liq\spike_exch_liq.py'
$outputRoot = [System.IO.Path]::GetFullPath(
    $(if ([System.IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory } else { Join-Path $PSScriptRoot $OutputDirectory }))
$fetchIbExe = Join-Path $automationRoot 'bin\fetch-ib-min-tick.exe'
New-Item -Path $outputRoot -ItemType Directory -Force | Out-Null

$ibEnvLabel = if ($null -ne $ibConnect) { $ibConnect.Environment } else { 'unknown' }
Write-Host "Operator:  $operatorRoot"
Write-Host "Manifest:  $strategyPath"
Write-Host "Entries:   $($indices.Count) of $($roots.Count)"
Write-Host "Output:    $outputRoot"
if (-not $NoIbEnrich) {
    Write-Host "IB:        $resolvedIbHost`:$resolvedIbPort ($ibEnvLabel)"
}
Write-Host ''

$failed = @()
foreach ($i in $indices) {
    if ($i -lt 0 -or $i -ge $roots.Count) {
        throw "EntryIndex $i out of range (0..$($roots.Count - 1))."
    }

    $entry = $roots[$i]
    $entryLabel = if (-not [string]::IsNullOrWhiteSpace([string]$entry.Name)) { [string]$entry.Name } else { "entry-$i" }
    $exchanges = ($entry.IBExchanges | ForEach-Object { [string]$_ }) -join ','
    $rtsFiles = @(Get-EodhdExtractionEntryRtsFiles -Entry $entry)
    if ($rtsFiles.Count -eq 0) {
        throw "Entry $entryLabel matched zero .rts files."
    }

    $outDir = Join-Path $outputRoot $entryLabel
    Write-Host "$entryLabel  exchanges=$exchanges  rts=$($rtsFiles.Count)  -> $outDir"

    $stage = if ($DryRun) { '<staging>' } else { Join-Path $env:TEMP "spike-exch-liq-$entryLabel-$(Get-Random)" }
    $spikeArgs = @(
        $spikeScript,
        '--strategy-path', $stage,
        '--exchanges', $exchanges,
        '--output-json', (Join-Path $outDir 'exch-liq-spike.json'),
        '--output-csv', (Join-Path $outDir 'exch-liq-spike-summary.csv'),
        '--output-html', (Join-Path $outDir 'exch-liq-spike.html'),
        '--ib-exchanges', $exchanges,
        '--ib-currency', [string]$entry.Currency,
        '--ib-host', $resolvedIbHost,
        '--ib-port', [string]$resolvedIbPort,
        '--fetch-ib-min-tick', $fetchIbExe
    )
    if ($MaxSymbols -gt 0) {
        $spikeArgs += @('--max-symbols', [string]$MaxSymbols)
    }
    if ($NoIbEnrich) {
        $spikeArgs += '--no-ib-enrich'
    }

    $quotedArgs = foreach ($arg in $spikeArgs) {
        if ($arg -match '[\s"]') { '"' + ($arg -replace '"', '""') + '"' } else { $arg }
    }
    Write-Host "  python $($quotedArgs -join ' ')" -ForegroundColor DarkGray

    if ($DryRun) {
        continue
    }

    New-Item -Path $outDir -ItemType Directory -Force | Out-Null
    New-Item -Path $stage -ItemType Directory -Force | Out-Null
    try {
        foreach ($rts in $rtsFiles) {
            $dest = Join-Path $stage (Split-Path -Path $rts -Leaf)
            try {
                New-Item -ItemType HardLink -Path $dest -Target $rts -ErrorAction Stop | Out-Null
            }
            catch {
                Copy-Item -LiteralPath $rts -Destination $dest
            }
        }

        & python @spikeArgs | Out-Host
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) { $exitCode = 0 }
        if ($exitCode -ne 0) {
            $failed += $entryLabel
        }
    }
    finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failed.Count -gt 0) {
    throw "spike-exch-liq failed: $($failed -join ', ')"
}

Write-Host ''
Write-Host "Done. HTML under: $outputRoot"
