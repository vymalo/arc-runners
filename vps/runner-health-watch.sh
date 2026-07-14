#!/usr/bin/env bash
# runner-health-watch.sh — detect a wedged / memory-starved runner EARLY.
#
# Context: on 2026-07-02 a host-native image build blew past its cgroup memory
# cap and, because swap was enabled, thrashed in D-state (unkillable) for ~19h
# before anyone noticed — the only symptom was a runner "disappearing" from the
# org list. `MemorySwapMax=0` now converts that into a fast OOM-kill, but we still
# want to SEE pressure/OOM/stall events instead of finding out hours later. This
# is the detection layer: a systemd timer runs it every couple of minutes and it
# logs a WARN (and optionally POSTs a webhook) when a runner cgroup is unhealthy.
#
# Signals, per cgroup (agent service AND the runner's user-<uid>.slice):
#   - memory PSI  : `memory.pressure` "some avg60" — sustained stall = thrashing
#                   or heavy reclaim (the pre-wedge / starvation symptom).
#   - OOM kills   : `memory.events` oom_kill delta since last run — a job hit its
#                   cap and was killed (expected fail-fast, but worth surfacing:
#                   repeated kills mean an undersized cap or an oversized build).
#   - D-state     : any task stuck in uninterruptible sleep — the actual wedge
#                   fingerprint (also catches non-memory I/O hangs).
#
# Idempotent, read-only (never kills anything — it only reports). Run as root
# (needs to read every cgroup + /proc). Exit 0 always; a monitor must not flap.
set -uo pipefail

# ---- tunables (override via /etc/runner-health-watch.env) ----------------
PSI_WARN="${PSI_WARN:-20}"          # WARN when memory PSI "some avg60" >= this (%)
DISK_WARN="${DISK_WARN:-80}"        # WARN when the storage FS is >= this (% used)
STATE_DIR="${STATE_DIR:-/run/runner-health-watch}"   # tmpfs: oom_kill baselines
WEBHOOK_URL="${WEBHOOK_URL:-}"      # optional: POST a JSON alert on WARN
CG_ROOT=/sys/fs/cgroup
# Sourcing an env file lets ops set a webhook / thresholds without editing this.
[[ -r /etc/runner-health-watch.env ]] && . /etc/runner-health-watch.env

mkdir -p "$STATE_DIR"
warnings=()   # collected WARN lines for this pass (also drives the webhook)

log() { logger -t runner-health -p "daemon.${1}" -- "${2}" 2>/dev/null || true; }

# float ">=" via awk. Kept intentionally over a pure-bash scaling trick: the latter
# breaks on a non-integer PSI_WARN (e.g. "20.5"), and fge runs only ~6x per 2-min
# tick, so the fork cost is negligible. awk exits 0 when a>=b.
fge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>=b)}'; }

# check_cgroup <label> <cgroup-abs-path>
check_cgroup() {
  local label="$1" cg="$2"
  [[ -d "$cg" ]] || return 0

  # --- memory PSI (avg60 of "some") — pure-bash parse, no fork -----------
  local psi=0 line
  if [[ -r "$cg/memory.pressure" ]]; then
    while read -r line; do
      if [[ "$line" == some* ]]; then
        psi="${line##*avg60=}"; psi="${psi%% *}"
        break
      fi
    done < "$cg/memory.pressure"
    psi="${psi:-0}"
  fi

  # --- OOM-kill delta since last pass -----------------------------------
  local oomk=0 last=0 delta=0 ev_name ev_val
  if [[ -r "$cg/memory.events" ]]; then
    while read -r ev_name ev_val; do
      [[ "$ev_name" == oom_kill ]] && { oomk="$ev_val"; break; }
    done < "$cg/memory.events"
    oomk="${oomk:-0}"
  fi
  local statef safe_label last_raw
  safe_label="${label//[^A-Za-z0-9_.-]/_}"
  statef="$STATE_DIR/${safe_label}.oomk"
  # Validate: a truncated/garbage state file must not blow up the arithmetic below.
  if [[ -r "$statef" ]]; then
    last_raw="$(< "$statef")"
    [[ "$last_raw" =~ ^[0-9]+$ ]] && last="$last_raw"
  fi
  # oom_kill only grows within a boot; on reboot the cgroup counter resets to 0
  # and so does tmpfs state, so a plain delta is correct.
  delta=$(( oomk - last ))
  (( delta < 0 )) && delta=0
  echo "$oomk" > "$statef"

  # --- D-state tasks in this cgroup -------------------------------------
  # Iterate THREADS, not just TGIDs: a multithreaded process (buildah/podman/.NET)
  # can have a worker thread wedged in D while its leader is in interruptible sleep,
  # which cgroup.procs (leaders only) would miss. Pure-bash stat parse, no fork:
  # strip up to the last ')' (comm may contain spaces/parens), then take the state.
  local dcount=0 tid sline st
  if [[ -r "$cg/cgroup.threads" ]]; then
    while read -r tid; do
      if read -r sline < "/proc/$tid/stat" 2>/dev/null; then
        st="${sline##*)}"; st="${st:1:1}"
        [[ "$st" == "D" ]] && dcount=$(( dcount + 1 ))
      fi
    done < "$cg/cgroup.threads"
  fi

  # --- verdict ----------------------------------------------------------
  local cur="?" max="?"
  [[ -r "$cg/memory.current" ]] && cur="$(cat "$cg/memory.current")"
  [[ -r "$cg/memory.max" ]] && max="$(cat "$cg/memory.max")"

  local issues=()
  fge "$psi" "$PSI_WARN" && issues+=("mem-PSI(some avg60)=${psi}%>=${PSI_WARN}%")
  (( delta > 0 )) && issues+=("oom_kill+${delta}")
  (( dcount > 0 )) && issues+=("D-state tasks=${dcount}")

  if (( ${#issues[@]} > 0 )); then
    local msg="UNHEALTHY ${label}: ${issues[*]} (mem ${cur}/${max})"
    log warning "$msg"
    warnings+=("$msg")
  fi
}

# ---- sweep every runner: agent service cgroup + its user slice -----------
shopt -s nullglob
for svc_cg in "$CG_ROOT"/runners.slice/actions.runner.*.service; do
  svc="${svc_cg##*/}"
  check_cgroup "agent:${svc#actions.runner.}" "$svc_cg"
  # map the service to its user slice via the unit's User=
  user="$(systemctl show -p User --value "$svc" 2>/dev/null || true)"
  if [[ -n "$user" ]]; then
    uid="$(id -u "$user" 2>/dev/null || true)"
    [[ -n "$uid" ]] && check_cgroup "user:${user}" "$CG_ROOT/user.slice/user-${uid}.slice"
  fi
done

# ---- disk pressure on the storage FS (rootless stores live under /home) ---
# A full disk is what makes container: builds die with "No space left on device"
# yet leaves the cgroups healthy — so it is invisible to the checks above. This
# is the early signal that was missing before the disk-full incident; the daily
# prune + per-job cleanup do the reclaiming, this only reports.
disk_usage=$(df --output=pcent /home 2>/dev/null | tail -1 | tr -dc '0-9')
[[ -n "$disk_usage" ]] || disk_usage=$(df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9')
if [[ -n "$disk_usage" ]] && (( disk_usage >= DISK_WARN )); then
  msg="UNHEALTHY disk: storage FS at ${disk_usage}% used (>=${DISK_WARN}%)"
  log warning "$msg"
  warnings+=("$msg")
fi

# ---- optional webhook on any WARN ----------------------------------------
if (( ${#warnings[@]} > 0 )) && [[ -n "$WEBHOOK_URL" ]]; then
  # best-effort; a down webhook must never fail the monitor. jq-free JSON escaping
  # in pure bash: escape backslashes then quotes per line, join with literal \n.
  body=""
  for w in "${warnings[@]}"; do
    w="${w//\\/\\\\}"; w="${w//\"/\\\"}"
    body="${body:+${body}\\n}${w}"
  done
  curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
    -d "{\"text\":\"[runner-health] ${HOSTNAME:-$(hostname)}: ${body}\"}" \
    "$WEBHOOK_URL" >/dev/null 2>&1 || log warning "webhook POST failed"
fi

exit 0
