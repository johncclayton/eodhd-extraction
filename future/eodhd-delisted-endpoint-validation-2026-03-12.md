# EODHD Delisted Symbols Validation (2026-03-12)

## Goal
Validate whether the Exchanges API returns delisted tickers when `delisted=1` is added to:

`/api/exchange-symbol-list/{exchange_code}?api_token={token}&fmt=json&delisted=1`

## Validation Setup
- Exchange tested: `US`
- Endpoints compared:
  - `https://eodhd.com/api/exchange-symbol-list/US?api_token={token}&fmt=json`
  - `https://eodhd.com/api/exchange-symbol-list/US?api_token={token}&fmt=json&delisted=1`
- Token source: local `.env` (`EODHD_API_TOKEN`) used during live test (not stored here).

## Key Results
- Without `delisted=1`: **49,217** symbols
- With `delisted=1`: **57,062** symbols
- Active tickers like `AAPL` and `QQQ` are present in the normal endpoint and absent from the `delisted=1` endpoint.
- Practical behavior observed: `delisted=1` returns a **delisted universe view**, not an active+delisted merged set.

## Delisted Payload Shape
Fields returned for `delisted=1` rows:
- `Code`
- `Name`
- `Country`
- `Exchange`
- `Currency`
- `Type`
- `Isin`

Notably absent:
- No `Delisted` boolean/flag field
- No explicit delisting date field

## Sample Rows From `delisted=1`
Representative delisted records (fund/ETF/stock):

```json
[
  {
    "Code": "AAIT",
    "Name": "iShares MSCI All Country Asia Info Tech",
    "Type": "ETF",
    "Exchange": "NASDAQ",
    "Currency": "USD",
    "Isin": null
  },
  {
    "Code": "AAMEFX",
    "Name": "AAMEFX",
    "Type": "Mutual Fund",
    "Exchange": "NMFQS",
    "Currency": "USD",
    "Isin": null
  },
  {
    "Code": "AAADX",
    "Name": "ALPINE RISING DIVIDEND FUND CLASS A",
    "Type": "FUND",
    "Exchange": "NMFQS",
    "Currency": "USD",
    "Isin": "US0030224499"
  },
  {
    "Code": "AAAB",
    "Name": "Admiralty Bancorp Inc",
    "Type": "Common Stock",
    "Exchange": "NASDAQ",
    "Currency": "USD",
    "Isin": null
  }
]
```

## Do We Know *When* It Was Delisted?
From `exchange-symbol-list ... &delisted=1`, **no**.

There is no delisting timestamp in this payload.  
Best available proxy is the last available EOD candle date for the symbol.

Example proxy check:
- Symbol: `AAAB.US`
- Latest available historical bar date observed: `2003-01-29`
- Interpretation: use as `last_trade_date` proxy, not guaranteed legal/effective delisting date.

## Type Distribution Snapshot (Delisted US Set)
Top types seen in the `delisted=1` result:
- Common Stock: 31,677
- FUND: 18,435
- Mutual Fund: 2,748
- ETF: 2,696
- Preferred Stock: 1,212

## Suggested Next Step
If needed for downstream modeling/prompting, extend export pipeline with:
- `is_delisted_source = true` (source-level flag from endpoint variant used)
- `last_trade_date` (derived from historical endpoint, per symbol)
- `last_trade_date_is_proxy = true` (explicit quality marker)
