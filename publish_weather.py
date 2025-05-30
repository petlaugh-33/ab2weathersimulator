#!/usr/bin/env python3
import ssl, time, json, random, pathlib, os
from paho.mqtt import client as mqtt

STATE      = pathlib.Path('/opt/STATE_CODE').read_text().strip()
ENDPOINT   = os.getenv('IOT_ENDPOINT')
TOPIC      = f"{os.getenv('TOPIC_PREFIX')}/{STATE}"
CERT_FILE  = '/etc/iot-device/cert.pem'
KEY_FILE   = '/etc/iot-device/priv.key'
ROOT_CA    = '/etc/ssl/certs/ca-bundle.crt'
CLIENT_ID  = f'weather_monitor_{STATE}'   

client = mqtt.Client(client_id=CLIENT_ID)
client.tls_set(ROOT_CA, certfile=CERT_FILE, keyfile=KEY_FILE,
               tls_version=ssl.PROTOCOL_TLSv1_2)

print("Connecting to", ENDPOINT, "as", CLIENT_ID, flush=True)
rc = client.connect(ENDPOINT, 8883)
print("connect rc =", rc, flush=True)          # 0 = success
if rc != 0:
    raise SystemExit("MQTT CONNECT failed")

client.loop_start()
try:
    while True:
        payload = json.dumps({
            "state": STATE,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "temperature": round(random.uniform(30, 100), 1),
            "humidity":    round(random.uniform(10, 90), 1)
        })
        client.publish(TOPIC, payload, qos=1)
        print(payload, flush=True)
        time.sleep(5)
finally:
    client.loop_stop(); client.disconnect()
