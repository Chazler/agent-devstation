#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

expect_failure() {
  if "$@"; then
    echo "Expected command to fail: $*" >&2
    exit 1
  fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
export AGENT_DEVSTATION_TOOL_PREFIX="$tmp/prefix"
export AGENT_DEVSTATION_TOOL_REGISTRY="$tmp/registry.json"
export PATH="$tmp/bin:$PATH"
fixture_install="$AGENT_DEVSTATION_TOOL_PREFIX/lib/agent-devstation/installed-tools/fixture"
fixture_binary="$AGENT_DEVSTATION_TOOL_PREFIX/bin/fixture"

# A local fixture exercises real checksums without network access or Linux binaries.
printf '#!/bin/sh\necho fixture\n' > "$tmp/fixture"
sha=$(shasum -a 256 "$tmp/fixture" | awk '{print $1}')
jq -n --arg sha "$sha" '
  {url: "https://example.invalid/fixture", sha256: $sha} as $download |
  {
    fixture: {
      default: true,
      version: "1.0.0",
      version_args: ["--version"],
      versions: {"1.0.0": {amd64: $download, arm64: $download}}
    }
  }
' > "$AGENT_DEVSTATION_TOOL_REGISTRY"

cat > "$tmp/bin/dpkg" <<'MOCK'
#!/bin/sh
printf '%s\n' "${TEST_ARCH:-amd64}"
MOCK
cat > "$tmp/bin/curl" <<'MOCK'
#!/bin/sh
printf 'download\n' >> "$TEST_TMP/downloads"
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then
    cp "$TEST_TMP/fixture" "$2"
    exit
  fi
  shift
done
exit 1
MOCK

# macOS provides shasum; production Ubuntu supplies sha256sum.
if ! command -v sha256sum >/dev/null; then
  cat > "$tmp/bin/sha256sum" <<'MOCK'
#!/bin/sh
exec shasum -a 256 "$@"
MOCK
fi
chmod +x "$tmp/bin/"*
export TEST_TMP="$tmp"
bash scripts/install-tools.sh
"$fixture_binary" | grep -qx fixture
bash scripts/install-tools.sh
[[ $(wc -l < "$tmp/downloads") -eq 1 ]]

# Interrupted staging and corrupted installed executable must recover.
mkdir -p "${fixture_install%/fixture}/.fixture-staging"
printf corrupt > "$fixture_install/fixture"
bash scripts/install-tools.sh
[[ $(wc -l < "$tmp/downloads") -eq 2 ]]

# Invalid requests must fail before changing existing installations.
for selection in unknown 'fixture,' '../fixture'; do
  expect_failure env AGENT_DEVSTATION_TOOLS="$selection" bash scripts/install-tools.sh
done
expect_failure env AGENT_DEVSTATION_TOOL_FIXTURE_VERSION=9.0.0 bash scripts/install-tools.sh
expect_failure env TEST_ARCH=riscv64 bash scripts/install-tools.sh
test -x "$fixture_binary"

# A registered version override replaces the installation and completion marker.
jq '.fixture.versions["1.0.1"] = .fixture.versions["1.0.0"]' "$AGENT_DEVSTATION_TOOL_REGISTRY" > "$tmp/updated.json"
mv "$tmp/updated.json" "$AGENT_DEVSTATION_TOOL_REGISTRY"
AGENT_DEVSTATION_TOOL_FIXTURE_VERSION=1.0.1 bash scripts/install-tools.sh
[[ $(cat "$fixture_install/.version") == 1.0.1 ]]

# An empty selection removes the installed tool.
test -x "$fixture_binary"
AGENT_DEVSTATION_TOOLS= bash scripts/install-tools.sh
test ! -e "$fixture_binary"
TEST_ARCH=arm64 bash scripts/install-tools.sh

# Bad checksums fail closed and leave the complete installation intact.
jq '(.fixture.versions[][] .sha256) = ("0" * 64)' "$AGENT_DEVSTATION_TOOL_REGISTRY" > "$tmp/bad.json"
expect_failure env AGENT_DEVSTATION_TOOL_REGISTRY="$tmp/bad.json" bash scripts/install-tools.sh
"$fixture_binary" | grep -qx fixture

# Registry selection and legacy flags both dispatch custom installers.
mkdir -p "$tmp/custom/tools"
cp scripts/install-tools.sh "$tmp/custom/"
cat > "$tmp/custom/install-fixture.sh" <<'MOCK'
#!/bin/sh
printf '%s\n' "$AGENT_DEVSTATION_FIXTURE_ENABLED" >> "$TEST_TMP/custom-calls"
MOCK
chmod +x "$tmp/custom/install-fixture.sh"
cat > "$tmp/custom/tools/registry.json" <<'JSON'
{
  "fixture": {
    "default": false,
    "installer": "install-fixture.sh",
    "enabled_env": "AGENT_DEVSTATION_FIXTURE_ENABLED"
  }
}
JSON
custom_registry="$tmp/custom/tools/registry.json"
custom_installer="$tmp/custom/install-tools.sh"
AGENT_DEVSTATION_TOOL_REGISTRY="$custom_registry" AGENT_DEVSTATION_TOOLS=fixture bash "$custom_installer"
AGENT_DEVSTATION_TOOL_REGISTRY="$custom_registry" AGENT_DEVSTATION_FIXTURE_ENABLED=true bash "$custom_installer"
AGENT_DEVSTATION_TOOL_REGISTRY="$custom_registry" bash "$custom_installer"
[[ $(cat "$tmp/custom-calls") == $'true\ntrue\nfalse' ]]

# Validate the shipped manifest on each architecture without installation.
for arch in amd64 arm64; do
  TEST_ARCH="$arch" \
    AGENT_DEVSTATION_TOOL_REGISTRY="$PWD/tools/registry.json" \
    AGENT_DEVSTATION_TOOLS= bash scripts/install-tools.sh --binaries-only
done
echo 'Tool registry tests passed (AMD64 and ARM64 fixture assets)'
