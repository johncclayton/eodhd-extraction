# spike-exch-liq (EODHD)

Compare **daily EOD volume** across multiple EODHD listings for each strategy symbol. Replaces the former IB/TWS `spike-for-exch-liq` tool (removed from `rt-automation`).

## Setup

```powershell
cd c:\Users\johnc\src\trading\eodhd-extraction\spike-exch-liq
python -m pip install -r requirements.txt
```

Requires `EODHD_API_TOKEN` in `eodhd-extraction\.env` (same as other scripts in this repo).

For **IB primary-exchange enrichment** (on by default), paper or live TWS must be running and `rt-automation\bin\fetch-ib-min-tick.exe` must exist (build via `rt-automation\Tooling\BuildAndDeploy-Tooling.ps1`). Skip IB with `--no-ib-enrich` if TWS is offline.

## Run

### From operator config (recommended)

`Run-ExchLiqSpike.ps1` reads `EodhdSymbolExtractionRoots` from operator `config.json` and runs **one spike per entry**. Each entry’s `IBExchanges` is passed through to `--exchanges` and `--ib-exchanges` (spike maps IB codes to EODHD suffixes). RTS files come from the same `StrategyPaths` / `FilePatterns` / `AlwaysAddedFiles` resolution as symbol export.

```powershell
cd c:\Users\johnc\src\trading\eodhd-extraction
.\Run-ExchLiqSpike.ps1 -OperatorConfigPath ..\paper-john\config.json
```

Outputs: `analysis\exch-liq-spike\entry-0\`, `entry-1\`, … (index matches the array in `config.json`).

```powershell
.\Run-ExchLiqSpike.ps1 -OperatorConfigPath ..\paper-john\config.json -MaxSymbols 5
.\Run-ExchLiqSpike.ps1 -OperatorConfigPath ..\paper-john\config.json -EntryIndex 1
.\Run-ExchLiqSpike.ps1 -OperatorConfigPath ..\paper-john\config.json -DryRun
```

### Manual single run

Run from the **`eodhd-extraction` repo root** (the script locates `.env` from there or any parent):

```powershell
cd c:\Users\johnc\src\trading\eodhd-extraction
```

#### Quick smoke (5 symbols, paper-john EURO strategy)

```powershell
python spike-exch-liq\spike_exch_liq.py `
  --strategy-path ..\paper-john\Strategies\EURO\EURO_DAX_long_mean_rev_sin_LR_v1.0.rts `
  --exchanges XETRA,F,STU,PA,MC,AS,HE `
  --max-symbols 5 `
  --output-json analysis\exch-liq-spike.json `
  --output-csv analysis\exch-liq-spike-summary.csv `
  --output-html analysis\exch-liq-spike.html
```

Then open `analysis\exch-liq-spike.html` in a browser.

### Full strategy (all symbols from one RTS)

Omit `--max-symbols` (default `0` = no limit):

```powershell
python spike-exch-liq\spike_exch_liq.py `
  --strategy-path ..\paper-john\Strategies\EURO\EURO_DAX_long_mean_rev_sin_LR_v1.0.rts `
  --exchanges XETRA,F,STU,PA,MC,AS,HE `
  --output-json analysis\exch-liq-spike.json `
  --output-csv analysis\exch-liq-spike-summary.csv `
  --output-html analysis\exch-liq-spike.html
```

### All strategies in a folder

Pass a directory; every `*.rts` under it is scanned for `DataSource: EODHD` / `IncludeList:` entries:

```powershell
python spike-exch-liq\spike_exch_liq.py `
  --strategy-path ..\paper-john\Strategies\EURO `
  --exchanges XETRA,F,STU,PA,MC,AS,HE `
  --output-html analysis\exch-liq-spike.html
```

### Ad-hoc symbol list (no RTS)

Comma-separated tickers or a path to a text file (one symbol per line; `#` comments allowed):

```powershell
python spike-exch-liq\spike_exch_liq.py `
  --symbols "1COV,ADS,SAP" `
  --exchanges XETRA,F,STU,PA,MC,AS,HE `
  --output-html analysis\exch-liq-spike.html
```

IncludeList-style remaps work here too, e.g. `--symbols "1COV.F>1COV,PPFB.XETRA>EGLN"`.

Combine `--strategy-path` and `--symbols`; duplicates are merged (strategy listing wins when present).

### EODHD only (no TWS)

```powershell
python spike-exch-liq\spike_exch_liq.py `
  --strategy-path ..\paper-john\Strategies\EURO\EURO_DAX_long_mean_rev_sin_LR_v1.0.rts `
  --max-symbols 5 `
  --no-ib-enrich `
  --output-html analysis\exch-liq-spike.html
```

### Live TWS (port 7496)

```powershell
python spike-exch-liq\spike_exch_liq.py `
  --strategy-path ..\live-john\Strategies\EURO\EURO_DAX_long_mean_rev_sin_LR_v1.0.rts `
  --ib-port 7496 `
  --output-html analysis\exch-liq-spike.html
```

### Useful flags

| Flag | Default | Purpose |
|------|---------|---------|
| `--lookback-days` | `90` | Calendar days of EOD history |
| `--max-symbols` | `0` | Cap symbol count (`0` = all) |
| `--request-delay-ms` | `250` | Pause between EODHD API calls |
| `--no-cache` | (cache on) | Force fresh EODHD fetches |
| `--verbose` / `-v` | off | Log each EODHD symbol fetch |
| `--no-ib-enrich` | IB on | Skip `fetch-ib-min-tick` |
| `--ib-port` | `7497` | TWS port (`7496` live) |
| `--ib-exchanges` | `FWB,XETRA,IBIS` | Passed to `fetch-ib-min-tick`; see note below |
| `--fetch-ib-min-tick` | auto | Override path to `fetch-ib-min-tick.exe` |

All CLI options: `python spike-exch-liq\spike_exch_liq.py --help`

### What you should see

1. Repo root, symbol count, exchange list, lookback dates, cache path.
2. Per-symbol lines: `SYMBOL: OK strategy=… best=…` (best = highest avg daily EOD volume).
3. Cache hit/miss counts, then optional IB enrichment (TWS connect + `ibPrimary=` per symbol).
4. Paths to JSON, CSV, and HTML under `--output-*`.
5. Summary counts: symbols with data, strategy listing vs IB primary vs highest-volume venue.

Default **`--lookback-days` is 90**. Responses are cached under `.cache/spike-exch-liq-eod` keyed by symbol and date range, so longer lookbacks reuse prior fetches when dates overlap.

The HTML report: tickers on the left (strategy listing, **IB primary**, highest EODHD volume), **3D volume-over-time** chart on the right.

**IB enrichment note:** `--ib-exchanges` defaults to `FWB,XETRA,IBIS`. Only the **first** entry is sent as the contract-request `PrimaryExch` hint; the JSON/HTML field **`ib_primary_exchange`** is what IB **returns** on `reqContractDetails`. Putting `XETRA` first often breaks German symbols (IB error 200).

## Exchange codes

CLI accepts **IB-style aliases** (mapped to EODHD suffixes via `IB_TO_EODHD_EXCHANGE` in `spike_exch_liq.py`):

| IB / operator | EODHD | Notes |
|---------------|-------|-------|
| IBIS, IBIS2 | XETRA | IB Xetra boards (equities / ETF segment) |
| XETRA | XETRA | EODHD label; IB often reports IBIS |
| FWB | F | Frankfurt floor |
| SWB | STU | Stuttgart |
| GETTEX | MU | Börse München Gettex |
| VSE | VI | Vienna |
| SBF | PA | Euronext Paris |
| AEB | AS | Euronext Amsterdam |
| ENEXT.BE | BR | Euronext Brussels |
| BVME, BVME.ETF | MC | Borsa Italiana → EODHD Madrid suffix |
| BM | MC | Bolsa de Madrid |
| EBS | SW | SIX Swiss |
| LSE, LSEETF | LSE | UK cash / ETF segment |
| HEX | HE | Nasdaq Helsinki |
| BVL | LS | Euronext Lisbon |

Default `--exchanges` is `XETRA,F,STU,PA,MC,AS,HE` (EURO multi-market). Add venues from `2026.02.25_European_Stocks_validation.txt` when needed (`MU`, `BE`, `DU`, `VI`, …).

**Non-1:1 / unmapped IB codes**

- **IBIS → XETRA**, not VI. **VSE → VI** (Austria). Do not confuse IBIS with Vienna.
- **GETTEX → MU** (Munich). EODHD **DU** is Düsseldorf; no common IB alias in our map.
- **MTFs / internalisers** (`CHIXDE`, `TGATE`, `TRQXDE`, `BATEDE`, `DXEDE`, `EUIBSI`, …) have no EODHD EOD suffix — they pass through unchanged and usually return `NOT_FOUND` unless you add a matching `--exchanges` EODHD code manually.
- **SMART** is IB routing, not an EODHD listing.

## IncludeList remaps

Entries like `PPFB.XETRA>EGLN` use the **left-hand EODHD code** (`PPFB`) for `/eod/` requests across all `--exchanges`, not the RT symbol (`EGLN`). The report keeps both: `symbol` (RT) and `eodhd_query_code` (API ticker).

## Outputs

| File | Content |
|------|---------|
| `exch-liq-spike.json` | Full report: per-symbol strategy listing, per-exchange daily bars + min/avg/max/total |
| `exch-liq-spike-summary.csv` | Flat Symbol × Exchange summary |
| `exch-liq-spike.html` | Self-contained interactive page (Plotly CDN + embedded JSON) |

JSON daily bars are structured for downstream Python (`numpy` / `pandas` / `plotly`) if you want custom charts beyond the bundled HTML.

## Notes

- Strategy `IncludeList` entries like `1COV.F>1COV` record **strategy listing** (`F`) for comparison vs highest-volume venue. Remapped codes (`PPFB.XETRA>EGLN`) query **`PPFB.*`** on EODHD.
- Missing listings return `NOT_FOUND` (no bar data); other exchanges for the same symbol still contribute.
- `--request-delay-ms` (default 250) spaces EODHD calls; increase if you hit rate limits.
