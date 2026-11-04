# Builds and runs the Tauri desktop app on Linux, headless under Xvfb.
FROM swift:6.4
RUN apt-get update && apt-get install -y --no-install-recommends \
    fonts-liberation libwebkit2gtk-4.1-dev build-essential curl wget file pkg-config libxdo-dev libssl-dev \
    libayatana-appindicator3-dev librsvg2-dev xvfb xauth imagemagick dbus-x11 x11-utils ca-certificates nodejs npm \
    && rm -rf /var/lib/apt/lists/*
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo PATH=/opt/cargo/bin:$PATH
RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
