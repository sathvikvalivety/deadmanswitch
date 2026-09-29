# Dead Man's Switch (Raspberry Pi 4 + AWS)

A robust, resilient dead man's switch where human check-in is the primary trigger, and a Raspberry Pi 4 serves as a hardware health monitor.

---

## 1. Quick Start

### Directory Layout

```
deadmanswitch/
├── config.json                     # System configuration (timings, emails, recipients)
├── ctl.py                          # Management CLI (seed, status, checkin, rearm, pause)
├── certs/                          # Generated SSH keys and AWS IoT certificates
├── lambda/
│   ├── checkin.py                  # Web check-in Lambda (Function URL)
│   └── monitor.py                  # Scheduled state machine evaluator (EventBridge 15m)
├── pi/
│   ├── heartbeat.py                # Telemetry daemon (mTLS to AWS IoT Core)
│   ├── deadman-heartbeat.service   # Systemd unit file with hardware watchdog
│   ├── deploy-pi.ps1 / .sh         # Automated deploy to Pi (192.168.137.62)
│   └── setup-ssh-key.ps1           # Installs generated SSH key on Pi
├── infra/
│   ├── deploy-aws.ps1 / .sh        # Automated AWS infrastructure setup
│   ├── teardown-aws.ps1 / .sh      # Full AWS teardown
│   └── policies/                   # Least-privilege IAM and IoT policies
└── secrets/
    ├── encrypt_payload.sh          # Age encryption + Shamir's Secret Sharing
    └── recover_payload.sh          # Shamir's Secret recovery
```

---

## 2. Step-by-Step Deployment

### Step 1: AWS Deployment (Automated)

When your AWS CLI is configured with your desired credentials (`aws configure`):

**On Windows (PowerShell):**
```powershell
.\infra\deploy-aws.ps1 -AwsRegion ap-south-1 -AlarmEmail you@example.com
```

**On Linux / macOS / WSL (Bash):**
```bash
chmod +x infra/*.sh pi/*.sh secrets/*.sh
./infra/deploy-aws.sh
```

This provisions DynamoDB (`deadman-state`), SSM Parameter (`/deadman/checkin_token`), IAM roles, the Check-in and Monitor Lambdas, EventBridge cron, CloudWatch alarms, and AWS IoT Thing + X.509 certificates in `certs/`.

---

### Step 2: Email Verification (Amazon SES)

Since the system starts in **text-only** mode:

#### Option A: You Own a Custom Domain (Recommended)
1. In the AWS Console, go to **Amazon SES** $\rightarrow$ **Identities** $\rightarrow$ **Create Identity** $\rightarrow$ **Domain**.
2. Add the 3 DKIM `CNAME` records to your DNS registrar.
3. Set `from_email` in `config.json` to e.g. `deadman@yourdomain.com`.

#### Option B: Single Email Address (Gmail / Personal)
1. Run:
   ```bash
   aws sesv2 create-email-identity --email-identity your-email@gmail.com
   ```
2. Open the verification email sent by AWS and click the confirmation link.
3. In `config.json`, set `"from_email": "your-email@gmail.com"`.

> [!NOTE]
> **SES Sandbox Note**: While in SES Sandbox, all recipient addresses must also be verified in SES, or you can request production access in the SES Console (Account dashboard $\rightarrow$ Request production access: *"Personal safety notification system, ~10 emails/month"*).

---

### Step 3: Raspberry Pi Deployment (`192.168.137.62`)

1. **Install SSH Public Key on Pi (One-time):**
   ```powershell
   .\pi\setup-ssh-key.ps1 -PiHost "192.168.137.62" -PiUser "pi"
   ```
   *(Enter password `pi` when prompted)*

2. **Deploy Daemon & Service to Pi:**
   ```powershell
   .\pi\deploy-pi.ps1 -PiHost "192.168.137.62" -PiUser "pi"
   ```

3. **Check Live Service Logs on Pi:**
   ```bash
   ssh -i certs/id_ed25519_pi pi@192.168.137.62 "journalctl -u deadman-heartbeat -f"
   ```

---

### Step 4: Check Status & Testing

1. **Inspect status:**
   ```bash
   python ctl.py status
   ```
2. **Perform a web check-in:**
   Open the secret URL printed by `deploy-aws.ps1` (`https://<lambda-url>/?t=<TOKEN>`) and click **"I am OK"**.
3. **Simulate manual CLI check-in:**
   ```bash
   python ctl.py checkin
   ```
4. **Pause while traveling (e.g. 72 hours):**
   ```bash
   python ctl.py pause 72
   python ctl.py unpause
   ```

---

## 3. Adding Secret Encrypted Files (Phase 6 Bolt-On)

When ready to attach encrypted payloads:
1. Run `./secrets/encrypt_payload.sh ./my-confidential-files/ 2 3` on an offline machine.
2. Distribute the 3 Shamir shares to 3 distinct safety contacts.
3. Upload `payload.age` to S3:
   ```bash
   aws s3 cp payload.age s3://deadman-payload-<ACCOUNT_ID>-ap-south-1/payload.age
   ```
4. Add `"attachment_bucket"` and `"attachment_key": "payload.age"` to `config.json` and run `python ctl.py seed config.json`.
