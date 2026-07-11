#!/bin/bash
# IndieLicense end-to-end demo: keypair → mint 5 keys → verify → tamper → revoke.
# Runs entirely in a temp dir; safe to run repeatedly.
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release --product indielicense >/dev/null
CLI="$PWD/.build/release/indielicense"

DIR="$(mktemp -d /tmp/indielicense-demo.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
cd "$DIR"

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

step "1. init — create the keypair for 'pixelpro'"
"$CLI" init --product pixelpro --key-dir "$DIR"

step "2. generate — mint 5 keys (buy once, 365 days of updates)"
"$CLI" generate --count 5 --mode updates --updates-duration 365d --key-dir "$DIR" --out keys.csv
column -s, -t keys.csv | cut -c1-120

KEY=$(awk -F, 'NR==2 {print $2}' keys.csv)

step "3. verify — check key #1 like the app would"
"$CLI" verify "$KEY" --key-dir "$DIR"

step "4. inspect — decode without any key material"
"$CLI" inspect "$KEY"

step "5. tamper — flip one character and watch it fail"
# flip one character inside the signature region, avoiding a no-op replacement
POS=$(( ${#KEY} - 20 ))
while [ "${KEY:$POS:1}" = "-" ]; do POS=$((POS + 1)); done
CH="${KEY:$POS:1}"; [ "$CH" = "0" ] && NEW="2" || NEW="0"
TAMPERED="${KEY:0:$POS}${NEW}${KEY:$((POS + 1))}"
if "$CLI" verify "$TAMPERED" --key-dir "$DIR"; then
  echo "BUG: tampered key verified"; exit 1
else
  echo "(exit code $? — tampered key rejected, as it must be)"
fi

step "6. revoke — refund key #3 and re-check it"
KEY3=$(awk -F, 'NR==4 {print $2}' keys.csv)
"$CLI" verify "$KEY3" --key-dir "$DIR" >/dev/null && echo "key #3 valid before revocation"
"$CLI" revoke 3 --note "refunded" --key-dir "$DIR"
"$CLI" revoke --list --key-dir "$DIR"
if "$CLI" verify "$KEY3" --key-dir "$DIR"; then
  echo "BUG: revoked key verified"; exit 1
else
  echo "(exit code $? — revoked key rejected by the signed denylist)"
fi

step "demo complete — everything ran offline in $DIR"
