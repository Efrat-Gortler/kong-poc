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
local credential, route

local function reset_env()
  exited, logged, resp_headers = nil, {}, {}
  credential, route = nil, nil
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
}

local function conf(over)
  local c = {}
  for k, v in pairs(base_conf) do c[k] = v end
  for k, v in pairs(over or {}) do c[k] = v end
  return c
end

local snapshot = {
  version = "v1", users = { "666efratg@corp.local" }, system_tokens = {}, routes = { "orders-export" },
  user_on_route = {},
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
    route = { name = "httproute.leg1.orders.0.0", tags = { "k8s-name:orders" } }
    h:access(conf())
    assert.equal(403, exited.status)
    assert.same({ message = "Forbidden" }, exited.body)
    assert.equal("user", kong.ctx.shared.blocklist_kind)
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
    assert.equal("user", resp_headers["X-Blocklist-Would-Block"])
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
