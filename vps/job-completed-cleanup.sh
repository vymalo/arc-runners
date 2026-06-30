#!/usr/bin/env bash
# ACTIONS_RUNNER_HOOK_JOB_COMPLETED hook — runs on the HOST as the runner user
# after every job. Wired in via each runner's .env (see 02-stage-runners.sh).
#
# WHY: these runners are PERSISTENT, not ephemeral. A job that runs
# `buildah login` / `docker login ghcr.io` (e.g. the image-push jobs) leaves a
# credential in the runner user's auth files. Its GITHUB_TOKEN expires when the
# job ends, but the file persists — so the NEXT container: job's image pull
# reuses that stale token and gets `403 Forbidden` from ghcr instead of pulling
# the public image anonymously. Wiping registry auth after every job makes each
# job start clean (jobs that need a registry log in themselves), exactly like an
# ephemeral runner would.
#
# Root-owned + only referenced by path, so a job can't tamper with this script.
set +e

uid="$(id -u)"
rtd="${XDG_RUNTIME_DIR:-/run/user/${uid}}"

rm -f \
  "${HOME}/.docker/config.json" \
  "${HOME}/.config/containers/auth.json" \
  "${rtd}/containers/auth.json"

# Never fail the job on cleanup trouble.
exit 0
