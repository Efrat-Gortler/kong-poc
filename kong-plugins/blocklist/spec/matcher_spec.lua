package.path = "./?.lua;" .. package.path
local matcher = require "kong.plugins.blocklist.matcher"

local snapshot = {
  version       = "v1",
  users         = { "666efratg@corp.local" },
  system_tokens = { "reports-service" },
  routes        = { "orders-export" },
  user_on_route = { { caller_id = "777danag@corp.local", route = "orders-create" } },
}

describe("matcher.index", function()
  it("rejects snapshots without a version", function()
    local idx, err = matcher.index({ users = {} })
    assert.is_nil(idx)
    assert.matches("version", err)
  end)

  it("rejects non-objects", function()
    assert.is_nil(matcher.index(nil))
    assert.is_nil(matcher.index("x"))
  end)

  it("tolerates missing lists and junk entries", function()
    local idx = matcher.index({ version = "v", users = { 1, "", "a" }, user_on_route = { "junk", { caller_id = "a" } } })
    assert.is_truthy(idx.users["a"])
    assert.is_nil(idx.users[""])
    assert.same({}, idx.user_on_route)
    assert.same({}, idx.routes)
  end)
end)

describe("matcher.check", function()
  local idx = assert(matcher.index(snapshot))

  it("allows unknown callers on unblocked routes", function()
    assert.is_nil(matcher.check(idx, "normaluser@corp.local", "orders"))
  end)

  it("blocks a user everywhere", function()
    assert.equal("user", matcher.check(idx, "666efratg@corp.local", "orders"))
    assert.equal("user", matcher.check(idx, "666efratg@corp.local", nil))
  end)

  it("blocks a system token", function()
    assert.equal("system_token", matcher.check(idx, "reports-service", "users"))
  end)

  it("blocks a route for everybody, including anonymous callers", function()
    assert.equal("route", matcher.check(idx, "normaluser@corp.local", "orders-export"))
    assert.equal("route", matcher.check(idx, nil, "orders-export"))
  end)

  it("blocks a user only on the given route", function()
    assert.equal("user_on_route", matcher.check(idx, "777danag@corp.local", "orders-create"))
    assert.is_nil(matcher.check(idx, "777danag@corp.local", "orders"))
    assert.is_nil(matcher.check(idx, "normaluser@corp.local", "orders-create"))
  end)

  it("is exact-match (no prefix / case folding)", function()
    assert.is_nil(matcher.check(idx, "666EFRATG@corp.local", "orders"))
    assert.is_nil(matcher.check(idx, "666efratg", "orders"))
  end)

  it("allows everything when no list is loaded", function()
    assert.is_nil(matcher.check(nil, "666efratg@corp.local", "orders-export"))
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
