using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace EodhdExperimental
{
    public sealed class SymbolIndexStreamer
    {
        private static readonly Regex NormRx = new Regex(@"[\s\.\-_/]", RegexOptions.Compiled);

        public Dictionary<string, HashSet<string>> Exact { get; } =
            new Dictionary<string, HashSet<string>>(StringComparer.Ordinal);

        public Dictionary<string, HashSet<string>> Normalized { get; } =
            new Dictionary<string, HashSet<string>>(StringComparer.Ordinal);

        public int AddPayloadFile(string path, string exchangeCode)
        {
            var bytes = File.ReadAllBytes(path);
            if (bytes.Length == 0)
                return 0;

            var reader = new Utf8JsonReader(bytes, new JsonReaderOptions
            {
                CommentHandling = JsonCommentHandling.Skip,
                AllowTrailingCommas = true
            });

            if (!reader.Read() || reader.TokenType != JsonTokenType.StartArray)
                throw new InvalidOperationException("Root must be a JSON array: " + path);

            int rowsUsed = 0;
            while (reader.Read())
            {
                if (reader.TokenType == JsonTokenType.EndArray)
                    break;

                if (reader.TokenType != JsonTokenType.StartObject)
                    reader.Skip();
                else
                    rowsUsed += ReadOneObject(ref reader, exchangeCode);
            }

            return rowsUsed;
        }

        private int ReadOneObject(ref Utf8JsonReader reader, string exchangeCode)
        {
            string code = "";
            string currency = "";

            while (reader.Read())
            {
                if (reader.TokenType == JsonTokenType.EndObject)
                    break;

                if (reader.TokenType != JsonTokenType.PropertyName)
                {
                    reader.Skip();
                    continue;
                }

                string prop = reader.GetString() ?? "";
                if (!reader.Read())
                    break;

                if (string.Equals(prop, "Code", StringComparison.Ordinal))
                {
                    if (reader.TokenType == JsonTokenType.String)
                        code = reader.GetString() ?? "";
                    else
                        reader.Skip();
                }
                else if (string.Equals(prop, "Currency", StringComparison.Ordinal))
                {
                    if (reader.TokenType == JsonTokenType.String)
                        currency = reader.GetString() ?? "";
                    else
                        reader.Skip();
                }
                else
                {
                    reader.Skip();
                }
            }

            if (string.IsNullOrWhiteSpace(code))
                return 0;

            AddRow(exchangeCode, code, currency);
            return 1;
        }

        private void AddRow(string exchange, string code, string currency)
        {
            var exactKey = code.Trim().ToUpperInvariant();
            if (string.IsNullOrEmpty(exactKey))
                return;

            var curNorm = string.IsNullOrWhiteSpace(currency)
                ? ""
                : currency.Trim().ToUpperInvariant();

            var token = exchange + "|" + curNorm;
            AddToken(Exact, exactKey, token);

            var normKey = NormalizeSymbol(code);
            if (!string.IsNullOrEmpty(normKey))
                AddToken(Normalized, normKey, token);
        }

        private static string NormalizeSymbol(string code)
        {
            var upper = code.Trim().ToUpperInvariant();
            if (string.IsNullOrEmpty(upper))
                return "";
            return NormRx.Replace(upper, "");
        }

        private static void AddToken(Dictionary<string, HashSet<string>> index, string key, string token)
        {
            if (string.IsNullOrEmpty(key) || string.IsNullOrEmpty(token))
                return;

            if (!index.TryGetValue(key, out var set))
            {
                set = new HashSet<string>();
                index[key] = set;
            }

            set.Add(token);
        }
    }
}
