#!/usr/bin/env bash
# 01-provision-host.sh — base host hardening + rootless-container stack for
# the vymalo GitHub Actions runner VPS (Debian 13 / trixie).
#
# Idempotent: safe to re-run. Run as root.
set -euo pipefail

log() { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }

if [[ $EUID -ne 0 ]]; then echo "must run as root" >&2; exit 1; fi

# Make the bootstrap dir traversable and its helper scripts executable,
# regardless of how they were copied here (a strict scp/cp umask can drop +x).
# job-completed-cleanup.sh is exec'd by unprivileged runner users (the runner
# hook); podman-prune.sh and runner-health-watch.sh are timer ExecStarts.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chmod 0755 "$SELF_DIR"
chmod 0755 "$SELF_DIR"/*.sh 2>/dev/null || true

export DEBIAN_FRONTEND=noninteractive

log "apt update + base packages"
apt-get update -qq
apt-get install -y --no-install-recommends \
  podman buildah podman-docker podman-compose \
  fuse-overlayfs crun catatonit \
  slirp4netns passt uidmap \
  netavark aardvark-dns \
  dbus-user-session \
  iptables \
  sudo \
  ca-certificates curl jq git tar gzip unzip xz-utils zstd \
  acl \
  unattended-upgrades apt-listchanges \
  htop ncdu

# podman-compose is installed explicitly: --no-install-recommends drops it
# (podman-docker only *recommends* a compose provider), but the README's
# `docker compose` / compose smoke-test path needs one on the host.
# sudo is required by 02-stage-runners.sh (per-user setup) + register-runner.sh;
# a minimal Debian image may not ship it.

# --- host registries: resolve unqualified short names --------------------
# Debian ships registries.conf with NO unqualified-search-registries, so a
# host-native `buildah build` / `podman pull` of a short name (e.g. `alpine`)
# fails to resolve. Default the search to docker.io for host-native image jobs
# (issue: bare-metal buildah builds). Fully-qualified refs are unaffected.
log "registries: unqualified-search = docker.io"
mkdir -p /etc/containers/registries.conf.d
cat > /etc/containers/registries.conf.d/10-unqualified-search.conf <<'EOF'
unqualified-search-registries = ["docker.io"]
EOF

# --- verify the rootless container toolchain is wired up ------------------
log "verify netavark + aardvark-dns are discoverable by podman"
# On Debian they live under /usr/lib/podman; podman expects them there.
for bin in netavark aardvark-dns; do
  if [[ -x "/usr/lib/podman/$bin" ]]; then
    echo "ok: /usr/lib/podman/$bin"
  elif command -v "$bin" >/dev/null 2>&1; then
    echo "ok (on PATH): $(command -v "$bin")"
  else
    echo "WARN: $bin not found where podman expects it" >&2
  fi
done

# --- swap (heavy CI builds + tight MemoryMax need a safety buffer) --------
log "swap"
if ! swapon --show | grep -q '/swapfile'; then
  # Create with 0600 FIRST so the zero-filled file is never world-readable,
  # even briefly, while it's being allocated (CWE-377/732).
  touch /swapfile
  chmod 600 /swapfile
  fallocate -l 8G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=8192
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
else
  echo "swap already present"
fi

# --- sysctl tuning for CI workloads --------------------------------------
log "sysctl (inotify / map_count / sockets for CI)"
cat > /etc/sysctl.d/99-ci-runners.conf <<'EOF'
# File watchers — Flutter/Node/webpack/jest open a lot of them.
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
fs.inotify.max_queued_events = 32768
# Some toolchains (ES, sanitizers, large mmap) need a high map count.
vm.max_map_count = 262144
# Connection backlog for compose smoke tests / local servers.
net.core.somaxconn = 4096
# Plenty of user namespaces for rootless podman across runners.
user.max_user_namespaces = 280000
EOF
sysctl --system >/dev/null

# --- pam limits (interactive sessions; systemd services set their own) ----
# Keyed on the `runners` group rather than hardcoded usernames, so scaling
# NUM_RUNNERS in 02-stage-runners.sh needs no edit here. That script adds each
# runner user to this group.
log "ulimits for the runners group"
groupadd -f runners
cat > /etc/security/limits.d/90-ci-runners.conf <<'EOF'
@runners  soft  nofile  65536
@runners  hard  nofile  1048576
*  soft  nproc  32768
*  hard  nproc  65536
EOF

# --- unattended security upgrades ----------------------------------------
log "unattended-upgrades (security only, no auto-reboot)"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true

# --- time sync ------------------------------------------------------------
log "time sync"
timedatectl set-ntp true 2>/dev/null || true

# --- parent slice for all runners (grouping; caps live per-service) -------
log "systemd parent slice for runners"
cat > /etc/systemd/system/runners.slice <<'EOF'
[Unit]
Description=GitHub Actions self-hosted runners (vymalo)
Before=slices.target

[Slice]
# Soft umbrella; hard per-runner caps are set on each runner service.
# Keeps all runners in one visible cgroup subtree: systemctl status runners.slice
EOF

# --- periodic container-storage prune ------------------------------------
# Persistent runners accumulate pulled base images + buildah --layers cache.
# A daily timer reclaims stale storage (full prune only under disk pressure).
log "podman-prune timer (reclaim rootless image storage)"
cat > /etc/systemd/system/podman-prune.service <<'EOF'
[Unit]
Description=Prune rootless container storage on the GitHub runner host

[Service]
Type=oneshot
ExecStart=/opt/runners-bootstrap/podman-prune.sh
Nice=10
IOSchedulingClass=idle
EOF
cat > /etc/systemd/system/podman-prune.timer <<'EOF'
[Unit]
Description=Daily rootless container storage prune

[Timer]
OnCalendar=*-*-* 04:30:00
RandomizedDelaySec=20min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now podman-prune.timer >/dev/null 2>&1 || true

# --- runner health watchdog ----------------------------------------------
# Detect a wedged / memory-starved runner early (memory PSI + oom_kill delta +
# D-state tasks) so a stuck job surfaces in minutes, not after hours. Read-only —
# it reports (journal WARN + optional webhook), never kills. See the 2026-07-02
# ~19h wedge (arc-runners#8); MemorySwapMax=0 prevents the wedge, this catches
# the pressure/OOM symptoms that precede or replace it.
log "runner-health-watch timer (early wedge/starvation detection)"
cat > /etc/systemd/system/runner-health-watch.service <<'EOF'
[Unit]
Description=Detect wedged/memory-starved GitHub runner cgroups (report-only)

[Service]
Type=oneshot
ExecStart=/opt/runners-bootstrap/runner-health-watch.sh
Nice=10
EOF
cat > /etc/systemd/system/runner-health-watch.timer <<'EOF'
[Unit]
Description=Poll runner cgroup health every 2 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
AccuracySec=15s

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now runner-health-watch.timer >/dev/null 2>&1 || true

log "host provisioning complete"
podman --version
buildah --version
