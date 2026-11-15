#!/usr/bin/env bash
# Command-line client for the blocking service (same API as the Swagger UI).
# A block = WHO (subject type + id) + WHERE (a route, or * = all routes).
#   scripts/block.sh add user     666efratg@corp.local '*'           "abnormal request volume" [ttlSeconds]
#   scripts/block.sh add user     777danag@corp.local  orders-create "duplicate orders"
#   scripts/block.sh add system   reports-service      '*'           "runaway batch job"
#   scripts/block.sh add token    <jti>                '*'           "token leaked"            300
#   scripts/block.sh add everyone -                    orders-create "backend failure"
#   scripts/block.sh list | routes | audit
#   scripts/block.sh unblock <id>
# Everyone on all routes is rejected (400). Token jti: scripts/get-token.sh <who> | cut -d. -f2 | base64 -d
source "$(dirname "$0")/lib.sh"
need curl jq
TOKEN="${TOKEN:-$("$REPO_ROOT/scripts/get-token.sh" opsadmin)}"
api() { "${CURL[@]}" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' "$@"; }

case "${1:-}" in
  list)    api "$BLOCKING_URL/api/blocks" | jq . ;;
  routes)  api "$BLOCKING_URL/api/routes" | jq -r '.[]' ;;
  audit)   api "$BLOCKING_URL/api/audit" | jq . ;;
  unblock) api -X DELETE "$BLOCKING_URL/api/blocks/${2:?id}" && echo "unblocked $2" ;;
  add)
    type="${2:?type: user | system | token | everyone}"; id="${3:?id (- for everyone)}"
    route="${4:?route (* = all routes)}"; reason="${5:?reason}"; ttl="${6:-}"
    body="$(jq -n --arg t "$type" --arg i "$id" --arg r "$route" --arg why "$reason" --arg ttl "$ttl" '
      {subject: ({type: $t} + (if $i == "-" then {} else {id: $i} end)), reason: $why}
      + (if $r == "*" then {} else {route: $r} end)
      + (if $ttl == "" then {} else {ttlSeconds: ($ttl | tonumber)} end)')"
    api -X POST "$BLOCKING_URL/api/blocks" -d "$body" | jq . ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
