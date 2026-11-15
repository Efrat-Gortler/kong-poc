# Blocking decision for Kong's `opa` plugin (blocking mechanism B).
#
# Kong calls POST /v1/data/kong/authz/decision for every request.
# data.blocklist comes from the blocking service as an OPA bundle (roots: ["blocklist"]),
# polled every few seconds by this leg's OPA:
#   data.blocklist.rules = { "<type>:<id>@<route>": "<block id>", ... }
#   type = user | system | token | everyone, id "*" for everyone, route "*" for all routes.
# data.blocking_config (charts/opa, from global.auth.systemToken) says which tokens are system tokens.
#
# Identity: Kong's opa input has no field for the OIDC "virtual credential", so caller_id, the
# system-token claim and jti are read from the bearer token. io.jwt.decode does NOT verify the
# signature - that is safe only because openid-connect (priority 1050) has already verified this
# exact token before opa (920) runs.
package kong.authz

import rego.v1

default decision := {"allow": true}

decision := {"allow": false, "status": 403, "message": "Forbidden"} if count(hits) > 0

# ---- inputs ----

bearer := t if {
	h := input.request.http.headers.authorization
	is_string(h)
	startswith(lower(h), "bearer ")
	t := trim_space(substring(h, 7, -1))
}

claims := payload if {
	[_, payload, _] := io.jwt.decode(bearer)
}

caller_id := c if {
	c := claims.caller_id
	is_string(c)
	c != ""
}

jti := j if {
	j := claims.jti
	is_string(j)
	j != ""
}

# Logical route name = HTTPRoute name, from the "k8s-name:" tag KIC puts on every route.
route_name := n if {
	some t in input.route.tags
	startswith(t, "k8s-name:")
	n := substring(t, 9, -1)
}

# ---- user or system ----

default system_claim := "client_id"

system_claim := data.blocking_config.system_claim

default system_claim_values := []

system_claim_values := data.blocking_config.system_claim_values

default caller_type := "user"

caller_type := "system" if is_system

is_system if {
	count(system_claim_values) == 0
	present(claims[system_claim])
}

is_system if {
	count(system_claim_values) > 0
	some want in system_claim_values
	claim_has(claims[system_claim], want)
}

present(v) if {
	v != null
	v != false
	v != ""
}

claim_has(v, want) if {
	not is_array(v)
	sprintf("%v", [v]) == want
}

claim_has(v, want) if {
	is_array(v)
	some x in v
	sprintf("%v", [x]) == want
}

# ---- rules: at most 5 key lookups ----

default rules := {}

rules := data.blocklist.rules

candidates contains concat("", ["everyone:*@", route_name])

candidates contains concat("", [caller_type, ":", caller_id, "@", route_name])

candidates contains concat("", [caller_type, ":", caller_id, "@*"])

candidates contains concat("", ["token:", jti, "@", route_name])

candidates contains concat("", ["token:", jti, "@*"])

hits contains k if {
	some k in candidates
	rules[k]
}
