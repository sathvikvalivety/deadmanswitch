#!/usr/bin/env bash
# Reconstructs the passphrase using Shamir's Secret Sharing (ssss-combine) and decrypts the age payload.

set -e

CIPHERTEXT="${1:-payload.age}"
OUTPUT_ARCHIVE="decrypted_payload.tar.gz"
OUTPUT_DIR="./recovered_files"

if [ ! -f "$CIPHERTEXT" ]; then
    echo "Error: Ciphertext file '$CIPHERTEXT' not found."
    echo "Usage: ./recover_payload.sh <path_to_payload.age>"
    exit 1
fi

command -v age >/dev/null 2>&1 || { echo "Error: 'age' is not installed."; exit 1; }
command -v ssss-combine >/dev/null 2>&1 || { echo "Error: 'ssss-combine' is not installed."; exit 1; }

echo "Enter your Shamir shares (Threshold number of shares required, one per prompt, press Enter):"
COMBINED_KEY=$(ssss-combine -t 2 -x -q)

echo "Decrypting $CIPHERTEXT..."
echo "$COMBINED_KEY" | age -d -o "$OUTPUT_ARCHIVE" "$CIPHERTEXT"

mkdir -p "$OUTPUT_DIR"
tar xzf "$OUTPUT_ARCHIVE" -C "$OUTPUT_DIR"
rm -f "$OUTPUT_ARCHIVE"
unset COMBINED_KEY

echo "Files successfully decrypted and unpacked to $OUTPUT_DIR!"
