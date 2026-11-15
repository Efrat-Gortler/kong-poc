package.path = "./?.lua;" .. package.path
local cjson   = require "cjson.safe"
local matcher = require "kong.plugins.blocklist.matcher"

-- unsigned test JWT: the plugin only decodes (openid-connect verified the real one)
local function b64url(s)
  local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local q = { math.floor(n / 262144) % 64, math.floor(n / 4096) % 64, math.floor(n / 64) % 64, n % 64 }
    local count = c and 4 or b and 3 or 2
    for j = 1, count do out[#out + 1] = chars:sub(q[j] + 1, q[j] + 1) end
  end
  return table.concat(out)
end
local function jwt(claims)
  return b64url('{"alg":"RS256","typ":"JWT"}') .. "." .. b64url(cjson.encode(claims)) .. ".c2ln"
end

local idx = assert(matcher.index({
  version = "v1",
  rules = {
    ["user:666efratg@corp.local@*"]             = "b-user-all",
    ["user:777danag@corp.local@orders-create"]  = "b-user-route",
    ["system:reports-service@*"]                = "b-system-all",
    ["system:billing-service@reports"]          = "b-system-route",
    ["token:jti-leaked@*"]                      = "b-token-all",
    ["token:jti-replayed@orders-create"]        = "b-token-route",
    ["everyone:*@orders-export"]                = "b-everyone-route",
  },
}))

describe("matcher.index", function()
  it("rejects snapshots without a version or without rules", function()
    local i, err = matcher.index({ rules = {} })
    assert.is_nil(i)
    assert.matches("version", err)
    i, err = matcher.index({ version = "v", users = {} })   -- old (v1) format
    assert.is_nil(i)
    assert.matches("rules", err)
  end)

  it("rejects non-objects", function()
    assert.is_nil(matcher.index(nil))
    assert.is_nil(matcher.index("x"))
  end)

  it("accepts an empty rule set (JSON {} or [])", function()
    assert.equal(0, matcher.index(cjson.decode('{"version":"v","rules":{}}')).size)
    assert.equal(0, matcher.index(cjson.decode('{"version":"v","rules":[]}')).size)
  end)

  it("builds keys as type:id@route", function()
    assert.equal("user:a@corp.local@*", matcher.key("user", "a@corp.local"))
    assert.equal("everyone:*@orders", matcher.key("everyone", "*", "orders"))
  end)
end)

describe("matcher.check - the 7 combinations", function()
  it("user on all routes", function()
    local h = matcher.check(idx, "user", "666efratg@corp.local", "j", "orders")
    assert.same({ key = "user:666efratg@corp.local@*", block_id = "b-user-all", kind = "user@*" }, h)
    assert.equal("user@*", matcher.check(idx, "user", "666efratg@corp.local", nil, nil).kind)
  end)

  it("user on one route only", function()
    assert.equal("user@route", matcher.check(idx, "user", "777danag@corp.local", "j", "orders-create").kind)
    assert.is_nil(matcher.check(idx, "user", "777danag@corp.local", "j", "orders"))
  end)

  it("system on all routes", function()
    assert.equal("system@*", matcher.check(idx, "system", "reports-service", "j", "users").kind)
  end)

  it("system on one route only", function()
    assert.equal("system@route", matcher.check(idx, "system", "billing-service", "j", "reports").kind)
    assert.is_nil(matcher.check(idx, "system", "billing-service", "j", "orders"))
  end)

  it("token on all routes, whoever holds it", function()
    assert.equal("token@*", matcher.check(idx, "user", "normaluser@corp.local", "jti-leaked", "orders").kind)
    assert.equal("token@*", matcher.check(idx, "system", "reports-x", "jti-leaked", nil).kind)
    -- a token block needs no caller_id (e.g. tokens without the claim)
    assert.equal("token@*", matcher.check(idx, "user", nil, "jti-leaked", "orders").kind)
  end)

  it("token on one route only", function()
    assert.equal("token@route", matcher.check(idx, "user", "normaluser@corp.local", "jti-replayed", "orders-create").kind)
    assert.is_nil(matcher.check(idx, "user", "normaluser@corp.local", "jti-replayed", "orders"))
  end)

  it("everyone on one route", function()
    assert.equal("everyone@route", matcher.check(idx, "user", "normaluser@corp.local", "j", "orders-export").kind)
    assert.equal("everyone@route", matcher.check(idx, "user", nil, nil, "orders-export").kind)
    assert.is_nil(matcher.check(idx, "user", "normaluser@corp.local", "j", "orders"))
  end)
end)

describe("matcher.check - separation and exactness", function()
  it("a user rule does not hit a system token with the same id (and vice versa)", function()
    assert.is_nil(matcher.check(idx, "system", "666efratg@corp.local", "j", "orders"))
    assert.is_nil(matcher.check(idx, "user", "reports-service", "j", "orders"))
  end)

  it("is exact-match (no prefix / case folding)", function()
    assert.is_nil(matcher.check(idx, "user", "666EFRATG@corp.local", "j", "orders"))
    assert.is_nil(matcher.check(idx, "user", "666efratg", "j", "orders"))
    assert.is_nil(matcher.check(idx, "user", "x", "JTI-LEAKED", "orders"))
  end)

  it("allows everything when no list is loaded", function()
    assert.is_nil(matcher.check(nil, "user", "666efratg@corp.local", "jti-leaked", "orders-export"))
  end)

  it("does at most 5 lookups", function()
    local lookups = 0
    local counting = { version = "v", rules = setmetatable({}, { __index = function() lookups = lookups + 1 end }) }
    assert.is_nil(matcher.check(counting, "user", "a", "j", "r"))
    assert.equal(5, lookups)
  end)
end)

describe("matcher.caller_type", function()
  it("system when the claim is present (POC: Keycloak client_id)", function()
    assert.equal("system", matcher.caller_type({ client_id = "reports-service" }, "client_id", {}))
    assert.equal("user", matcher.caller_type({ upn = "a@corp.local" }, "client_id", {}))
  end)

  it("ignores empty, false and JSON null claim values", function()
    assert.equal("user", matcher.caller_type({ client_id = "" }, "client_id"))
    assert.equal("user", matcher.caller_type({ client_id = false }, "client_id"))
    assert.equal("user", matcher.caller_type({ client_id = cjson.null }, "client_id"))
  end)

  it("with values: the claim must have one of them (string or list claim)", function()
    assert.equal("system", matcher.caller_type({ grant = "client_credentials" }, "grant", { "client_credentials" }))
    assert.equal("user", matcher.caller_type({ grant = "password" }, "grant", { "client_credentials" }))
    assert.equal("system", matcher.caller_type({ amr = { "x", "app" } }, "amr", { "app" }))
  end)

  it("user without claims", function()
    assert.equal("user", matcher.caller_type(nil, "client_id"))
  end)
end)

describe("matcher.jwt_claims", function()
  it("decodes the payload of a bearer token", function()
    local c = matcher.jwt_claims("Bearer " .. jwt({ caller_id = "a@corp.local", jti = "j-1", n = "äö" }))
    assert.equal("a@corp.local", c.caller_id)
    assert.equal("j-1", c.jti)
    assert.equal("äö", c.n)
  end)

  it("accepts any case of 'bearer'", function()
    assert.equal("j", matcher.jwt_claims("bearer " .. jwt({ jti = "j" })).jti)
  end)

  it("returns nil for missing, non-bearer or malformed values", function()
    assert.is_nil(matcher.jwt_claims(nil))
    assert.is_nil(matcher.jwt_claims("Basic YTpi"))
    assert.is_nil(matcher.jwt_claims("Bearer not-a-jwt"))
    assert.is_nil(matcher.jwt_claims("Bearer a.%%%.c"))
    assert.is_nil(matcher.jwt_claims("Bearer " .. b64url("{}") .. "." .. b64url("[1,") .. ".x"))
  end)
end)

describe("matcher.route_name", function()
  it("prefers the KIC k8s-name tag", function()
    assert.equal("orders-create", matcher.route_name({
      name = "httproute.leg1.orders-create.0.0",
      tags = { "k8s-namespace:leg1", "k8s-name:orders-create", "k8s-kind:HTTPRoute" },
    }))
  end)

  it("falls back to parsing the generated name", function()
    assert.equal("orders-create", matcher.route_name({ name = "httproute.leg1.orders-create.0.0" }))
  end)

  it("uses a plain name as is", function()
    assert.equal("legacy", matcher.route_name({ name = "legacy" }))
  end)

  it("handles a missing route", function()
    assert.is_nil(matcher.route_name(nil))
  end)
end)
