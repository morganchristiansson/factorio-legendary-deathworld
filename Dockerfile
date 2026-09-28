FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
# UTF-8 locale: Ruby's default external encoding comes from LANG; without
# this, File.read returns US-ASCII-flagged strings and any non-ASCII byte
# (player names, memories) blows up with Encoding::CompatibilityError.
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    jq \
    git \
    zip \
    unzip \
    lua5.4 \
    python3 \
    python3-pip \
    python3-rcon \
    ddgr pandoc \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --no-cache-dir --break-system-packages trafilatura

RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/* && \
    node --version && npm --version

# ── npm global packages ─────────────────────────────────────────────────────
RUN npm install -g @earendil-works/pi-coding-agent@0.87.1 && \
    pi --version

RUN mkdir -p /workspace
WORKDIR /workspace
USER ubuntu
