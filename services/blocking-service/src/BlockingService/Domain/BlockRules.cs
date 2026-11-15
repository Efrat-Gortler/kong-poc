using System.ComponentModel.DataAnnotations;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace BlockingService.Domain;

/// <summary>WHO is blocked.</summary>
public class SubjectDto
{
    /// <summary>
    /// user = a person (caller_id = upn); system = an application (caller_id = client id of a
    /// client-credentials token); token = one specific token (its jti claim); everyone = every caller
    /// (no id, needs a route).
    /// </summary>
    /// <example>user</example>
    [Required]
    public SubjectType? Type { get; set; }

    /// <summary>caller_id for user and system, the jti claim for token. Omit (or null) for everyone. Exact match, case-sensitive.</summary>
    /// <example>666efratg@corp.local</example>
    public string? Id { get; set; }
}

/// <summary>Request body for POST /api/blocks: a block = WHO (subject) + WHERE (route).</summary>
public class CreateBlockRequest
{
    /// <summary>WHO is blocked.</summary>
    [Required]
    public SubjectDto? Subject { get; set; }

    /// <summary>WHERE: a known route name (GET /api/routes). Null or omitted = all routes (not allowed for everyone).</summary>
    /// <example>orders-create</example>
    public string? Route { get; set; }

    /// <summary>Why (audit and gateway logs only; never shown to the blocked caller). 1-512 characters.</summary>
    /// <example>abnormal request volume</example>
    [Required]
    public string? Reason { get; set; }

    /// <summary>Optional end of the block (ISO 8601, in the future). Use either expiresAt or ttlSeconds.</summary>
    /// <example>2026-12-31T23:59:59Z</example>
    public DateTimeOffset? ExpiresAt { get; set; }

    /// <summary>Optional lifetime in seconds from now (positive). Use either expiresAt or ttlSeconds.</summary>
    /// <example>3600</example>
    public int? TtlSeconds { get; set; }
}

/// <summary>A block as returned by the API: the request shape plus its rule key and lifecycle.</summary>
public class BlockDto
{
    /// <example>3f2504e0-4f89-11d3-9a0c-0305e82c3301</example>
    public Guid Id { get; init; }
    /// <summary>WHO is blocked.</summary>
    public SubjectDto Subject { get; init; } = new();
    /// <summary>WHERE: the route name, or null = all routes.</summary>
    /// <example>orders-create</example>
    public string? Route { get; init; }
    /// <summary>The key the gateways look up: type:id@route ("@*" = all routes).</summary>
    /// <example>user:666efratg@corp.local@orders-create</example>
    public string Rule { get; init; } = "";
    /// <example>abnormal request volume</example>
    public string Reason { get; init; } = "";
    /// <example>opsadmin@corp.local</example>
    public string CreatedBy { get; init; } = "";
    public DateTimeOffset CreatedAt { get; init; }
    public DateTimeOffset? ExpiresAt { get; init; }
    public DateTimeOffset? RemovedAt { get; init; }
    public string? RemovedBy { get; init; }
    /// <summary>True while the block is enforced (not removed, not expired).</summary>
    public bool Active { get; init; }

    public static BlockDto From(Block b, DateTimeOffset now) => new()
    {
        Id = b.Id,
        Subject = new SubjectDto { Type = b.SubjectType, Id = b.SubjectId },
        Route = b.Route,
        Rule = b.RuleKey,
        Reason = b.Reason,
        CreatedBy = b.CreatedBy,
        CreatedAt = b.CreatedAt,
        ExpiresAt = b.ExpiresAt,
        RemovedAt = b.RemovedAt,
        RemovedBy = b.RemovedBy,
        Active = b.IsActive(now),
    };
}

public static class BlockValidator
{
    public const int MaxReasonLength = 512;
    public const int MaxIdLength = 256;

    /// <summary>Returns field path -> errors (ASP.NET ValidationProblem shape); empty when valid.</summary>
    public static Dictionary<string, string[]> Validate(CreateBlockRequest r, IReadOnlySet<string> knownRoutes, DateTimeOffset now)
    {
        var errors = new Dictionary<string, List<string>>();
        void Add(string field, string msg)
        {
            if (!errors.TryGetValue(field, out var l)) errors[field] = l = [];
            l.Add(msg);
        }

        var type = r.Subject?.Type;
        var id = r.Subject?.Id;
        if (r.Subject is null) Add("subject", "required: { \"type\": \"user\" | \"system\" | \"token\" | \"everyone\", \"id\": \"...\" }");
        else if (type is null) Add("subject.type", "required: user | system | token | everyone");

        if (type is SubjectType.Everyone)
        {
            if (!string.IsNullOrEmpty(id)) Add("subject.id", "must be omitted for subject.type everyone");
        }
        else if (type is not null)
        {
            var what = type == SubjectType.Token ? "the token's jti" : "the caller_id";
            if (string.IsNullOrWhiteSpace(id)) Add("subject.id", $"required for subject.type {RuleKeys.TypeName(type.Value)} ({what})");
            else
            {
                if (id.Length > MaxIdLength) Add("subject.id", $"at most {MaxIdLength} characters");
                if (id != id.Trim()) Add("subject.id", "must not have leading/trailing spaces");
            }
        }

        if (r.Route is not null)
        {
            if (r.Route is "" or RuleKeys.All) Add("route", "omit it (or null) for all routes");
            else if (!knownRoutes.Contains(r.Route))
                Add("route", $"unknown route '{r.Route}'; known: {string.Join(", ", knownRoutes.Order(StringComparer.Ordinal))}");
        }
        if (type is SubjectType.Everyone && r.Route is null)
            Add("route", "required for subject.type everyone: blocking everyone on all routes would stop all traffic");

        if (string.IsNullOrWhiteSpace(r.Reason)) Add("reason", "required");
        else if (r.Reason.Length > MaxReasonLength) Add("reason", $"at most {MaxReasonLength} characters");

        if (r.ExpiresAt is not null && r.TtlSeconds is not null) Add("expiresAt", "use expiresAt or ttlSeconds, not both");
        if (r.ExpiresAt is not null && r.ExpiresAt <= now) Add("expiresAt", "must be in the future");
        if (r.TtlSeconds is <= 0) Add("ttlSeconds", "must be positive");

        return errors.ToDictionary(kv => kv.Key, kv => kv.Value.ToArray());
    }

    public static DateTimeOffset? EffectiveExpiry(CreateBlockRequest r, DateTimeOffset now) =>
        r.ExpiresAt ?? (r.TtlSeconds is { } ttl ? now.AddSeconds(ttl) : null);

    /// <summary>The block a valid request describes (id normalised to null for everyone).</summary>
    public static (SubjectType Type, string? Id, string? Route) Target(CreateBlockRequest r) =>
        (r.Subject!.Type!.Value, r.Subject.Type == SubjectType.Everyone ? null : r.Subject.Id, r.Route);
}

public static class Names
{
    public static readonly JsonSerializerOptions Json = Configure(new JsonSerializerOptions(JsonSerializerDefaults.Web));

    /// <summary>Same settings for the HTTP layer and for audit/snapshot serialization.</summary>
    public static JsonSerializerOptions Configure(JsonSerializerOptions o)
    {
        // "user" | "system" | "token" | "everyone"; numbers are rejected
        o.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.SnakeCaseLower, allowIntegerValues: false));
        o.DefaultIgnoreCondition = JsonIgnoreCondition.Never;
        return o;
    }
}

/// <summary>
/// What the gateways consume: the Lua plugin (GET /api/blocklist) and OPA (bundle, data.blocklist).
/// rules: rule key -> block id. An object, so both gateways do a direct key lookup.
/// </summary>
public record Snapshot(
    [property: JsonPropertyName("version")] string Version,
    [property: JsonPropertyName("rules")] IReadOnlyDictionary<string, string> Rules);

public static class SnapshotBuilder
{
    /// <summary>
    /// Deterministic snapshot of the ACTIVE blocks. The version is a hash of the content, so it
    /// changes exactly when the effective list changes (including when a block expires) and is
    /// identical on every replica of this service.
    /// </summary>
    public static Snapshot Build(IEnumerable<Block> blocks, DateTimeOffset now)
    {
        var rules = new SortedDictionary<string, string>(StringComparer.Ordinal);
        foreach (var b in blocks.Where(b => b.IsActive(now)).OrderBy(b => b.CreatedAt).ThenBy(b => b.Id))
            rules.TryAdd(b.RuleKey, b.Id.ToString());   // duplicates are rejected on create; first one wins anyway

        var canonical = JsonSerializer.Serialize(rules);
        var version = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(canonical)))[..16];
        return new Snapshot(version, rules);
    }
}
