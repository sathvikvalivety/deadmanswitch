<#
.SYNOPSIS
    Automated AWS Infrastructure Provisioning Script for Dead Man's Switch.
.DESCRIPTION
    Provisions DynamoDB, SSM Parameter, IAM Roles, Lambdas, Function URL,
    EventBridge Schedule, IoT Core Thing/Certs/Rule, CloudWatch Alarms & SNS.
#>

param(
    [string]$AwsRegion = "ap-south-1",
    [string]$TableName = "deadman-state",
    [string]$ThingName = "deadman-pi",
    [string]$AlarmEmail = "",
    [switch]$DryRunMode = $true
)

$ErrorActionPreference = "Stop"

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "  Dead Man's Switch: AWS Infrastructure Deploy   " -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan

# Set environment
$env:AWS_REGION = $AwsRegion
$env:AWS_DEFAULT_REGION = $AwsRegion

# 1. Verify AWS CLI Credentials
Write-Host "`n[1/10] Verifying AWS Credentials..." -ForegroundColor Yellow
try {
    $callerIdentity = aws sts get-caller-identity --output json 2>$null | ConvertFrom-Json
    $accountId = $callerIdentity.Account
    $callerArn = $callerIdentity.Arn
    Write-Host "Authenticated as: $callerArn" -ForegroundColor Green
    Write-Host "Account ID: $accountId | Region: $AwsRegion" -ForegroundColor Green
} catch {
    Write-Error "Failed to authenticate with AWS CLI. Ensure 'aws configure' has been run or AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY are set."
    exit 1
}

$certDir = Join-Path $PSScriptRoot "..\certs"
if (!(Test-Path $certDir)) {
    New-Item -ItemType Directory -Path $certDir | Out-Null
}

# 2. DynamoDB Table
Write-Host "`n[2/10] Creating DynamoDB Table ($TableName)..." -ForegroundColor Yellow
$tableExists = aws dynamodb describe-table --table-name $TableName 2>$null
if (-not $tableExists) {
    aws dynamodb create-table `
        --table-name $TableName `
        --attribute-definitions AttributeName=pk,AttributeType=S `
        --key-schema AttributeName=pk,KeyType=HASH `
        --billing-mode PAY_PER_REQUEST | Out-Null
    
    Write-Host "Waiting for table creation..."
    aws dynamodb wait table-exists --table-name $TableName
    
    aws dynamodb update-continuous-backups `
        --table-name $TableName `
        --point-in-time-recovery-specification PointInTimeRecoveryEnabled=true | Out-Null
    Write-Host "Table created with Point-in-Time Recovery enabled." -ForegroundColor Green
} else {
    Write-Host "DynamoDB table '$TableName' already exists." -ForegroundColor Green
}

# 3. SSM Check-in Secret Token
Write-Host "`n[3/10] Setting up Check-in Token in AWS SSM Parameter Store..." -ForegroundColor Yellow
$tokenParamName = "/deadman/checkin_token"
$tokenExists = aws ssm get-parameter --name $tokenParamName 2>$null
if (-not $tokenExists) {
    $randomBytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($randomBytes)
    $token = [System.Convert]::ToBase64String($randomBytes).Replace("+", "-").Replace("/", "_").TrimEnd("=")
    
    aws ssm put-parameter `
        --name $tokenParamName `
        --type SecureString `
        --value "$token" `
        --overwrite | Out-Null
    Write-Host "Generated new check-in token in SSM: /deadman/checkin_token" -ForegroundColor Green
} else {
    $token = (aws ssm get-parameter --name $tokenParamName --with-decryption --query "Parameter.Value" --output text).Trim()
    Write-Host "SSM check-in token already exists." -ForegroundColor Green
}

# 4. IAM Roles
Write-Host "`n[4/10] Creating IAM Roles..." -ForegroundColor Yellow
$trustDoc = Join-Path $PSScriptRoot "policies\lambda-trust.json"
$iotTrustDoc = Join-Path $PSScriptRoot "policies\iot-trust.json"

# Lambda Basic Execution ARN
$basicRoleArn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"

# Check-in Role
$checkinRoleName = "deadman-checkin"
aws iam create-role --role-name $checkinRoleName --assume-role-policy-document "file://$trustDoc" 2>$null | Out-Null
aws iam attach-role-policy --role-name $checkinRoleName --policy-arn $basicRoleArn 2>$null | Out-Null
$checkinPolicyDoc = @"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "dynamodb:UpdateItem",
      "Resource": "arn:aws:dynamodb:${AwsRegion}:${accountId}:table/${TableName}"
    },
    {
      "Effect": "Allow",
      "Action": "ssm:GetParameter",
      "Resource": "arn:aws:ssm:${AwsRegion}:${accountId}:parameter/deadman/checkin_token"
    }
  ]
}
"@
aws iam put-role-policy --role-name $checkinRoleName --policy-name checkin-access --policy-document $checkinPolicyDoc | Out-Null

# Monitor Role
$monitorRoleName = "deadman-monitor"
aws iam create-role --role-name $monitorRoleName --assume-role-policy-document "file://$trustDoc" 2>$null | Out-Null
aws iam attach-role-policy --role-name $monitorRoleName --policy-arn $basicRoleArn 2>$null | Out-Null
$monitorPolicyDoc = @"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem",
        "dynamodb:UpdateItem"
      ],
      "Resource": "arn:aws:dynamodb:${AwsRegion}:${accountId}:table/${TableName}"
    },
    {
      "Effect": "Allow",
      "Action": "ssm:GetParameter",
      "Resource": "arn:aws:ssm:${AwsRegion}:${accountId}:parameter/deadman/checkin_token"
    },
    {
      "Effect": "Allow",
      "Action": "ses:SendEmail",
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::deadman-payload-*"
    }
  ]
}
"@
aws iam put-role-policy --role-name $monitorRoleName --policy-name monitor-access --policy-document $monitorPolicyDoc | Out-Null

# IoT Rule Role
$iotRoleName = "deadman-iot-rule"
aws iam create-role --role-name $iotRoleName --assume-role-policy-document "file://$iotTrustDoc" 2>$null | Out-Null
$iotRulePolicyDoc = @"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "dynamodb:PutItem",
      "Resource": "arn:aws:dynamodb:${AwsRegion}:${accountId}:table/${TableName}"
    }
  ]
}
"@
aws iam put-role-policy --role-name $iotRoleName --policy-name put-heartbeat --policy-document $iotRulePolicyDoc | Out-Null

Write-Host "IAM Roles created and policies attached." -ForegroundColor Green
Start-Sleep -Seconds 5

# 5. Package & Deploy Check-in Lambda
Write-Host "`n[5/10] Deploying deadman-checkin Lambda and Function URL..." -ForegroundColor Yellow
$lambdaDir = Join-Path $PSScriptRoot "..\lambda"
$checkinZip = Join-Path $lambdaDir "checkin.zip"
$monitorZip = Join-Path $lambdaDir "monitor.zip"

Compress-Archive -Path (Join-Path $lambdaDir "checkin.py") -DestinationPath $checkinZip -Force
Compress-Archive -Path (Join-Path $lambdaDir "monitor.py") -DestinationPath $monitorZip -Force

$checkinExists = aws lambda get-function --function-name deadman-checkin 2>$null
if (-not $checkinExists) {
    aws lambda create-function `
        --function-name deadman-checkin `
        --runtime python3.12 `
        --handler checkin.handler `
        --zip-file "fileb://$checkinZip" `
        --timeout 10 `
        --memory-size 128 `
        --role "arn:aws:iam::${accountId}:role/$checkinRoleName" `
        --environment "Variables={TABLE=$TableName,TOKEN_PARAM=$tokenParamName}" | Out-Null
} else {
    aws lambda update-function-code --function-name deadman-checkin --zip-file "fileb://$checkinZip" | Out-Null
    aws lambda update-function-configuration --function-name deadman-checkin `
        --environment "Variables={TABLE=$TableName,TOKEN_PARAM=$tokenParamName}" | Out-Null
}

# Function URL
aws lambda create-function-url-config --function-name deadman-checkin --auth-type NONE 2>$null | Out-Null
aws lambda add-permission --function-name deadman-checkin --statement-id url-public `
    --action lambda:InvokeFunctionUrl --principal "*" --function-url-auth-type NONE 2>$null | Out-Null
aws lambda add-permission --function-name deadman-checkin --statement-id url-invoke `
    --action lambda:InvokeFunction --principal "*" --invoked-via-function-url 2>$null | Out-Null

$checkinUrl = (aws lambda get-function-url-config --function-name deadman-checkin --query FunctionUrl --output text).Trim()
Write-Host "Check-in Function URL: $checkinUrl" -ForegroundColor Green

# 6. Deploy Monitor Lambda
Write-Host "`n[6/10] Deploying deadman-monitor Lambda..." -ForegroundColor Yellow
$dryRunVal = if ($DryRunMode) { "true" } else { "false" }
$monitorExists = aws lambda get-function --function-name deadman-monitor 2>$null

if (-not $monitorExists) {
    aws lambda create-function `
        --function-name deadman-monitor `
        --runtime python3.12 `
        --handler monitor.handler `
        --zip-file "fileb://$monitorZip" `
        --timeout 60 `
        --memory-size 256 `
        --role "arn:aws:iam::${accountId}:role/$monitorRoleName" `
        --environment "Variables={TABLE=$TableName,TOKEN_PARAM=$tokenParamName,CHECKIN_URL=$checkinUrl,DRY_RUN=$dryRunVal}" | Out-Null
} else {
    aws lambda update-function-code --function-name deadman-monitor --zip-file "fileb://$monitorZip" | Out-Null
    aws lambda update-function-configuration --function-name deadman-monitor `
        --environment "Variables={TABLE=$TableName,TOKEN_PARAM=$tokenParamName,CHECKIN_URL=$checkinUrl,DRY_RUN=$dryRunVal}" | Out-Null
}
Write-Host "Monitor Lambda deployed (DRY_RUN=$dryRunVal)." -ForegroundColor Green

# 7. EventBridge 15-minute schedule
Write-Host "`n[7/10] Configuring EventBridge 15-Minute Scheduler..." -ForegroundColor Yellow
$ruleName = "deadman-monitor-schedule"
aws events put-rule --name $ruleName --schedule-expression "rate(15 minutes)" | Out-Null
aws lambda add-permission --function-name deadman-monitor --statement-id events `
    --action lambda:InvokeFunction --principal events.amazonaws.com `
    --source-arn "arn:aws:events:${AwsRegion}:${accountId}:rule/$ruleName" 2>$null | Out-Null
aws events put-targets --rule $ruleName `
    --targets "Id=1,Arn=arn:aws:lambda:${AwsRegion}:${accountId}:function:deadman-monitor" | Out-Null
Write-Host "EventBridge cron rule active." -ForegroundColor Green

# 8. AWS IoT Core (Thing, Cert, Policy, Rule)
Write-Host "`n[8/10] Provisioning AWS IoT Core Thing, Certificates, and Rules..." -ForegroundColor Yellow
aws iot create-thing --thing-name $ThingName 2>$null | Out-Null

$certFile = Join-Path $certDir "device.pem.crt"
$pubKeyFile = Join-Path $certDir "public.pem.key"
$priKeyFile = Join-Path $certDir "private.pem.key"
$caFile = Join-Path $certDir "AmazonRootCA1.pem"

if (!(Test-Path $certFile) -or !(Test-Path $priKeyFile)) {
    Write-Host "Generating IoT X.509 device keys and certificates..."
    $certArn = (aws iot create-keys-and-certificate `
        --set-as-active `
        --certificate-pem-outfile $certFile `
        --public-key-outfile $pubKeyFile `
        --private-key-outfile $priKeyFile `
        --query certificateArn --output text).Trim()
    
    $iotPolicyDoc = (Get-Content (Join-Path $PSScriptRoot "policies\iot-policy.json") -Raw)
    $iotPolicyDoc = $iotPolicyDoc.Replace('${AWS_REGION}', $AwsRegion).Replace('${ACCOUNT_ID}', $accountId).Replace('${THING}', $ThingName)
    
    $tempPolicyFile = [System.IO.Path]::GetTempFileName()
    Set-Content -Path $tempPolicyFile -Value $iotPolicyDoc
    
    aws iot create-policy --policy-name deadman-pi-policy --policy-document "file://$tempPolicyFile" 2>$null | Out-Null
    Remove-Item $tempPolicyFile -Force
    
    aws iot attach-policy --policy-name deadman-pi-policy --target $certArn | Out-Null
    aws iot attach-thing-principal --thing-name $ThingName --principal $certArn | Out-Null
    Write-Host "IoT Certificates created and attached to Thing '$ThingName'." -ForegroundColor Green
} else {
    Write-Host "IoT Certificates already exist in certs/ directory." -ForegroundColor Green
}

# Download Amazon Root CA if missing
if (!(Test-Path $caFile)) {
    Invoke-WebRequest -Uri "https://www.amazontrust.com/repository/AmazonRootCA1.pem" -OutFile $caFile
}

# IoT Endpoint
$iotEndpoint = (aws iot describe-endpoint --endpoint-type iot:Data-ATS --query endpointAddress --output text).Trim()
Write-Host "IoT ATS Endpoint: $iotEndpoint" -ForegroundColor Green

# IoT Topic Rule
$iotRulePayload = @"
{
  "sql": "SELECT 'PI_HEARTBEAT' AS pk, timestamp() AS last_seen_ms, uptime_s, cpu_temp_c, throttled, disk_used_pct, boot_id FROM 'deadman/heartbeat'",
  "awsIotSqlVersion": "2016-03-23",
  "ruleDisabled": false,
  "actions": [
    {
      "dynamoDBv2": {
        "roleArn": "arn:aws:iam::${accountId}:role/$iotRoleName",
        "putItem": {
          "tableName": "$TableName"
        }
      }
    }
  ]
}
"@
$tempRuleFile = [System.IO.Path]::GetTempFileName()
Set-Content -Path $tempRuleFile -Value $iotRulePayload
Start-Sleep -Seconds 5
aws iot create-topic-rule --rule-name DeadmanHeartbeat --topic-rule-payload "file://$tempRuleFile" 2>$null | Out-Null
Remove-Item $tempRuleFile -Force
Write-Host "IoT Topic Rule 'DeadmanHeartbeat' configured." -ForegroundColor Green

# 9. CloudWatch Alarms & SNS (Optional Email)
Write-Host "`n[9/10] Setting up CloudWatch Alarms & Watcher Alarms..." -ForegroundColor Yellow
$snsTopicArn = (aws sns create-topic --name deadman-alerts --query TopicArn --output text).Trim()
if (-not [string]::IsNullOrWhiteSpace($AlarmEmail)) {
    aws sns subscribe --topic-arn $snsTopicArn --protocol email --notification-endpoint $AlarmEmail | Out-Null
    Write-Host "Subscribed $AlarmEmail to $snsTopicArn (Confirm the verification email!)." -ForegroundColor Green
}

# Error Alarm
aws cloudwatch put-metric-alarm `
    --alarm-name deadman-monitor-errors `
    --namespace AWS/Lambda `
    --metric-name Errors `
    --dimensions Name=FunctionName,Value=deadman-monitor `
    --statistic Sum `
    --period 900 `
    --evaluation-periods 1 `
    --threshold 1 `
    --comparison-operator GreaterThanOrEqualToThreshold `
    --treat-missing-data notBreaching `
    --alarm-actions $snsTopicArn | Out-Null

# Silent Failure Alarm (No invocations in 45 mins)
aws cloudwatch put-metric-alarm `
    --alarm-name deadman-monitor-silent `
    --namespace AWS/Lambda `
    --metric-name Invocations `
    --dimensions Name=FunctionName,Value=deadman-monitor `
    --statistic Sum `
    --period 3600 `
    --evaluation-periods 3 `
    --threshold 1 `
    --comparison-operator LessThanThreshold `
    --treat-missing-data breaching `
    --alarm-actions $snsTopicArn | Out-Null

Write-Host "CloudWatch Alarms active." -ForegroundColor Green

# 10. Seed Configuration
Write-Host "`n[10/10] Seeding initial DynamoDB configuration..." -ForegroundColor Yellow
$configPath = Join-Path $PSScriptRoot "..\config.json"
if (Test-Path $configPath) {
    & python "$PSScriptRoot\..\ctl.py" seed "$configPath"
}

# Summary
Write-Host "`n=================================================" -ForegroundColor Cyan
Write-Host "       DEPLOYMENT SUCCESSFUL! SUMMARY           " -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "Check-in Web URL:" -ForegroundColor Yellow
Write-Host "  $checkinUrl?t=$token" -ForegroundColor White
Write-Host "`nSave this URL on your phone bookmark!" -ForegroundColor Green
Write-Host "`nIoT Endpoint for Pi:" -ForegroundColor Yellow
Write-Host "  $iotEndpoint" -ForegroundColor White
Write-Host "`nNext Step: Run the Pi deployment script:" -ForegroundColor Yellow
Write-Host "  powershell -File .\pi\deploy-pi.ps1 -IotEndpoint $iotEndpoint" -ForegroundColor Cyan
