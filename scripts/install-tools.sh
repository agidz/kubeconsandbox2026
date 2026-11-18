#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
bin="$root/bin"
versions="$root/versions.yaml"
records="$bin/.versions"

if [[ "$(uname -s)/$(uname -m)" != Linux/x86_64 ]]; then
  printf '%s\n' 'Tool downloads require linux/amd64.' >&2
  exit 1
fi
mkdir -p "$bin"
touch "$records"
stage=$(mktemp -d "$bin/.install.XXXXXX")
trap 'rm -rf -- "$stage"' EXIT

# Read the tools section without yq, which is itself installed by this script.
tool_pins() {
  awk '
    /^[^ #]/ { tools = ($0 ~ /^tools:/) }
    tools && /^  [a-z][a-z-]*:/ {
      split($1, parts, ":")
      tool = parts[1]
      if (match($0, /version: *[^,} ]+/)) {
        pin = substr($0, RSTART, RLENGTH)
        sub(/^version: */, "", pin)
        print tool, pin
      }
    }
    tools && /^    version:/ {
      pin = $2
      gsub(/["\047]/, "", pin)
      print tool, pin
    }
  ' "$versions"
}

fetch() {
  curl --fail --silent --show-error --location --retry 3 "$@"
}

download() {
  local name=$1 version=$2 directory=$3
  local url asset checksums checksum member= column
  case "$name" in
    kubectl)
      url="https://dl.k8s.io/release/$version/bin/linux/amd64"
      asset=kubectl
      checksums=kubectl.sha256
      ;;
    helm)
      url=https://get.helm.sh
      asset="helm-$version-linux-amd64.tar.gz"
      checksums="$asset.sha256sum"
      member=linux-amd64/helm
      ;;
    yq)
      url="https://github.com/mikefarah/yq/releases/download/$version"
      asset=yq_linux_amd64
      checksums=checksums
      ;;
    kind)
      url="https://github.com/kubernetes-sigs/kind/releases/download/$version"
      asset=kind-linux-amd64
      checksums="$asset.sha256sum"
      ;;
    kagent)
      url="https://github.com/kagent-dev/kagent/releases/download/$version"
      asset=kagent-linux-amd64
      checksums="$asset.sha256"
      ;;
    kubectl-ate)
      url="https://github.com/kagent-dev/substrate/releases/download/$version"
      asset=kubectl-ate-linux-amd64
      checksums="$asset.sha256"
      ;;
    oras)
      url="https://github.com/oras-project/oras/releases/download/$version"
      asset="oras_${version#v}_linux_amd64.tar.gz"
      checksums="oras_${version#v}_checksums.txt"
      member=oras
      ;;
    *) printf 'No release recipe for %s\n' "$name" >&2; return 1 ;;
  esac

  fetch --output "$directory/release" "$url/$asset" || return
  case "$name" in
    yq)
      column=$(fetch "$url/checksums_hashes_order" | awk '$0 == "SHA-256" {print NR + 1}') || return
      [[ -n "$column" ]] || return 1
      checksum=$(fetch "$url/$checksums" | awk -v col="$column" -v file="$asset" '$1 == file {print $col}') || return
      ;;
    oras)
      checksum=$(fetch "$url/$checksums" | awk -v file="$asset" '$2 == file {print $1}') || return
      ;;
    *)
      checksum=$(fetch "$url/$checksums" | awk 'NR == 1 {print $1}') || return
      ;;
  esac
  [[ "$checksum" =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
  printf '%s  %s\n' "$checksum" "$directory/release" | sha256sum --check --status || return
  if [[ -n "$member" ]]; then
    tar -xzf "$directory/release" -C "$directory" "$member" || return
    install -m 0755 "$directory/$member" "$bin/$name" || return
  else
    install -m 0755 "$directory/release" "$bin/$name" || return
  fi
}

declare -A pins=()
order=()
while read -r tool version; do
  pins[$tool]=$version
  order+=("$tool")
done < <(tool_pins)
if (($#)); then order=("$@"); fi
if (("${#order[@]}" == 0)); then
  printf '%s\n' 'No executable pins found in versions.yaml.' >&2
  exit 1
fi

status=0
for tool in "${order[@]}"; do
  version=${pins[$tool]:-}
  if [[ -z "$version" ]]; then
    printf 'No version pin for %s\n' "$tool" >&2
    status=1
    continue
  fi
  if [[ -x "$bin/$tool" ]] && grep -Fxq "$tool $version" "$records"; then
    printf '  ✓ %s %s is installed\n' "$tool" "$version"
    continue
  fi
  mkdir -p "$stage/$tool"
  if ! download "$tool" "$version" "$stage/$tool"; then
    printf 'Download or checksum verification failed for %s %s\n' "$tool" "$version" >&2
    status=1
    continue
  fi
  awk -v tool="$tool" '$1 != tool' "$records" > "$stage/versions"
  printf '%s %s\n' "$tool" "$version" >> "$stage/versions"
  mv -f "$stage/versions" "$records"
  printf '  ✓ Installed %s %s\n' "$tool" "$version"
done
exit "$status"
