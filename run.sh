#!/usr/bin/env bash
set -e

# Ensure environment variables are set:
: "${AWS_IOT_ENDPOINT:?need AWS_IOT_ENDPOINT}"
: "${CLIENT_ID:?need CLIENT_ID}"
: "${CLAIM_CERT:?need CLAIM_CERT}"
: "${CLAIM_KEY:?need CLAIM_KEY}"
: "${ROOT_CA:?need ROOT_CA}"
: "${TOPIC:?need TOPIC}"

exec python3 /opt/weather-simulator/weather_simulator.py \
  --endpoint "$AWS_IOT_ENDPOINT" \
  --client-id "$CLIENT_ID" \
  --cert "$CLAIM_CERT" \
  --key "$CLAIM_KEY" \
  --root-ca "$ROOT_CA" \
  --topic "$TOPIC"
