using System.Formats.Tar;
using System.IO.Compression;
using System.Text;
using System.Text.Json;

namespace BlockingService.Domain;

/// <summary>
/// Builds an OPA bundle (tar.gz) that holds only DATA under the root "blocklist":
///   /.manifest            {"revision": "&lt;version&gt;", "roots": ["blocklist"]}
///   /blocklist/data.json  the snapshot  ->  data.blocklist.* in Rego
/// The Rego policy itself comes from Git (opa/policy), not from this service.
/// </summary>
public static class OpaBundle
{
    public static byte[] Build(Snapshot snapshot)
    {
        using var output = new MemoryStream();
        using (var gzip = new GZipStream(output, CompressionLevel.Fastest, leaveOpen: true))
        using (var tar = new TarWriter(gzip, TarEntryFormat.Pax, leaveOpen: false))
        {
            var manifest = JsonSerializer.Serialize(new { revision = snapshot.Version, roots = new[] { "blocklist" } });
            Write(tar, ".manifest", manifest);
            Write(tar, "blocklist/data.json", JsonSerializer.Serialize(snapshot));
        }
        return output.ToArray();
    }

    private static void Write(TarWriter tar, string name, string content)
    {
        var entry = new PaxTarEntry(TarEntryType.RegularFile, name)
        {
            DataStream = new MemoryStream(Encoding.UTF8.GetBytes(content)),
            Mode = UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.GroupRead | UnixFileMode.OtherRead,
            ModificationTime = DateTimeOffset.UnixEpoch,
        };
        tar.WriteEntry(entry);
    }
}
