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
STATE_DIR="${STATE_DIR:-/run/runner-health-watch}"   # tmpfs: oom_kill baselines
WEBHOOK_URL="${WEBHOOK_URL:-}"      # optional: POST a JSON alert on WARN
CG_ROOT=/sys/fs/cgroup
# Sourcing an env file lets ops set a webhook / thresholds without editing this.
[[ -r /etc/runner-health-watch.env ]] && . /etc/runner-health-watch.env

mkdir -p "$STATE_DIR"
warnings=()   # collected WARN lines for this pass (also drives the webhook)

log() { logger -t runner-health -p "daemon.${1}" -- "${2}" 2>/dev/null || true; }

# float ">=" without bc: awk exits 0 when a>=b
fge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>=b)}'; }

# check_cgroup <label> <cgroup-abs-path>
check_cgroup() {
  local label="$1" cg="$2"
  [[ -d "$cg" ]] || return 0

  # --- memory PSI (avg60 of "some") -------------------------------------
  local psi=0
  if [[ -r "$cg/memory.pressure" ]]; then
    psi="$(awk '/^some /{for(i=1;i<=NF;i++){if($i ~ /^avg60=/){sub(/avg60=/,"",$i);print $i;exit}}}' \
      "$cg/memory.pressure" 2>/dev/null)"
    psi="${psi:-0}"
  fi

  # --- OOM-kill delta since last pass -----------------------------------
  local oomk=0 last=0 delta=0
  if [[ -r "$cg/memory.events" ]]; then
    oomk="$(awk '/^oom_kill /{print $2}' "$cg/memory.events" 2>/dev/null)"
    oomk="${oomk:-0}"
  fi
  local statef
  statef="$STATE_DIR/$(echo "$label" | tr -c 'A-Za-z0-9_.-' '_').oomk"
  [[ -r "$statef" ]] && last="$(cat "$statef" 2>/dev/null || echo 0)"
  # oom_kill only grows within a boot; on reboot the cgroup counter resets to 0
  # and so does tmpfs state, so a plain delta is correct.
  delta=$(( oomk - last ))
  (( delta < 0 )) && delta=0
  echo "$oomk" > "$statef"

  # --- D-state tasks in this cgroup -------------------------------------
  local dcount=0 pid st
  if [[ -r "$cg/cgroup.procs" ]]; then
    while read -r pid; do
      [[ -r "/proc/$pid/stat" ]] || continue
      # field 3 of /proc/pid/stat is the state char; guard comms with spaces/()
      st="$(awk '{s=$0; sub(/^[0-9]+ \(.*\) /,"",s); print substr(s,1,1)}' "/proc/$pid/stat" 2>/dev/null)"
      [[ "$st" == "D" ]] && dcount=$(( dcount + 1 ))
    done < "$cg/cgroup.procs"
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
  svc="$(basename "$svc_cg")"
  check_cgroup "agent:${svc#actions.runner.}" "$svc_cg"
  # map the service to its user slice via the unit's User=
  user="$(systemctl show -p User --value "$svc" 2>/dev/null || true)"
  if [[ -n "$user" ]]; then
    uid="$(id -u "$user" 2>/dev/null || true)"
    [[ -n "$uid" ]] && check_cgroup "user:${user}" "$CG_ROOT/user.slice/user-${uid}.slice"
  fi
done

# ---- optional webhook on any WARN ----------------------------------------
if (( ${#warnings[@]} > 0 )) && [[ -n "$WEBHOOK_URL" ]]; then
  # best-effort; a down webhook must never fail the monitor. jq-free JSON: join
  # the warnings into one text field with escaped quotes/newlines.
  body="$(printf '%s\n' "${warnings[@]}" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk 'BEGIN{ORS="\\n"}{print}')"
  curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
    -d "{\"text\":\"[runner-health] $(hostname): ${body}\"}" \
    "$WEBHOOK_URL" >/dev/null 2>&1 || log warning "webhook POST failed"
fi

exit 0
