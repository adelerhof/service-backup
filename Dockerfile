# No HEALTHCHECK: the image only runs as short-lived Jobs/CronJobs.
# trunk-ignore-all(checkov/CKV_DOCKER_2)
# k8s-backup: the tools for the cluster's backup jobs (DR plan chapter 5).
# Only tools, no secrets: tokens and keys come from Secrets at runtime.
#
# Versions that must match the cluster (rebuild the image first when an
# upgrade changes them, see README):
#   ETCD_VERSION     = the cluster's etcd  (kube-system etcd pod image)
#   PG_MAJOR         = Harbor's PostgreSQL (harbor-database-0: postgres --version)

# ---------- stage 1: downloads, checked against pinned checksums ----------
FROM debian:trixie-slim AS fetch

ARG ETCD_VERSION=3.6.6
ARG ETCD_SHA256=887afaa4a99f22d802ccdfbe65730a5e79aa5c9ce2c8799c67e9d804c50ecedb
# Proxmox archive keyring for trixie (keys F4E136C6…0C39 and 24B30F06…778E)
ARG PROXMOX_KEYRING_SHA256=136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45
# PostgreSQL apt repository key (B97B0AFC…ACCC4CF8)
ARG PGDG_KEY_SHA256=0144068502a1eddd2a0280ede10ef607d1ec592ce819940991203941564e8e76

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# trunk-ignore(hadolint/DL3008)
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /fetch

RUN curl -fsSLo etcd.tar.gz \
        "https://github.com/etcd-io/etcd/releases/download/v${ETCD_VERSION}/etcd-v${ETCD_VERSION}-linux-amd64.tar.gz" \
    && echo "${ETCD_SHA256}  etcd.tar.gz" | sha256sum -c - \
    && tar -xzf etcd.tar.gz --strip-components=1 \
        "etcd-v${ETCD_VERSION}-linux-amd64/etcdctl" \
        "etcd-v${ETCD_VERSION}-linux-amd64/etcdutl"

RUN curl -fsSLo proxmox-archive-keyring.gpg \
        https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
    && echo "${PROXMOX_KEYRING_SHA256}  proxmox-archive-keyring.gpg" | sha256sum -c - \
    && curl -fsSLo pgdg.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    && echo "${PGDG_KEY_SHA256}  pgdg.asc" | sha256sum -c - \
    && gpg --dearmor -o pgdg.gpg pgdg.asc

# ---------- stage 2: the image itself (no curl, no gnupg) ----------
FROM debian:trixie-slim

ARG ETCD_VERSION=3.6.6
ARG PG_MAJOR=15

LABEL org.opencontainers.image.title="k8s-backup" \
      org.opencontainers.image.description="Tools for the cluster backup jobs: proxmox-backup-client, etcdctl/etcdutl, pg_dump, rsync" \
      org.opencontainers.image.source="https://github.com/adelerhof/service-backup" \
      eu.adelerhof.etcd-version="${ETCD_VERSION}" \
      eu.adelerhof.pg-major="${PG_MAJOR}"

COPY --from=fetch /fetch/proxmox-archive-keyring.gpg /usr/share/keyrings/proxmox-archive-keyring.gpg
COPY --from=fetch /fetch/pgdg.gpg /usr/share/keyrings/pgdg.gpg
COPY --from=fetch /fetch/etcdctl /fetch/etcdutl /usr/local/bin/

# ca-certificates must be in the same layer as the https repositories:
# the base image has no CA bundle, so apt can't reach them before it.
# trunk-ignore(hadolint/DL3008)
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && printf '%s\n' \
        'Types: deb' \
        'URIs: http://download.proxmox.com/debian/pbs-client' \
        'Suites: trixie' \
        'Components: main' \
        'Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg' \
        > /etc/apt/sources.list.d/pbs-client.sources \
    && printf '%s\n' \
        'Types: deb' \
        'URIs: https://apt.postgresql.org/pub/repos/apt' \
        'Suites: trixie-pgdg' \
        'Components: main' \
        'Signed-By: /usr/share/keyrings/pgdg.gpg' \
        > /etc/apt/sources.list.d/pgdg.sources \
    && apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
        proxmox-backup-client \
        "postgresql-client-${PG_MAJOR}" \
        rsync \
        tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s "/usr/lib/postgresql/${PG_MAJOR}/bin/pg_dump" /usr/local/bin/pg_dump \
    && ln -s "/usr/lib/postgresql/${PG_MAJOR}/bin/pg_restore" /usr/local/bin/pg_restore \
    && useradd --uid 10001 --user-group --home-dir /home/backup --create-home --shell /usr/sbin/nologin backup-runner

COPY scripts/ /usr/local/bin/

ENV TZ=Europe/Amsterdam

# Non-root by default. The etcd job overrides this with runAsUser: 0 in its
# manifest (it reads /etc/kubernetes/pki, mode 600), see DR plan chapter 5.
USER 10001
WORKDIR /home/backup

ENTRYPOINT ["/usr/local/bin/versions.sh"]
