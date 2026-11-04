#!/usr/bin/env bash
# Prints an access token from the simulated ADFS (Keycloak).
#   scripts/get-token.sh 666efratg          # user (password grant via poc-cli)
#   scripts/get-token.sh reports-service    # system token (client credentials)
#   scripts/get-token.sh rogue-service      # token from the untrusted "rogue" realm
# Users:   666efratg 777danag normaluser opsadmin(role blocker)
# Clients: reports-service billing-service legacy-service(no caller_id) other-app(wrong aud) short-lived(5s)
source "$(dirname "$0")/lib.sh"
need oc curl jq
who="${1:?usage: $0 <user|client>}"
users="666efratg 777danag normaluser opsadmin"
realm="$REALM"; [[ "$who" == rogue-service ]] && realm=rogue
url="$KEYCLOAK_URL/realms/$realm/protocol/openid-connect/token"

if [[ " $users " == *" $who "* ]]; then
  pw="$(secret_value idp idp-test-credentials KC_TEST_USER_PASSWORD)"
  resp="$("${CURL[@]}" "$url" -d grant_type=password -d client_id=poc-cli \
          --data-urlencode "username=$who" --data-urlencode "password=$pw" -d scope=openid)"
else
  secret="$(secret_value idp idp-test-credentials KC_SYSTEM_CLIENT_SECRET)"
  resp="$("${CURL[@]}" "$url" -d grant_type=client_credentials -d client_id="$who" \
          --data-urlencode "client_secret=$secret")"
fi
jq -er .access_token <<<"$resp"
