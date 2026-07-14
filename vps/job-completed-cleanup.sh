#!/usr/bin/env bash
# ACTIONS_RUNNER_HOOK_JOB_COMPLETED hook — runs on the HOST as the runner user
# after every job. Wired in via each runner's .env (see 02-stage-runners.sh).
#
# Does two jobs, both scoped to THIS runner user so a concurrent job on another
# runner is never touched (each runner = its own user + its own rootless store,
# and a persistent runner runs one job at a time, so there is no same-user job
# in flight here either):
#
#   1. WIPE REGISTRY AUTH. These runners are PERSISTENT, not ephemeral. A job that
#      runs `buildah login` / `docker login ghcr.io` (e.g. the image-push jobs)
#      leaves a credential in the runner user's auth files. Its GITHUB_TOKEN
#      expires when the job ends, but the file persists — so the NEXT container:
#      job's image pull reuses that stale token and gets `403 Forbidden` from ghcr
#      instead of pulling the public image anonymously. Wiping registry auth after
#      every job makes each job start clean (jobs that need a registry log in
#      themselves), exactly like an ephemeral runner would.
#
#   2. RECLAIM SPACE. Persistent runners accumulate two things:
#      a) leftover /tmp scratch from build steps that `mktemp -d` and never clean
#         up. /tmp is a RAM-backed tmpfs on Debian trixie (~50% of RAM), so this
#         scratch fills the tmpfs AND permanently pins RAM. A full /tmp is what
#         makes `container:` builds die with "No space left on device" even though
#         the disk has hundreds of GB free — the actual disk-full incident cause.
#         Swept unconditionally below (this user's entries only).
#      b) this user's rootless podman store (images/build cache/volumes) on the
#         disk under /home. Mirrors podman-prune.sh's "light always, full only
#         under disk pressure" policy, but at PER-JOB frequency so pressure is
#         caught within one job instead of waiting for the prune timer window.
#
# Root-owned + only referenced by path, so a job can't tamper with this script.
set +e

DISK_PCT="${CLEANUP_DISK_PCT:-80}"   # full-prune trigger (% used); above the daily
                                     # 75% since this runs far more often.

uid="$(id -u)"
me="$(id -un)"
rtd="${XDG_RUNTIME_DIR:-/run/user/${uid}}"

# ---- 1. wipe registry auth ------------------------------------------------
# Guard each base path so an empty HOME/rtd can't turn into a root-relative rm.
[[ -n "${HOME:-}" ]] && rm -f \
  "${HOME}/.docker/config.json" \
  "${HOME}/.config/containers/auth.json"
[[ -n "${rtd:-}" ]] && rm -f "${rtd}/containers/auth.json"

# ---- 2. reclaim disk ------------------------------------------------------
pod() { XDG_RUNTIME_DIR="$rtd" podman "$@" >/dev/null 2>&1; }

# Leftover /tmp scratch OWNED BY THIS runner user (build steps that mktemp -d /tmp
# and leave it behind). User-scoped so a concurrent runner's live /tmp is safe.
[[ -n "$me" ]] && find /tmp -mindepth 1 -maxdepth 1 -user "$me" \
  -exec rm -rf {} + 2>/dev/null

# Always: drop this user's stopped containers (cheap, no image/cache loss).
pod container prune -f

# Under disk pressure only: hard claw-back of ALL unused images + build cache +
# volumes for this user. Accepts a cold re-pull/rebuild next run — far cheaper
# than a job failing on a full disk. Nothing is meant to persist across jobs on
# an ephemeral-style runner, so unused volumes are fair game.
# Query the runner user's own $HOME — where its rootless store lives — so we
# check the right FS without assuming the host's /home layout. 10# forces base-10
# so an operator-set leading-zero threshold (e.g. DISK_PCT=08) can't trip bash's
# octal parser (df itself never zero-pads, so $usage is always plain like "8").
usage=$(df --output=pcent "${HOME:-/}" 2>/dev/null | tail -1 | tr -dc '0-9')
if [[ -n "$usage" ]] && (( 10#$usage >= 10#$DISK_PCT )); then
  pod system prune -af --volumes
fi

# Never fail the job on cleanup trouble.
exit 0
