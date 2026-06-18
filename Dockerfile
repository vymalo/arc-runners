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
#   Node/JS    — Node LTS + pnpm (via corepack).
#   Flutter    — Flutter SDK (bundles Dart) + precached engine artifacts.
#   Android    — cmdline-tools + platform-tools + build-tools + platform,
#                on OpenJDK 21, for `flutter build apk` / Gradle.
#   Mobile rel — Ruby + bundler + fastlane (Android build/release lane).
#   Ops/k8s    — kubectl, helm, argocd, mc (MinIO client).
#   just deps  — chronic (moreutils, used by `just` recipe wrappers) +
#                gum (pretty output, optional); pre-commit (pipx); zsh
#                (hooks that run under `zsh -i -c`); jq.
#
# Bump any tool by editing its ARG below; the image rebuilds on the next
# push touching `Dockerfile` (or via workflow_dispatch).
#
# Build + publish: `.github/workflows/build.yml`.
# Published as `ghcr.io/vymalo/arc-runners:latest` + `:<sha7>`.
# Deploy: point the ARC RunnerSet's runner container `image:` at the
# published tag (see README.md).

FROM ghcr.io/actions/actions-runner:latest

USER root

# ---- Pinned tool versions (bumpable) ----------------------------------
# Latest-tracking pins were resolved from authoritative release sources
# (github releases/latest, nodejs.org/dist, dl.k8s.io/stable.txt, the
# Flutter + Android package manifests, crates.io) — not guessed. Re-resolve
# when bumping. FRB / pnpm are repo-determined (see notes).
ARG SCCACHE_VERSION=0.15.0
ARG FLUTTER_VERSION=3.44.2
ARG NODE_VERSION=24.16.0
ARG PNPM_VERSION=10.33.2
ARG GUM_VERSION=0.17.0
# FRB CLI MUST match the plugins' `flutter_rust_bridge = "=2.12.0"`; this is
# repo-pinned, not a latest-tracking value.
ARG FRB_VERSION=2.12.0
# cratestack-cli tracks the consuming project's cratestack version
# (resolved from crates.io). Keep it in lockstep with that pin.
ARG CRATESTACK_VERSION=0.4.8
ARG ANDROID_CMDLINE_TOOLS=14742923
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
ARG HELM_VERSION=4.2.1
ARG ARGOCD_VERSION=3.4.3
ARG FASTLANE_CONSTRAINT="~> 2.228"

# ---- System packages --------------------------------------------------
# build-base/headers for the cargo workspace (aws-lc-sys, ring,
# libsqlite3-sys, openssl-sys, bindgen). unzip/xz-utils/zip for the
# Flutter + Android SDK archives. zsh for pre-commit hooks (`zsh -i -c`).
# moreutils provides `chronic`, REQUIRED by every justfile recipe's `qr`.
# jq for shell tooling. pipx + python3-venv to install pre-commit. Java
# (OpenJDK 21 — the latest JDK supported by Android Studio) + Ruby for the
# Android / fastlane lanes.
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
       git \
       unzip \
       xz-utils \
       zip \
       zsh \
       moreutils \
       jq \
       pipx \
       python3-venv \
       openjdk-21-jdk-headless \
       ruby-full \
    && rm -rf /var/lib/apt/lists/*

ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64

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
