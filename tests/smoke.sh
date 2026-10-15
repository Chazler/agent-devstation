#!/usr/bin/env bash
set -euo pipefail

image=${IMAGE:-agent-devstation:ci}
name="devstation-smoke-$$"
java_name="devstation-java-smoke-$$"
cache_volume="devstation-cache-smoke-$$"
codex_name="devstation-codex-smoke-$$"
optional_name="devstation-optional-tools-smoke-$$"
codex_volume="devstation-codex-home-smoke-$$"
workspace_volume="devstation-workspace-smoke-$$"
nested_workspace_volume="devstation-nested-workspace-smoke-$$"
nested_home_volume="devstation-nested-home-smoke-$$"
trap 'docker rm -f "$name" "$java_name" "$codex_name" "$optional_name" >/dev/null 2>&1 || true; docker volume rm "$cache_volume" "$codex_volume" "$workspace_volume" "$nested_workspace_volume" "$nested_home_volume" >/dev/null 2>&1 || true' EXIT
trap 'echo "Smoke test failed at line $LINENO" >&2' ERR

wait_for_editor() {
  local editor_ready=false
  for _ in $(seq 1 180); do
    if docker exec -u dev "$name" curl -s --max-time 2 -o /dev/null http://127.0.0.1:8080/; then
      editor_ready=true
      break
    fi
    if [[ $(docker inspect -f '{{.State.Running}}' "$name") != true ]]; then
      docker logs "$name"
      return 1
    fi
    sleep 2
  done
  if [[ "$editor_ready" != true ]]; then
    docker logs "$name"
    return 1
  fi
}

wait_for_writable_node() {
  for _ in $(seq 1 60); do
    # npm can run before the entrypoint finishes giving dev write access.
    if docker exec -u dev "$name" bash -c 'npm --version >/dev/null && test -w /opt/sdk/node/current/bin && test -w /opt/sdk/node/current/lib/node_modules' >/dev/null 2>&1; then
      return 0
    fi
    if [[ $(docker inspect -f '{{.State.Running}}' "$name") != true ]]; then
      docker logs "$name"
      return 1
    fi
    sleep 2
  done
  docker logs "$name"
  return 1
}

bash tests/codex-wrapper.sh
bash tests/tool-registry.sh

# kubectl is baked into both architectures, without a startup download.
docker run --rm --entrypoint /usr/local/bin/kubectl "$image" version --client
docker run --rm -e AGENT_DEVSTATION_TOOLS= "$image" bash -lc '! command -v kubectl'

# The simple Compose path retains Docker's default security filters. The
# optional sandboxed path needs the options below; test that path separately.
test "$(docker compose config --format json | jq -r '.services["agent-devstation"].security_opt // [] | length')" = 0
docker compose config --format json | jq -e '.services["agent-devstation"].volumes | any(.target == "/home/dev/workspaces")' >/dev/null
docker run --rm "$image" bash -lc 'test -x /usr/bin/bwrap'
test "$(docker run --rm --security-opt seccomp=unconfined --security-opt apparmor=unconfined "$image" \
  codex sandbox -c 'sandbox_mode="read-only"' /bin/sh -lc 'cd "$HOME" && pwd -P')" = /home/dev
if docker run --rm --security-opt seccomp=unconfined --security-opt apparmor=unconfined "$image" \
  codex sandbox -c 'sandbox_mode="read-only"' /bin/sh -lc 'touch /home/dev/workspaces/codex-read-only-probe' >/dev/null 2>&1; then
  echo 'Codex read-only sandbox allowed a workspace write' >&2
  exit 1
fi

# Compose can create ./workspaces as an empty root-owned bind source on Linux.
# The image must make that mount writable without taking over existing files.
docker volume create "$workspace_volume" >/dev/null
docker run --rm --mount "type=volume,src=$workspace_volume,dst=/home/dev/workspaces,volume-nocopy" --entrypoint bash "$image" -lc \
  'chown root:root /home/dev/workspaces; chmod 755 /home/dev/workspaces'
docker run --rm --mount "type=volume,src=$workspace_volume,dst=/home/dev/workspaces,volume-nocopy" "$image" bash -lc \
  'test "$HOME" = /home/dev && test -w "$HOME" && test -w /home/dev/workspaces && git init -q --bare /tmp/smoke-origin.git && git clone -q /tmp/smoke-origin.git /home/dev/workspaces/Watchtower && test -d /home/dev/workspaces/Watchtower/.git'
docker run --rm --mount "type=volume,src=$workspace_volume,dst=/home/dev/workspaces,volume-nocopy" --entrypoint bash "$image" -lc \
  'chown root:root /home/dev/workspaces'
if output=$(docker run --rm -e AGENT_DEVSTATION_UID=1234 -e AGENT_DEVSTATION_GID=1234 \
  --mount "type=volume,src=$workspace_volume,dst=/home/dev/workspaces,volume-nocopy" "$image" true 2>&1); then
  echo 'Nonempty root-owned workspace was accepted unexpectedly' >&2
  exit 1
fi
[[ "$output" == *'/home/dev/workspaces is not writable by dev'* ]] || { echo "$output" >&2; exit 1; }
docker run --rm --mount "type=volume,src=$workspace_volume,dst=/home/dev/workspaces,volume-nocopy" --entrypoint bash "$image" -lc \
  'test "$(stat -c %u /home/dev/workspaces)" = 0 && test "$(stat -c %u /home/dev/workspaces/Watchtower)" = 1000'

# The Compose layout nests a project mount under the persisted home volume.
docker volume create "$nested_home_volume" >/dev/null
docker volume create "$nested_workspace_volume" >/dev/null
docker run --rm --mount "type=volume,src=$nested_home_volume,dst=/home/dev" \
  --mount "type=volume,src=$nested_workspace_volume,dst=/home/dev/workspaces,volume-nocopy" "$image" bash -lc \
  'test "$PWD" = /home/dev/workspaces && test -w "$HOME/workspaces" && test -w "$HOME/.codex"'
# Changing the dev UID must repair the home volume without taking ownership of
# existing project files in the nested workspace mount.
docker run --rm --mount "type=volume,src=$nested_workspace_volume,dst=/home/dev/workspaces,volume-nocopy" \
  --entrypoint bash "$image" -lc \
  'mkdir -p /home/dev/workspaces/project && touch /home/dev/workspaces/project/existing && chown -R 1000:1000 /home/dev/workspaces/project && chown 1234:1234 /home/dev/workspaces'
docker run --rm -e AGENT_DEVSTATION_UID=1234 -e AGENT_DEVSTATION_GID=1234 \
  --mount "type=volume,src=$nested_home_volume,dst=/home/dev" \
  --mount "type=volume,src=$nested_workspace_volume,dst=/home/dev/workspaces,volume-nocopy" "$image" bash -lc \
  'test "$(id -u):$(id -g)" = 1234:1234 && test -w "$HOME" && test -w "$HOME/workspaces" && test "$(stat -c %u:%g "$HOME/workspaces/project/existing")" = 1000:1000'

# A home volume created by an older image can contain root-owned uv cache files
# even when the cache directory itself belongs to dev.
docker volume create "$cache_volume" >/dev/null
docker run --rm -v "$cache_volume:/home/dev" --entrypoint bash "$image" -lc \
  'mkdir -p /home/dev/.cache/uv; chown dev:dev /home/dev/.cache; touch /home/dev/.cache/uv/root-owned'
docker run --rm -v "$cache_volume:/home/dev" "$image" bash -lc \
  'test -w /home/dev/.cache/uv/root-owned && test -f /home/dev/.cache/.agent-devstation-ownership-v1'
docker run --rm -e AGENT_DEVSTATION_UID=1234 -e AGENT_DEVSTATION_GID=1234 "$image" bash -lc \
  'test "$(id -u):$(id -g)" = 1234:1234 && test -w /home/dev/.codex && test -w /home/dev/workspaces'
docker run --rm -e AGENT_DEVSTATION_UID=33 -e AGENT_DEVSTATION_GID=20 "$image" bash -lc \
  'test "$(id -u):$(id -g)" = 33:20 && test -w /home/dev/.codex && test -w /home/dev/workspaces'

docker run -d --name "$name" -e AGENT_DEVSTATION_VSCODE_EDITOR_ENABLED=false "$image" >/dev/null
sleep 3
docker exec -u dev "$name" bash -lc 'codex --version && claude --version && gh --version && ! command -v code-server'
# Optional tools are absent unless selected.
docker exec -u dev "$name" bash -lc \
  '! command -v docker && ! command -v dockerd && test -L /opt/playwright-browsers && test -w "$PLAYWRIGHT_BROWSERS_PATH" && touch "$PLAYWRIGHT_BROWSERS_PATH/project-cache-probe"'
docker exec -u root "$name" /usr/local/lib/agent-devstation/install-playwright-browser.sh
docker exec -u dev "$name" test -f /home/dev/.cache/ms-playwright/project-cache-probe
docker exec -u dev "$name" bash -lc '
  set -euo pipefail
  codex login --help | grep -- "--device-auth" >/dev/null
  codex login --help | grep -- "--with-api-key" >/dev/null
  codex remote-control --help | grep "pair" >/dev/null
  claude auth --help | grep "login" >/dev/null
  claude --help | grep -- "--remote-control" >/dev/null
'
docker exec -u dev "$name" bash -lc 'for sdk in python python3 pip3 node npm npx corepack dotnet java javac go gofmt rustc cargo rustup; do if command -v "$sdk" >/dev/null; then echo "Unexpected SDK command: $sdk" >&2; exit 1; fi; done'
docker exec -u dev "$name" bash -lc '! curl -s --max-time 1 -o /dev/null http://127.0.0.1:8080/'
docker rm -f "$name" >/dev/null

# The home volume retains Codex daemon state and the user's start choice, but
# its package under /opt/codex belongs to the disposable container layer. A
# recreated container must bootstrap the package and resume Remote Control.
docker volume create "$codex_volume" >/dev/null
for generation in 1 2; do
  docker run -d --name "$codex_name" -v "$codex_volume:/home/dev" "$image" >/dev/null
  if [[ "$generation" == 1 ]]; then
    docker exec -u dev "$codex_name" bash -lc '
    set -euo pipefail
    status=0
    timeout 60s codex remote-control start >/tmp/codex-remote-start.log 2>&1 || status=$?
    [[ "$status" == 0 || "$status" == 1 ]] || { cat /tmp/codex-remote-start.log; exit 1; }
    test -x /home/dev/.codex/packages/app-server-daemon/current/bin/codex
    test -S /home/dev/.codex/app-server-control/app-server-control.sock
    touch /home/dev/.codex/.agent-devstation-remote-control-enabled
  '
  else
    # This polling shell exits explicitly; use a non-login shell so Ubuntu's
    # logout hook cannot replace its success status under set -e.
    docker exec -u dev "$codex_name" bash -c '
      set -euo pipefail
      for _ in $(seq 1 60); do
        test -S /home/dev/.codex/app-server-control/app-server-control.sock && exit 0
        sleep 1
      done
      exit 1
    '
    docker logs "$codex_name" 2>&1 | grep 'Resuming Codex Remote Control' >/dev/null
  fi
  docker rm -f "$codex_name" >/dev/null
done

if docker run --rm -e AGENT_DEVSTATION_SDK_NODE=24.x "$image" true >/dev/null 2>&1; then
  echo 'Version syntax accepted .x unexpectedly' >&2
  exit 1
fi
if docker run --rm -e AGENT_DEVSTATION_VSCODE_EDITOR_ENABLED=true "$image" true >/dev/null 2>&1; then
  echo 'Editor started without a password unexpectedly' >&2
  exit 1
fi
if output=$(docker run --rm -e AGENT_DEVSTATION_PLAYWRIGHT_CHROMIUM_ENABLED=true \
  -e PLAYWRIGHT_BROWSERS_PATH=/tmp/project-browsers "$image" true 2>&1); then
  echo 'Shared Chromium accepted a conflicting browser cache unexpectedly' >&2
  exit 1
fi
[[ "$output" == *'PLAYWRIGHT_BROWSERS_PATH must be /opt/playwright-browsers'* ]] || { echo "$output" >&2; exit 1; }

# Temurin's range API can return 21.0.12.1 when asked for 21.0.12. Verify
# that an exact selector picks the requested numeric release.
docker run -d --name "$java_name" -e AGENT_DEVSTATION_SDK_JAVA=21.0.12 "$image" >/dev/null
ready=false
for _ in $(seq 1 120); do
  if docker logs "$java_name" 2>&1 | grep '^java 21.0.12 ready$' >/dev/null; then ready=true; break; fi
  if [[ $(docker inspect -f '{{.State.Running}}' "$java_name") != true ]]; then docker logs "$java_name"; exit 1; fi
  sleep 2
done
[[ "$ready" == true ]] || { docker logs "$java_name"; exit 1; }
docker exec -u dev "$java_name" bash -lc 'java -version 2>&1 | grep -q "^openjdk version \"21.0.12\""'
docker rm -f "$java_name" >/dev/null

docker run -d --name "$name" \
  -e AGENT_DEVSTATION_SDK_PYTHON=3.14 -e AGENT_DEVSTATION_SDK_NODE=24 -e AGENT_DEVSTATION_SDK_DOTNET=10 \
  -e AGENT_DEVSTATION_SDK_JAVA=21 -e AGENT_DEVSTATION_SDK_GO=1.24 -e AGENT_DEVSTATION_SDK_RUST=1.85 \
  -e AGENT_DEVSTATION_VSCODE_EDITOR_ENABLED=true -e AGENT_DEVSTATION_VSCODE_PASSWORD=smoke-only-password \
  "$image" >/dev/null

ready=false
for _ in $(seq 1 180); do
  if docker logs "$name" 2>&1 | grep 'rust .* ready' >/dev/null; then ready=true; break; fi
  if [[ $(docker inspect -f '{{.State.Running}}' "$name") != true ]]; then docker logs "$name"; exit 1; fi
  sleep 10
done
[[ "$ready" == true ]] || { docker logs "$name"; exit 1; }

wait_for_editor

echo 'Checking SDK commands and editor login'
docker exec -u dev "$name" bash -lc 'python3 --version && node --version && dotnet --version && java -version && go version && rustc --version && cargo --version && test "$JAVA_HOME" = /opt/sdk/java/current && test "$DOTNET_ROOT" = /opt/sdk/dotnet/current'
docker exec -u dev "$name" code-server --version
docker exec -i -u dev -e DOTNET_CLI_TELEMETRY_OPTOUT=1 "$name" bash -s < tests/sdk-functional.sh
docker exec -u dev "$name" bash -lc 'curl -s -D - -o /dev/null http://127.0.0.1:8080/ | grep -qi "Location: ./login"'
docker exec -u dev "$name" bash -lc 'curl -s -c /tmp/editor-cookie -o /dev/null -d password=smoke-only-password http://127.0.0.1:8080/login; curl -s -b /tmp/editor-cookie -D - -o /dev/null http://127.0.0.1:8080/ | grep -qi "Location: ./?folder=/home/dev/workspaces"'

# A hard interruption can leave extraction files beside an otherwise complete
# editor installation. Startup must clear them without downloading again.
docker exec -u root "$name" mkdir -p /opt/.agent-devstation-code-server-staging
before=$(docker logs "$name" 2>&1 | grep -c '^Installing ')
echo 'Restarting with installed SDKs and editor'
docker restart "$name" >/dev/null
wait_for_editor
after=$(docker logs "$name" 2>&1 | grep -c '^Installing ')
[[ "$before" == "$after" ]] || { echo 'Restart downloaded an SDK or editor again' >&2; exit 1; }
docker exec -u dev "$name" test ! -e /opt/.agent-devstation-code-server-staging
docker logs "$name" 2>&1 | grep '^Removing incomplete code-server download$' >/dev/null
docker logs "$name" 2>&1 | grep '^Found code-server .*; already installed$' >/dev/null

# A failed download can leave the current path without a working command. The
# next start must repair it instead of entering a permanent restart loop.
docker exec -u root "$name" mv /opt/sdk/node/current/bin/npm /opt/sdk/node/current/bin/npm.incomplete
docker restart "$name" >/dev/null
wait_for_writable_node
docker logs "$name" 2>&1 | grep '^Removing incomplete node installation$' >/dev/null

# An interrupted install can also leave a version directory before the
# current link is created. Startup must clear that partial directory.
docker exec -u root "$name" rm /opt/sdk/node/current
docker restart "$name" >/dev/null
wait_for_writable_node
repairs=$(docker logs "$name" 2>&1 | grep -c '^Removing incomplete node installation$')
[[ "$repairs" -ge 2 ]] || { echo 'Missing-current recovery did not clear the partial SDK' >&2; exit 1; }

# Go can still report its version when extraction stopped before its source
# tree was complete. Without the completion marker, startup must reinstall it.
docker exec -u root "$name" mv /opt/sdk/go/current/src /opt/sdk/go/current/src.incomplete
docker exec -u root "$name" mv /opt/sdk/go/.agent-devstation-complete /opt/sdk/go/.agent-devstation-incomplete
docker restart "$name" >/dev/null
recovered=false
for _ in $(seq 1 60); do
  if docker exec -u dev "$name" bash -lc 'test -d /opt/sdk/go/current/src && test -f /opt/sdk/go/.agent-devstation-complete && go version' >/dev/null 2>&1; then recovered=true; break; fi
  if [[ $(docker inspect -f '{{.State.Running}}' "$name") != true ]]; then docker logs "$name"; exit 1; fi
  sleep 2
done
[[ "$recovered" == true ]] || { docker logs "$name"; exit 1; }
docker logs "$name" 2>&1 | grep '^Removing incomplete go installation$' >/dev/null

# A changed selector replaces the installed version, and an empty selector
# removes it, even before a Compose recreation discards the container layer.
replacement=$(docker exec -u root -e HOME=/root -e AGENT_DEVSTATION_SDK_NODE=22 "$name" /usr/local/lib/agent-devstation/install-sdks.sh)
[[ "$replacement" == *'Uninstalling node '* && "$replacement" == *'Installing node 22'* ]] || { echo "$replacement" >&2; exit 1; }
docker exec -u dev "$name" bash -lc 'node --version | grep -q "^v22\."'
removal=$(docker exec -u root -e HOME=/root -e AGENT_DEVSTATION_SDK_NODE= "$name" /usr/local/lib/agent-devstation/install-sdks.sh)
[[ "$removal" == *'Uninstalling node (not selected)'* ]] || { echo "$removal" >&2; exit 1; }
docker exec -u dev "$name" bash -lc '! command -v node && test ! -e /opt/sdk/node'

docker rm -f "$name" >/dev/null
docker run -d --name "$name" "$image" >/dev/null
sleep 3
docker exec -u dev "$name" bash -lc 'for sdk in python python3 pip3 node npm npx corepack dotnet java javac go gofmt rustc cargo rustup code-server; do ! command -v "$sdk" || exit 1; done; test ! -e /opt/code-server'

# Selected tools install at startup and work as dev. A project-owned Playwright
# package must be able to launch the shared Chromium binary.
docker run -d --name "$optional_name" --shm-size=1g \
  -e AGENT_DEVSTATION_SDK_NODE=24 \
  -e AGENT_DEVSTATION_DOCKER_CLI_ENABLED=true \
  -e AGENT_DEVSTATION_PLAYWRIGHT_CHROMIUM_ENABLED=true \
  "$image" >/dev/null
optional_ready=false
for _ in $(seq 1 300); do
  if docker logs "$optional_name" 2>&1 | grep '^Playwright Chromium 1.63.0 ready$' >/dev/null; then optional_ready=true; break; fi
  if [[ $(docker inspect -f '{{.State.Running}}' "$optional_name") != true ]]; then docker logs "$optional_name"; exit 1; fi
  sleep 2
done
[[ "$optional_ready" == true ]] || { docker logs "$optional_name"; exit 1; }
docker exec -u dev "$optional_name" bash -lc \
  'docker --version && docker compose version && docker buildx version && test "$PLAYWRIGHT_BROWSERS_PATH" = /opt/playwright-browsers && ! command -v playwright && ! command -v playwright-core'
docker exec -i -u dev "$optional_name" bash -s < tests/playwright-functional.sh

# A restart reuses complete installations and clears interrupted downloads.
docker exec -u root "$optional_name" mkdir -p /opt/.agent-devstation-docker-cli-staging /opt/.agent-devstation-playwright-staging
before=$(docker logs "$optional_name" 2>&1 | grep -c '^Installing \(Docker CLI\|Playwright Chromium\) ')
docker restart "$optional_name" >/dev/null
reused=false
for _ in $(seq 1 60); do
  if docker logs "$optional_name" 2>&1 | grep '^Found Playwright Chromium .*; already installed$' >/dev/null; then reused=true; break; fi
  if [[ $(docker inspect -f '{{.State.Running}}' "$optional_name") != true ]]; then docker logs "$optional_name"; exit 1; fi
  sleep 2
done
[[ "$reused" == true ]] || { docker logs "$optional_name"; exit 1; }
after=$(docker logs "$optional_name" 2>&1 | grep -c '^Installing \(Docker CLI\|Playwright Chromium\) ')
[[ "$before" == "$after" ]] || { echo 'Restart downloaded optional tools again' >&2; exit 1; }
docker exec -u dev "$optional_name" bash -lc \
  'test ! -e /opt/.agent-devstation-docker-cli-staging && test ! -e /opt/.agent-devstation-playwright-staging'

# The full browser remaining must not hide a missing headless shell.
docker exec -u root "$optional_name" bash -lc '
  set -euo pipefail
  binary=$(find /opt/playwright-browsers -type f -name chrome-headless-shell -print -quit)
  test -n "$binary"
  rm -- "$binary"
  # Simulate the unfinished dpkg journal left by an interrupted dependency
  # install, and confirm that APT really refuses to proceed before recovery.
  touch /var/lib/dpkg/updates/0000
  if apt-get install -y --no-install-recommends ca-certificates > /tmp/interrupted-apt.log 2>&1; then
    echo "APT unexpectedly accepted an interrupted dpkg journal" >&2
    exit 1
  fi
  grep -q "dpkg was interrupted" /tmp/interrupted-apt.log
  HOME=/root /usr/local/lib/agent-devstation/install-playwright-browser.sh
  test ! -e /var/lib/dpkg/updates/0000
'
docker exec -i -u dev "$optional_name" bash -s < tests/playwright-functional.sh
docker exec -u dev "$optional_name" bash -lc \
  'mkdir -p /home/dev/.cache/ms-playwright && touch /home/dev/.cache/ms-playwright/project-cache-probe'
docker exec -u root -e AGENT_DEVSTATION_DOCKER_CLI_ENABLED=false "$optional_name" /usr/local/lib/agent-devstation/install-docker-cli.sh
docker exec -u root -e AGENT_DEVSTATION_PLAYWRIGHT_CHROMIUM_ENABLED=false "$optional_name" /usr/local/lib/agent-devstation/install-playwright-browser.sh
docker exec -u dev "$optional_name" bash -lc \
  '! command -v docker && test ! -e /opt/agent-devstation-docker-cli && test -L /opt/playwright-browsers && test -w "$PLAYWRIGHT_BROWSERS_PATH" && test -f "$PLAYWRIGHT_BROWSERS_PATH/project-cache-probe" && test ! -e "$PLAYWRIGHT_BROWSERS_PATH/.agent-devstation-installer"'
