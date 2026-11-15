using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using BlockingService;
using BlockingService.Data;
using BlockingService.Domain;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Diagnostics;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.EntityFrameworkCore;
using Microsoft.Net.Http.Headers;
using Microsoft.OpenApi.Models;
using ProblemDetails = Microsoft.AspNetCore.Mvc.ProblemDetails;

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

// Minimal APIs read Http.Json.JsonOptions; Swashbuckle reads Mvc.JsonOptions - same settings for both
// (enums as "user" | "system" | "token" | "everyone").
builder.Services.Configure<Microsoft.AspNetCore.Http.Json.JsonOptions>(o => Names.Configure(o.SerializerOptions));
builder.Services.Configure<Microsoft.AspNetCore.Mvc.JsonOptions>(o => Names.Configure(o.JsonSerializerOptions));
// Malformed JSON / unknown enum values: throw, so the exception handler can answer with a clear 400.
builder.Services.Configure<RouteHandlerOptions>(o => o.ThrowOnBadRequest = true);

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
        Version = "v2",
        Description = """
            A block = WHO (`subject`) + WHERE (`route`).

            | subject.type | subject.id | route: a name | route: omitted (all routes) |
            |---|---|---|---|
            | `user` | caller_id (upn) | ✔ | ✔ |
            | `system` | caller_id (client id) | ✔ | ✔ |
            | `token` | the token's `jti` | ✔ | ✔ |
            | `everyone` | — | ✔ | ✘ (400: would stop all traffic) |

            Every gateway leg enforces a new block within one poll interval. Write endpoints need a
            Keycloak token with role `blocker` (`scripts/get-token.sh opsadmin`).
            """,
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
    // properties that reference a schema (subject, subject.type) keep their own description/example
    o.UseAllOfToExtendReferenceSchemas();
    o.SchemaFilter<SubjectTypeSchemaFilter>();
    o.OperationFilter<BlockExamplesOperationFilter>();
});

var app = builder.Build();

using (var scope = app.Services.CreateScope())
{
    var db = scope.ServiceProvider.GetRequiredService<BlockingDbContext>();
    for (var attempt = 1; ; attempt++)
    {
        try { await Schema.EnsureCurrentAsync(db, app.Logger); break; }
        catch (Exception ex) when (attempt < 30)
        {
            app.Logger.LogWarning("Database not ready ({Attempt}/30): {Message}", attempt, ex.Message);
            await Task.Delay(TimeSpan.FromSeconds(2));
        }
    }
}

app.UseExceptionHandler(e => e.Run(async http =>
{
    var ex = http.Features.Get<IExceptionHandlerFeature>()?.Error;
    if (ex is BadHttpRequestException bad)
    {
        var (field, message) = RequestErrors.Describe(bad);
        await TypedResults.ValidationProblem(new Dictionary<string, string[]> { [field] = [message] },
            title: "The request body is not valid").ExecuteAsync(http);
        return;
    }
    await TypedResults.Problem(title: "Unexpected error", statusCode: StatusCodes.Status500InternalServerError).ExecuteAsync(http);
}));
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
    var rows = await q.OrderByDescending(b => b.CreatedAt).ToListAsync();
    return TypedResults.Ok(rows.Select(b => BlockDto.From(b, now)).ToList());
}).WithSummary("List blocks (active only unless includeInactive=true); same shape as the POST body plus id, rule and lifecycle");

api.MapPost("/", async Task<Results<Created<BlockDto>, ValidationProblem, Conflict<ProblemDetails>>>
    (CreateBlockRequest req, BlockingDbContext db, ClaimsPrincipal user) =>
{
    var now = DateTimeOffset.UtcNow;
    var errors = BlockValidator.Validate(req, knownRoutes, now);
    if (errors.Count > 0) return TypedResults.ValidationProblem(errors, title: "The block is not valid");

    var (type, id, route) = BlockValidator.Target(req);
    var key = RuleKeys.Key(type, id, route);
    var active = await db.Blocks.Where(b => b.RemovedAt == null && (b.ExpiresAt == null || b.ExpiresAt > now)).ToListAsync();
    var dup = active.FirstOrDefault(b => b.RuleKey == key);
    if (dup is not null)
        return TypedResults.Conflict(new ProblemDetails
        {
            Title = "Already blocked", Status = StatusCodes.Status409Conflict,
            Detail = $"Active block {dup.Id} has the same rule {key}.",
        });

    var block = new Block
    {
        SubjectType = type, SubjectId = id, Route = route, Reason = req.Reason!.Trim(),
        CreatedBy = Actor(user), CreatedAt = now, ExpiresAt = BlockValidator.EffectiveExpiry(req, now),
    };
    db.Blocks.Add(block);
    db.Audit.Add(Audit("created", block, block.CreatedBy, now));
    await db.SaveChangesAsync();
    app.Logger.LogInformation("Block created {Id} rule={Rule} by={By}", block.Id, block.RuleKey, block.CreatedBy);
    return TypedResults.Created($"/api/blocks/{block.Id}", BlockDto.From(block, now));
}).WithSummary("Create a block: WHO (subject) + WHERE (route). Takes effect on every leg within one poll interval")
  .WithDescription("Every combination of subject.type and route is valid except everyone on all routes (400). " +
                   "An active block with the same rule gives 409.");

api.MapDelete("/{id:guid}", async Task<Results<NoContent, NotFound>> (Guid id, BlockingDbContext db, ClaimsPrincipal user) =>
{
    var now = DateTimeOffset.UtcNow;
    var block = await db.Blocks.FirstOrDefaultAsync(b => b.Id == id && b.RemovedAt == null);
    if (block is null) return TypedResults.NotFound();
    block.RemovedAt = now;
    block.RemovedBy = Actor(user);
    db.Audit.Add(Audit("removed", block, block.RemovedBy, now));
    await db.SaveChangesAsync();
    app.Logger.LogInformation("Block removed {Id} rule={Rule} by={By}", block.Id, block.RuleKey, block.RemovedBy);
    return TypedResults.NoContent();
}).WithSummary("Unblock");

app.MapGet("/api/audit", async (BlockingDbContext db, int take = 100) =>
    await db.Audit.AsNoTracking().OrderByDescending(a => a.Id).Take(Math.Clamp(take, 1, 1000)).ToListAsync())
    .WithTags("Blocks").RequireAuthorization("blocker").WithSummary("Audit log of every change (v2 schema; v1 history is in table audit_v1)");

app.MapGet("/api/routes", () => knownRoutes.Order(StringComparer.Ordinal))
    .WithTags("Blocks").RequireAuthorization("blocker").WithSummary("Route names a block can name in 'route'");

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
}).WithSummary("Active rules for the Lua plugin: { version, rules: { \"type:id@route\": blockId } } (supports If-None-Match)");

gw.MapGet("/opa/bundle.tar.gz", async (HttpContext http, BlockingDbContext db) =>
{
    var snapshot = await CurrentSnapshot(db);
    var etag = $"\"{snapshot.Version}\"";
    http.Response.Headers.ETag = etag;
    if (MatchesEtag(http.Request, etag)) return Results.StatusCode(StatusCodes.Status304NotModified);
    return Results.File(OpaBundle.Build(snapshot), "application/gzip", "bundle.tar.gz");
}).WithSummary("Same rules as an OPA bundle (data.blocklist.rules), polled by each leg's OPA");

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
                    log.LogInformation("Block expired {Id} rule={Rule}", b.Id, b.RuleKey);
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
