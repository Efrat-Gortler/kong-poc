using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using BlockingService.Data;
using BlockingService.Domain;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.AspNetCore.Http.Json;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using Microsoft.Net.Http.Headers;
using Microsoft.OpenApi.Models;

var builder = WebApplication.CreateBuilder(args);
var cfg = builder.Configuration;

// ---------- configuration ----------
var issuer = cfg["Auth:Issuer"] ?? "http://keycloak.idp.svc.cluster.local:8080/realms/corp";
var audience = cfg["Auth:Audience"] ?? "api://blocking-service";
var blockerRole = cfg["Auth:BlockerRole"] ?? "blocker";
var readerKey = cfg["Reader:ApiKey"] ?? throw new InvalidOperationException("Reader:ApiKey (env Reader__ApiKey) is required");
var knownRoutes = (cfg.GetSection("Blocking:KnownRoutes").Get<string[]>() ?? [])
    .ToHashSet(StringComparer.Ordinal);

builder.Services.AddDbContext<BlockingDbContext>(o =>
    o.UseNpgsql(cfg.GetConnectionString("Blocking") ?? throw new InvalidOperationException("ConnectionStrings:Blocking is required")));

// minimal APIs read Http.Json.JsonOptions; Mvc.JsonOptions (also imported) is ambiguous with it
builder.Services.Configure<Microsoft.AspNetCore.Http.Json.JsonOptions>(o =>
{
    foreach (var c in Names.Json.Converters) o.SerializerOptions.Converters.Add(c);
    o.SerializerOptions.DefaultIgnoreCondition = Names.Json.DefaultIgnoreCondition;
});

builder.Services
    .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(o =>
    {
        o.Authority = issuer;
        o.RequireHttpsMetadata = issuer.StartsWith("https://", StringComparison.OrdinalIgnoreCase);
        o.MapInboundClaims = false;           // keep "roles", "caller_id" as they are
        o.TokenValidationParameters.ValidAudience = audience;
        o.TokenValidationParameters.ValidIssuer = issuer;
        o.TokenValidationParameters.RoleClaimType = "roles";
        o.TokenValidationParameters.NameClaimType = "caller_id";
    });
builder.Services.AddAuthorizationBuilder()
    .AddPolicy("blocker", p => p.RequireAuthenticatedUser().RequireRole(blockerRole));

builder.Services.AddHostedService<ExpiryWorker>();
builder.Services.AddHealthChecks();
builder.Services.AddProblemDetails();

builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen(o =>
{
    o.SwaggerDoc("v1", new OpenApiInfo
    {
        Title = "Kong POC - Blocking service",
        Version = "v1",
        Description = "Block users, system tokens and routes on every leg within seconds. " +
                      "Write endpoints need a Keycloak token with role 'blocker' (scripts/get-token.sh opsadmin).",
    });
    var bearer = new OpenApiSecurityScheme
    {
        Type = SecuritySchemeType.Http, Scheme = "bearer", BearerFormat = "JWT",
        Description = "Paste an access token (without the 'Bearer ' prefix).",
        Reference = new OpenApiReference { Type = ReferenceType.SecurityScheme, Id = "bearer" },
    };
    o.AddSecurityDefinition("bearer", bearer);
    o.AddSecurityRequirement(new OpenApiSecurityRequirement { [bearer] = [] });
    var xml = Path.Combine(AppContext.BaseDirectory, "BlockingService.xml");
    if (File.Exists(xml)) o.IncludeXmlComments(xml);
});

var app = builder.Build();

// Schema: EnsureCreated keeps the POC free of migration tooling (see README "Deviations").
using (var scope = app.Services.CreateScope())
{
    var db = scope.ServiceProvider.GetRequiredService<BlockingDbContext>();
    for (var attempt = 1; ; attempt++)
    {
        try { db.Database.EnsureCreated(); break; }
        catch (Exception ex) when (attempt < 30)
        {
            app.Logger.LogWarning("Database not ready ({Attempt}/30): {Message}", attempt, ex.Message);
            await Task.Delay(TimeSpan.FromSeconds(2));
        }
    }
}

app.UseExceptionHandler();
app.UseSwagger();
app.UseSwaggerUI(o => o.SwaggerEndpoint("/swagger/v1/swagger.json", "v1"));
app.UseAuthentication();
app.UseAuthorization();

app.MapGet("/", () => Results.Redirect("/swagger")).ExcludeFromDescription();
app.MapHealthChecks("/healthz");
app.MapGet("/readyz", async (BlockingDbContext db) =>
    await db.Database.CanConnectAsync() ? Results.Ok(new { status = "ready" }) : Results.StatusCode(503))
    .ExcludeFromDescription();

// ---------- operator API (role: blocker) ----------
var api = app.MapGroup("/api/blocks").WithTags("Blocks").RequireAuthorization("blocker");

api.MapGet("/", async (BlockingDbContext db, bool includeInactive = false) =>
{
    var now = DateTimeOffset.UtcNow;
    var q = db.Blocks.AsNoTracking();
    if (!includeInactive) q = q.Where(b => b.RemovedAt == null && (b.ExpiresAt == null || b.ExpiresAt > now));
    return await q.OrderByDescending(b => b.CreatedAt).Select(b => BlockDto.From(b, now)).ToListAsync();
}).WithSummary("List blocks (active only unless includeInactive=true)");

api.MapPost("/", async Task<Results<Created<BlockDto>, ValidationProblem, Conflict<ProblemDetails>>>
    (CreateBlockRequest req, BlockingDbContext db, ClaimsPrincipal user) =>
{
    var now = DateTimeOffset.UtcNow;
    var errors = BlockValidator.Validate(req, knownRoutes, now);
    if (errors.Count > 0) return TypedResults.ValidationProblem(errors);

    var callerId = string.IsNullOrWhiteSpace(req.CallerId) ? null : req.CallerId;
    var route = string.IsNullOrWhiteSpace(req.Route) ? null : req.Route;
    var active = await db.Blocks.Where(b => b.RemovedAt == null && (b.ExpiresAt == null || b.ExpiresAt > now)).ToListAsync();
    var dup = active.FirstOrDefault(b => BlockValidator.SameTarget(b, req.Kind, callerId, route));
    if (dup is not null)
        return TypedResults.Conflict(new ProblemDetails { Title = "Already blocked", Detail = $"Active block {dup.Id} covers this target." });

    var block = new Block
    {
        Kind = req.Kind, CallerId = callerId, Route = route, Reason = req.Reason.Trim(),
        CreatedBy = Actor(user), CreatedAt = now, ExpiresAt = BlockValidator.EffectiveExpiry(req, now),
    };
    db.Blocks.Add(block);
    db.Audit.Add(Audit("created", block, block.CreatedBy, now));
    await db.SaveChangesAsync();
    app.Logger.LogInformation("Block created {Id} kind={Kind} caller={Caller} route={Route} by={By}",
        block.Id, Names.Kind(block.Kind), block.CallerId, block.Route, block.CreatedBy);
    return TypedResults.Created($"/api/blocks/{block.Id}", BlockDto.From(block, now));
}).WithSummary("Create a block (takes effect on every leg within one poll interval)");

api.MapDelete("/{id:guid}", async Task<Results<NoContent, NotFound>> (Guid id, BlockingDbContext db, ClaimsPrincipal user) =>
{
    var now = DateTimeOffset.UtcNow;
    var block = await db.Blocks.FirstOrDefaultAsync(b => b.Id == id && b.RemovedAt == null);
    if (block is null) return TypedResults.NotFound();
    block.RemovedAt = now;
    block.RemovedBy = Actor(user);
    db.Audit.Add(Audit("removed", block, block.RemovedBy, now));
    await db.SaveChangesAsync();
    app.Logger.LogInformation("Block removed {Id} by={By}", block.Id, block.RemovedBy);
    return TypedResults.NoContent();
}).WithSummary("Unblock");

app.MapGet("/api/audit", async (BlockingDbContext db, int take = 100) =>
    await db.Audit.AsNoTracking().OrderByDescending(a => a.Id).Take(Math.Clamp(take, 1, 1000)).ToListAsync())
    .WithTags("Blocks").RequireAuthorization("blocker").WithSummary("Audit log of every change");

app.MapGet("/api/routes", () => knownRoutes.Order(StringComparer.Ordinal))
    .WithTags("Blocks").RequireAuthorization("blocker").WithSummary("Route names that can be blocked");

// ---------- gateway API (service credential) ----------
var gw = app.MapGroup("/api").WithTags("Gateways").AddEndpointFilter(async (ctx, next) =>
    IsReader(ctx.HttpContext.Request, readerKey) ? await next(ctx) : Results.Unauthorized());

gw.MapGet("/blocklist", async (HttpContext http, BlockingDbContext db) =>
{
    var snapshot = await CurrentSnapshot(db);
    var etag = $"\"{snapshot.Version}\"";
    http.Response.Headers.ETag = etag;
    http.Response.Headers.CacheControl = "no-cache";
    if (MatchesEtag(http.Request, etag)) return Results.StatusCode(StatusCodes.Status304NotModified);
    return Results.Json(snapshot, Names.Json);
}).WithSummary("Active block list for the Lua plugin (supports If-None-Match)");

gw.MapGet("/opa/bundle.tar.gz", async (HttpContext http, BlockingDbContext db) =>
{
    var snapshot = await CurrentSnapshot(db);
    var etag = $"\"{snapshot.Version}\"";
    http.Response.Headers.ETag = etag;
    if (MatchesEtag(http.Request, etag)) return Results.StatusCode(StatusCodes.Status304NotModified);
    return Results.File(OpaBundle.Build(snapshot), "application/gzip", "bundle.tar.gz");
}).WithSummary("Same list as an OPA bundle (data.blocklist), polled by each leg's OPA");

app.Run();

// ---------- helpers ----------
static string Actor(ClaimsPrincipal u) =>
    u.FindFirstValue("caller_id") ?? u.FindFirstValue("preferred_username") ?? u.FindFirstValue("sub") ?? "unknown";

static AuditEntry Audit(string action, Block b, string actor, DateTimeOffset at) => new()
{
    At = at, Action = action, BlockId = b.Id, Actor = actor,
    Details = JsonSerializer.Serialize(BlockDto.From(b, at), Names.Json),
};

static async Task<Snapshot> CurrentSnapshot(BlockingDbContext db)
{
    var now = DateTimeOffset.UtcNow;
    var rows = await db.Blocks.AsNoTracking()
        .Where(b => b.RemovedAt == null && (b.ExpiresAt == null || b.ExpiresAt > now)).ToListAsync();
    return SnapshotBuilder.Build(rows, now);
}

static bool MatchesEtag(HttpRequest req, string etag) =>
    req.Headers.IfNoneMatch.Any(v => v is not null && v.Split(',').Any(x => x.Trim() == etag || x.Trim() == "*"));

static bool IsReader(HttpRequest req, string key)
{
    string? presented = req.Headers["X-Api-Key"].FirstOrDefault();
    var auth = req.Headers[HeaderNames.Authorization].FirstOrDefault();
    if (presented is null && auth is not null && auth.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
        presented = auth["Bearer ".Length..].Trim();
    if (presented is null) return false;
    return CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(presented), Encoding.UTF8.GetBytes(key));
}

public record BlockDto(
    Guid Id, BlockKind Kind, string? CallerId, string? Route, string Reason, string CreatedBy,
    DateTimeOffset CreatedAt, DateTimeOffset? ExpiresAt, DateTimeOffset? RemovedAt, string? RemovedBy, bool Active)
{
    public static BlockDto From(Block b, DateTimeOffset now) =>
        new(b.Id, b.Kind, b.CallerId, b.Route, b.Reason, b.CreatedBy, b.CreatedAt, b.ExpiresAt, b.RemovedAt, b.RemovedBy, b.IsActive(now));
}

/// <summary>Marks expired blocks as removed and audits it. The snapshot already
/// ignores expired rows, so expiry takes effect even between two runs.</summary>
public class ExpiryWorker(IServiceScopeFactory scopes, ILogger<ExpiryWorker> log) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stop)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(5));
        while (await timer.WaitForNextTickAsync(stop))
        {
            try
            {
                using var scope = scopes.CreateScope();
                var db = scope.ServiceProvider.GetRequiredService<BlockingDbContext>();
                var now = DateTimeOffset.UtcNow;
                var expired = await db.Blocks.Where(b => b.RemovedAt == null && b.ExpiresAt != null && b.ExpiresAt <= now).ToListAsync(stop);
                foreach (var b in expired)
                {
                    b.RemovedAt = now;
                    b.RemovedBy = "system:expiry";
                    db.Audit.Add(new AuditEntry
                    {
                        At = now, Action = "expired", BlockId = b.Id, Actor = "system:expiry",
                        Details = JsonSerializer.Serialize(BlockDto.From(b, now), Names.Json),
                    });
                    log.LogInformation("Block expired {Id}", b.Id);
                }
                if (expired.Count > 0) await db.SaveChangesAsync(stop);
            }
            catch (Exception ex) when (!stop.IsCancellationRequested)
            {
                log.LogWarning(ex, "Expiry run failed");
            }
        }
    }
}

public partial class Program;
