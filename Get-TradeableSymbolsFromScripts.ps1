<#
.SYNOPSIS
    Extracts the EODHD tradeable-symbol universe from RealTest strategy scripts.

.DESCRIPTION
    Walks the given .rts files, tracking the active `DataSource:` per Import block, and
    collects symbols from `IncludeList:` lines that belong to a `DataSource: EODHD` block
    (Norgate include lists such as index or FX symbols are ignored).

    Each token of the form `ABBN.SW>ABBN` is reduced to the RealTest symbol (the part after
    '>'), a trailing two-letter exchange suffix (e.g. `.SW`, `.CA`) is stripped, and any
    RealTest named-list annotation like {"MP_SCHWEIZ"} is removed. The result is the bare
    symbol set RealTest uses in its data file (e.g. ABBN, NESN, NOVN).

.PARAMETER StrategyPath
    Directory containing .rts scripts, a single .rts file, or a file glob to scan.

.PARAMETER OutFile
    Optional path to write the symbol list (one per line). Always returns the array too.

.EXAMPLE
    ./Get-TradeableSymbolsFromScripts.ps1 -StrategyPath C:\path\to\Strategies\CHF -OutFile .\output\tradeable-symbols.txt
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$StrategyPath,

    [Parameter(Mandatory = $false)]
    [string]$OutFile = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-EodhdSymbolsFromRtsFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $symbols = New-Object 'System.Collections.Generic.List[string]'
    $currentSource = ""

    foreach ($rawLine in (Get-Content -LiteralPath $Path)) {
        $line = $rawLine.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith("//")) {
            continue
        }

        $dsMatch = [regex]::Match($line, '^DataSource:\s*(\S+)', 'IgnoreCase')
        if ($dsMatch.Success) {
            $currentSource = $dsMatch.Groups[1].Value.Trim().ToUpperInvariant()
            continue
        }

        $ilMatch = [regex]::Match($line, '^IncludeList:\s*(.+)$', 'IgnoreCase')
        if (-not $ilMatch.Success) {
            continue
        }
        if ($currentSource -ne "EODHD") {
            continue
        }

        $rhs = $ilMatch.Groups[1].Value
        # Drop RealTest named-list annotations like {"MP_SCHWEIZ"}.
        $rhs = [regex]::Replace($rhs, '\{[^}]*\}', '')
        # Strip inline comments.
        $rhs = ($rhs -split '//', 2)[0]

        foreach ($rawTok in ($rhs -split ',')) {
            $tok = $rawTok.Trim()
            if ($tok.Length -eq 0) { continue }

            $gt = $tok.LastIndexOf('>')
            if ($gt -ge 0) {
                $tok = $tok.Substring($gt + 1).Trim()
            }
            if ($tok -match '\.[A-Z]{2}$') {
                $tok = $tok.Substring(0, $tok.Length - 3)
            }
            if ($tok.Length -gt 0) {
                $symbols.Add($tok)
            }
        }
    }

    return $symbols
}

$files = @()
if (Test-Path -LiteralPath $StrategyPath -PathType Container) {
    $files = @(Get-ChildItem -LiteralPath $StrategyPath -Filter '*.rts' -File | Select-Object -ExpandProperty FullName)
}
elseif (Test-Path -LiteralPath $StrategyPath -PathType Leaf) {
    $files = @($StrategyPath)
}
else {
    $files = @(Get-ChildItem -Path $StrategyPath -File | Select-Object -ExpandProperty FullName)
}

if ($files.Count -eq 0) {
    throw "No strategy files found at: $StrategyPath"
}

$all = New-Object 'System.Collections.Generic.List[string]'
foreach ($file in $files) {
    foreach ($sym in (Get-EodhdSymbolsFromRtsFile -Path $file)) {
        $all.Add($sym)
    }
}

$unique = @($all | Sort-Object -Unique)

if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
    $dir = Split-Path -Path $OutFile -Parent
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    $unique -join [Environment]::NewLine | Out-File -LiteralPath $OutFile -Encoding utf8
    Write-Host ("Wrote {0} symbols to {1}" -f $unique.Count, $OutFile)
}

return $unique
