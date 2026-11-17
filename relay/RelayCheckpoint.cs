using System;
using System.IO;
using System.Security.Cryptography;

namespace MPFever.StandaloneRelay
{
    /// <summary>The relay's latest complete checkpoint. The first 32 bytes contain the expected SHA-256 of the save.</summary>
    sealed class RelayCheckpoint : IDisposable
    {
        internal const int ChunkSize = 1024 * 1024;
        internal const long MaxSize = 1024L * 1024 * 1024;
        const int HashSize = 32;

        readonly string current, pending;
        readonly FileStream directoryLock;
        FileStream upload;
        IncrementalHash digest;
        byte[] expectedHash;
        long remaining;

        public RelayCheckpoint(string directory)
        {
            // (a directory made here is private to the account that runs the relay, and so are its files: the save is a whole world)
            if (OperatingSystem.IsWindows()) Directory.CreateDirectory(directory);
            else
            {
                Directory.CreateDirectory(directory, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
                if ((File.GetUnixFileMode(directory) & (UnixFileMode.GroupRead | UnixFileMode.OtherRead | UnixFileMode.GroupWrite | UnixFileMode.OtherWrite)) != 0)
                    Log.Warn("the checkpoint directory " + directory + " can be read by other accounts: chmod 700 it");
            }
            current = Path.Combine(directory, "checkpoint.bin");
            pending = Path.Combine(directory, "checkpoint.partial");
            directoryLock = Open(Path.Combine(directory, "checkpoint.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite);
            try { File.Delete(pending); }
            catch { directoryLock.Dispose(); throw; }
        }

        /// <summary>A file only its owner may read or write (on Unix: mode 600; Windows keeps the folder's rights).</summary>
        static FileStream Open(string path, FileMode mode, FileAccess access)
        {
            var options = new FileStreamOptions { Mode = mode, Access = access, Share = FileShare.None };
            if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
            return new FileStream(path, options);
        }

        public void Begin(long size, byte[] hash)
        {
            if (size <= 0 || size > MaxSize) throw new ArgumentOutOfRangeException(nameof(size));
            if (hash?.Length != HashSize) throw new ArgumentException("Expected a SHA-256 digest", nameof(hash));
            Abort();
            upload = Open(pending, FileMode.CreateNew, FileAccess.Write);
            try
            {
                upload.Write(hash);
                digest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                expectedHash = (byte[])hash.Clone();
                remaining = size;
            }
            catch { Abort(); throw; }
        }

        public bool Append(byte[] bytes)
        {
            if (upload == null || bytes == null || bytes.Length == 0 || bytes.Length > ChunkSize || bytes.Length > remaining) return false;
            upload.Write(bytes);
            digest.AppendData(bytes);
            remaining -= bytes.Length;
            return true;
        }

        public bool Complete()
        {
            try
            {
                if (upload == null || remaining != 0 || !CryptographicOperations.FixedTimeEquals(digest.GetHashAndReset(), expectedHash)) return false;
                upload.Flush(flushToDisk: true);
                upload.Dispose();
                upload = null;
                // Same directory, so replacing the complete file cannot expose a partly written save.
                File.Move(pending, current, overwrite: true);
                return true;
            }
            finally { Abort(); }
        }

        public void Abort()
        {
            upload?.Dispose();
            upload = null;
            digest?.Dispose();
            digest = null;
            expectedHash = null;
            remaining = 0;
            File.Delete(pending);
        }

        public FileStream Open(out long size, out string sha)
        {
            size = 0;
            sha = null;
            if (!File.Exists(current)) return null;
            var file = new FileStream(current, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete);
            try
            {
                size = file.Length - HashSize;
                if (size <= 0 || size > MaxSize) throw new IOException("Invalid relay checkpoint length");
                var hash = new byte[HashSize];
                file.ReadExactly(hash);
                sha = Convert.ToHexString(hash).ToLowerInvariant();
                return file;
            }
            catch { file.Dispose(); throw; }
        }

        public void Dispose()
        {
            try { Abort(); }
            finally { directoryLock.Dispose(); }
        }
    }
}

