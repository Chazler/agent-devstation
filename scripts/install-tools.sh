#!/usr/bin/env bash
set -euo pipefail

base=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
registry=${AGENT_DEVSTATION_TOOL_REGISTRY:-$base/tools/registry.json}
if [[ ! -f "$registry" && -z "${AGENT_DEVSTATION_TOOL_REGISTRY-}" ]]; then registry="$base/../tools/registry.json"; fi
prefix=${AGENT_DEVSTATION_TOOL_PREFIX:-/usr/local}
root="$prefix/lib/agent-devstation/installed-tools"
mode=${1-}
[[ $# -le 1 && ( -z "$mode" || "$mode" == --binaries-only ) ]] || { echo 'Usage: install-tools.sh [--binaries-only]' >&2; exit 2; }
fail() { echo "$*" >&2; exit 2; }
# The registry is trusted image content, never downloaded or evaluated as shell.
jq -e 'type == "object" and length > 0 and all(to_entries[];
  (.key | test("^[a-z][a-z0-9-]*$")) and (.value.default | type == "boolean") and
  (if .value.installer then
    (.value.installer | test("^install-[a-z-]+\\.sh$")) and
    (.value.enabled_env | test("^AGENT_DEVSTATION_[A-Z_]+$"))
  else
    (.value.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
    ((.value.version_args // []) | type == "array" and all(.[]; type == "string")) and
    (.value.versions | type == "object") and
    all(.value.versions[]; has("amd64") and has("arm64") and
      all(.[]; (.url | startswith("https://")) and (.sha256 | test("^[a-f0-9]{64}$"))))
  end))' "$registry" >/dev/null || fail 'Invalid tool registry'

selection=${AGENT_DEVSTATION_TOOLS-$(jq -r '[to_entries[] | select(.value.default) | .key] | join(",")' "$registry")}
# Validate the entire request before installing or removing anything.
[[ -z "$selection" || "$selection" =~ ^[a-z][a-z0-9-]*(,[a-z][a-z0-9-]*)*$ ]] || fail 'AGENT_DEVSTATION_TOOLS must be a comma-separated list of tool names (or empty)'
IFS=, read -r -a requested <<< "$selection"
for tool in ${requested[@]+"${requested[@]}"}; do
  [[ -z "$tool" ]] || jq -e --arg tool "$tool" 'has($tool)' "$registry" >/dev/null || fail "Unknown tool: $tool"
done
arch=$(dpkg --print-architecture)
[[ "$arch" == amd64 || "$arch" == arm64 ]] || fail "Unsupported tool architecture: $arch"
plan=$(mktemp)
trap 'rm -f "$plan"' EXIT
while IFS= read -r tool; do
  enabled=false
  case ",$selection," in *",$tool,"*) enabled=true ;; esac
  installer=$(jq -r --arg t "$tool" '.[$t].installer // empty' "$registry")
  if [[ -n "$installer" ]]; then
    [[ "$mode" != --binaries-only ]] || continue
    env_name=$(jq -r --arg t "$tool" '.[$t].enabled_env' "$registry")
    legacy=${!env_name-}
    [[ -z "$legacy" || "$legacy" == true || "$legacy" == false ]] || fail "$env_name must be true or false"
    # Legacy true adds a tool; false does not veto an explicit registry selection.
    [[ "$legacy" != true ]] || enabled=true
    [[ -x "$base/$installer" ]] || fail "Missing custom installer: $installer"
    printf '%s\t%s\t%s\t%s\n' "$tool" "$enabled" "$installer" "$env_name" >> "$plan"
  else
    version_env=AGENT_DEVSTATION_TOOL_$(printf '%s' "$tool" | tr 'a-z-' 'A-Z_')_VERSION
    version=${!version_env-$(jq -r --arg t "$tool" '.[$t].version' "$registry")}
    jq -e --arg t "$tool" --arg v "$version" '.[$t].versions | has($v)' "$registry" >/dev/null || fail "Unsupported $tool version: $version; add verified release assets to the registry first"
    printf '%s\t%s\tbinary\t%s\n' "$tool" "$enabled" "$version" >> "$plan"
  fi
done < <(jq -r 'keys[]' "$registry")

mkdir -p "$root" "$prefix/bin"
while IFS=$'\t' read -r tool enabled installer detail; do
  if [[ "$installer" != binary ]]; then
    env "$detail=$enabled" "$base/$installer"
    continue
  fi
  target="$root/$tool"
  stage="$root/.$tool-staging"
  rm -rf -- "$stage"
  if [[ "$enabled" == false ]]; then
    # Only remove our own link, never another package's executable.
    if [[ -L "$prefix/bin/$tool" && "$(readlink "$prefix/bin/$tool")" == "$target/$tool" ]]; then rm -f -- "$prefix/bin/$tool"; fi
    rm -rf -- "$target"
    continue
  fi
  checksum=$(jq -r --arg t "$tool" --arg v "$detail" --arg a "$arch" '.[$t].versions[$v][$a].sha256' "$registry")
  if [[ -f "$target/.version" && "$(cat "$target/.version")" == "$detail" && -x "$target/$tool" ]] && printf '%s  %s\n' "$checksum" "$target/$tool" | sha256sum -c - >/dev/null 2>&1; then
    echo "Found $tool $detail; already installed"
  else
    mkdir -p "$stage"
    url=$(jq -r --arg t "$tool" --arg v "$detail" --arg a "$arch" '.[$t].versions[$v][$a].url' "$registry")
    echo "Installing $tool $detail"
    curl -fsSL --connect-timeout 15 --max-time 300 --retry 3 "$url" -o "$stage/$tool"
    printf '%s  %s\n' "$checksum" "$stage/$tool" | sha256sum -c - >/dev/null
    chmod 0755 "$stage/$tool"
    version_args=()
    while IFS= read -r arg; do version_args+=("$arg"); done < <(jq -r --arg t "$tool" ' .[$t].version_args // [] | .[]' "$registry")
    if [[ ${#version_args[@]} -gt 0 ]]; then "$stage/$tool" "${version_args[@]}"; fi
    printf '%s\n' "$detail" > "$stage/.version"
    rm -rf -- "$target"
    mv -- "$stage" "$target"
  fi
  if [[ -e "$prefix/bin/$tool" || -L "$prefix/bin/$tool" ]]; then
    [[ -L "$prefix/bin/$tool" && "$(readlink "$prefix/bin/$tool")" == "$target/$tool" ]] || fail "Refusing to replace unmanaged executable: $prefix/bin/$tool"
  fi
  ln -sfn "$target/$tool" "$prefix/bin/$tool"
done < "$plan"
