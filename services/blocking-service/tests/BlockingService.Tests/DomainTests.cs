using System.Formats.Tar;
using System.IO.Compression;
using System.Text.Json;
using BlockingService.Domain;
using Xunit;

namespace BlockingService.Tests;

public class ValidatorTests
{
    private static readonly HashSet<string> Routes = ["orders", "orders-create"];
    private static readonly DateTimeOffset Now = new(2026, 11, 4, 12, 0, 0, TimeSpan.Zero);

    private static Dictionary<string, string[]> V(BlockKind kind, string? caller = null, string? route = null,
        string reason = "test", DateTimeOffset? expires = null, int? ttl = null) =>
        BlockValidator.Validate(new CreateBlockRequest(kind, caller, route, reason, expires, ttl), Routes, Now);

    [Fact] public void User_needs_caller() => Assert.Contains("callerId", V(BlockKind.User).Keys);
    [Fact] public void User_must_not_have_route() => Assert.Contains("route", V(BlockKind.User, "a@corp.local", "orders").Keys);
    [Fact] public void Valid_user() => Assert.Empty(V(BlockKind.User, "a@corp.local"));
    [Fact] public void Valid_system_token() => Assert.Empty(V(BlockKind.SystemToken, "reports-service"));
    [Fact] public void Route_needs_known_route() => Assert.Contains("route", V(BlockKind.Route, route: "nope").Keys);
    [Fact] public void Valid_route() => Assert.Empty(V(BlockKind.Route, route: "orders"));
    [Fact] public void Route_must_not_have_caller() => Assert.Contains("callerId", V(BlockKind.Route, "x", "orders").Keys);
    [Fact] public void UserOnRoute_needs_both() => Assert.Equal(2, V(BlockKind.UserOnRoute).Count);
    [Fact] public void Valid_user_on_route() => Assert.Empty(V(BlockKind.UserOnRoute, "a@corp.local", "orders-create"));
    [Fact] public void Reason_required() => Assert.Contains("reason", V(BlockKind.User, "a", reason: " ").Keys);
    [Fact] public void Expiry_in_past_rejected() => Assert.Contains("expiresAt", V(BlockKind.User, "a", expires: Now.AddSeconds(-1)).Keys);
    [Fact] public void Expiry_and_ttl_exclusive() => Assert.Contains("expiresAt", V(BlockKind.User, "a", expires: Now.AddHours(1), ttl: 10).Keys);
    [Fact] public void Caller_with_spaces_rejected() => Assert.Contains("callerId", V(BlockKind.User, " a ").Keys);

    [Fact]
    public void Ttl_becomes_expiry()
    {
        var r = new CreateBlockRequest(BlockKind.User, "a", null, "x", null, 30);
        Assert.Equal(Now.AddSeconds(30), BlockValidator.EffectiveExpiry(r, Now));
    }

    [Fact]
    public void Kind_names_are_snake_case() =>
        Assert.Equal("user_on_route", Names.Kind(BlockKind.UserOnRoute));

    [Fact]
    public void Request_json_uses_snake_case_kinds()
    {
        var r = JsonSerializer.Deserialize<CreateBlockRequest>(
            """{"kind":"system_token","callerId":"reports-service","reason":"leak"}""", Names.Json)!;
        Assert.Equal(BlockKind.SystemToken, r.Kind);
    }
}

public class SnapshotTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 4, 12, 0, 0, TimeSpan.Zero);

    private static Block B(BlockKind k, string? caller = null, string? route = null, DateTimeOffset? expires = null, bool removed = false) =>
        new() { Kind = k, CallerId = caller, Route = route, Reason = "r", CreatedAt = Now, ExpiresAt = expires, RemovedAt = removed ? Now : null };

    [Fact]
    public void Contains_only_active_blocks_sorted_by_kind()
    {
        var s = SnapshotBuilder.Build([
            B(BlockKind.User, "z@corp.local"),
            B(BlockKind.User, "a@corp.local"),
            B(BlockKind.User, "gone@corp.local", removed: true),
            B(BlockKind.User, "old@corp.local", expires: Now.AddSeconds(-1)),
            B(BlockKind.SystemToken, "reports-service"),
            B(BlockKind.Route, route: "orders"),
            B(BlockKind.UserOnRoute, "d@corp.local", "orders-create"),
        ], Now);

        Assert.Equal(new[] { "a@corp.local", "z@corp.local" }, s.Users);
        Assert.Equal(new[] { "reports-service" }, s.SystemTokens);
        Assert.Equal(new[] { "orders" }, s.Routes);
        Assert.Equal(new[] { new UserOnRoute("d@corp.local", "orders-create") }, s.UserOnRoute);
    }

    [Fact]
    public void Version_is_stable_and_order_independent()
    {
        var a = SnapshotBuilder.Build([B(BlockKind.User, "a"), B(BlockKind.User, "b")], Now);
        var b = SnapshotBuilder.Build([B(BlockKind.User, "b"), B(BlockKind.User, "a")], Now);
        Assert.Equal(a.Version, b.Version);
    }

    [Fact]
    public void Version_changes_when_a_block_expires()
    {
        var blocks = new[] { B(BlockKind.User, "a", expires: Now.AddSeconds(10)) };
        Assert.NotEqual(SnapshotBuilder.Build(blocks, Now).Version, SnapshotBuilder.Build(blocks, Now.AddSeconds(11)).Version);
    }

    [Fact]
    public void Same_caller_as_user_and_system_token_stays_separate()
    {
        var s = SnapshotBuilder.Build([B(BlockKind.User, "x"), B(BlockKind.SystemToken, "y")], Now);
        Assert.DoesNotContain("y", s.Users);
        Assert.DoesNotContain("x", s.SystemTokens);
    }

    [Fact]
    public void Json_shape_matches_what_the_gateways_expect()
    {
        var s = SnapshotBuilder.Build([B(BlockKind.UserOnRoute, "d", "r")], Now);
        using var doc = JsonDocument.Parse(JsonSerializer.Serialize(s));
        var root = doc.RootElement;
        foreach (var p in new[] { "version", "users", "system_tokens", "routes", "user_on_route" })
            Assert.True(root.TryGetProperty(p, out _), $"missing {p}");
        Assert.Equal("d", root.GetProperty("user_on_route")[0].GetProperty("caller_id").GetString());
    }
}

public class OpaBundleTests
{
    [Fact]
    public void Bundle_has_manifest_and_data_under_blocklist_root()
    {
        var s = SnapshotBuilder.Build([new Block { Kind = BlockKind.User, CallerId = "a", Reason = "r" }], DateTimeOffset.UtcNow);
        var files = new Dictionary<string, string>();
        using (var gz = new GZipStream(new MemoryStream(OpaBundle.Build(s)), CompressionMode.Decompress))
        using (var tar = new TarReader(gz))
        {
            while (tar.GetNextEntry() is { } e)
            {
                using var r = new StreamReader(e.DataStream!);
                files[e.Name] = r.ReadToEnd();
            }
        }

        Assert.Equal(new[] { ".manifest", "blocklist/data.json" }, files.Keys.Order(StringComparer.Ordinal));
        using var manifest = JsonDocument.Parse(files[".manifest"]);
        Assert.Equal(s.Version, manifest.RootElement.GetProperty("revision").GetString());
        Assert.Equal("blocklist", manifest.RootElement.GetProperty("roots")[0].GetString());
        using var data = JsonDocument.Parse(files["blocklist/data.json"]);
        Assert.Equal("a", data.RootElement.GetProperty("users")[0].GetString());
    }
}
