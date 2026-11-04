-- Pure matching logic for the blocklist plugin (no Kong / nginx dependencies,
-- so it is unit-tested directly with busted).
--
-- Snapshot format (GET /api/blocklist on the blocking service):
-- {
--   "version": "sha256...",
--   "users":         ["666efratg@corp.local"],
--   "system_tokens": ["reports-service"],
--   "routes":        ["orders-create"],
--   "user_on_route": [{"caller_id": "777danag@corp.local", "route": "orders-create"}]
-- }
local M = {}

local function set_of(list)
  local s = {}
  if type(list) == "table" then
    for _, v in ipairs(list) do
      if type(v) == "string" and v ~= "" then
        s[v] = true
      end
    end
  end
  return s
end

local function pair_key(caller_id, route)
  return caller_id .. "\0" .. route
end

-- Build O(1) lookup tables. Returns nil, err for a structurally invalid snapshot.
function M.index(snapshot)
  if type(snapshot) ~= "table" then
    return nil, "snapshot is not an object"
  end
  if type(snapshot.version) ~= "string" or snapshot.version == "" then
    return nil, "snapshot has no version"
  end
  local pairs_set = {}
  if type(snapshot.user_on_route) == "table" then
    for _, e in ipairs(snapshot.user_on_route) do
      if type(e) == "table" and type(e.caller_id) == "string" and type(e.route) == "string" then
        pairs_set[pair_key(e.caller_id, e.route)] = true
      end
    end
  end
  return {
    version       = snapshot.version,
    users         = set_of(snapshot.users),
    system_tokens = set_of(snapshot.system_tokens),
    routes        = set_of(snapshot.routes),
    user_on_route = pairs_set,
  }
end

-- Returns the block kind ("route" | "user" | "system_token" | "user_on_route")
-- or nil when the request is allowed. caller_id and route_name may be nil.
function M.check(idx, caller_id, route_name)
  if not idx then
    return nil
  end
  if route_name and idx.routes[route_name] then
    return "route"
  end
  if caller_id then
    if idx.users[caller_id] then
      return "user"
    end
    if idx.system_tokens[caller_id] then
      return "system_token"
    end
    if route_name and idx.user_on_route[pair_key(caller_id, route_name)] then
      return "user_on_route"
    end
  end
  return nil
end

-- Logical route name = the HTTPRoute name. KIC tags every generated Kong route
-- with "k8s-name:<HTTPRoute name>"; fall back to parsing the generated name
-- "httproute.<namespace>.<name>.<rule>.<match>".
function M.route_name(route)
  if type(route) ~= "table" then
    return nil
  end
  if type(route.tags) == "table" then
    for _, t in ipairs(route.tags) do
      if type(t) == "string" and t:sub(1, 9) == "k8s-name:" then
        return t:sub(10)
      end
    end
  end
  if type(route.name) == "string" then
    local name = route.name:match("^httproute%.[^.]+%.([^.]+)%.")
    return name or route.name
  end
  return nil
end

return M
