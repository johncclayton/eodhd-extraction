param(
    [Parameter(Mandatory = $false)]
    [string]$InputFilePath = "",
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ""
)

if ([string]::IsNullOrWhiteSpace($InputFilePath)) {
    $scriptDirectory = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
    $InputFilePath = Join-Path $scriptDirectory "2026.02.25_European_Stocks.txt"
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $scriptDirectory = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
    $ConfigPath = Join-Path $scriptDirectory "eodhd-config.json"
}

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

function ConvertTo-NormalizedSymbol {
    param([Parameter(Mandatory = $true)][string]$Value)

    $upper = $Value.Trim().ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($upper)) {
        return ""
    }

    # Remove separator characters for tolerant matching.
    return ($upper -replace '[\s\.\-_/]', '')
}

function Get-SymbolCandidates {
    param([Parameter(Mandatory = $true)][string]$Symbol)

    $raw = $Symbol.Trim().ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    $candidates = @(
        $raw
        ($raw -replace '\s+', '')
        ($raw -replace '\s+', '-')
        ($raw -replace '\.', '')
        ($raw -replace '\.', '-')
        (ConvertTo-NormalizedSymbol -Value $raw)
    )

    return @(
        $candidates |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique
    )
}

function Add-ExchangeMatch {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Index,
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [string]$ExchangeCode
    )

    if ([string]::IsNullOrWhiteSpace($Key) -or [string]::IsNullOrWhiteSpace($ExchangeCode)) {
        return
    }

    if (-not $Index.ContainsKey($Key)) {
        $Index[$Key] = New-Object 'System.Collections.Generic.HashSet[string]'
    }

    [void]$Index[$Key].Add($ExchangeCode)
}

function Invoke-EodhdSymbolValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputFilePath,
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = "Stop"

    try {
        if (-not (Test-Path -LiteralPath $InputFilePath)) {
            Write-Error "Input file not found: $InputFilePath"
            return 1
        }
        if (-not (Test-Path -LiteralPath $ConfigPath)) {
            Write-Error "Config file not found: $ConfigPath"
            return 1
        }

        $configDirectory = Split-Path -Path $ConfigPath -Parent
        $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
        $outputDirectorySetting = [string]$config.outputDirectory
        if ([string]::IsNullOrWhiteSpace($outputDirectorySetting)) {
            $outputDirectorySetting = "./output"
        }
        $outputDirectory = Resolve-ConfigRelativePath -Path $outputDirectorySetting -ConfigDirectory $configDirectory

        if (-not (Test-Path -LiteralPath $outputDirectory)) {
            Write-Error "Output directory not found: $outputDirectory"
            return 1
        }

        $exchangePayloadFiles = @(Get-ChildItem -LiteralPath $outputDirectory -Filter "*-symbols-full.json" -File)
        if ($exchangePayloadFiles.Count -eq 0) {
            Write-Error "No '*-symbols-full.json' files found in output directory: $outputDirectory"
            return 1
        }

        $symbolToExchangesExact = @{}
        $symbolToExchangesNormalized = @{}

        foreach ($payloadFile in $exchangePayloadFiles) {
            $exchangeCode = [System.IO.Path]::GetFileNameWithoutExtension($payloadFile.Name) -replace '-symbols-full$', ''
            if ([string]::IsNullOrWhiteSpace($exchangeCode)) {
                continue
            }

            $rows = @()
            try {
                $rows = @(Get-Content -LiteralPath $payloadFile.FullName -Raw | ConvertFrom-Json)
            }
            catch {
                Write-Warning "Skipping unreadable payload file: $($payloadFile.FullName)"
                continue
            }

            foreach ($row in $rows) {
                $code = [string]$row.Code
                if ([string]::IsNullOrWhiteSpace($code)) {
                    continue
                }

                $exactKey = $code.Trim().ToUpperInvariant()
                $normalizedKey = ConvertTo-NormalizedSymbol -Value $code

                Add-ExchangeMatch -Index $symbolToExchangesExact -Key $exactKey -ExchangeCode $exchangeCode
                Add-ExchangeMatch -Index $symbolToExchangesNormalized -Key $normalizedKey -ExchangeCode $exchangeCode
            }
        }

        $sections = New-Object 'System.Collections.Generic.List[object]'
        $currentSectionHeader = $null
        $currentSymbols = $null
        $currentSeen = $null

        foreach ($rawLine in (Get-Content -LiteralPath $InputFilePath)) {
            $line = $rawLine.Trim()
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            $isSymbolLine = $line.Contains(',')
            if (-not $isSymbolLine) {
                if ($null -ne $currentSectionHeader) {
                    $sections.Add([pscustomobject]@{
                        Header = $currentSectionHeader
                        Symbols = @($currentSymbols)
                    })
                }

                $currentSectionHeader = $line
                $currentSymbols = New-Object 'System.Collections.Generic.List[string]'
                $currentSeen = New-Object 'System.Collections.Generic.HashSet[string]'
                continue
            }

            if ($null -eq $currentSectionHeader) {
                $currentSectionHeader = "Unsectioned"
                $currentSymbols = New-Object 'System.Collections.Generic.List[string]'
                $currentSeen = New-Object 'System.Collections.Generic.HashSet[string]'
            }

            foreach ($part in $line.Split(',')) {
                $symbol = $part.Trim()
                if ([string]::IsNullOrWhiteSpace($symbol)) {
                    continue
                }

                $dedupeKey = $symbol.ToUpperInvariant()
                if ($currentSeen.Add($dedupeKey)) {
                    $currentSymbols.Add($symbol)
                }
            }
        }

        if ($null -ne $currentSectionHeader) {
            $sections.Add([pscustomobject]@{
                Header = $currentSectionHeader
                Symbols = @($currentSymbols)
            })
        }

        if ($sections.Count -eq 0) {
            Write-Error "No sections parsed from input file: $InputFilePath"
            return 1
        }

        $outputLines = New-Object 'System.Collections.Generic.List[string]'
        $totalSymbols = 0
        $totalFound = 0
        $totalNotFound = 0

        foreach ($section in $sections) {
            $notFoundLines = New-Object 'System.Collections.Generic.List[string]'
            $foundLines = New-Object 'System.Collections.Generic.List[string]'

            foreach ($symbol in @($section.Symbols)) {
                $totalSymbols++
                $exchangeSet = New-Object 'System.Collections.Generic.HashSet[string]'

                foreach ($candidate in (Get-SymbolCandidates -Symbol $symbol)) {
                    if ($symbolToExchangesExact.ContainsKey($candidate)) {
                        foreach ($ex in $symbolToExchangesExact[$candidate]) {
                            [void]$exchangeSet.Add($ex)
                        }
                    }
                    if ($symbolToExchangesNormalized.ContainsKey($candidate)) {
                        foreach ($ex in $symbolToExchangesNormalized[$candidate]) {
                            [void]$exchangeSet.Add($ex)
                        }
                    }
                }

                $matchedExchanges = @($exchangeSet | Sort-Object)
                if ($matchedExchanges.Count -eq 0) {
                    $totalNotFound++
                    $notFoundLines.Add(("{0}, NOT_FOUND" -f $symbol))
                }
                else {
                    $totalFound++
                    $foundLines.Add(("{0}, {1}" -f $symbol, ($matchedExchanges -join ", ")))
                }
            }

            $outputLines.Add([string]$section.Header)
            foreach ($line in $notFoundLines) { $outputLines.Add($line) }
            foreach ($line in $foundLines) { $outputLines.Add($line) }
            $outputLines.Add("")
        }

        $inputDirectory = Split-Path -Path $InputFilePath -Parent
        $inputBaseName = [System.IO.Path]::GetFileNameWithoutExtension($InputFilePath)
        $validationOutputPath = Join-Path $inputDirectory ("{0}_validation.txt" -f $inputBaseName)

        [System.IO.File]::WriteAllLines($validationOutputPath, @($outputLines), [System.Text.Encoding]::UTF8)

        Write-Host "Validation output written to: $validationOutputPath"
        Write-Host ("Sections: {0} | Symbols: {1} | Found: {2} | Not found: {3}" -f $sections.Count, $totalSymbols, $totalFound, $totalNotFound)
        return 0
    }
    catch {
        Write-Error "Validation failed: $($_.Exception.Message)"
        return 1
    }
}

if ($MyInvocation.InvocationName -ne ".") {
    $exitCode = Invoke-EodhdSymbolValidation -InputFilePath $script:InputFilePath -ConfigPath $script:ConfigPath
    exit $exitCode
}
