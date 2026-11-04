-- blocklist: rejects requests whose caller / route / caller-on-route is in the
-- blocking service's list.
--
-- * No network call in the request path. A background timer polls the blocking
--   service every `poll_interval` seconds (ETag / If-None-Match, so unchanged
--   polls are cheap) and stores the snapshot in shared memory. Only one worker
--   per pod polls (shared-memory lock); every worker reads the same snapshot.
-- * If a poll fails, the last good snapshot stays in use.
-- * Before the first successful poll, `fail_open` decides (default: 503).
-- * Runs after openid-connect (1050) and before opa (920) / rate limiting (910),
--   so a blocked request never consumes rate-limit quota.
local cjson   = require "cjson.safe"
local http    = require "resty.http"
local matcher = require "kong.plugins.blocklist.matcher"

local ngx        = ngx
local kong       = kong

local function timer_at(delay, fn)
  return ngx.timer.at(delay, fn)
end

local SHM_NAME        = "blocklist"
local KEY_SNAPSHOT    = "snapshot"     -- raw JSON body of the last good snapshot
local KEY_VERSION     = "version"      -- its version (also used as ETag)
local KEY_FETCHED_AT  = "fetched_at"   -- last successful poll (200 or 304)
local KEY_FAILURES    = "poll_failures"
local KEY_LOCK        = "poll_lock"

local Blocklist = {
  PRIORITY = 1000,
  VERSION  = "0.1.0",
}

-- per-worker state
local active_conf      -- config of the (single) global instance, set by configure()
local loop_running = false
local cached_version, cached_index

local function shm()
  local d = ngx.shared[SHM_NAME]
  if not d then
    error("lua_shared_dict '" .. SHM_NAME .. "' missing: set KONG_NGINX_HTTP_LUA_SHARED_DICT='blocklist 5m'")
  end
  return d
end

local function poll_once(conf)
  local dict = shm()
  -- one poller per pod and interval
  local got_lock = dict:add(KEY_LOCK, ngx.worker.pid(), math.max(conf.poll_interval * 0.9, 0.5))
  if not got_lock then
    return
  end

  local httpc = http.new()
  httpc:set_timeout(conf.timeout_ms)
  local headers = {
    ["Accept"]    = "application/json",
    ["X-Api-Key"] = conf.api_key,
  }
  local version = dict:get(KEY_VERSION)
  if version then
    headers["If-None-Match"] = '"' .. version .. '"'
  end

  local res, err = httpc:request_uri(conf.service_url, { method = "GET", headers = headers })
  if not res then
    dict:incr(KEY_FAILURES, 1, 0)
    kong.log.err("[blocklist] poll failed, keeping last list (version ", version or "none", "): ", err)
    return
  end
  if res.status == 304 then
    dict:set(KEY_FETCHED_AT, ngx.now())
    return
  end
  if res.status ~= 200 then
    dict:incr(KEY_FAILURES, 1, 0)
    kong.log.err("[blocklist] poll returned HTTP ", res.status, ", keeping last list")
    return
  end

  local snapshot, derr = cjson.decode(res.body)
  local idx, ierr = matcher.index(snapshot)
  if not idx then
    dict:incr(KEY_FAILURES, 1, 0)
    kong.log.err("[blocklist] invalid snapshot, keeping last list: ", derr or ierr)
    return
  end
  -- body first, then version: readers key their cache on the version
  dict:set(KEY_SNAPSHOT, res.body)
  dict:set(KEY_VERSION, idx.version)
  dict:set(KEY_FETCHED_AT, ngx.now())
  if idx.version ~= version then
    kong.log.notice("[blocklist] loaded list version ", idx.version)
  end
end

local function loop(premature)
  if premature then
    loop_running = false
    return
  end
  local conf = active_conf
  if not conf then              -- plugin removed from the config
    loop_running = false
    return
  end
  local ok, err = pcall(poll_once, conf)
  if not ok then
    kong.log.err("[blocklist] poll error: ", err)
  end
  local _, terr = timer_at(conf.poll_interval, loop)
  if terr then
    loop_running = false
    kong.log.err("[blocklist] could not reschedule poll timer: ", terr)
  end
end

-- Called in every worker whenever the declarative config changes.
-- `configs` = configs of all enabled instances of this plugin (nil if none).
function Blocklist:configure(configs)
  active_conf = configs and configs[1] or nil
  if configs and #configs > 1 then
    kong.log.warn("[blocklist] ", #configs, " instances configured; polling with the first only")
  end
  if active_conf and not loop_running then
    loop_running = true
    local _, err = timer_at(0, loop)
    if err then
      loop_running = false
      kong.log.err("[blocklist] could not start poll timer: ", err)
    end
  end
end

-- Decoded index for the current snapshot, decoded once per worker per version.
local function current_index()
  local dict = shm()
  local version = dict:get(KEY_VERSION)
  if not version then
    return nil
  end
  if version ~= cached_version then
    local idx = matcher.index(cjson.decode(dict:get(KEY_SNAPSHOT) or ""))
    if idx then
      cached_version, cached_index = version, idx
    end
  end
  return cached_index
end

function Blocklist:access(conf)
  local idx = current_index()
  if not idx then
    if conf.fail_open then
      return
    end
    return kong.response.exit(503, { message = "Service unavailable" })
  end

  local credential = kong.client.get_credential()
  local caller_id  = credential and credential.id or nil
  local route_name = matcher.route_name(kong.router.get_route())

  local kind = matcher.check(idx, caller_id, route_name)
  if not kind then
    return
  end

  -- reason stays in the logs only; the client gets a generic body
  kong.log.notice("[blocklist] ", conf.observe_only and "would block" or "blocked",
                  " kind=", kind, " caller_id=", caller_id or "-", " route=", route_name or "-",
                  " leg=", conf.leg or "-", " list_version=", idx.version)
  kong.ctx.shared.blocklist_kind = kind

  if conf.observe_only then
    kong.ctx.plugin.would_block = kind
    return
  end
  return kong.response.exit(conf.status_code, { message = "Forbidden" })
end

function Blocklist:header_filter(conf)
  if conf.observe_only and kong.ctx.plugin.would_block then
    kong.response.set_header("X-Blocklist-Would-Block", kong.ctx.plugin.would_block)
  end
end

return Blocklist
