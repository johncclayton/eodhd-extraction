# EODHD Export

This folder contains a standalone method to export exchange symbols from EODHD for use with [Real Test Trading software](https://mhptrading.com/)  The basic idea is to remove the need to figure out which symbols are available at which exchanges.

Before you start, you MUST have Order Clerk also installed on this computer - as the script creates symbol files that require access to the OrderClerkExchanges.csv file in the Order Clerk installation.

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
- `output/SW-syminfo-rt.csv` - Real Test specific symbol info with `Symbol,Exchange,Name,Currency` (`Symbol` without exchange suffix, `Exchange` mapped from the first `OrderClerkExchanges.csv` row where column 3 matches EODHD `CountryISO2`).

Notes:

- Files ending with `-symbols-rt.txt` are intended for RealTest import use.
- OrderClerk mapping file resolution order:
  1. `C:\OrderClerk\OrderClerkExchanges.csv`
  2. `fallback\OrderClerkExchanges.csv` (repo fallback)
- If the primary `C:\OrderClerk\OrderClerkExchanges.csv` file is missing, the exporter logs a loud warning and uses the fallback file.
- If `C:\OrderClerk\OrderClerkExchanges.csv` has no `CountryISO2` match for an exported exchange, the exporter warns and leaves `Exchange` set to the original EODHD exchange code.

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

## Files

- `eodhd-config.json` - exchange selection and runtime settings.
- `Invoke-EodhdSymbolExport.ps1` - main exporter.
- `Run-EodhdSnapshot.ps1` - scheduler-friendly wrapper script.
- `output/` - generated snapshot outputs (created at runtime).
- `logs/` - run logs and transcripts (created at runtime).

