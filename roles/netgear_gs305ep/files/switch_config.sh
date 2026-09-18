#!/bin/bash

CONFIG_FILE="$1"
NTGRRC_BIN="./ntgrrc"  # Adjust path if needed

if [[ -z "$CONFIG_FILE" ]]; then
  echo "Usage: $0 <config.json>"
  exit 1
fi

if ! command -v jq >/dev/null; then
  echo "jq is required but not installed. Exiting."
  exit 1
fi

ADDRESS=$(jq -r '.address' "$CONFIG_FILE")
PASSWORD=$(jq -r '.password' "$CONFIG_FILE")

# Login
$NTGRRC_BIN login --address "$ADDRESS" --password "$PASSWORD" || {
  echo "Login failed."
  exit 1
}

# Apply settings per port
jq -c '.ports[]' "$CONFIG_FILE" | while read -r port_conf; do
  PORT=$(echo "$port_conf" | jq -r '.port')
  POE=$(echo "$port_conf" | jq -r '.poe // empty')
  SPEED=$(echo "$port_conf" | jq -r '.speed // empty')
  FLOW=$(echo "$port_conf" | jq -r '.flow_control // empty')
  MODE=$(echo "$port_conf" | jq -r '.mode // empty')

  echo "Configuring port $PORT..."

  if [[ -n "$POE" ]]; then
    $NTGRRC_BIN poe set -p "$PORT" --power "$POE" --address "$ADDRESS"
  fi

  if [[ -n "$SPEED" || -n "$FLOW" || -n "$MODE" ]]; then
    ARGS=()
    [[ -n "$SPEED" ]] && ARGS+=("--speed" "$SPEED")
    [[ -n "$FLOW" ]] && ARGS+=("--flow-control" "$FLOW")
    [[ -n "$MODE" ]] && ARGS+=("--mode" "$MODE")
    $NTGRRC_BIN port set -p "$PORT" "${ARGS[@]}" --address "$ADDRESS"
  fi
done
