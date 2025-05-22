# Weather Simulator Demo

This repository hosts code and scripts for a multi‑state AWS IoT weather simulator.

## Repository layout

- `weather_simulator.py`: Python script generating and publishing weather data.
- `run.sh`: Simple wrapper to invoke the simulator with environment variables.
- `scripts/start-weather-simulator.sh`: Bootstrapping script for EC2 user‑data.

## Usage

1. Bake an AMI including this repo under `/opt/weather-simulator`.
2. Launch EC2 instances using the AMI and add the following user‑data:
   ```bash
   #!/usr/bin/env bash
   /opt/weather-simulator/scripts/start-weather-simulator.sh
