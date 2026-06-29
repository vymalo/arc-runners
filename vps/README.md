# vymalo self-hosted runners — VPS bootstrap

Three isolated GitHub Actions runners on a standalone VPS, registered to the
**vymalo org** so any repo's workflows can target them. Rootless Podman +
Buildah provide the container runtime (no Docker daemon). Each runner is
hard-capped by systemd to its own slice of the machine.

> This is **separate** from the ARC container image at the repo root
> (`Dockerfile`), which runs runners in Kubernetes. These scripts provision
> *native* `./svc.sh`-managed runners on a single Debian 13 host.
>
> **Deploy:** copy this directory to the box and run as root, in order:
> ```bash
> scp -r vps/ root@<host>:/opt/runners-bootstrap
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
headroom is shared; memory is a hard `MemoryMax` per runner (+2 GiB swap each,
8 GiB system swap as buffer).

Each runner runs as its own unprivileged user with its own subuid/subgid range
and its own rootless Podman socket. A job in one runner cannot see or starve
another.

## Registering a runner  (the part that needs YOUR token)

Get a **registration token** (short-lived, not a PAT) from:
<https://github.com/organizations/vymalo/settings/actions/runners/new>
(pick Linux / x64; copy only the `--token XXXX` value).

### Option A — one command (recommended)

```bash
sudo /opt/runners-bootstrap/register-runner.sh 1 <TOKEN>
sudo /opt/runners-bootstrap/register-runner.sh 2 <TOKEN>   # fresh token each
sudo /opt/runners-bootstrap/register-runner.sh 3 <TOKEN>
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

## Operating

```bash
# status of all three
systemctl status 'actions.runner.vymalo.vps-runner-*' --no-pager

# live resource view (caps + current usage), grouped under the slice
systemd-cgtop runners.slice
systemctl status runners.slice

# confirm a runner's caps actually bound
systemctl show actions.runner.vymalo.vps-runner-1.service \
  -p CPUQuotaPerSecUSec -p MemoryMax -p Slice

# stop / start / restart one runner
systemctl stop  actions.runner.vymalo.vps-runner-1.service
systemctl start actions.runner.vymalo.vps-runner-1.service
```

### Removing a runner

```bash
cd /home/runner-1/actions-runner
sudo ./svc.sh stop && sudo ./svc.sh uninstall
sudo -u runner-1 bash -c "cd ~/actions-runner && ./config.sh remove --token <REMOVE_TOKEN>"
```

## Re-running the bootstrap

`01-provision-host.sh` and `02-stage-runners.sh` are idempotent — re-run them
after a kernel/package bump or to add capacity (bump `NUM_RUNNERS`). They never
touch a registered runner's config.

## Tuning the caps

Edit `02-stage-runners.sh` (`CPU_QUOTA` / `MEM_MAX`) and re-run, or live:

```bash
sudo systemctl set-property actions.runner.vymalo.vps-runner-1.service \
  CPUQuota=300% MemoryMax=8G
```
