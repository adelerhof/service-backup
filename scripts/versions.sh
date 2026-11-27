#!/bin/bash
# Prints the version of every tool in the image. Default entrypoint, so
# `docker run --rm ghcr.io/adelerhof/k8s-backup:<tag>` is the smoke test.
# The job scripts (chapters 6-8) are called with --entrypoint / command.
# Exits non-zero if a tool is missing or doesn't run.
set -euo pipefail

show() {
	local name=$1 out
	shift
	out=$("$@" 2>&1)
	printf '%-22s %s\n' "${name}:" "${out%%$'\n'*}"
}

show etcdctl etcdctl version
show etcdutl etcdutl version
show proxmox-backup-client proxmox-backup-client version
show pg_dump pg_dump --version
show rsync rsync --version
show user id
