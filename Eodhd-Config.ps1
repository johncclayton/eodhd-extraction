# Shared helpers: merge eodhd-config.json with optional .env / process-environment overrides.
# Precedence (lowest to highest): JSON file, then .env beside the config file, then process environment.
# Recognized override key forms per JSON property (first non-empty wins): EODHD_<SNAKE>, <SNAKE>, exact JSON name (case-insensitive).

function Get-EodhdDotEnvDictionary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DotEnvPath
    )

    $dict = @{}
    if (-not (Test-Path -LiteralPath $DotEnvPath)) {
        return $dict
    }

    foreach ($rawLine in (Get-Content -LiteralPath $DotEnvPath)) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
            continue
        }

        if ($line.StartsWith("export ")) {
            $line = $line.Substring(7).Trim()
        }

        $parts = $line.Split("=", 2)
        if ($parts.Count -ne 2) {
            continue
        }

        $name = $parts[0].Trim()
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        $value = $parts[1].Trim()
        if ($value.Length -ge 2) {
            $isDoubleQuoted = $value.StartsWith('"') -and $value.EndsWith('"')
            $isSingleQuoted = $value.StartsWith("'") -and $value.EndsWith("'")
            if ($isDoubleQuoted -or $isSingleQuoted) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }

        $dict[$name] = $value
    }

    return $dict
}

function ConvertTo-EodhdUpperSnakeCase {
    param([Parameter(Mandatory = $true)][string]$CamelCase)

    if ([string]::IsNullOrWhiteSpace($CamelCase)) {
        return ""
    }

    $withUnderscores = [regex]::Replace($CamelCase, '(?<=[a-z0-9])(?=[A-Z])', '_')
    return $withUnderscores.ToUpperInvariant()
}

function Get-EodhdConfigEnvOverrideRaw {
    param(
        [Parameter(Mandatory = $true)]
        [string]$JsonPropertyName,
        [Parameter(Mandatory = $true)]
        [hashtable]$DotEnvDict
    )

    $snake = ConvertTo-EodhdUpperSnakeCase -CamelCase $JsonPropertyName
    $candidates = @(
        if ($snake.Length -gt 0) { "EODHD_$snake" } else { $null }
        $snake
        $JsonPropertyName
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    foreach ($c in $candidates) {
        $v = [Environment]::GetEnvironmentVariable($c)
        if (-not [string]::IsNullOrWhiteSpace($v)) {
            return $v
        }
    }

    foreach ($c in $candidates) {
        foreach ($key in $DotEnvDict.Keys) {
            if ([string]::Equals($key, $c, [System.StringComparison]::OrdinalIgnoreCase)) {
                $v = [string]$DotEnvDict[$key]
                if (-not [string]::IsNullOrWhiteSpace($v)) {
                    return $v
                }
            }
        }
    }

    return $null
}

function ConvertFrom-EodhdEnvStringList {
    param([Parameter(Mandatory = $true)][string]$Raw)

    $t = $Raw.Trim()
    if ($t.Length -eq 0) {
        return @()
    }

    if ($t.StartsWith("[")) {
        try {
            $parsed = $t | ConvertFrom-Json
            return @(
                @($parsed) |
                ForEach-Object { [string]$_ } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                ForEach-Object { $_.Trim() }
            )
        }
        catch {
            throw "Invalid JSON array for list override: $($_.Exception.Message)"
        }
    }

    return @(
        $t.Split(",") |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Merge-EodhdConfigWithEnvOverrides {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Config,
        [Parameter(Mandatory = $true)]
        [string]$ConfigDirectory
    )

    $dotEnvPath = Join-Path $ConfigDirectory ".env"
    $dotEnvDict = Get-EodhdDotEnvDictionary -DotEnvPath $dotEnvPath

    foreach ($prop in @($Config.PSObject.Properties)) {
        $name = [string]$prop.Name
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        $raw = Get-EodhdConfigEnvOverrideRaw -JsonPropertyName $name -DotEnvDict $dotEnvDict
        if ($null -eq $raw -or [string]::IsNullOrWhiteSpace($raw)) {
            continue
        }

        switch -Wildcard ($name) {
            "requestTimeoutSeconds" {
                $parsed = 0
                if (-not [int]::TryParse($raw.Trim(), [ref]$parsed)) {
                    throw "requestTimeoutSeconds override must be an integer: $raw"
                }
                if ($parsed -le 0) {
                    throw "requestTimeoutSeconds override must be greater than zero."
                }
                $Config | Add-Member -NotePropertyName $name -NotePropertyValue $parsed -Force
            }
            "currencies" {
                $list = @(ConvertFrom-EodhdEnvStringList -Raw $raw | ForEach-Object { $_.ToUpperInvariant() } | Sort-Object -Unique)
                $Config | Add-Member -NotePropertyName $name -NotePropertyValue $list -Force
            }
            "countries" {
                $list = @(ConvertFrom-EodhdEnvStringList -Raw $raw | ForEach-Object { $_.ToUpperInvariant() } | Sort-Object -Unique)
                $Config | Add-Member -NotePropertyName $name -NotePropertyValue $list -Force
            }
            "exchanges" {
                try {
                    $parsed = $raw.Trim() | ConvertFrom-Json
                }
                catch {
                    throw "exchanges override must be valid JSON (same shape as in eodhd-config.json): $($_.Exception.Message)"
                }
                $Config | Add-Member -NotePropertyName $name -NotePropertyValue $parsed -Force
            }
            Default {
                $Config | Add-Member -NotePropertyName $name -NotePropertyValue $raw.Trim() -Force
            }
        }
    }

    return $Config
}

function Get-EodhdEffectiveConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Config file not found: $ConfigPath"
    }

    $configDirectory = Split-Path -Path $ConfigPath -Parent
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    return (Merge-EodhdConfigWithEnvOverrides -Config $config -ConfigDirectory $configDirectory)
}
