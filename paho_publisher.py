#!/usr/bin/env python3

import ssl, time, json, random, requests
from paho.mqtt import client as mqtt

# Fetch IMDSv2 token
token = requests.put(
    'http://169.254.169.254/latest/api/token',
    headers={'X-aws-ec2-metadata-token-ttl-seconds': '21600'}
).text

# Read the StateCode tag
STATE = requests.get(
    'http://169.254.169.254/latest/meta-data/tags/instance/StateCode',
    headers={'X-aws-ec2-metadata-token': token}
).text

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
