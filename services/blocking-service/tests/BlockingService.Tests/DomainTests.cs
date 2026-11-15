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

    private static CreateBlockRequest R(SubjectType? type, string? id = null, string? route = null,
        string? reason = "test", DateTimeOffset? expires = null, int? ttl = null, bool noSubject = false) => new()
    {
        Subject = noSubject ? null : new SubjectDto { Type = type, Id = id },
        Route = route, Reason = reason, ExpiresAt = expires, TtlSeconds = ttl,
    };

    private static Dictionary<string, string[]> V(CreateBlockRequest r) => BlockValidator.Validate(r, Routes, Now);

    // the 7 valid combinations
    [Theory]
    [InlineData(SubjectType.User, "a@corp.local", null)]
    [InlineData(SubjectType.User, "a@corp.local", "orders")]
    [InlineData(SubjectType.System, "reports-service", null)]
    [InlineData(SubjectType.System, "reports-service", "orders-create")]
    [InlineData(SubjectType.Token, "8f0c6f3e-2f4b-4c51-9a7e-3d6d1c2b9e10", null)]
    [InlineData(SubjectType.Token, "8f0c6f3e-2f4b-4c51-9a7e-3d6d1c2b9e10", "orders")]
    [InlineData(SubjectType.Everyone, null, "orders")]
    public void Valid_combinations(SubjectType type, string? id, string? route) => Assert.Empty(V(R(type, id, route)));

    [Fact]
    public void Everyone_on_all_routes_is_rejected()
    {
        var e = V(R(SubjectType.Everyone));
        Assert.Contains("route", e.Keys);
        Assert.Contains("all traffic", e["route"][0]);
    }

    [Fact] public void Subject_required() => Assert.Contains("subject", V(R(null, noSubject: true)).Keys);
    [Fact] public void Subject_type_required() => Assert.Contains("subject.type", V(R(null, "a")).Keys);

    [Theory]
    [InlineData(SubjectType.User)]
    [InlineData(SubjectType.System)]
    [InlineData(SubjectType.Token)]
    public void Id_required_except_everyone(SubjectType type) => Assert.Contains("subject.id", V(R(type)).Keys);

    [Fact] public void Token_id_error_names_jti() => Assert.Contains("jti", V(R(SubjectType.Token))["subject.id"][0]);
    [Fact] public void Everyone_must_not_have_id() => Assert.Contains("subject.id", V(R(SubjectType.Everyone, "x", "orders")).Keys);
    [Fact] public void Id_with_spaces_rejected() => Assert.Contains("subject.id", V(R(SubjectType.User, " a ")).Keys);
    [Fact] public void Id_too_long_rejected() => Assert.Contains("subject.id", V(R(SubjectType.User, new string('a', 257))).Keys);

    [Fact]
    public void Unknown_route_lists_the_known_ones()
    {
        var e = V(R(SubjectType.User, "a", "nope"));
        Assert.Contains("orders-create", e["route"][0]);
    }

    [Theory]
    [InlineData("")]
    [InlineData("*")]
    public void All_routes_is_null_not_a_wildcard(string route) => Assert.Contains("route", V(R(SubjectType.User, "a", route)).Keys);

    [Fact] public void Reason_required() => Assert.Contains("reason", V(R(SubjectType.User, "a", reason: " ")).Keys);
    [Fact] public void Reason_missing() => Assert.Contains("reason", V(R(SubjectType.User, "a", reason: null)).Keys);
    [Fact] public void Expiry_in_past_rejected() => Assert.Contains("expiresAt", V(R(SubjectType.User, "a", expires: Now.AddSeconds(-1))).Keys);
    [Fact] public void Expiry_and_ttl_exclusive() => Assert.Contains("expiresAt", V(R(SubjectType.User, "a", expires: Now.AddHours(1), ttl: 10)).Keys);
    [Fact] public void Ttl_must_be_positive() => Assert.Contains("ttlSeconds", V(R(SubjectType.User, "a", ttl: 0)).Keys);

    [Fact]
    public void Ttl_becomes_expiry() =>
        Assert.Equal(Now.AddSeconds(30), BlockValidator.EffectiveExpiry(R(SubjectType.User, "a", ttl: 30), Now));

    [Fact]
    public void Target_drops_an_id_for_everyone() =>
        Assert.Equal((SubjectType.Everyone, (string?)null, (string?)"orders"),
            BlockValidator.Target(new CreateBlockRequest { Subject = new() { Type = SubjectType.Everyone }, Route = "orders", Reason = "r" }));

    [Fact]
    public void Request_json_uses_lowercase_types_and_nested_subject()
    {
        var r = JsonSerializer.Deserialize<CreateBlockRequest>(
            """{"subject":{"type":"system","id":"reports-service"},"route":"orders","reason":"leak","ttlSeconds":60}""", Names.Json)!;
        Assert.Equal(SubjectType.System, r.Subject!.Type);
        Assert.Equal("reports-service", r.Subject.Id);
        Assert.Equal("orders", r.Route);
        Assert.Equal(60, r.TtlSeconds);
    }

    [Theory]
    [InlineData("""{"subject":{"type":"group","id":"x"},"reason":"r"}""")]
    [InlineData("""{"subject":{"type":0,"id":"x"},"reason":"r"}""")]
    public void Unknown_or_numeric_type_does_not_bind(string json) =>
        Assert.Throws<JsonException>(() => JsonSerializer.Deserialize<CreateBlockRequest>(json, Names.Json));
}

public class RuleKeyTests
{
    [Theory]
    [InlineData(SubjectType.User, "a@corp.local", null, "user:a@corp.local@*")]
    [InlineData(SubjectType.User, "a@corp.local", "orders", "user:a@corp.local@orders")]
    [InlineData(SubjectType.System, "reports-service", null, "system:reports-service@*")]
    [InlineData(SubjectType.Token, "j1", "orders", "token:j1@orders")]
    [InlineData(SubjectType.Everyone, null, "orders", "everyone:*@orders")]
    public void Keys(SubjectType t, string? id, string? route, string expected) => Assert.Equal(expected, RuleKeys.Key(t, id, route));

    [Fact]
    public void Dto_has_the_request_shape_plus_rule()
    {
        var b = new Block { SubjectType = SubjectType.Token, SubjectId = "j1", Reason = "r", CreatedAt = DateTimeOffset.UnixEpoch };
        using var doc = JsonDocument.Parse(JsonSerializer.Serialize(BlockDto.From(b, DateTimeOffset.UnixEpoch), Names.Json));
        var root = doc.RootElement;
        Assert.Equal("token", root.GetProperty("subject").GetProperty("type").GetString());
        Assert.Equal("j1", root.GetProperty("subject").GetProperty("id").GetString());
        Assert.Equal(JsonValueKind.Null, root.GetProperty("route").ValueKind);
        Assert.Equal("token:j1@*", root.GetProperty("rule").GetString());
        Assert.True(root.GetProperty("active").GetBoolean());
    }
}

public class SnapshotTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 4, 12, 0, 0, TimeSpan.Zero);

    private static Block B(SubjectType t, string? id = null, string? route = null, DateTimeOffset? expires = null, bool removed = false) =>
        new() { SubjectType = t, SubjectId = id, Route = route, Reason = "r", CreatedAt = Now, ExpiresAt = expires, RemovedAt = removed ? Now : null };

    [Fact]
    public void Contains_only_active_rules_sorted()
    {
        var s = SnapshotBuilder.Build([
            B(SubjectType.User, "z@corp.local"),
            B(SubjectType.User, "a@corp.local", "orders"),
            B(SubjectType.User, "gone@corp.local", removed: true),
            B(SubjectType.User, "old@corp.local", expires: Now.AddSeconds(-1)),
            B(SubjectType.System, "reports-service"),
            B(SubjectType.Token, "j1"),
            B(SubjectType.Everyone, route: "orders-create"),
        ], Now);

        Assert.Equal(new[]
        {
            "everyone:*@orders-create", "system:reports-service@*", "token:j1@*",
            "user:a@corp.local@orders", "user:z@corp.local@*",
        }, s.Rules.Keys);
    }

    [Fact]
    public void Rule_value_is_the_block_id()
    {
        var b = B(SubjectType.User, "a");
        Assert.Equal(b.Id.ToString(), SnapshotBuilder.Build([b], Now).Rules["user:a@*"]);
    }

    [Fact]
    public void Version_is_stable_and_order_independent()
    {
        var x = B(SubjectType.User, "a");
        var y = B(SubjectType.User, "b");
        Assert.Equal(SnapshotBuilder.Build([x, y], Now).Version, SnapshotBuilder.Build([y, x], Now).Version);
    }

    [Fact]
    public void Version_changes_when_a_block_expires()
    {
        var blocks = new[] { B(SubjectType.User, "a", expires: Now.AddSeconds(10)) };
        Assert.NotEqual(SnapshotBuilder.Build(blocks, Now).Version, SnapshotBuilder.Build(blocks, Now.AddSeconds(11)).Version);
    }

    [Fact]
    public void Same_id_as_user_and_system_gives_two_rules()
    {
        var s = SnapshotBuilder.Build([B(SubjectType.User, "x"), B(SubjectType.System, "x")], Now);
        Assert.Equal(new[] { "system:x@*", "user:x@*" }, s.Rules.Keys);
    }

    [Fact]
    public void Json_shape_matches_what_the_gateways_expect()
    {
        var s = SnapshotBuilder.Build([B(SubjectType.User, "d", "r")], Now);
        using var doc = JsonDocument.Parse(JsonSerializer.Serialize(s, Names.Json));
        var root = doc.RootElement;
        Assert.Equal(s.Version, root.GetProperty("version").GetString());
        Assert.Equal(JsonValueKind.Object, root.GetProperty("rules").ValueKind);
        Assert.True(root.GetProperty("rules").TryGetProperty("user:d@r", out _));
    }
}

public class OpaBundleTests
{
    [Fact]
    public void Bundle_has_manifest_and_rules_under_blocklist_root()
    {
        var s = SnapshotBuilder.Build([new Block { SubjectType = SubjectType.User, SubjectId = "a", Reason = "r" }], DateTimeOffset.UtcNow);
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
        Assert.True(data.RootElement.GetProperty("rules").TryGetProperty("user:a@*", out _));
    }
}
