#!/usr/bin/env python3
"""EODHD multi-listing volume spike with interactive 3D HTML report."""

from __future__ import annotations

import argparse
import csv
import json
import os
import random
import re
import subprocess
import sys
import tempfile
import time
from dataclasses import asdict, dataclass, field
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from urllib.parse import quote

import plotly.graph_objects as go
import requests

DATA_SOURCE_RX = re.compile(r"^DataSource:\s*(\S+)", re.IGNORECASE)
INCLUDE_LIST_RX = re.compile(r"^IncludeList:\s*(.+)$", re.IGNORECASE)
NAMED_LIST_RX = re.compile(r"\{[^}]*\}")

# IB PrimaryExch / ValidExchanges labels -> EODHD exchange suffixes (symbol.{suffix}).
# Unlisted IB codes pass through unchanged (see ib_exchange_to_eodhd / map_exchanges).
IB_TO_EODHD_EXCHANGE = {
    # Germany — Xetra / Deutsche Börse cash equity
    "XETRA": "XETRA",
    "IBIS": "XETRA",
    "IBIS2": "XETRA",
    "FWB": "F",
    "F": "F",
    "SWB": "STU",
    "STU": "STU",
    "GETTEX": "MU",  # Börse München Gettex (not Düsseldorf DU)
    # Austria
    "VSE": "VI",
    # France / Euronext Paris
    "SBF": "PA",
    # Netherlands / Euronext Amsterdam
    "AEB": "AS",
    # Belgium / Euronext Brussels
    "ENEXT.BE": "BR",
    "ENEXTBE": "BR",
    # Italy — Borsa Italiana (Milan listings on EODHD MC)
    "BVME": "MC",
    "BVME.ETF": "MC",
    # Spain — Bolsa de Madrid
    "BM": "MC",
    # Switzerland — SIX
    "EBS": "SW",
    # UK — LSE (ETF segment shares the cash listing suffix)
    "LSE": "LSE",
    "LSEETF": "LSE",
    "CHIXJ": "LSE",
    "BATEEU": "LSE",
    "ICEEU": "LSE",
    # Finland — Nasdaq Helsinki
    "HEX": "HE",
    # Portugal — Euronext Lisbon (EODHD LS)
    "BVL": "LS",
    # EODHD-native suffixes also used as IB/strategy labels (identity)
    "PA": "PA",
    "AS": "AS",
    "MC": "MC",
    "HE": "HE",
    "SW": "SW",
    "VI": "VI",
    "BR": "BR",
    "BE": "BE",
    "DU": "DU",
    "HA": "HA",
    "HM": "HM",
    "MU": "MU",
    "LS": "LS",
}


@dataclass
class StrategySymbol:
    base: str
    strategy_listing: str | None = None
    strategy_eodhd_symbol: str | None = None


@dataclass
class DailyBar:
    date: str
    volume: float


@dataclass
class ExchangeVolumeStats:
    exchange: str
    eodhd_symbol: str
    status: str
    note: str = ""
    bar_count: int = 0
    min_daily_volume: float = 0.0
    avg_daily_volume: float = 0.0
    max_daily_volume: float = 0.0
    total_volume: float = 0.0
    daily_bars: list[DailyBar] = field(default_factory=list)


@dataclass
class SymbolLiquidityResult:
    symbol: str
    strategy_listing: str | None
    strategy_eodhd_symbol: str | None
    queried_exchanges: list[str]
    status: str
    eodhd_query_code: str | None = None
    note: str = ""
    per_exchange: list[ExchangeVolumeStats] = field(default_factory=list)
    highest_avg_volume_exchange: str | None = None
    highest_avg_volume: float = 0.0
    strategy_listing_is_highest_avg: bool = False
    strategy_listing_avg_rank: int | None = None
    highest_total_volume_exchange: str | None = None
    highest_total_volume: float = 0.0
    strategy_listing_is_highest_total: bool = False
    ib_primary_exchange: str | None = None
    ib_valid_exchanges: str | None = None
    ib_status: str | None = None
    ib_primary_is_highest_avg: bool = False
    ib_primary_avg_rank: int | None = None


def find_repo_root(start: Path) -> Path:
    current = start.resolve()
    while True:
        if (current / ".env").exists() or (current / "eodhd-config.json").exists():
            return current
        if current.parent == current:
            break
        current = current.parent
    raise RuntimeError(f"Could not find eodhd-extraction root starting from {start}")


def load_api_token(repo_root: Path) -> str:
    env_path = repo_root / ".env"
    if env_path.exists():
        for raw_line in env_path.read_text(encoding="utf-8").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[7:].strip()
            if "=" not in line:
                continue
            name, value = line.split("=", 1)
            if name.strip() != "EODHD_API_TOKEN":
                continue
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            if value:
                return value

    from_env = os.environ.get("EODHD_API_TOKEN", "").strip()
    if from_env:
        return from_env
    raise RuntimeError("Missing EODHD_API_TOKEN in .env or environment")


def normalize_base_symbol(token: str) -> tuple[str, str | None, str | None]:
    tok = token.strip()
    if not tok:
        return "", None, None

    strategy_eodhd_symbol: str | None = None
    if ">" in tok:
        left, right = tok.rsplit(">", 1)
        strategy_eodhd_symbol = left.strip()
        tok = right.strip()
    else:
        strategy_eodhd_symbol = None

    if tok.upper().endswith(".SW"):
        tok = tok[:-3]

    brace = tok.find("{")
    if brace >= 0:
        tok = tok[:brace].strip()

    strategy_listing: str | None = None
    if strategy_eodhd_symbol and "." in strategy_eodhd_symbol:
        strategy_listing = strategy_eodhd_symbol.rsplit(".", 1)[1].upper()

    return tok.upper(), strategy_listing, strategy_eodhd_symbol


def eodhd_ticker_code(sym: StrategySymbol) -> str:
    """EODHD API code: left side of IncludeList remap (PPFB.XETRA>EGLN → PPFB), else RT base."""
    if sym.strategy_eodhd_symbol and "." in sym.strategy_eodhd_symbol:
        return sym.strategy_eodhd_symbol.rsplit(".", 1)[0].strip().upper()
    return sym.base


def load_symbols_from_rts(path: Path) -> dict[str, StrategySymbol]:
    symbols: dict[str, StrategySymbol] = {}
    current_source = ""

    for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("//"):
            continue

        ds_match = DATA_SOURCE_RX.match(line)
        if ds_match:
            current_source = ds_match.group(1).strip().upper()
            continue

        il_match = INCLUDE_LIST_RX.match(line)
        if not il_match or current_source != "EODHD":
            continue

        rhs = NAMED_LIST_RX.sub("", il_match.group(1))
        comment_idx = rhs.find("//")
        if comment_idx >= 0:
            rhs = rhs[:comment_idx]

        for raw_tok in rhs.split(","):
            base, listing, eodhd_symbol = normalize_base_symbol(raw_tok)
            if not base:
                continue
            existing = symbols.get(base)
            if existing is None:
                symbols[base] = StrategySymbol(base, listing, eodhd_symbol)
            elif listing and not existing.strategy_listing:
                existing.strategy_listing = listing
                existing.strategy_eodhd_symbol = eodhd_symbol

    return symbols


def load_symbols(strategy_path: str | None, symbols_input: str | None, max_symbols: int) -> list[StrategySymbol]:
    seen: dict[str, StrategySymbol] = {}

    if strategy_path:
        path = Path(strategy_path)
        if path.is_file():
            seen.update(load_symbols_from_rts(path))
        elif path.is_dir():
            for rts_file in sorted(path.rglob("*.rts")):
                seen.update(load_symbols_from_rts(rts_file))
        else:
            raise FileNotFoundError(f"Strategy path not found: {path}")

    if symbols_input:
        content = Path(symbols_input).read_text(encoding="utf-8") if Path(symbols_input).exists() else symbols_input
        for raw_line in content.splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            for raw_tok in line.split(","):
                base, listing, eodhd_symbol = normalize_base_symbol(raw_tok)
                if base and base not in seen:
                    seen[base] = StrategySymbol(base, listing, eodhd_symbol)

    ordered = sorted(seen.values(), key=lambda s: s.base)
    if max_symbols > 0:
        ordered = ordered[:max_symbols]
    return ordered


def map_exchanges(raw_exchanges: list[str]) -> list[str]:
    mapped: list[str] = []
    seen: set[str] = set()
    for raw in raw_exchanges:
        key = raw.strip().upper()
        if not key:
            continue
        eodhd = IB_TO_EODHD_EXCHANGE.get(key, key)
        if eodhd not in seen:
            seen.add(eodhd)
            mapped.append(eodhd)
    return mapped


def ib_exchange_to_eodhd(ib_exchange: str) -> str:
    return IB_TO_EODHD_EXCHANGE.get(ib_exchange.strip().upper(), ib_exchange.strip().upper())


def pick_json_field(obj: dict[str, Any], *names: str) -> Any:
    for name in names:
        if name in obj:
            return obj[name]
    lowered = {str(k).lower(): v for k, v in obj.items()}
    for name in names:
        value = lowered.get(name.lower())
        if value is not None:
            return value
    return None


def resolve_fetch_ib_min_tick_exe(explicit: str | None) -> Path | None:
    if explicit:
        path = Path(explicit)
        return path if path.exists() else None

    repo_root = find_repo_root(Path(__file__).resolve().parent)
    candidates = [
        repo_root.parent / "rt-automation" / "bin" / "fetch-ib-min-tick.exe",
        Path.cwd() / ".." / "rt-automation" / "bin" / "fetch-ib-min-tick.exe",
    ]
    for candidate in candidates:
        resolved = candidate.resolve()
        if resolved.exists():
            return resolved
    return None


def fetch_ib_primary_map(
    symbols: list[StrategySymbol],
    *,
    exe_path: Path,
    ib_exchanges: str,
    currency: str,
    host: str,
    port: int,
    verbose: bool,
) -> dict[str, dict[str, str | None]]:
    symbol_file = tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False, encoding="utf-8", newline="\n")
    json_file = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8")
    symbol_file_path = Path(symbol_file.name)
    json_file_path = Path(json_file.name)
    symbol_file.close()
    json_file.close()

    try:
        symbol_file_path.write_text(
            "\n".join(sym.base for sym in symbols) + "\n",
            encoding="utf-8",
        )
        cmd = [
            str(exe_path),
            "--symbols",
            str(symbol_file_path),
            "--exchanges",
            ib_exchanges,
            "--currency",
            currency,
            "--host",
            host,
            "--port",
            str(port),
            "--contract-details-only",
            "--output-json",
            str(json_file_path),
        ]
        if verbose:
            print("IB:", " ".join(cmd), flush=True)

        completed = subprocess.run(cmd, capture_output=True, text=True, check=False)
        if completed.stdout.strip():
            print(completed.stdout.rstrip())
        if completed.returncode != 0:
            err = completed.stderr.strip() or completed.stdout.strip() or f"exit {completed.returncode}"
            raise RuntimeError(f"fetch-ib-min-tick failed: {err}")

        payload = json.loads(json_file_path.read_text(encoding="utf-8"))
        rows = pick_json_field(payload, "Symbols", "symbols") or []
        result: dict[str, dict[str, str | None]] = {}
        for row in rows:
            symbol = pick_json_field(row, "Symbol", "symbol")
            if not symbol:
                continue
            result[str(symbol).upper()] = {
                "primary": pick_json_field(row, "IbPrimaryExchange", "ibPrimaryExchange"),
                "valid": pick_json_field(row, "ValidExchanges", "validExchanges"),
                "status": pick_json_field(row, "Status", "status"),
            }
        return result
    finally:
        symbol_file_path.unlink(missing_ok=True)
        json_file_path.unlink(missing_ok=True)


def apply_ib_enrichment(
    results: list[SymbolLiquidityResult],
    ib_rows: dict[str, dict[str, str | None]],
) -> None:
    for result in results:
        row = ib_rows.get(result.symbol.upper())
        if not row:
            continue

        result.ib_primary_exchange = row.get("primary") or None
        result.ib_valid_exchanges = row.get("valid") or None
        result.ib_status = row.get("status") or None

        ok_rows = [item for item in result.per_exchange if item.status == "OK" and item.bar_count > 0]
        if not ok_rows or not result.ib_primary_exchange:
            continue

        mapped_primary = ib_exchange_to_eodhd(result.ib_primary_exchange)
        best = max(ok_rows, key=lambda item: item.avg_daily_volume)
        ranked = sorted(ok_rows, key=lambda item: (-item.avg_daily_volume, item.exchange))
        ranks = {item.exchange: idx + 1 for idx, item in enumerate(ranked)}
        result.ib_primary_is_highest_avg = mapped_primary == best.exchange
        result.ib_primary_avg_rank = ranks.get(mapped_primary)


def compute_backoff(attempt: int) -> float:
    return min(60.0, 2**attempt) + random.uniform(0.25, 1.25)


EOD_CACHE_VERSION = 1


def cache_date_key(d: date) -> str:
    """Strip non-digits from an ISO date for stable cache keys (2026-07-02 -> 20260702)."""
    return re.sub(r"[^0-9]", "", d.isoformat())


def eod_cache_file_path(cache_dir: Path, eodhd_symbol: str, start: date, end: date) -> Path:
    safe_symbol = re.sub(r"[^\w.-]", "_", eodhd_symbol)
    filename = f"{safe_symbol}__{cache_date_key(start)}__{cache_date_key(end)}.json"
    return cache_dir / filename


def load_eod_cache(
    cache_dir: Path, eodhd_symbol: str, start: date, end: date
) -> tuple[list[DailyBar], str, str] | None:
    path = eod_cache_file_path(cache_dir, eodhd_symbol, start, end)
    if not path.exists():
        return None
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if payload.get("v") != EOD_CACHE_VERSION:
        return None
    if payload.get("eodhd_symbol") != eodhd_symbol:
        return None
    if payload.get("start") != cache_date_key(start):
        return None
    if payload.get("end") != cache_date_key(end):
        return None
    status = str(payload.get("status", ""))
    note = str(payload.get("note", ""))
    bars: list[DailyBar] = []
    for row in payload.get("bars", []):
        if not isinstance(row, dict) or not row.get("date"):
            continue
        try:
            volume = float(row.get("volume") or 0)
        except (TypeError, ValueError):
            volume = 0.0
        bars.append(DailyBar(str(row["date"]), volume))
    bars.sort(key=lambda b: b.date)
    return bars, status, note


def save_eod_cache(
    cache_dir: Path,
    eodhd_symbol: str,
    start: date,
    end: date,
    bars: list[DailyBar],
    status: str,
    note: str,
) -> None:
    cache_dir.mkdir(parents=True, exist_ok=True)
    payload = {
        "v": EOD_CACHE_VERSION,
        "eodhd_symbol": eodhd_symbol,
        "start": cache_date_key(start),
        "end": cache_date_key(end),
        "status": status,
        "note": note,
        "bars": [{"date": bar.date, "volume": bar.volume} for bar in bars],
    }
    path = eod_cache_file_path(cache_dir, eodhd_symbol, start, end)
    tmp_path = path.with_suffix(".json.tmp")
    tmp_path.write_text(json.dumps(payload, separators=(",", ":")), encoding="utf-8")
    tmp_path.replace(path)


def fetch_eod_bars(
    session: requests.Session,
    api_token: str,
    eodhd_symbol: str,
    start: date,
    end: date,
    timeout: float,
) -> tuple[list[DailyBar], str, str]:
    encoded = quote(eodhd_symbol, safe="")
    url = (
        f"https://eodhd.com/api/eod/{encoded}"
        f"?api_token={quote(api_token, safe='')}"
        f"&period=d&fmt=json&from={start.isoformat()}&to={end.isoformat()}"
    )

    max_attempts = 8
    for attempt in range(1, max_attempts + 1):
        try:
            response = session.get(url, timeout=timeout)
        except requests.RequestException as exc:
            if attempt == max_attempts:
                return [], "ERROR", str(exc)
            time.sleep(compute_backoff(attempt))
            continue

        if response.status_code == 404:
            return [], "NOT_FOUND", "Symbol not found on EODHD"
        if response.status_code == 200:
            try:
                payload = response.json()
            except json.JSONDecodeError as exc:
                return [], "ERROR", f"Invalid JSON: {exc}"
            if not isinstance(payload, list):
                return [], "ERROR", "Unexpected payload (expected JSON array)"
            bars: list[DailyBar] = []
            for row in payload:
                day = row.get("date")
                volume = row.get("volume")
                if not day:
                    continue
                try:
                    vol = float(volume or 0)
                except (TypeError, ValueError):
                    vol = 0.0
                bars.append(DailyBar(str(day), vol))
            bars.sort(key=lambda b: b.date)
            if not bars:
                return [], "NO_DATA", "Empty history"
            return bars, "OK", ""

        if response.status_code in {429, 408} or response.status_code >= 500:
            if attempt == max_attempts:
                return [], "ERROR", f"HTTP {response.status_code}: {response.text[:200]}"
            retry_after = response.headers.get("Retry-After")
            delay = float(retry_after) if retry_after and retry_after.isdigit() else compute_backoff(attempt)
            time.sleep(delay)
            continue

        return [], "ERROR", f"HTTP {response.status_code}: {response.text[:200]}"

    return [], "ERROR", "Exhausted retries"


_CACHEABLE_EOD_STATUSES = frozenset({"OK", "NOT_FOUND", "NO_DATA"})


def fetch_eod_bars_cached(
    session: requests.Session,
    api_token: str,
    eodhd_symbol: str,
    start: date,
    end: date,
    timeout: float,
    cache_dir: Path | None,
    use_cache: bool,
) -> tuple[list[DailyBar], str, str, bool]:
    if use_cache and cache_dir is not None:
        cached = load_eod_cache(cache_dir, eodhd_symbol, start, end)
        if cached is not None:
            return *cached, True

    bars, status, note = fetch_eod_bars(session, api_token, eodhd_symbol, start, end, timeout)
    if use_cache and cache_dir is not None and status in _CACHEABLE_EOD_STATUSES:
        save_eod_cache(cache_dir, eodhd_symbol, start, end, bars, status, note)
    return bars, status, note, False


def summarize_exchange(exchange: str, eodhd_symbol: str, bars: list[DailyBar], status: str, note: str) -> ExchangeVolumeStats:
    if status != "OK" or not bars:
        return ExchangeVolumeStats(exchange, eodhd_symbol, status, note)

    volumes = [b.volume for b in bars]
    total = float(sum(volumes))
    return ExchangeVolumeStats(
        exchange=exchange,
        eodhd_symbol=eodhd_symbol,
        status=status,
        note=note,
        bar_count=len(bars),
        min_daily_volume=float(min(volumes)),
        avg_daily_volume=total / len(volumes),
        max_daily_volume=float(max(volumes)),
        total_volume=total,
        daily_bars=bars,
    )


def finalize_symbol_result(
    sym: StrategySymbol,
    queried_exchanges: list[str],
    per_exchange: list[ExchangeVolumeStats],
) -> SymbolLiquidityResult:
    ok_rows = [row for row in per_exchange if row.status == "OK" and row.bar_count > 0]
    result = SymbolLiquidityResult(
        symbol=sym.base,
        strategy_listing=sym.strategy_listing,
        strategy_eodhd_symbol=sym.strategy_eodhd_symbol,
        eodhd_query_code=eodhd_ticker_code(sym),
        queried_exchanges=queried_exchanges,
        status="OK" if ok_rows else "NO_DATA",
        note="" if ok_rows else "No exchange returned volume bars",
        per_exchange=per_exchange,
    )

    if not ok_rows:
        return result

    best_avg = max(ok_rows, key=lambda r: r.avg_daily_volume)
    best_total = max(ok_rows, key=lambda r: r.total_volume)
    result.highest_avg_volume_exchange = best_avg.exchange
    result.highest_avg_volume = best_avg.avg_daily_volume
    result.highest_total_volume_exchange = best_total.exchange
    result.highest_total_volume = best_total.total_volume

    if sym.strategy_listing:
        ranked = sorted(ok_rows, key=lambda r: (-r.avg_daily_volume, r.exchange))
        ranks = {row.exchange: idx + 1 for idx, row in enumerate(ranked)}
        listing = sym.strategy_listing.upper()
        mapped_listing = IB_TO_EODHD_EXCHANGE.get(listing, listing)
        result.strategy_listing_is_highest_avg = mapped_listing == best_avg.exchange
        result.strategy_listing_is_highest_total = mapped_listing == best_total.exchange
        result.strategy_listing_avg_rank = ranks.get(mapped_listing)

    return result


def build_report(
    symbols: list[SymbolLiquidityResult],
    *,
    lookback_days: int,
    exchanges: list[str],
    strategy_path: str | None,
) -> dict[str, Any]:
    ok = [s for s in symbols if s.status == "OK"]
    return {
        "generatedUtc": datetime.now(timezone.utc).isoformat(),
        "source": "EODHD",
        "lookbackDays": lookback_days,
        "exchanges": exchanges,
        "strategyPath": strategy_path,
        "symbolCount": len(symbols),
        "strategyListingHighestAvgCount": sum(1 for s in ok if s.strategy_listing_is_highest_avg),
        "strategyListingHighestTotalCount": sum(1 for s in ok if s.strategy_listing_is_highest_total),
        "ibPrimaryHighestAvgCount": sum(1 for s in ok if s.ib_primary_is_highest_avg),
        "ibEnriched": any(s.ib_primary_exchange for s in symbols),
        "symbols": [asdict(s) for s in symbols],
    }


def write_summary_csv(path: Path, symbols: list[SymbolLiquidityResult]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(
            [
                "Symbol",
                "StrategyListing",
                "StrategyEodhdSymbol",
                "IbPrimaryExchange",
                "IbValidExchanges",
                "Exchange",
                "EodhdSymbol",
                "Status",
                "BarCount",
                "MinDailyVolume",
                "AvgDailyVolume",
                "MaxDailyVolume",
                "TotalVolume",
                "HighestAvgExchange",
                "StrategyListingIsHighestAvg",
                "StrategyListingAvgRank",
                "IbPrimaryIsHighestAvg",
                "IbPrimaryAvgRank",
            ]
        )
        for sym in symbols:
            if not sym.per_exchange:
                writer.writerow(
                    [
                        sym.symbol,
                        sym.strategy_listing or "",
                        sym.strategy_eodhd_symbol or "",
                        sym.ib_primary_exchange or "",
                        sym.ib_valid_exchanges or "",
                    ]
                )
                continue
            for ex in sym.per_exchange:
                writer.writerow(
                    [
                        sym.symbol,
                        sym.strategy_listing or "",
                        sym.strategy_eodhd_symbol or "",
                        sym.ib_primary_exchange or "",
                        sym.ib_valid_exchanges or "",
                        ex.exchange,
                        ex.eodhd_symbol,
                        ex.status,
                        ex.bar_count,
                        ex.min_daily_volume,
                        ex.avg_daily_volume,
                        ex.max_daily_volume,
                        ex.total_volume,
                        sym.highest_avg_volume_exchange or "",
                        "Y" if sym.strategy_listing_is_highest_avg else "N",
                        sym.strategy_listing_avg_rank if sym.strategy_listing_avg_rank is not None else "",
                        "Y" if sym.ib_primary_is_highest_avg else "N",
                        sym.ib_primary_avg_rank if sym.ib_primary_avg_rank is not None else "",
                    ]
                )


def _exchange_color(exchange: str) -> str:
    palette = {
        "XETRA": "#1f77b4",
        "F": "#ff7f0e",
        "STU": "#2ca02c",
        "VI": "#d62728",
        "DU": "#9467bd",
        "MU": "#8c564b",
        "BE": "#e377c2",
    }
    return palette.get(exchange.upper(), "#7f7f7f")


_GRAPH_LINE_WIDTH = 4
_GRAPH_LINE_WIDTH_IB_PRIMARY = _GRAPH_LINE_WIDTH + 1


def _is_ib_primary_exchange(exchange: str, ib_primary: str | None) -> bool:
    if not ib_primary:
        return False
    mapped = ib_exchange_to_eodhd(ib_primary)
    return exchange.upper() == mapped.upper()


def _graph_line_width(exchange: str, ib_primary: str | None) -> int:
    if _is_ib_primary_exchange(exchange, ib_primary):
        return _GRAPH_LINE_WIDTH_IB_PRIMARY
    return _GRAPH_LINE_WIDTH


def build_interactive_html(report: dict[str, Any], title: str) -> str:
    symbols = report["symbols"]
    if not symbols:
        raise ValueError("Report has no symbols")

    first = symbols[0]
    fig = _figure_for_symbol(first, title)

    report_json = json.dumps(report, separators=(",", ":"))
    fig_json = fig.to_json()

    sidebar_items = []
    for sym in symbols:
        listing = sym.get("strategy_listing") or "?"
        ib_primary = sym.get("ib_primary_exchange") or "?"
        best = sym.get("highest_avg_volume_exchange") or "-"
        marker = " *" if sym.get("ib_primary_is_highest_avg") else ""
        label = f"{sym['symbol']} · strat {listing} · IB {ib_primary} · vol {best}{marker}"
        sidebar_items.append(
            f'<button type="button" class="ticker" data-symbol="{sym["symbol"]}">{label}</button>'
        )

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>{title}</title>
  <script src="https://cdn.plot.ly/plotly-2.35.2.min.js"></script>
  <style>
    :root {{
      color-scheme: light dark;
      --bg: #111;
      --panel: #1b1b1b;
      --text: #eee;
      --muted: #aaa;
      --accent: #4ea1ff;
      --border: #333;
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      font: 14px/1.4 Segoe UI, system-ui, sans-serif;
      background: var(--bg);
      color: var(--text);
    }}
    #app {{
      display: grid;
      grid-template-columns: 280px 1fr;
      min-height: 100vh;
    }}
    #sidebar {{
      border-right: 1px solid var(--border);
      background: var(--panel);
      overflow: auto;
      padding: 12px;
    }}
    #sidebar h1 {{
      margin: 0 0 8px;
      font-size: 16px;
    }}
    #sidebar p {{
      margin: 0 0 12px;
      color: var(--muted);
      font-size: 12px;
    }}
    .ticker {{
      display: block;
      width: 100%;
      text-align: left;
      margin: 0 0 6px;
      padding: 8px 10px;
      border: 1px solid var(--border);
      border-radius: 6px;
      background: #222;
      color: var(--text);
      cursor: pointer;
    }}
    .ticker:hover {{ border-color: var(--accent); }}
    .ticker.active {{
      border-color: var(--accent);
      background: #16324f;
    }}
    #plot {{
      min-height: 100vh;
    }}
    #meta {{
      padding: 10px 14px;
      border-bottom: 1px solid var(--border);
      background: #151515;
      color: var(--muted);
      font-size: 12px;
    }}
  </style>
</head>
<body>
  <div id="app">
    <aside id="sidebar">
      <h1>Exchange liquidity</h1>
      <p>{len(symbols)} symbols · {report.get('lookbackDays')}d · EODHD {', '.join(report.get('exchanges', []))}{' · IB enriched' if report.get('ibEnriched') else ''}<br />↑↓ to move between symbols</p>
      {''.join(sidebar_items)}
    </aside>
    <section>
      <div id="meta"></div>
      <div id="plot"></div>
    </section>
  </div>
  <script>
    const report = {report_json};
    const symbolMap = Object.fromEntries(report.symbols.map(s => [s.symbol, s]));
    let currentFigure = {fig_json};
    let currentSymbolIndex = 0;

    const IB_TO_EODHD = {json.dumps(IB_TO_EODHD_EXCHANGE, separators=(",", ":"))};
    const GRAPH_LINE_WIDTH = 4;
    const GRAPH_LINE_WIDTH_IB_PRIMARY = GRAPH_LINE_WIDTH + 1;

    function ibPrimaryEodhdExchange(ibPrimary) {{
      if (!ibPrimary) return null;
      const key = String(ibPrimary).trim().toUpperCase();
      return IB_TO_EODHD[key] || key;
    }}

    function isIbPrimaryExchange(exchange, ibPrimary) {{
      const mapped = ibPrimaryEodhdExchange(ibPrimary);
      return mapped != null && String(exchange).toUpperCase() === mapped.toUpperCase();
    }}

    function graphLineWidth(exchange, ibPrimary) {{
      return isIbPrimaryExchange(exchange, ibPrimary) ? GRAPH_LINE_WIDTH_IB_PRIMARY : GRAPH_LINE_WIDTH;
    }}

    function figureForSymbol(sym) {{
      const exchanges = (sym.per_exchange || []).filter(e => e.status === 'OK' && (e.daily_bars || []).length);
      const traces = [];
      exchanges.forEach((ex, idx) => {{
        const dates = ex.daily_bars.map(b => b.date);
        const volumes = ex.daily_bars.map(b => b.volume);
        traces.push({{
          type: 'scatter3d',
          mode: 'lines+markers',
          name: ex.exchange,
          x: dates,
          y: Array(dates.length).fill(idx),
          z: volumes,
          line: {{ width: graphLineWidth(ex.exchange, sym.ib_primary_exchange) }},
          marker: {{ size: 3 }},
          customdata: Array(dates.length).fill(ex.eodhd_symbol),
          hovertemplate:
            '<b>%{{fullData.name}}</b><br>' +
            'Date: %{{x}}<br>' +
            'Volume: %{{z:,}}<br>' +
            'Symbol: %{{customdata}}<extra></extra>'
        }});
      }});

      const yLabels = exchanges.map(e => e.exchange);
      return {{
        data: traces,
        layout: {{
          title: `${{sym.symbol}} daily volume by listing (${{report.lookbackDays}}d)`,
          scene: {{
            xaxis: {{ title: 'Date' }},
            yaxis: {{
              title: 'Exchange',
              tickmode: 'array',
              tickvals: yLabels.map((_, i) => i),
              ticktext: yLabels
            }},
            zaxis: {{ title: 'Volume' }}
          }},
          margin: {{ l: 0, r: 0, t: 50, b: 0 }},
          legend: {{ orientation: 'h', y: 1.08 }}
        }}
      }};
    }}

    function setActive(symbol) {{
      document.querySelectorAll('.ticker').forEach(btn => {{
        btn.classList.toggle('active', btn.dataset.symbol === symbol);
      }});
    }}

    function styleIbPrimaryLegend(sym) {{
      const mapped = ibPrimaryEodhdExchange(sym?.ib_primary_exchange);
      document.querySelectorAll('#plot .legend .legendtext').forEach(el => {{
        const isPrimary = mapped && el.textContent.trim().toUpperCase() === mapped.toUpperCase();
        el.style.fontWeight = isPrimary ? 'bold' : '';
      }});
    }}

    function renderSymbol(symbol) {{
      const sym = symbolMap[symbol];
      if (!sym) return;
      const idx = report.symbols.findIndex(s => s.symbol === symbol);
      if (idx >= 0) {{
        currentSymbolIndex = idx;
      }}
      currentFigure = figureForSymbol(sym);
      Plotly.react('plot', currentFigure.data, currentFigure.layout, {{ responsive: true }})
        .then(() => styleIbPrimaryLegend(sym));
      const listing = sym.strategy_listing || '?';
      const ibPrimary = sym.ib_primary_exchange || '?';
      const ibValid = sym.ib_valid_exchanges || '-';
      const best = sym.highest_avg_volume_exchange || '-';
      const stratRank = sym.strategy_listing_avg_rank != null ? sym.strategy_listing_avg_rank : 'n/a';
      const ibRank = sym.ib_primary_avg_rank != null ? sym.ib_primary_avg_rank : 'n/a';
      const stratMatch = sym.strategy_listing_is_highest_avg ? 'yes' : 'no';
      const ibMatch = sym.ib_primary_is_highest_avg ? 'yes' : 'no';
      document.getElementById('meta').textContent =
        `${{symbol}} · IB primary ${{ibPrimary}} (valid: ${{ibValid}}) · strategy listing ${{listing}} · highest EODHD avg ${{best}} · IB primary rank ${{ibRank}} (is highest: ${{ibMatch}}) · strategy rank ${{stratRank}} (is highest: ${{stratMatch}})`;
      setActive(symbol);
      const activeBtn = document.querySelector('.ticker.active');
      if (activeBtn) {{
        activeBtn.scrollIntoView({{ block: 'nearest', behavior: 'smooth' }});
      }}
    }}

    function moveSymbol(delta) {{
      const next = currentSymbolIndex + delta;
      if (next < 0 || next >= report.symbols.length) {{
        return;
      }}
      renderSymbol(report.symbols[next].symbol);
    }}

    Plotly.newPlot('plot', currentFigure.data, currentFigure.layout, {{ responsive: true }})
      .then(() => styleIbPrimaryLegend(report.symbols[0]));
    renderSymbol({json.dumps(first['symbol'])});

    document.getElementById('sidebar').addEventListener('click', (ev) => {{
      const btn = ev.target.closest('.ticker');
      if (!btn) return;
      renderSymbol(btn.dataset.symbol);
    }});

    document.addEventListener('keydown', (ev) => {{
      if (ev.key === 'ArrowDown') {{
        ev.preventDefault();
        moveSymbol(1);
      }} else if (ev.key === 'ArrowUp') {{
        ev.preventDefault();
        moveSymbol(-1);
      }}
    }});
  </script>
</body>
</html>
"""


def _figure_for_symbol(sym: dict[str, Any], title_prefix: str) -> go.Figure:
    exchanges = [ex for ex in sym.get("per_exchange", []) if ex.get("status") == "OK" and ex.get("daily_bars")]
    traces: list[go.Scatter3d] = []
    y_labels: list[str] = []

    ib_primary = sym.get("ib_primary_exchange")
    for idx, ex in enumerate(exchanges):
        y_labels.append(ex["exchange"])
        dates = [bar["date"] for bar in ex["daily_bars"]]
        volumes = [bar["volume"] for bar in ex["daily_bars"]]
        line_width = _graph_line_width(ex["exchange"], ib_primary)
        traces.append(
            go.Scatter3d(
                x=dates,
                y=[idx] * len(dates),
                z=volumes,
                mode="lines+markers",
                name=ex["exchange"],
                line=dict(width=line_width, color=_exchange_color(ex["exchange"])),
                marker=dict(size=3, color=_exchange_color(ex["exchange"])),
                customdata=[ex["eodhd_symbol"]] * len(dates),
                hovertemplate=(
                    "<b>%{{fullData.name}}</b><br>"
                    "Date: %{x}<br>"
                    "Volume: %{z:,}<br>"
                    "Symbol: %{customdata}<extra></extra>"
                ),
            )
        )

    fig = go.Figure(data=traces)
    fig.update_layout(
        title=f"{sym['symbol']} daily volume by listing",
        scene=dict(
            xaxis_title="Date",
            yaxis=dict(
                title="Exchange",
                tickmode="array",
                tickvals=list(range(len(y_labels))),
                ticktext=y_labels,
            ),
            zaxis_title="Volume",
        ),
        margin=dict(l=0, r=0, t=50, b=0),
        legend=dict(orientation="h", y=1.08),
    )
    return fig


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="EODHD multi-listing volume spike with 3D HTML report")
    parser.add_argument("--strategy-path", help="RTS file or directory (EODHD IncludeList scan)")
    parser.add_argument("--symbols", help="Comma list or path to symbol file")
    parser.add_argument(
        "--exchanges",
        default="XETRA,F,STU,PA,MC,AS,HE",
        help="EODHD exchange suffixes (IB aliases e.g. FWB->F, IBIS->XETRA, SBF->PA). Default: XETRA,F,STU,PA,MC,AS,HE",
    )
    parser.add_argument("--lookback-days", type=int, default=90, help="Calendar days of EOD history (default 90)")
    parser.add_argument("--max-symbols", type=int, default=0, help="Limit symbols (0 = all)")
    parser.add_argument("--request-delay-ms", type=int, default=250, help="Pause between API calls")
    parser.add_argument("--timeout-seconds", type=int, default=100)
    parser.add_argument(
        "--cache-dir",
        help="Directory for EODHD response cache (default: <repo>/.cache/spike-exch-liq-eod)",
    )
    parser.add_argument("--no-cache", dest="use_cache", action="store_false", default=True)
    parser.add_argument("--output-json", default="exch-liq-spike.json")
    parser.add_argument("--output-csv", default="exch-liq-spike-summary.csv")
    parser.add_argument("--output-html", default="exch-liq-spike.html")
    parser.add_argument("--ib-enrich", dest="ib_enrich", action="store_true", default=True)
    parser.add_argument("--no-ib-enrich", dest="ib_enrich", action="store_false")
    parser.add_argument(
        "--ib-exchanges",
        default="FWB,XETRA,IBIS",
        help="IB exchanges for fetch-ib-min-tick --exchanges; first entry is request PrimaryExch hint only (default: FWB,XETRA,IBIS)",
    )
    parser.add_argument("--ib-currency", default="EUR", help="IB contract currency (default: EUR)")
    parser.add_argument("--ib-host", default="127.0.0.1")
    parser.add_argument("--ib-port", type=int, default=7496, help="TWS port (7496 live, 7497 paper)")
    parser.add_argument(
        "--fetch-ib-min-tick",
        help="Path to fetch-ib-min-tick.exe (default: ../rt-automation/bin/fetch-ib-min-tick.exe)",
    )
    parser.add_argument("-v", "--verbose", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    if not args.strategy_path and not args.symbols:
        print("Error: provide --strategy-path and/or --symbols", file=sys.stderr)
        return 2

    repo_root = find_repo_root(Path.cwd())
    api_token = load_api_token(repo_root)
    exchanges = map_exchanges(args.exchanges.split(","))
    if not exchanges:
        print("Error: no exchanges configured", file=sys.stderr)
        return 2

    try:
        strategy_symbols = load_symbols(args.strategy_path, args.symbols, args.max_symbols)
    except FileNotFoundError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 2

    if not strategy_symbols:
        print("Error: no symbols loaded", file=sys.stderr)
        return 2

    end = date.today()
    start = end - timedelta(days=max(1, args.lookback_days))

    print(f"Repo root: {repo_root}")
    print(f"Symbols: {len(strategy_symbols)}")
    print(f"Exchanges: {', '.join(exchanges)}")
    print(f"Lookback: {start} .. {end}")

    cache_dir: Path | None = None
    if args.use_cache:
        cache_dir = Path(args.cache_dir) if args.cache_dir else repo_root / ".cache" / "spike-exch-liq-eod"
        print(f"EOD cache: {cache_dir}")

    session = requests.Session()
    session.headers.update({"User-Agent": "spike-exch-liq/1.0", "Accept": "application/json"})

    cache_hits = 0
    cache_misses = 0
    results: list[SymbolLiquidityResult] = []
    for sym in strategy_symbols:
        per_exchange: list[ExchangeVolumeStats] = []
        for exchange in exchanges:
            query_code = eodhd_ticker_code(sym)
            eodhd_symbol = f"{query_code}.{exchange}"
            if args.verbose:
                print(f"  {eodhd_symbol} ...", flush=True)
            bars, status, note, from_cache = fetch_eod_bars_cached(
                session,
                api_token,
                eodhd_symbol,
                start,
                end,
                float(args.timeout_seconds),
                cache_dir,
                args.use_cache,
            )
            if from_cache:
                cache_hits += 1
                if args.verbose:
                    print(f"    cache hit ({status})", flush=True)
            else:
                cache_misses += 1
            per_exchange.append(summarize_exchange(exchange, eodhd_symbol, bars, status, note))
            if not from_cache and args.request_delay_ms > 0:
                time.sleep(args.request_delay_ms / 1000.0)

        result = finalize_symbol_result(sym, exchanges, per_exchange)
        results.append(result)
        listing = sym.strategy_listing or "?"
        best = result.highest_avg_volume_exchange or "-"
        print(f"{sym.base}: {result.status} strategy={listing} best={best}")

    if args.use_cache:
        print(f"EOD cache: {cache_hits} hits, {cache_misses} misses")

    if args.ib_enrich:
        exe_path = resolve_fetch_ib_min_tick_exe(args.fetch_ib_min_tick)
        if exe_path is None:
            print(
                "WARNING: IB enrichment skipped — fetch-ib-min-tick.exe not found "
                "(build rt-automation Tooling or pass --fetch-ib-min-tick)",
                file=sys.stderr,
            )
        else:
            print(f"IB enrichment via {exe_path} ({args.ib_host}:{args.ib_port}) ...")
            try:
                ib_rows = fetch_ib_primary_map(
                    strategy_symbols,
                    exe_path=exe_path,
                    ib_exchanges=args.ib_exchanges,
                    currency=args.ib_currency,
                    host=args.ib_host,
                    port=args.ib_port,
                    verbose=args.verbose,
                )
                apply_ib_enrichment(results, ib_rows)
                enriched = sum(1 for row in results if row.ib_primary_exchange)
                print(f"IB primary exchange resolved for {enriched}/{len(results)} symbols")
            except RuntimeError as exc:
                print(f"WARNING: IB enrichment failed: {exc}", file=sys.stderr)

    report = build_report(
        results,
        lookback_days=args.lookback_days,
        exchanges=exchanges,
        strategy_path=args.strategy_path,
    )

    json_path = Path(args.output_json)
    csv_path = Path(args.output_csv)
    html_path = Path(args.output_html)
    for path in (json_path, csv_path, html_path):
        path.parent.mkdir(parents=True, exist_ok=True)

    json_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    write_summary_csv(csv_path, results)
    html_path.write_text(build_interactive_html(report, "EODHD exchange liquidity"), encoding="utf-8")

    ok = [r for r in results if r.status == "OK"]
    print()
    print(f"Wrote JSON:  {json_path.resolve()}")
    print(f"Wrote CSV:   {csv_path.resolve()}")
    print(f"Wrote HTML:  {html_path.resolve()}")
    print(f"Summary: {len(ok)}/{len(results)} symbols with volume data")
    if ok:
        avg_match = sum(1 for r in ok if r.strategy_listing_is_highest_avg)
        ib_match = sum(1 for r in ok if r.ib_primary_is_highest_avg)
        print(f"  Strategy listing had highest avg daily volume: {avg_match}/{len(ok)}")
        if any(r.ib_primary_exchange for r in results):
            print(f"  IB primary had highest avg daily volume:     {ib_match}/{len(ok)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
