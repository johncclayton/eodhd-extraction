param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = (Join-Path $PSScriptRoot "eodhd-config.json")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Eodhd-Config.ps1")

function Resolve-ConfigRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$ConfigDirectory
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return (Join-Path $ConfigDirectory $Path)
}

function Get-LogsDirectory {
    param([Parameter(Mandatory = $true)][string]$EffectiveConfigPath)

    if (-not (Test-Path -LiteralPath $EffectiveConfigPath)) {
        return (Join-Path $PSScriptRoot "logs")
    }

    try {
        $cfgDir = Split-Path -Path $EffectiveConfigPath -Parent
        $cfg = Get-EodhdEffectiveConfig -ConfigPath $EffectiveConfigPath
        $logsDir = Resolve-ConfigRelativePath -Path ([string]$cfg.logsDirectory) -ConfigDirectory $cfgDir
        if ([string]::IsNullOrWhiteSpace($logsDir)) {
            return (Join-Path $PSScriptRoot "logs")
        }
        return $logsDir
    }
    catch {
        return (Join-Path $PSScriptRoot "logs")
    }
}

$logsDirectory = Get-LogsDirectory -EffectiveConfigPath $ConfigPath
if (-not (Test-Path -LiteralPath $logsDirectory)) {
    New-Item -Path $logsDirectory -ItemType Directory -Force | Out-Null
}

$transcriptPath = Join-Path $logsDirectory ("eodhd-run-{0}.transcript.log" -f (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss"))
$exitCode = 1

try {
    Start-Transcript -Path $transcriptPath -Force | Out-Null

    . (Join-Path $PSScriptRoot "Invoke-EodhdSymbolExport.ps1")
    $exitCode = Invoke-EodhdSymbolExport -ConfigPath $ConfigPath
}
catch {
    Write-Error "Run-EodhdSnapshot failed: $($_.Exception.Message)"
    $exitCode = 1
}
finally {
    try {
        Stop-Transcript | Out-Null
    }
    catch {
        # no-op
    }
}

exit $exitCode
