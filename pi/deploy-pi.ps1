<#
.SYNOPSIS
    Deploys the Dead Man's Switch Heartbeat service to the Raspberry Pi.
.DESCRIPTION
    Transfers scripts, configuration, and certificates to the Pi (default: 192.168.137.62),
    configures permissions, creates the dedicated virtual environment, installs awsiotsdk,
    and sets up the systemd service.
#>

param(
    [string]$PiHost = "192.168.137.62",
    [string]$PiUser = "pi",
    [string]$IotEndpoint = "",
    [string]$ThingName = "deadman-pi",
    [int]$IntervalSec = 300,
    [string]$SshKeyPath = "$PSScriptRoot\..\certs\id_ed25519_pi"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Raspberry Pi Heartbeat Deployment ===" -ForegroundColor Cyan
Write-Host "Target Host: $PiUser@$PiHost"

# Check if certificates exist
$certDir = Join-Path $PSScriptRoot "..\certs"
$certFile = Join-Path $certDir "device.pem.crt"
$keyFile = Join-Path $certDir "private.pem.key"
$caFile = Join-Path $certDir "AmazonRootCA1.pem"

if (!(Test-Path $certFile) -or !(Test-Path $keyFile) -or !(Test-Path $caFile)) {
    Write-Warning "AWS IoT Certificates not found in $certDir."
    Write-Warning "Make sure you run infra/deploy-aws.ps1 or place device.pem.crt, private.pem.key, and AmazonRootCA1.pem in certs/."
}

# If IotEndpoint is not specified, try reading from environment or AWS CLI
if ([string]::IsNullOrWhiteSpace($IotEndpoint)) {
    try {
        $IotEndpoint = aws iot describe-endpoint --endpoint-type iot:Data-ATS --query endpointAddress --output text 2>$null
    } catch {}
}

if ([string]::IsNullOrWhiteSpace($IotEndpoint)) {
    $IotEndpoint = "YOUR_AWS_IOT_ENDPOINT.iot.ap-south-1.amazonaws.com"
    Write-Warning "Using placeholder IoT endpoint: $IotEndpoint. Update /etc/deadman/env on the Pi when ready."
}

Write-Host "IoT Endpoint: $IotEndpoint" -ForegroundColor Green

# 1. Setup temporary staging directory on the Pi
Write-Host "`nStep 1: Staging files to Pi..." -ForegroundColor Yellow
$tempStaging = "/tmp/deadman_staging"

# SSH connection options
$sshOpts = @("-o", "StrictHostKeyChecking=no")
if (Test-Path $SshKeyPath) {
    $sshOpts += @("-i", $SshKeyPath)
}

# Copy files to staging
$scpCmd = "scp"
if (Test-Path $SshKeyPath) {
    & scp -i $SshKeyPath -o StrictHostKeyChecking=no "$PSScriptRoot\heartbeat.py" "$PSScriptRoot\deadman-heartbeat.service" "$PiUser@${PiHost}:/tmp/"
    if (Test-Path $certFile) {
        & scp -i $SshKeyPath -o StrictHostKeyChecking=no "$certFile" "$keyFile" "$caFile" "$PiUser@${PiHost}:/tmp/"
    }
} else {
    & scp -o StrictHostKeyChecking=no "$PSScriptRoot\heartbeat.py" "$PSScriptRoot\deadman-heartbeat.service" "$PiUser@${PiHost}:/tmp/"
    if (Test-Path $certFile) {
        & scp -o StrictHostKeyChecking=no "$certFile" "$keyFile" "$caFile" "$PiUser@${PiHost}:/tmp/"
    }
}

# 2. Remote execution commands
Write-Host "`nStep 2: Configuring system, user, and virtualenv on the Pi..." -ForegroundColor Yellow

$remoteScript = @"
set -e
echo '[1/6] Creating deadman system user and directories...'
sudo id -u deadman &>/dev/null || sudo useradd --system --home /opt/deadman --shell /usr/sbin/nologin deadman
sudo mkdir -p /opt/deadman /etc/deadman

echo '[2/6] Setting up Python virtual environment...'
sudo apt-get update -qq && sudo apt-get install -y -qq python3-venv python3-pip
if [ ! -d "/opt/deadman/venv" ]; then
    sudo python3 -m venv /opt/deadman/venv
fi
sudo /opt/deadman/venv/bin/pip install --upgrade pip -q
sudo /opt/deadman/venv/bin/pip install awsiotsdk -q

echo '[3/6] Deploying scripts and permissions...'
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
sudo tee /etc/deadman/env >/dev/null <<EOF
IOT_ENDPOINT=$IotEndpoint
THING=$ThingName
INTERVAL_S=$IntervalSec
CONFIG_DIR=/etc/deadman/
TOPIC=deadman/heartbeat
EOF
sudo chmod 640 /etc/deadman/env

echo '[5/6] Configuring systemd service...'
sudo mv /tmp/deadman-heartbeat.service /etc/systemd/system/deadman-heartbeat.service
sudo systemctl daemon-reload
sudo systemctl enable deadman-heartbeat
sudo systemctl restart deadman-heartbeat

echo '[6/6] Service status check...'
sudo systemctl status deadman-heartbeat --no-pager || true
"@

# Execute remote commands
if (Test-Path $SshKeyPath) {
    & ssh -i $SshKeyPath -o StrictHostKeyChecking=no "$PiUser@$PiHost" $remoteScript
} else {
    & ssh -o StrictHostKeyChecking=no "$PiUser@$PiHost" $remoteScript
}

Write-Host "`nRaspberry Pi deployment finished!" -ForegroundColor Green
Write-Host "To monitor live logs on the Pi, run:"
Write-Host "  ssh $PiUser@$PiHost 'journalctl -u deadman-heartbeat -f'" -ForegroundColor Cyan
