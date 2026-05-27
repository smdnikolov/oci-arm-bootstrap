#!/usr/bin/env bash
set -u

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

for AD in $ADS; do
  [ -z "$AD" ] && continue
  echo "::group::Trying $AD"

  OUT=$(oci compute instance launch \
    --availability-domain "$AD" \
    --compartment-id "$COMPARTMENT_ID" \
    --shape "VM.Standard.A1.Flex" \
    --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY_GB}" \
    --image-id "$IMAGE_ID" \
    --subnet-id "$SUBNET_ID" \
    --assign-public-ip true \
    --display-name "$DISPLAY_NAME" \
    --boot-volume-size-in-gbs "$BOOT_VOLUME_GB" \
    --metadata "{\"ssh_authorized_keys\":\"$SSH_PUBLIC_KEY\"}" \
    --wait-for-state RUNNING 2>&1)
  RC=$?
  echo "$OUT"
  echo "::endgroup::"

  if [ $RC -eq 0 ]; then
    echo "SUCCESS: instance launched in $AD"
    exit 0
  fi

  if echo "$OUT" | grep -qi "Out of host capacity\|TooManyRequests\|InternalError"; then
    echo "$AD: transient/capacity error, trying next AD"
    CAPACITY_HIT=1
    continue
  fi

  # Anything else looks like a config mistake — fail loud so the run goes red.
  echo "Non-capacity error — failing the run so you can investigate logs"
  exit 1
done

if [ $CAPACITY_HIT -eq 1 ]; then
  echo "All ADs out of capacity this round. Will retry on next schedule."
  exit 75   # non-zero so workflow does NOT mark success / disable itself
fi

echo "No ADs were tried — something is wrong with AD discovery"
exit 1
