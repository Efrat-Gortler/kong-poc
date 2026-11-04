using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace BlockingService.Domain;

/// <summary>Request body for POST /api/blocks.</summary>
public record CreateBlockRequest(
    BlockKind Kind,
    string? CallerId,
    string? Route,
    string Reason,
    DateTimeOffset? ExpiresAt,
    int? TtlSeconds);

public static class BlockValidator
{
    public const int MaxReasonLength = 512;

    /// <summary>Returns field -> errors; empty when valid.</summary>
    public static Dictionary<string, string[]> Validate(CreateBlockRequest r, IReadOnlySet<string> knownRoutes, DateTimeOffset now)
    {
        var errors = new Dictionary<string, List<string>>();
        void Add(string field, string msg)
        {
            if (!errors.TryGetValue(field, out var l)) errors[field] = l = [];
            l.Add(msg);
        }

        var needsCaller = r.Kind is BlockKind.User or BlockKind.SystemToken or BlockKind.UserOnRoute;
        var needsRoute = r.Kind is BlockKind.Route or BlockKind.UserOnRoute;

        if (needsCaller && string.IsNullOrWhiteSpace(r.CallerId)) Add("callerId", $"required for kind {Names.Kind(r.Kind)}");
        if (!needsCaller && !string.IsNullOrEmpty(r.CallerId)) Add("callerId", $"not allowed for kind {Names.Kind(r.Kind)}");
        if (needsRoute && string.IsNullOrWhiteSpace(r.Route)) Add("route", $"required for kind {Names.Kind(r.Kind)}");
        if (!needsRoute && !string.IsNullOrEmpty(r.Route)) Add("route", $"not allowed for kind {Names.Kind(r.Kind)}");
        if (needsRoute && !string.IsNullOrWhiteSpace(r.Route) && !knownRoutes.Contains(r.Route))
            Add("route", $"unknown route '{r.Route}'");
        if (r.CallerId is { Length: > 256 }) Add("callerId", "too long");
        if (r.CallerId is not null && r.CallerId != r.CallerId.Trim()) Add("callerId", "must not have leading/trailing spaces");

        if (string.IsNullOrWhiteSpace(r.Reason)) Add("reason", "required");
        else if (r.Reason.Length > MaxReasonLength) Add("reason", "too long");

        if (r.ExpiresAt is not null && r.TtlSeconds is not null) Add("expiresAt", "use expiresAt or ttlSeconds, not both");
        if (r.ExpiresAt is not null && r.ExpiresAt <= now) Add("expiresAt", "must be in the future");
        if (r.TtlSeconds is <= 0) Add("ttlSeconds", "must be positive");

        return errors.ToDictionary(kv => kv.Key, kv => kv.Value.ToArray());
    }

    public static DateTimeOffset? EffectiveExpiry(CreateBlockRequest r, DateTimeOffset now) =>
        r.ExpiresAt ?? (r.TtlSeconds is { } ttl ? now.AddSeconds(ttl) : null);

    /// <summary>Two active blocks are duplicates when they block the same thing.</summary>
    public static bool SameTarget(Block a, BlockKind kind, string? callerId, string? route) =>
        a.Kind == kind && a.CallerId == callerId && a.Route == route;
}

public static class Names
{
    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.SnakeCaseLower) },
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public static string Kind(BlockKind k) => JsonNamingPolicy.SnakeCaseLower.ConvertName(k.ToString());
}

/// <summary>What the gateways consume (Lua plugin snapshot and OPA bundle data).</summary>
public record Snapshot(
    [property: JsonPropertyName("version")] string Version,
    [property: JsonPropertyName("users")] IReadOnlyList<string> Users,
    [property: JsonPropertyName("system_tokens")] IReadOnlyList<string> SystemTokens,
    [property: JsonPropertyName("routes")] IReadOnlyList<string> Routes,
    [property: JsonPropertyName("user_on_route")] IReadOnlyList<UserOnRoute> UserOnRoute);

public record UserOnRoute(
    [property: JsonPropertyName("caller_id")] string CallerId,
    [property: JsonPropertyName("route")] string Route);

public static class SnapshotBuilder
{
    /// <summary>
    /// Deterministic snapshot of the ACTIVE blocks. The version is a hash of the
    /// content, so it changes exactly when the effective list changes (including
    /// when a block expires) and is identical on every replica of this service.
    /// </summary>
    public static Snapshot Build(IEnumerable<Block> blocks, DateTimeOffset now)
    {
        var active = blocks.Where(b => b.IsActive(now)).ToList();
        static List<string> Sorted(IEnumerable<string?> xs) =>
            xs.OfType<string>().Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToList();

        var users = Sorted(active.Where(b => b.Kind == BlockKind.User).Select(b => b.CallerId));
        var tokens = Sorted(active.Where(b => b.Kind == BlockKind.SystemToken).Select(b => b.CallerId));
        var routes = Sorted(active.Where(b => b.Kind == BlockKind.Route).Select(b => b.Route));
        var pairs = active.Where(b => b.Kind == BlockKind.UserOnRoute && b.CallerId is not null && b.Route is not null)
            .Select(b => new UserOnRoute(b.CallerId!, b.Route!))
            .Distinct()
            .OrderBy(p => p.CallerId, StringComparer.Ordinal).ThenBy(p => p.Route, StringComparer.Ordinal)
            .ToList();

        var canonical = JsonSerializer.Serialize(new { users, tokens, routes, pairs });
        var version = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(canonical)))[..16];
        return new Snapshot(version, users, tokens, routes, pairs);
    }
}
