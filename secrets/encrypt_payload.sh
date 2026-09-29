#!/usr/bin/env bash
# Encrypts a directory of secret files using age and splits the passphrase with Shamir's Secret Sharing (ssss).
# Run this on a trusted, offline machine.

set -e

SOURCE_DIR="${1:-./files-to-release}"
OUTPUT_ARCHIVE="payload.tar.gz"
OUTPUT_CIPHERTEXT="payload.age"
THRESHOLD="${2:-2}"
SHARES="${3:-3}"

if [ ! -d "$SOURCE_DIR" ]; then
    echo "Error: Directory '$SOURCE_DIR' does not exist."
    echo "Usage: ./encrypt_payload.sh <folder_path> [threshold] [shares]"
    exit 1
fi

command -v age >/dev/null 2>&1 || { echo "Error: 'age' is not installed (sudo apt install age)."; exit 1; }
command -v ssss-split >/dev/null 2>&1 || { echo "Error: 'ssss' is not installed (sudo apt install ssss)."; exit 1; }

echo "Step 1: Creating tarball of secret files..."
tar czf "$OUTPUT_ARCHIVE" -C "$SOURCE_DIR" .

echo "Step 2: Generating secure 128-bit passphrase..."
PASSPHRASE=$(openssl rand -hex 16)

echo "Step 3: Encrypting with age..."
echo "$PASSPHRASE" | age -p -o "$OUTPUT_CIPHERTEXT" "$OUTPUT_ARCHIVE"
rm -f "$OUTPUT_ARCHIVE"

echo "Step 4: Splitting passphrase into $SHARES shares (Threshold: $THRESHOLD needed)..."
echo "--------------------------------------------------------"
echo "$PASSPHRASE" | ssss-split -t "$THRESHOLD" -n "$SHARES" -x -q
echo "--------------------------------------------------------"

# Clear sensitive variable
unset PASSPHRASE

echo "SUCCESS: $OUTPUT_CIPHERTEXT created."
echo "Distribute one share to each recipient over separate communication channels."
echo "Upload to S3 with: aws s3 cp $OUTPUT_CIPHERTEXT s3://<YOUR_BUCKET>/$OUTPUT_CIPHERTEXT"
