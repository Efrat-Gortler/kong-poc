local typedefs = require "kong.db.schema.typedefs"

return {
  name = "blocklist",
  fields = {
    -- global or per route/service only; blocks are keyed by caller_id, not by Kong Consumer
    { consumer = typedefs.no_consumer },
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          -- Snapshot endpoint of the blocking service.
          { service_url = typedefs.url { required = true } },
          -- Reader credential for the snapshot endpoint (injected from a Secret via KIC configPatches).
          { api_key = { type = "string", required = true, referenceable = true } },
          { poll_interval = { type = "number", default = 5, between = { 1, 300 } } },
          { timeout_ms = { type = "integer", default = 2000, between = { 100, 60000 } } },
          -- What to do before the FIRST successful fetch. After that, the last good list is kept.
          { fail_open = { type = "boolean", default = false } },
          -- Log + mark (X-Blocklist-Would-Block) instead of rejecting. Used by blocking.mode=both-observe.
          { observe_only = { type = "boolean", default = false } },
          { status_code = { type = "integer", default = 403, between = { 400, 599 } } },
          -- Free text, only for log lines.
          { leg = { type = "string" } },
        },
      },
    },
  },
}
