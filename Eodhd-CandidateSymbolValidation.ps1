param(
    <#
    Optional shorthand (position 0): folder containing candidate_input.txt, or path to candidate_input.txt / another input file.
    Do not combine with -InputFilePath or -Folder.
    #>
    [Parameter(Mandatory = $false, Position = 0)]
    [string]$Path = "",

    [Parameter(Mandatory = $false)]
    [string]$InputFilePath = "",

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "",

    [Parameter(Mandatory = $false)]
    [string]$AnalysisDirectory = "",

    <#
    Points at an analysis folder that contains candidate_input.txt.
    Sets input to <Folder>\candidate_input.txt and AnalysisDirectory to the resolved folder.
    Do not combine with -InputFilePath, -Path, or a different -AnalysisDirectory.
    #>
    [Parameter(Mandatory = $false)]
    [string]$Folder = "",

    [Parameter(Mandatory = $false)]
    [string]$PreferredExchangeCode = "SW",

    [Parameter(Mandatory = $false)]
    [switch]$SkipHistoryDownload,

    [Parameter(Mandatory = $false)]
    [switch]$ProfileTimings
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:EodhdRepoRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent

. (Join-Path $script:EodhdRepoRoot "Eodhd-Config.ps1")

function Get-ParsedCandidateHeader {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Line
    )

    $result = [pscustomobject]@{
        Valid            = $false
        Description      = ""
        SleeveName       = ""
        RequiredCurrency = ""
    }

    $match = [regex]::Match($Line.Trim(), '^(.+)\s\(([^,]+),\s*([^)]+)\):\s*$')
    if (-not $match.Success) {
        return $result
    }

    $result.Valid = $true
    $result.Description = $match.Groups[1].Value.Trim()
    $result.SleeveName = $match.Groups[2].Value.Trim()
    $result.RequiredCurrency = $match.Groups[3].Value.Trim().ToUpperInvariant()
    return $result
}

function ConvertTo-NormalizedCandidateSymbol {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $upper = $Value.Trim().ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($upper)) {
        return ""
    }

    return ($upper -replace '[\s\.\-_/]', '')
}

function Get-SymbolLookupKeys {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Symbol
    )

    $raw = $Symbol.Trim().ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    return @(
        $raw
        ($raw -replace '\s+', '')
        ($raw -replace '\s+', '-')
        ($raw -replace '\.', '')
        ($raw -replace '\.', '-')
        (ConvertTo-NormalizedCandidateSymbol -Value $raw)
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
}

# EODHD-style TICKER.EXCHANGE in candidate files (e.g. ALC.SW). Exchange suffix must be 2+ chars so BRK.B stays one symbol.
function Get-ListingLookupSymbolAndExchange {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CandidateSymbol
    )

    $trim = $CandidateSymbol.Trim().ToUpperInvariant()
    $result = [pscustomobject]@{
        LookupSymbol     = $trim
        RequestedExchange = ""
    }
    if ($trim -match '^(.+)\.([A-Z][A-Z0-9]{1,5})$') {
        $base = $matches[1].Trim()
        $exch = $matches[2].Trim()
        if ($exch.Length -ge 2 -and -not [string]::IsNullOrWhiteSpace($base)) {
            $result.LookupSymbol = $base
            $result.RequestedExchange = $exch
        }
    }
    return $result
}

function Test-RequiredCurrencyMatches {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Expected,
        [Parameter(Mandatory = $true)]
        [string]$Actual
    )

    if ($Expected -eq $Actual) {
        return $true
    }

    if (($Expected -eq "GBP" -and $Actual -eq "GBX") -or ($Expected -eq "GBX" -and $Actual -eq "GBP")) {
        return $true
    }

    return $false
}

function Resolve-CandidatePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RawInputFilePath
    )

    if (-not [string]::IsNullOrWhiteSpace($RawInputFilePath)) {
        return [System.IO.Path]::GetFullPath($RawInputFilePath)
    }

    return (Join-Path $script:EodhdRepoRoot "analysis\candidate-symbol-validation\sample-vz-idea\candidate_input.txt")
}

function Resolve-AnalysisPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResolvedInputFilePath,
        [Parameter(Mandatory = $true)]
        [string]$RawAnalysisDirectory
    )

    if (-not [string]::IsNullOrWhiteSpace($RawAnalysisDirectory)) {
        return [System.IO.Path]::GetFullPath($RawAnalysisDirectory)
    }

    $inputDirectory = Split-Path -Path $ResolvedInputFilePath -Parent
    if ([string]::IsNullOrWhiteSpace($inputDirectory)) {
        return $script:EodhdRepoRoot
    }

    return $inputDirectory
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

function Get-CandidateSections {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath
    )

    $sections = @()
    $currentHeader = $null
    $currentSymbols = @()
    $currentSeen = @{}

    foreach ($rawLine in (Get-Content -LiteralPath $InputPath)) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        if ($line.StartsWith("#") -or $line.StartsWith("//")) {
            continue
        }

        $isSectionHeader = [regex]::IsMatch($line, '^(.+)\s\(([^)]+)\):\s*$')

        if ($isSectionHeader) {
            if ($null -ne $currentHeader) {
                $parsed = Get-ParsedCandidateHeader -Line $currentHeader
                if (-not $parsed.Valid) {
                    throw "Invalid section header '$currentHeader'. Expected format: description (rt-list-name, CUR):"
                }

                $sections += [pscustomobject]@{
                    Header           = $currentHeader
                    Description      = [string]$parsed.Description
                    RtListName       = [string]$parsed.SleeveName
                    RequiredCurrency = [string]$parsed.RequiredCurrency
                    Symbols          = @($currentSymbols)
                }
            }

            $currentHeader = $line
            $currentSymbols = @()
            $currentSeen = @{}
            continue
        }

        if ($null -eq $currentHeader) {
            throw "Found symbol line before any section header in '$InputPath'."
        }

        foreach ($part in $line.Split(',')) {
            $symbol = $part.Trim().ToUpperInvariant()
            if ([string]::IsNullOrWhiteSpace($symbol)) {
                continue
            }

            if (-not $currentSeen.ContainsKey($symbol)) {
                $currentSeen[$symbol] = $true
                $currentSymbols += $symbol
            }
        }
    }

    if ($null -ne $currentHeader) {
        $parsed = Get-ParsedCandidateHeader -Line $currentHeader
        if (-not $parsed.Valid) {
            throw "Invalid section header '$currentHeader'. Expected format: description (rt-list-name, CUR):"
        }

        $sections += [pscustomobject]@{
            Header           = $currentHeader
            Description      = [string]$parsed.Description
            RtListName       = [string]$parsed.SleeveName
            RequiredCurrency = [string]$parsed.RequiredCurrency
            Symbols          = @($currentSymbols)
        }
    }

    if (@($sections).Count -eq 0) {
        throw "No candidate sections parsed from '$InputPath'."
    }

    return @($sections)
}

function Get-ListingIndexes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    $configDirectory = Split-Path -Path $ConfigPath -Parent
    $config = Get-EodhdEffectiveConfig -ConfigPath $ConfigPath
    $outputDirectorySetting = [string]$config.outputDirectory
    if ([string]::IsNullOrWhiteSpace($outputDirectorySetting)) {
        $outputDirectorySetting = "./output"
    }

    $outputDirectory = Resolve-ConfigRelativePath -Path $outputDirectorySetting -ConfigDirectory $configDirectory
    if (-not (Test-Path -LiteralPath $outputDirectory)) {
        throw "Output directory not found: $outputDirectory. Run Invoke-EodhdSymbolExport.ps1 first."
    }

    $exchangePayloadFiles = @(Get-ChildItem -LiteralPath $outputDirectory -Filter "*-symbols-full.json" -File)
    if ($exchangePayloadFiles.Count -eq 0) {
        throw "No '*-symbols-full.json' files found in output directory: $outputDirectory. Run Invoke-EodhdSymbolExport.ps1 first."
    }

    $exact = @{}
    $normalized = @{}
    foreach ($payloadFile in $exchangePayloadFiles) {
        $exchangeCode = [System.IO.Path]::GetFileNameWithoutExtension($payloadFile.Name) -replace '-symbols-full$', ''
        if ([string]::IsNullOrWhiteSpace($exchangeCode)) {
            continue
        }

        $rows = Get-Content -LiteralPath $payloadFile.FullName -Raw | ConvertFrom-Json
        foreach ($row in @($rows)) {
            $code = [string]$row.Code
            if ([string]::IsNullOrWhiteSpace($code)) {
                continue
            }

            $upperCode = $code.Trim().ToUpperInvariant()
            $currency = [string]$row.Currency
            $token = "{0}|{1}" -f $exchangeCode.Trim().ToUpperInvariant(), $currency.Trim().ToUpperInvariant()

            if (-not $exact.ContainsKey($upperCode)) {
                $exact[$upperCode] = New-Object 'System.Collections.Generic.HashSet[string]'
            }
            $exact[$upperCode].Add($token) | Out-Null

            $normalizedCode = ConvertTo-NormalizedCandidateSymbol -Value $upperCode
            if (-not [string]::IsNullOrWhiteSpace($normalizedCode)) {
                if (-not $normalized.ContainsKey($normalizedCode)) {
                    $normalized[$normalizedCode] = New-Object 'System.Collections.Generic.HashSet[string]'
                }
                $normalized[$normalizedCode].Add($token) | Out-Null
            }
        }
    }

    return [pscustomobject]@{
        Exact            = $exact
        Normalized       = $normalized
        OutputDirectory  = $outputDirectory
        ExchangePayloads = $exchangePayloadFiles.FullName
    }
}

function Get-CandidateValidationRows {
    param(
        [Parameter(Mandatory = $true)]
        $Sections,
        [Parameter(Mandatory = $true)]
        $ListingIndexes,
        [Parameter(Mandatory = $true)]
        [string]$PreferredExchangeCode
    )

    $rows = @()

    foreach ($section in @($Sections)) {
        foreach ($symbol in @($section.Symbols)) {
            $split = Get-ListingLookupSymbolAndExchange -CandidateSymbol ([string]$symbol)
            $lookupSymbol = [string]$split.LookupSymbol
            $requestedExchange = [string]$split.RequestedExchange

            $tokenMap = @{}

            foreach ($candidate in (Get-SymbolLookupKeys -Symbol $lookupSymbol)) {
                if ($ListingIndexes.Exact.ContainsKey($candidate)) {
                    foreach ($token in @($ListingIndexes.Exact[$candidate])) {
                        $tokenMap[[string]$token] = $true
                    }
                }

                if ($ListingIndexes.Normalized.ContainsKey($candidate)) {
                    foreach ($token in @($ListingIndexes.Normalized[$candidate])) {
                        $tokenMap[[string]$token] = $true
                    }
                }
            }

            $allMatches = @(
                $tokenMap.Keys |
                Sort-Object |
                ForEach-Object {
                    $parts = ([string]$_) -split '\|', 2
                    [pscustomobject]@{
                        Exchange = if ($parts.Count -ge 1) { [string]$parts[0] } else { "" }
                        Currency = if ($parts.Count -ge 2) { [string]$parts[1] } else { "" }
                    }
                }
            )

            $currencyMatches = @(
                $allMatches |
                Where-Object { Test-RequiredCurrencyMatches -Expected ([string]$section.RequiredCurrency) -Actual ([string]$_.Currency) } |
                Sort-Object Exchange, Currency
            )

            $exchangeFilter = if (-not [string]::IsNullOrWhiteSpace($requestedExchange)) { $requestedExchange } else { $PreferredExchangeCode }
            $preferredMatches = @(
                $currencyMatches |
                Where-Object { $_.Exchange -eq $exchangeFilter }
            )

            $status = ""
            $statusDetail = ""
            $chosenExchange = ""
            $chosenCurrency = ""

            if ($allMatches.Count -eq 0) {
                $status = "not_found"
                $statusDetail = "No matching listing token found."
            }
            elseif ($currencyMatches.Count -eq 0) {
                $status = "currency_mismatch"
                $statusDetail = "Symbol exists, but none of the listings matched required currency $($section.RequiredCurrency)."
            }
            elseif ($preferredMatches.Count -eq 0) {
                if (-not [string]::IsNullOrWhiteSpace($requestedExchange)) {
                    $status = "not_on_requested_exchange"
                    $statusDetail = "Currency matched, but symbol was not found on requested exchange $requestedExchange."
                }
                else {
                    $status = "not_on_preferred_exchange"
                    $statusDetail = "Currency matched, but symbol was not found on preferred exchange $PreferredExchangeCode."
                }
            }
            else {
                $status = "valid"
                if (-not [string]::IsNullOrWhiteSpace($requestedExchange)) {
                    $statusDetail = "Listing found on requested exchange $requestedExchange and currency matched."
                }
                else {
                    $statusDetail = "Listing found on preferred exchange and currency matched."
                }
                $chosenExchange = [string]$preferredMatches[0].Exchange
                $chosenCurrency = [string]$preferredMatches[0].Currency
            }

            $apiBase = $lookupSymbol
            $chosenApiSymbol = $(if ([string]::IsNullOrWhiteSpace($chosenExchange)) { "" } else { "{0}.{1}" -f $apiBase, $chosenExchange })

            $rows += [pscustomobject]@{
                SectionDescription       = [string]$section.Description
                SleeveName               = [string]$section.RtListName
                RequiredCurrency         = [string]$section.RequiredCurrency
                RequestedSymbol          = [string]$symbol
                MatchStatus              = $status
                MatchStatusDetail        = $statusDetail
                PreferredExchangeCode    = $PreferredExchangeCode
                ChosenExchange           = $chosenExchange
                ChosenCurrency           = $chosenCurrency
                ChosenApiSymbol          = $chosenApiSymbol
                AllExchanges             = (($allMatches | ForEach-Object { $_.Exchange }) -join ';')
                AllCurrencies            = (($allMatches | ForEach-Object { $_.Currency }) -join ';')
                CurrencyMatchedExchanges = (($currencyMatches | ForEach-Object { $_.Exchange }) -join ';')
            }
        }
    }

    return @($rows)
}

function Write-Utf8Lines {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        $Lines
    )

    $directory = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    [System.IO.File]::WriteAllLines($Path, [string[]]@($Lines), [System.Text.UTF8Encoding]::new($false))
}

function Invoke-HistoryDownload {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SymbolsFilePath,
        [Parameter(Mandatory = $true)]
        [string]$HistoryOutputDirectory,
        [Parameter(Mandatory = $true)]
        [string]$HistorySummaryCsvPath
    )

    Push-Location $script:EodhdRepoRoot
    try {
        $arguments = @(
            "run"
            ".\DownloadSymbolHistory.cs"
            "--"
            "--output-dir"
            $HistoryOutputDirectory
            "--summary-csv"
            $HistorySummaryCsvPath
            "--symbol-file"
            $SymbolsFilePath
        )

        & dotnet @arguments
        if ($LASTEXITCODE -ne 0) {
            throw "DownloadSymbolHistory.cs failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
    }
}

function Get-HistoryLookup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HistorySummaryCsvPath
    )

    if (-not (Test-Path -LiteralPath $HistorySummaryCsvPath)) {
        return @{}
    }

    $lookup = @{}
    foreach ($row in (Import-Csv -LiteralPath $HistorySummaryCsvPath)) {
        $lookup[[string]$row.Symbol] = $row
    }

    return $lookup
}

function Join-HistoryToValidationRows {
    param(
        [Parameter(Mandatory = $true)]
        $ValidationRows,
        [Parameter(Mandatory = $true)]
        $HistoryLookup
    )

    $joined = @()
    foreach ($row in @($ValidationRows)) {
        $history = $null
        if (-not [string]::IsNullOrWhiteSpace([string]$row.ChosenApiSymbol) -and $HistoryLookup.ContainsKey([string]$row.ChosenApiSymbol)) {
            $history = $HistoryLookup[[string]$row.ChosenApiSymbol]
        }

        $joined += [pscustomobject]@{
            SectionDescription       = [string]$row.SectionDescription
            SleeveName               = [string]$row.SleeveName
            RequiredCurrency         = [string]$row.RequiredCurrency
            RequestedSymbol          = [string]$row.RequestedSymbol
            MatchStatus              = [string]$row.MatchStatus
            MatchStatusDetail        = [string]$row.MatchStatusDetail
            PreferredExchangeCode    = [string]$row.PreferredExchangeCode
            ChosenExchange           = [string]$row.ChosenExchange
            ChosenCurrency           = [string]$row.ChosenCurrency
            ChosenApiSymbol          = [string]$row.ChosenApiSymbol
            AllExchanges             = [string]$row.AllExchanges
            AllCurrencies            = [string]$row.AllCurrencies
            CurrencyMatchedExchanges = [string]$row.CurrencyMatchedExchanges
            HistoryRows              = if ($null -eq $history) { "" } else { [string]$history.Rows }
            FirstDate                = if ($null -eq $history) { "" } else { [string]$history.FirstDate }
            LastDate                 = if ($null -eq $history) { "" } else { [string]$history.LastDate }
            CsvPath                  = if ($null -eq $history) { "" } else { [string]$history.CsvPath }
        }
    }

    return @($joined)
}

function Write-SummaryMarkdown {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        $ResultRows,
        [Parameter(Mandatory = $true)]
        [string]$InputFilePath,
        [Parameter(Mandatory = $true)]
        [string]$PreferredExchangeCode
    )

    $validHistoryRows = @(
        $ResultRows |
        Where-Object {
            $_.MatchStatus -eq "valid" -and -not [string]::IsNullOrWhiteSpace([string]$_.FirstDate)
        }
    )

    $sharedStartDate = ""
    $bottlenecks = @()
    $historyConstraints = @()
    if ($validHistoryRows.Count -gt 0) {
        $sharedStartDate = (
            $validHistoryRows |
            ForEach-Object { [datetime]::ParseExact([string]$_.FirstDate, "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture) } |
            Sort-Object -Descending |
            Select-Object -First 1
        ).ToString("yyyy-MM-dd")

        $bottlenecks = @(
            $validHistoryRows |
            Where-Object { [string]$_.FirstDate -eq $sharedStartDate } |
            Sort-Object SleeveName, RequestedSymbol
        )

        $historyConstraints = @(
            $validHistoryRows |
            Sort-Object @{ Expression = { [datetime]::ParseExact([string]$_.FirstDate, "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture) }; Descending = $true }, SleeveName, RequestedSymbol
        )
    }

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add("# Candidate Symbol Validation") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Input file: ``$InputFilePath``") | Out-Null
    $lines.Add("- Preferred exchange: ``$PreferredExchangeCode``") | Out-Null
    $lines.Add("- Requested symbols: ``$($ResultRows.Count)``") | Out-Null
    $lines.Add("- Valid listing+currency matches: ``$((@($ResultRows | Where-Object { $_.MatchStatus -eq 'valid' })).Count)``") | Out-Null
    $lines.Add("- Shared supported start date: ``$(if ([string]::IsNullOrWhiteSpace($sharedStartDate)) { 'n/a' } else { $sharedStartDate })``") | Out-Null
    $lines.Add("") | Out-Null

    $statusGroups = @(
        $ResultRows |
        Group-Object MatchStatus |
        Sort-Object Name
    )
    $lines.Add("## Status Counts") | Out-Null
    foreach ($group in $statusGroups) {
        $lines.Add("- ``$($group.Name)``: ``$($group.Count)``") | Out-Null
    }
    $lines.Add("") | Out-Null

    $lines.Add("## Bottleneck Symbols") | Out-Null
    if ($bottlenecks.Count -eq 0) {
        $lines.Add("- None.") | Out-Null
    }
    else {
        foreach ($row in $bottlenecks) {
            $lines.Add("- ``$($row.RequestedSymbol)`` / ``$($row.SleeveName)`` starts on ``$($row.FirstDate)``") | Out-Null
        }
    }
    $lines.Add("") | Out-Null

    $lines.Add("## History Constraints") | Out-Null
    if ($historyConstraints.Count -eq 0) {
        $lines.Add("- None.") | Out-Null
    }
    else {
        foreach ($row in $historyConstraints) {
            $lines.Add("- ``$($row.RequestedSymbol)`` / ``$($row.SleeveName)`` starts on ``$($row.FirstDate)``") | Out-Null
        }
    }
    $lines.Add("") | Out-Null

    $lines.Add("## Rejected Candidates") | Out-Null
    $rejected = @(
        $ResultRows |
        Where-Object { $_.MatchStatus -ne "valid" } |
        Sort-Object SleeveName, RequestedSymbol
    )
    if ($rejected.Count -eq 0) {
        $lines.Add("- None.") | Out-Null
    }
    else {
        foreach ($row in $rejected) {
            $lines.Add("- ``$($row.RequestedSymbol)`` / ``$($row.SleeveName)``: ``$($row.MatchStatus)`` (`$($row.MatchStatusDetail)`)") | Out-Null
        }
    }

    Write-Utf8Lines -Path $Path -Lines $lines
}

function Invoke-EodhdCandidateSymbolValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$Path,
        [Parameter(Mandatory = $false)]
        [string]$InputFilePath,
        [Parameter(Mandatory = $false)]
        [string]$ConfigPath,
        [Parameter(Mandatory = $false)]
        [string]$AnalysisDirectory,
        [Parameter(Mandatory = $false)]
        [string]$Folder,
        [Parameter(Mandatory = $false)]
        [string]$PreferredExchangeCode,
        [Parameter(Mandatory = $false)]
        [switch]$SkipHistoryDownload,
        [Parameter(Mandatory = $false)]
        [switch]$ProfileTimings
    )

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        if (-not [string]::IsNullOrWhiteSpace($InputFilePath)) {
            throw "Cannot use -Path together with -InputFilePath. Pass one location, or use the explicit parameters only."
        }
        if (-not [string]::IsNullOrWhiteSpace($Folder)) {
            throw "Cannot use -Path together with -Folder."
        }
        $resolvedPath = [System.IO.Path]::GetFullPath($Path)
        if (-not (Test-Path -LiteralPath $resolvedPath)) {
            throw "Path not found: $resolvedPath"
        }
        if (Test-Path -LiteralPath $resolvedPath -PathType Container) {
            $candidateInFolder = Join-Path $resolvedPath "candidate_input.txt"
            if (-not (Test-Path -LiteralPath $candidateInFolder -PathType Leaf)) {
                throw "Directory does not contain candidate_input.txt: $resolvedPath"
            }
            if (-not [string]::IsNullOrWhiteSpace($AnalysisDirectory)) {
                $resolvedAd = [System.IO.Path]::GetFullPath($AnalysisDirectory)
                if (-not $resolvedAd.Equals($resolvedPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw "Cannot use -Path (folder) together with a different -AnalysisDirectory."
                }
            }
            $InputFilePath = $candidateInFolder
            $AnalysisDirectory = $resolvedPath
        }
        else {
            $InputFilePath = $resolvedPath
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Folder)) {
        $resolvedFolder = [System.IO.Path]::GetFullPath($Folder)
        if (-not (Test-Path -LiteralPath $resolvedFolder -PathType Container)) {
            throw "Folder not found or not a directory: $resolvedFolder"
        }
        $candidateInFolder = Join-Path $resolvedFolder "candidate_input.txt"
        if (-not (Test-Path -LiteralPath $candidateInFolder -PathType Leaf)) {
            throw "candidate_input.txt not found in folder: $resolvedFolder"
        }
        if (-not [string]::IsNullOrWhiteSpace($InputFilePath)) {
            throw "Cannot use -Folder together with -InputFilePath or -Path. Point -Folder at a directory that contains candidate_input.txt."
        }
        if (-not [string]::IsNullOrWhiteSpace($AnalysisDirectory)) {
            $resolvedAd = [System.IO.Path]::GetFullPath($AnalysisDirectory)
            if (-not $resolvedAd.Equals($resolvedFolder, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Cannot use -Folder together with a different -AnalysisDirectory."
            }
        }
        $InputFilePath = $candidateInFolder
        $AnalysisDirectory = $resolvedFolder
    }

    $resolvedInputFilePath = Resolve-CandidatePath -RawInputFilePath $InputFilePath
    $resolvedConfigPath = if ([string]::IsNullOrWhiteSpace($ConfigPath)) { Join-Path $script:EodhdRepoRoot "eodhd-config.json" } else { [System.IO.Path]::GetFullPath($ConfigPath) }
    $resolvedAnalysisDirectory = Resolve-AnalysisPath -ResolvedInputFilePath $resolvedInputFilePath -RawAnalysisDirectory $AnalysisDirectory

    if (-not (Test-Path -LiteralPath $resolvedInputFilePath)) {
        throw "Input file not found: $resolvedInputFilePath"
    }
    if (-not (Test-Path -LiteralPath $resolvedConfigPath)) {
        throw "Config file not found: $resolvedConfigPath"
    }

    New-Item -Path $resolvedAnalysisDirectory -ItemType Directory -Force | Out-Null

    $sections = Get-CandidateSections -InputPath $resolvedInputFilePath

    $listingIndexes = Get-ListingIndexes -ConfigPath $resolvedConfigPath
    $validationRows = Get-CandidateValidationRows -Sections $sections -ListingIndexes $listingIndexes -PreferredExchangeCode $PreferredExchangeCode

    $validationCsvPath = Join-Path $resolvedAnalysisDirectory "candidate_validation.csv"
    $validationRows | Export-Csv -LiteralPath $validationCsvPath -NoTypeInformation -Encoding utf8

    $historySymbols = @(
        $validationRows |
        Where-Object { $_.MatchStatus -eq "valid" -and -not [string]::IsNullOrWhiteSpace([string]$_.ChosenApiSymbol) } |
        Select-Object -ExpandProperty ChosenApiSymbol -Unique
    )

    $symbolsFilePath = Join-Path $resolvedAnalysisDirectory "history_symbols.txt"
    Write-Utf8Lines -Path $symbolsFilePath -Lines ([string[]]$historySymbols)

    $historyOutputDirectory = Join-Path $resolvedAnalysisDirectory "history-data"
    $historySummaryCsvPath = Join-Path $resolvedAnalysisDirectory "history_summary.csv"
    if (-not $SkipHistoryDownload -and $historySymbols.Count -gt 0) {
        Invoke-HistoryDownload -SymbolsFilePath $symbolsFilePath -HistoryOutputDirectory $historyOutputDirectory -HistorySummaryCsvPath $historySummaryCsvPath
    }

    $historyLookup = Get-HistoryLookup -HistorySummaryCsvPath $historySummaryCsvPath
    $resultRows = Join-HistoryToValidationRows -ValidationRows $validationRows -HistoryLookup $historyLookup

    $resultCsvPath = Join-Path $resolvedAnalysisDirectory "candidate_results.csv"
    $resultRows | Export-Csv -LiteralPath $resultCsvPath -NoTypeInformation -Encoding utf8

    $summaryPath = Join-Path $resolvedAnalysisDirectory "summary.md"
    Write-SummaryMarkdown -Path $summaryPath -ResultRows $resultRows -InputFilePath $resolvedInputFilePath -PreferredExchangeCode $PreferredExchangeCode

    Write-Host "Candidate validation complete."
    Write-Host "Analysis directory: $resolvedAnalysisDirectory"
    Write-Host "Validation CSV: $validationCsvPath"
    Write-Host "Result CSV: $resultCsvPath"
    Write-Host "Summary: $summaryPath"

    return 0
}

if ($MyInvocation.InvocationName -ne ".") {
    $exitCode = Invoke-EodhdCandidateSymbolValidation `
        -Path $Path `
        -InputFilePath $InputFilePath `
        -ConfigPath $ConfigPath `
        -AnalysisDirectory $AnalysisDirectory `
        -Folder $Folder `
        -PreferredExchangeCode $PreferredExchangeCode `
        -SkipHistoryDownload:$SkipHistoryDownload `
        -ProfileTimings:$ProfileTimings
    exit $exitCode
}
