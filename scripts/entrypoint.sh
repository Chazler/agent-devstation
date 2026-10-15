#!/usr/bin/env bash
set -euo pipefail

editor_enabled=${AGENT_DEVSTATION_VSCODE_EDITOR_ENABLED-${VSCODE_EDITOR_ENABLED-false}}
editor_password=${AGENT_DEVSTATION_VSCODE_PASSWORD-${VSCODE_PASSWORD-${PASSWORD-}}}
docker_cli_enabled=${AGENT_DEVSTATION_DOCKER_CLI_ENABLED-false}
playwright_chromium_enabled=${AGENT_DEVSTATION_PLAYWRIGHT_CHROMIUM_ENABLED-false}
dev_uid=${AGENT_DEVSTATION_UID-${DEV_UID-1000}}
dev_gid=${AGENT_DEVSTATION_GID-${DEV_GID-1000}}

case "$editor_enabled" in
  true|false) ;;
  *) echo 'AGENT_DEVSTATION_VSCODE_EDITOR_ENABLED must be true or false' >&2; exit 2 ;;
esac
for setting in "$docker_cli_enabled" "$playwright_chromium_enabled"; do
  case "$setting" in
    true|false) ;;
    *) echo 'AGENT_DEVSTATION_DOCKER_CLI_ENABLED and AGENT_DEVSTATION_PLAYWRIGHT_CHROMIUM_ENABLED must be true or false' >&2; exit 2 ;;
  esac
done

if [[ "$editor_enabled" == true && -z "$editor_password" ]]; then
  echo 'AGENT_DEVSTATION_VSCODE_PASSWORD is required when the editor is enabled' >&2
  exit 2
fi

for value in "$dev_uid" "$dev_gid"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || { echo 'AGENT_DEVSTATION_UID and AGENT_DEVSTATION_GID must be positive integers' >&2; exit 2; }
done

if [[ "$dev_gid" != "$(id -g dev)" ]]; then groupmod -o -g "$dev_gid" dev; fi
if [[ "$dev_uid" != "$(id -u dev)" ]]; then
  # usermod -u recursively changes files under the recorded home directory.
  # Temporarily point it elsewhere so it cannot chown mounted projects.
  usermod -o -d /.agent-devstation-uid-change -u "$dev_uid" dev
  usermod -d /home/dev dev
fi
workspace_dir=/home/dev/workspaces
if [[ "$(stat -c %u:%g /home/dev)" != "$(id -u dev):$(id -g dev)" ]]; then
  # Never change ownership of project files through the nested bind mount.
  chown dev:dev /home/dev
  find /home/dev -mindepth 1 -path /home/dev/workspaces -prune -o -exec chown -h dev:dev {} +
fi
if ! gosu dev test -w /home/dev || ! gosu dev test -x /home/dev; then
  echo "/home/dev is not accessible to dev (UID $(id -u dev), GID $(id -g dev); directory owner $(stat -c %u:%g /home/dev)). Fix ownership or permissions of the home volume." >&2
  exit 1
fi
if [[ "$(stat -c %u:%g /opt/codex)" != "$(id -u dev):$(id -g dev)" ]]; then
  chown -R dev:dev /opt/codex
fi
dev_can_create_workspace() {
  gosu dev test -w "$workspace_dir" && gosu dev test -x "$workspace_dir"
}
mkdir -p "$workspace_dir"
if ! mountpoint -q "$workspace_dir"; then
  if [[ "$(stat -c %u:%g "$workspace_dir")" != "$(id -u dev):$(id -g dev)" ]]; then
    chown dev:dev "$workspace_dir"
  fi
elif ! dev_can_create_workspace \
  && [[ "$(stat -c %u "$workspace_dir")" == 0 ]] \
  && [[ -z "$(find "$workspace_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  # Compose creates a missing ./workspaces bind source as an empty root-owned
  # directory on Linux. Claim only that empty mount, never existing projects.
  echo "Claiming empty root-owned $workspace_dir mount for dev"
  if ! chown dev:dev "$workspace_dir"; then
    echo "Could not claim the empty $workspace_dir mount" >&2
  fi
fi
if ! dev_can_create_workspace; then
  echo "$workspace_dir is not writable by dev (UID $(id -u dev), GID $(id -g dev); directory owner $(stat -c %u:%g "$workspace_dir")). Set AGENT_DEVSTATION_UID/GID to the host owner or fix ownership of the mounted workspaces directory." >&2
  exit 1
fi
mkdir -p /home/dev/.codex /home/dev/.claude /home/dev/.local/share/code-server
chown dev:dev /home/dev /home/dev/.codex /home/dev/.claude /home/dev/.local /home/dev/.local/share
chown -R dev:dev /home/dev/.local/share/code-server

# CODEX_HOME persists, while the daemon package under /opt/codex and /tmp do
# not survive container recreation. A missing package needs a fresh bootstrap;
# on a normal restart only its dead process records and socket need clearing.
codex_daemon_dir=/home/dev/.codex/app-server-daemon
if [[ -d "$codex_daemon_dir" ]]; then
  if [[ ! -x /home/dev/.codex/packages/app-server-daemon/current/bin/codex ]]; then
    echo 'Clearing stale Codex daemon state'
    rm -rf -- "$codex_daemon_dir"
  else
    rm -f -- "$codex_daemon_dir"/daemon.pid "$codex_daemon_dir"/daemon-updater.pid \
      "$codex_daemon_dir"/app-server.pid "$codex_daemon_dir"/app-server-updater.pid \
      "$codex_daemon_dir"/daemon-updater.sock
  fi
fi
rm -f -- /home/dev/.codex/app-server-control/app-server-control.sock

if [[ "$editor_enabled" == false ]]; then
  # Remove the editor before SDK downloads, which may fail or take a while.
  if [[ -e /opt/code-server || -L /opt/code-server \
    || -e /opt/.agent-devstation-code-server-staging || -L /opt/.agent-devstation-code-server-staging \
    || -e /usr/local/bin/code-server || -L /usr/local/bin/code-server ]]; then
    echo 'Uninstalling code-server (editor disabled)' >&2
  else
    echo 'code-server disabled; not installed' >&2
  fi
  rm -f -- /usr/local/bin/code-server
  rm -rf -- /opt/code-server /opt/.agent-devstation-code-server-staging
fi

# Installers run as root, but HOME belongs to dev in normal sessions. Keep
# installer caches out of the persisted dev home.
HOME=/root /usr/local/lib/agent-devstation/install-sdks.sh >&2
HOME=/root /usr/local/lib/agent-devstation/install-tools.sh >&2
chown dev:dev /opt/sdk
for sdk_dir in /opt/sdk/*; do
  [[ -e "$sdk_dir" ]] || continue
  if [[ "$(stat -c %u:%g "$sdk_dir")" != "$(id -u dev):$(id -g dev)" ]]; then
    chown -R dev:dev "$sdk_dir"
  fi
done
if [[ -d /home/dev/.cache && ! -L /home/dev/.cache && ! -e /home/dev/.cache/.agent-devstation-ownership-v1 ]]; then
  # Older images could leave root-owned files inside a dev-owned cache. Repair
  # the persisted volume once, without walking a large cache on every restart.
  chown -R dev:dev /home/dev/.cache
  touch /home/dev/.cache/.agent-devstation-ownership-v1
  chown dev:dev /home/dev/.cache/.agent-devstation-ownership-v1
fi

if [[ "$editor_enabled" == true ]]; then
  /usr/local/lib/agent-devstation/install-editor.sh >&2
fi

if [[ $# -gt 0 ]]; then
  exec gosu dev "$@"
fi

if [[ -f /home/dev/.codex/.agent-devstation-remote-control-enabled ]]; then
  echo 'Resuming Codex Remote Control'
  if ! gosu dev codex remote-control start; then
    echo 'Codex Remote Control did not start; check the logs and run codex remote-control start after resolving the error' >&2
  fi
fi

if [[ "$editor_enabled" == true ]]; then
  # code-server uses PASSWORD internally; users configure the namespaced setting.
  exec gosu dev env PASSWORD="$editor_password" code-server --bind-addr 0.0.0.0:8080 --auth password "$workspace_dir"
fi

exec gosu dev sleep infinity
