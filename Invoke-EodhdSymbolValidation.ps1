param(
    [Parameter(Mandatory = $false)]
    [string]$InputFilePath = "",
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "",
    [Parameter(Mandatory = $false, HelpMessage = "Print phase timings and slowest *-symbols-full.json loads (negligible overhead when off).")]
    [switch]$ProfileTimings
)

if ([string]::IsNullOrWhiteSpace($InputFilePath)) {
    $scriptDirectory = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
    $InputFilePath = Join-Path $scriptDirectory "2026.02.25_European_Stocks.txt"
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $scriptDirectory = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
    $ConfigPath = Join-Path $scriptDirectory "eodhd-config.json"
}

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'Invoke-EodhdSymbolValidation requires PowerShell 7+ (listing indexes use System.Text.Json Utf8JsonReader).'
}

$symbolIndexCsPath = Join-Path (Split-Path -Path $MyInvocation.MyCommand.Path -Parent) 'SymbolIndexStreamer.cs'
if (-not (Test-Path -LiteralPath $symbolIndexCsPath)) {
    throw "C# helper not found: $symbolIndexCsPath"
}

try {
    Add-Type -Path $symbolIndexCsPath -ErrorAction Stop
}
catch {
    if ($_.Exception.Message -notmatch '(is already defined|already exists|duplicate type name)') {
        throw
    }
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

function Add-ValidationPhaseElapsed {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Stopwatch]$Stopwatch,
        [Parameter(Mandatory = $true)]
        $List,
        [Parameter(Mandatory = $true)]
        [string]$PhaseName
    )

    $Stopwatch.Stop()
    [void]$List.Add([pscustomobject]@{ Phase = $PhaseName; Ms = [int64]$Stopwatch.ElapsedMilliseconds })
    [void]$Stopwatch.Restart()
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

function Get-ParsedSectionHeader {
    param([Parameter(Mandatory = $true)][string]$Line)

    $result = [pscustomobject]@{
        Valid            = $false
        Description      = ""
        RtListName       = ""
        SectionCurrency  = ""
    }

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $result
    }

    $m = [regex]::Match($Line.Trim(), '^(.+)\s\(([^)]+)\):\s*$')
    if (-not $m.Success) {
        return $result
    }

    $desc = $m.Groups[1].Value.Trim()
    $inner = $m.Groups[2].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($desc) -or [string]::IsNullOrWhiteSpace($inner)) {
        return $result
    }

    $rt = ""
    $sectionCurrency = ""
    $commaIndex = $inner.IndexOf(',')
    if ($commaIndex -ge 0) {
        $rt = $inner.Substring(0, $commaIndex).Trim()
        $sectionCurrency = $inner.Substring($commaIndex + 1).Trim()
    }
    else {
        $rt = $inner
    }

    if ([string]::IsNullOrWhiteSpace($rt)) {
        return $result
    }

    if ($commaIndex -lt 0 -or [string]::IsNullOrWhiteSpace($sectionCurrency)) {
        return $result
    }

    $sectionCurrency = $sectionCurrency.ToUpperInvariant()

    $result.Valid = $true
    $result.Description = $desc
    $result.RtListName = $rt
    $result.SectionCurrency = $sectionCurrency
    return $result
}

function Get-SectionMatchRateDisplayLine {
    param(
        [Parameter(Mandatory = $true)]
        $Section,
        [Parameter(Mandatory = $true)]
        [int]$Percent
    )

    if ($Section.HeaderFormatValid) {
        return ("{0}: {1} [{2}] ({3}%)" -f $Section.Description, $Section.RtListName, $Section.SectionCurrency, $Percent)
    }

    return ("{0} ({1}%)" -f $Section.Header, $Percent)
}

function Add-ToListingTokenSet {
    param(
        [Parameter(Mandatory = $true)]
        $TokenSet,
        [Parameter(Mandatory = $true)]
        $Index,
        [Parameter(Mandatory = $true)]
        [string]$CandidateKey
    )

    if (-not $Index.ContainsKey($CandidateKey)) {
        return
    }

    foreach ($t in $Index[$CandidateKey]) {
        [void]$TokenSet.Add([string]$t)
    }
}

function Split-ListingToken {
    param([Parameter(Mandatory = $true)][string]$Token)

    $i = $Token.IndexOf('|')
    if ($i -lt 0) {
        return @{
            Exchange = $Token
            Currency = ""
        }
    }

    return @{
        Exchange = $Token.Substring(0, $i)
        Currency = $Token.Substring($i + 1)
    }
}

function Test-SectionCurrencyMatchesListing {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Expected,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Listing
    )

    if ($Expected -eq $Listing) {
        return $true
    }

    # EODHD often uses GBX (pence) on LSE rows; section headers typically say GBP.
    if (($Expected -eq "GBP" -and $Listing -eq "GBX") -or ($Expected -eq "GBX" -and $Listing -eq "GBP")) {
        return $true
    }

    return $false
}

function Invoke-EodhdSymbolValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputFilePath,
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,
        [Parameter(Mandatory = $false)]
        [switch]$ProfileTimings
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = "Stop"

    try {
        $timingPhases = $null
        $fileTimings = $null
        $phaseSw = $null
        $runSw = $null
        if ($ProfileTimings) {
            $timingPhases = New-Object 'System.Collections.Generic.List[object]'
            $fileTimings = New-Object 'System.Collections.Generic.List[object]'
            $phaseSw = [System.Diagnostics.Stopwatch]::StartNew()
            $runSw = [System.Diagnostics.Stopwatch]::StartNew()
        }

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

        if ($ProfileTimings) {
            Add-ValidationPhaseElapsed -Stopwatch $phaseSw -List $timingPhases -PhaseName "ConfigAndDiscovery"
        }

        Write-Host ""
        Write-Host ("BuildListingIndexes: {0} payload file(s); Utf8JsonReader streaming (one file at a time)." -f $exchangePayloadFiles.Count)

        $streamer = [EodhdExperimental.SymbolIndexStreamer]::new()
        foreach ($payloadFile in $exchangePayloadFiles) {
            $exchangeCode = [System.IO.Path]::GetFileNameWithoutExtension($payloadFile.Name) -replace '-symbols-full$', ''
            if ([string]::IsNullOrWhiteSpace($exchangeCode)) {
                continue
            }

            Write-Host ("  {0}  ex={1}  (streaming parse + index...)" -f $payloadFile.Name, $exchangeCode)
            $fileSw = $null
            if ($ProfileTimings) {
                $fileSw = [System.Diagnostics.Stopwatch]::StartNew()
            }

            try {
                $rowCount = $streamer.AddPayloadFile($payloadFile.FullName, $exchangeCode)
            }
            catch {
                Write-Host ("  {0} - skipped (error)" -f $payloadFile.Name)
                Write-Warning "Skipping payload file (streaming parse failed): $($payloadFile.FullName) - $($_.Exception.Message)"
                if ($ProfileTimings -and $null -ne $fileSw) {
                    $fileSw.Stop()
                }
                continue
            }

            if ($ProfileTimings -and $null -ne $fileSw) {
                $fileSw.Stop()
                [void]$fileTimings.Add([pscustomobject]@{
                    Exchange = $exchangeCode
                    RowCount = $rowCount
                    Ms       = [int64]$fileSw.ElapsedMilliseconds
                    Name     = $payloadFile.Name
                })
            }

            Write-Host ("  {0}  ex={1}  rows={2} (indexed)" -f $payloadFile.Name, $exchangeCode, $rowCount)
        }

        $symbolToListingsExact = $streamer.Exact
        $symbolToListingsNormalized = $streamer.Normalized

        if ($ProfileTimings) {
            Add-ValidationPhaseElapsed -Stopwatch $phaseSw -List $timingPhases -PhaseName "BuildListingIndexes(total)"
        }

        $sections = New-Object 'System.Collections.Generic.List[object]'
        $currentSectionHeader = $null
        $currentSymbols = $null
        $currentSeen = $null

        function Add-CurrentSection {
            param([Parameter(Mandatory = $true)][string]$Header, $SymbolsList)

            $parsed = Get-ParsedSectionHeader -Line $Header
            [void]$sections.Add([pscustomobject]@{
                    Header            = $Header
                    Description       = [string]$parsed.Description
                    RtListName        = [string]$parsed.RtListName
                    SectionCurrency   = [string]$parsed.SectionCurrency
                    HeaderFormatValid = [bool]$parsed.Valid
                    Symbols           = @($SymbolsList)
                })
        }

        foreach ($rawLine in (Get-Content -LiteralPath $InputFilePath)) {
            $line = $rawLine.Trim()
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            if ($line.StartsWith("#") -or $line.StartsWith("//")) {
                continue
            }

            # Commas inside "description (rt-list-name, CUR):" (CUR required) must not turn the header into a symbol line.
            $isSectionHeaderShape = [regex]::IsMatch($line, '^(.+)\s\(([^)]+)\):\s*$')
            $isSymbolLine = $line.Contains(',') -and -not $isSectionHeaderShape
            if (-not $isSymbolLine) {
                if ($null -ne $currentSectionHeader) {
                    Add-CurrentSection -Header $currentSectionHeader -SymbolsList $currentSymbols
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
            Add-CurrentSection -Header $currentSectionHeader -SymbolsList $currentSymbols
        }

        if ($sections.Count -eq 0) {
            Write-Error "No sections parsed from input file: $InputFilePath"
            return 1
        }

        if ($ProfileTimings) {
            Add-ValidationPhaseElapsed -Stopwatch $phaseSw -List $timingPhases -PhaseName "ParseInputFile"
        }

        $outputLines = New-Object 'System.Collections.Generic.List[string]'
        $totalSymbols = 0
        $totalFound = 0
        $totalNotFound = 0
        $totalCurrencyMismatch = 0
        $notFoundBySection = New-Object 'System.Collections.Generic.List[object]'
        $currencyMismatchBySection = New-Object 'System.Collections.Generic.List[object]'
        $sectionMatchRates = New-Object 'System.Collections.Generic.List[object]'

        foreach ($section in $sections) {
            $notFoundLines = New-Object 'System.Collections.Generic.List[string]'
            $foundLines = New-Object 'System.Collections.Generic.List[string]'
            $sectionNotFoundSymbols = New-Object 'System.Collections.Generic.List[string]'
            $sectionCurrencyMismatchLines = New-Object 'System.Collections.Generic.List[string]'
            $sectionCurrencyMismatchCount = 0

            $expectedCurrency = [string]$section.SectionCurrency

            foreach ($symbol in @($section.Symbols)) {
                $totalSymbols++
                $listingTokenSet = New-Object 'System.Collections.Generic.HashSet[string]'

                foreach ($candidate in (Get-SymbolCandidates -Symbol $symbol)) {
                    Add-ToListingTokenSet -TokenSet $listingTokenSet -Index $symbolToListingsExact -CandidateKey $candidate
                    Add-ToListingTokenSet -TokenSet $listingTokenSet -Index $symbolToListingsNormalized -CandidateKey $candidate
                }

                if ($listingTokenSet.Count -eq 0) {
                    $totalNotFound++
                    [void]$sectionNotFoundSymbols.Add($symbol)
                    $notFoundLines.Add(("{0}, NOT_FOUND" -f $symbol))
                    continue
                }

                $matchedTokens = [System.Collections.Generic.List[string]]::new()
                foreach ($t in $listingTokenSet) {
                    $p = Split-ListingToken -Token $t
                    if ([string]::IsNullOrWhiteSpace($expectedCurrency)) {
                        [void]$matchedTokens.Add([string]$t)
                    }
                    elseif (Test-SectionCurrencyMatchesListing -Expected $expectedCurrency -Listing ([string]$p.Currency)) {
                        [void]$matchedTokens.Add([string]$t)
                    }
                }

                if ($matchedTokens.Count -eq 0) {
                    $totalCurrencyMismatch++
                    $sectionCurrencyMismatchCount++
                    $summaries = New-Object 'System.Collections.Generic.List[string]'
                    foreach ($t in ($listingTokenSet | Sort-Object)) {
                        $p = Split-ListingToken -Token $t
                        $curLabel = if ([string]::IsNullOrWhiteSpace([string]$p.Currency)) { "?" } else { [string]$p.Currency }
                        [void]$summaries.Add(("{0}@{1}" -f $curLabel, $p.Exchange))
                    }

                    $detail = ($summaries -join ", ")
                    $line = ("{0}, CURRENCY_MISMATCH need {1}; listing had {2}" -f $symbol, $expectedCurrency, $detail)
                    $notFoundLines.Add($line)
                    $sectionCurrencyMismatchLines.Add($line)
                    continue
                }

                $exchangeSet = New-Object 'System.Collections.Generic.HashSet[string]'
                foreach ($t in $matchedTokens) {
                    $p = Split-ListingToken -Token $t
                    [void]$exchangeSet.Add([string]$p.Exchange)
                }

                $matchedExchanges = @($exchangeSet | Sort-Object)
                $totalFound++
                $foundLines.Add(("{0}, {1}" -f $symbol, ($matchedExchanges -join ", ")))
            }

            if ($sectionNotFoundSymbols.Count -gt 0) {
                [void]$notFoundBySection.Add([pscustomobject]@{
                    Header  = [string]$section.Header
                    Symbols = @($sectionNotFoundSymbols)
                })
            }

            if ($sectionCurrencyMismatchLines.Count -gt 0) {
                [void]$currencyMismatchBySection.Add([pscustomobject]@{
                    Header = [string]$section.Header
                    Lines  = @($sectionCurrencyMismatchLines)
                })
            }

            $sectionTotal = @($section.Symbols).Count
            $sectionFoundCount = $sectionTotal - $sectionNotFoundSymbols.Count - $sectionCurrencyMismatchCount
            $sectionPercent = if ($sectionTotal -eq 0) {
                100
            }
            else {
                [int][math]::Round(100.0 * $sectionFoundCount / $sectionTotal)
            }

            [void]$sectionMatchRates.Add([pscustomobject]@{
                    Section      = $section
                    FoundCount   = $sectionFoundCount
                    TotalCount   = $sectionTotal
                    PercentFound = $sectionPercent
                })

            $outputLines.Add([string]$section.Header)
            foreach ($line in $notFoundLines) { $outputLines.Add($line) }
            foreach ($line in $foundLines) { $outputLines.Add($line) }
            $outputLines.Add("")
        }

        if ($ProfileTimings) {
            Add-ValidationPhaseElapsed -Stopwatch $phaseSw -List $timingPhases -PhaseName "ValidateSymbols"
        }

        $sortedMatchRates = @(
            $sectionMatchRates |
            Sort-Object @{ Expression = 'PercentFound'; Descending = $true }, @{
                Expression = {
                    if ($_.Section.HeaderFormatValid) { [string]$_.Section.Description } else { [string]$_.Section.Header }
                }
                Descending = $false
            }
        )

        $outputLines.Add("--- SECTION MATCH RATES (sorted by % found, highest first) ---")
        foreach ($row in $sortedMatchRates) {
            $outputLines.Add((Get-SectionMatchRateDisplayLine -Section $row.Section -Percent $row.PercentFound))
        }
        $outputLines.Add("")

        $outputLines.Add("--- VALID SECTION HEADERS (rt-list-name, currency) ---")
        $outputLines.Add("Required input header format: description (rt-list-name, CUR):")
        $outputLines.Add("Listing Currency from each *-symbols-full.json row must match CUR for a symbol to count as found (GBP in the header matches EODHD GBX on LSE).")
        $outputLines.Add("Columns: rt-list-name <TAB> description <TAB> currency")
        $validRt = @($sections | Where-Object { $_.HeaderFormatValid })
        if ($validRt.Count -eq 0) {
            $outputLines.Add("(none)")
        }
        else {
            foreach ($s in $validRt) {
                $outCur = [string]$s.SectionCurrency
                $outputLines.Add(("{0}`t{1}`t{2}" -f $s.RtListName, $s.Description, $outCur))
            }
        }

        $outputLines.Add("")
        $outputLines.Add("--- SECTION HEADER FORMAT ERRORS ---")
        $invalidHeaderSections = @($sections | Where-Object { -not $_.HeaderFormatValid })
        if ($invalidHeaderSections.Count -eq 0) {
            $outputLines.Add("(none - every section header matched description (rt-list-name, currency):)")
        }
        else {
            foreach ($s in $invalidHeaderSections) {
                $outputLines.Add(("ERROR: {0}" -f $s.Header))
            }
        }

        if ($ProfileTimings) {
            Add-ValidationPhaseElapsed -Stopwatch $phaseSw -List $timingPhases -PhaseName "AssembleReport"
        }

        $inputDirectory = Split-Path -Path $InputFilePath -Parent
        $inputBaseName = [System.IO.Path]::GetFileNameWithoutExtension($InputFilePath)
        $validationOutputPath = Join-Path $inputDirectory ("{0}_validation.txt" -f $inputBaseName)

        [System.IO.File]::WriteAllLines($validationOutputPath, @($outputLines), [System.Text.Encoding]::UTF8)

        if ($ProfileTimings) {
            Add-ValidationPhaseElapsed -Stopwatch $phaseSw -List $timingPhases -PhaseName "WriteOutputFile"
        }

        Write-Host "Validation output written to: $validationOutputPath"
        Write-Host ("Sections: {0} | Symbols: {1} | Found: {2} | Not found: {3} | Currency mismatch: {4}" -f $sections.Count, $totalSymbols, $totalFound, $totalNotFound, $totalCurrencyMismatch)

        Write-Host ""
        Write-Host "Section match rates (sorted by % found, highest first):"
        foreach ($row in $sortedMatchRates) {
            $line = Get-SectionMatchRateDisplayLine -Section $row.Section -Percent $row.PercentFound
            $fc = if ($row.PercentFound -eq 100) {
                "Green"
            }
            elseif ($row.PercentFound -ge 80) {
                "DarkYellow"
            }
            else {
                "Red"
            }
            Write-Host $line -ForegroundColor $fc
        }

        Write-Host ""
        if ($totalNotFound -eq 0 -and $totalCurrencyMismatch -eq 0) {
            Write-Host "All symbols were found with no missing codes or currency mismatches."
        }
        else {
            if ($totalNotFound -gt 0) {
                Write-Host ("Symbols NOT FOUND ({0}) by input section:" -f $totalNotFound)
                foreach ($group in $notFoundBySection) {
                    Write-Host ""
                    Write-Host $group.Header
                    foreach ($sym in $group.Symbols) {
                        Write-Host ("  {0}" -f $sym)
                    }
                }
            }

            if ($totalCurrencyMismatch -gt 0) {
                Write-Host ""
                Write-Host ("CURRENCY_MISMATCH ({0}) by input section (expected currency in header vs EODHD listing Currency field):" -f $totalCurrencyMismatch)
                foreach ($group in $currencyMismatchBySection) {
                    Write-Host ""
                    Write-Host $group.Header
                    foreach ($line in $group.Lines) {
                        Write-Host ("  {0}" -f $line)
                    }
                }
            }
        }

        Write-Host ""
        if ($invalidHeaderSections.Count -gt 0) {
            Write-Host ("SECTION HEADER FORMAT ERRORS ({0}) - expected: description (rt-list-name, CUR):" -f $invalidHeaderSections.Count) -ForegroundColor Red
            foreach ($s in $invalidHeaderSections) {
                Write-Host ("  ERROR: {0}" -f $s.Header) -ForegroundColor Red
            }
        }
        else {
            Write-Host "All section headers match description (rt-list-name, CUR):"
        }

        if ($ProfileTimings) {
            $runSw.Stop()
            Write-Host ""
            Write-Host "--- ProfileTimings (invoke body, milliseconds) ---"
            $sumMs = [int64]0
            foreach ($row in $timingPhases) {
                Write-Host ("  {0,-38} {1,9} ms" -f $row.Phase, $row.Ms)
                $sumMs += $row.Ms
            }
            Write-Host ("  {0,-38} {1,9} ms" -f "Phases sum (overlap excluded)", $sumMs)
            Write-Host ("  {0,-38} {1,9} ms" -f "Wall clock (through host output)", $runSw.ElapsedMilliseconds)
            Write-Host "  Slowest payload files (streaming parse + index rows):"
            foreach ($ft in ($fileTimings | Sort-Object Ms -Descending | Select-Object -First 15)) {
                Write-Host ("    {0,7} ms  rows={1,8}  ex={2,-6}  {3}" -f $ft.Ms, $ft.RowCount, $ft.Exchange, $ft.Name)
            }
        }

        return 0
    }
    catch {
        Write-Error "Validation failed: $($_.Exception.Message)"
        return 1
    }
}

if ($MyInvocation.InvocationName -ne ".") {
    $exitCode = Invoke-EodhdSymbolValidation -InputFilePath $script:InputFilePath -ConfigPath $script:ConfigPath -ProfileTimings:$ProfileTimings
    exit $exitCode
}
