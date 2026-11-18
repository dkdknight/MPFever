using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace MPFever.StandaloneRelay
{
    // Test-only copy of the literal reader from upstream 0.8.11. Use only with generated well-formed input.
    static class LegacyLuaLit
    {
        public static object Parse(string s)
        {
            int i = 0;
            var v = Value(s, ref i);
            return v;
        }

        static void Ws(string s, ref int i) { while (i < s.Length && char.IsWhiteSpace(s[i])) i++; }

        static object Value(string s, ref int i)
        {
            Ws(s, ref i);
            if (i >= s.Length) return null;
            char c = s[i];
            if (c == '{') return Table(s, ref i);
            if (c == '"') return Str(s, ref i);
            // (compared in place: a copy of the rest of the text at every value made a station's 850 KB build take 30 s to read,
            // and the reader of that player's messages, their clock among them, stood still meanwhile: issue #54)
            if (string.CompareOrdinal(s, i, "true", 0, 4) == 0) { i += 4; return true; }
            if (string.CompareOrdinal(s, i, "false", 0, 5) == 0) { i += 5; return false; }
            if (string.CompareOrdinal(s, i, "nil", 0, 3) == 0) { i += 3; return null; }
            int st = i;
            while (i < s.Length && "+-0123456789.eE".IndexOf(s[i]) >= 0) i++;
            double.TryParse(s.Substring(st, i - st), NumberStyles.Float, CultureInfo.InvariantCulture, out var d);
            return d;
        }

        static Dictionary<object, object> Table(string s, ref int i)
        {
            var t = new Dictionary<object, object>();
            i++; // {
            while (true)
            {
                Ws(s, ref i);
                if (i >= s.Length) return t;
                if (s[i] == '}') { i++; return t; }
                if (s[i] == ',') { i++; continue; }
                if (s[i] == '[')
                {
                    i++;
                    var k = Value(s, ref i);
                    Ws(s, ref i);
                    if (i < s.Length && s[i] == ']') i++;
                    Ws(s, ref i);
                    if (i < s.Length && s[i] == '=') i++;
                    var v = Value(s, ref i);
                    if (k != null) t[Norm(k)] = v;
                }
                else { Value(s, ref i); }
            }
        }

        static object Norm(object k) => k is double d && d == Math.Floor(d) ? (object)(long)d : k;

        static string Str(string s, ref int i)
        {
            var sb = new StringBuilder();
            i++; // opening quote
            while (i < s.Length && s[i] != '"')
            {
                if (s[i] == '\\' && i + 1 < s.Length)
                {
                    i++;
                    char e = s[i];
                    if (e == 'n') sb.Append('\n');
                    else if (e == 'r') sb.Append('\r');
                    else if (char.IsDigit(e))
                    {
                        int st = i;
                        while (i < s.Length && i - st < 3 && char.IsDigit(s[i])) i++;
                        sb.Append((char)int.Parse(s.Substring(st, i - st)));
                        continue;
                    }
                    else sb.Append(e);
                    i++;
                }
                else { sb.Append(s[i]); i++; }
            }
            i++; // closing quote
            return sb.ToString();
        }
    }
}
