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

Published as:

- `ghcr.io/vymalo/arc-runners:latest`
- `ghcr.io/vymalo/arc-runners:<sha7>` — immutable per commit, for pinning.

## Baked-in toolchain

Every tool is pinned to a bumpable `ARG` in the [`Dockerfile`](./Dockerfile).

| Ecosystem | Tools |
| --------- | ----- |
| **System** | build-essential, pkg-config, libssl-dev, cmake, clang, libclang-dev, curl, git, unzip, xz-utils, zip, **zsh**, **moreutils** (`chronic`), **jq** |
| **Rust** | stable toolchain (rustup) + `rustfmt`/`clippy`/`rust-src`/`llvm-tools-preview` + `wasm32-unknown-unknown` target; cargo tools `cargo-llvm-cov`, `just`, `cargo-nextest`, `cargo-deny`, `sccache` |
| **Codegen** | `flutter_rust_bridge_codegen`, `cratestack-cli` |
| **Node / JS** | Node + `pnpm` (via corepack) |
| **Flutter** | Flutter SDK (bundles Dart) + precached engine/Android artifacts |
| **Android** | cmdline-tools + platform-tools + build-tools + platform, on OpenJDK 21 |
| **Mobile release** | Ruby + bundler + fastlane |
| **Ops / k8s** | `kubectl`, `helm`, `argocd`, `mc` (MinIO client) |
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

Bump a tool by editing its `ARG`; the image rebuilds on the next push that
touches the `Dockerfile`.

## Build & publish

[`.github/workflows/build.yml`](./.github/workflows/build.yml) builds and
publishes the image. It runs on **GitHub-hosted runners** on purpose — this
repo bootstraps the runner image, so it must not depend on a self-hosted
runner of its own kind.

- **Pull requests** build the image (validating `Dockerfile` changes) but
  **never push**.
- Pushes to **`main`** and **`v*` tags** publish `:latest` + `:<sha7>`.
- `GITHUB_TOKEN` is mounted as a build secret (for `cargo-binstall`'s GitHub
  API rate limit) and is **never baked into a layer**.
- The cold build is large, so the workflow frees ~25–40 GB of preinstalled
  host SDKs first and uses a **registry-backed** buildx cache
  (`:buildcache`) to avoid the 10 GB Actions-cache ceiling.

No repository secrets beyond the automatic `GITHUB_TOKEN` are required to build.

### Make the image pullable

The published GHCR package is **private by default**. Either:

- make the `arc-runners` package **public** (GHCR → package → Package settings →
  Change visibility), so ARC can pull it without credentials; **or**
- keep it private and give the RunnerSet an `imagePullSecret` for GHCR.

## Deploy to ARC

Point the RunnerSet's runner container image at a published tag. Prefer an
immutable `:<sha7>` tag in production so a new build can't silently change the
runner out from under in-flight jobs:

```yaml
template:
  spec:
    containers:
      - name: runner
        image: ghcr.io/vymalo/arc-runners:latest # or :<sha7>
```

If your ARC chart uses the higher-level `image.repository` / `image.tag` keys,
set them to the same repository/tag pair instead.

> **Circular-dependency caveat:** if you also use this image to *build itself*
> on a self-hosted RunnerSet, a broken publish can leave you without a working
> runner to build the fix. This repo avoids that by building on GitHub-hosted
> runners. If you mirror the build onto a self-hosted runner elsewhere, recover
> from a bad publish by re-pinning `image:` to the last-good `:<sha7>` tag.

## Optional shared caches

The image bakes `sccache` and `mc`, but **no cache endpoints or credentials are
baked in** — they are supplied by the *consuming* repo's workflows via their own
Actions variables/secrets (or pod env), e.g. `RUSTC_WRAPPER=sccache` with an
S3-compatible backend (`SCCACHE_BUCKET` / `SCCACHE_ENDPOINT` / AWS-style keys).
Everything is fail-open: unset values simply disable that cache. Substitute your
own endpoint and a dedicated, bucket-scoped key — do not commit credentials.

## License

[MIT](./LICENSE).
