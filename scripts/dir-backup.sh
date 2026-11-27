#!/bin/bash
# A mounted volume -> PBS as one pxar archive (DR plan chapter 7, recordings).
# Generic: what to back up and under which name comes from the env.
#
# Env: SOURCE_DIR (the mounted volume), ARCHIVE_NAME (e.g. recordings.pxar),
# BACKUP_ID, PBS_REPOSITORY, PBS_PASSWORD_FILE (file with the token secret),
# optional PBS_NAMESPACE (default k8s), MIN_FILES (default 1).
set -euo pipefail

: "${SOURCE_DIR:?}" "${ARCHIVE_NAME:?}" "${BACKUP_ID:?}" "${PBS_REPOSITORY:?}" "${PBS_PASSWORD_FILE:?}"
PBS_NAMESPACE=${PBS_NAMESPACE:-k8s}
# At least this many files, or the volume isn't what we think it is. Set 0
# only if the volume may legitimately be empty.
MIN_FILES=${MIN_FILES:-1}

# The image's WORKDIR belongs to uid 10001; this job may run as another
# user (recordings: 10000, like the app), and find/du fail on an unreadable
# working directory.
cd /

log() {
	local ts
	ts=$(date -Is)
	printf '%s %s\n' "${ts}" "$*"
}

log "1/2 check ${SOURCE_DIR}"
if ! mountpoint -q "${SOURCE_DIR}"; then
	log "ERROR: ${SOURCE_DIR} is not a mount point; not sending it"
	exit 1
fi
files=$(find "${SOURCE_DIR}" -xdev -path "${SOURCE_DIR}/lost+found" -prune -o -type f -print | wc -l)
# informational only, never a reason to stop
size=$(du -sh --exclude=lost+found "${SOURCE_DIR}" 2>/dev/null | cut -f1) || size="?"
log "${files} files, ${size}"
if ((files < MIN_FILES)); then
	log "ERROR: ${files} files, expected at least ${MIN_FILES}; not sending it"
	exit 1
fi

# metadata change detection: unchanged files (by size/mtime/inode data) are
# reused from the previous snapshot instead of being read again, so a night
# without new recordings reads almost nothing from the volume.
log "2/2 send to PBS (${PBS_NAMESPACE}/host/${BACKUP_ID})"
proxmox-backup-client backup \
	"${ARCHIVE_NAME}:${SOURCE_DIR}" \
	--skip-lost-and-found true \
	--change-detection-mode metadata \
	--ns "${PBS_NAMESPACE}" \
	--backup-type host \
	--backup-id "${BACKUP_ID}"

log "done"
