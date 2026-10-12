#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

# Resolve once per workflow so both architectures install the same stable
# built-in CLIs. APT versions must be available in both signed package indexes.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GNUPGHOME="$tmp/gnupg"
mkdir -m 0700 "$GNUPGHOME"

fetch() {
  curl -fsSL --connect-timeout 15 --max-time 60 --retry 3 "$1" -o "$2"
}

resolve_apt_version() {
  local package=$1 base=$2 key_url=$3 expected_fingerprint=$4
  local arch path hash candidate latest=''
  fetch "$key_url" "$tmp/$package.key"
  gpg --batch --show-keys --with-colons "$tmp/$package.key" | awk -F: '
    $1 == "pub" { primary = 1; next }
    primary && $1 == "fpr" { print $10; primary = 0 }
  ' > "$tmp/$package.fingerprints"
  grep -Fxq "$expected_fingerprint" "$tmp/$package.fingerprints" || {
    echo "Unexpected $package apt signing key" >&2
    exit 1
  }
  gpg --batch --import "$tmp/$package.key" >&2
  gpg --batch --export "$expected_fingerprint" > "$tmp/$package.gpg"
  fetch "$base/InRelease" "$tmp/$package.InRelease"
  gpgv --keyring "$tmp/$package.gpg" "$tmp/$package.InRelease" >&2

  for arch in amd64 arm64; do
    path="main/binary-$arch/Packages.gz"
    hash=$(awk -v path="$path" '
      /^SHA256:$/ { in_sha256 = 1; next }
      in_sha256 && /^[^ ]/ { exit }
      in_sha256 && $3 == path { print $1; exit }
    ' "$tmp/$package.InRelease")
    [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || { echo "No SHA256 for $package $path" >&2; exit 1; }
    fetch "$base/$path" "$tmp/$package-$arch.gz"
    if ! printf '%s  %s\n' "$hash" "$tmp/$package-$arch.gz" | sha256sum --check --status; then
      echo "Checksum mismatch for $package $arch package index" >&2
      exit 1
    fi
    gzip -dc "$tmp/$package-$arch.gz" | awk -v package="$package" '
      BEGIN { RS = ""; FS = "\n" }
      {
        name = ""; version = ""
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^Package: /) name = substr($i, 10)
          if ($i ~ /^Version: /) version = substr($i, 10)
        }
        if (name == package && version != "") print version
      }
    ' | sort -u > "$tmp/$package-$arch.versions"
  done

  while IFS= read -r candidate; do
    if [[ -z "$latest" ]] || dpkg --compare-versions "$candidate" gt "$latest"; then latest=$candidate; fi
  done < <(comm -12 "$tmp/$package-amd64.versions" "$tmp/$package-arm64.versions")
  [[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?$ ]] || {
    echo "No common stable $package version for AMD64 and ARM64" >&2
    exit 1
  }
  printf '%s\n' "$latest"
}

fetch https://releases.openai.com/codex/channels/latest "$tmp/codex.json"
codex=$(jq -er '.tag_name | capture("^rust-v(?<version>[0-9]+\\.[0-9]+\\.[0-9]+)$").version' "$tmp/codex.json")

fetch https://api.github.com/repos/astral-sh/uv/releases/latest "$tmp/uv.json"
jq -e '(.draft == false and .prerelease == false) and
  ([.assets[].name] | contains(["uv-x86_64-unknown-linux-gnu.tar.gz", "uv-aarch64-unknown-linux-gnu.tar.gz"]))' \
  "$tmp/uv.json" >/dev/null || { echo 'Latest stable uv release must provide AMD64 and ARM64 Linux binaries' >&2; exit 1; }
uv=$(jq -er '.tag_name | capture("^v?(?<version>[0-9]+\\.[0-9]+\\.[0-9]+)$").version' "$tmp/uv.json")

gh=$(resolve_apt_version gh https://cli.github.com/packages/dists/stable \
  https://cli.github.com/packages/githubcli-archive-keyring.gpg 7F38BBB59D064DBCB3D84D725612B36462313325)
claude=$(resolve_apt_version claude-code https://downloads.claude.ai/claude-code/apt/stable/dists/stable \
  https://downloads.claude.ai/keys/claude-code.asc 31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE)

printf 'codex=%s\nclaude=%s\ngh=%s\nuv=%s\n' "$codex" "$claude" "$gh" "$uv"
printf 'Resolved stable built-ins: Codex %s, Claude Code %s, GitHub CLI %s, uv %s\n' "$codex" "$claude" "$gh" "$uv" >&2
