#!/usr/bin/env bash
set -e

AWS_REGION="${AWS_REGION:-ap-south-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
TABLE_NAME="deadman-state"
THING_NAME="deadman-pi"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="$SCRIPT_DIR/../certs"
mkdir -p "$CERT_DIR"

echo "================================================="
echo "  Dead Man's Switch: AWS Infrastructure Deploy   "
echo "================================================="

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account ID: $ACCOUNT_ID | Region: $AWS_REGION"

# DynamoDB
echo "[1/8] Setting up DynamoDB..."
if ! aws dynamodb describe-table --table-name "$TABLE_NAME" >/dev/null 2>&1; then
    aws dynamodb create-table \
      --table-name "$TABLE_NAME" \
      --attribute-definitions AttributeName=pk,AttributeType=S \
      --key-schema AttributeName=pk,KeyType=HASH \
      --billing-mode PAY_PER_REQUEST
    aws dynamodb wait table-exists --table-name "$TABLE_NAME"
    aws dynamodb update-continuous-backups \
      --table-name "$TABLE_NAME" \
      --point-in-time-recovery-specification PointInTimeRecoveryEnabled=true
fi

# SSM Token
echo "[2/8] Setting up SSM Token..."
if ! aws ssm get-parameter --name /deadman/checkin_token >/dev/null 2>&1; then
    TOKEN=$(python3 -c "import secrets;print(secrets.token_urlsafe(32))")
    aws ssm put-parameter --name /deadman/checkin_token --type SecureString --value "$TOKEN"
fi
TOKEN=$(aws ssm get-parameter --name /deadman/checkin_token --with-decryption --query "Parameter.Value" --output text)

# Roles
echo "[3/8] Setting up IAM Roles..."
aws iam create-role --role-name deadman-checkin --assume-role-policy-document file://"$SCRIPT_DIR/policies/lambda-trust.json" 2>/dev/null || true
aws iam attach-role-policy --role-name deadman-checkin --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true
aws iam put-role-policy --role-name deadman-checkin --policy-name checkin-access --policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [
    {\"Effect\": \"Allow\", \"Action\": \"dynamodb:UpdateItem\", \"Resource\": \"arn:aws:dynamodb:$AWS_REGION:$ACCOUNT_ID:table/$TABLE_NAME\"},
    {\"Effect\": \"Allow\", \"Action\": \"ssm:GetParameter\", \"Resource\": \"arn:aws:ssm:$AWS_REGION:$ACCOUNT_ID:parameter/deadman/checkin_token\"}
  ]
}"

aws iam create-role --role-name deadman-monitor --assume-role-policy-document file://"$SCRIPT_DIR/policies/lambda-trust.json" 2>/dev/null || true
aws iam attach-role-policy --role-name deadman-monitor --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true
aws iam put-role-policy --role-name deadman-monitor --policy-name monitor-access --policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [
    {\"Effect\": \"Allow\", \"Action\": [\"dynamodb:GetItem\", \"dynamodb:UpdateItem\"], \"Resource\": \"arn:aws:dynamodb:$AWS_REGION:$ACCOUNT_ID:table/$TABLE_NAME\"},
    {\"Effect\": \"Allow\", \"Action\": \"ssm:GetParameter\", \"Resource\": \"arn:aws:ssm:$AWS_REGION:$ACCOUNT_ID:parameter/deadman/checkin_token\"},
    {\"Effect\": \"Allow\", \"Action\": \"ses:SendEmail\", \"Resource\": \"*\"},
    {\"Effect\": \"Allow\", \"Action\": \"s3:GetObject\", \"Resource\": \"arn:aws:s3:::deadman-payload-*\"}
  ]
}"

aws iam create-role --role-name deadman-iot-rule --assume-role-policy-document file://"$SCRIPT_DIR/policies/iot-trust.json" 2>/dev/null || true
aws iam put-role-policy --role-name deadman-iot-rule --policy-name put-heartbeat --policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [
    {\"Effect\": \"Allow\", \"Action\": \"dynamodb:PutItem\", \"Resource\": \"arn:aws:dynamodb:$AWS_REGION:$ACCOUNT_ID:table/$TABLE_NAME\"}
  ]
}"

# Lambdas
echo "[4/8] Packaging and deploying Lambdas..."
cd "$SCRIPT_DIR/../lambda"
zip -q -r checkin.zip checkin.py
zip -q -r monitor.zip monitor.py

if ! aws lambda get-function --function-name deadman-checkin >/dev/null 2>&1; then
    aws lambda create-function \
      --function-name deadman-checkin \
      --runtime python3.12 \
      --handler checkin.handler \
      --zip-file fileb://checkin.zip \
      --timeout 10 \
      --memory-size 128 \
      --role "arn:aws:iam::$ACCOUNT_ID:role/deadman-checkin" \
      --environment "Variables={TABLE=$TABLE_NAME,TOKEN_PARAM=/deadman/checkin_token}"
else
    aws lambda update-function-code --function-name deadman-checkin --zip-file fileb://checkin.zip
fi

aws lambda create-function-url-config --function-name deadman-checkin --auth-type NONE 2>/dev/null || true
aws lambda add-permission --function-name deadman-checkin --statement-id url-public --action lambda:InvokeFunctionUrl --principal "*" --function-url-auth-type NONE 2>/dev/null || true
aws lambda add-permission --function-name deadman-checkin --statement-id url-invoke --action lambda:InvokeFunction --principal "*" --invoked-via-function-url 2>/dev/null || true

CHECKIN_URL=$(aws lambda get-function-url-config --function-name deadman-checkin --query FunctionUrl --output text)

if ! aws lambda get-function --function-name deadman-monitor >/dev/null 2>&1; then
    aws lambda create-function \
      --function-name deadman-monitor \
      --runtime python3.12 \
      --handler monitor.handler \
      --zip-file fileb://monitor.zip \
      --timeout 60 \
      --memory-size 256 \
      --role "arn:aws:iam::$ACCOUNT_ID:role/deadman-monitor" \
      --environment "Variables={TABLE=$TABLE_NAME,TOKEN_PARAM=/deadman/checkin_token,CHECKIN_URL=$CHECKIN_URL,DRY_RUN=true}"
else
    aws lambda update-function-code --function-name deadman-monitor --zip-file fileb://monitor.zip
    aws lambda update-function-configuration --function-name deadman-monitor --environment "Variables={TABLE=$TABLE_NAME,TOKEN_PARAM=/deadman/checkin_token,CHECKIN_URL=$CHECKIN_URL,DRY_RUN=true}"
fi

# EventBridge Schedule
echo "[5/8] Configuring EventBridge Schedule..."
aws events put-rule --name deadman-monitor-schedule --schedule-expression "rate(15 minutes)"
aws lambda add-permission --function-name deadman-monitor --statement-id events --action lambda:InvokeFunction --principal events.amazonaws.com --source-arn "arn:aws:events:$AWS_REGION:$ACCOUNT_ID:rule/deadman-monitor-schedule" 2>/dev/null || true
aws events put-targets --rule deadman-monitor-schedule --targets "Id=1,Arn=arn:aws:lambda:$AWS_REGION:$ACCOUNT_ID:function:deadman-monitor"

# IoT Core
echo "[6/8] Configuring AWS IoT Core..."
aws iot create-thing --thing-name "$THING_NAME" 2>/dev/null || true

if [ ! -f "$CERT_DIR/device.pem.crt" ]; then
    CERT_ARN=$(aws iot create-keys-and-certificate \
      --set-as-active \
      --certificate-pem-outfile "$CERT_DIR/device.pem.crt" \
      --public-key-outfile "$CERT_DIR/public.pem.key" \
      --private-key-outfile "$CERT_DIR/private.pem.key" \
      --query certificateArn --output text)

    sed -e "s/\${AWS_REGION}/$AWS_REGION/g" -e "s/\${ACCOUNT_ID}/$ACCOUNT_ID/g" -e "s/\${THING}/$THING_NAME/g" "$SCRIPT_DIR/policies/iot-policy.json" > /tmp/iot-policy.json
    aws iot create-policy --policy-name deadman-pi-policy --policy-document file:///tmp/iot-policy.json 2>/dev/null || true
    aws iot attach-policy --policy-name deadman-pi-policy --target "$CERT_ARN"
    aws iot attach-thing-principal --thing-name "$THING_NAME" --principal "$CERT_ARN"
fi

curl -s -o "$CERT_DIR/AmazonRootCA1.pem" https://www.amazontrust.com/repository/AmazonRootCA1.pem
IOT_ENDPOINT=$(aws iot describe-endpoint --endpoint-type iot:Data-ATS --query endpointAddress --output text)

cat > /tmp/iot-rule.json <<EOF
{
  "sql": "SELECT 'PI_HEARTBEAT' AS pk, timestamp() AS last_seen_ms, uptime_s, cpu_temp_c, throttled, disk_used_pct, boot_id FROM 'deadman/heartbeat'",
  "awsIotSqlVersion": "2016-03-23",
  "ruleDisabled": false,
  "actions": [{"dynamoDBv2": {"roleArn": "arn:aws:iam::$ACCOUNT_ID:role/deadman-iot-rule", "putItem": {"tableName": "$TABLE_NAME"}}}]
}
EOF
sleep 5
aws iot create-topic-rule --rule-name DeadmanHeartbeat --topic-rule-payload file:///tmp/iot-rule.json 2>/dev/null || true

# Alarms
echo "[7/8] Setting up Alarms..."
TOPIC=$(aws sns create-topic --name deadman-alerts --query TopicArn --output text)
aws cloudwatch put-metric-alarm --alarm-name deadman-monitor-errors --namespace AWS/Lambda --metric-name Errors --dimensions Name=FunctionName,Value=deadman-monitor --statistic Sum --period 900 --evaluation-periods 1 --threshold 1 --comparison-operator GreaterThanOrEqualToThreshold --treat-missing-data notBreaching --alarm-actions "$TOPIC"
aws cloudwatch put-metric-alarm --alarm-name deadman-monitor-silent --namespace AWS/Lambda --metric-name Invocations --dimensions Name=FunctionName,Value=deadman-monitor --statistic Sum --period 3600 --evaluation-periods 3 --threshold 1 --comparison-operator LessThanThreshold --treat-missing-data breaching --alarm-actions "$TOPIC"

# Seed
echo "[8/8] Seeding initial config..."
python3 "$SCRIPT_DIR/../ctl.py" seed "$SCRIPT_DIR/../config.json"

echo "================================================="
echo "Deployment Complete!"
echo "Check-in URL: ${CHECKIN_URL}?t=${TOKEN}"
echo "IoT Endpoint: $IOT_ENDPOINT"
echo "================================================="
