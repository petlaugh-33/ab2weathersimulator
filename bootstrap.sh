#!/bin/bash
set -euo pipefail

# --- 0) Auto-assign StateCode tag if not set ---
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds:21600")
EXISTING=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/tags/instance/StateCode || true)
if [[ -z "$EXISTING" ]]; then
  # Download states list from GitHub
  STATES_JSON=$(curl -s https://raw.githubusercontent.com/your-org/ab2weathersimulator/main/states.json)
  # Pick a random state
  STATE=$(echo "$STATES_JSON" | jq -r '.states | .[ (now|floor % length) ]')
  INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/instance-id)
  aws ec2 create-tags \
    --resources "$INSTANCE_ID" \
    --tags Key=StateCode,Value="$STATE" Key=Name,Value="weather-monitor-$STATE"
else
  STATE="$EXISTING"
fi

echo "Assigned StateCode: $STATE" > /var/log/state-assignment.log

# 1) System update & packages
yum update -y
yum install -y git python3 python3-pip jq aws-cli

# 2) Fetch certificates & CA from S3
CERT_DIR=/etc/iot-device
mkdir -p "$CERT_DIR"
aws s3 cp "s3://my-iot-claim-certs/AmazonRootCA1 (1).pem" \
    "$CERT_DIR/rootCA.pem"
aws s3 cp "s3://my-iot-claim-certs/public.pem.key" \
    "$CERT_DIR/deviceCert.crt"
aws s3 cp "s3://my-iot-claim-certs/private.pem.key" \
    "$CERT_DIR/devicePrivateKey.key"
chmod 644 "$CERT_DIR"/*

# 3) Python dependencies
pip3 install --no-cache-dir paho-mqtt requests

# 4) Write publisher script
cat << 'PYTHON' > /opt/paho_publisher.py
#!/usr/bin/env python3
import ssl, time, json, random
from paho.mqtt import client as mqtt

# Read STATE from file
with open('/opt/STATE_CODE') as f:
    STATE = f.read().strip()

ENDPOINT = 'a3qn7c7brkka54-ats.iot.us-east-1.amazonaws.com'
TOPIC    = f'weather/{STATE}'
ROOT_CA = '/etc/iot-device/rootCA.pem'
CERT    = '/etc/iot-device/deviceCert.crt'
KEY     = '/etc/iot-device/devicePrivateKey.key'

client = mqtt.Client(client_id=f'weather-monitor-{STATE}')
client.tls_set(ca_certs=ROOT_CA,
               certfile=CERT,
               keyfile=KEY,
               tls_version=ssl.PROTOCOL_TLSv1_2)
client.connect(ENDPOINT, port=8883)
client.loop_start()

try:
    while True:
        payload = {
            'state': STATE,
            'timestamp': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
            'temperature': round(random.uniform(30,100),1),
            'humidity':    round(random.uniform(10,90),1)
        }
        msg = json.dumps(payload)
        print(msg, flush=True)
        client.publish(TOPIC, msg, qos=1)
        time.sleep(5)
except KeyboardInterrupt:
    client.loop_stop()
    client.disconnect()
PYTHON

# Persist STATE for publisher
echo "$STATE" > /opt/STATE_CODE
chmod +x /opt/paho_publisher.py

# 5) Systemd service & log setup
LOG=/var/log/paho-weather.log
touch "$LOG"
chown ec2-user:ec2-user "$LOG"

cat << 'UNIT' > /etc/systemd/system/paho-weather.service
[Unit]
Description=Weather Publisher via Paho MQTT
After=network.target

[Service]
Type=simple
User=ec2-user
ExecStart=/opt/paho_publisher.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable paho-weather.service
systemctl start  paho-weather.service
