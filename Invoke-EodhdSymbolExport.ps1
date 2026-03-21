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

$script:EodhdRepoRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent

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

    $exchanges | Select-Object -Property $propertyNames
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

    function ConvertTo-NormalizedExchangeMappingValue {
        param([AllowNull()][string]$Value)

        if ([string]::IsNullOrWhiteSpace($Value)) {
            return ""
        }

        return $Value.Trim().ToUpperInvariant()
    }

    function Get-OrderClerkExchangeMappings {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [string]$CsvPath
        )

        if (-not (Test-Path -LiteralPath $CsvPath)) {
            throw "OrderClerk exchange mapping file not found: $CsvPath"
        }

        $rows = @(Import-Csv -LiteralPath $CsvPath)
        if ($rows.Count -eq 0) {
            return @()
        }

        $mappings = @()
        foreach ($row in $rows) {
            $columnValues = @(
                $row.PSObject.Properties |
                ForEach-Object { [string]$_.Value }
            )

            if ($columnValues.Count -lt 3) {
                throw "OrderClerk exchange mapping file must contain at least three columns: $CsvPath"
            }

            $exchangeCode = [string]$columnValues[0]
            $country = [string]$columnValues[2]
            if ([string]::IsNullOrWhiteSpace($exchangeCode) -or [string]::IsNullOrWhiteSpace($country)) {
                continue
            }

            $mappings += [pscustomobject]@{
                ExchangeCode = $exchangeCode.Trim()
                Country = $country.Trim()
                NormalizedCountry = (ConvertTo-NormalizedExchangeMappingValue -Value $country)
            }
        }

        return $mappings
    }

    function Get-OrderClerkExchangesInstallLooksNewerMessage {
        param(
            [Parameter(Mandatory = $true)]
            [string]$BundledPath
        )

        $installPath = "C:\OrderClerk\OrderClerkExchanges.csv"
        if (-not (Test-Path -LiteralPath $installPath)) {
            return $null
        }

        if (-not (Test-Path -LiteralPath $BundledPath)) {
            return $null
        }

        try {
            $installItem = Get-Item -LiteralPath $installPath
            $bundledItem = Get-Item -LiteralPath $BundledPath
            $installLineCount = [System.IO.File]::ReadAllLines($installPath).Length
            $bundledLineCount = [System.IO.File]::ReadAllLines($BundledPath).Length
            $moreRows = $installLineCount -gt $bundledLineCount
            $moreBytes = $installItem.Length -gt $bundledItem.Length
            if ($moreRows -or $moreBytes) {
                return "OrderClerkExchanges.csv file in the C:\OrderClerk folder seems to be more up to date!"
            }
        }
        catch {
            return $null
        }

        return $null
    }

    function Get-ExchangeCountryIso2 {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [psobject]$Exchange
        )

        return [string]$Exchange.CountryISO2
    }

    function Format-EodhdExchangeDiagnostics {
        param([Parameter(Mandatory = $true)][psobject]$Exchange)

        $orderedKeys = @(
            "Name",
            "Country",
            "Currency",
            "CountryISO2",
            "CountryISO3",
            "OperatingMIC"
        )

        $parts = New-Object 'System.Collections.Generic.List[string]'
        foreach ($key in $orderedKeys) {
            $prop = $Exchange.PSObject.Properties[$key]
            if ($null -eq $prop) {
                continue
            }

            $val = [string]$prop.Value
            if ([string]::IsNullOrWhiteSpace($val)) {
                continue
            }

            [void]$parts.Add(("{0}={1}" -f $key, $val.Trim()))
        }

        $skip = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        [void]$skip.Add("Code")
        foreach ($p in $parts) {
            [void]$skip.Add(($p -split '=', 2)[0])
        }

        foreach ($prop in $Exchange.PSObject.Properties) {
            if ([string]::IsNullOrWhiteSpace($prop.Name) -or $skip.Contains($prop.Name)) {
                continue
            }

            $val = [string]$prop.Value
            if ([string]::IsNullOrWhiteSpace($val)) {
                continue
            }

            if ($val.Length -gt 120) {
                continue
            }

            [void]$skip.Add($prop.Name)
            [void]$parts.Add(("{0}={1}" -f $prop.Name, $val.Trim()))
            if ($parts.Count -ge 14) {
                break
            }
        }

        if ($parts.Count -eq 0) {
            return "No extra metadata fields on this EODHD exchange row (only Code is populated)."
        }

        return ($parts -join "; ")
    }

    function Resolve-OrderClerkExchangeCode {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [string]$ExchangeCode,
            [Parameter(Mandatory = $true)]
            [psobject[]]$AvailableExchanges,
            [Parameter(Mandatory = $true)]
            [hashtable]$OrderClerkMappingsByCountry,
            [Parameter(Mandatory = $true)]
            [string]$LogFile
        )

        $exchangeMetadata = @(
            $AvailableExchanges |
            Where-Object { [string]$_.Code -eq $ExchangeCode }
        )

        if ($exchangeMetadata.Count -eq 0) {
            throw "Unable to resolve EODHD exchange metadata for exchange '$ExchangeCode'."
        }

        $exchange = $exchangeMetadata[0]
        $exchangeContext = Format-EodhdExchangeDiagnostics -Exchange $exchange
        $countryIso2 = [string](Get-ExchangeCountryIso2 -Exchange $exchange)
        if ([string]::IsNullOrWhiteSpace($countryIso2)) {
            $warningMessage = @"
No CountryISO2 value found for EODHD exchange '$ExchangeCode'. Using EODHD exchange code.
EODHD listing for this exchange: $exchangeContext
OrderClerk mapping uses CountryISO2 (CSV column 3); if it is missing here, map manually or fix EODHD data for this exchange row.
"@
            Write-Warning $warningMessage
            foreach ($warningLine in ($warningMessage -split "`r?`n")) {
                if (-not [string]::IsNullOrWhiteSpace($warningLine)) {
                    "[$((Get-Date).ToUniversalTime().ToString("o"))] WARNING: $warningLine" | Add-Content -LiteralPath $LogFile
                }
            }
            return $ExchangeCode
        }

        $normalizedCountryIso2 = ConvertTo-NormalizedExchangeMappingValue -Value $countryIso2
        if ($OrderClerkMappingsByCountry.ContainsKey($normalizedCountryIso2)) {
            return [string]$OrderClerkMappingsByCountry[$normalizedCountryIso2].ExchangeCode
        }

        $warningMessage = @"
No OrderClerk exchange mapping found for EODHD exchange '$ExchangeCode' CountryISO2 '$countryIso2'. Using EODHD exchange code.
EODHD listing for this exchange: $exchangeContext
Add or fix a row in fallback\OrderClerkExchanges.csv (column 3 country ISO2 must match this listing) if you need a different OrderClerk exchange code.
"@
        Write-Warning $warningMessage
        foreach ($warningLine in ($warningMessage -split "`r?`n")) {
            if (-not [string]::IsNullOrWhiteSpace($warningLine)) {
                "[$((Get-Date).ToUniversalTime().ToString("o"))] WARNING: $warningLine" | Add-Content -LiteralPath $LogFile
            }
        }
        return $ExchangeCode
    }

    function Format-SymInfoCsvField {
        param(
            [Parameter(Mandatory = $false)]
            [AllowEmptyString()]
            [string]$Value
        )

        if ($null -eq $Value) {
            return ""
        }

        $s = $Value.Trim()
        if ($s.Length -eq 0) {
            return ""
        }

        # UTF-8 en dash (E2 80 93) misread as Windows-1252, then stored as UTF-8 → literal U+00E2 U+20AC U+201C.
        $mojibakeEnDash = ([string][char]0x00E2) + ([string][char]0x20AC) + ([string][char]0x201C)
        $s = $s.Replace($mojibakeEnDash, "-")

        # Control characters (incl. NUL, CR, LF, TAB) → space; format chars (zero-width, BOM, etc.) removed.
        $s = [regex]::Replace($s, '\p{Cc}+', ' ')
        $s = [regex]::Replace($s, '\p{Cf}+', '')

        # Common “smart” punctuation → ASCII so legacy tools and single-byte parsers behave.
        $s = $s.Replace([char]0x2018, "'").Replace([char]0x2019, "'").Replace([char]0x201A, "'").Replace([char]0x201B, "'")
        $s = $s.Replace([char]0x201C, ' ').Replace([char]0x201D, ' ').Replace([char]0x201E, ' ').Replace([char]0x201F, ' ')
        $s = $s.Replace([char]0x2032, "'").Replace([char]0x2033, "'")
        $s = $s.Replace([char]0x2013, '-').Replace([char]0x2014, '-').Replace([char]0x2212, '-')
        # Use string overload; Replace(char,'...') binds to Replace(char,char) in PowerShell and throws.
        $s = $s.Replace([string][char]0x2026, '...')
        $s = $s.Replace([char]0x00AB, "'").Replace([char]0x00BB, "'")

        # Characters that confuse naive CSV / line parsers even when Export-Csv quotes fields.
        $s = $s.Replace('"', '')
        $s = $s.Replace(',', ' ')
        $s = $s.Replace(';', ' ')
        $s = $s.Replace([char]0x2028, ' ').Replace([char]0x2029, ' ')

        $s = $s -replace '\s+', ' '
        return $s.Trim()
    }

    try {
        if (-not (Test-Path -LiteralPath $ConfigPath)) {
            throw "Config file not found: $ConfigPath"
        }

        $configDirectory = Split-Path -Path $ConfigPath -Parent
        . (Join-Path $script:EodhdRepoRoot "Eodhd-Config.ps1")
        $config = Get-EodhdEffectiveConfig -ConfigPath $ConfigPath

        $apiBaseUrl = [string]$config.apiBaseUrl
        if ([string]::IsNullOrWhiteSpace($apiBaseUrl)) {
            throw "Missing config value: apiBaseUrl"
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
            throw "Missing API token. Provide EODHD_API_TOKEN in .env or set EODHD_API_TOKEN in environment."
        }

        if ($ListExchanges) {
            Write-EodhdAvailableExchanges -ApiBaseUrl $apiBaseUrl -ApiToken $token -TimeoutSeconds $requestTimeoutSeconds
            return
        }

        $availableExchanges = @()
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
                throw "No exchanges matched config selectors. currencies: $currenciesText ; countries: $countriesText"
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
            throw "No exchange codes found in config.exchanges."
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
        $orderClerkExchangeCsvPath = Join-Path $PSScriptRoot "fallback\OrderClerkExchanges.csv"

        "[$timestampIso] Starting EODHD symbol export" | Out-File -LiteralPath $logFile -Encoding utf8
        "[$timestampIso] Token source: $tokenSource" | Add-Content -LiteralPath $logFile

        if ($availableExchanges.Count -eq 0) {
            $availableExchanges = @(Get-EodhdAvailableExchanges -ApiBaseUrl $apiBaseUrl -ApiToken $token -TimeoutSeconds $requestTimeoutSeconds)
        }

        "[$((Get-Date).ToUniversalTime().ToString("o"))] Using OrderClerk exchange mapping file: $orderClerkExchangeCsvPath" | Add-Content -LiteralPath $logFile

        $orderClerkMappings = @(Get-OrderClerkExchangeMappings -CsvPath $orderClerkExchangeCsvPath)
        $orderClerkMappingsByCountry = @{}
        foreach ($mapping in $orderClerkMappings) {
            $normalizedCountry = [string]$mapping.NormalizedCountry
            if ([string]::IsNullOrWhiteSpace($normalizedCountry)) {
                continue
            }

            if (-not $orderClerkMappingsByCountry.ContainsKey($normalizedCountry)) {
                # Keep the first row found in fallback\OrderClerkExchanges.csv for each country.
                $orderClerkMappingsByCountry[$normalizedCountry] = $mapping
            }
        }

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
                $mappedExchangeCode = Resolve-OrderClerkExchangeCode -ExchangeCode $exchangeCode -AvailableExchanges $availableExchanges -OrderClerkMappingsByCountry $orderClerkMappingsByCountry -LogFile $logFile

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
                            Symbol = (Format-SymInfoCsvField -Value $symbolValue)
                            Exchange = (Format-SymInfoCsvField -Value $mappedExchangeCode)
                            Name = (Format-SymInfoCsvField -Value ([string]$_.Name))
                            Currency = (Format-SymInfoCsvField -Value ([string]$_.Currency))
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

        $orderClerkFreshnessWarning = Get-OrderClerkExchangesInstallLooksNewerMessage -BundledPath $orderClerkExchangeCsvPath
        if ($null -ne $orderClerkFreshnessWarning) {
            $warnLine = "WARNING: $orderClerkFreshnessWarning"
            "[$((Get-Date).ToUniversalTime().ToString("o"))] $warnLine" | Add-Content -LiteralPath $logFile
            Write-Warning $orderClerkFreshnessWarning
        }

        if ($summary.exchangesFailed -gt 0 -or $summary.outputWriteFailed) {
            throw "Export completed with failures. Review log file: $logFile"
        }
    }
    catch {
        throw
    }
}

if ($MyInvocation.InvocationName -ne ".") {
    try {
        Invoke-EodhdSymbolExport -ConfigPath $script:ConfigPath -ListExchanges:$ListExchanges -AllExchanges:$AllExchanges
        exit 0
    }
    catch {
        Write-Error -Message $_.Exception.Message
        exit 1
    }
}
