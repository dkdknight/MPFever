using System;
using System.Security.Cryptography;
using System.Text;

namespace MPFever
{
    /// <summary>The relay's password and key in mpfever_settings.txt: written protected by Windows (DPAPI, this Windows account on this PC),
    /// as "dpapi:" and a base64 text, so that the file (copied, synchronised, sent in a report by mistake) does not give them away.
    /// A value without that prefix is read as it is: a file typed by hand, or written by the first versions, keeps working. If Windows
    /// cannot protect (nothing breaks: the value is written as it is) or unprotect it (another account or PC: the value is empty and the
    /// player enters it again in the Relay window).</summary>
    static class SecretStore
    {
        internal const string Prefix = "dpapi:";
        static readonly byte[] Entropy = Encoding.UTF8.GetBytes("MPFever relay settings");

        internal static bool IsProtected(string stored) => stored != null && stored.StartsWith(Prefix, StringComparison.Ordinal);

        /// <summary>The text to write in the settings file for a secret ("" stays "").</summary>
        internal static string Protect(string plain)
        {
            if (string.IsNullOrEmpty(plain) || IsProtected(plain)) return plain ?? "";
            try
            {
                var blob = ProtectedData.Protect(Encoding.UTF8.GetBytes(plain), Entropy, DataProtectionScope.CurrentUser);
                return Prefix + Convert.ToBase64String(blob);
            }
            catch (Exception) { return plain; }
        }

        /// <summary>The secret a settings value holds; null when it is protected and cannot be opened here.</summary>
        internal static string Unprotect(string stored)
        {
            if (string.IsNullOrEmpty(stored) || !IsProtected(stored)) return stored ?? "";
            try
            {
                var blob = Convert.FromBase64String(stored.Substring(Prefix.Length).Trim());
                return Encoding.UTF8.GetString(ProtectedData.Unprotect(blob, Entropy, DataProtectionScope.CurrentUser));
            }
            catch (Exception) { return null; }
        }
    }
}
