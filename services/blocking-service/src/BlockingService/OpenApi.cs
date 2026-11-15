using System.Text.Json;
using BlockingService.Domain;
using Microsoft.OpenApi.Any;
using Microsoft.OpenApi.Models;
using Swashbuckle.AspNetCore.SwaggerGen;

namespace BlockingService;

/// <summary>SubjectType as a string enum with the wire names and what each one means.</summary>
public class SubjectTypeSchemaFilter : ISchemaFilter
{
    public void Apply(OpenApiSchema schema, SchemaFilterContext context)
    {
        if ((Nullable.GetUnderlyingType(context.Type) ?? context.Type) != typeof(SubjectType)) return;
        schema.Type = "string";
        schema.Format = null;
        schema.Enum = Enum.GetValues<SubjectType>().Select(t => (IOpenApiAny)new OpenApiString(RuleKeys.TypeName(t))).ToList();
        schema.Description =
            "user: a person, id = caller_id (upn) · system: an application, id = caller_id (client id) · " +
            "token: one token, id = its jti · everyone: every caller, no id, needs a route";
        schema.Example = new OpenApiString("user");
    }
}

/// <summary>Request examples for POST /api/blocks: every valid combination, plus the one that is rejected.</summary>
public class BlockExamplesOperationFilter : IOperationFilter
{
    private static OpenApiObject Body(string type, string? id, string? route, string reason, int? ttl = null)
    {
        var subject = new OpenApiObject { ["type"] = new OpenApiString(type) };
        if (id is not null) subject["id"] = new OpenApiString(id);
        var body = new OpenApiObject { ["subject"] = subject };
        if (route is not null) body["route"] = new OpenApiString(route);
        body["reason"] = new OpenApiString(reason);
        if (ttl is not null) body["ttlSeconds"] = new OpenApiInteger(ttl.Value);
        return body;
    }

    private static readonly (string Key, string Summary, OpenApiObject Value)[] Examples =
    [
        ("user-all-routes", "User on all routes", Body("user", "666efratg@corp.local", null, "abnormal request volume")),
        ("user-one-route", "User on one route", Body("user", "777danag@corp.local", "orders-create", "duplicate orders", 3600)),
        ("system-all-routes", "System (application) on all routes", Body("system", "reports-service", null, "runaway batch job")),
        ("system-one-route", "System on one route", Body("system", "billing-service", "reports", "report export misuse")),
        ("token-all-routes", "One leaked token on all routes", Body("token", "8f0c6f3e-2f4b-4c51-9a7e-3d6d1c2b9e10", null, "token leaked", 300)),
        ("token-one-route", "One token on one route", Body("token", "8f0c6f3e-2f4b-4c51-9a7e-3d6d1c2b9e10", "orders-create", "replayed token")),
        ("everyone-one-route", "Everyone on one route (route closed)", Body("everyone", null, "orders-create", "backend failure")),
        ("rejected-everyone-all-routes", "REJECTED (400): everyone on all routes", Body("everyone", null, null, "this would stop all traffic")),
    ];

    public void Apply(OpenApiOperation operation, OperationFilterContext context)
    {
        if (context.ApiDescription.HttpMethod != "POST" || context.ApiDescription.RelativePath?.TrimEnd('/') != "api/blocks") return;
        if (operation.RequestBody?.Content is not { } content) return;
        foreach (var media in content.Values)
        {
            media.Examples = Examples.ToDictionary(e => e.Key, e => new OpenApiExample { Summary = e.Summary, Value = e.Value });
        }
        if (operation.Responses.TryGetValue("400", out var bad) && bad.Content is not null)
        {
            foreach (var media in bad.Content.Values)
            {
                media.Example = new OpenApiObject
                {
                    ["type"] = new OpenApiString("https://tools.ietf.org/html/rfc9110#section-15.5.1"),
                    ["title"] = new OpenApiString("The block is not valid"),
                    ["status"] = new OpenApiInteger(400),
                    ["errors"] = new OpenApiObject
                    {
                        ["route"] = new OpenApiArray { new OpenApiString("required for subject.type everyone: blocking everyone on all routes would stop all traffic") },
                    },
                };
            }
        }
    }
}

/// <summary>Turns request-binding failures (malformed JSON, unknown enum value, ...) into a field + message.</summary>
public static class RequestErrors
{
    public static (string Field, string Message) Describe(BadHttpRequestException ex)
    {
        if (ex.InnerException is JsonException je)
        {
            var field = je.Path is { Length: > 2 } p ? p.TrimStart('$', '.') : "body";
            var message = field switch
            {
                "subject.type" => "must be one of: user, system, token, everyone",
                "ttlSeconds" => "must be a whole number of seconds",
                "expiresAt" => "must be an ISO 8601 date-time, e.g. 2026-12-31T23:59:59Z",
                "body" => "is not valid JSON",
                _ => "has an invalid value",
            };
            return (field, message);
        }
        return ("body", ex.Message.Contains("body", StringComparison.OrdinalIgnoreCase) || ex.Message.Contains("JSON", StringComparison.OrdinalIgnoreCase)
            ? "a JSON body (Content-Type: application/json) is required"
            : ex.Message);
    }
}
