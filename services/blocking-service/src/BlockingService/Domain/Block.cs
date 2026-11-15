namespace BlockingService.Domain;

/// <summary>WHO a block applies to.</summary>
public enum SubjectType
{
    /// <summary>A user, by caller_id (the upn).</summary>
    User,
    /// <summary>An application, by caller_id (client id of a client-credentials token).</summary>
    System,
    /// <summary>One specific token, by its jti claim (e.g. a leaked token).</summary>
    Token,
    /// <summary>Every caller (no id). Only together with a route.</summary>
    Everyone,
}

/// <summary>A block = WHO (subject type + id) + WHERE (one route, or all routes when Route is null).</summary>
public class Block
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public SubjectType SubjectType { get; set; }
    /// <summary>caller_id for user/system, jti for token, null for everyone.</summary>
    public string? SubjectId { get; set; }
    /// <summary>Logical route name = HTTPRoute name; null = all routes.</summary>
    public string? Route { get; set; }
    public string Reason { get; set; } = "";
    public string CreatedBy { get; set; } = "";
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset? ExpiresAt { get; set; }
    /// <summary>Set when unblocked or expired. Rows are never deleted (audit).</summary>
    public DateTimeOffset? RemovedAt { get; set; }
    public string? RemovedBy { get; set; }

    public bool IsActive(DateTimeOffset now) =>
        RemovedAt is null && (ExpiresAt is null || ExpiresAt > now);

    /// <summary>The gateway lookup key, e.g. "user:a@corp.local@orders" or "token:abc@*".</summary>
    public string RuleKey => RuleKeys.Key(SubjectType, SubjectId, Route);
}

public class AuditEntry
{
    public long Id { get; set; }
    public DateTimeOffset At { get; set; }
    /// <summary>created | removed | expired</summary>
    public string Action { get; set; } = "";
    public Guid BlockId { get; set; }
    public string Actor { get; set; } = "";
    /// <summary>JSON snapshot of the block at the time of the change.</summary>
    public string Details { get; set; } = "";
}

/// <summary>
/// Rule keys shared by the snapshot (/api/blocklist), the OPA bundle, the Lua plugin and the Rego policy:
///   &lt;type&gt;:&lt;id&gt;@&lt;route&gt;    type = user | system | token | everyone, id = "*" for everyone,
///                         route = "*" for all routes.
/// Route names never contain "@", so the key is unambiguous even though upns do.
/// A gateway checks at most 5 keys per request: subject@route, subject@*, token@route, token@*, everyone@route.
/// </summary>
public static class RuleKeys
{
    public const string All = "*";

    public static string TypeName(SubjectType t) => t switch
    {
        SubjectType.User => "user",
        SubjectType.System => "system",
        SubjectType.Token => "token",
        SubjectType.Everyone => "everyone",
        _ => throw new ArgumentOutOfRangeException(nameof(t), t, null),
    };

    public static string Key(SubjectType t, string? id, string? route) =>
        $"{TypeName(t)}:{(t == SubjectType.Everyone ? All : id)}@{route ?? All}";
}
