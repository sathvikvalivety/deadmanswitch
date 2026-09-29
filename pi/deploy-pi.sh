#!/usr/bin/env bash
set -e

PI_HOST="${1:-192.168.137.62}"
PI_USER="${2:-pi}"
IOT_ENDPOINT="${3:-}"
THING_NAME="deadman-pi"
INTERVAL_S="300"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="$SCRIPT_DIR/../certs"
SSH_KEY="$CERT_DIR/id_ed25519_pi"

echo "=== Raspberry Pi Heartbeat Deployment ==="
echo "Target: $PI_USER@$PI_HOST"

if [ -z "$IOT_ENDPOINT" ]; then
    IOT_ENDPOINT=$(aws iot describe-endpoint --endpoint-type iot:Data-ATS --query endpointAddress --output text 2>/dev/null || echo "YOUR_AWS_IOT_ENDPOINT.iot.ap-south-1.amazonaws.com")
fi

SSH_OPTS="-o StrictHostKeyChecking=no"
if [ -f "$SSH_KEY" ]; then
    SSH_OPTS="$SSH_OPTS -i $SSH_KEY"
fi

echo "Step 1: Staging files..."
scp $SSH_OPTS "$SCRIPT_DIR/heartbeat.py" "$SCRIPT_DIR/deadman-heartbeat.service" "$PI_USER@$PI_HOST:/tmp/"
if [ -f "$CERT_DIR/device.pem.crt" ]; then
    scp $SSH_OPTS "$CERT_DIR/device.pem.crt" "$CERT_DIR/private.pem.key" "$CERT_DIR/AmazonRootCA1.pem" "$PI_USER@$PI_HOST:/tmp/"
fi

echo "Step 2: Configuring Pi daemon and service..."
ssh $SSH_OPTS "$PI_USER@$PI_HOST" "bash -s" <<EOF
set -e
echo '[1/6] Creating deadman system user...'
sudo id -u deadman &>/dev/null || sudo useradd --system --home /opt/deadman --shell /usr/sbin/nologin deadman
sudo mkdir -p /opt/deadman /etc/deadman

echo '[2/6] Setting up Python virtual environment...'
sudo apt-get update -qq && sudo apt-get install -y -qq python3-venv python3-pip
if [ ! -d "/opt/deadman/venv" ]; then
    sudo python3 -m venv /opt/deadman/venv
fi
sudo /opt/deadman/venv/bin/pip install --upgrade pip -q
sudo /opt/deadman/venv/bin/pip install awsiotsdk -q

echo '[3/6] Deploying scripts and certificates...'
sudo mv /tmp/heartbeat.py /opt/deadman/heartbeat.py
sudo chmod 755 /opt/deadman/heartbeat.py
sudo chown -R deadman:deadman /opt/deadman

if [ -f /tmp/device.pem.crt ]; then
    sudo mv /tmp/device.pem.crt /tmp/private.pem.key /tmp/AmazonRootCA1.pem /etc/deadman/
    sudo chown -R root:deadman /etc/deadman
    sudo chmod 750 /etc/deadman
    sudo chmod 640 /etc/deadman/*
fi

echo '[4/6] Creating /etc/deadman/env...'
sudo tee /etc/deadman/env >/dev/null <<ENV_EOF
IOT_ENDPOINT=$IOT_ENDPOINT
THING=$THING_NAME
INTERVAL_S=$INTERVAL_S
CONFIG_DIR=/etc/deadman/
TOPIC=deadman/heartbeat
ENV_EOF
sudo chmod 640 /etc/deadman/env

echo '[5/6] Enabling and starting systemd service...'
sudo mv /tmp/deadman-heartbeat.service /etc/systemd/system/deadman-heartbeat.service
sudo systemctl daemon-reload
sudo systemctl enable deadman-heartbeat
sudo systemctl restart deadman-heartbeat

echo '[6/6] Service Status:'
sudo systemctl status deadman-heartbeat --no-pager || true
EOF

echo "Deployment complete! Live logs can be monitored with:"
echo "  ssh $SSH_OPTS $PI_USER@$PI_HOST 'journalctl -u deadman-heartbeat -f'"
