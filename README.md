# sonatype-nexus-update-migration

Operational tooling for running, validating, and migrating Reliable Cloud
Services' self-hosted **Sonatype Nexus Repository** on AWS. Everything here is
plain Bash driving the AWS CLI and standard Linux tools — no agents, no
framework to install. Each script is self-contained, documents its own inputs,
and can be run on its own.

The repository collects three related jobs that grew out of operating one Nexus
instance:

1. **Upgrading Nexus in place** on a RHEL host (with a matching rollback).
2. **Migrating the whole instance** from a RHEL 8 EC2 to a RHEL 9 EC2, using an
   isolated clone of the data so production is never at risk.
3. **Cloning the external RDS** the instance runs on — a building block the
   migration uses, and useful on its own.

---

## Layout

```
.
├── upgrade/                         In-place Nexus version upgrade on a RHEL host
│   ├── nexus-upgrade-rollback.sh    Download, stage, promote a new Nexus; roll back on demand
│   └── nexus-post-upgrade-validate.sh   Validate repos/connectors after an upgrade
│
├── migration/                       RHEL 8 → RHEL 9 host migration (isolated-clone model)
│   ├── README.md                    Full run order and safety model for the migration
│   ├── 00-config.sh                 Shared config — edit everything marked <<< EDIT
│   ├── 01-pre-validate.sh           Prereq checks + non-disruptive EBS/RDS snapshots
│   ├── 02-provision-configure.sh    Restore clone RDS + volumes; install & configure Nexus on RHEL 9
│   ├── 03-post-validate.sh          DB-binding, repo parity, blob-store, format checks
│   └── nexus-post-upgrade-validate.sh   Format validator (shared copy; stage 5 delegates to it)
│
├── ec2/
│   └── ec2-clone.sh                 Clone an EC2 instance onto a new AMI, reusing config + data-volume snapshots
│
└── rds/
    └── rds-clone.sh                 Snapshot an RDS instance and restore a mirror of it
```

---

## RHEL 8 → RHEL 9 upgrade — end-to-end order

This is the full sequence for moving the Nexus host from RHEL 8 to RHEL 9. The
whole thing runs against **isolated clones** of production data, so the live
RHEL 8 instance keeps serving the entire time. Three separate concerns move in
parallel and converge on the new host:

- the **compute** (EC2 instance) → `ec2/ec2-clone.sh`
- the **database** (external PostgreSQL RDS) → `rds/rds-clone.sh`
- **Nexus itself** (install + config + validation) → `migration/*`

> **Before you start — three facts to pin down.** (1) The exact Nexus version
> the old box runs; the new box must install the *same* version (a newer binary
> won't open an older database). (2) The data-volume mount path on the old box
> (e.g. `/app/sonatype-work`); it must be identical on the new box or file blob
> stores won't resolve. (3) Which AZ the source lives in; the clone stays in it.

### Phase 0 — Capture a baseline (old box, prod stays live)
Record what "good" looks like so you can prove parity later.

```
# repo inventory from the OLD Nexus, for a parity check after migration
NEXUS_HOST_VALIDATE=<old-ip> NEXUS_ADMIN_PASS='***' \
  migration/03-post-validate.sh --capture-baseline ./migration/.repo-baseline.txt
```

### Phase 1 — Pre-validate + snapshot data (old box, non-disruptive)
Edit `migration/00-config.sh` first (all `<<< EDIT` markers), then:

```
migration/01-pre-validate.sh          # checks prereqs; snapshots prod EBS + RDS
```

This only reads prod and creates snapshots — nothing is detached or stopped.

### Phase 2 — Clone the database (RDS)
Stand up an isolated copy of the PostgreSQL RDS the new host will use. **Always
dry-run first** to see the exact plan, then execute.

```
rds/rds-clone.sh --source <prod-rds-id> --target <clone-rds-id> \
  --endpoint <prod-rds-endpoint> --dry-run
rds/rds-clone.sh --source <prod-rds-id> --target <clone-rds-id> \
  --endpoint <prod-rds-endpoint>
```

Note the clone's endpoint address from the output — it goes into
`CLONE_RDS_HOST` in `migration/00-config.sh`. Make sure the clone RDS security
group lets the new instance reach the DB port.

### Phase 3 — Clone the compute (EC2 onto the RHEL 9 AMI)
Launch the new RHEL 9 instance, mirroring the old box's type, key pair, SGs,
subnet, IAM profile, and tags, with **snapshot-copies of the data volumes**
attached at their original device names. The old RHEL 8 root is *not* cloned —
the new instance boots from the RHEL 9 AMI. **Dry-run first.**

```
ec2/ec2-clone.sh --source <old-instance-id> --ami <rhel9-ami-id> \
  --name <new-name-tag> --dry-run
ec2/ec2-clone.sh --source <old-instance-id> --ami <rhel9-ami-id> \
  --name <new-name-tag>
```

Put the resulting instance id in `NEW_INSTANCE_ID` in `migration/00-config.sh`.

### Phase 4 — Provision & configure Nexus (on the new RHEL 9 box, as root)
`migration/02-provision-configure.sh` runs in stages. The data volumes are
already attached by Phase 3, so here you mount them and install Nexus pointed at
the cloned RDS.

```
export CLONE_RDS_PASSWORD='***'
sudo -E migration/02-provision-configure.sh host-prep        # pkgs, user, SELinux, firewall
sudo    migration/02-provision-configure.sh host-mount       # guided mount of data volume(s)
sudo    migration/02-provision-configure.sh host-mount-verify
sudo    migration/02-provision-configure.sh host-install     # pinned Nexus version
sudo -E migration/02-provision-configure.sh host-configure   # nexus-store.properties -> clone RDS
sudo    migration/02-provision-configure.sh host-service     # systemd unit + start
```

Mount the data volume(s) at the **same path** the old box used, by UUID. Watch
`tail -f <data-dir>/log/nexus.log` for the first-start rebuild tasks to finish.

> The `aws-*` stages of `02-provision-configure.sh` (restore RDS, create/attach
> volumes) overlap with what `rds-clone.sh` and `ec2-clone.sh` do. Use the
> standalone clone scripts for the clone itself (they capture far more of the
> source config and dry-run the plan); use `02`'s `host-*` stages for the
> on-box install and configuration.

### Phase 5 — Validate the clone (parity gate)
Prove the migrated instance matches the old one before trusting it.

```
NEXUS_ADMIN_PASS='***' migration/03-post-validate.sh \
  --baseline ./migration/.repo-baseline.txt
NEXUS_HOST=<new-ip> NEXUS_PASS='***' migration/nexus-post-upgrade-validate.sh
```

Must pass: PostgreSQL bound (not H2 fallback), repo list matches the baseline,
blob stores report content, and the format pulls/pushes succeed.

### Phase 6 — Cutover (separate, deliberate window)
The steps above build and validate a **parallel clone**. The real production
cutover is its own short window: stop old Nexus → take fresh RDS + EBS snapshots
(or re-point to the real data) → bring up the RHEL 9 box on the **real** data →
move the Elastic IP so clients need no change → keep the old instance **stopped,
not terminated**, as rollback. See `migration/README.md` for the cutover detail
and the two-writers safety rule (never point two Nexus instances at one RDS).

### At a glance

| Phase | Script | Runs on | Touches prod? |
|-------|--------|---------|---------------|
| 0 Baseline | `migration/03-post-validate.sh --capture-baseline` | workstation | read-only |
| 1 Pre-validate | `migration/01-pre-validate.sh` | workstation | snapshots only |
| 2 Clone RDS | `rds/rds-clone.sh` | workstation | snapshot only |
| 3 Clone EC2 | `ec2/ec2-clone.sh` | workstation | snapshots only |
| 4 Provision | `migration/02-provision-configure.sh host-*` | new RHEL 9 box | no |
| 5 Validate | `migration/03-post-validate.sh` | new box / workstation | no |
| 6 Cutover | manual + `migration/README.md` | both | yes (planned) |

## What each script is for

### `upgrade/nexus-upgrade-rollback.sh`
In-place upgrade of Nexus on a single RHEL host where the install lives at
`/app/nexus` and data at `/app/sonatype-work`. It downloads the target version,
extracts it in an **isolated staging directory** (so the tarball's bundled
`sonatype-work/` skeleton can never shadow live data), copies the install-dir
config across (vmoptions, SSL keystore, jetty), backs up the current install,
promotes the new one, applies our standard tweaks (Jetty `maxThreads`, keystore
filename + passwords), and restarts the service. `rollback` restores the most
recent backup of a prior version.

```
sudo ./nexus-upgrade-rollback.sh upgrade  --from 3.89.0-09 --to 3.94.0-12
sudo ./nexus-upgrade-rollback.sh rollback --restore 3.89.0-09 --current 3.94.0-12
```

> Data-dir downgrades aren't supported by Nexus, so a rollback only restores the
> install dir — take a database/blob backup before any upgrade. See the script's
> `--help`.

### `upgrade/nexus-post-upgrade-validate.sh`
Post-change smoke test. Confirms the UI/REST endpoints are healthy and lists the
repository inventory, then exercises real pulls/pushes against the formats we
serve — Docker (proxy pull + hosted build/push round-trip), Maven, npm, PyPI,
raw, and yum. Built for an **HTTP test replica** (reminds you about Docker
`insecure-registries`), and ports cleanly to HTTPS for production. Every section
is placeholder-driven and independently toggleable; it never aborts on the first
failure, printing a pass/fail/skip summary instead.

```
NEXUS_HOST=<ip> NEXUS_PASS='***' ./nexus-post-upgrade-validate.sh
./nexus-post-upgrade-validate.sh --only docker
./nexus-post-upgrade-validate.sh --list
```

### `migration/` — RHEL 8 → RHEL 9
A four-script sequence that stands up Nexus on a new RHEL 9 EC2 against an
**isolated clone** of production data (EBS blob volumes cloned from snapshots,
external PostgreSQL cloned via RDS snapshot/restore), so the live RHEL 8 box
stays up and untouched. Pins the **same Nexus version** as the old box — a newer
binary refuses to start against an older database. Full run order, the
two-writers safety rule, and the real-cutover pattern are in
[`migration/README.md`](migration/README.md).

### `ec2/ec2-clone.sh`
Clones an existing EC2 instance onto a **new AMI** (the RHEL 9 image you pass),
reusing the source's configuration without touching the source. It describes the
source, snapshots only its **data** volumes (never the root — the new AMI
supplies that), creates new volumes from those snapshots in the same AZ, launches
a mirror instance (same type, key pair, security groups, subnet, IAM profile,
tags, EBS-optimized flag), attaches the cloned volumes at their original device
names, waits for 2/2 status checks, and verifies parity. Has a **`--dry-run`**
that prints the exact AWS commands (like `terraform plan`). Mounting the data
volumes on the new host (by UUID, at their original paths) is a separate step.

```
./ec2-clone.sh --source i-0abc123 --ami ami-0rhel9 --dry-run
./ec2-clone.sh --source i-0abc123 --ami ami-0rhel9
```

### `rds/rds-clone.sh`
Clones an existing RDS instance: describes the source, captures everything the
restore won't carry (security groups, parameter/option groups, subnet group,
storage/IOPS, Multi-AZ, CA cert, Performance Insights, monitoring, backup
retention, tags), takes a fresh snapshot, restores a mirror, applies the
leftovers, and verifies parity field-by-field. Has a **`--dry-run`** that prints
the exact AWS commands it would run (like `terraform plan`) without creating
anything.

```
./rds-clone.sh --source nexus-prod --target nexus-clone --endpoint <src-endpoint> --dry-run
./rds-clone.sh --source nexus-prod --target nexus-clone --endpoint <src-endpoint>
```

---

## Conventions across the toolkit

- **Isolated-clone first.** Anything that could touch production data works on a
  snapshot or a copy. Two Nexus instances must never write the same database or
  blob store — that corrupts state.
- **Version pinning.** Nexus stamps a schema version into its database; a newer
  binary can't open an older DB. Upgrades and migrations state the version
  explicitly.
- **Identical paths.** File blob stores reference absolute paths, so the data
  mount point stays the same (`/app/sonatype-work`) across hosts.
- **Placeholders, not secrets.** Passwords come from environment variables
  (`NEXUS_PASS`, `CLONE_RDS_PASSWORD`, …), never hardcoded. Fill the
  `<<< EDIT` markers in config before running.
- **Fail-open validation.** Validators run every check and summarize, rather than
  stopping at the first failure.
- **Bash 3.2 safe.** Scripts avoid associative arrays so they run on stock macOS
  Bash as well as RHEL.

## Requirements

- Bash, `curl`, `tar`, standard coreutils (on the Nexus hosts).
- AWS CLI v2 configured locally, and `jq`, for the `migration/` AWS stages and
  `rds/rds-clone.sh`.
- Docker (Docker Desktop is fine) on whatever machine runs the Docker section of
  the validator.

## How this was built

These scripts were developed iteratively against the real Nexus instance and the
Sonatype 3.87+/3.9x tarball layout (single-level install dir plus a sibling
`sonatype-work/`, bundled Temurin JDK 21, external-PostgreSQL `nexus-store.properties`
under `<data-dir>/etc/fabric/`). Behavior was checked against Sonatype's own
upgrade and database-migration documentation; the structural assumptions were
confirmed against an actual `tar -tzf` of the release artifact rather than
assumed.
