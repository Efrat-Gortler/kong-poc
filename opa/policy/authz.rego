# Blocking decision for Kong's `opa` plugin (blocking mechanism B).
#
# Kong calls POST /v1/data/kong/authz/decision for every request.
# data.blocklist comes from the blocking service as an OPA bundle
# (roots: ["blocklist"]), polled every few seconds by this leg's OPA.
#
# Identity: Kong's opa input has no field for the OIDC "virtual credential",
# so the caller is read from the bearer token. io.jwt.decode does NOT verify
# the signature - that is safe only because openid-connect (priority 1050)
# has already verified this exact token before opa (920) runs.
package kong.authz

import rego.v1

default decision := {"allow": true}

decision := {"allow": false, "status": 403, "message": "Forbidden"} if count(block_kinds) > 0

# ---- inputs ----

bearer := t if {
	h := input.request.http.headers.authorization
	is_string(h)
	startswith(lower(h), "bearer ")
	t := substring(h, 7, -1)
}

caller_id := c if {
	[_, payload, _] := io.jwt.decode(bearer)
	c := payload.caller_id
	is_string(c)
}

# Logical route name = HTTPRoute name, from the "k8s-name:" tag KIC puts on every route.
route_name := n if {
	some t in input.route.tags
	startswith(t, "k8s-name:")
	n := substring(t, 9, -1)
}

# ---- rules ----

block_kinds contains "route" if route_name in data.blocklist.routes

block_kinds contains "user" if caller_id in data.blocklist.users

block_kinds contains "system_token" if caller_id in data.blocklist.system_tokens

block_kinds contains "user_on_route" if {
	some e in data.blocklist.user_on_route
	e.caller_id == caller_id
	e.route == route_name
}
