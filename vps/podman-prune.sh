#!/usr/bin/env bash
# podman-prune.sh — reclaim rootless container storage on the persistent runners.
# Driven by podman-prune.timer (daily). Per runner user:
#   * LIGHT prune always — dangling images, stopped containers, networks, and
#     build cache OLDER than PRUNE_KEEP_HOURS (default 7d). The age filter keeps
#     the hot arc-runners base image + recent `buildah --layers` cache so normal
#     builds stay fast; only stale junk is reclaimed.
#   * FULL prune only under disk pressure — if the storage filesystem is at/above
#     PRUNE_DISK_PCT (default 75%), also drop ALL unused images + volumes to claw
#     space back, accepting a cold re-pull/rebuild next run.
#
# Runs as root (from the timer); each prune is executed AS the runner user since
# rootless storage lives in that user's home. Safe to run during jobs: prune only
# removes UNUSED resources — an in-flight build's layers are referenced and kept.
set +e

KEEP_HOURS="${PRUNE_KEEP_HOURS:-168}"   # keep images/cache newer than this
DISK_PCT="${PRUNE_DISK_PCT:-75}"        # full-prune trigger (% used)

log() { printf '%s podman-prune: %s\n' "$(date -Is)" "$*"; }

usage=$(df --output=pcent /home 2>/dev/null | tail -1 | tr -dc '0-9')
[[ -n "$usage" ]] || usage=$(df --output=pcent / | tail -1 | tr -dc '0-9')
log "storage FS at ${usage}% used (full-prune threshold ${DISK_PCT}%, keep<${KEEP_HOURS}h)"

for u in $(getent passwd | awk -F: '$1 ~ /^runner-[0-9]+$/ {print $1}'); do
  uid=$(id -u "$u" 2>/dev/null) || continue
  rtd="/run/user/${uid}"
  [[ -d "$rtd" ]] || { log "$u: no runtime dir — skip"; continue; }
  pod() { sudo -u "$u" XDG_RUNTIME_DIR="$rtd" podman "$@" 2>&1; }

  out=$(pod system prune -f --filter "until=${KEEP_HOURS}h")
  log "$u: light prune — $(printf '%s' "$out" | grep -i reclaimed || echo 'nothing to reclaim')"

  if (( usage >= DISK_PCT )); then
    out=$(pod system prune -af --volumes)
    log "$u: FULL prune (disk pressure) — $(printf '%s' "$out" | grep -i reclaimed || echo 'nothing to reclaim')"
  fi
done
log "done"
