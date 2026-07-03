#Requires -Version 7
<#
.SYNOPSIS
    Extracts the EODHD tradeable-symbol universe from RealTest strategy scripts.

.DESCRIPTION
    Thin CLI wrapper around rt-automation/Scripts/Get-TradeableSymbolsFromScripts.ps1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$StrategyPath,

    [Parameter(Mandatory = $false)]
    [string[]]$FilePatterns = @(),

    [Parameter(Mandatory = $false)]
    [string]$OutFile = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$helper = Join-Path $PSScriptRoot '..\rt-automation\Scripts\Get-TradeableSymbolsFromScripts.ps1'
$helper = [System.IO.Path]::GetFullPath($helper)
if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) {
    throw "Get-TradeableSymbolsFromScripts helper not found at: $helper"
}
. $helper

$unique = @(Get-TradeableSymbolsFromStrategyPath -StrategyPath $StrategyPath -FilePatterns $FilePatterns)

if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
    $dir = Split-Path -Path $OutFile -Parent
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    $unique -join [Environment]::NewLine | Out-File -LiteralPath $OutFile -Encoding utf8
}

return $unique
