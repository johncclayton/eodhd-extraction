param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "",
    [Parameter(Mandatory = $false)]
    [switch]$ListExchanges,
    [Parameter(Mandatory = $false)]
    [switch]$AllExchanges
)

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $scriptDirectory = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
    $ConfigPath = Join-Path $scriptDirectory "eodhd-config.json"
}

function Get-EodhdAvailableExchanges {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ApiBaseUrl,
        [Parameter(Mandatory = $true)]
        [string]$ApiToken,
        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 60
    )

    $listUri = "{0}/exchanges-list/?api_token={1}&fmt=json" -f $ApiBaseUrl.TrimEnd('/'), $ApiToken
    $exchangeList = @(Invoke-RestMethod -Method Get -Uri $listUri -TimeoutSec $TimeoutSeconds)
    if (@($exchangeList).Count -eq 1 -and $exchangeList[0] -is [System.Array]) {
        $exchangeList = @($exchangeList[0])
    }

    if (@($exchangeList).Count -eq 0) {
        return @()
    }

    $normalizedExchanges = @()
    foreach ($item in $exchangeList) {
        $propertyNames = @(
            $item.PSObject.Properties |
            ForEach-Object { $_.Name }
        )

        if (@($propertyNames).Count -eq 0) {
            continue
        }

        $propertyDefinitions = @()
        $maxCount = 1

        foreach ($propertyName in $propertyNames) {
            $propertyValue = $item.$propertyName
            $isArrayValue = $propertyValue -is [System.Array]
            $values = if ($isArrayValue) { @($propertyValue) } else { @($propertyValue) }

            if (@($values).Count -gt $maxCount) {
                $maxCount = @($values).Count
            }

            $propertyDefinitions += [pscustomobject]@{
                Name = $propertyName
                Values = $values
                RepeatSingleValue = -not $isArrayValue
            }
        }

        for ($i = 0; $i -lt $maxCount; $i++) {
            $normalizedExchange = [ordered]@{}

            foreach ($propertyDefinition in $propertyDefinitions) {
                $values = @($propertyDefinition.Values)
                $value = $null

                if ($i -lt @($values).Count) {
                    $value = $values[$i]
                }
                elseif ($propertyDefinition.RepeatSingleValue -and @($values).Count -eq 1) {
                    $value = $values[0]
                }

                $normalizedExchange[$propertyDefinition.Name] = if ($null -ne $value) { [string]$value } else { "" }
            }

            $normalizedExchanges += [pscustomobject]$normalizedExchange
        }
    }

    return ($normalizedExchanges | Sort-Object -Property Code)
}

function Write-EodhdAvailableExchanges {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ApiBaseUrl,
        [Parameter(Mandatory = $true)]
        [string]$ApiToken,
        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 60
    )

    $exchanges = @(Get-EodhdAvailableExchanges -ApiBaseUrl $ApiBaseUrl -ApiToken $ApiToken -TimeoutSeconds $TimeoutSeconds)
    if ($exchanges.Count -eq 0) {
        Write-Warning "No exchanges returned by EODHD."
        return
    }

    $preferredPropertyOrder = @(
        "Code",
        "Name",
        "Country",
        "Currency",
        "CountryISO2",
        "CountryISO3",
        "OperatingMIC"
    )

    $availablePropertyNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($exchange in $exchanges) {
        foreach ($property in $exchange.PSObject.Properties) {
            [void]$availablePropertyNames.Add($property.Name)
        }
    }

    $propertyNames = [System.Collections.Generic.List[string]]::new()
    foreach ($propertyName in $preferredPropertyOrder) {
        if ($availablePropertyNames.Contains($propertyName)) {
            $propertyNames.Add($propertyName)
        }
    }

    foreach ($propertyName in $availablePropertyNames) {
        if (-not $propertyNames.Contains($propertyName)) {
            $propertyNames.Add($propertyName)
        }
    }

    # Header plus one exchange per line for predictable CLI output.
    Write-Host ($propertyNames -join " | ")

    $exchanges | ForEach-Object {
        $values = foreach ($propertyName in $propertyNames) {
            [string]$_.($propertyName)
        }

        Write-Host ($values -join " | ")
    }
}

function Invoke-EodhdSymbolExport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ConfigPath = (Join-Path $PSScriptRoot "eodhd-config.json"),
        [Parameter(Mandatory = $false)]
        [switch]$ListExchanges,
        [Parameter(Mandatory = $false)]
        [switch]$AllExchanges
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = "Stop"

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

    function New-DirectoryIfMissing {
        param([Parameter(Mandatory = $true)][string]$Path)
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -Path $Path -ItemType Directory -Force | Out-Null
        }
    }

    function Get-DotEnvValue {
        param(
            [Parameter(Mandatory = $true)]
            [string]$DotEnvPath,
            [Parameter(Mandatory = $true)]
            [string]$Key
        )

        if (-not (Test-Path -LiteralPath $DotEnvPath)) {
            return $null
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
            if ($name -ne $Key) {
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

            return $value
        }

        return $null
    }

    try {
        if (-not (Test-Path -LiteralPath $ConfigPath)) {
            Write-Error "Config file not found: $ConfigPath"
            return 1
        }

        $configDirectory = Split-Path -Path $ConfigPath -Parent
        $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

        $apiBaseUrl = [string]$config.apiBaseUrl
        if ([string]::IsNullOrWhiteSpace($apiBaseUrl)) {
            Write-Error "Missing config value: apiBaseUrl"
            return 1
        }

        $requestTimeoutSeconds = 60
        if ($null -ne $config.requestTimeoutSeconds -and [int]$config.requestTimeoutSeconds -gt 0) {
            $requestTimeoutSeconds = [int]$config.requestTimeoutSeconds
        }

        $envVarName = "EODHD_API_TOKEN"

        $dotEnvPath = Resolve-ConfigRelativePath -Path ".env" -ConfigDirectory $configDirectory

        $tokenSource = ""
        $token = Get-DotEnvValue -DotEnvPath $dotEnvPath -Key "EODHD_API_TOKEN"
        if (-not [string]::IsNullOrWhiteSpace($token)) {
            $tokenSource = "dotenv"
        }

        if ([string]::IsNullOrWhiteSpace($token)) {
            $token = [Environment]::GetEnvironmentVariable($envVarName)
            if (-not [string]::IsNullOrWhiteSpace($token)) {
                $tokenSource = "environment"
            }
        }

        if ([string]::IsNullOrWhiteSpace($token)) {
            Write-Error "Missing API token. Provide EODHD_API_TOKEN in .env or set EODHD_API_TOKEN in environment."
            return 1
        }

        if ($ListExchanges) {
            Write-EodhdAvailableExchanges -ApiBaseUrl $apiBaseUrl -ApiToken $token -TimeoutSeconds $requestTimeoutSeconds
            return 0
        }

        $configuredExchangeCodes = @()
        $configuredCurrencies = @(
            @($config.currencies) |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim().ToUpperInvariant() } |
            Sort-Object -Unique
        )
        $configuredCountries = @(
            @($config.countries) |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim().ToUpperInvariant() } |
            Sort-Object -Unique
        )

        if ($AllExchanges) {
            $availableExchanges = @(Get-EodhdAvailableExchanges -ApiBaseUrl $apiBaseUrl -ApiToken $token -TimeoutSeconds $requestTimeoutSeconds)
            $configuredExchangeCodes = @(
                $availableExchanges |
                ForEach-Object { [string]$_.Code } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                ForEach-Object { $_.Trim() } |
                Sort-Object -Unique
            )
        }
        elseif ($configuredCurrencies.Count -gt 0 -or $configuredCountries.Count -gt 0) {
            $availableExchanges = @(Get-EodhdAvailableExchanges -ApiBaseUrl $apiBaseUrl -ApiToken $token -TimeoutSeconds $requestTimeoutSeconds)
            $selectedCurrencyExchanges = @(
                $availableExchanges |
                Where-Object {
                    $exchangeCurrency = [string]$_.Currency
                    $exchangeCountry = [string]$_.Country

                    $matchesCurrency = $false
                    if ($configuredCurrencies.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($exchangeCurrency)) {
                        $matchesCurrency = $configuredCurrencies -contains $exchangeCurrency.Trim().ToUpperInvariant()
                    }

                    $matchesCountry = $false
                    if ($configuredCountries.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($exchangeCountry)) {
                        $matchesCountry = $configuredCountries -contains $exchangeCountry.Trim().ToUpperInvariant()
                    }

                    $matchesCurrency -or $matchesCountry
                }
            )

            $configuredExchangeCodes = @(
                $selectedCurrencyExchanges |
                ForEach-Object { [string]$_.Code } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                ForEach-Object { $_.Trim() } |
                Sort-Object -Unique
            )

            if ($configuredExchangeCodes.Count -eq 0) {
                $currenciesText = if ($configuredCurrencies.Count -gt 0) { $configuredCurrencies -join ', ' } else { '(none)' }
                $countriesText = if ($configuredCountries.Count -gt 0) { $configuredCountries -join ', ' } else { '(none)' }
                Write-Error "No exchanges matched config selectors. currencies: $currenciesText ; countries: $countriesText"
                return 1
            }
        }
        else {
            foreach ($exchange in @($config.exchanges)) {
                if ($null -eq $exchange) {
                    continue
                }

                $codeValue = $exchange.code
                if ($codeValue -is [System.Array]) {
                    foreach ($codeItem in @($codeValue)) {
                        $code = [string]$codeItem
                        if (-not [string]::IsNullOrWhiteSpace($code)) {
                            $configuredExchangeCodes += $code.Trim()
                        }
                    }
                }
                else {
                    $code = [string]$codeValue
                    if (-not [string]::IsNullOrWhiteSpace($code)) {
                        $configuredExchangeCodes += $code.Trim()
                    }
                }
            }
        }

        $configuredExchangeCodes = @($configuredExchangeCodes | Sort-Object -Unique)
        if ($configuredExchangeCodes.Count -eq 0) {
            Write-Error "No exchange codes found in config.exchanges."
            return 1
        }

        $symbolFormat = [string]$config.symbolFormat
        if ([string]::IsNullOrWhiteSpace($symbolFormat)) {
            $symbolFormat = "{Code}.{ExchangeCode}"
        }

        $outputDirectory = Resolve-ConfigRelativePath -Path ([string]$config.outputDirectory) -ConfigDirectory $configDirectory
        $logsDirectory = Resolve-ConfigRelativePath -Path ([string]$config.logsDirectory) -ConfigDirectory $configDirectory
        $runHealthFileName = [string]$config.runHealthFileName
        $runHealthSummaryFileName = [string]$config.runHealthSummaryFileName

        if ([string]::IsNullOrWhiteSpace($runHealthFileName)) { $runHealthFileName = "last-run.json" }
        if ([string]::IsNullOrWhiteSpace($runHealthSummaryFileName)) { $runHealthSummaryFileName = "run-health-summary.csv" }

        New-DirectoryIfMissing -Path $outputDirectory
        New-DirectoryIfMissing -Path $logsDirectory

        $timestampUtc = (Get-Date).ToUniversalTime()
        $timestampIso = $timestampUtc.ToString("o")
        $logFile = Join-Path $logsDirectory ("eodhd-export-{0}.log" -f $timestampUtc.ToString("yyyyMMdd-HHmmss"))

        "[$timestampIso] Starting EODHD symbol export" | Out-File -LiteralPath $logFile -Encoding utf8
        "[$timestampIso] Token source: $tokenSource" | Add-Content -LiteralPath $logFile

        $exchangeResults = @()
        $anyExchangePullFailed = $false
        $outputWriteFailed = $false

        foreach ($exchangeCode in $configuredExchangeCodes) {
            $result = [ordered]@{
                exchangeCode       = $exchangeCode
                status             = "Succeeded"
                totalSymbols       = 0
                filteredSymbols    = 0
                outputSymbolsOnlyFile = ""
                outputPayloadFile  = ""
                outputSymbolInfoFile = ""
                errorMessage       = ""
            }

            try {
                $uri = "{0}/exchange-symbol-list/{1}?api_token={2}&fmt=json" -f $apiBaseUrl.TrimEnd('/'), $exchangeCode, $token
                "[$((Get-Date).ToUniversalTime().ToString("o"))] Pulling exchange $exchangeCode from $apiBaseUrl" | Add-Content -LiteralPath $logFile

                $payload = Invoke-RestMethod -Method Get -Uri $uri -TimeoutSec $requestTimeoutSeconds
                $rows = @($payload)
                $result.totalSymbols = $rows.Count

                $result.filteredSymbols = $rows.Count

                $symbols = @(
                    $rows |
                    ForEach-Object {
                        if ([string]::IsNullOrWhiteSpace([string]$_.Code)) { return }
                        $symbolFormat.Replace("{Code}", [string]$_.Code).Replace("{ExchangeCode}", $exchangeCode)
                    } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    Sort-Object -Unique
                )

                $symbolsFile = Join-Path $outputDirectory ("{0}-symbols-rt.txt" -f $exchangeCode)
                $payloadFile = Join-Path $outputDirectory ("{0}-symbols-full.json" -f $exchangeCode)
                $symbolInfoFile = Join-Path $outputDirectory ("{0}-syminfo-rt.csv" -f $exchangeCode)

                $symbolInfoRows = @(
                    $rows |
                    ForEach-Object {
                        $code = [string]$_.Code
                        $symbolValue = $code

                        if ([string]::IsNullOrWhiteSpace($symbolValue)) {
                            $symbolValue = $symbolFormat.Replace("{Code}", $code).Replace("{ExchangeCode}", $exchangeCode)
                        }

                        if (-not [string]::IsNullOrWhiteSpace($symbolValue)) {
                            $exchangeSuffixPattern = "\.{0}$" -f [Regex]::Escape($exchangeCode)
                            $symbolValue = [Regex]::Replace($symbolValue, $exchangeSuffixPattern, "", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                        }

                        [pscustomobject]@{
                            Symbol = $symbolValue
                            Exchange = $exchangeCode
                            Name = [string]$_.Name
                            Currency = [string]$_.Currency
                        }
                    } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_.Symbol) } |
                    Sort-Object -Property Symbol -Unique
                )

                try {
                    $symbols -join [Environment]::NewLine | Out-File -LiteralPath $symbolsFile -Encoding utf8
                    $rows | ConvertTo-Json -Depth 12 | Out-File -LiteralPath $payloadFile -Encoding utf8
                    $symbolInfoRows | Export-Csv -LiteralPath $symbolInfoFile -NoTypeInformation -Encoding utf8
                }
                catch {
                    $outputWriteFailed = $true
                    throw
                }

                $result.outputSymbolsOnlyFile = $symbolsFile
                $result.outputPayloadFile = $payloadFile
                $result.outputSymbolInfoFile = $symbolInfoFile
            }
            catch {
                $anyExchangePullFailed = $true
                $result.status = "Failed"
                $result.errorMessage = $_.Exception.Message
                "[$((Get-Date).ToUniversalTime().ToString("o"))] Exchange $exchangeCode failed: $($result.errorMessage)" | Add-Content -LiteralPath $logFile
            }

            $exchangeResults += [pscustomobject]$result
        }

        $summary = [ordered]@{
            timestampUtc          = $timestampIso
            configPath            = (Resolve-Path -LiteralPath $ConfigPath).Path
            outputDirectory       = $outputDirectory
            exchangesRequested    = $configuredExchangeCodes.Count
            exchangesSucceeded    = (@($exchangeResults | Where-Object { $_.status -eq "Succeeded" })).Count
            exchangesFailed       = (@($exchangeResults | Where-Object { $_.status -eq "Failed" })).Count
            totalSymbolsFiltered  = [int](@($exchangeResults | Measure-Object -Property filteredSymbols -Sum).Sum)
            anyExchangePullFailed = $anyExchangePullFailed
            outputWriteFailed     = $outputWriteFailed
        }

        $lastRunPath = Join-Path $outputDirectory $runHealthFileName
        $summaryCsvPath = Join-Path $outputDirectory $runHealthSummaryFileName

        [pscustomobject]@{
            run = [pscustomobject]$summary
            exchanges = $exchangeResults
        } | ConvertTo-Json -Depth 12 | Out-File -LiteralPath $lastRunPath -Encoding utf8

        [pscustomobject]$summary | Export-Csv -LiteralPath $summaryCsvPath -NoTypeInformation -Encoding utf8

        "[$((Get-Date).ToUniversalTime().ToString("o"))] Export complete. Failed exchanges: $($summary.exchangesFailed)" | Add-Content -LiteralPath $logFile

        if ($summary.exchangesFailed -gt 0 -or $summary.outputWriteFailed) {
            return 1
        }

        return 0
    }
    catch {
        Write-Error "Unexpected exporter failure: $($_.Exception.Message)"
        return 1
    }
}

if ($MyInvocation.InvocationName -ne ".") {
    $exitCode = Invoke-EodhdSymbolExport -ConfigPath $script:ConfigPath -ListExchanges:$ListExchanges -AllExchanges:$AllExchanges
    exit $exitCode
}
