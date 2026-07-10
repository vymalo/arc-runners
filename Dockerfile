# vymalo/arc-runners — a batteries-included self-hosted GitHub Actions
# runner image for the Actions Runner Controller (ARC).
#
# Philosophy: bake in EVERY tool a full Rust + Flutter + Android + Node +
# Ruby + k8s workflow needs, so the image is built once (heavy) and reused
# everywhere (fast). An ARC pod's emptyDir wipes per-job caches, so anything
# not in the image gets re-installed on every job — baking removes that
# per-job cost and the implicit dependency on upstream availability mid-job.
# See README.md for the full inventory + rationale.
#
# Baked in, by ecosystem:
#   Rust       — stable toolchain (rustup) + rustfmt/clippy/rust-src/
#                llvm-tools-preview components + wasm32-unknown-unknown
#                target; cargo tools: cargo-llvm-cov, just, cargo-nextest,
#                cargo-deny, sccache (shared S3-compatible compile cache).
#   Codegen    — flutter_rust_bridge_codegen (FRB) + cratestack-cli.
#   Node/JS    — Node + pnpm (via corepack). Node major is a BUILD MATRIX
#                axis: we ship 22 and 24 (set via NODE_VERSION build-arg).
#   Browser    — Google Chrome stable (headless) for web/e2e test lanes
#                (`flutter test --platform chrome`, Karma, Puppeteer). amd64-only.
#   Flutter    — Flutter SDK (bundles Dart) + precached engine artifacts.
#   Android    — cmdline-tools + platform-tools + build-tools + platform,
#                on OpenJDK 21 (JAVA_VERSION arg), for `flutter build apk`
#                / Gradle. JDK 21 is inside every current Gradle/AGP support
#                window. The arg is parameterized so a JDK 25 leg can be added
#                later, but only 21 is built today (newer JDKs need validation
#                against the consuming repo's Gradle/AGP pins first).
#   Mobile rel — Ruby + bundler + fastlane (Android build/release lane).
#   Ops/k8s    — kubectl, helm, argocd, mc (MinIO client), gh (GitHub CLI).
#   Containers — rootless Buildah (image build) + Podman (run/compose) +
#                docker-compose provider, for daemonless builds and compose
#                smoke tests WITHOUT a privileged dind sidecar (vfs+chroot
#                defaults; see README for the fuse-overlayfs fast-path).
#   just deps  — chronic (moreutils, used by `just` recipe wrappers) +
#                gum (pretty output, optional); pre-commit (pipx); zsh
#                (hooks that run under `zsh -i -c`); jq + yq (YAML; the latter
#                required by subosito/flutter-action's flutter-version-file).
#   CI baseline — git-lfs, zstd, wget, rsync: bundled by GitHub-hosted ubuntu
#                runners but missing from the actions-runner base; baked so
#                workflows assuming a hosted environment work here too.
#
# Bump any tool by editing its ARG below; the image rebuilds on the next
# push touching `Dockerfile` (or via workflow_dispatch).
#
# ARCHITECTURE: x86_64 / linux/amd64 ONLY. Every binary download below pulls
# an amd64 asset and Google Chrome ships no arm64 Linux build, so there is no
# arm64 variant for now. The workflow builds `platforms: linux/amd64`.
#
# BUILD MATRIX: the workflow fans out over JAVA_VERSION x NODE_VERSION and
# publishes one image per combo (e.g. `:jdk21-node24`). The `:latest` /
# `:<sha7>` tags track the canonical jdk21-node24 combo. The ARG defaults
# below reproduce that canonical combo for a plain `docker build`.
#
# Build + publish: `.github/workflows/build.yml`.
# Published as `ghcr.io/vymalo/arc-runners:jdk<JAVA>-node<NODE_MAJOR>` (+ the
# canonical combo also as `:latest` / `:<sha7>`).
# Deploy: point the ARC RunnerSet's runner container `image:` at the
# published tag (see README.md).

FROM ghcr.io/actions/actions-runner:latest

USER root

# ---- Pinned tool versions (bumpable) ----------------------------------
# Latest-tracking pins were resolved from authoritative release sources
# (github releases/latest, nodejs.org/dist, dl.k8s.io/stable.txt, the
# Flutter + Android package manifests, crates.io) — not guessed. Re-resolve
# when bumping. FRB / pnpm are repo-determined (see notes).
# JAVA_VERSION + NODE_VERSION are BUILD MATRIX axes (see header). The defaults
# below are the canonical `:latest` combo (JDK 21 + Node 24); the workflow
# overrides them per matrix combo via build-args. JAVA_VERSION selects the
# `openjdk-<N>-jdk-headless` apt package + the JAVA_HOME path; the noble base
# offers 21 and 25, but only 21 is built today (25 needs Gradle/AGP validation
# first). NODE_VERSION is the full x.y.z (Node 22.x or 24.x); re-resolve the
# patch from nodejs.org/dist when bumping a major.
ARG JAVA_VERSION=21
ARG NODE_VERSION=24.18.0
ARG SCCACHE_VERSION=0.16.0
ARG FLUTTER_VERSION=3.44.4
ARG PNPM_VERSION=11.9.0
ARG GUM_VERSION=0.17.0
# yq (mikefarah) — YAML processor. Required by subosito/flutter-action when a
# workflow uses `flutter-version-file:` (its setup.sh shells out to `yq`).
# GitHub-hosted ubuntu bundles it; this image must bake it (we ship `jq`, not `yq`).
# yq has no per-binary .sha256 asset, so the digest is pinned here (cross-checked
# against the release `checksums` table, SHA-256 column) and verified at build.
ARG YQ_VERSION=4.53.3
ARG YQ_SHA256=fa52a4e758c63d38299163fbdd1edfb4c4963247918bf9c1c5d31d84789eded4
# Docker Compose binary — used ONLY as the `podman compose` provider (Podman
# runs the dev-stack smoke test; no Docker daemon involved). Verified at build
# via the release's published .sha256 asset.
ARG COMPOSE_VERSION=5.2.0
# FRB CLI MUST match the plugins' `flutter_rust_bridge = "=2.12.0"`; this is
# repo-pinned, not a latest-tracking value.
ARG FRB_VERSION=2.12.0
# cratestack-cli tracks the consuming project's cratestack version
# (resolved from crates.io). Keep it in lockstep with that pin.
ARG CRATESTACK_VERSION=0.4.8
ARG ANDROID_CMDLINE_TOOLS=15641748
# Latest STABLE platform + build-tools, resolved from Google's package
# manifest filtered to the stable channel (channel-0):
#   xmllint --xpath '//remotePackage[channelRef/@ref="channel-0" and
#     starts-with(@path,"platforms;android-")]/@path' repository2-1.xml
# Do NOT just take the manifest max or `sdkmanager --list` max — both
# include preview/canary packages (e.g. platforms;android-37) that the
# default stable channel refuses to install. Re-resolve via the channel-0
# xpath when bumping.
ARG ANDROID_PLATFORM=android-36
ARG ANDROID_BUILD_TOOLS=37.0.0
ARG KUBECTL_VERSION=1.36.2
# helm 4.x — major bump from 3.x, but it maintains chart backwards
# compatibility (https://helm.sh/docs/overview/), so existing charts work.
ARG HELM_VERSION=4.2.2
ARG ARGOCD_VERSION=3.4.4
# GitHub CLI (cli/cli). Used by workflows for `gh` API calls / releases / PR ops;
# NOT in the actions-runner base (GitHub-hosted ubuntu bundles it, this image must
# bake it). gh ships no per-asset .sha256 — the release publishes a combined
# `gh_<ver>_checksums.txt`; the amd64-tarball digest is pinned here (cross-checked
# against that file) and verified at build.
ARG GH_VERSION=2.96.0
ARG GH_SHA256=83d5c2ccad5498f58bf6368acb1ab32588cf43ab3a4b1c301bf36328b1c8bd60
ARG FASTLANE_CONSTRAINT="~> 2.236"

# ---- System packages --------------------------------------------------
# build-base/headers for the cargo workspace (aws-lc-sys, ring,
# libsqlite3-sys, openssl-sys, bindgen). unzip/xz-utils/zip for the
# Flutter + Android SDK archives. zsh for pre-commit hooks (`zsh -i -c`).
# moreutils provides `chronic`, REQUIRED by every justfile recipe's `qr`.
# jq for shell tooling. gnupg provides `gpg` to dearmor the Google Chrome
# apt signing key (present in the base today, listed explicitly so the build
# doesn't silently depend on it). pipx + python3-venv to install pre-commit. Java
# (OpenJDK, JAVA_VERSION matrix axis — 21 is the AGP-supported LTS, 25 the
# newer LTS) + Ruby for the Android / fastlane lanes.
#
# CI-baseline tools that GitHub-hosted `ubuntu` runners bundle but the
# actions-runner base does NOT (verified against the base image) — baked so
# workflows that assume a GitHub-hosted environment don't break on these runners:
#   git-lfs — `actions/checkout` with `lfs: true`; LFS-backed asset repos.
#   zstd    — `actions/cache` + `actions/upload-artifact` compress with zstd;
#             without it they fall back to gzip (slower + version-mismatch noise).
#   wget    — this image otherwise ships only curl; many third-party action
#             install scripts and shell steps assume wget.
#   rsync   — deploy/sync steps and actions that shell out to it.
# (openssh-client is already in the base, so it is intentionally NOT listed.)
# These track Ubuntu's repo — unpinned, like buildah/podman below.
RUN apt-get update -y \
    && apt-get install -y --no-install-recommends \
       build-essential \
       pkg-config \
       libssl-dev \
       cmake \
       clang \
       libclang-dev \
       ca-certificates \
       curl \
       gnupg \
       git \
       git-lfs \
       zstd \
       wget \
       rsync \
       unzip \
       xz-utils \
       zip \
       zsh \
       moreutils \
       jq \
       pipx \
       python3-venv \
       "openjdk-${JAVA_VERSION}-jdk-headless" \
       ruby-full \
    && rm -rf /var/lib/apt/lists/* \
    # Register the LFS smudge/clean filters system-wide (/etc/gitconfig) so
    # every user (root + the baked `runner`) gets LFS-aware git. --skip-repo:
    # there is no repo at build time. Mirrors GitHub-hosted runner setup.
    && git lfs install --system --skip-repo \
    && git-lfs --version

ENV JAVA_HOME=/usr/lib/jvm/java-${JAVA_VERSION}-openjdk-amd64

# ---- Rootless container build (Buildah) + run (Podman) — replaces dind -------
# Daemonless + rootless: jobs build images (buildah) and run compose stacks
# (podman) WITHOUT a privileged `docker:dind` sidecar, so the runner pod is a
# single unprivileged container. buildah/podman track Ubuntu's repo — apt
# version strings are codename-specific and brittle to pin, unlike the ARG-
# driven binary downloads — so they are intentionally unpinned here.
RUN set -eux; \
    apt-get update -y; \
    apt-get install -y --no-install-recommends \
      buildah \
      podman \
      netavark \
      aardvark-dns \
      iptables \
      fuse-overlayfs \
      uidmap \
      slirp4netns \
      passt; \
    rm -rf /var/lib/apt/lists/*; \
    buildah --version; podman --version; \
    # netavark/aardvark-dns install as podman helpers under /usr/lib/podman,
    # not on PATH — verify them there (podman's default helper_binaries_dir).
    # iptables is REQUIRED: netavark 1.4's default firewall driver shells out to
    # it to set up the rootless bridge NAT; without it `podman run` on a bridge
    # network dies "netavark: No such file or directory (os error 2)".
    /usr/lib/podman/netavark --version; test -x /usr/lib/podman/aardvark-dns; iptables --version

# Compose provider for `podman compose` — pinned + checksum-verified against the
# release's published .sha256 asset.
RUN set -eux; \
    base="https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}"; \
    curl --proto '=https' --tlsv1.2 -fsSL "${base}/docker-compose-linux-x86_64" -o /tmp/docker-compose; \
    curl --proto '=https' --tlsv1.2 -fsSL "${base}/docker-compose-linux-x86_64.sha256" -o /tmp/docker-compose.sha256; \
    echo "$(cut -d' ' -f1 /tmp/docker-compose.sha256)  /tmp/docker-compose" | sha256sum -c -; \
    install -m 0755 /tmp/docker-compose /usr/local/bin/docker-compose; \
    rm -f /tmp/docker-compose /tmp/docker-compose.sha256; \
    docker-compose version

# Rootless defaults so it works in a stock unprivileged pod: `vfs` storage (no
# /dev/fuse needed) + subuid/subgid for the runner user. Override to overlay +
# fuse-overlayfs (mount /dev/fuse) for the speed fast-path — see README.
#
# runroot/graphroot are PINNED explicitly (not left to podman's rootless
# auto-detection). This image is itself run as a nested container on a rootless-
# podman VPS host (see vymalo/arc-runners vps/), so `podman`/`buildah` invoked
# INSIDE it are effectively podman-in-podman. c/storage's rootless default-path
# computation needs XDG_RUNTIME_DIR (or a real /run/user/<uid>) to derive a
# runroot — but a `container:` job's env has neither (GitHub Actions only injects
# HOME/GITHUB_ACTIONS/CI, and a job that overrides `--user root` still runs
# inside the OUTER rootless user namespace, so podman's userns detection still
# takes the rootless code path regardless of the apparent in-container uid).
# With no usable default, c/storage fails immediately with "runroot must be set"
# — e.g. vymalo-shop's `backend integration tests` job, which does
# `podman run -d ... postgres:17-alpine` as its first step (see vymalo/arc-runners
# root-cause writeup: the fix belongs here so every consuming job gets it, not in
# each workflow). Fixed dirs sidestep that detection entirely: a config-supplied
# runroot/graphroot is used verbatim, never recomputed. World-writable (1777)
# since a job can run as root, the baked `runner` uid, or (rarely) another uid.
RUN set -eux; \
    mkdir -p /etc/containers; \
    mkdir -p /var/lib/nested-podman/storage /var/lib/nested-podman/run; \
    chmod 1777 /var/lib/nested-podman/storage /var/lib/nested-podman/run; \
    printf '[storage]\ndriver = "vfs"\nrunroot = "/var/lib/nested-podman/run"\ngraphroot = "/var/lib/nested-podman/storage"\n' > /etc/containers/storage.conf; \
    # Force the netavark backend (+ aardvark-dns) so `podman compose` containers
    # resolve each other by service name. The default CNI backend ships no DNS
    # plugin, so compose stacks fail with "lookup <svc>: no such host".
    printf '[network]\nnetwork_backend = "netavark"\n' > /etc/containers/containers.conf; \
    # subuid/subgid for the baked `runner` user only — deliberately NO `root` entry.
    # Consequence for nested podman: a `container:` job that does `podman run` AS
    # ROOT (`--user root`) must also be `--privileged`. With `--privileged`, podman
    # runs the inner container without id-shifting, so no root subuid range is
    # needed (verified: nested `podman run postgres:17-alpine --network host` works).
    # WITHOUT `--privileged`, nested-podman-as-root falls back to a single-id
    # mapping and cannot extract any image with non-zero-gid files — e.g. alpine's
    # /etc/shadow (gid 42) fails with "potentially insufficient UIDs or GIDs ...
    # lchown /etc/shadow: invalid argument", exit 125. vymalo-shop's `backend
    # integration tests` job uses `--privileged --user root` for exactly this. No
    # root entry is added because no job needs non-privileged nested-podman-as-root
    # (and --privileged is the established pattern); if you ever do, run the nested
    # podman as the `runner` user — which HAS the range above — instead.
    printf 'runner:100000:65536\n' > /etc/subuid; \
    printf 'runner:100000:65536\n' > /etc/subgid

# ---- yq (mikefarah) — required by subosito/flutter-action; digest-verified ----
RUN set -eux; \
    curl --proto '=https' --tlsv1.2 -fsSL \
      "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" \
      -o /usr/local/bin/yq; \
    echo "${YQ_SHA256}  /usr/local/bin/yq" | sha256sum -c -; \
    chmod 0755 /usr/local/bin/yq; \
    yq --version

# ---- sccache (shared S3-compatible compilation cache) -----------------
# Prebuilt musl binary (seconds to fetch vs minutes to compile). Consumed
# via RUSTC_WRAPPER=sccache by the consuming repo's CI workflows (and any
# service image builds that install their own sccache).
RUN set -eux; \
    base="sccache-v${SCCACHE_VERSION}-x86_64-unknown-linux-musl"; \
    curl --proto '=https' --tlsv1.2 -fsSL \
      "https://github.com/mozilla/sccache/releases/download/v${SCCACHE_VERSION}/${base}.tar.gz" \
      -o /tmp/sccache.tar.gz; \
    tar -xzf /tmp/sccache.tar.gz -C /tmp; \
    install -m 0755 "/tmp/${base}/sccache" /usr/local/bin/sccache; \
    rm -rf /tmp/sccache.tar.gz "/tmp/${base}"; \
    sccache --version

# ---- Node.js + pnpm (corepack) ----------------------------------------
# Official Node binary tarball into /usr/local; corepack (bundled with
# Node) pins pnpm to the version declared in a project's packageManager.
RUN set -eux; \
    curl --proto '=https' --tlsv1.2 -fsSL \
      "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
      -o /tmp/node.tar.xz; \
    tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1; \
    rm -f /tmp/node.tar.xz; \
    corepack enable; \
    corepack prepare "pnpm@${PNPM_VERSION}" --activate; \
    node --version; \
    pnpm --version

# ---- Google Chrome stable (headless) — web/e2e test lanes -------------
# For `flutter test --platform chrome`, Karma, Puppeteer, etc. Installed from
# Google's official apt repo (amd64-only — there is no arm64 Linux Chrome, which
# is one reason this image is x86-only). The .deb declares its own runtime libs
# (libnss3, libgbm, libasound2, ...) so apt pulls them in; fonts-liberation is
# added for sane text rendering in headless screenshots. `chromium` is symlinked
# for tools that probe for that name. CHROME_EXECUTABLE is what Flutter web reads;
# CHROME_BIN / PUPPETEER_EXECUTABLE_PATH cover Karma / Puppeteer (whose bundled
# download we skip via PUPPETEER_SKIP_DOWNLOAD).
RUN set -eux; \
    curl --proto '=https' --tlsv1.2 -fsSL https://dl.google.com/linux/linux_signing_key.pub \
      | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg; \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
      > /etc/apt/sources.list.d/google-chrome.list; \
    apt-get update -y; \
    apt-get install -y --no-install-recommends \
      google-chrome-stable \
      fonts-liberation; \
    rm -rf /var/lib/apt/lists/*; \
    ln -sf /usr/bin/google-chrome-stable /usr/local/bin/chromium; \
    google-chrome-stable --version

ENV CHROME_EXECUTABLE=/usr/bin/google-chrome-stable \
    CHROME_BIN=/usr/bin/google-chrome-stable \
    PUPPETEER_SKIP_DOWNLOAD=1 \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/google-chrome-stable

# ---- gum (charmbracelet) — optional pretty output for justfile recipes -
RUN set -eux; \
    mkdir -p /tmp/gum; \
    curl --proto '=https' --tlsv1.2 -fsSL \
      "https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/gum_${GUM_VERSION}_Linux_x86_64.tar.gz" \
      | tar -xz -C /tmp/gum; \
    install -m 0755 "$(find /tmp/gum -name gum -type f | head -n1)" /usr/local/bin/gum; \
    rm -rf /tmp/gum; \
    gum --version

# ---- Android SDK (cmdline-tools + platform/build-tools) ----------------
# Needs Java (installed above). Installed to /opt/android-sdk then handed
# to the runner user so Gradle/Flutter can write into it. Platform +
# build-tools are pinned to the stable-channel maxima (see the ARG block);
# sdkmanager installs from the stable channel by default.
ENV ANDROID_SDK_ROOT=/opt/android-sdk \
    ANDROID_HOME=/opt/android-sdk
RUN set -eux; \
    mkdir -p "${ANDROID_SDK_ROOT}/cmdline-tools"; \
    curl --proto '=https' --tlsv1.2 -fsSL \
      "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS}_latest.zip" \
      -o /tmp/cmdline-tools.zip; \
    unzip -q /tmp/cmdline-tools.zip -d /tmp/cmdline-tools; \
    mv /tmp/cmdline-tools/cmdline-tools "${ANDROID_SDK_ROOT}/cmdline-tools/latest"; \
    rm -rf /tmp/cmdline-tools.zip /tmp/cmdline-tools; \
    sdkmanager="${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager"; \
    yes | "$sdkmanager" --sdk_root="${ANDROID_SDK_ROOT}" --licenses >/dev/null; \
    "$sdkmanager" --sdk_root="${ANDROID_SDK_ROOT}" --install \
       "platform-tools" \
       "platforms;${ANDROID_PLATFORM}" \
       "build-tools;${ANDROID_BUILD_TOOLS}"; \
    chown -R runner:runner "${ANDROID_SDK_ROOT}"

# ---- Ruby gems: bundler + fastlane ------------------------------------
RUN set -eux; \
    gem install --no-document bundler; \
    gem install --no-document fastlane -v "${FASTLANE_CONSTRAINT}"; \
    fastlane --version

# ---- Ops / k8s tooling: kubectl, helm, argocd, mc ----------------------
RUN set -eux; \
    curl --proto '=https' --tlsv1.2 -fsSL \
      "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
      -o /usr/local/bin/kubectl; \
    chmod 0755 /usr/local/bin/kubectl; \
    curl --proto '=https' --tlsv1.2 -fsSL \
      "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" \
      | tar -xz -C /tmp; \
    install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm; \
    rm -rf /tmp/linux-amd64; \
    curl --proto '=https' --tlsv1.2 -fsSL \
      "https://github.com/argoproj/argo-cd/releases/download/v${ARGOCD_VERSION}/argocd-linux-amd64" \
      -o /usr/local/bin/argocd; \
    chmod 0755 /usr/local/bin/argocd; \
    curl --proto '=https' --tlsv1.2 -fsSL \
      "https://dl.min.io/client/mc/release/linux-amd64/mc" \
      -o /usr/local/bin/mc; \
    chmod 0755 /usr/local/bin/mc; \
    kubectl version --client; helm version; argocd version --client; mc --version

# ---- GitHub CLI (gh) — digest-verified tarball ------------------------
# Extracts to gh_<ver>_linux_amd64/bin/gh; installed to /usr/local/bin (on PATH).
RUN set -eux; \
    curl --proto '=https' --tlsv1.2 -fsSL \
      "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
      -o /tmp/gh.tar.gz; \
    echo "${GH_SHA256}  /tmp/gh.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/gh.tar.gz -C /tmp; \
    install -m 0755 "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh; \
    rm -rf /tmp/gh.tar.gz "/tmp/gh_${GH_VERSION}_linux_amd64"; \
    gh --version

# ---- Everything below runs AS the runner user -------------------------
# rustup/cargo metadata lands in /home/runner/{.cargo,.rustup} (the
# dtolnay/rust-toolchain + Swatinem/rust-cache default paths), pipx
# packages in /home/runner/.local, and Flutter/pub-cache under the home
# dir — all runner-owned, no chown needed.
USER runner

ENV CARGO_HOME=/home/runner/.cargo \
    RUSTUP_HOME=/home/runner/.rustup
ENV PATH=/home/runner/.cargo/bin:/home/runner/.local/bin:${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:$PATH

# ---- Rust toolchain + components + targets ----------------------------
RUN set -eux; \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --default-toolchain stable --no-modify-path; \
    rustup component add llvm-tools-preview rustfmt clippy rust-src; \
    rustup target add wasm32-unknown-unknown

# ---- Cargo tools via cargo-binstall (prebuilt binaries; compile only as
#      a last resort) so the image build stays well under timeout --------
# GITHUB_TOKEN (optional build secret) lifts cargo-binstall's GitHub API
# rate limit from 60 to 5000 req/hr — without it the resolver hammers
# api.github.com unauthenticated and eats minutes of 504 retries. Mounted
# as a secret (never layered); `set -eu` WITHOUT -x so it isn't echoed.
# `cratestack` has no top-level --version (it requires a subcommand), so
# verify it with --help.
RUN --mount=type=secret,id=github_token \
    set -eu; \
    if [ -s /run/secrets/github_token ]; then \
      export GITHUB_TOKEN="$(cat /run/secrets/github_token)"; \
    fi; \
    curl --proto '=https' --tlsv1.2 -fsSL \
      https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh \
      | bash; \
    cargo binstall -y --locked \
       cargo-llvm-cov \
       just \
       cargo-nextest \
       cargo-deny \
       "flutter_rust_bridge_codegen@${FRB_VERSION}" \
       "cratestack-cli@${CRATESTACK_VERSION}"; \
    cargo-llvm-cov llvm-cov --version; \
    just --version; \
    cargo nextest --version; \
    cargo deny --version; \
    flutter_rust_bridge_codegen --version; \
    cratestack --help >/dev/null

# ---- Baked self-config -------------------------------------------------
# Config the runner needs regardless of which lane runs, so the image is
# self-sufficient. Secret/endpoint values (sccache + remote-cache creds) are NOT
#     baked — they arrive as CI vars/secrets / pod env (see README.md).
#   - git safe.directory '*': the Actions checkout is often owned by a
#     different uid than the runner process; without this git refuses with
#     "detected dubious ownership".
#   - cargo git-fetch-with-cli: a Rust workspace may pull crates as a git
#     dependency; the CLI fetcher is the reliable path for that.
#   - telemetry off for turbo/next; PNPM_HOME on PATH for pnpm global bins.
ENV TURBO_TELEMETRY_DISABLED=1 \
    DO_NOT_TRACK=1 \
    NEXT_TELEMETRY_DISABLED=1 \
    PNPM_HOME=/home/runner/.local/share/pnpm
ENV PATH=$PNPM_HOME:$PATH
RUN set -eux; \
    git config --global --add safe.directory '*'; \
    mkdir -p "$CARGO_HOME"; \
    printf '[net]\ngit-fetch-with-cli = true\n' > "$CARGO_HOME/config.toml"

# ---- pre-commit (pipx) ------------------------------------------------
RUN set -eux; \
    pipx install pre-commit; \
    pre-commit --version

# ---- Flutter SDK (bundles Dart) + precached engine/Android artifacts ---
# FLUTTER_VERSION is pinned to the latest stable that bundles a Dart
# version meeting your Flutter app's pubspec floor. The SDK + precache are baked so
# only pub *packages* are fetched per run (e.g. from an S3-backed
# pub-cache action). PUB_CACHE is the default ~/.pub-cache so
# that cache action restores into the path Dart already reads.
ENV FLUTTER_VERSION=${FLUTTER_VERSION} \
    FLUTTER_HOME=/home/runner/flutter \
    PUB_CACHE=/home/runner/.pub-cache
ENV PATH=$FLUTTER_HOME/bin:$FLUTTER_HOME/bin/cache/dart-sdk/bin:$PUB_CACHE/bin:$PATH

RUN set -eux; \
    url="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"; \
    curl --proto '=https' --tlsv1.2 -fsSL "$url" -o /tmp/flutter.tar.xz; \
    tar -xJf /tmp/flutter.tar.xz -C /home/runner; \
    rm -f /tmp/flutter.tar.xz; \
    git config --global --add safe.directory "$FLUTTER_HOME"; \
    flutter config --no-analytics --no-cli-animations; \
    flutter config --android-sdk "$ANDROID_SDK_ROOT"; \
    flutter precache; \
    flutter --version; \
    dart --version
