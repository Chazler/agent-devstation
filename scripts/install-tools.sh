#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
registry=${AGENT_DEVSTATION_TOOL_REGISTRY:-$script_dir/tools/registry.json}
if [[ ! -f "$registry" && -z "${AGENT_DEVSTATION_TOOL_REGISTRY-}" ]]; then
  registry="$script_dir/../tools/registry.json"
fi
install_prefix=${AGENT_DEVSTATION_TOOL_PREFIX:-/usr/local}
install_root="$install_prefix/lib/agent-devstation/installed-tools"
bin_dir="$install_prefix/bin"
mode=${1-}

fail() {
  echo "$*" >&2
  exit 2
}

validate_registry() {
  # The registry is trusted image content, never downloaded or evaluated as shell.
  jq -e '
    def valid_download:
      (.url | startswith("https://")) and
      (.sha256 | test("^[a-f0-9]{64}$"));

    def valid_custom_installer:
      (.installer | test("^install-[a-z-]+\\.sh$")) and
      (.enabled_env | test("^AGENT_DEVSTATION_[A-Z_]+$"));

    def valid_binary:
      (.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
      ((.version_args // []) | type == "array" and all(.[]; type == "string")) and
      (.versions | type == "object") and
      all(.versions[];
        has("amd64") and has("arm64") and all(.[]; valid_download)
      );

    type == "object" and length > 0 and all(to_entries[];
      (.key | test("^[a-z][a-z0-9-]*$")) and
      (.value.default | type == "boolean") and
      (.value | if .installer then valid_custom_installer else valid_binary end)
    )
  ' "$registry" >/dev/null || fail 'Invalid tool registry'
}

validate_selection() {
  local requested_tool

  if [[ -n "$selection" && ! "$selection" =~ ^[a-z][a-z0-9-]*(,[a-z][a-z0-9-]*)*$ ]]; then
    fail 'AGENT_DEVSTATION_TOOLS must be a comma-separated list of tool names (or empty)'
  fi

  # Reading one name per line also handles an empty selection on macOS Bash 3.
  while IFS= read -r requested_tool; do
    [[ -n "$requested_tool" ]] || continue
    if ! jq -e --arg tool "$requested_tool" 'has($tool)' "$registry" >/dev/null; then
      fail "Unknown tool: $requested_tool"
    fi
  done < <(printf '%s\n' "$selection" | tr ',' '\n')
}

plan_custom_installer() {
  local tool=$1 enabled=$2 installer=$3
  local enabled_env legacy_enabled

  enabled_env=$(jq -r --arg tool "$tool" '.[$tool].enabled_env' "$registry")
  legacy_enabled=${!enabled_env-}
  case "$legacy_enabled" in
    ''|true|false) ;;
    *) fail "$enabled_env must be true or false" ;;
  esac

  # Legacy true adds a tool; false does not veto an explicit registry selection.
  if [[ "$legacy_enabled" == true ]]; then
    enabled=true
  fi
  [[ -x "$script_dir/$installer" ]] || fail "Missing custom installer: $installer"

  printf '%s\t%s\t%s\t%s\n' "$tool" "$enabled" "$installer" "$enabled_env"
}

plan_binary() {
  local tool=$1 enabled=$2
  local version_env default_version version

  version_env=AGENT_DEVSTATION_TOOL_$(printf '%s' "$tool" | tr 'a-z-' 'A-Z_')_VERSION
  default_version=$(jq -r --arg tool "$tool" '.[$tool].version' "$registry")
  version=${!version_env-$default_version}
  if ! jq -e --arg tool "$tool" --arg version "$version" \
    '.[$tool].versions | has($version)' "$registry" >/dev/null; then
    fail "Unsupported $tool version: $version; add verified release assets to the registry first"
  fi

  printf '%s\t%s\tbinary\t%s\n' "$tool" "$enabled" "$version"
}

create_install_plan() {
  local tool enabled installer

  while IFS= read -r tool; do
    enabled=false
    case ",$selection," in
      *",$tool,"*) enabled=true ;;
    esac

    installer=$(jq -r --arg tool "$tool" '.[$tool].installer // empty' "$registry")
    if [[ -n "$installer" ]]; then
      [[ "$mode" != --binaries-only ]] || continue
      plan_custom_installer "$tool" "$enabled" "$installer"
    else
      plan_binary "$tool" "$enabled"
    fi
  done < <(jq -r 'keys[]' "$registry")
}

verify_checksum() {
  local checksum=$1 binary=$2
  printf '%s  %s\n' "$checksum" "$binary" | sha256sum -c - >/dev/null
}

is_managed_link() {
  local link=$1 binary=$2
  [[ -L "$link" && "$(readlink "$link")" == "$binary" ]]
}

check_binary_version() {
  local tool=$1 binary=$2 argument
  local version_args=()

  while IFS= read -r argument; do
    version_args+=("$argument")
  done < <(jq -r --arg tool "$tool" '.[$tool].version_args // [] | .[]' "$registry")

  if [[ ${#version_args[@]} -gt 0 ]]; then
    "$binary" "${version_args[@]}"
  fi
}

install_binary() {
  local tool=$1 enabled=$2 version=$3
  local target="$install_root/$tool"
  local stage="$install_root/.$tool-staging"
  local link="$bin_dir/$tool"
  local checksum url

  rm -rf -- "$stage"
  if [[ "$enabled" == false ]]; then
    # Only remove our own link, never another package's executable.
    if is_managed_link "$link" "$target/$tool"; then
      rm -f -- "$link"
    fi
    rm -rf -- "$target"
    return
  fi

  checksum=$(jq -r --arg tool "$tool" --arg version "$version" --arg arch "$arch" \
    '.[$tool].versions[$version][$arch].sha256' "$registry")
  if [[ -f "$target/.version" && "$(cat "$target/.version")" == "$version" && -x "$target/$tool" ]] \
    && verify_checksum "$checksum" "$target/$tool" 2>/dev/null; then
    echo "Found $tool $version; already installed"
  else
    url=$(jq -r --arg tool "$tool" --arg version "$version" --arg arch "$arch" \
      '.[$tool].versions[$version][$arch].url' "$registry")
    echo "Installing $tool $version"
    mkdir -p "$stage"
    curl -fsSL --connect-timeout 15 --max-time 300 --retry 3 "$url" -o "$stage/$tool"
    verify_checksum "$checksum" "$stage/$tool"
    chmod 0755 "$stage/$tool"
    check_binary_version "$tool" "$stage/$tool"
    printf '%s\n' "$version" > "$stage/.version"
    rm -rf -- "$target"
    mv -- "$stage" "$target"
  fi

  if [[ -e "$link" || -L "$link" ]]; then
    is_managed_link "$link" "$target/$tool" || fail "Refusing to replace unmanaged executable: $link"
  fi
  ln -sfn "$target/$tool" "$link"
}

if [[ $# -gt 1 || ( -n "$mode" && "$mode" != --binaries-only ) ]]; then
  fail 'Usage: install-tools.sh [--binaries-only]'
fi
validate_registry
selection=${AGENT_DEVSTATION_TOOLS-$(jq -r '[to_entries[] | select(.value.default) | .key] | join(",")' "$registry")}
validate_selection
arch=$(dpkg --print-architecture)
case "$arch" in
  amd64|arm64) ;;
  *) fail "Unsupported tool architecture: $arch" ;;
esac

# Validate every tool before installing or removing anything. Plan columns are:
# tool name, enabled flag, installer (or "binary"), version or enable-variable name.
plan=$(mktemp)
trap 'rm -f "$plan"' EXIT
create_install_plan > "$plan"

mkdir -p "$install_root" "$bin_dir"
while IFS=$'\t' read -r tool enabled installer version_or_env; do
  if [[ "$installer" == binary ]]; then
    install_binary "$tool" "$enabled" "$version_or_env"
  else
    env "$version_or_env=$enabled" "$script_dir/$installer"
  fi
done < "$plan"
