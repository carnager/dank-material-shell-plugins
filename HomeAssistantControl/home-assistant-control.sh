#!/bin/bash

ENTITY_ID="$1"
NEW_STATE="$2"
BASE_URL="${3:-http://homeassistant.local:8123}"
TOKEN="${4:-}"

if [[ -z "$ENTITY_ID" || -z "$NEW_STATE" || -z "$TOKEN" ]]; then
    echo "Usage: $0 <entity-id> <true|false> <base-url> <access-token>" >&2
    exit 1
fi

if [ "$NEW_STATE" = "true" ]; then
    SERVICE="turn_on"
else
    SERVICE="turn_off"
fi

curl -sS --fail -k -X POST \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"entity_id\":\"$ENTITY_ID\"}" \
    "$BASE_URL/api/services/homeassistant/$SERVICE"
