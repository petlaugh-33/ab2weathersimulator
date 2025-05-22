usr/bin/env bash
set -euo pipefail

# Discover IoT data endpoint
export AWS_IOT_ENDPOINT=$(aws iot describe-endpoint \
  --endpoint-type iot:Data-ATS \
  --output text --query endpointAddress)

# Certificate paths
export CLAIM_CERT="/etc/weather-sim/certs/claim.pem.crt"
export CLAIM_KEY="/etc/weather-sim/certs/claim.pem.key"
export ROOT_CA="/etc/weather-sim/certs/AmazonRootCA1.pem"

# Defaults (override via user-data tags or launch config)
export CLIENT_ID="weather_station_simulator"
export TOPIC="sensor/data"

# Start the simulator
exec /opt/weather-simulator/run.sh >> /var/log/weather-sim.log 2>&1

