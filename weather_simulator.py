import json
import time
import random
import datetime
import math
from AWSIoTPythonSDK.MQTTLib import AWSIoTMQTTClient

# AWS IoT Core Configuration
ENDPOINT = "a3qn7c7brkka54-ats.iot.us-east-1.amazonaws.com"
CLIENT_ID = "weather_station_simulator"
TOPIC = "sensor/data"
PATH_TO_CERT = "certificates/device.pem.crt"
PATH_TO_KEY = "certificates/private.pem.key"
PATH_TO_ROOT = "certificates/root.pem"

STATIONS = [
    {
        "id": "weather_monitor_wa",
        "state": "Washington",
        "city": "Seattle",
        "lat": 47.6062,
        "lon": -122.3321,
        "temp_range": (35, 75),
        "humidity_range": (60, 90),
        "pressure_range": (1010, 1020),
        "rainfall_prob": 0.4,
        "wind_range": (0, 15)
    },
    {
        "id": "weather_monitor_ca",
        "state": "California",
        "city": "San Francisco",
        "lat": 37.7749,
        "lon": -122.4194,
        "temp_range": (50, 70),
        "humidity_range": (70, 85),
        "pressure_range": (1010, 1018),
        "rainfall_prob": 0.2,
        "wind_range": (5, 20)
    },
    {
        "id": "weather_monitor_tx",
        "state": "Texas",
        "city": "Austin",
        "lat": 30.2672,
        "lon": -97.7431,
        "temp_range": (60, 95),
        "humidity_range": (50, 80),
        "pressure_range": (1008, 1015),
        "rainfall_prob": 0.2,
        "wind_range": (0, 15)
    },
    {
        "id": "weather_monitor_fl",
        "state": "Florida",
        "city": "Miami",
        "lat": 25.7617,
        "lon": -80.1918,
        "temp_range": (70, 90),
        "humidity_range": (70, 95),
        "pressure_range": (1008, 1016),
        "rainfall_prob": 0.4,
        "wind_range": (5, 20)
    },
    {
        "id": "weather_monitor_ny",
        "state": "New York",
        "city": "New York City",
        "lat": 40.7128,
        "lon": -74.0060,
        "temp_range": (30, 85),
        "humidity_range": (45, 75),
        "pressure_range": (1008, 1020),
        "rainfall_prob": 0.3,
        "wind_range": (5, 25)
    }
]

def calculate_heat_index(T, RH):
    if T < 80:
        return T
    hi = -42.379 + (2.04901523 * T) + (10.14333127 * RH) - (0.22475541 * T * RH)          - (6.83783e-3 * T ** 2) - (5.481717e-2 * RH ** 2) + (1.22874e-3 * T ** 2 * RH)          + (8.5282e-4 * T * RH ** 2) - (1.99e-6 * T ** 2 * RH ** 2)
    return round(hi, 2)

def calculate_dew_point(T, RH):
    T_C = (T - 32) * 5 / 9
    gamma = math.log(RH / 100) + (17.62 * T_C) / (243.12 + T_C)
    dp_C = (243.12 * gamma) / (17.62 - gamma)
    return round((dp_C * 9 / 5) + 32, 2)

class WeatherStationSimulator:
    def __init__(self):
        self.mqtt_client = self._setup_mqtt_client()
        self.weather_conditions = {}

    def _setup_mqtt_client(self):
        client = AWSIoTMQTTClient(CLIENT_ID)
        client.configureEndpoint(ENDPOINT, 8883)
        client.configureCredentials(PATH_TO_ROOT, PATH_TO_KEY, PATH_TO_CERT)
        client.configureAutoReconnectBackoffTime(1, 32, 20)
        client.configureOfflinePublishQueueing(-1)
        client.configureDrainingFrequency(2)
        client.configureConnectDisconnectTimeout(10)
        client.configureMQTTOperationTimeout(5)
        client.connect()
        return client

    def generate_weather_data(self, station):
        sid = station["id"]
        if sid not in self.weather_conditions:
            self.weather_conditions[sid] = {"is_raining": False, "rain_intensity": 0}

        hour = datetime.datetime.now().hour
        temp_adj = next(adj for rng, adj in {
            range(0, 6): -5, range(6, 12): 0, range(12, 18): 5, range(18, 24): 0
        }.items() if hour in rng)

        temperature = round(random.uniform(*station["temp_range"]) + temp_adj, 2)
        humidity = round(random.uniform(*station["humidity_range"]), 2)
        pressure = round(random.uniform(*station["pressure_range"]), 2)
        wind_speed = round(random.uniform(*station["wind_range"]), 2)
        wind_direction = round(random.uniform(0, 360), 2)

        rain_chance = random.random() < station["rainfall_prob"]
        self.weather_conditions[sid]["is_raining"] = rain_chance
        self.weather_conditions[sid]["rain_intensity"] = (
            min(self.weather_conditions[sid]["rain_intensity"] + random.uniform(0, 0.5), 4)
            if rain_chance else 0
        )

        heat_index = calculate_heat_index(temperature, humidity)
        dew_point = calculate_dew_point(temperature, humidity)
        condition = "Clear"
        if self.weather_conditions[sid]["is_raining"]:
            r = self.weather_conditions[sid]["rain_intensity"]
            condition = "Light Rain" if r < 1 else "Moderate Rain" if r < 2.5 else "Heavy Rain"
        elif humidity > 90:
            condition = "Foggy"
        elif wind_speed > 20:
            condition = "Windy"

        return {
            "device": sid,
            "state": station["state"],
            "city": station["city"],
            "timestamp": int(time.time()),
            "measurements": {
                "temperature": temperature,
                "humidity": humidity,
                "pressure": pressure,
                "wind_speed": wind_speed,
                "wind_direction": wind_direction,
                "rainfall": round(self.weather_conditions[sid]["rain_intensity"], 2),
                "heat_index": heat_index,
                "dew_point": dew_point
            },
            "conditions": {
                "weather_condition": condition,
                "is_raining": self.weather_conditions[sid]["is_raining"]
            }
        }

    def run(self):
        while True:
            for station in STATIONS:
                try:
                    data = self.generate_weather_data(station)
                    self.mqtt_client.publish(TOPIC, json.dumps(data), 1)
                    print(f"{station['city']}, {station['state']}: Temp={data['measurements']['temperature']}F")
                except Exception as e:
                    print(f"Error with {station['id']}: {e}")
            time.sleep(5)

if __name__ == "__main__":
    print("Starting Weather Simulator...")
    WeatherStationSimulator().run()
