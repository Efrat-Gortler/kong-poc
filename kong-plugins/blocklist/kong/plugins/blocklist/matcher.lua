-- Pure matching logic for the blocklist plugin (no Kong / nginx dependencies,
-- so it is unit-tested directly with busted).
--
-- Snapshot format (GET /api/blocklist on the blocking service):
-- {
--   "version": "sha256...",
--   "rules": {                                   -- rule key -> block id
--     "user:666efratg@corp.local@*":     "3f25...",
--     "user:777danag@corp.local@orders-create": "...",
--     "system:reports-service@*":        "...",
--     "token:8f0c6f3e-...@*":            "...",
--     "everyone:*@orders-create":        "..."
--   }
-- }
-- Rule key = <type>:<id>@<route>, type = user | system | token | everyone, id "*" for everyone,
-- route "*" for all routes. Route names never contain "@", so keys stay unambiguous with upns.
local cjson = require "cjson.safe"

local M = { ALL = "*" }

local function key(t, id, route)
  return t .. ":" .. id .. "@" .. (route or M.ALL)
end
M.key = key

-- Build the lookup table. Returns nil, err for a structurally invalid snapshot.
function M.index(snapshot)
  if type(snapshot) ~= "table" then
    return nil, "snapshot is not an object"
  end
  if type(snapshot.version) ~= "string" or snapshot.version == "" then
    return nil, "snapshot has no version"
  end
  if type(snapshot.rules) ~= "table" then
    return nil, "snapshot has no rules object"
  end
  local rules, n = {}, 0
  for k, v in pairs(snapshot.rules) do
    if type(k) == "string" and k ~= "" then
      rules[k] = type(v) == "string" and v or true
      n = n + 1
    end
  end
  return { version = snapshot.version, rules = rules, size = n }
end

-- "user" | "system": a token is a system token when it carries `claim` (POC: Keycloak puts
-- client_id only into client-credentials tokens) and, if `values` is a non-empty list, the
-- claim's value (or one of its values) is in it.
function M.caller_type(claims, claim, values)
  if type(claims) ~= "table" or type(claim) ~= "string" then
    return "user"
  end
  local v = claims[claim]
  if v == nil or v == cjson.null or v == false or v == "" then
    return "user"
  end
  if type(values) ~= "table" or #values == 0 then
    return "system"
  end
  local candidates = type(v) == "table" and v or { v }
  for _, c in ipairs(candidates) do
    for _, want in ipairs(values) do
      if tostring(c) == want then
        return "system"
      end
    end
  end
  return "user"
end

-- Returns { key, block_id, kind } for the first matching rule, or nil when allowed.
-- At most 5 lookups: subject@route, subject@*, token@route, token@*, everyone@route.
-- caller_type: "user" | "system"; caller_id, jti, route_name may be nil.
function M.check(idx, caller_type, caller_id, jti, route_name)
  if not idx then
    return nil
  end
  local rules = idx.rules
  local function hit(k, kind)
    local id = rules[k]
    if id then
      return { key = k, block_id = id ~= true and id or nil, kind = kind }
    end
  end
  local r
  if route_name then
    r = hit(key("everyone", M.ALL, route_name), "everyone@route")
    if r then return r end
  end
  if caller_id then
    if route_name then
      r = hit(key(caller_type, caller_id, route_name), caller_type .. "@route")
      if r then return r end
    end
    r = hit(key(caller_type, caller_id, M.ALL), caller_type .. "@*")
    if r then return r end
  end
  if jti then
    if route_name then
      r = hit(key("token", jti, route_name), "token@route")
      if r then return r end
    end
    r = hit(key("token", jti, M.ALL), "token@*")
    if r then return r end
  end
  return nil
end

-- ---- JWT payload (NOT verified here: openid-connect, priority 1050, has already verified this
-- exact bearer token before this plugin, priority 1000, runs) ----

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_INDEX = {}
for i = 1, #B64 do B64_INDEX[B64:sub(i, i)] = i - 1 end

-- Plain-Lua fallback; inside Kong ngx.decode_base64 (C) is used.
local function b64decode_lua(s)
  local out, bits, nbits = {}, 0, 0
  for i = 1, #s do
    local v = B64_INDEX[s:sub(i, i)]
    if v == nil then
      if s:sub(i, i) ~= "=" then return nil end
    else
      bits = bits * 64 + v
      nbits = nbits + 6
      if nbits >= 8 then
        nbits = nbits - 8
        local byte = math.floor(bits / 2 ^ nbits)
        out[#out + 1] = string.char(byte)
        bits = bits - byte * 2 ^ nbits
      end
    end
  end
  return table.concat(out)
end

local function b64url_decode(s)
  s = s:gsub("-", "+"):gsub("_", "/")
  local pad = #s % 4
  if pad == 2 then s = s .. "==" elseif pad == 3 then s = s .. "=" elseif pad == 1 then return nil end
  local native = ngx and ngx.decode_base64
  if native then
    return native(s)
  end
  return b64decode_lua(s)
end

-- Claims of the bearer token in an Authorization header value, or nil.
function M.jwt_claims(authorization)
  if type(authorization) ~= "string" then
    return nil
  end
  local token = authorization:match("^[Bb][Ee][Aa][Rr][Ee][Rr]%s+(%S+)%s*$")
  local payload = token and token:match("^[^.]+%.([^.]+)%.[^.]*$")
  if not payload then
    return nil
  end
  local json = b64url_decode(payload)
  local claims = json and cjson.decode(json)
  if type(claims) ~= "table" then
    return nil
  end
  return claims
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
