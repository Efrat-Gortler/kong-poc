namespace BlockingService.Domain;

/// <summary>The four block kinds from the design.</summary>
public enum BlockKind
{
    /// <summary>A user (caller_id = upn) is blocked on every route.</summary>
    User,
    /// <summary>A system (client-credentials) token is blocked on every route.</summary>
    SystemToken,
    /// <summary>A route is blocked for everybody.</summary>
    Route,
    /// <summary>A user or system token is blocked on one route only.</summary>
    UserOnRoute,
}

public class Block
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public BlockKind Kind { get; set; }
    /// <summary>Value of the caller_id claim (upn for users, client id for system tokens).</summary>
    public string? CallerId { get; set; }
    /// <summary>Logical route name = HTTPRoute name.</summary>
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
