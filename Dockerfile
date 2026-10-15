FROM ubuntu:26.04

LABEL org.opencontainers.image.source="https://github.com/LucUrlings/agent-devstation"

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/home/dev \
    CODEX_HOME=/home/dev/.codex \
    DOTNET_ROOT=/opt/sdk/dotnet/current \
    JAVA_HOME=/opt/sdk/java/current \
    GOROOT=/opt/sdk/go/current \
    GOPATH=/home/dev/go \
    CARGO_HOME=/opt/sdk/rust/current \
    RUSTUP_HOME=/opt/sdk/rust/rustup \
    UV_PYTHON_INSTALL_DIR=/opt/sdk/python \
    PLAYWRIGHT_BROWSERS_PATH=/opt/playwright-browsers \
    PATH=/opt/sdk/python/current/bin:/opt/sdk/node/current/bin:/opt/sdk/dotnet/current:/opt/sdk/java/current/bin:/opt/sdk/go/current/bin:/home/dev/go/bin:/opt/sdk/rust/current/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin

RUN apt-get update \
    && apt-get upgrade -y --with-new-pkgs --no-install-recommends \
    && apt-get install -y --no-install-recommends \
      bash bubblewrap ca-certificates curl git gnupg gosu jq openssh-client procps \
      sudo passwd tar unzip xz-utils zstd build-essential libicu78 libssl3t64 \
    && rm -rf /var/lib/apt/lists/* \
    && if id -u ubuntu >/dev/null 2>&1; then usermod -l dev -d /home/dev -m ubuntu && groupmod -n dev ubuntu; else useradd -m -u 1000 -s /bin/bash dev; fi \
    && mkdir -p /opt/sdk /home/dev/workspaces /home/dev/.codex /home/dev/.config /home/dev/.local \
    && chown -R dev:dev /home/dev

# GitHub's signed apt repository supplies the same gh command to all projects.
ARG GH_VERSION
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod 0644 /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && if [ -n "$GH_VERSION" ]; then apt-get install -y --no-install-recommends "gh=$GH_VERSION"; else apt-get install -y --no-install-recommends gh; fi \
    && rm -rf /var/lib/apt/lists/* \
    && { [ -z "$GH_VERSION" ] || [ "$(dpkg-query -W -f='${Version}' gh)" = "$GH_VERSION" ]; } \
    && gh --version

ARG UV_VERSION
RUN if [ -n "$UV_VERSION" ]; then url="https://astral.sh/uv/$UV_VERSION/install.sh"; else url=https://astral.sh/uv/install.sh; fi \
    && curl -fsSL "$url" -o /tmp/install-uv.sh \
    && UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh /tmp/install-uv.sh \
    && rm /tmp/install-uv.sh \
    && { [ -z "$UV_VERSION" ] || [ "$(uv --version | awk '{print $2}')" = "$UV_VERSION" ]; } \
    && uv --version

# Anthropic's signed stable apt repository keeps the CLI outside user SDK paths.
ARG CLAUDE_VERSION
RUN install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://downloads.claude.ai/keys/claude-code.asc -o /etc/apt/keyrings/claude-code.asc \
    && echo 'deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/stable stable main' > /etc/apt/sources.list.d/claude-code.list \
    && apt-get update \
    && if [ -n "$CLAUDE_VERSION" ]; then apt-get install -y --no-install-recommends "claude-code=$CLAUDE_VERSION"; else apt-get install -y --no-install-recommends claude-code; fi \
    && rm -rf /var/lib/apt/lists/* \
    && { [ -z "$CLAUDE_VERSION" ] || [ "$(dpkg-query -W -f='${Version}' claude-code)" = "$CLAUDE_VERSION" ]; } \
    && claude --version

# Official standalone Codex release. The installer is executed only at image build time.
ARG CODEX_VERSION=latest
RUN curl -fsSL https://chatgpt.com/codex/install.sh -o /tmp/install-codex.sh \
    && HOME=/root CODEX_HOME=/opt/codex sh /tmp/install-codex.sh --release "$CODEX_VERSION" \
    && ln -s /opt/codex/packages /home/dev/.codex/packages \
    && chown -R dev:dev /opt/codex /home/dev/.codex \
    && rm /tmp/install-codex.sh \
    && installed=$(/opt/codex/packages/standalone/current/bin/codex --version) \
    && echo "$installed" \
    && { [ "$CODEX_VERSION" = latest ] || [ "$installed" = "codex-cli $CODEX_VERSION" ]; }

COPY tools/registry.json /usr/local/lib/agent-devstation/tools/registry.json
COPY scripts/install-tools.sh /usr/local/lib/agent-devstation/
COPY scripts/entrypoint.sh scripts/install-sdks.sh scripts/install-editor.sh scripts/install-docker-cli.sh scripts/install-playwright-browser.sh /usr/local/lib/agent-devstation/
COPY scripts/codex.sh /usr/local/bin/codex
RUN chmod 0755 /usr/local/lib/agent-devstation/*.sh /usr/local/bin/codex && chown -R dev:dev /home/dev

WORKDIR /home/dev/workspaces
EXPOSE 8080
ENTRYPOINT ["/usr/local/lib/agent-devstation/entrypoint.sh"]
