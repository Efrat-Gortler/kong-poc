#!/usr/bin/env bash
# Command-line client for the blocking service (same API as the Swagger UI).
#   scripts/block.sh list
#   scripts/block.sh user          666efratg@corp.local "abnormal request volume" [ttlSeconds]
#   scripts/block.sh system_token  reports-service      "token leaked"            [ttlSeconds]
#   scripts/block.sh route         orders-create        "backend failure"         [ttlSeconds]
#   scripts/block.sh user_on_route 777danag@corp.local orders-create "reason"     [ttlSeconds]
#   scripts/block.sh unblock <id>
#   scripts/block.sh audit
source "$(dirname "$0")/lib.sh"
need curl jq
TOKEN="${TOKEN:-$("$REPO_ROOT/scripts/get-token.sh" opsadmin)}"
api() { "${CURL[@]}" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' "$@"; }
ttl_json() { [[ -n "${1:-}" ]] && echo ", \"ttlSeconds\": $1" || true; }

case "${1:-}" in
  list)   api "$BLOCKING_URL/api/blocks" | jq . ;;
  audit)  api "$BLOCKING_URL/api/audit" | jq . ;;
  unblock) api -X DELETE "$BLOCKING_URL/api/blocks/${2:?id}" && echo "unblocked $2" ;;
  user|system_token)
    api -X POST "$BLOCKING_URL/api/blocks" \
      -d "{\"kind\":\"$1\",\"callerId\":\"${2:?caller_id}\",\"reason\":\"${3:?reason}\"$(ttl_json "${4:-}")}" | jq . ;;
  route)
    api -X POST "$BLOCKING_URL/api/blocks" \
      -d "{\"kind\":\"route\",\"route\":\"${2:?route}\",\"reason\":\"${3:?reason}\"$(ttl_json "${4:-}")}" | jq . ;;
  user_on_route)
    api -X POST "$BLOCKING_URL/api/blocks" \
      -d "{\"kind\":\"user_on_route\",\"callerId\":\"${2:?caller_id}\",\"route\":\"${3:?route}\",\"reason\":\"${4:?reason}\"$(ttl_json "${5:-}")}" | jq . ;;
  *) sed -n '2,9p' "$0"; exit 1 ;;
esac
