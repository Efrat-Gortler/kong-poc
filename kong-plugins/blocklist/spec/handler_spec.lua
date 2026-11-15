-- Handler tests with stubbed Kong PDK / nginx APIs (runs with plain busted, no Kong needed).
package.path = "./?.lua;" .. package.path
local cjson = require "cjson.safe"

-- ---------- minimal stubs ----------
local function new_dict()
  local store = {}
  return {
    get = function(_, k) return store[k] end,
    set = function(_, k, v) store[k] = v; return true end,
    add = function(_, k, v) if store[k] ~= nil then return false, "exists" end store[k] = v; return true end,
    incr = function(_, k, n, init) store[k] = (store[k] or init or 0) + n; return store[k] end,
    delete = function(_, k) store[k] = nil end,
    _store = store,
  }
end

local http_response    -- what the stubbed resty.http returns
local last_request
package.loaded["resty.http"] = {
  new = function()
    return {
      set_timeout = function() end,
      request_uri = function(_, url, opts)
        last_request = { url = url, opts = opts }
        if type(http_response) == "function" then return http_response() end
        return http_response
      end,
    }
  end,
}

local exited, logged, resp_headers
local credential, route, authorization

-- unsigned test JWT (the plugin only decodes; openid-connect verified the real token)
local function b64url(str)
  local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
  local out = {}
  for i = 1, #str, 3 do
    local a, b, c = str:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local q = { math.floor(n / 262144) % 64, math.floor(n / 4096) % 64, math.floor(n / 64) % 64, n % 64 }
    for j = 1, (c and 4 or b and 3 or 2) do out[#out + 1] = chars:sub(q[j] + 1, q[j] + 1) end
  end
  return table.concat(out)
end
local function bearer(claims)
  return "Bearer " .. b64url('{"alg":"RS256"}') .. "." .. b64url(cjson.encode(claims)) .. ".sig"
end

local function reset_env()
  exited, logged, resp_headers = nil, {}, {}
  credential, route, authorization = nil, nil, nil
  _G.ngx = {
    shared = { blocklist = new_dict() },
    worker = { pid = function() return 1 end },
    now = function() return 1000 end,
    timer = { at = function() return true end },   -- loop started manually in tests
  }
  _G.kong = {
    log = setmetatable({}, { __index = function(_, lvl)
      return function(...) table.insert(logged, { lvl = lvl, msg = table.concat({ ... }) }) end
    end }),
    client = { get_credential = function() return credential end },
    request = { get_header = function(name) if name:lower() == "authorization" then return authorization end end },
    router = { get_route = function() return route end },
    response = {
      exit = function(status, body) exited = { status = status, body = body }; return exited end,
      set_header = function(k, v) resp_headers[k] = v end,
    },
    ctx = { shared = {}, plugin = {} },
  }
  package.loaded["kong.plugins.blocklist.handler"] = nil
  return require("kong.plugins.blocklist.handler")
end

local base_conf = {
  service_url = "http://blocking/api/blocklist", api_key = "k", poll_interval = 5,
  timeout_ms = 1000, fail_open = false, observe_only = false, status_code = 403, leg = "leg1",
  system_claim = "client_id", system_claim_values = {},
}

local function conf(over)
  local c = {}
  for k, v in pairs(base_conf) do c[k] = v end
  for k, v in pairs(over or {}) do c[k] = v end
  return c
end

local snapshot = {
  version = "v1",
  rules = {
    ["user:666efratg@corp.local@*"] = "b1",
    ["system:reports-service@*"]    = "b2",
    ["token:leaked-jti@*"]          = "b3",
    ["everyone:*@orders-export"]    = "b4",
  },
}

-- Run one poll through the real code path (configure -> timer loop -> poll_once).
-- The stubbed ngx.timer.at captures the loop callback instead of scheduling it.
local pending
local function install_timer_stub()
  ngx.timer.at = function(_, fn) pending = fn; return true end
end

local function poll(handler, c)
  install_timer_stub()
  handler:configure({ c })
  assert.is_function(pending, "poll loop was not scheduled")
  local fn = pending
  pending = nil
  ngx.shared.blocklist:delete("poll_lock")
  fn(false)          -- runs poll_once and reschedules itself into `pending`
  -- keep the loop alive for the next poll() call of this test
  handler:configure({ c })
  if not pending then pending = fn end
end

describe("blocklist handler", function()
  it("before the first fetch: 503 when fail_open=false", function()
    local h = reset_env()
    h:access(conf())
    assert.equal(503, exited.status)
  end)

  it("before the first fetch: allow when fail_open=true", function()
    local h = reset_env()
    h:access(conf({ fail_open = true }))
    assert.is_nil(exited)
  end)

  it("loads a snapshot and blocks a listed user with a generic body", function()
    local h = reset_env()
    http_response = { status = 200, body = cjson.encode(snapshot), headers = {} }
    poll(h, conf())
    assert.equal("k", last_request.opts.headers["X-Api-Key"])

    credential = { id = "666efratg@corp.local" }
    authorization = bearer({ caller_id = "666efratg@corp.local", jti = "j1" })
    route = { name = "httproute.leg1.orders.0.0", tags = { "k8s-name:orders" } }
    h:access(conf())
    assert.equal(403, exited.status)
    assert.same({ message = "Forbidden" }, exited.body)
    assert.equal("user@*", kong.ctx.shared.blocklist_kind)
    assert.matches("rule=user:666efratg@corp.local@* block=b1", logged[#logged].msg, 1, true)
  end)

  it("blocks a system token, recognised by the configured claim", function()
    local h = reset_env()
    http_response = { status = 200, body = cjson.encode(snapshot), headers = {} }
    poll(h, conf())
    credential = { id = "reports-service" }
    route = { tags = { "k8s-name:users" } }
    authorization = bearer({ caller_id = "reports-service", client_id = "reports-service", jti = "j2" })
    h:access(conf())
    assert.equal(403, exited.status)
    assert.equal("system@*", kong.ctx.shared.blocklist_kind)

    -- same caller_id without the system claim = a user: the system rule does not apply
    exited = nil
    authorization = bearer({ caller_id = "reports-service", jti = "j3" })
    h:access(conf())
    assert.is_nil(exited)

    -- another claim configured: client_id alone no longer makes it a system token
    exited = nil
    authorization = bearer({ caller_id = "reports-service", client_id = "reports-service", jti = "j4" })
    h:access(conf({ system_claim = "appid" }))
    assert.is_nil(exited)
  end)

  it("blocks one token by its jti, even without a caller_id", function()
    local h = reset_env()
    http_response = { status = 200, body = cjson.encode(snapshot), headers = {} }
    poll(h, conf())
    route = { tags = { "k8s-name:orders" } }
    authorization = bearer({ jti = "leaked-jti" })
    h:access(conf())
    assert.equal(403, exited.status)
    assert.equal("token@*", kong.ctx.shared.blocklist_kind)
  end)

  it("blocks everyone on a route", function()
    local h = reset_env()
    http_response = { status = 200, body = cjson.encode(snapshot), headers = {} }
    poll(h, conf())
    credential = { id = "normaluser@corp.local" }
    authorization = bearer({ caller_id = "normaluser@corp.local", jti = "j5" })
    route = { tags = { "k8s-name:orders-export" } }
    h:access(conf())
    assert.equal(403, exited.status)
    assert.equal("everyone@route", kong.ctx.shared.blocklist_kind)
  end)

  it("lets other callers through", function()
    local h = reset_env()
    http_response = { status = 200, body = cjson.encode(snapshot), headers = {} }
    poll(h, conf())
    credential = { id = "normaluser@corp.local" }
    route = { tags = { "k8s-name:orders" } }
    h:access(conf())
    assert.is_nil(exited)
  end)

  it("sends If-None-Match and keeps the list on 304", function()
    local h = reset_env()
    http_response = { status = 200, body = cjson.encode(snapshot), headers = {} }
    poll(h, conf())
    http_response = { status = 304, body = "", headers = {} }
    poll(h, conf())
    assert.equal('"v1"', last_request.opts.headers["If-None-Match"])
    credential = { id = "666efratg@corp.local" }
    h:access(conf())
    assert.equal(403, exited.status)
  end)

  it("keeps the last good list when the service is down or returns garbage", function()
    local h = reset_env()
    http_response = { status = 200, body = cjson.encode(snapshot), headers = {} }
    poll(h, conf())
    http_response = function() return nil, "connection refused" end
    poll(h, conf())
    http_response = { status = 200, body = "{not json", headers = {} }
    poll(h, conf())
    http_response = { status = 500, body = "", headers = {} }
    poll(h, conf())
    assert.equal(3, ngx.shared.blocklist:get("poll_failures"))
    route = { tags = { "k8s-name:orders-export" } }
    h:access(conf())
    assert.equal(403, exited.status)
  end)

  it("observe_only marks instead of blocking", function()
    local h = reset_env()
    http_response = { status = 200, body = cjson.encode(snapshot), headers = {} }
    poll(h, conf())
    credential = { id = "666efratg@corp.local" }
    local c = conf({ observe_only = true })
    h:access(c)
    assert.is_nil(exited)
    h:header_filter(c)
    assert.equal("user@*", resp_headers["X-Blocklist-Would-Block"])
  end)

  it("only one worker polls per interval (shared lock)", function()
    local h = reset_env()
    http_response = { status = 200, body = cjson.encode(snapshot), headers = {} }
    poll(h, conf())
    last_request = nil
    -- lock still held by the first poll: a second worker's timer must not fetch
    -- a second worker (fresh module state) shares the same shared dict
    install_timer_stub()
    pending = nil
    package.loaded["kong.plugins.blocklist.handler"] = nil
    local h2 = require("kong.plugins.blocklist.handler")
    h2:configure({ conf() })
    assert.is_function(pending)
    pending(false)
    assert.is_nil(last_request)
  end)

  it("stops polling when the plugin is removed", function()
    local h = reset_env()
    install_timer_stub()
    pending = nil
    h:configure({ conf() })
    local fn = pending
    h:configure(nil)
    last_request = nil
    fn(false)
    assert.is_nil(last_request)
  end)
end)
