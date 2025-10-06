#!/bin/bash
set -e

# Create virtual environment accessible by all users
python3 -m venv /etc/cost-metrics-env
chmod -R 755 /etc/cost-metrics-env

# Install requirements
/etc/cost-metrics-env/bin/pip install -r requirements.txt
