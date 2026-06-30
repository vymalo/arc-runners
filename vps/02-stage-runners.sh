#!/usr/bin/env bash
# 02-stage-runners.sh — create N isolated runner users, wire up rootless
# Podman per user, download the actions-runner package into each home, and
# pre-stage the systemd resource-cap drop-ins so each runner is hard-limited
# to its own slice of the box. Does NOT register to GitHub (that needs a
# token — see register-runner.sh / README).
#
# Idempotent. Run as root.
set -euo pipefail

# ---- config -------------------------------------------------------------
# A runner's footprint is split across TWO cgroups: the agent (a system service
# under runners.slice) and its build containers (under the user's slice). They
# have independent quotas, so the per-runner ceiling is the SUM. Keep the agent
# budget small (it only orchestrates) so the headline total stays honest:
#   agent 1 GiB + containers 9 GiB = 10 GiB per runner  ×3 = 30 GiB ≤ 31 GiB host.
NUM_RUNNERS=3
CONTAINER_CPU_QUOTA="400%"   # 4 vCPU ceiling for the build workload (user slice)
CONTAINER_MEM_MAX="9G"       # hard cap for build containers — the real workload
CONTAINER_MEM_HIGH="8500M"   # soft throttle before the hard cap
AGENT_CPU_QUOTA="100%"       # the .NET listener/worker does no heavy lifting
AGENT_MEM_MAX="1G"
AGENT_MEM_HIGH="768M"
MEM_SWAP_MAX="2G"            # limited swap per cgroup under pressure
ORG="vymalo"   # runner labels are applied at registration — see register-runner.sh
SUBID_SIZE=65536
SUBID_BASE=100000

log() { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
if [[ $EUID -ne 0 ]]; then echo "must run as root" >&2; exit 1; fi

# ---- resolve latest actions-runner release ------------------------------
# Use GITHUB_TOKEN when present: the unauthenticated API is 60 req/h per IP,
# which a shared VPS can exhaust (re-runs, CI, neighbours behind the same NAT).
log "resolving latest actions/runner release"
curl_auth=()
[[ -n "${GITHUB_TOKEN:-}" ]] && curl_auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
RUNNER_VERSION="$(curl -fsSL "${curl_auth[@]}" https://api.github.com/repos/actions/runner/releases/latest \
  | jq -r '.tag_name' | sed 's/^v//')"
[[ -n "$RUNNER_VERSION" && "$RUNNER_VERSION" != "null" ]] || { echo "could not resolve runner version" >&2; exit 1; }
TARBALL="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${TARBALL}"
CACHE="/opt/actions-runner-cache/${TARBALL}"
echo "runner version: ${RUNNER_VERSION}"

mkdir -p /opt/actions-runner-cache
if [[ ! -f "$CACHE" ]]; then
  log "downloading ${TARBALL}"
  # Download to a temp path and rename only on success, so an interrupted fetch
  # never leaves a truncated file that a re-run mistakes for a valid cache hit.
  curl -fsSL -o "${CACHE}.part" "$URL" && mv -f "${CACHE}.part" "$CACHE"
fi

for i in $(seq 1 "$NUM_RUNNERS"); do
  USER="runner-${i}"
  NAME="vps-runner-${i}"
  HOME_DIR="/home/${USER}"
  RUN_DIR="${HOME_DIR}/actions-runner"

  log "=== ${USER} (registers as ${NAME}) ==="

  # --- user -------------------------------------------------------------
  # `runners` group carries the PAM ulimits set in 01-provision-host.sh.
  groupadd -f runners
  if ! id "$USER" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash -G runners "$USER"
  else
    usermod -aG runners "$USER"
  fi
  UID_N="$(id -u "$USER")"

  # --- non-overlapping subuid/subgid ranges for rootless podman ---------
  start=$(( SUBID_BASE + (i - 1) * SUBID_SIZE ))
  range="${start}-$(( start + SUBID_SIZE - 1 ))"
  if ! grep -q "^${USER}:" /etc/subuid; then
    usermod --add-subuids "$range" "$USER"
  fi
  if ! grep -q "^${USER}:" /etc/subgid; then
    usermod --add-subgids "$range" "$USER"
  fi

  # --- linger so /run/user/<uid> + user systemd exist at boot -----------
  loginctl enable-linger "$USER"
  # give logind a moment to spin up the runtime dir
  for _ in $(seq 1 20); do [[ -d "/run/user/${UID_N}" ]] && break; sleep 0.3; done
  if [[ ! -d "/run/user/${UID_N}" ]]; then
    echo "ERROR: /run/user/${UID_N} not created — is systemd-logind running?" >&2
    exit 1
  fi

  RTD="/run/user/${UID_N}"
  USERCTL=(sudo -u "$USER" XDG_RUNTIME_DIR="$RTD" DBUS_SESSION_BUS_ADDRESS="unix:path=${RTD}/bus")

  # --- initialise rootless podman + enable the docker-compat socket -----
  "${USERCTL[@]}" podman info >/dev/null 2>&1 || true
  "${USERCTL[@]}" systemctl --user enable --now podman.socket
  echo "podman socket: ${RTD}/podman/podman.sock"

  # --- download + extract the runner ------------------------------------
  # Extract AND install OS deps while the tree is still root-owned, BEFORE
  # handing it to the unprivileged user. Once chowned, a job running as that
  # user could rewrite bin/installdependencies.sh; re-running this script as
  # root must never exec a user-writable script. So deps run once, here only.
  mkdir -p "$RUN_DIR"
  if [[ ! -x "${RUN_DIR}/config.sh" ]]; then
    tar -xzf "$CACHE" -C "$RUN_DIR"
    # runner OS deps (libicu, etc.) — output kept visible for debugging.
    DEBIAN_FRONTEND=noninteractive "${RUN_DIR}/bin/installdependencies.sh"
  fi
  chown -R "${USER}:${USER}" "$RUN_DIR"

  # --- .env: inject the docker-compat socket into every job's environment -
  # DOCKER_HOST points at /var/run/docker.sock, NOT the raw /run/user/<uid>
  # path: the latter does not exist inside a container: job (only the bind-
  # mounted /var/run/docker.sock does), and on host jobs the runner service's
  # private mount ns resolves /var/run/docker.sock to the same rootless socket.
  # One value that works in both contexts.
  # rm -f first: after the first run this dir is runner-owned, so a prior job
  # could swap .env for a symlink to a root file; removing the link (not its
  # target) before writing prevents a root-following clobber (TOCTOU).
  rm -f "${RUN_DIR}/.env"
  cat > "${RUN_DIR}/.env" <<EOF
XDG_RUNTIME_DIR=${RTD}
DOCKER_HOST=unix:///var/run/docker.sock
DOCKER_BUILDKIT=0
ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/opt/runners-bootstrap/job-completed-cleanup.sh
EOF
  # 0600: the .env is the conventional place secrets get added later; keep it
  # owner-only from the start rather than relying on the caller's umask.
  chown "${USER}:${USER}" "${RUN_DIR}/.env"
  chmod 600 "${RUN_DIR}/.env"

  # --- pre-stage the systemd resource-cap drop-in -----------------------
  # The unit svc.sh will create is actions.runner.<ORG>.<NAME>.service.
  # This drop-in exists ahead of time; svc.sh's daemon-reload picks it up.
  DROPDIR="/etc/systemd/system/actions.runner.${ORG}.${NAME}.service.d"
  mkdir -p "$DROPDIR"
  cat > "${DROPDIR}/10-resources.conf" <<EOF
[Unit]
# Order after the user manager that owns the rootless podman.socket which
# BindPaths (below) depends on.
After=user@${UID_N}.service
Wants=user@${UID_N}.service

[Service]
# The stock actions-runner unit sets NO Restart=, so if BindPaths loses the
# boot race against the user's podman.socket the runner would stay down. Add an
# explicit restart policy: a failed start retries until the socket exists.
Restart=always
RestartSec=5
# --- resource bound for the runner AGENT process ---
# NOTE: this caps only the .NET listener/worker (kept deliberately small — it
# only orchestrates). Rootless build CONTAINERS run under user-<uid>.slice and
# are capped separately below; the per-runner total is agent + container slice.
Slice=runners.slice
CPUQuota=${AGENT_CPU_QUOTA}
CPUWeight=100
MemoryMax=${AGENT_MEM_MAX}
MemoryHigh=${AGENT_MEM_HIGH}
MemorySwapMax=${MEM_SWAP_MAX}
TasksMax=12288
IOWeight=100
LimitNOFILE=1048576
LimitNPROC=65536
# --- rootless podman wiring for the runner agent ---
Environment=XDG_RUNTIME_DIR=${RTD}
Environment=DOCKER_HOST=unix:///var/run/docker.sock
# GitHub's runner unconditionally bind-mounts /var/run/docker.sock into every
# container: job. podman-docker symlinks that to /run/podman/podman.sock (the
# ROOTFUL socket, which we don't run), so it dangles and 'docker create' fails
# with 'statfs /var/run/docker.sock: no such file or directory'. Give this
# runner a PRIVATE mount namespace where that target is its own rootless
# socket — per-runner, no cross-user conflict, stays rootless.
BindPaths=${RTD}/podman/podman.sock:/run/podman/podman.sock
EOF

  # --- cap the USER slice: this is where the real workload runs ---------
  # Rootless containers launched via DOCKER_HOST are created by the user's
  # podman service under user-<uid>.slice, which is UNCAPPED by default. Without
  # this, a container: build escapes the runner-agent cap above and can consume
  # the whole box, starving the other runners. One dedicated user per runner, so
  # capping its slice bounds that runner's entire container footprint.
  USLICEDIR="/etc/systemd/system/user-${UID_N}.slice.d"
  mkdir -p "$USLICEDIR"
  cat > "${USLICEDIR}/10-runner-cap.conf" <<EOF
[Slice]
CPUQuota=${CONTAINER_CPU_QUOTA}
MemoryMax=${CONTAINER_MEM_MAX}
MemoryHigh=${CONTAINER_MEM_HIGH}
MemorySwapMax=${MEM_SWAP_MAX}
TasksMax=24576
EOF

  echo "staged: ${RUN_DIR}  (cap: ${CONTAINER_CPU_QUOTA} CPU / ${CONTAINER_MEM_MAX} containers + ${AGENT_MEM_MAX} agent)"
done

systemctl daemon-reload
log "all runners staged. registration token still required — see README."
echo "actions-runner version: ${RUNNER_VERSION}"
