#!/bin/bash
# etcd + /etc/kubernetes -> PBS (DR plan chapter 6).
# Runs on k8smaster (host network, /etc/kubernetes mounted read-only at
# $HOST_K8S). Stops at the first error, so a broken snapshot is never sent.
#
# Env: PBS_REPOSITORY, PBS_PASSWORD_FILE (file with the token secret), optional PBS_NAMESPACE
# (default k8s), BACKUP_ID (default k8smaster-etcd), HOST_K8S (default
# /host/etc/kubernetes), WORK_DIR (default /work), ETCD_ENDPOINT.
set -euo pipefail

: "${PBS_REPOSITORY:?}" "${PBS_PASSWORD_FILE:?}"
PBS_NAMESPACE=${PBS_NAMESPACE:-k8s}
BACKUP_ID=${BACKUP_ID:-k8smaster-etcd}
HOST_K8S=${HOST_K8S:-/host/etc/kubernetes}
WORK_DIR=${WORK_DIR:-/work}
# A fresh kubeadm cluster has a few hundred keys, ours ~2300 (2026-11-27).
MIN_KEYS=${MIN_KEYS:-1000}
ETCD_ENDPOINT=${ETCD_ENDPOINT:-https://127.0.0.1:2379}
PKI=${HOST_K8S}/pki/etcd
snapshot=${WORK_DIR}/etcd.img

log() {
	local ts
	ts=$(date -Is)
	printf '%s %s\n' "${ts}" "$*"
}

log "1/3 etcd snapshot from ${ETCD_ENDPOINT}"
etcdctl --endpoints="${ETCD_ENDPOINT}" \
	--cacert="${PKI}/ca.crt" \
	--cert="${PKI}/healthcheck-client.crt" \
	--key="${PKI}/healthcheck-client.key" \
	snapshot save "${snapshot}"

log "2/3 check the snapshot"
status=$(etcdutl snapshot status "${snapshot}" --write-out=json)
keys=$(jq -r '.totalKey' <<<"${status}")
log "snapshot status: ${status}"
if ! [[ ${keys} =~ ^[0-9]+$ ]] || ((keys < MIN_KEYS)); then
	log "ERROR: snapshot has ${keys} keys, expected a lot more; not sending it"
	exit 1
fi

log "3/3 send to PBS (${PBS_NAMESPACE}/host/${BACKUP_ID})"
proxmox-backup-client backup \
	"etcd.img:${snapshot}" \
	"kubernetes.pxar:${HOST_K8S}" \
	--ns "${PBS_NAMESPACE}" \
	--backup-type host \
	--backup-id "${BACKUP_ID}"

log "done"
