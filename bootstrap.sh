#!/bin/bash
set -euo pipefail

# --- 0) Pick a random state and tag the EC2 instance ---
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds:21600")
STATES_JSON=$(curl -s https://raw.githubusercontent.com/petlaugh-33/ab2weathersimulator/main/states.json)
LEN=$(echo "$STATES_JSON" | jq '.states | length')
INDEX=$(( $(date +%s) % LEN ))
STATE=$(echo "$STATES_JSON" | jq -r ".states[$INDEX]")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)
aws ec2 create-tags \
  --resources "$INSTANCE_ID" \
  --tags Key=StateCode,Value="$STATE" Key=Name,Value="weather-monitor-$STATE"
echo "Assigned StateCode: $STATE" > /var/log/state-assignment.log

# --- 1) System update & base packages ---
yum update -y
yum install -y git python3 python3-pip jq aws-cli

# --- 2) Fetch claim certificates & root CA from S3 ---
CERT_DIR=/etc/iot-device
mkdir -p "$CERT_DIR"
aws s3 cp "s3://my-iot-claim-certs/AmazonRootCA1 (1).pem" "$CERT_DIR/rootCA.pem"
aws s3 cp "s3://my-iot-claim-certs/public.pem.key"   "$CERT_DIR/claimCert.crt"
aws s3 cp "s3://my-iot-claim-certs/private.pem.key"  "$CERT_DIR/claimKey.key"
chmod 400 "$CERT_DIR"/claim*.key "$CERT_DIR"/claim*.crt "$CERT_DIR"/rootCA.pem

# --- 3) Install AWS IoT Device Client ---
curl -Lo /tmp/aws-iot-device-client.rpm \
  https://s3.amazonaws.com/aws-iot-device-client/aws-iot-device-client-latest.rpm
yum install -y /tmp/aws-iot-device-client.rpm

# --- 4) Configure fleet provisioning ---
cat > /etc/aws-iot-device-client/config.toml <<EOF
endpoint = "$(aws iot describe-endpoint --endpoint-type iot:Data-ATS --output text --query endpointAddress)"
claim_certificate_file = "/etc/iot-device/claimCert.crt"
claim_private_key_file  = "/etc/iot-device/claimKey.key"
root_ca_file            = "/etc/iot-device/rootCA.pem"

[provisioning]
enabled       = true
template_name = "MyFleetTemplate"
EOF

systemctl daemon-reload
systemctl enable aws-iot-device-client
systemctl start  aws-iot-device-client

# --- 5) Wait for device certs to arrive ---
PROV_DIR=/etc/aws-iot-device-client/certs
until ls "$PROV_DIR"/device*.pem >/dev/null 2>&1; do sleep 1; done

# copy the provisioned cert/key into our iot-device folder
cp "$PROV_DIR"/deviceCert.crt    /etc/iot-device/deviceCert.crt
cp "$PROV_DIR"/devicePrivateKey.key /etc/iot-device/devicePrivateKey.key
chmod 644 /etc/iot-device/device*.crt /etc/iot-device/device*.key

# --- 6) Install Python deps & persist STATE ---
pip3 install --no-cache-dir paho-mqtt requests jq
echo "$STATE" > /opt/STATE_CODE

# --- 7) Write the Paho publisher script ---
cat << 'PYTHON' > /opt/paho_publisher.py
#!/usr/bin/env python3
import ssl, time, json, random

from paho.mqtt import client as mqtt

with open('/opt/STATE_CODE') as f:
    STATE = f.read().strip()

ENDPOINT = 'a3qn7c7brkka54-ats.iot.us-east-1.amazonaws.com'
TOPIC    = f'weather/{STATE}'
ROOT_CA  = '/etc/iot-device/rootCA.pem'
CERT     = '/etc/iot-device/deviceCert.crt'
KEY      = '/etc/iot-device/devicePrivateKey.key'

client = mqtt.Client(client_id=f'weather-monitor-{STATE}')
client.tls_set(ca_certs=ROOT_CA,
               certfile=CERT,
               keyfile=KEY,
               tls_version=ssl.PROTOCOL_TLSv1_2)
client.connect(ENDPOINT, 8883)
client.loop_start()

try:
    while True:
        msg = json.dumps({
            'state': STATE,
            'timestamp': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
            'temperature': round(random.uniform(30,100),1),
            'humidity':    round(random.uniform(10,90),1)
        })
        print(msg, flush=True)
        client.publish(TOPIC, msg, qos=1)
        time.sleep(5)
except KeyboardInterrupt:
    client.loop_stop()
    client.disconnect()
PYTHON

chmod +x /opt/paho_publisher.py

# --- 8) Set up the publisher as a systemd service ---
LOG=/var/log/paho-weather.log
touch "$LOG"; chown ec2-user:ec2-user "$LOG"

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
