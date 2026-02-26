# EODHD Export 

This folder contains a standalone PowerShell process to export exchange symbols from EODHD for RT import files.

## Quickstart (Non-Technical)

Follow these steps in order.

1. Get an EODHD API key
   - Go to the EODHD website and create an account.
   - In your account dashboard, copy your API key.

2. Copy the `.env.example` to `.env` and paste in your EODHD API key   
   - Open `.env` in a text editor.
   - Make sure you have exactly one line in this format:

```text
EODHD_API_TOKEN=your-real-api-key-goes-here
```

3. Make sure that the file is called `.env` - there is already a .gitignore file that EXCLUDES this from source control.

4. Test that your key works (safe test, no symbol export)
   - Open PowerShell in this folder and run:

```powershell
pwsh .\Invoke-EodhdSymbolExport.ps1 -ListExchanges
```

   - Expected result: one exchange per line (Code, Name, Country, Currency).

Congratulations - the system works - now onto the configuration.

## Configuration

Edit `eodhd-config.json`:

- `exchanges` controls which exchange lists are pulled.
  - `code` can be a single value or a list.
  - `enabled` is no longer used.
- `currencies` is an optional list of currency codes (default: empty list `[]`).
  - Purpose: choose exchanges by the exchange trading currency instead of hardcoding exchange codes.
  - Example: `["CHF","EUR"]`.
- `countries` is an optional list of country names (default: empty list `[]`).
  - Purpose: choose exchanges by country (for example all exchanges in Germany).
  - Example: `["Germany"]`.
- Selector behavior:
  - If either `currencies` or `countries` has values, the script calls `exchanges-list` and selects exchanges matching either selector.
  - In selector mode, `exchanges` is ignored.
  - Output is still per exchange (one file per matched exchange).
- All instrument types returned by EODHD are included in the export (no type filtering).
- `outputDirectory` and `logsDirectory` can be relative or absolute paths.

Example:

```json
"exchanges": [
  { "code": ["SW", "XETRA"] }
]
```

Currency-driven selection example:

```json
"currencies": ["CHF", "EUR"]
```

Country-driven selection example:

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

From this folder:

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

This uses your configured token, calls `exchanges-list`, and prints one exchange per line (`Code | Name | Country | Currency`).

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

For each enabled exchange (example `SW`):

- `output/SW-symbols-rt.txt` - import-ready symbols (`CODE.EXCHANGE` format by default).
- `output/SW-symbols-full.json` - filtered symbol payload for diagnostics.

Notes:

- Files ending with `-symbols-rt.txt` are intended for RealTest import use.

Run-health outputs for dashboard ingestion:

- `output/last-run.json`
- `output/run-health-summary.csv`

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
