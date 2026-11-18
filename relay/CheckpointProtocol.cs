using System;
using System.Collections.Generic;
using System.IO;

namespace MPFever.StandaloneRelay
{
    sealed partial class SessionCore
    {
        readonly object checkpointGate = new object();
        RelayCheckpoint checkpoint;
        Peer checkpointUpload;
        Peer checkpointDownload;
        string checkpointDownloadSha;
        long checkpointDownloadAt;
        Peer checkpointRestored;

        void CloseCheckpoint()
        {
            lock (checkpointGate)
            {
                checkpoint?.Dispose();
                checkpoint = null;
            }
        }

        void ReleaseCheckpoint(Peer peer)
        {
            lock (checkpointGate)
            {
                if (checkpointUpload == peer)
                {
                    checkpointUpload = null;
                    checkpoint?.Abort();
                }
                if (checkpointDownload == peer) checkpointDownload = null;
                if (checkpointRestored == peer) checkpointRestored = null;
            }
        }

        void HandleCheckpoint(Msg message, Peer sender)
        {
            var fields = CheckpointWire.Read(message);
            string id = CheckpointWire.Text(fields, "id");
            if (!Guid.TryParseExact(id, "N", out _)) return;

            Msg reply;
            lock (checkpointGate)
            {
                // (review of PR #412: only the host may; the disk work is done outside hostGate, which every player's message takes:
                // a save written to a slow disk held the whole session)
                lock (hostGate) { if (sender != host) return; }
                {
                    // (a relay started without --checkpoint-dir keeps nothing: it says so instead of leaving the launcher to time out)
                    if (checkpoint == null) { reply = CheckpointReply(id, "empty"); }
                    else try { reply = CheckpointRequest(message, sender, fields, id); }
                    catch (Exception e) when (e is IOException || e is UnauthorizedAccessException)
                    {
                        try { ReleaseCheckpoint(sender); }
                        catch (Exception cleanup) when (cleanup is IOException || cleanup is UnauthorizedAccessException)
                        { Log.Warn("checkpoint cleanup: " + cleanup.Message); }
                        Log.Warn("checkpoint storage: " + e.Message);
                        reply = CheckpointReply(id, "io");
                    }
                }
            }
            relay.Send(sender, reply);
        }

        Msg CheckpointReply(string id, string status, string extra = "")
            => Msg.Make(CheckpointWire.Reply, HostName, "{" + CheckpointWire.Field("id", id) + "," + CheckpointWire.Field("status", status) + extra + "}");

        bool OwnerKey(string key) => !string.IsNullOrEmpty(opt.CheckpointOwnerKey) && SamePassword(key, opt.CheckpointOwnerKey);
        /// <summary>The key of the owner or of the trusted player. Wrong keys count like wrong passwords: after MaxBadPasswords from one
        /// address it is refused for LockoutSeconds, even with the right key.</summary>
        bool KeyOk(Peer sender, string key)
        {
            string ip = AddressOf(sender);
            if (LockedOut(ip)) return false;
            if (OwnerKey(key) || RecoveryKey(key)) return true;
            NoteBadPassword(ip);
            return false;
        }

        bool RecoveryKey(string key) => opt.ResumeWithoutHost && !string.IsNullOrEmpty(opt.CheckpointRecoveryKey) && SamePassword(key, opt.CheckpointRecoveryKey);

        Msg CheckpointRequest(Msg m, Peer sender, Dictionary<object, object> fields, string id)
        {
            if (m.Kind == CheckpointWire.Binary)
            {
                if (checkpointUpload == sender && checkpoint.Append(m.Data)) return CheckpointReply(id, "part");
                ReleaseCheckpoint(sender);
                return CheckpointReply(id, "invalid");
            }

            string key = CheckpointWire.Text(fields, "key");
            switch (CheckpointWire.Text(fields, "op"))
            {
                case "begin":
                    // (the recovery key is the key of a player trusted to host: it may store the save it goes on with, too)
                    if (checkpointRestored != sender && !KeyOk(sender, key)) return CheckpointReply(id, "denied");
                    if (!CheckpointWire.Number(fields, "size", CheckpointWire.MaxSize, out var bytes) || bytes == 0)
                        return CheckpointReply(id, "invalid");
                    string hashText = CheckpointWire.Text(fields, "sha");
                    if (hashText?.Length != 64) return CheckpointReply(id, "invalid");
                    byte[] hash;
                    try { hash = Convert.FromHexString(hashText); }
                    catch (FormatException) { return CheckpointReply(id, "invalid"); }
                    checkpointUpload = sender;
                    checkpoint.Begin(bytes, hash);
                    return CheckpointReply(id, "upload");
                case "commit":
                    if (checkpointUpload != sender) return CheckpointReply(id, "invalid");
                    checkpointUpload = null;
                    return CheckpointReply(id, checkpoint.Complete() ? "saved" : "invalid");
                case "open":
                    if (!KeyOk(sender, key)) return CheckpointReply(id, "denied");
                    checkpointDownload = null;
                    using (var file = checkpoint.Open(out var size, out var sha))
                    {
                        if (file == null) return CheckpointReply(id, "empty");
                        checkpointDownload = sender;
                        checkpointDownloadSha = sha;
                        checkpointDownloadAt = 0;
                        return CheckpointReply(id, "download", "," + CheckpointWire.Field("size", size) + "," + CheckpointWire.Field("sha", sha));
                    }
                case "read":
                    return ReadCheckpoint(sender, fields, id);
                case "loaded":
                    if (checkpointDownload != sender) return CheckpointReply(id, "denied");
                    using (var file = checkpoint.Open(out var size, out var sha))
                    {
                        if (file == null || sha != checkpointDownloadSha || checkpointDownloadAt != size)
                            return CheckpointReply(id, "invalid");
                    }
                    checkpointDownload = null;
                    checkpointRestored = sender;
                    return CheckpointReply(id, "ready");
                default:
                    return CheckpointReply(id, "invalid");
            }
        }

        Msg ReadCheckpoint(Peer sender, Dictionary<object, object> fields, string id)
        {
            if (checkpointDownload != sender) return CheckpointReply(id, "denied");
            using var file = checkpoint.Open(out var size, out var sha);
            if (file == null || sha != checkpointDownloadSha) return CheckpointReply(id, "changed");
            if (!CheckpointWire.Number(fields, "offset", size - 1, out var offset) || offset != checkpointDownloadAt)
                return CheckpointReply(id, "invalid");
            file.Position += offset;
            int count = (int)Math.Min(CheckpointWire.ChunkSize, size - offset);
            var data = new byte[count];
            file.ReadExactly(data);
            checkpointDownloadAt += count;
            return new Msg { Kind = CheckpointWire.Binary, From = HostName, Data = data,
                Payload = "{" + CheckpointWire.Field("id", id) + "," + CheckpointWire.Field("offset", offset)
                    + "," + CheckpointWire.Field("len", count) + "}" };
        }
    }
}

