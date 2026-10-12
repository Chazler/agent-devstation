#!/usr/bin/env bash
set -euo pipefail

# Cache real upstream metadata, then corrupt it to test both verification
# gates without extra requests or fake signing keys.
review_dir=$(mktemp -d)
trap 'rm -rf "$review_dir"' EXIT
export RESOLVER_CURL_BIN
RESOLVER_CURL_BIN=$(command -v curl)
export RESOLVER_CACHE="$review_dir/cache"
mkdir -p "$review_dir/bin" "$RESOLVER_CACHE"
cat > "$review_dir/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
url='' output=''
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    https://*) url=${args[i]} ;;
    -o) output=${args[i+1]} ;;
  esac
done
[[ -n "$url" && -n "$output" ]]
cache_key=$(printf '%s' "$url" | sha256sum | cut -d ' ' -f 1)
if [[ -f "$RESOLVER_CACHE/$cache_key" ]]; then
  cp "$RESOLVER_CACHE/$cache_key" "$output"
else
  "$RESOLVER_CURL_BIN" "$@"
  cp "$output" "$RESOLVER_CACHE/$cache_key"
fi
case "${RESOLVER_FAULT-}" in
  checksum)
    [[ "$url" != "$RESOLVER_TARGET"*/Packages.gz ]] || printf 'corrupted' >> "$output"
    ;;
  signature)
    [[ "$url" != "$RESOLVER_TARGET"*/InRelease ]] || sed -i 's/^SHA256:/SHA256: corrupted/' "$output"
    ;;
esac
SH
chmod 755 "$review_dir/bin/curl"
export PATH="$review_dir/bin:$PATH"

bash scripts/resolve-image-versions.sh > "$review_dir/versions"
for package in codex claude gh uv; do
  grep -Eq "^$package=[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?$" "$review_dir/versions"
done
for fault in checksum signature; do
  for target in https://cli.github.com/packages https://downloads.claude.ai/claude-code/apt; do
    if RESOLVER_FAULT="$fault" RESOLVER_TARGET="$target" \
      bash scripts/resolve-image-versions.sh > "$review_dir/output" 2> "$review_dir/error"; then
      echo "Resolver accepted $fault corruption in $target" >&2
      exit 1
    fi
    test ! -s "$review_dir/output"
    if [[ "$fault" == signature ]]; then
      grep -q 'BAD signature' "$review_dir/error"
    else
      grep -q 'Checksum mismatch' "$review_dir/error"
    fi
  done
done
echo 'Signed metadata and checksum rejection checks passed' >&2
cat "$review_dir/versions"
