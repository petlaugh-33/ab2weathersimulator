#!/usr/bin/env python3
"""Publish random weather telemetry every 5 s and handle IoT jobs."""
import ssl, time, json, random, pathlib, os, subprocess
from paho.mqtt import client as mqtt

STATE      = pathlib.Path('/opt/STATE_CODE').read_text().strip()
ENDPOINT   = os.getenv('IOT_ENDPOINT')
TOPIC      = f"{os.getenv('TOPIC_PREFIX')}/{STATE}"
CERT_FILE  = '/etc/iot-device/cert.pem'
KEY_FILE   = '/etc/iot-device/priv.key'
ROOT_CA    = '/etc/ssl/certs/ca-bundle.crt'
CLIENT_ID  = f'weather_monitor_{STATE}'

def on_connect(client, userdata, flags, rc):
    print(f"Connected with result code {rc}", flush=True)
    # Subscribe to jobs topics
    client.subscribe(f"$aws/things/{CLIENT_ID}/jobs/notify-next")
    client.subscribe(f"$aws/things/{CLIENT_ID}/jobs/+/get/accepted")

def on_message(client, userdata, msg):
    print(f"Received message on topic {msg.topic}", flush=True)
    if 'notify-next' in msg.topic:
        payload = json.loads(msg.payload)
        if 'execution' in payload:
            job_id = payload['execution']['jobId']
            client.publish(f"$aws/things/{CLIENT_ID}/jobs/{job_id}/get", "")
    elif '/get/accepted' in msg.topic:
        handle_job(json.loads(msg.payload))

def handle_job(job_doc):
    job_id = job_doc['execution']['jobId']
    job = job_doc['execution']['jobDocument']
    
    print(f"Handling job {job_id}: {job}", flush=True)
    
    try:
        if job['operation'] == 'download':
            # Download file
            subprocess.run(['curl', '-o', job['destination'], job['source']['url']], check=True)
            
            # Run install script if provided
            if 'install' in job:
                subprocess.run(job['install']['script'], shell=True, check=True)
            
            # Run the script
            if 'run' in job:
                subprocess.run(job['run']['script'], shell=True, check=True)
            
        # Add more job types here as needed
        
        update_job_execution(client, job_id, 'SUCCEEDED')
    except Exception as e:
        print(f"Job failed: {e}", flush=True)
        update_job_execution(client, job_id, 'FAILED', {'error': str(e)})

def update_job_execution(client, job_id, status, status_details=None):
    payload = json.dumps({
        'status': status,
        'statusDetails': status_details or {}
    })
    client.publish(f"$aws/things/{CLIENT_ID}/jobs/{job_id}/update", payload)

client = mqtt.Client(client_id=CLIENT_ID)
client.on_connect = on_connect
client.on_message = on_message
client.tls_set(ROOT_CA, certfile=CERT_FILE, keyfile=KEY_FILE,
               tls_version=ssl.PROTOCOL_TLSv1_2)

print("Connecting to", ENDPOINT, "as", CLIENT_ID, flush=True)
rc = client.connect(ENDPOINT, 8883)
print("connect rc =", rc, flush=True)          # 0 = success
if rc:
    raise SystemExit("MQTT CONNECT failed")

client.loop_start()
try:
    while True:
        payload = json.dumps({
            "state": STATE,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "temperature": round(random.uniform(30,100),1),
            "humidity":    round(random.uniform(10,90),1)
        })
        client.publish(TOPIC, payload, qos=1)
        print(payload, flush=True)
        time.sleep(5)
finally:
    client.loop_stop(); client.disconnect()

