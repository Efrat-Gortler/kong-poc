package kong.authz_test

import rego.v1

import data.kong.authz

# Unsigned test tokens are fine: the policy only decodes (Kong verified the real one).
token(claims) := io.jwt.encode_sign({"alg": "HS256", "typ": "JWT"}, claims, {"kty": "oct", "k": "c2VjcmV0"})

req(claims, route) := {
	"request": {"http": {"headers": {"authorization": concat(" ", ["Bearer", token(claims)])}}},
	"route": {"name": concat(".", ["httproute.leg1", route, "0.0"]), "tags": [concat(":", ["k8s-name", route])]},
}

list := {
	"version": "v1",
	"users": ["666efratg@corp.local"],
	"system_tokens": ["reports-service"],
	"routes": ["orders-export"],
	"user_on_route": [{"caller_id": "777danag@corp.local", "route": "orders-create"}],
}

test_allows_normal_user if {
	authz.decision.allow with input as req({"caller_id": "normaluser@corp.local"}, "orders")
		with data.blocklist as list
}

test_blocks_user if {
	d := authz.decision with input as req({"caller_id": "666efratg@corp.local"}, "orders")
		with data.blocklist as list
	not d.allow
	d.status == 403
}

test_blocks_system_token if {
	not authz.decision.allow with input as req({"caller_id": "reports-service"}, "users")
		with data.blocklist as list
}

test_blocks_route_for_everybody if {
	not authz.decision.allow with input as req({"caller_id": "normaluser@corp.local"}, "orders-export")
		with data.blocklist as list
}

test_blocks_route_without_token if {
	not authz.decision.allow with input as {"request": {"http": {"headers": {}}}, "route": {"tags": ["k8s-name:orders-export"]}}
		with data.blocklist as list
}

test_user_on_route_only_on_that_route if {
	not authz.decision.allow with input as req({"caller_id": "777danag@corp.local"}, "orders-create")
		with data.blocklist as list
	authz.decision.allow with input as req({"caller_id": "777danag@corp.local"}, "orders")
		with data.blocklist as list
}

test_reports_kind if {
	k := authz.block_kinds with input as req({"caller_id": "777danag@corp.local"}, "orders-create")
		with data.blocklist as list
	k == {"user_on_route"}
}

# No bundle loaded yet -> data.blocklist undefined -> allow (OPA side is fail-open;
# an unreachable OPA is fail-closed: Kong answers 500).
test_no_bundle_allows if {
	authz.decision.allow with input as req({"caller_id": "666efratg@corp.local"}, "orders")
}

test_ignores_malformed_header if {
	authz.decision.allow with input as {"request": {"http": {"headers": {"authorization": "Basic abc"}}}, "route": {"tags": []}}
		with data.blocklist as list
}
