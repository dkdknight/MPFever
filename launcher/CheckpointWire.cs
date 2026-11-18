using System;
using System.Collections.Generic;
using System.Globalization;

namespace MPFever
{
    static class CheckpointWire
    {
        public const int ChunkSize = 1024 * 1024;
        public const long MaxSize = 1024L * 1024 * 1024;
        public const string Request = "tun_checkpoint";
        public const string Binary = "tun_checkpoint_bin";
        public const string Reply = "tun_checkpoint_reply";

        public static Dictionary<object, object> Read(Msg message) => LuaLit.Parse(message.Payload) as Dictionary<object, object>;
        public static string Text(Dictionary<object, object> fields, string key)
            => fields != null && fields.TryGetValue(key, out var value) ? value as string : null;
        public static bool Number(Dictionary<object, object> fields, string key, long max, out long result)
        {
            result = 0;
            if (fields == null || !fields.TryGetValue(key, out var value) || !(value is double d) ||
                !(d >= 0 && d <= max) || d != Math.Floor(d)) return false;
            result = (long)d;
            return true;
        }

        public static string Field(string key, string value) => "[\"" + key + "\"]=" + LuaLit.Quote(value);
        public static string Field(string key, long value) => "[\"" + key + "\"]=" + value.ToString(CultureInfo.InvariantCulture);
        public static string Hex(byte[] bytes) => BitConverter.ToString(bytes).Replace("-", "").ToLowerInvariant();
    }
}

