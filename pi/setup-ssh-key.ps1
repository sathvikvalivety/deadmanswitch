<#
.SYNOPSIS
    Copies the generated SSH public key to Raspberry Pi authorized_keys for passwordless access.
#>

param(
    [string]$PiHost = "192.168.137.62",
    [string]$PiUser = "pi",
    [string]$PublicKeyPath = "$PSScriptRoot\..\certs\id_ed25519_pi.pub"
)

if (!(Test-Path $PublicKeyPath)) {
    Write-Error "Public key not found at $PublicKeyPath. Run ssh-keygen first."
    exit 1
}

$pubKey = (Get-Content $PublicKeyPath -Raw).Trim()
Write-Host "Authorizing SSH key on $PiUser@$PiHost..." -ForegroundColor Yellow
Write-Host "(Enter Pi password when prompted, e.g. 'pi')"

$cmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$pubKey' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

& ssh -o StrictHostKeyChecking=no "$PiUser@$PiHost" $cmd

if ($LASTEXITCODE -eq 0) {
    Write-Host "SSH public key successfully installed!" -ForegroundColor Green
    Write-Host "You can now connect without password using: ssh -i $PSScriptRoot\..\certs\id_ed25519_pi $PiUser@$PiHost"
} else {
    Write-Warning "SSH command failed. Check IP address and password."
}
