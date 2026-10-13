# Klaxon cross-framework bench suite — linux/arm64 container image.
#
# One image carries all four runner toolchains (klaxon/zig, qt6, compose/JVM,
# flutter+xvfb) plus the CI-published klaxon deps bundle. The repository is NOT
# baked in — run-one.sh bind-mounts it read-only, rsyncs to /work, and links
# /opt/klaxon-deps as deps/ so the host checkout stays clean.
#
# Build:   container build -t klaxon-bench -f bench/container/Dockerfile .
# Run:     container run --rm --cpus N --memory XG \
#            -v "$PWD:/repo:ro" -v "$PWD/bench/results:/results" \
#            klaxon-bench <klaxon|qt|compose|flutter> [scene ...]

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive TZ=UTC LANG=C.UTF-8

# ---------------------------------------------------------------------------
# System packages — mirror .github/workflows/ci.yml apt-packages for the
# linux-arm64 job, plus the per-runner toolchain deps.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git xz-utils unzip zip python3 rsync \
    clang cmake ninja-build generate-ninja pkg-config \
    build-essential make g++ \
    libc++-dev libc++abi-dev \
    # klaxon (ci.yml): X11/Wayland dev for SDL3, EGL/GLES, a11y stack
    libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev \
    libxinerama-dev libxss-dev libxtst-dev \
    libwayland-dev wayland-protocols libxkbcommon-dev \
    libegl1-mesa-dev libgles2-mesa-dev \
    libasound2-dev libdbus-1-dev libudev-dev libusb-1.0-0-dev libibus-1.0-dev \
    libatk1.0-dev libatk-bridge2.0-dev libatspi2.0-dev \
    # qt runner: offscreen raster (QT_QPA_PLATFORM=offscreen)
    qt6-base-dev qt6-base-dev-tools libqt6opengl6-dev qt6-declarative-dev \
    qml6-module-qtquick qml6-module-qtquick-layouts qml6-module-qtquick-shapes \
    qml6-module-qtquick-window qml6-module-qtqml-workerscript \
    qml6-module-qt5compat-graphicaleffects libqt6svg6 \
    # compose runner: JVM + skiko needs libgl for its raster native
    openjdk-21-jdk libgl1-mesa-dri \
    # flutter linux desktop (GTK embedder under Xvfb — software raster)
    xvfb xauth libgtk-3-dev libblkid-dev liblzma-dev \
    # fonts: text_cjk/text_rich need real CJK glyphs on every runner
    fonts-noto-cjk fonts-dejavu \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Zig 0.17.0 (must match the repo toolchain pin)
ARG ZIG_VER=0.17.0
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VER}/zig-aarch64-linux-${ZIG_VER}.tar.xz" -o /tmp/zig.tar.xz \
    && tar -xJf /tmp/zig.tar.xz -C /opt \
    && ln -s "/opt/zig-aarch64-linux-${ZIG_VER}/zig" /usr/local/bin/zig \
    && rm /tmp/zig.tar.xz

# ---------------------------------------------------------------------------
# Klaxon linux deps (skia + sdl3 + wamr, CI-published artifact — the same
# bundle the ubuntu-24.04-arm job downloads; public release, no auth needed).
ARG DEPS_TAG=deps-1c54a72328c0
RUN mkdir -p /opt/klaxon-deps \
    && curl -fsSL "https://github.com/Vehicoule/klaxon/releases/download/${DEPS_TAG}/deps-native-linux-arm64.tar.gz" -o /tmp/deps.tar.gz \
    && tar -xzf /tmp/deps.tar.gz -C /opt/klaxon-deps \
    && rm /tmp/deps.tar.gz

# ---------------------------------------------------------------------------
# Flutter is NOT baked in: the container VM's network to
# storage.googleapis.com measures ~10 KB/s (vs ~17 MB/s on the host) — a
# multi-hour layer. run-matrix.sh mounts the host-downloaded linux SDK at
# /opt/flutter-host instead (see bench/container/fetch-flutter.sh).

# ---------------------------------------------------------------------------
# Ubuntu arm64 clang defaults to -moutline-atomics → cmake-built objects would
# reference __aarch64_*_sync helpers zig's builtins lack (ci.yml arm64 note).
ENV CFLAGS=-mno-outline-atomics CXXFLAGS=-mno-outline-atomics \
    SDL_VIDEODRIVER=dummy QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
    QSG_RENDER_LOOP=basic GRADLE_OPTS=-Dorg.gradle.jvmargs=-Xmx3g

WORKDIR /work
ENTRYPOINT ["/repo/bench/container/run-one.sh"]
