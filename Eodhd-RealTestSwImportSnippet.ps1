# Dot-source from Get-SpiConstituents.ps1 / Get-SmiExpandedConstituents.ps1.
# Writes a minimal RealTest Import: block for EODHD Swiss (.SW) symbols.

function Export-EodhdSwRealTestImportSnippet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputFolder,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Tickers,
        [Parameter(Mandatory = $true)]
        [string]$SnippetFileName,
        [Parameter(Mandatory = $true)]
        [string]$SaveAsRtdName,
        [Parameter(Mandatory = $true)]
        [string]$ImportLogFileName,
        [Parameter(Mandatory = $true)]
        [string]$GroupTag,
        [int]$SymbolsPerIncludeLine = 14
    )

    if (-not (Test-Path -LiteralPath $OutputFolder)) {
        New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
    }

    $unique = @(
        $Tickers |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )

    $pairs = foreach ($t in $unique) {
        '{0}.SW>{1}' -f $t, $t
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('Import:')
    $lines.Add("`tDataSource:`tEODHD")
    $lines.Add("`tSymInfoFile:`t?scriptpath?\output\SW-syminfo-rt.csv")
    $lines.Add('')
    $lines.Add("`tSaveAs:`t$SaveAsRtdName")
    $lines.Add("`tLogFile:`t?scriptpath?\output\$ImportLogFileName")
    $lines.Add('')

    if ($pairs.Count -eq 0) {
        $lines.Add("`t// No equity tickers to import (empty universe).")
    }
    else {
        for ($i = 0; $i -lt $pairs.Count; $i += $SymbolsPerIncludeLine) {
            $take = [Math]::Min($SymbolsPerIncludeLine, $pairs.Count - $i)
            $slice = $pairs[$i..($i + $take - 1)]
            $joined = $slice -join ', '
            $lines.Add("`tIncludeList:`t$joined  {`"$GroupTag`"}")
        }
    }

    $path = Join-Path $OutputFolder $SnippetFileName
    $text = ($lines -join "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))

    return [pscustomobject]@{
        Path        = $path
        SymbolCount = $unique.Count
    }
}
