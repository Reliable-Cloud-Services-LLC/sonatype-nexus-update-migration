# Nexus RHEL 8 → RHEL 9 Migration (isolated-clone model)

Migrates Sonatype Nexus Repository from a RHEL 8 EC2 to a new RHEL 9 EC2
**without touching the live RHEL 8 box**. Blob-store EBS volumes and the
external PostgreSQL RDS are **snapshotted and cloned**; the new instance runs
against the clones. Old prod stays up and serving the whole time.

Pinned Nexus version: **3.95.3-02** (must match the old box — a newer binary
refuses to start against a 3.95 database). Upgrading Nexus is a *separate*
exercise after this migration is proven.

## Critical safety rule

**Never point two running Nexus instances at the same RDS or the same blob
volumes.** Two writers corrupt state. That's why this is a clone: the new box
reads a restored RDS and volumes built from snapshots, never prod. The scripts
include guards (`assert_not_prod_rds`) but the discipline is yours.

## Files

| File | Where it runs | What it does |
|------|---------------|--------------|
| `00-config.sh` | — | Shared config. Edit everything marked `<<< EDIT`. |
| `01-pre-validate.sh` | workstation (AWS CLI) | Checks prereqs; snapshots prod EBS + RDS (non-disruptive). |
| `02-provision-configure.sh` | workstation **and** RHEL 9 box | Restores clone RDS, creates/attaches clone volumes; then on the box: prep, mount, install, configure, service. |
| `03-post-validate.sh` | RHEL 9 box (or remote) | Health, **DB-is-PostgreSQL-not-H2**, repo parity vs baseline, blob stores online, format smoke tests. |
| `nexus-post-upgrade-validate.sh` | — | Your existing format validator; `03` delegates to it. |

## Order of operations

### Before cutover window (prod stays live)
1. Edit `00-config.sh`. Set versions, paths, `NEW_AZ`, `PROD_RDS_INSTANCE_ID`,
   `BLOB_VOLUMES`, RDS clone sizing, ports, context path, `NEXUS_UID`.
2. **Capture a repo baseline from the OLD box** (for parity later):
   ```
   NEXUS_HOST_VALIDATE=<old-ip> NEXUS_ADMIN_PASS='***' \
     ./03-post-validate.sh --capture-baseline ./.repo-baseline.txt
   ```
3. `./01-pre-validate.sh` — validates + snapshots prod EBS and RDS. Wait for
   snapshots to complete (commands printed at the end).

### Build the clone
4. Launch a RHEL 9 EC2 **in `NEW_AZ`**. Put its id in `NEW_INSTANCE_ID`.
5. `./02-provision-configure.sh all-aws` — restores clone RDS, creates clone
   volumes, attaches them. Copy the printed clone-RDS endpoint into
   `CLONE_RDS_HOST` in `00-config.sh`. Ensure the clone RDS security group
   lets the new instance reach 5432.

### On the RHEL 9 box (as root)
6. `export CLONE_RDS_PASSWORD='***'`
7. `sudo -E ./02-provision-configure.sh host-prep`
8. `sudo ./02-provision-configure.sh host-mount` → follow the guided steps to
   mount each clone volume **at the same path as the old box**, by UUID.
   Then `sudo ./02-provision-configure.sh host-mount-verify`.
9. `sudo ./02-provision-configure.sh host-install`
10. `sudo -E ./02-provision-configure.sh host-configure` (writes
    `nexus-store.properties` → clone RDS; sets `nexus.datastore.enabled=true`,
    context path, `karaf.data`).
11. `sudo ./02-provision-configure.sh host-service` → starts Nexus. Watch
    `tail -f <DATA_DIR>/log/nexus.log` for rebuild tasks to finish.

### Validate
12. `NEXUS_ADMIN_PASS='***' ./03-post-validate.sh --baseline ./.repo-baseline.txt`
    Must pass: PostgreSQL bound (not H2), repo list matches baseline, blob
    stores report content.
13. Deep format checks: `NEXUS_HOST=<new-ip> NEXUS_PASS='***' ./nexus-post-upgrade-validate.sh`

## Why each guardrail exists

- **Version pinning (3.95.3-02):** Nexus writes a schema-version marker in the
  DB. A newer binary reading it fails with *"database appears to be from a later
  version."* Match the old box exactly; upgrade afterward.
- **H2-fallback detection:** if `nexus-store.properties` is missing/misread,
  Nexus silently boots its embedded H2 and looks "up" while serving an empty
  catalog. `03` greps the log and the store file to catch this.
- **Identical mount paths:** file blob stores reference absolute paths. Mount
  the clone volume where the old box had it or the stores won't resolve.
- **Clone isolation:** Sonatype explicitly requires a *copy* of blobs + DB for
  any parallel instance; sharing live data diverges/corrupts it.

## Real cutover (later, separate from the parallel rehearsal)

The clone above is your rehearsal/validation. For the actual production move,
the safest pattern is a short window: stop old Nexus → take fresh RDS + EBS
snapshots (or re-point to real volumes) → bring up the RHEL 9 box on the
**real** data → move the Elastic IP so clients need no change → keep the old
instance stopped (not terminated) as rollback. Re-run `03` against it.

## PostgreSQL note

Because the DB is external, the EBS volume carries **blob stores + config
only** — the database migrates via the RDS snapshot/restore, independently.
Both halves must line up: the restored RDS holds the catalog, the cloned
volumes hold the matching blobs, taken at close to the same time.
