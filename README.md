# EODHD Export

This folder contains a standalone method to export exchange symbols from EODHD for use with [Real Test Trading software](https://mhptrading.com/)  The basic idea is to remove the need to figure out which symbols are available at which exchanges.

## Quickstart (Listing EODHD Exchanges)

Follow these steps in order to run the script and start exploring how it works.

1. Get an EODHD API key
  - Go to the EODHD website and create an account.
  - In your account dashboard, copy your API key.
2. Copy the `.env.example` to `.env` and paste in your EODHD API key
  - Open `.env` in a text editor.
  - Make sure you have exactly one line in the following format:

```text
EODHD_API_TOKEN=your-real-api-key-goes-here
```

1. Make sure that the file is called `.env` - there is already a .gitignore file that EXCLUDES this from source control.
2. Test that your key works by fetch a list of all the available exchanges from EODHD
  - Open PowerShell in this folder and run:

```powershell
pwsh .\Invoke-EodhdSymbolExport.ps1 -ListExchanges
```

- Expected result: information per exchange getting dumped to the console, something like this: 

```
Code         : USE
Name         : Uganda Securities Exchange
Country      : Uganda
Currency     : UGX
CountryISO2  : UG
CountryISO3  : UGA
OperatingMIC : XUGA
```


Congratulations - the system works - now onto the configuration of which exchanges to dump symbols for.

## Real Test Configuration [IMPORTANT]

Do NOT forget to put your EODHD API key into the real test ini file.  Real Test has to be closed when you modify the realtest.ini file. 

## Configuration

The Quickstart shows how to list the available exchanges.  To have the extraction script download only the exchanges you are interested in you fill in the ``exchanges`` configuration, its also possible to download all exchange, symbols via currency or by country.

The example configuration in this repo is:

```json
{
  "apiBaseUrl": "https://eodhd.com/api",
  "requestTimeoutSeconds": 60,
  "currencies": [],
  "countries": [],
  "exchanges": [
    {
      "code": [
        "SW",
        "XETRA",
        "PA",
        "F"
      ]
    }
  ],
  "symbolFormat": "{Code}.{ExchangeCode}",
  "outputDirectory": "./output",
  "logsDirectory": "./logs",
  "runHealthFileName": "last-run.json",
  "runHealthSummaryFileName": "run-health-summary.csv"
}
```

Here is what each of those elements do:

- `exchanges` controls which exchange lists are pulled.
  - `code` can be a single value or a list of exchange codes (take these from the -ListExchanges result).
- `currencies` is an optional list of currency codes (default: empty list `[]`).
  - Purpose: choose exchanges by the exchange trading currency instead of specific exchange codes.
  - Example: `["CHF","EUR"]`.
- `countries` is an optional list of country names (default: empty list `[]`).
  - Purpose: choose exchanges by country (for example all exchanges in Germany).
  - Example: `["Germany"]`.
- Selector behavior:
  - If either `currencies` or `countries` has values, the script calls `exchanges-list` and selects exchanges matching either selector.
  - In selector mode, `exchanges` is **ignored**.
  - Output is still per exchange (one file per matched exchange).
- All instrument types returned by EODHD are included in the export (no type filtering).
- `outputDirectory` and `logsDirectory` can be relative or absolute paths.

Example:

This configuration will fetch all symbols for both the SW and XETRA exchanges. 

```json
"exchanges": [
  { "code": ["SW", "XETRA"] }
]
```

Currency-driven selection example:

Overrides `exchanges` and instead pulls all exchanges that use one of the listed currencies.  All this code does is list exchanges, then downloads ALL the symbols for that exchange - as long as that exchange uses the specified currency.

```json
"currencies": ["CHF", "EUR"]
```

Country-driven selection example:

Overrides `exchanges` and instead pulls all exchanges within a particular country.  All this code does is list exchanges, then downloads ALL the symbols for that exchange - as long as that exchange is for the specified country.

```json
"countries": ["Germany"]
```

## Secure Token Configuration (.env)

Use a `.env` file in this folder with common dotenv syntax:

```text
EODHD_API_TOKEN=your-real-token-here
```

Quoted values also work:

```text
EODHD_API_TOKEN="your-real-token-here"
```

Token precedence at runtime:

1. `EODHD_API_TOKEN` from `.env` file
2. `EODHD_API_TOKEN` from process/user environment variables

Example token setup using process environment variable:

```powershell
$env:EODHD_API_TOKEN = "your-token-here"
```

For safety, store real secrets in `.env` and NEVER CHECK THIS INTO SOURCE CONTROL.

## Run Manually

This is meant for task scheduler style environments - all it does it wrap the main script with a way of capturing all the output to a log.  

If that makes no sense - you don't need it - just use the main script `Invoke-EodhdSymbolExport.ps1`

```powershell
.\Run-EodhdSnapshot.ps1
```

Or run the exporter directly:

```powershell
.\Invoke-EodhdSymbolExport.ps1
```

Both commands return `0` on success and non-zero on failure.

To list available exchanges from EODHD (on demand, no symbol export):

```powershell
.\Invoke-EodhdSymbolExport.ps1 -ListExchanges
```

This uses your configured token, calls `exchanges-list`, and outputs exchange objects. When run directly, PowerShell will display them in its default table view, and you can also filter or reformat them in the pipeline.

Example:

```powershell
.\Invoke-EodhdSymbolExport.ps1 -ListExchanges |
    Where-Object Code -in @('SW', 'F') |
    Format-List *
```

## Parameters

`Invoke-EodhdSymbolExport.ps1` supports these parameters:

- `-ConfigPath` - Use a specific config file path.
  - Example:

```powershell
.\Invoke-EodhdSymbolExport.ps1 -ConfigPath .\eodhd-config.json
```

- `-ListExchanges` - List exchanges from EODHD without exporting symbol files.
  - Example:

```powershell
.\Invoke-EodhdSymbolExport.ps1 -ListExchanges
```

- `-AllExchanges` - Ignore `config.exchanges` and export all available exchanges.
  - Example:

```powershell
.\Invoke-EodhdSymbolExport.ps1 -AllExchanges
```

## Full history downloader (`DownloadSymbolHistory.cs`)

`DownloadSymbolHistory.cs` is a single-file .NET app that downloads full EOD history for one or more symbols and writes RealTest-compatible CSV files into `data/`.

It reads `EODHD_API_TOKEN` from `.env` in this folder, or from the process environment if the key is not present in `.env`.

Example using direct symbol arguments:

```powershell
dotnet run .\DownloadSymbolHistory.cs -- HPRD.SW GBRE.SW TRET.SW
```

Example using a bulk symbol file:

```powershell
dotnet run .\DownloadSymbolHistory.cs -- --symbol-file .\symbols.txt
```

Example mixing a symbol file with extra symbols on the command line:

```powershell
dotnet run .\DownloadSymbolHistory.cs -- --symbol-file .\symbols.txt SRECHA.SW
```

The `--symbol-file` format is flexible:

- one symbol per line is supported
- comma-separated symbols are supported
- whitespace-separated symbols are supported
- blank lines are ignored
- lines beginning with `#` are ignored

Example `symbols.txt`:

```text
# Foreign property
HPRD.SW
GBRE.SW
TRET.SW

# Swiss property
SRECHA.SW
```

### Output format

The downloader writes:

- `data/<SYMBOL>.csv` - one file per symbol in RealTest multi-file CSV import format
- `data/symbols-rt.txt` - one symbol per line for use in `IncludeList`
- `data/import-example.txt` - sample RealTest `Import:` block

Each per-symbol CSV file contains:

```text
Date,Open,High,Low,Close,Volume,AdjClose
```

This is intended for `DataSource: CSV` with `DataPath` and `CSVFields`, not `DataSource: EODHD`.

Example RealTest import:

```text
Import:
	DataSource:	CSV
	DataPath:	?scriptpath?\data
	IncludeList:	?scriptpath?\data\symbols-rt.txt
	CSVFields:	Date,Open,High,Low,Close,Volume,AdjClose
	SaveAs:	imported_from_eodhd_csv.rtd
```

### Rate limiting

The downloader respects EODHD retry and rate-limit signals:

- honors `Retry-After` when present
- retries `429`, `408`, and `5xx` responses
- watches `X-RateLimit-Remaining` and `X-RateLimit-Limit` to back off when close to the limit

## Transcript Logging (Wrapper Script)

`Run-EodhdSnapshot.ps1` uses PowerShell transcript logging:

- Starts logging with `Start-Transcript`
- Stops and closes the log with `Stop-Transcript` in a `finally` block

This creates a run-level transcript file in `logs/`:

- `eodhd-run-<timestamp>.transcript.log`

Why this is useful:

- Captures host output and errors from scheduled runs
- Makes troubleshooting easier when Task Scheduler runs unattended
- Ensures the transcript is closed cleanly even if the export fails

## Output Files

For each exchange (example `SW`):

- `output/SW-symbols-rt.txt` - import section ready symbols (`CODE.EXCHANGE` format by default), put this in an IncludeList statement in your RTS script.
- `output/SW-symbols-full.json` - the full JSON data returned by EODHD.
- `output/SW-syminfo-rt.csv` - Real Test specific symbol info with `Symbol,Exchange,Name,Currency` (`Symbol` without exchange suffix, `Exchange` mapped from the first `fallback\OrderClerkExchanges.csv` row where column 3 matches EODHD `CountryISO2`).

Notes:

- Files ending with `-symbols-rt.txt` are intended for RealTest import use.
- The exporter always reads `fallback\OrderClerkExchanges.csv` for country → exchange acronym mapping.
- After an export run, if `C:\OrderClerk\OrderClerkExchanges.csv` exists and has more lines or a larger file size than the bundled CSV, the exporter logs a warning and emits `Write-Warning` so you can refresh `fallback\OrderClerkExchanges.csv` if needed.
- If that CSV has no `CountryISO2` match for an exported exchange, the exporter warns and leaves `Exchange` set to the original EODHD exchange code.

OrderClerk mapping rationale (Marsten Parker, 12 March 2026):

> "All that matters is that when OC is comparing an IB position list record with an OC position (derived from trade list) in the reconcile code it can say “same symbol, same country”. This works e.g. in the US where RT sets all the order exchange fields to SMART/AMEX while IB returns the actual exchange (e.g. Nasdaq). The mapping still works. So you could get by with just looking up EODHD’s CountryISO2 value in column 3 and whichever row is found first, use that exchange acronym in your syminfo.csv."

Run-health outputs for dashboard ingestion:

- `output/last-run.json`
- `output/run-health-summary.csv`

## General

- Token sources are strictly:
  1. `.env` key `EODHD_API_TOKEN`
  2. environment variable `EODHD_API_TOKEN`
- `.env` parser supports standard `KEY=value`, quoted values, and `export KEY=value`.
- Exporter writes a per-run exporter log:
  - `logs/eodhd-export-<timestamp>.log`
- `last-run.json` includes per-exchange metadata including output file paths and failure details.
- In `-ListExchanges` mode, EODHD exchange entries are normalized before display (handles array-shaped fields from upstream API).

## Task Scheduler

Use this command as the task action:

```text
powershell.exe -ExecutionPolicy Bypass -File "C:\path\to\eodhd\Run-EodhdSnapshot.ps1"
```

If you keep the token in an environment variable, run the task under a user account that has that variable defined.

## Symbol validation performance (`Invoke-EodhdSymbolValidation.ps1`)

Validation compares your listing file to `output/*-symbols-full.json` only. Re-run the exporter after editing `fallback\OrderClerkExchanges.csv` if you need syminfo / exchange tokens to match the updated mapping.

Most time is spent reading every `*-symbols-full.json` under `output/` and building in-memory indexes. The script requires **PowerShell 7+** and streams each file with `System.Text.Json` `Utf8JsonReader` (only `Code` / `Currency` per row), avoiding `ConvertFrom-Json` and per-row PowerShell objects.

- **Profile** — Run `.\Invoke-EodhdSymbolValidation.ps1 -ProfileTimings` to print per-phase timings and the slowest payload files.

## Candidate symbol validation (`Eodhd-CandidateSymbolValidation.ps1`)

Use `Eodhd-CandidateSymbolValidation.ps1` when you want to validate a strategy candidate universe against the exported EODHD listing snapshots and then prove the shared history depth supported by the full set.

The workflow answers:

- which candidate symbols exist in the exported listing snapshots
- which of those candidates match the required currency
- which exchange-qualified symbol will be used for history download
- what the first and last available bar dates are for each valid symbol
- what shared start date the full validated set supports

Input format:

```text
USA core S&P 500 (USA_CORE_SPX, USD):
CSSPX

Swiss real estate funds (SWISS_RE_FUNDS, CHF):
SRECHA, SRFCHA
```

Header format must be:

```text
description (rt-list-name, CUR):
```

Example:

```powershell
pwsh -File .\Eodhd-CandidateSymbolValidation.ps1 `
  -InputFilePath .\analysis\candidate-symbol-validation\sample-vz-idea\candidate_input.txt `
  -AnalysisDirectory .\analysis\candidate-symbol-validation\sample-vz-idea
```

Outputs written into the analysis directory include:

- `candidate_validation.csv`
- `history_symbols.txt`
- `history_summary.csv`
- `candidate_results.csv`
- `summary.md`
- `history-data\*.csv`

Sample analysis input:

- `analysis/candidate-symbol-validation/sample-vz-idea/candidate_input.txt`

## Files

- `fallback\OrderClerkExchanges.csv` - country (column 3) → exchange acronym mapping for syminfo / listing exchange tokens.
- `eodhd-config.json` - exchange selection and runtime settings.
- `Eodhd-CandidateSymbolValidation.ps1` - validate candidate universes and compute shared supported history start date.
- `Invoke-EodhdSymbolExport.ps1` - main exporter.
- `Invoke-EodhdSymbolValidation.ps1` - validate symbol lists against exported `*-symbols-full.json` payloads.
- `Run-EodhdSnapshot.ps1` - scheduler-friendly wrapper script.
- `output/` - generated snapshot outputs (created at runtime).
- `logs/` - run logs and transcripts (created at runtime).

