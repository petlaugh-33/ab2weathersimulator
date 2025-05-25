#!/bin/bash
set -euo pipefail
# ---------- settings you might change ----------
POLICY_NAME="WeatherPublishPolicy"
TOPIC_PREFIX="weather"
# -----------------------------------------------

dnf update -y
dnf install -y jq awscli python3 python3-pip

###############################################################################
# 1. choose a random state and tag the instance
###############################################################################
TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token \
        -H "X-aws-ec2-metadata-token-ttl-seconds:21600")
IID=$(curl -s -H "X-aws-ec2-metadata-token:$TOKEN" \
        http://169.254.169.254/latest/meta-data/instance-id)

STATES=$(curl -s https://raw.githubusercontent.com/petlaugh-33/ab2weathersimulator/main/states.json)
LEN=$(echo "$STATES" | jq '.states|length')
IDX=$(( RANDOM % LEN ))
STATE=$(echo "$STATES" | jq -r ".states | sort | .[$IDX]")
THING_NAME="weather_monitor_${STATE}"

aws ec2 create-tags --resources "$IID" \
  --tags Key=Name,Value="$THING_NAME" Key=StateCode,Value="$STATE"
echo "$STATE" > /opt/STATE_CODE

###############################################################################
# 2. ensure IoT policy exists (idempotent)
###############################################################################
POLICY_DOC='{
  "Version":"2012-10-17",
  "Statement":[
    { "Effect":"Allow",
      "Action":[ "iot:Connect", "iot:Publish" ],
      "Resource":[
        "arn:aws:iot:*:*:client/weather-monitor-*",
        "arn:aws:iot:*:*:topic/weather/*"
      ] }
  ]
}'
aws iot get-policy --policy-name "$POLICY_NAME" >/dev/null 2>&1 \
  || aws iot create-policy --policy-name "$POLICY_NAME" --policy-document "$POLICY_DOC"

###############################################################################
# 3. create Thing, cert, keys, and attach everything
###############################################################################
aws iot create-thing --thing-name "$THING_NAME" >/dev/null 2>&1 || true

CERT_DIR=/etc/iot-device
mkdir -p "$CERT_DIR"
CREATE_OUT=$(aws iot create-keys-and-certificate --set-as-active \
              --certificate-pem-outfile "$CERT_DIR/cert.pem" \
              --public-key-outfile      "$CERT_DIR/pub.key"  \
              --private-key-outfile     "$CERT_DIR/priv.key")
CERT_ARN=$(echo "$CREATE_OUT" | jq -r '.certificateArn')

aws iot attach-policy         --policy-name "$POLICY_NAME"     --target "$CERT_ARN"
aws iot attach-thing-principal --thing-name "$THING_NAME"       --principal "$CERT_ARN"

chmod 644 "$CERT_DIR"/cert.pem "$CERT_DIR"/pub.key
chmod 600 "$CERT_DIR"/priv.key

###############################################################################
# 4. discover IoT endpoint
###############################################################################
IOT_ENDPOINT=$(aws iot describe-endpoint --endpoint-type iot:Data-ATS \
                 --query 'endpointAddress' --output text)

###############################################################################
# 5. install paho-mqtt and create publisher + systemd unit
###############################################################################
pip3 install --no-cache-dir paho-mqtt

cat >/usr/local/bin/publish_weather.py <<'PY'
#!/usr/bin/env python3
import ssl, time, json, random, pathlib, os
from paho.mqtt import client as mqtt

STATE      = pathlib.Path('/opt/STATE_CODE').read_text().strip()
ENDPOINT   = os.environ['IOT_ENDPOINT']
TOPIC      = f"{os.environ['TOPIC_PREFIX']}/{STATE}"
CERT_FILE  = '/etc/iot-device/cert.pem'
KEY_FILE   = '/etc/iot-device/priv.key'
ROOT_CA    = '/etc/ssl/certs/ca-bundle.crt'
client = mqtt.Client(client_id=f'weather-monitor-{STATE}')
client.tls_set(ROOT_CA, certfile=CERT_FILE, keyfile=KEY_FILE,
               tls_version=ssl.PROTOCOL_TLSv1_2)
client.connect(ENDPOINT, 8883); client.loop_start()
try:
    while True:
        msg = json.dumps({
            "state": STATE,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "temperature": round(random.uniform(30,100),1),
            "humidity":    round(random.uniform(10,90),1)
        })
        client.publish(TOPIC, msg, qos=1)
        time.sleep(5)
finally:
    client.loop_stop(); client.disconnect()
PY
chmod +x /usr/local/bin/publish_weather.py

cat >/etc/systemd/system/weather.service <<UNIT
[Unit]
Description=Weather telemetry publisher
After=network.target

[Service]
Environment="IOT_ENDPOINT=${IOT_ENDPOINT}"
Environment="TOPIC_PREFIX=${TOPIC_PREFIX}"
User=ec2-user
ExecStart=/usr/local/bin/publish_weather.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now weather.service
