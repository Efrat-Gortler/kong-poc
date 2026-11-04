#!/usr/bin/env bash
# Simulates a release drain in the GSLB.
#   scripts/drain-leg.sh status
#   scripts/drain-leg.sh leg2 drain    # leg2 gets no new requests
#   scripts/drain-leg.sh leg2 ready    # back in rotation
source "$(dirname "$0")/lib.sh"
need curl jq
case "${1:-status}" in
  status) "${CURL[@]}" "$GSLB_CONTROL_URL/legs" | jq . ;;
  *) "${CURL[@]}" -X POST "$GSLB_CONTROL_URL/legs/$1/${2:?drain|ready}" | jq . ;;
esac
