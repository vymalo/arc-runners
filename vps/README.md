# vymalo self-hosted runners — VPS bootstrap

Three isolated GitHub Actions runners on a standalone VPS, registered to the
**vymalo org** so any repo's workflows can target them. Rootless Podman +
Buildah provide the container runtime (no Docker daemon). Each runner is
hard-capped by systemd to its own slice of the machine.

> This is **separate** from the ARC container image at the repo root
> (`Dockerfile`), which runs runners in Kubernetes. These scripts provision
> *native* `./svc.sh`-managed runners on a single Debian 13 host.
>
> **Deploy:** copy this directory's *contents* to the box and run as root, in
> order. (Use rsync with a trailing slash, or `scp vps/*` — `scp -r vps/ dest`
> would nest into `dest/vps/` if `dest` already exists.)
> ```bash
> ssh root@<host> 'mkdir -p /opt/runners-bootstrap'
> rsync -a vps/ root@<host>:/opt/runners-bootstrap/      # trailing slashes matter
> ssh root@<host> 'bash /opt/runners-bootstrap/01-provision-host.sh \
>                  && bash /opt/runners-bootstrap/02-stage-runners.sh'
> ```
> Then register each runner (needs a token — see below).

## What's on the box

| Runner       | OS user    | Install dir                     | CPU cap | RAM cap |
|--------------|------------|---------------------------------|---------|---------|
| vps-runner-1 | runner-1   | /home/runner-1/actions-runner   | 4 vCPU  | 10 GiB  |
| vps-runner-2 | runner-2   | /home/runner-2/actions-runner   | 4 vCPU  | 10 GiB  |
| vps-runner-3 | runner-3   | /home/runner-3/actions-runner   | 4 vCPU  | 10 GiB  |

Host: 12 vCPU / 31 GiB. Caps are CPUQuota (ceiling, not reservation) so idle
headroom is shared; memory is a hard `MemoryMax` (+2 GiB swap each, 8 GiB
system swap as buffer).

**The cap is applied in two places** (this matters):

- `actions.runner.vymalo.vps-runner-N.service` — bounds the runner *agent*.
- `user-<uid>.slice` — bounds everything the runner user runs, **including the
  rootless build containers**. Container jobs are launched by the user's Podman
  service under `user-<uid>.slice`, *not* under the runner service, so without a
  cap there they would escape the limit and could consume the whole box.

These are **separate cgroups with independent quotas**, so a runner's true
ceiling is the *sum*. The agent budget is kept deliberately small (it only
orchestrates) so the headline number stays honest:

| cgroup | what runs there | CPU | RAM |
|---|---|---|---|
| `actions.runner.…service` (runners.slice) | runner agent | 100% | 1 GiB |
| `user-<uid>.slice` | build + service containers | 400% | 9 GiB |
| **per-runner total** | | ~5 vCPU ceiling | **10 GiB** |

3 × 10 GiB = 30 GiB ≤ 31 GiB host (CPU quotas are ceilings, freely
oversubscribed). The agent service also carries `Restart=always` (the stock
actions-runner unit sets none), so it self-heals if it loses the boot race
against the user's `podman.socket`.

Each runner runs as its own unprivileged user with its own subuid/subgid range
and its own rootless Podman socket. A job in one runner cannot see or starve
another.

## Registering a runner  (the part that needs YOUR token)

Get a **registration token** (short-lived, not a PAT) from:
<https://github.com/organizations/vymalo/settings/actions/runners/new>
(pick Linux / x64; copy only the `--token XXXX` value).

### Option A — one command (recommended)

The token is passed via the environment (or prompted), never as a CLI arg, so
it doesn't leak through `/proc/<pid>/cmdline` to the other runner users' jobs:

```bash
sudo RUNNER_TOKEN=<TOKEN> /opt/runners-bootstrap/register-runner.sh 1
sudo RUNNER_TOKEN=<TOKEN> /opt/runners-bootstrap/register-runner.sh 2   # fresh token each
sudo RUNNER_TOKEN=<TOKEN> /opt/runners-bootstrap/register-runner.sh 3
# or omit RUNNER_TOKEN and it prompts (input hidden)
```

Tokens are single-use and expire in ~1h — grab a new one per runner.

### Option B — by hand with ./svc.sh (you asked for this path)

```bash
sudo -u runner-1 -i
cd ~/actions-runner
./config.sh --url https://github.com/vymalo --token <TOKEN> \
            --name vps-runner-1 --labels self-hosted,linux,x64,podman,vymalo-vps \
            --work _work --unattended --replace
exit
# back as root:
cd /home/runner-1/actions-runner
sudo ./svc.sh install runner-1
sudo systemctl daemon-reload      # binds the pre-staged resource caps
sudo ./svc.sh start
```

Repeat for runner-2 / runner-3. The resource caps and Podman wiring are
applied automatically because the systemd drop-in
(`/etc/systemd/system/actions.runner.vymalo.vps-runner-N.service.d/10-resources.conf`)
was pre-staged — **as long as you keep the runner name `vps-runner-N`.**

## Using the runners from a workflow

### Targeting these runners

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux, x64]   # pins to the 3 VPS runners
```

Prefer `[self-hosted, linux, x64]` (or add `vymalo-vps`) over bare
`runs-on: self-hosted`. The org also has a macOS/ARM64 runner that shares the
`self-hosted` label, so the bare form can schedule a Linux job onto the Mac.

### The host has NO toolchain — run jobs in the image

Natively the box has only `podman`, `buildah`, and `git`. **There is no
flutter / cargo / node / java on the host.** A step that runs `cargo build`
directly on the runner will fail with `command not found`.

The full Rust / Flutter / Android / Node / JDK toolchain lives in
`ghcr.io/vymalo/arc-runners:latest` (the same image ARC runs in k8s; public,
no auth to pull). Run the job *inside* it — the runner's rootless Podman serves
the docker-compat API via `DOCKER_HOST`, so `container:` jobs and `docker build`
work unchanged:

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux, x64]
    container:
      image: ghcr.io/vymalo/arc-runners:latest
    steps:
      - uses: actions/checkout@v4
      - run: cargo build          # ✅ flutter / node / pnpm / java all on PATH
      - run: flutter --version
```

Verified present in the image: Flutter 3.44.4, Cargo 1.96.0, Node 24.18.0,
OpenJDK 21, pnpm, kubectl, helm, Android SDK.

> **Gotcha — don't use a login shell inside the container.** The image exposes
> its toolchain via the image `PATH` env (`/home/runner/flutter/bin`,
> `~/.cargo/bin`, …). A login/`-l` shell re-sources `/etc/profile` and wipes
> that PATH, so tools vanish. The default Actions step shell
> (`bash --noprofile --norc`) preserves it — just never set `shell: bash -l {0}`.

`docker` is also aliased to `podman` (podman-docker), and `DOCKER_HOST` points
at each runner's rootless socket (injected via the runner's `.env`), so plain
`docker build` / `docker compose` in a job work too.

> **Why a `BindPaths` drop-in exists.** GitHub's runner unconditionally
> bind-mounts `/var/run/docker.sock` into every `container:` job. `podman-docker`
> symlinks that path to the *rootful* `/run/podman/podman.sock`, which we don't
> run — so it dangles and `docker create` fails with
> `statfs /var/run/docker.sock: no such file or directory`. Each runner service
> gets a private mount namespace (`BindPaths=…/podman.sock:/run/podman/podman.sock`)
> that resolves it to that runner's own rootless socket. Fully rootless, no
> cross-runner conflict.
>
> **Docker-in-docker caveat:** the mounted socket is owned by the host runner
> user, which maps to *root* inside the rootless container. A workflow step that
> shells out to `docker`/`podman` *from inside* the job container therefore needs
> the container to run as root (`container.options: --user 0`). Plain
> `container:` jobs that just build/test (the common case) are unaffected.

### Image-build (buildah) jobs: run host-native, not in `container:`

Building/pushing images with **buildah does NOT belong in a `container:` job**
here. Nesting rootless buildah inside the podman-managed job container hits an
unavoidable uid + storage-driver conflict (the image ships a pre-initialised
rootless `overlay` store under the runner user's `$HOME`; running it as root
can't reuse that store and can't cleanly override the driver). See
[vymalo/hyperswitch#10](https://github.com/vymalo/hyperswitch/issues/10).

The host already has rootless **buildah + fuse-overlayfs** configured per runner
user. So run the build job directly on the runner — no `container:`:

```yaml
jobs:
  build-images:
    runs-on: [self-hosted, linux, x64]   # NO container:
    steps:
      - uses: actions/checkout@v4
      - run: |
          buildah login -u "$USER" -p "$TOKEN" ghcr.io
          buildah build --layers -t ghcr.io/vymalo/foo:latest .
          buildah push ghcr.io/vymalo/foo:latest
```

Storage is already overlay/rootless for the runner user; no `storage.conf`,
`--user root`, or driver overrides needed. Keep `container:` only for jobs that
need the baked toolchain (Rust/Flutter/Node) — and split those from the image
build into separate jobs. Fully-qualify image refs (`public.ecr.aws/docker/library/postgres`)
since the host defines no unqualified-search registries.

## Persistent-runner credential hygiene

These runners are persistent, not ephemeral, so registry logins leak between
jobs. A job that runs `buildah login` / `docker login ghcr.io` (image-push jobs)
leaves a credential in the runner user's auth files; its `GITHUB_TOKEN` expires
when the job ends, and the next `container:` job's pull then reuses that stale
token and gets **`403 Forbidden`** from ghcr instead of pulling a public image
anonymously.

`job-completed-cleanup.sh` (wired via `ACTIONS_RUNNER_HOOK_JOB_COMPLETED` in each
runner's `.env`) wipes `~/.docker/config.json` + `containers/auth.json` after
every job, so each job starts clean. Symptom if this ever regresses:
`Requesting bearer token: invalid status code from registry 403 (Forbidden)` at
"Initialize containers", even though the image is public and pulls anonymously
elsewhere. Manual clear: `rm -f ~runner-N/.docker/config.json
/run/user/<uid>/containers/auth.json`.

Corollary: do **not** add `container.credentials` for pulling the public
arc-runners image — a repo-scoped `GITHUB_TOKEN` can't pull a cross-repo package
and will 403. Let `container:` pull it anonymously.

## Disk / image cleanup

Persistent runners accumulate pulled base images and `buildah --layers` cache.
`podman-prune.timer` runs `podman-prune.sh` daily (~04:30, randomized):

- **Light prune always** — dangling images, stopped containers, build cache
  older than `PRUNE_KEEP_HOURS` (default 168h/7d). The age filter keeps the hot
  arc-runners base image + recent build cache, so normal builds stay fast.
- **Full prune only under disk pressure** — if the storage FS is ≥
  `PRUNE_DISK_PCT` (default 75%), also drops all unused images + volumes.

Safe to run during jobs (prune only removes *unused* resources). Tune via the
env vars on the service, or run on demand:

```bash
systemctl start podman-prune.service        # run now
journalctl -u podman-prune.service -n 20     # see what it reclaimed
systemctl list-timers podman-prune.timer     # next scheduled run
# per-runner storage usage:
sudo -u runner-1 XDG_RUNTIME_DIR=/run/user/1000 podman system df
```

## Operating

```bash
# status of all three
systemctl status 'actions.runner.vymalo.vps-runner-*' --no-pager

# live resource view (caps + current usage), grouped under the slice
systemd-cgtop runners.slice
systemctl status runners.slice

# confirm BOTH caps bound — agent service AND the user slice (containers).
# user-<uid>.slice is the one that actually bounds build containers; check it.
systemctl show actions.runner.vymalo.vps-runner-1.service \
  -p CPUQuotaPerSecUSec -p MemoryMax -p Slice
systemctl show user-$(id -u runner-1).slice -p CPUQuotaPerSecUSec -p MemoryMax

# stop / start / restart one runner
systemctl stop  actions.runner.vymalo.vps-runner-1.service
systemctl start actions.runner.vymalo.vps-runner-1.service
```

### Removing a runner

`./config.sh remove` needs a **remove token**, which is a *different*
short-lived token from the registration (add) token — mint it from the org
remove-token API (not the `runners/new` page):

```bash
REMOVE_TOKEN=$(gh api -X POST /orgs/vymalo/actions/runners/remove-token --jq .token)
cd /home/runner-1/actions-runner
sudo ./svc.sh stop && sudo ./svc.sh uninstall
sudo -u runner-1 bash -c "cd ~/actions-runner && ./config.sh remove --token $REMOVE_TOKEN"
```

## Re-running the bootstrap

`01-provision-host.sh` and `02-stage-runners.sh` are idempotent — re-run them
after a kernel/package bump or to add capacity (bump `NUM_RUNNERS`). They never
touch a registered runner's config.

## Tuning the caps

Edit `02-stage-runners.sh` (`CONTAINER_*` / `AGENT_*`) and re-run — that retunes
both cgroups at once and is the recommended path. To tune live, remember there
are **two** cgroups: the user slice bounds the real workload, so don't forget it.

```bash
# the workload (build containers) — the one that usually matters:
sudo systemctl set-property user-$(id -u runner-1).slice CPUQuota=300% MemoryMax=7G
# the agent (rarely needs changing):
sudo systemctl set-property actions.runner.vymalo.vps-runner-1.service \
  CPUQuota=100% MemoryMax=1G
```

Setting only the `actions.runner.…service` cap (as earlier docs showed) retunes
just the agent — your build containers stay bounded by the old user-slice cap.
