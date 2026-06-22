# oci-arm-bootstrap

Automatically grab an **Oracle Cloud Always-Free Ampere A1 (ARM)** VM in a
region where capacity is scarce, by repeatedly attempting a launch until one
succeeds.

Oracle's Always-Free A1 capacity in popular regions (e.g. Frankfurt) is almost
always exhausted — a manual launch just returns `Out of host capacity`. This
repo runs a GitHub Actions workflow that tries to launch an instance across
every availability domain in your home region, fails fast on capacity errors,
and is meant to be fired on a tight interval until it wins a free slot. On
success it opens a GitHub issue (so you get an email) and **auto-disables
itself**.

> Built originally to host a Stremio server, but it provisions a plain Ubuntu
> 24.04 ARM VM you can use for anything.

---

## How it works

1. An **external cron service** (e.g. cron-job.org) calls the GitHub API on an
   interval to trigger the `Launch OCI ARM instance` workflow
   (`workflow_dispatch`).
2. The workflow (`.github/workflows/launch.yml`) installs the OCI CLI, writes an
   OCI config from your secrets, and runs `launch.sh`.
3. `launch.sh` resolves the latest Ubuntu 24.04 aarch64 image and tries
   `oci compute instance launch` (shape `VM.Standard.A1.Flex`) in each
   availability domain. Capacity rejections (`HTTP 500 Out of host capacity`)
   are treated as transient — it moves on and exits cleanly so no failure email
   is sent. A genuine config error fails the run loudly.
4. On the first success it opens a "launched 🎉" issue with the instance OCID +
   public IP, then runs `gh workflow disable launch.yml` so it stops trying.

Why an external cron instead of GitHub's native `schedule:`? Native cron is
unreliable (delayed/skipped under load) and auto-disables after 60 days of repo
inactivity. An external pinger gives a dependable, tight cadence.

---

## Free-tier hardware limits (important)

As of **~June 15, 2026** Oracle cut the Always-Free Ampere A1 allowance in half:

| Resource     | Always-Free max | Configured here |
| ------------ | --------------- | --------------- |
| OCPUs        | **2**           | 2               |
| Memory       | **12 GB**       | 12 GB           |
| Block/boot storage | **200 GB** total | 200 GB     |

These values live in `.github/workflows/launch.yml` under the `Attempt launch`
step (`OCPUS`, `MEMORY_GB`, `BOOT_VOLUME_GB`). **Do not exceed them** — on a free
tenancy the launch will be rejected, and on Pay-As-You-Go you'll be billed.
`launch.sh` does not enforce the cap; it passes whatever these env vars contain.

---

## Required GitHub Secrets

Set these under **Repo → Settings → Secrets and variables → Actions → New
repository secret**. The workflow reads them as `${{ secrets.* }}`.

| Secret               | What it is                                                                 |
| -------------------- | -------------------------------------------------------------------------- |
| `OCI_USER`           | Your user OCID (`ocid1.user.oc1..…`)                                        |
| `OCI_TENANCY`        | Your tenancy OCID (`ocid1.tenancy.oc1..…`)                                  |
| `OCI_FINGERPRINT`    | Fingerprint of the API signing key (e.g. `aa:bb:cc:…`)                      |
| `OCI_REGION`         | Home region identifier (e.g. `eu-frankfurt-1`)                             |
| `OCI_API_KEY_PEM`    | The **full private key PEM** for the API key (multi-line, paste as-is)     |
| `OCI_COMPARTMENT_ID` | Compartment OCID to launch in (root tenancy OCID is fine)                  |
| `OCI_SUBNET_ID`      | OCID of a public subnet in your VCN (`ocid1.subnet.oc1.…`)                  |
| `SSH_PUBLIC_KEY`     | Your SSH **public** key — injected so you can `ssh ubuntu@<ip>`            |

> `GITHUB_TOKEN` is provided automatically by Actions; you do **not** create it.

### Where to find each OCI value

- **User / Tenancy OCID + Fingerprint + API key**: OCI Console → top-right
  profile → **My profile → API keys → Add API key**. Download the private key,
  and copy the user OCID, tenancy OCID, and fingerprint it shows you.
- **Region**: shown in the console region menu (use the identifier form like
  `eu-frankfurt-1`).
- **Compartment OCID**: Console → **Identity → Compartments** (or use the
  tenancy/root OCID).
- **Subnet OCID**: Console → **Networking → Virtual Cloud Networks → your VCN →
  Subnets**. Use a **public** subnet so `--assign-public-ip` works.
- **SSH public key**: contents of your `~/.ssh/id_ed25519.pub` (or `id_rsa.pub`).

### Setting a secret with the GitHub CLI (alternative to the UI)

```bash
gh secret set OCI_REGION        --repo <owner>/oci-arm-bootstrap --body "eu-frankfurt-1"
gh secret set OCI_API_KEY_PEM   --repo <owner>/oci-arm-bootstrap < ~/.oci/oci_api_key.pem
gh secret set SSH_PUBLIC_KEY    --repo <owner>/oci-arm-bootstrap < ~/.ssh/id_ed25519.pub
# …repeat for the OCID-based secrets
```

---

## Tunable launch values (workflow env, not secrets)

In `.github/workflows/launch.yml`, the `Attempt launch` step also sets
non-secret values you can edit directly:

| Env var          | Default      | Notes                                          |
| ---------------- | ------------ | ---------------------------------------------- |
| `DISPLAY_NAME`   | `arm-stremio`| Instance display name in the console           |
| `OCPUS`          | `2`          | Must be ≤ 2 for free tier                       |
| `MEMORY_GB`      | `12`         | Must be ≤ 12 for free tier                      |
| `BOOT_VOLUME_GB` | `200`        | ≤ 200 GB total free block storage               |

---

## Setting up the external cron trigger

1. **Create a fine-grained PAT** (GitHub → Settings → Developer settings →
   Personal access tokens → Fine-grained tokens):
   - Repository access: **Only select repositories** → this repo
   - Permissions: **Actions: Read and write** + **Metadata: Read-only** (auto)
   - Expiration: set a long custom date so it doesn't lapse mid-hunt
2. **Point your cron service** at the dispatch endpoint:

   ```
   POST https://api.github.com/repos/<owner>/oci-arm-bootstrap/actions/workflows/launch.yml/dispatches
   Headers:
     Authorization: Bearer <your_fine_grained_PAT>
     Accept: application/vnd.github+json
   Body:
     {"ref":"main"}
   ```
3. **Interval:** every **1–2 minutes**. Each run completes in ~1 minute, so this
   leaves no gaps and avoids piling up queued runs. Don't go below 1 min — no
   extra attempts are gained (the `concurrency` group allows only one run at a
   time) and you risk OCI throttling.

When the launch finally succeeds, the workflow auto-disables itself, so your
cron calls start returning **HTTP 403 (workflow disabled)** — that's your signal
you got the instance (plus the GitHub issue it opens).

---

## Performance notes

- `launch.sh` passes **`--no-retry`** to the launch call. `Out of host capacity`
  is an HTTP 500, which the OCI CLI's default retry strategy would otherwise
  retry for ~2 minutes *per AD* before giving up. `--no-retry` makes it fail in
  seconds, so each run cycles all ADs quickly and you fire many more launch
  attempts per hour — which is what actually wins scarce capacity.
- Capacity frees in brief, random windows that many other grabber bots also
  chase, so the winning strategy is simply **attempting often**, not waiting.

---

## After you get the instance

1. SSH in: `ssh -i ~/.ssh/<your-key> ubuntu@<public-ip>`
2. Open any needed ports in the VCN's Security List (the original use case opens
   `11470`/`12470` for Stremio).
3. Re-enable the workflow later (Actions tab → enable) only if you want to
   provision again.
