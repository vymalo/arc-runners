# Ansible provisioning for the vymalo VPS runner hosts

Declarative replacement for the imperative `vps/*.sh` bootstrap scripts. Same
end state, but with **drift detection** (`--check --diff`) — the thing the shell
scripts couldn't give us, and whose absence let the live host silently diverge
from source (the 1G/2G-swap caps that caused the ~19h wedge — arc-runners#8).

> **Status: source of truth.** Validated against the primary host (a `--check`
> converge is clean) and used to provision the **second** host (`vps-runners-2`)
> from bare Debian. The `vps/*.sh` scripts are legacy. Shared
> defaults live in `group_vars/all.yml`; per-host sizing (a smaller box runs
> fewer/larger runners) lives in `host_vars/<name>.yml`.

## Layout

```
ansible/
  ansible.cfg           inventory.ini        site.yml
  requirements.yml      # Galaxy collections (ansible.posix)
  group_vars/all.yml    # shared tunables (caps, counts, paths) — defaults for every host
  host_vars/<name>.yml  # per-host overrides (e.g. a smaller box: fewer/larger runners)
  roles/
    provision_host/     # packages, registries, swap, sysctl, ulimits, slice, timers
    stage_runners/      # per-runner users, subid, linger, podman socket, tree, drop-ins
    register_runner/    # register+install+start ONE runner (needs a token)
```

## Usage

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml   # once (or run via `uvx --from ansible`, which bundles them)

# Dry run — show drift against the live host, change nothing:
ansible-playbook site.yml --check --diff

# Converge host + staging (idempotent):
GITHUB_TOKEN=ghp_… ansible-playbook site.yml        # token lifts the runner-release API rate limit

# Onboarding a NEW host — always --limit it so you don't touch the others:
ansible-playbook site.yml --limit vps-runners-2

# Register one runner (short-lived org token, not a PAT) — pass via a 0600 vars
# file, not argv, so it never lands in your shell's process list / history:
ansible-playbook site.yml --limit vps-runners-2 --tags register -e runner_index=1 -e @token.yml
```

Tune shared caps/counts in `group_vars/all.yml` (or per-host in `host_vars/<name>.yml`),
re-run with `--check --diff` to preview, then apply. Changing a memory cap is now a
one-line edit with a visible diff.

> `--check` can't fully dry-run a **bare** host: the `apt` module needs
> `python3-apt` (which a real run auto-installs) for check mode, so the first
> provision of a fresh box is applied directly after a `--syntax-check`.

## Values reflect the POST-incident hardened state

`group_vars/all.yml` encodes the arc-runners#8 fix — **`mem_swap_max: "0"`** and
(after the 3→2 reshare) **`agent_mem_max: "9G"` / `container_mem_max: "13824M"`** —
not the pre-fix `1G/2G` the `vps/` scripts on an un-updated `main` still show. The
smaller second box overrides these down in `host_vars/vps-runners-2.yml` (one
larger runner sized to its 15 GiB). Deterministic uids (`runner_base_uid`) are an
improvement over the shell's reliance on `useradd` allocation order.

## Dependencies / caveats

- `provision_host` copies helper scripts (incl. `runner-health-watch.sh`) from
  `../vps/`, the single source of truth during coexistence.
- Collections: `ansible.posix` (for `mount`), declared in `requirements.yml`.
  Everything else is `ansible.builtin`.
- A few steps use `command`/`shell` where no native module fits (`loginctl
  enable-linger` with a `creates:` guard, `config.sh`, `svc.sh install`) — each is
  guarded to stay idempotent.

## Validation (before trusting it over `vps/`)

1. `ansible-playbook site.yml --syntax-check`
2. `ansible-playbook site.yml --check --diff` against the host — **expect near-zero
   changes** (the host is already in the target state). Any diff is real drift to
   read carefully.
3. Converge on the host; confirm all `runner_count` runners stay `active` and the
   caps match (`systemctl show … -p MemoryMax -p MemorySwapMax`).
4. Only then retire `vps/*.sh` (and move the helper scripts into the roles' `files/`
   for self-containment).

## Known follow-ups

- Move helper scripts into `roles/*/files/` so `ansible/` is self-contained and
  `vps/` can be deleted.
- `ansible-vault` for the registration token if it's ever stored rather than passed.
