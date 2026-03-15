#!/bin/bash

BASE_URL="${1:-http://homeassistant.local:8123}"
TOKEN="${2:-}"

if [[ -z "$TOKEN" ]]; then
    echo "Usage: $0 <base-url> <access-token>" >&2
    exit 1
fi

raw_data=$(curl -sS --fail -k \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    "$BASE_URL/api/states")

echo "$raw_data" | jq -c '
  [ .[]
    | select(.entity_id | startswith("light.") or startswith("switch."))
    | {
        name: (.attributes.friendly_name // .entity_id),
        room: (.attributes.area_name // .attributes.area // .attributes.room // "Unassigned"),
        on: (.state == "on")
      }
  ]'
