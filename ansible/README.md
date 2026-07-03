# Ansible provisioning for the vymalo VPS runner host

Declarative replacement for the imperative `vps/*.sh` bootstrap scripts. Same
end state, but with **drift detection** (`--check --diff`) — the thing the shell
scripts couldn't give us, and whose absence let the live host silently diverge
from source (the 1G/2G-swap caps that caused the ~19h wedge — arc-runners#8).

> **Status: SCAFFOLD — not yet cut over.** Faithfully translated from the shell
> scripts and reviewed, but **not yet validated against the host**. The `vps/`
> scripts remain the source of truth until a `--check` run is clean and a
> converge is verified. See *Validation* below.

## Layout

```
ansible/
  ansible.cfg           inventory.ini        site.yml
  group_vars/all.yml    # every tunable (caps, counts, paths) — the source of truth
  roles/
    provision_host/     # packages, registries, swap, sysctl, ulimits, slice, timers
    stage_runners/      # per-runner users, subid, linger, podman socket, tree, drop-ins
    register_runner/    # register+install+start ONE runner (needs a token)
```

## Usage

```bash
cd ansible

# Dry run — show drift against the live host, change nothing:
ansible-playbook site.yml --check --diff

# Converge host + staging (idempotent):
GITHUB_TOKEN=ghp_… ansible-playbook site.yml        # token lifts the runner-release API rate limit

# Register one runner (short-lived org token, not a PAT):
ansible-playbook site.yml --tags register -e runner_index=1 -e "runner_token=$TOKEN"
```

Tune caps/counts in `group_vars/all.yml`, re-run with `--check --diff` to preview,
then apply. Changing a memory cap is now a one-line edit with a visible diff.

## Values reflect the POST-incident hardened state

`group_vars/all.yml` encodes the arc-runners#8 fix — **`mem_swap_max: "0"`** and
**`agent_mem_max: "6G"`** — not the pre-fix `1G/2G` the `vps/` scripts on an
un-updated `main` still show. Deterministic uids (`runner_base_uid`) are an
improvement over the shell's reliance on `useradd` allocation order.

## Dependencies / caveats

- **Requires arc-runners#9 merged.** `provision_host` copies helper scripts from
  `../vps/`, including `runner-health-watch.sh`, which #9 adds. A `--check` will
  fail on the missing file until #9 lands.
- Collections: `ansible.posix` (for `mount`). Everything else is `ansible.builtin`.
- A few steps use `command`/`shell` where no native module fits (`loginctl
  enable-linger` with a `creates:` guard, `config.sh`, `svc.sh install`) — each is
  guarded to stay idempotent.

## Validation (before trusting it over `vps/`)

1. `ansible-playbook site.yml --syntax-check`
2. `ansible-playbook site.yml --check --diff` against the host — **expect near-zero
   changes** (the host is already in the target state). Any diff is real drift to
   read carefully.
3. Converge on the host; confirm all three runners stay `active` and the caps
   match (`systemctl show … -p MemoryMax -p MemorySwapMax`).
4. Only then retire `vps/*.sh` (and move the helper scripts into the roles' `files/`
   for self-containment).

## Known follow-ups

- Port `register-runner.sh`'s TOCTOU hardening (root-own the tree + re-extract
  `svc.sh` from the immutable cache across `svc.sh install`).
- Move helper scripts into `roles/*/files/` so `ansible/` is self-contained and
  `vps/` can be deleted.
- `ansible-vault` for the registration token if it's ever stored rather than passed.
