package kong.authz_test

import rego.v1

import data.kong.authz

# Unsigned test tokens are fine: the policy only decodes (Kong verified the real one).
token(claims) := io.jwt.encode_sign({"alg": "HS256", "typ": "JWT"}, claims, {"kty": "oct", "k": "c2VjcmV0"})

req(claims, route) := {
	"request": {"http": {"headers": {"authorization": concat(" ", ["Bearer", token(claims)])}}},
	"route": {"name": concat(".", ["httproute.leg1", route, "0.0"]), "tags": [concat(":", ["k8s-name", route])]},
}

user(id) := {"caller_id": id, "jti": concat("-", ["jti", id])}

system(id) := {"caller_id": id, "client_id": id, "jti": concat("-", ["jti", id])}

list := {
	"version": "v1",
	"rules": {
		"user:666efratg@corp.local@*": "b-user-all",
		"user:777danag@corp.local@orders-create": "b-user-route",
		"system:reports-service@*": "b-system-all",
		"system:billing-service@reports": "b-system-route",
		"token:jti-leaked@*": "b-token-all",
		"token:jti-replayed@orders-create": "b-token-route",
		"everyone:*@orders-export": "b-everyone-route",
	},
}

allowed(claims, route) if {
	authz.decision.allow with input as req(claims, route)
		with data.blocklist as list
}

blocked(claims, route) if {
	d := authz.decision with input as req(claims, route)
		with data.blocklist as list
	not d.allow
	d.status == 403
}

hits(claims, route) := h if {
	h := authz.hits with input as req(claims, route)
		with data.blocklist as list
}

test_allows_normal_user if allowed(user("normaluser@corp.local"), "orders")

# ---- the 7 combinations ----

test_user_all_routes if {
	blocked(user("666efratg@corp.local"), "orders")
	hits(user("666efratg@corp.local"), "orders") == {"user:666efratg@corp.local@*"}
}

test_user_one_route if {
	blocked(user("777danag@corp.local"), "orders-create")
	allowed(user("777danag@corp.local"), "orders")
}

test_system_all_routes if blocked(system("reports-service"), "users")

test_system_one_route if {
	blocked(system("billing-service"), "reports")
	allowed(system("billing-service"), "orders")
}

test_token_all_routes_whoever_holds_it if {
	blocked({"caller_id": "normaluser@corp.local", "jti": "jti-leaked"}, "orders")
	blocked({"caller_id": "x", "client_id": "x", "jti": "jti-leaked"}, "users")
	blocked({"jti": "jti-leaked"}, "orders")
}

test_token_one_route if {
	blocked({"caller_id": "normaluser@corp.local", "jti": "jti-replayed"}, "orders-create")
	allowed({"caller_id": "normaluser@corp.local", "jti": "jti-replayed"}, "orders")
}

test_everyone_one_route if {
	blocked(user("normaluser@corp.local"), "orders-export")
	blocked(system("reports-service-2"), "orders-export")
	allowed(user("normaluser@corp.local"), "orders")
}

test_everyone_route_without_token if {
	not authz.decision.allow with input as {"request": {"http": {"headers": {}}}, "route": {"tags": ["k8s-name:orders-export"]}}
		with data.blocklist as list
}

# ---- user vs system ----

test_user_rule_does_not_hit_system_with_same_id if {
	allowed(system("666efratg@corp.local"), "orders")
	allowed(user("reports-service"), "users")
}

test_system_claim_is_configurable if {
	# client_id no longer marks a system token once another claim is configured
	authz.decision.allow with input as req(system("reports-service"), "users")
		with data.blocklist as list
		with data.blocking_config as {"system_claim": "appid"}
	not authz.decision.allow with input as req({"caller_id": "reports-service", "appid": "x"}, "users")
		with data.blocklist as list
		with data.blocking_config as {"system_claim": "appid"}
}

test_system_claim_values if {
	cfg := {"system_claim": "grant", "system_claim_values": ["client_credentials"]}
	not authz.decision.allow with input as req({"caller_id": "reports-service", "grant": "client_credentials"}, "users")
		with data.blocklist as list
		with data.blocking_config as cfg
	authz.decision.allow with input as req({"caller_id": "reports-service", "grant": "password"}, "users")
		with data.blocklist as list
		with data.blocking_config as cfg
}

test_caller_type_defaults if {
	authz.caller_type == "user" with input as req({"caller_id": "a"}, "orders")
	authz.caller_type == "system" with input as req({"caller_id": "a", "client_id": "a"}, "orders")
	authz.caller_type == "user" with input as req({"caller_id": "a", "client_id": ""}, "orders")
}

test_at_most_five_candidates if {
	c := authz.candidates with input as req(user("a"), "orders")
	count(c) == 5
}

# ---- robustness ----

test_exact_match if {
	allowed(user("666EFRATG@corp.local"), "orders")
	allowed({"caller_id": "x", "jti": "JTI-LEAKED"}, "orders")
}

# No bundle loaded yet -> no rules -> allow (OPA side is fail-open;
# an unreachable OPA is fail-closed: Kong answers 500).
test_no_bundle_allows if {
	authz.decision.allow with input as req(user("666efratg@corp.local"), "orders")
}

test_ignores_malformed_header if {
	authz.decision.allow with input as {"request": {"http": {"headers": {"authorization": "Basic abc"}}}, "route": {"tags": []}}
		with data.blocklist as list
}
