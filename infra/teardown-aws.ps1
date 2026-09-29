<#
.SYNOPSIS
    Tears down and deletes Dead Man's Switch AWS resources.
#>

param(
    [string]$AwsRegion = "ap-south-1",
    [string]$TableName = "deadman-state",
    [string]$ThingName = "deadman-pi"
)

Write-Host "Teardown initiated for AWS Region: $AwsRegion..." -ForegroundColor Yellow

# 1. EventBridge
aws events remove-targets --rule deadman-monitor-schedule --ids 1 2>$null | Out-Null
aws events delete-rule --name deadman-monitor-schedule 2>$null | Out-Null

# 2. Lambdas
aws lambda delete-function --function-name deadman-checkin 2>$null | Out-Null
aws lambda delete-function --function-name deadman-monitor 2>$null | Out-Null

# 3. IoT Topic Rule, Policy, Principal & Thing
aws iot delete-topic-rule --rule-name DeadmanHeartbeat 2>$null | Out-Null
$principals = aws iot list-thing-principals --thing-name $ThingName 2>$null | ConvertFrom-Json
if ($principals.principals) {
    foreach ($p in $principals.principals) {
        aws iot detach-thing-principal --thing-name $ThingName --principal $p 2>$null | Out-Null
        aws iot detach-policy --policy-name deadman-pi-policy --target $p 2>$null | Out-Null
        $certId = $p.Split("/")[-1]
        aws iot update-certificate --certificate-id $certId --new-status INACTIVE 2>$null | Out-Null
        aws iot delete-certificate --certificate-id $certId 2>$null | Out-Null
    }
}
aws iot delete-policy --policy-name deadman-pi-policy 2>$null | Out-Null
aws iot delete-thing --thing-name $ThingName 2>$null | Out-Null

# 4. DynamoDB
aws dynamodb delete-table --table-name $TableName 2>$null | Out-Null

# 5. SSM
aws ssm delete-parameter --name /deadman/checkin_token 2>$null | Out-Null

# 6. Alarms & SNS
aws cloudwatch delete-alarms --alarm-names deadman-monitor-errors deadman-monitor-silent 2>$null | Out-Null
$snsArn = aws sns create-topic --name deadman-alerts --query TopicArn --output text 2>$null
if ($snsArn) { aws sns delete-topic --topic-arn $snsArn 2>$null | Out-Null }

# 7. IAM Roles
aws iam delete-role-policy --role-name deadman-checkin --policy-name checkin-access 2>$null | Out-Null
aws iam detach-role-policy --role-name deadman-checkin --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>$null | Out-Null
aws iam delete-role --role-name deadman-checkin 2>$null | Out-Null

aws iam delete-role-policy --role-name deadman-monitor --policy-name monitor-access 2>$null | Out-Null
aws iam detach-role-policy --role-name deadman-monitor --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>$null | Out-Null
aws iam delete-role --role-name deadman-monitor 2>$null | Out-Null

aws iam delete-role-policy --role-name deadman-iot-rule --policy-name put-heartbeat 2>$null | Out-Null
aws iam delete-role --role-name deadman-iot-rule 2>$null | Out-Null

Write-Host "Teardown complete!" -ForegroundColor Green
