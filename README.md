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
└── rds/
    └── rds-clone.sh                 Snapshot an RDS instance and restore a mirror of it
```

---

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
