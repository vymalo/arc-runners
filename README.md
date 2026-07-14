# vymalo/arc-runners

A **batteries-included self-hosted GitHub Actions runner image** for the
[Actions Runner Controller (ARC)](https://github.com/actions/actions-runner-controller).

It extends the official `ghcr.io/actions/actions-runner` base with a full
**Rust + Flutter + Android + Node + Ruby + Kubernetes** toolchain, baked in
once so jobs start fast.

> **Why bake everything in?** An ARC pod's `emptyDir` wipes per-job caches, so
> any tool not in the image gets re-installed on every job — adding per-job
> cost and an implicit dependency on upstream availability mid-run. Building
> the image once (heavy) and reusing it everywhere (fast) removes both.

> **Architecture:** **x86_64 / `linux/amd64` only** for now — there is no arm64
> variant. Every baked binary pulls an amd64 asset and Google Chrome ships no
> arm64 Linux build, so an arm64 image isn't offered yet.

### Image matrix

The build fans out over **Java × Node**, publishing one image per combo. Only
**Java 21** is shipped today (it's inside every current Gradle/AGP support
window); the axis is kept matrix-shaped so a JDK 25 leg can be added later once
validated against the consuming repo's Gradle/AGP pins.

| | Node 22 | Node 24 |
| --- | --- | --- |
| **Java 21** | `:jdk21-node22` | `:jdk21-node24` ← also `:latest` |

Each combo is published as a moving `:jdk<java>-node<node>` tag plus an
immutable `:jdk<java>-node<node>-<sha7>` tag. The canonical **`jdk21-node24`**
combo is *additionally* published as the moving `:latest` and `:<sha7>` tags:

- `ghcr.io/vymalo/arc-runners:latest` — canonical `jdk21-node24`.
- `ghcr.io/vymalo/arc-runners:<sha7>` — canonical combo, immutable per commit.
- `ghcr.io/vymalo/arc-runners:jdk21-node22` — Node 22 variant.
- `ghcr.io/vymalo/arc-runners:jdk21-node<node>-<sha7>` — combo, pinned.

## Baked-in toolchain

Every tool is pinned to a bumpable `ARG` in the [`Dockerfile`](./Dockerfile).

| Ecosystem | Tools |
| --------- | ----- |
| **System** | build-essential, pkg-config, libssl-dev, cmake, clang, libclang-dev, curl, **wget**, git, **git-lfs**, **zstd**, **rsync**, unzip, xz-utils, zip, **zsh**, **moreutils** (`chronic`), **jq** |
| **Rust** | stable toolchain (rustup) + `rustfmt`/`clippy`/`rust-src`/`llvm-tools-preview` + `wasm32-unknown-unknown` target; cargo tools `cargo-llvm-cov`, `just`, `cargo-nextest`, `cargo-deny`, `sccache` |
| **Codegen** | `flutter_rust_bridge_codegen`, `cratestack-cli` |
| **Node / JS** | Node (**22** or **24**, matrix axis) + `pnpm` (via corepack) |
| **Browser** | Google Chrome stable (headless) — `flutter test --platform chrome`, Karma, Puppeteer; `chromium` symlink + `CHROME_EXECUTABLE`/`CHROME_BIN` set |
| **Flutter** | Flutter SDK (bundles Dart) + precached engine/Android artifacts |
| **Android** | cmdline-tools + platform-tools + build-tools + platform, on OpenJDK **21** |
| **Mobile release** | Ruby + bundler + fastlane |
| **Ops / k8s** | `kubectl`, `helm`, `argocd`, `mc` (MinIO client), `gh` (GitHub CLI) |
| **Pre-commit** | `pre-commit` (via pipx) |

### Pinned versions

The `ARG` block at the top of the `Dockerfile` holds every version. Latest-
tracking pins are resolved from authoritative release sources (GitHub releases,
`nodejs.org/dist`, `dl.k8s.io`, the Flutter/Android package manifests,
crates.io) — re-resolve when bumping rather than guessing. A few are intentionally
project-determined:

- **`FRB_VERSION`** must match the `flutter_rust_bridge` crate version your
  plugins pin (the generated bindings are version-locked to it).
- **`CRATESTACK_VERSION`** tracks the cratestack version your project consumes,
  so generated clients match.
- **`FLUTTER_VERSION`** must ship a Dart version that meets your app's pubspec
  floor.
- **`JAVA_VERSION`** and **`NODE_VERSION`** are **build-matrix axes** — the
  workflow overrides the `ARG` defaults per combo. Today the matrix is Java 21 ×
  Node 22/24; the `ARG` defaults (`JAVA_VERSION=21`, `NODE_VERSION=24.18.0`)
  reproduce the canonical `:latest` combo for a plain `docker build`. To add a
  Java (e.g. 25) or Node version, edit the `matrix` in
  [`build.yml`](./.github/workflows/build.yml) (and the Node-major → full-version
  `include` mapping for Node).

Bump a tool by editing its `ARG`; the image rebuilds on the next push that
touches the `Dockerfile`.

## Build & publish

[`.github/workflows/build.yml`](./.github/workflows/build.yml) builds and
publishes the image. It runs on **GitHub-hosted runners** on purpose — this
repo bootstraps the runner image, so it must not depend on a self-hosted
runner of its own kind.

- It runs a **matrix** (Java 21 × Node 22/24), producing two images;
  see [Image matrix](#image-matrix) for the tag scheme.
- **Pull requests** build the image (validating `Dockerfile` changes) but
  **never push**.
- Pushes to **`main`** and **`v*` tags** publish each combo's
  `:jdk<java>-node<node>` (+ `-<sha7>`) tags; the canonical `jdk21-node24`
  combo also moves `:latest` + `:<sha7>`.
- `GITHUB_TOKEN` is mounted as a build secret (for `cargo-binstall`'s GitHub
  API rate limit) and is **never baked into a layer**.
- The cold build is large, so the workflow frees ~25–40 GB of preinstalled
  host SDKs first and uses a per-combo **registry-backed** buildx cache
  (`:buildcache-jdk<java>-node<node>`) to avoid the 10 GB Actions-cache ceiling.

No repository secrets beyond the automatic `GITHUB_TOKEN` are required to build.

### Make the image pullable

The published GHCR package is **private by default**. Either:

- make the `arc-runners` package **public** (GHCR → package → Package settings →
  Change visibility), so ARC can pull it without credentials; **or**
- keep it private and give the RunnerSet an `imagePullSecret` for GHCR.

## Deploy to ARC

Point the RunnerSet's runner container image at a published tag. Pick the combo
your jobs need (e.g. `:jdk21-node22`); prefer an immutable
`:jdk<java>-node<node>-<sha7>` tag in production so a new build can't silently
change the runner out from under in-flight jobs:

```yaml
template:
  spec:
    containers:
      - name: runner
        # canonical combo: :latest == :jdk21-node24
        # other combo:     :jdk21-node22
        # pin in prod:     :jdk21-node24-<sha7>
        image: ghcr.io/vymalo/arc-runners:jdk21-node24
```

If your ARC chart uses the higher-level `image.repository` / `image.tag` keys,
set them to the same repository/tag pair instead.

> **Circular-dependency caveat:** if you also use this image to *build itself*
> on a self-hosted RunnerSet, a broken publish can leave you without a working
> runner to build the fix. This repo avoids that by building on GitHub-hosted
> runners. If you mirror the build onto a self-hosted runner elsewhere, recover
> from a bad publish by re-pinning `image:` to the last-good `:<sha7>` tag.

### Rootless container builds need `allowPrivilegeEscalation: true`

The image bakes **rootless buildah/podman** with everything they need on the
*image* side — `uidmap`, `/etc/subuid` + `/etc/subgid` ranges for the `runner`
user, and `vfs` storage (no `/dev/fuse` required). But buildah/podman still have
to set up a user namespace, which runs the **setuid** `newuidmap`/`newgidmap`.
A hardened pod with `allowPrivilegeEscalation: false` sets `no_new_privs`, which
disables setuid — so the mapping fails and image builds die while unpacking the
base layer:

```
newuidmap: write to uid_map failed: Operation not permitted → Falling back to single mapping
ApplyLayer ... remount /, flags: 0x44000: permission denied
```

Set `allowPrivilegeEscalation: true` on the runner container (it stays **non-root**
— `runAsUser: 1001`, no added capabilities — far less than the privileged `dind`
sidecar this replaces):

```yaml
template:
  spec:
    containers:
      - name: runner
        image: ghcr.io/vymalo/arc-runners:jdk21-node24
        securityContext:
          runAsUser: 1001
          runAsGroup: 1001
          # setuid newuidmap/newgidmap → user namespace for rootless buildah/podman
          allowPrivilegeEscalation: true
```

> The runner namespace's Pod Security Standard must be at least **`baseline`** for
> this to be admitted (a `restricted` namespace rejects it). For the overlay +
> `fuse-overlayfs` speed fast-path, additionally mount `/dev/fuse` and switch the
> storage driver — see the storage note in the Dockerfile.

> **Node-kernel caveat (Ubuntu 24.04 / kernel ≥ 6.8):** `allowPrivilegeEscalation`
> is necessary but **not always sufficient**. These kernels default
> `kernel.apparmor_restrict_unprivileged_userns=1`, which denies the `uid_map`
> write (even a bare `unshare -U -r` fails) regardless of caps or AppArmor profile
> on the *pod*. It's an **unnamespaced node sysctl**, so no `securityContext` can
> re-grant it. Tell it apart from a pod-security problem by reading
> `/proc/sys/kernel/apparmor_restrict_unprivileged_userns` on the runner.
>
> **The rootless fix is to flip the node sysctl, not to go privileged.** Set
> `kernel.apparmor_restrict_unprivileged_userns=0` on each runner node (a
> `sysctl.d` drop-in, kernel cmdline, or — the GitOps-native way — a small
> privileged node-tuning DaemonSet that `sysctl -w`s it on every node). The runner
> pod then stays **non-privileged**: `runAsUser: 1001`,
> `allowPrivilegeEscalation: true`, `capabilities.add: [SETUID, SETGID]`, AppArmor
> + seccomp `Unconfined` — a `baseline`-PSS pod, not a privileged one. Running the
> runner `privileged: true` also works (CAP_SYS_ADMIN bypasses the restriction) but
> it is a *strictly larger* privilege grant than fixing the one node sysctl, so
> prefer the sysctl. Whichever you pick, apply it to **every** node a runner can
> schedule onto.

### `podman compose` needs container DNS (netavark)

`podman compose` stacks resolve each other by **service name** (`redis`,
`wiremock`, …). Podman's default **CNI** backend ships no DNS plugin, so those
lookups fall through to the host/cluster resolver and fail with
`lookup <svc>: no such host`. This image therefore installs **`netavark` +
`aardvark-dns`** and pins `network_backend = "netavark"` in
`/etc/containers/containers.conf`, so compose service discovery works out of the box.

### Rootless image builds with BuildKit (`buildctl`)

Alongside buildah, the image bakes **rootless BuildKit** — `buildkitd` +
`buildctl` plus **`rootlesskit`** — for jobs that want BuildKit's own frontend
and cache features (registry cache exporters, `--mount=type=cache`,
reproducible-build options) rather than buildah's CLI. It is **not** a baked
service: a job starts the user-space daemon itself and points `buildctl` at it,
so there is still no privileged `dind` sidecar. A minimal build-and-push step:

```bash
# 1. start the rootless daemon. Inside a pod/container add
#    --oci-worker-no-process-sandbox: k8s has no `systempaths=unconfined`, so
#    buildkitd can't unmask /proc for a per-step sandbox (caveat: build steps
#    can then signal/ptrace the daemon). Default `native` snapshotter → no /dev/fuse.
rootlesskit buildkitd --oci-worker-no-process-sandbox &
# 2. build straight from a Dockerfile and push (registry auth from docker/login-action)
buildctl build \
  --frontend dockerfile.v0 \
  --local context=. --local dockerfile=. \
  --output type=image,name=ghcr.io/you/app:tag,push=true
```

**Privilege — not lighter than buildah.** Rootless BuildKit sets up an
unprivileged user namespace the same way buildah does, so it is **not** a way to
drop buildah's pod-security requirements. BuildKit's [upstream Kubernetes
example](https://github.com/moby/buildkit/tree/master/examples/kubernetes) runs
with `seccompProfile: Unconfined` + `appArmorProfile: Unconfined` (plus the
`--oci-worker-no-process-sandbox` above) — a **`baseline`-or-looser** pod, not a
tighter one — and it is blocked by the *same* Ubuntu-24.04
`kernel.apparmor_restrict_unprivileged_userns=1` node sysctl that blocks buildah
(see the buildah notes above). Validate the exact flags/`securityContext` with a
smoke test in your runner pod before switching a workflow over.

Storage mirrors the buildah story: the default **`native`** snapshotter needs no
`/dev/fuse` (like Podman's `vfs`); for the faster **`fuse-overlayfs`**
snapshotter, mount `/dev/fuse` and add `--oci-worker-snapshotter=fuse-overlayfs`.
Only the amd64 `buildkitd`/`buildctl`/`buildkit-runc` binaries are installed; the
tarball's bundled CNI plugins (rootless uses host networking via
`rootlesskit`/`slirp4netns`) and cross-arch QEMU binaries (this image is
amd64-only) are dropped.

## Optional shared caches

The image bakes `sccache` and `mc`, but **no cache endpoints or credentials are
baked in** — they are supplied by the *consuming* repo's workflows via their own
Actions variables/secrets (or pod env), e.g. `RUSTC_WRAPPER=sccache` with an
S3-compatible backend (`SCCACHE_BUCKET` / `SCCACHE_ENDPOINT` / AWS-style keys).
Everything is fail-open: unset values simply disable that cache. Substitute your
own endpoint and a dedicated, bucket-scoped key — do not commit credentials.

## License

[MIT](./LICENSE).
