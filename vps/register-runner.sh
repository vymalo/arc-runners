#!/usr/bin/env bash
# register-runner.sh — register + install + start ONE staged runner.
#
# Usage:
#   sudo ./register-runner.sh <index> <registration-token>
#
#   <index>  1 | 2 | 3  (matches the staged runner-<index> user)
#   <token>  org registration token from
#            https://github.com/organizations/vymalo/settings/actions/runners/new
#            (the short-lived "token" value, NOT a PAT)
#
# This is the "do it all" convenience path. If you prefer to drive it by hand
# with ./svc.sh, see README.md — the resource caps apply either way because the
# systemd drop-in was pre-staged.
set -euo pipefail

ORG="vymalo"
URL="https://github.com/${ORG}"
LABELS="self-hosted,linux,x64,podman,vymalo-vps"

idx="${1:?usage: register-runner.sh <index> <token>}"
token="${2:?usage: register-runner.sh <index> <token>}"
USER="runner-${idx}"
NAME="vps-runner-${idx}"
RUN_DIR="/home/${USER}/actions-runner"

[[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }
[[ -x "${RUN_DIR}/config.sh" ]] || { echo "runner ${idx} not staged at ${RUN_DIR}" >&2; exit 1; }

echo "==> configuring ${NAME} as user ${USER}"
# Pass values as positional args ($1..$4), never interpolated into the script
# body — the registration token is short-lived but could still contain shell
# metacharacters; this avoids any quoting/expansion surprise.
sudo -u "$USER" bash -s -- "$RUN_DIR" "$URL" "$token" "$NAME" "$LABELS" <<'INNER'
cd "$1" && ./config.sh \
  --url "$2" \
  --token "$3" \
  --name "$4" \
  --labels "$5" \
  --work _work \
  --unattended --replace
INNER

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
