# service-backup

Backup code for the Kubernetes cluster: the `k8s-backup` image, the
backup jobs and the Synology restore script. Plan and reasons: notes
`applicaties/k8s-dr-step-plan.md` (this repository is decision 4, the
image is chapter 5).

## The image: `ghcr.io/adelerhof/k8s-backup`

Only tools, no secrets (tokens come from Secrets when a job runs).

| Tool                    | Source                                                  | Version rule                                       |
| ----------------------- | ------------------------------------------------------- | -------------------------------------------------- |
| `proxmox-backup-client` | Proxmox `pbs-client` repository, trixie                 | latest at build time                               |
| `etcdctl`, `etcdutl`    | official etcd release, SHA-256 pinned in the Dockerfile | **same as the cluster's etcd** (`ETCD_VERSION`)    |
| `pg_dump`, `pg_restore` | PostgreSQL apt repository (`trixie-pgdg`)               | **same major as Harbor's PostgreSQL** (`PG_MAJOR`) |
| `rsync`                 | Debian                                                  | —                                                  |

- Base `debian:trixie-slim`, amd64 only. Two stages: downloads and
  key/checksum checks happen in the first, so the image itself has no
  `curl` or `gnupg`.
- Runs as user `10001` by default. Only the etcd job runs as root (it
  reads `/etc/kubernetes/pki`).
- The default entrypoint `versions.sh` prints every tool's version:

  ```bash
  docker run --rm ghcr.io/adelerhof/k8s-backup:<tag>
  ```

- On the laptop the same image is used for restores (the laptop has no
  `proxmox-backup-client`), see the DR plan chapter 11.

### When to rebuild

Rebuild **before** an upgrade that changes:

- **etcd** (a Kubernetes minor upgrade usually does): check with
  `kubectl -n kube-system get pod -l component=etcd -o jsonpath='{.items[0].spec.containers[0].image}'`,
  set `ETCD_VERSION` and `ETCD_SHA256` (from the release's `SHA256SUMS`).
- **Harbor's PostgreSQL major**: check with
  `kubectl -n harbor exec harbor-database-0 -c database -- postgres --version`,
  set `PG_MAJOR`.

And monthly, in the CVE run (Trivy, `scan-images.sh`). The build runs
`apt-get upgrade`, so a rebuild picks up Debian security fixes.

**Known Trivy findings in `etcdctl`/`etcdutl`** (first scan 2026-11-27,
Trivy 0.76.2: ~90 fixable HIGH, 2 CRITICAL in Go stdlib, `x/net`,
`grpc`): they're built into the official etcd 3.6.6 release, the same
build the cluster's own etcd runs. Accepted: the version has to match the
cluster, and the tools only talk to etcd on the node itself
(`127.0.0.1:2379`). They go away with the next etcd version that comes
with a Kubernetes upgrade.

If one of the pinned signing keys changes (Proxmox or PostgreSQL rotates
it), the build stops at the `sha256sum -c` step: check the new key's
fingerprint against the vendor's site before updating the checksum.

### Build and publish

```bash
./build.sh
```

Needs a Docker login to `ghcr.io` and `harbor.adelerhof.eu`. Builds, runs
the smoke test, pushes `:latest` and `:<timestamp>` to both, and updates
the tag in `manifests/` (once there are manifests). GHCR is the one the
cluster uses: after a disaster Harbor (inside the cluster) is gone, GHCR
isn't.

## Layout

| Path                                           | What                                             |
| ---------------------------------------------- | ------------------------------------------------ |
| `Dockerfile`, `docker-compose.yml`, `build.sh` | the image                                        |
| `scripts/`                                     | scripts copied into the image (`/usr/local/bin`) |
| `manifests/`, `argocd/`                        | the jobs and their Argo CD app                   |

## Jobs

| Job                | Namespace | When        | PBS backup (namespace `k8s`)                                              | Token                   |
| ------------------ | --------- | ----------- | ------------------------------------------------------------------------- | ----------------------- |
| `etcd-backup`      | `backup`  | daily 03:30 | `host/k8smaster-etcd`: `etcd.img` + `kubernetes.pxar` (`/etc/kubernetes` without `tmp/`, kubeadm upgrade leftovers) | `k8s-backup@pbs!etcd`   |
| `harbor-db-backup` | `harbor`  | daily 03:35 | `host/harbor-db`: `harbor-db.pxar` (`registry.dump` + `globals.sql`)      | `k8s-backup@pbs!harbor` |

Each script stops at the first error and checks what it made before
sending it (etcd: at least `MIN_KEYS` keys; Harbor: at least
`MIN_TABLES` tables with data, and roles present). Failed jobs stay
visible (`backoffLimit: 0`, last 3 kept).

The jobs reach PBS as `pbs.home.adelerhof.eu` (the name on its
certificate). That name resolves through a CoreDNS `hosts` entry, and the
Harbor job's egress rule is a NetworkPolicy; both live in the private
`adelerhof/k8s` repository, so no internal address is in this one.

### Secrets (by hand, never in Git)

Token secrets are in KeePass. Create each Secret from a file so the
token never lands in the shell history:

```bash
umask 077; ${EDITOR:-vi} /tmp/pbs-token     # paste the token secret, save
kubectl -n backup create secret generic pbs-backup --from-file=token=/tmp/pbs-token
shred -u /tmp/pbs-token
```

Same for the Harbor job with the `!harbor` token, in namespace `harbor`.
The Harbor DB password comes from Harbor's own Secret `harbor-database`.

### Run once by hand

```bash
kubectl -n backup create job etcd-backup-manual --from=cronjob/etcd-backup
kubectl -n backup logs -f job/etcd-backup-manual
```

## Security: this repository is public

Nothing secret or private goes in here: tokens, keys and passwords live in
Kubernetes Secrets (created by hand, never committed), internal addresses
and hostnames stay in the private notes.

| Check                                                                          | Where                                               | When                                    |
| ------------------------------------------------------------------------------ | --------------------------------------------------- | --------------------------------------- |
| TruffleHog, whole history                                                      | `.github/workflows/security.yml`, job `secret-scan` | every push, pull request, weekly        |
| Internal IPs, bare `*.home`/`*.ansible` hostnames, private keys, PBS key files | same, job `private-info`                            | every push, pull request                |
| GitHub secret scanning + push protection                                       | repository settings                                 | every push (blocks known token formats) |
| Dependabot alerts + security updates                                           | repository settings                                 | continuous                              |
| Dependabot version updates (base image digest, actions), 14-day cooldown       | `.github/dependabot.yml`                            | weekly                                  |
| CodeQL (GitHub Actions workflows)                                              | repository settings, default setup                  | every push, pull request, weekly        |

Actions are pinned by commit SHA. The `master` ruleset requires a pull
request and the `secret-scan` and `private-info` checks.
