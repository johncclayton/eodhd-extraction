using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

var cancellation = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) =>
{
    e.Cancel = true;
    cancellation.Cancel();
};

var options = ParseArguments(args);
if (options.ShowHelp)
{
    PrintUsage();
    return;
}

var rootDirectory = FindRepoRoot(Environment.CurrentDirectory);
var envPath = Path.Combine(rootDirectory, ".env");
var apiToken = GetApiToken(envPath);
var dataDirectory = Path.Combine(rootDirectory, "data");
Directory.CreateDirectory(dataDirectory);
var symbols = LoadSymbols(options, Environment.CurrentDirectory);
if (symbols.Count == 0)
{
    Console.Error.WriteLine("No symbols were provided. Use positional symbols, --symbol-file, or both.");
    Console.WriteLine();
    PrintUsage();
    return;
}

using var http = new HttpClient
{
    BaseAddress = new Uri("https://eodhd.com/api/"),
    Timeout = TimeSpan.FromSeconds(100)
};
http.DefaultRequestHeaders.UserAgent.ParseAdd("DownloadSymbolHistory/1.0");
http.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));

Console.WriteLine($"Repo root: {rootDirectory}");
Console.WriteLine($"Output dir: {dataDirectory}");
Console.WriteLine($"Symbols: {string.Join(", ", symbols)}");

foreach (var symbol in symbols)
{
    cancellation.Token.ThrowIfCancellationRequested();

    var encodedSymbol = Uri.EscapeDataString(symbol);
    var requestUri = $"eod/{encodedSymbol}?api_token={Uri.EscapeDataString(apiToken)}&period=d&fmt=json";

    Console.WriteLine();
    Console.WriteLine($"Downloading {symbol} ...");

    var payload = await GetWithRetryAsync(http, requestUri, symbol, cancellation.Token);
    var bars = ParseBars(payload, symbol);
    var outputPath = Path.Combine(dataDirectory, $"{SanitizeFileName(symbol)}.csv");
    await WriteBarsCsvAsync(outputPath, bars, cancellation.Token);

    var summary = SummarizeBars(bars);
    Console.WriteLine($"Saved {symbol} -> {outputPath}");
    Console.WriteLine(summary);
}

var symbolsListPath = Path.Combine(dataDirectory, "symbols-rt.txt");
await File.WriteAllLinesAsync(symbolsListPath, symbols, new UTF8Encoding(false), cancellation.Token);
Console.WriteLine();
Console.WriteLine($"Saved RealTest include list -> {symbolsListPath}");

var importExamplePath = Path.Combine(dataDirectory, "import-example.txt");
await File.WriteAllTextAsync(importExamplePath, BuildImportExample(), new UTF8Encoding(false), cancellation.Token);
Console.WriteLine($"Saved RealTest import example -> {importExamplePath}");

static AppOptions ParseArguments(string[] rawArgs)
{
    var positionalSymbols = new List<string>();
    string? symbolFilePath = null;
    var showHelp = false;

    for (var i = 0; i < rawArgs.Length; i++)
    {
        var arg = rawArgs[i];
        if (IsHelpFlag(arg))
        {
            showHelp = true;
            continue;
        }

        if (arg.Equals("--symbol-file", StringComparison.OrdinalIgnoreCase)
            || arg.Equals("-f", StringComparison.OrdinalIgnoreCase))
        {
            if (i + 1 >= rawArgs.Length)
            {
                throw new ArgumentException("Missing value for --symbol-file.");
            }

            symbolFilePath = rawArgs[++i];
            continue;
        }

        positionalSymbols.Add(arg);
    }

    return new AppOptions(positionalSymbols, symbolFilePath, showHelp);
}

static bool IsHelpFlag(string value) =>
    value.Equals("-h", StringComparison.OrdinalIgnoreCase)
    || value.Equals("--help", StringComparison.OrdinalIgnoreCase)
    || value.Equals("/?", StringComparison.OrdinalIgnoreCase);

static List<string> LoadSymbols(AppOptions options, string currentDirectory)
{
    var result = new List<string>();
    var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

    AddTokens(result, seen, options.PositionalSymbols);

    if (!string.IsNullOrWhiteSpace(options.SymbolFilePath))
    {
        var resolvedPath = Path.GetFullPath(options.SymbolFilePath, currentDirectory);
        if (!File.Exists(resolvedPath))
        {
            throw new FileNotFoundException($"Symbol file not found: {resolvedPath}", resolvedPath);
        }

        foreach (var rawLine in File.ReadLines(resolvedPath))
        {
            var line = rawLine.Trim();
            if (string.IsNullOrWhiteSpace(line) || line.StartsWith('#'))
            {
                continue;
            }

            AddTokens(result, seen, SplitTokens(line));
        }
    }

    return result;
}

static void AddTokens(List<string> result, HashSet<string> seen, IEnumerable<string> rawValues)
{
    foreach (var rawValue in rawValues)
    {
        foreach (var token in SplitTokens(rawValue))
        {
            if (seen.Add(token))
            {
                result.Add(token);
            }
        }
    }
}

static IEnumerable<string> SplitTokens(string rawValue) =>
    rawValue
        .Split([',', ' ', '\t'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
        .Where(static token => !string.IsNullOrWhiteSpace(token));

static void PrintUsage()
{
    Console.WriteLine("Download full EODHD history for one or more symbols as RealTest CSV files.");
    Console.WriteLine();
    Console.WriteLine("Usage:");
    Console.WriteLine("  dotnet run DownloadSymbolHistory.cs -- SYMBOL [SYMBOL ...]");
    Console.WriteLine("  dotnet run DownloadSymbolHistory.cs -- HPRD.SW GBRE.SW TRET.SW");
    Console.WriteLine("  dotnet run DownloadSymbolHistory.cs -- HPRD.SW,GBRE.SW,TRET.SW");
    Console.WriteLine("  dotnet run DownloadSymbolHistory.cs -- --symbol-file .\\symbols.txt");
    Console.WriteLine("  dotnet run DownloadSymbolHistory.cs -- --symbol-file .\\symbols.txt GBRE.SW");
    Console.WriteLine();
    Console.WriteLine("Notes:");
    Console.WriteLine("  - Reads EODHD_API_TOKEN from .env in eodhd-extraction or from the process environment.");
    Console.WriteLine("  - Writes one SYMBOL.csv file per symbol under eodhd-extraction/data/.");
    Console.WriteLine("  - Also writes symbols-rt.txt and import-example.txt for RealTest.");
    Console.WriteLine("  - CSV columns are Date,Open,High,Low,Close,Volume,AdjClose.");
    Console.WriteLine("  - --symbol-file accepts one symbol per line, comma-separated symbols, or whitespace-separated symbols.");
    Console.WriteLine("  - Blank lines and lines starting with # are ignored.");
    Console.WriteLine("  - Omits from/to so EODHD returns the full available history.");
}

static string FindRepoRoot(string startDirectory)
{
    var current = new DirectoryInfo(startDirectory);

    while (current is not null)
    {
        var envPath = Path.Combine(current.FullName, ".env");
        if (File.Exists(envPath))
        {
            return current.FullName;
        }

        current = current.Parent;
    }

    throw new InvalidOperationException(
        $"Could not find .env starting from '{startDirectory}'. Run this from eodhd-extraction or a subdirectory."
    );
}

static string GetApiToken(string envPath)
{
    var fromEnvFile = GetDotEnvValue(envPath, "EODHD_API_TOKEN");
    if (!string.IsNullOrWhiteSpace(fromEnvFile))
    {
        return fromEnvFile;
    }

    var fromEnvironment = Environment.GetEnvironmentVariable("EODHD_API_TOKEN");
    if (!string.IsNullOrWhiteSpace(fromEnvironment))
    {
        return fromEnvironment.Trim();
    }

    throw new InvalidOperationException("Missing EODHD_API_TOKEN in .env and process environment.");
}

static string? GetDotEnvValue(string envPath, string key)
{
    if (!File.Exists(envPath))
    {
        return null;
    }

    foreach (var rawLine in File.ReadLines(envPath))
    {
        var line = rawLine.Trim();
        if (string.IsNullOrWhiteSpace(line) || line.StartsWith('#'))
        {
            continue;
        }

        if (line.StartsWith("export ", StringComparison.OrdinalIgnoreCase))
        {
            line = line["export ".Length..].Trim();
        }

        var separatorIndex = line.IndexOf('=');
        if (separatorIndex <= 0)
        {
            continue;
        }

        var name = line[..separatorIndex].Trim();
        if (!name.Equals(key, StringComparison.Ordinal))
        {
            continue;
        }

        var value = line[(separatorIndex + 1)..].Trim();
        if (value.Length >= 2)
        {
            var quoted = (value.StartsWith('"') && value.EndsWith('"'))
                || (value.StartsWith('\'') && value.EndsWith('\''));
            if (quoted)
            {
                value = value[1..^1];
            }
        }

        return value;
    }

    return null;
}

static async Task<string> GetWithRetryAsync(HttpClient http, string requestUri, string symbol, CancellationToken cancellationToken)
{
    var maxAttempts = 8;
    var random = new Random();

    for (var attempt = 1; attempt <= maxAttempts; attempt++)
    {
        using HttpResponseMessage? response = await TrySendAsync(http, requestUri, cancellationToken);
        if (response is null)
        {
            var networkDelay = ComputeBackoffDelay(attempt, random, null);
            Console.WriteLine($"Network failure for {symbol}; retrying in {networkDelay.TotalSeconds:n1}s (attempt {attempt}/{maxAttempts})");
            await Task.Delay(networkDelay, cancellationToken);
            continue;
        }

        if (response.IsSuccessStatusCode)
        {
            var content = await response.Content.ReadAsStringAsync(cancellationToken);
            await HonorPostSuccessRateLimitAsync(response, cancellationToken);
            return content;
        }

        if (!IsRetryable(response.StatusCode) || attempt == maxAttempts)
        {
            var errorBody = await response.Content.ReadAsStringAsync(cancellationToken);
            throw new HttpRequestException(
                $"EODHD request for {symbol} failed with {(int)response.StatusCode} {response.ReasonPhrase}. Body: {errorBody}"
            );
        }

        var retryDelay = GetRetryDelay(response, attempt, random);
        Console.WriteLine(
            $"EODHD returned {(int)response.StatusCode} for {symbol}; retrying in {retryDelay.TotalSeconds:n1}s (attempt {attempt}/{maxAttempts})"
        );
        await Task.Delay(retryDelay, cancellationToken);
    }

    throw new InvalidOperationException($"Exhausted retries for {symbol}.");
}

static async Task<HttpResponseMessage?> TrySendAsync(HttpClient http, string requestUri, CancellationToken cancellationToken)
{
    try
    {
        return await http.GetAsync(requestUri, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
    }
    catch (HttpRequestException)
    {
        return null;
    }
    catch (TaskCanceledException) when (!cancellationToken.IsCancellationRequested)
    {
        return null;
    }
}

static bool IsRetryable(HttpStatusCode statusCode) =>
    statusCode == HttpStatusCode.TooManyRequests
    || statusCode == HttpStatusCode.RequestTimeout
    || (int)statusCode >= 500;

static TimeSpan GetRetryDelay(HttpResponseMessage response, int attempt, Random random)
{
    if (response.Headers.RetryAfter is { } retryAfter)
    {
        if (retryAfter.Delta is { } delta && delta > TimeSpan.Zero)
        {
            return delta;
        }

        if (retryAfter.Date is { } date)
        {
            var fromHeader = date - DateTimeOffset.UtcNow;
            if (fromHeader > TimeSpan.Zero)
            {
                return fromHeader;
            }
        }
    }

    if (TryGetHeaderInt(response.Headers, "X-RateLimit-Remaining", out var remaining) && remaining <= 0)
    {
        return TimeSpan.FromSeconds(65);
    }

    return ComputeBackoffDelay(attempt, random, response.Headers);
}

static TimeSpan ComputeBackoffDelay(int attempt, Random random, HttpResponseHeaders? headers)
{
    var baseSeconds = Math.Min(60, Math.Pow(2, attempt));
    var jitterMilliseconds = random.Next(250, 1250);

    if (headers is not null
        && TryGetHeaderInt(headers, "X-RateLimit-Limit", out var limit)
        && limit > 0
        && TryGetHeaderInt(headers, "X-RateLimit-Remaining", out var remaining)
        && remaining <= Math.Max(1, limit / 100))
    {
        baseSeconds = Math.Max(baseSeconds, 30);
    }

    return TimeSpan.FromSeconds(baseSeconds) + TimeSpan.FromMilliseconds(jitterMilliseconds);
}

static async Task HonorPostSuccessRateLimitAsync(HttpResponseMessage response, CancellationToken cancellationToken)
{
    if (TryGetHeaderInt(response.Headers, "X-RateLimit-Remaining", out var remaining) && remaining <= 1)
    {
        var pause = TimeSpan.FromSeconds(65);
        Console.WriteLine($"Rate limit nearly exhausted (remaining={remaining}); pausing for {pause.TotalSeconds:n0}s");
        await Task.Delay(pause, cancellationToken);
    }
}

static bool TryGetHeaderInt(HttpResponseHeaders headers, string name, out int value)
{
    value = 0;
    if (!headers.TryGetValues(name, out var values))
    {
        return false;
    }

    var first = values.FirstOrDefault();
    return int.TryParse(first, NumberStyles.Integer, CultureInfo.InvariantCulture, out value);
}

static List<EodBar> ParseBars(string payload, string symbol)
{
    using var document = JsonDocument.Parse(payload);
    if (document.RootElement.ValueKind != JsonValueKind.Array)
    {
        throw new InvalidOperationException($"Unexpected payload for {symbol}: expected a JSON array.");
    }

    var bars = new List<EodBar>();
    foreach (var row in document.RootElement.EnumerateArray())
    {
        var dateText = GetString(row, "date");
        if (string.IsNullOrWhiteSpace(dateText))
        {
            continue;
        }

        if (!DateOnly.TryParse(dateText, CultureInfo.InvariantCulture, DateTimeStyles.None, out var date))
        {
            throw new InvalidOperationException($"Could not parse date '{dateText}' for {symbol}.");
        }

        var open = GetDecimal(row, "open");
        var high = GetDecimal(row, "high");
        var low = GetDecimal(row, "low");
        var close = GetDecimal(row, "close");
        var volume = GetDecimal(row, "volume");
        var adjClose = GetOptionalDecimal(row, "adjusted_close") ?? close;

        bars.Add(new EodBar(date, open, high, low, close, volume, adjClose));
    }

    bars.Sort(static (a, b) => a.Date.CompareTo(b.Date));
    return bars;
}

static async Task WriteBarsCsvAsync(string outputPath, IReadOnlyList<EodBar> bars, CancellationToken cancellationToken)
{
    await using var writer = new StreamWriter(outputPath, false, new UTF8Encoding(false));
    await writer.WriteLineAsync("Date,Open,High,Low,Close,Volume,AdjClose");

    foreach (var bar in bars)
    {
        cancellationToken.ThrowIfCancellationRequested();

        var line = string.Join(
            ',',
            bar.Date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
            FormatDecimal(bar.Open),
            FormatDecimal(bar.High),
            FormatDecimal(bar.Low),
            FormatDecimal(bar.Close),
            FormatDecimal(bar.Volume),
            FormatDecimal(bar.AdjClose)
        );

        await writer.WriteLineAsync(line);
    }
}

static string SummarizeBars(IReadOnlyList<EodBar> bars)
{
    if (bars.Count == 0)
    {
        return "Rows: 0";
    }

    return $"Rows: {bars.Count}; first date: {bars[0].Date:yyyy-MM-dd}; last date: {bars[^1].Date:yyyy-MM-dd}";
}

static string BuildImportExample()
{
    return """
Import:
	DataSource:	CSV
	DataPath:	?scriptpath?\data
	IncludeList:	?scriptpath?\data\symbols-rt.txt
	CSVFields:	Date,Open,High,Low,Close,Volume,AdjClose
	SaveAs:	imported_from_eodhd_csv.rtd

Settings:
	DataFile:	imported_from_eodhd_csv.rtd
	StartDate:	Earliest
	EndDate:	Latest
""";
}

static string? GetString(JsonElement row, string propertyName)
{
    if (!row.TryGetProperty(propertyName, out var property))
    {
        return null;
    }

    return property.ValueKind switch
    {
        JsonValueKind.String => property.GetString(),
        JsonValueKind.Number => property.GetRawText(),
        _ => null
    };
}

static decimal GetDecimal(JsonElement row, string propertyName)
{
    var value = GetOptionalDecimal(row, propertyName);
    if (value is null)
    {
        throw new InvalidOperationException($"Missing numeric property '{propertyName}'.");
    }

    return value.Value;
}

static decimal? GetOptionalDecimal(JsonElement row, string propertyName)
{
    if (!row.TryGetProperty(propertyName, out var property))
    {
        return null;
    }

    if (property.ValueKind == JsonValueKind.Null)
    {
        return null;
    }

    if (property.ValueKind == JsonValueKind.Number)
    {
        return property.GetDecimal();
    }

    if (property.ValueKind == JsonValueKind.String
        && decimal.TryParse(property.GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var parsed))
    {
        return parsed;
    }

    return null;
}

static string FormatDecimal(decimal value) =>
    value.ToString("0.##########", CultureInfo.InvariantCulture);

static string SanitizeFileName(string symbol)
{
    var invalidChars = Path.GetInvalidFileNameChars();
    var pattern = $"[{Regex.Escape(new string(invalidChars))}]";
    return Regex.Replace(symbol, pattern, "_");
}

record EodBar(
    DateOnly Date,
    decimal Open,
    decimal High,
    decimal Low,
    decimal Close,
    decimal Volume,
    decimal AdjClose
);

record AppOptions(
    List<string> PositionalSymbols,
    string? SymbolFilePath,
    bool ShowHelp
);
