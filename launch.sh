#!/usr/bin/env bash
set -u
export SUPPRESS_LABEL_WARNING=True

echo "=== Validating inputs ==="
missing=0
for var in COMPARTMENT_ID SUBNET_ID SSH_PUBLIC_KEY OCPUS MEMORY_GB BOOT_VOLUME_GB DISPLAY_NAME; do
  if [ -z "${!var:-}" ]; then
    echo "ERROR: required env var '$var' is empty or unset"
    missing=1
  fi
done
if [ $missing -ne 0 ]; then
  echo "Fix the corresponding GitHub secret(s) and re-run."
  exit 1
fi

echo "=== Looking up latest Ubuntu 24.04 aarch64 image ==="
IMAGE_ID=$(oci compute image list \
  --compartment-id "$COMPARTMENT_ID" \
  --operating-system "Canonical Ubuntu" \
  --operating-system-version "24.04" \
  --shape "VM.Standard.A1.Flex" \
  --sort-by TIMECREATED --sort-order DESC \
  --query 'data[0].id' --raw-output 2>/dev/null)

if [ -z "$IMAGE_ID" ] || [ "$IMAGE_ID" = "null" ]; then
  echo "ERROR: could not resolve Ubuntu 24.04 aarch64 image OCID"
  exit 1
fi
echo "Using image: $IMAGE_ID"

echo "=== Listing availability domains ==="
ADS=$(oci iam availability-domain list \
        --compartment-id "$COMPARTMENT_ID" \
        --query 'data[].name' --raw-output | tr -d '[]," ' | tr '\n' ' ')
echo "ADs: $ADS"

CAPACITY_HIT=0

# Write JSON to files and pass via file:// URIs — most reliable across CLI versions.
SSH_KEY_CLEAN=$(printf '%s' "$SSH_PUBLIC_KEY" | tr -d '\r\n' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
META_FILE=/tmp/oci_metadata.json
SHAPE_FILE=/tmp/oci_shape_config.json
jq -nc --arg k "$SSH_KEY_CLEAN" '{ssh_authorized_keys: $k}' > "$META_FILE"
jq -nc --argjson o "$OCPUS" --argjson m "$MEMORY_GB" '{ocpus: $o, memoryInGBs: $m}' > "$SHAPE_FILE"

echo "--- metadata.json ---"
cat "$META_FILE"; echo
echo "--- shape_config.json ---"
cat "$SHAPE_FILE"; echo

FIRST=1
for AD in $ADS; do
  [ -z "$AD" ] && continue

  # Small jitter + spacing between AD attempts to avoid hammering the LaunchInstance endpoint
  # in lockstep with other bots. Skip on the first AD so cold-start latency stays low.
  if [ $FIRST -eq 0 ]; then
    SLEEP_S=$(( 8 + RANDOM % 5 ))   # 8-12 seconds
    echo "Sleeping ${SLEEP_S}s before next AD..."
    sleep "$SLEEP_S"
  fi
  FIRST=0

  echo "::group::Trying $AD"

  OUT=$(oci compute instance launch \
    --availability-domain "$AD" \
    --compartment-id "$COMPARTMENT_ID" \
    --shape "VM.Standard.A1.Flex" \
    --shape-config "file://$SHAPE_FILE" \
    --image-id "$IMAGE_ID" \
    --subnet-id "$SUBNET_ID" \
    --assign-public-ip true \
    --display-name "$DISPLAY_NAME" \
    --boot-volume-size-in-gbs "$BOOT_VOLUME_GB" \
    --metadata "file://$META_FILE" \
    --wait-for-state RUNNING 2>&1)
  RC=$?
  echo "$OUT"
  echo "::endgroup::"

  if [ $RC -eq 0 ]; then
    echo "SUCCESS: instance launched in $AD"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
      INSTANCE_ID=$(echo "$OUT" | jq -r '.data.id // empty' 2>/dev/null)
      PUBLIC_IP=""
      if [ -n "$INSTANCE_ID" ]; then
        # Resolve the VNIC -> public IP. Best-effort: don't fail the run if this errors.
        VNIC_ID=$(oci compute instance list-vnics --instance-id "$INSTANCE_ID" \
          --query 'data[0].id' --raw-output 2>/dev/null || true)
        if [ -n "$VNIC_ID" ] && [ "$VNIC_ID" != "null" ]; then
          PUBLIC_IP=$(oci network vnic get --vnic-id "$VNIC_ID" \
            --query 'data."public-ip"' --raw-output 2>/dev/null || true)
        fi
      fi
      {
        echo "launched=true"
        echo "ad=$AD"
        echo "instance_id=${INSTANCE_ID:-}"
        echo "public_ip=${PUBLIC_IP:-}"
      } >> "$GITHUB_OUTPUT"
    fi
    exit 0
  fi

  # Treat anything network-/capacity-/5xx-flavoured as transient: try next AD, no email.
  if echo "$OUT" | grep -qiE "Out of host capacity|TooManyRequests|InternalError|RequestException|timed out|timeout|ServiceUnavailable|ConnectionError|EndpointConnectionError|Could not connect|temporarily unavailable|throttl"; then
    echo "$AD: transient error, trying next AD"
    CAPACITY_HIT=1
    continue
  fi

  # Anything else looks like a real config mistake — fail loud so the run goes red and emails us.
  echo "Non-transient error — failing the run so you can investigate logs"
  exit 1
done

if [ $CAPACITY_HIT -eq 1 ]; then
  echo "All ADs hit transient/capacity errors this round. Will retry on next schedule."
  # Exit 0 so GitHub does NOT send a failure email for the expected case.
  # The workflow's disable-on-success step is gated by the 'launched' output, not exit code.
  exit 0
fi

echo "No ADs were tried — something is wrong with AD discovery"
exit 1
