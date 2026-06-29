#!/usr/bin/env bash
# register-runner.sh — register + install + start ONE staged runner.
#
# Usage:
#   sudo RUNNER_TOKEN=<token> ./register-runner.sh <index>
#   # or, interactively (token is prompted, never echoed):
#   sudo ./register-runner.sh <index>
#
#   <index>        1 | 2 | 3  (matches the staged runner-<index> user)
#   RUNNER_TOKEN   org registration token from
#                  https://github.com/organizations/vymalo/settings/actions/runners/new
#                  (the short-lived "token" value, NOT a PAT)
#
# The token is read from the environment or prompted — NOT taken as a CLI arg —
# so it never lands in this script's /proc/<pid>/cmdline, which is world-readable
# and would otherwise leak the token to jobs running under the other runner
# users. (It is still briefly visible in config.sh's own argv while it runs;
# that is upstream actions-runner behaviour we can't avoid here.)
#
# This is the "do it all" convenience path. If you prefer to drive it by hand
# with ./svc.sh, see README.md — the resource caps apply either way because the
# systemd drop-in was pre-staged.
#
# SECURITY NOTE: re-running this against a runner that has already executed
# untrusted (e.g. fork-PR) jobs is unsafe — those jobs can write the runner tree
# and this script runs parts of it as root. Re-register only fresh/trusted
# runners, or use ephemeral runners for untrusted workloads.
set -euo pipefail

ORG="vymalo"
URL="https://github.com/${ORG}"
LABELS="self-hosted,linux,x64,podman,vymalo-vps"

idx="${1:?usage: sudo RUNNER_TOKEN=<token> register-runner.sh <index>}"
USER="runner-${idx}"
NAME="vps-runner-${idx}"
RUN_DIR="/home/${USER}/actions-runner"

[[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }
[[ -x "${RUN_DIR}/config.sh" ]] || { echo "runner ${idx} not staged at ${RUN_DIR}" >&2; exit 1; }

token="${RUNNER_TOKEN:-}"
if [[ -z "$token" ]]; then
  read -rsp "Registration token for ${NAME}: " token; echo
fi
[[ -n "$token" ]] || { echo "no token provided (set RUNNER_TOKEN or enter when prompted)" >&2; exit 1; }

echo "==> configuring ${NAME} as user ${USER}"
# Token is handed to the child via the environment (env is owner/root-readable
# only — unlike argv), and config flags via positional args ($1..$4).
sudo -u "$USER" RUNNER_TOKEN="$token" bash -s -- "$RUN_DIR" "$URL" "$NAME" "$LABELS" <<'INNER'
cd "$1" && ./config.sh \
  --url "$2" \
  --token "$RUNNER_TOKEN" \
  --name "$3" \
  --labels "$4" \
  --work _work \
  --unattended --replace
INNER

# Re-extract svc.sh from the immutable root-owned cache before running it as
# root, so a job that tampered with the (runner-owned) tree can't get a doctored
# svc.sh executed with root privileges.
echo "==> refreshing root-run svc.sh from cache"
cache=(/opt/actions-runner-cache/actions-runner-linux-x64-*.tar.gz)
if [[ -f "${cache[0]}" ]]; then
  tar -xzf "${cache[0]}" -C "$RUN_DIR" ./svc.sh
  chown root:root "${RUN_DIR}/svc.sh"
  chmod 0755 "${RUN_DIR}/svc.sh"
else
  echo "   (cache tarball not found — using on-disk svc.sh; ensure it's untampered)" >&2
fi

echo "==> installing + starting service"
cd "$RUN_DIR"
./svc.sh install "$USER"
systemctl daemon-reload          # ensure the pre-staged resource drop-in binds
./svc.sh start

echo "==> status"
systemctl status "actions.runner.${ORG}.${NAME}.service" --no-pager -l | head -n 15 || true
echo
systemctl show "actions.runner.${ORG}.${NAME}.service" \
  -p CPUQuotaPerSecUSec -p MemoryMax -p Slice 2>/dev/null || true
echo "==> ${NAME} registered. Verify at https://github.com/organizations/${ORG}/settings/actions/runners"
