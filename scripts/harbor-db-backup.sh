#!/bin/bash
# Harbor database -> PBS (DR plan chapter 6).
# Runs in the harbor namespace, non-root. Stops at the first error, so a
# broken dump is never sent.
#
# Env: PGHOST, PGUSER, PGPASSWORD (Secret harbor-database), PBS_REPOSITORY,
# PBS_PASSWORD_FILE (file with the token secret), optional PGDATABASE (default registry),
# PBS_NAMESPACE (default k8s), BACKUP_ID (default harbor-db), WORK_DIR
# (default /work).
set -euo pipefail

: "${PGHOST:?}" "${PGUSER:?}" "${PGPASSWORD:?}" "${PBS_REPOSITORY:?}" "${PBS_PASSWORD_FILE:?}"
PGDATABASE=${PGDATABASE:-registry}
PBS_NAMESPACE=${PBS_NAMESPACE:-k8s}
BACKUP_ID=${BACKUP_ID:-harbor-db}
WORK_DIR=${WORK_DIR:-/work}
# Harbor 2.14 has 49 tables (2026-11-27).
MIN_TABLES=${MIN_TABLES:-30}
dump_dir=${WORK_DIR}/harbor-db
export PGDATABASE

log() {
	local ts
	ts=$(date -Is)
	printf '%s %s\n' "${ts}" "$*"
}

mkdir -p "${dump_dir}"

log "1/3 dump ${PGDATABASE} and the roles from ${PGHOST}"
pg_dump --format=custom --file="${dump_dir}/${PGDATABASE}.dump"
pg_dumpall --globals-only --file="${dump_dir}/globals.sql"

log "2/3 check the dump"
toc=$(pg_restore --list "${dump_dir}/${PGDATABASE}.dump")
tables=$(grep -c ' TABLE DATA ' <<<"${toc}" || true)
size=$(du -h "${dump_dir}/${PGDATABASE}.dump")
log "dump: ${size%%[[:space:]]*}, ${tables} tables with data"
if ((tables < MIN_TABLES)); then
	log "ERROR: only ${tables} tables with data, expected Harbor's full schema; not sending it"
	exit 1
fi
if ! grep -q '^CREATE ROLE' "${dump_dir}/globals.sql"; then
	log "ERROR: globals.sql has no roles; not sending it"
	exit 1
fi

log "3/3 send to PBS (${PBS_NAMESPACE}/host/${BACKUP_ID})"
proxmox-backup-client backup \
	"harbor-db.pxar:${dump_dir}" \
	--ns "${PBS_NAMESPACE}" \
	--backup-type host \
	--backup-id "${BACKUP_ID}"

log "done"
