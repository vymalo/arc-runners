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
# Hand the token to the child via the EXPORTED environment + sudo --preserve-env,
# NOT as `sudo VAR=val` (which would put the token in sudo's own argv, visible in
# /proc/<pid>/cmdline). config flags go via positional args ($1..$4).
export RUNNER_TOKEN="$token"
sudo -u "$USER" --preserve-env=RUNNER_TOKEN bash -s -- "$RUN_DIR" "$URL" "$NAME" "$LABELS" <<'INNER'
cd "$1" && ./config.sh \
  --url "$2" \
  --token "$RUNNER_TOKEN" \
  --name "$3" \
  --labels "$4" \
  --work _work \
  --unattended --replace
INNER

# Take the tree root-owned for the privileged install: this closes the TOCTOU
# window where a concurrent (compromised) runner-user process could swap svc.sh
# or its helpers between extraction and root execution. Restored to the runner
# user on exit (even on failure) so the service can run as that user.
echo "==> refreshing root-run svc.sh from cache + installing service"
restore_owner() { chown -R "${USER}:${USER}" "$RUN_DIR"; }
trap restore_owner EXIT
chown -R root:root "$RUN_DIR"

# Re-extract svc.sh from the immutable root-owned cache so the root-executed
# helper is pristine. Pick the HIGHEST-version tarball (matches what staging
# installed — the staging script always fetches latest), not the lexicographic
# first, in case multiple releases are cached.
cache="$(ls -1 /opt/actions-runner-cache/actions-runner-linux-x64-*.tar.gz 2>/dev/null | sort -V | tail -1)"
if [[ -n "$cache" ]]; then
  tar -xzf "$cache" -C "$RUN_DIR" ./svc.sh
  chmod 0755 "${RUN_DIR}/svc.sh"
else
  echo "   (cache tarball not found — using on-disk svc.sh; ensure it's untampered)" >&2
fi

cd "$RUN_DIR"
./svc.sh install "$USER"
restore_owner            # hand the tree back before starting (service runs as $USER)
trap - EXIT
systemctl daemon-reload  # ensure the pre-staged resource drop-in binds
./svc.sh start

echo "==> status"
systemctl status "actions.runner.${ORG}.${NAME}.service" --no-pager -l | head -n 15 || true
echo
systemctl show "actions.runner.${ORG}.${NAME}.service" \
  -p CPUQuotaPerSecUSec -p MemoryMax -p Slice 2>/dev/null || true
echo "==> ${NAME} registered. Verify at https://github.com/organizations/${ORG}/settings/actions/runners"
