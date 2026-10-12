#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SparkQwen: Qwen3.8-Flash-Next on two DGX Sparks, served by Atlas. Run on the
# Spark that will serve the API (rank 0); the other one (rank 1) is driven over ssh.
#
#   ./start.sh              prepare whatever is missing, then serve
#   ./start.sh stop         stop both ranks
#   ./start.sh status       container state and health
#   ./start.sh logs [worker]
#   ./start.sh build | download    run one preparation step
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
if [[ -f .env ]]; then set -a; . ./.env; set +a; fi
: "${WORKER:?set WORKER in .env to the ssh destination of the other Spark (see .env.example)}"
[[ $WORKER != -* ]] || { echo "WORKER must be an ssh destination, not an option: $WORKER" >&2; exit 2; }
MODEL_ROOT=${MODEL_ROOT:-$HOME/models/sparkqwen}
PROFILE=${PROFILE:-8x32k}
IMAGE=${IMAGE:-$(install/build.sh --tag)}
read -r CHECKPOINT_REPO CHECKPOINT_REVISION < <(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m["repository"], m["revision"])' install/checkpoint.json)
MODEL=qwen3.8-flash-next-atlas
API=http://127.0.0.1:8893
NAME=atlas-sparkqwen-rank

say() { printf '\033[1m== %s\033[0m\n' "$*"; }
# Run a command on the worker; ssh joins its arguments into one shell line, so quote each.
on_worker() { ssh -o BatchMode=yes "$WORKER" "$(printf '%q ' "$@")"; }
# Run a local script on the worker with safely quoted arguments.
script_on_worker() { local script=$1; shift; on_worker bash -s -- "$@" < "$script"; }
has_image() { docker image inspect "$IMAGE" >/dev/null 2>&1; }

# Each Spark's RoCE ports whose link is up and that have an IPv4 address, one
# "<hca> <interface> <address/prefix>" line each. Only PCIe domain 0 (rocep*):
# the engine adds the device behind the other domain of the same port itself.
fabric_ports() {
  local dev net cidr
  for dev in /sys/class/infiniband/rocep*; do
    grep -qs ACTIVE "$dev/ports/1/state" || continue
    for net in "$dev"/device/net/*; do
      cidr=$(ip -4 -o addr show dev "${net##*/}" 2>/dev/null | awk '{print $4; exit}')
      [[ -n $cidr ]] && echo "${dev##*/} ${net##*/} $cidr"
    done
  done
}

# Pick the fabric port on each Spark: the pair of active ports on the same IPv4
# subnet is the cable between them. Sets hca0/iface0/ip0 (here) and hca1/ip1
# (the worker). FABRIC_HCA in .env overrides it for both.
pick_fabric() {
  local here there choice
  here=$(fabric_ports)
  there=$(on_worker bash -s <<< "$(declare -f fabric_ports); fabric_ports")
  [[ -n $here ]] || { echo "no RoCE port with its link up and an IPv4 address on this Spark; check the cable and the port's address, or set FABRIC_HCA in .env" >&2; exit 2; }
  [[ -n $there ]] || { echo "no RoCE port with its link up and an IPv4 address on $WORKER; check the cable and the port's address, or set FABRIC_HCA in .env" >&2; exit 2; }
  choice=$(python3 - "$here" "$there" <<'PY'
import ipaddress, sys
parse = lambda text: [line.split() for line in text.splitlines() if len(line.split()) == 3]
here, there = parse(sys.argv[1]), parse(sys.argv[2])
net = lambda cidr: ipaddress.ip_interface(cidr).network
match = [(a, b) for a in here for b in there if net(a[2]) == net(b[2])]
a, b = match[0] if match else (here[0], there[0])
print(a[0], a[1], a[2].split('/')[0], b[0], b[1], b[2].split('/')[0], 'subnet' if match else 'first')
PY
)
  read -r hca0 iface0 ip0 hca1 iface1 ip1 how <<< "$choice"
  if [[ $how == subnet ]]; then
    say "fabric: $hca0 ($iface0, $ip0) here, $hca1 ($iface1, $ip1) on $WORKER; set FABRIC_HCA in .env to choose another port"
  else
    say "fabric: no active port pair shares a subnet; using $hca0 ($iface0, $ip0) here and $hca1 ($iface1, $ip1) on $WORKER. If they are not cabled to each other, set FABRIC_HCA in .env"
  fi
}

# The image for this checkout is pulled from ghcr.io/enntity/atlas-sparkqwen
# (its tag is the install/ tree); if that tag is not published, it is built
# from source. PULL=0 always builds.
build() {
  say "image $IMAGE"
  if ! has_image; then
    if [[ ${PULL:-1} != 1 ]] || ! docker pull "$IMAGE"; then
      say "building $IMAGE from source (a cold build takes 30-60 minutes)"
      IMAGE=$(install/build.sh)
    fi
  fi
  if ! on_worker docker image inspect "$IMAGE" >/dev/null 2>&1; then
    if [[ ${PULL:-1} != 1 ]] || ! on_worker docker pull "$IMAGE"; then
      say "copying the image to $WORKER"; docker save "$IMAGE" | on_worker docker load
    fi
  fi
}

hf_download() {  # repo revision dir; uses a throwaway container when hf is not installed
  if command -v hf >/dev/null; then
    hf download "$1" --revision "$2" --local-dir "$3"
  else
    # The image by digest and every package by hash (install/hf-requirements.txt).
    docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e HF_TOKEN -v "$MODEL_ROOT:$MODEL_ROOT" \
      -v "$PWD/install/hf-requirements.txt:/hf-requirements.txt:ro" \
      python:3.12-slim@sha256:05cda9777409a9c3ffddd94a4c476b79f0769a0b4857f0c7ed9226b6800b0d6f \
      sh -c 'pip install -q --disable-pip-version-check --require-hashes --target /tmp/hf -r /hf-requirements.txt &&
        PYTHONPATH=/tmp/hf /tmp/hf/bin/hf download "$0" --revision "$1" --local-dir "$2"' "$1" "$2" "$3"
  fi
}

# One ssh stream moves ~0.5 GB/s; eight parallel streams fill ~3.5 GB/s of the
# cable. The final rsync picks up the small files and anything left over.
copy_to_worker() {  # directory name under MODEL_ROOT
  on_worker mkdir -p "$MODEL_ROOT"
  (cd "$MODEL_ROOT" && find "$1" -type f -size +64M ! -name '*.incomplete' -print0) |
    xargs -0 -P8 -I{} rsync -aR -e 'ssh -c aes128-gcm@openssh.com' "$MODEL_ROOT/./{}" "$WORKER:$MODEL_ROOT/"
  rsync -a --exclude "*.incomplete" "$MODEL_ROOT/$1" "$WORKER:$MODEL_ROOT/"
}

# Download the pinned checkpoint once, then mirror it to the worker. The marker
# is written only after both copies are complete.
download() {
  local dir="$MODEL_ROOT/${CHECKPOINT_REPO/\//--}"
  [[ $(cat "$dir/.sparkqwen-revision" 2>/dev/null) == "$CHECKPOINT_REVISION" ]] && return
  say "download $CHECKPOINT_REPO @ $CHECKPOINT_REVISION"
  hf_download "$CHECKPOINT_REPO" "$CHECKPOINT_REVISION" "$dir"
  say "copy $CHECKPOINT_REPO to $WORKER:$MODEL_ROOT"
  copy_to_worker "${dir##*/}"
  echo "$CHECKPOINT_REVISION" > "$dir/.sparkqwen-revision"
}

stop() {
  docker rm -f "${NAME}0" >/dev/null 2>&1 || true
  on_worker docker rm -f "${NAME}1" >/dev/null 2>&1 || true
}

state() { docker inspect -f '{{.State.Status}}' "${NAME}0" 2>/dev/null || echo absent; }
worker_state() { on_worker docker inspect -f '{{.State.Status}}' "${NAME}1" 2>/dev/null || echo absent; }

switch() {  # NAME FLAG: append FLAG to common when the .env switch NAME is 1
  case ${!1:-0} in
    0) ;;
    1) common+=("$2") ;;
    *) echo "$1 must be 0 or 1" >&2; exit 2 ;;
  esac
}

serve() {
  local iface address common hca0 iface0 ip0 hca1 iface1 ip1 how
  if [[ -n ${FABRIC_HCA:-} ]]; then
    hca0=$FABRIC_HCA hca1=$FABRIC_HCA
  else
    pick_fabric
  fi
  iface=${FABRIC_INTERFACE:-$(ls "/sys/class/infiniband/$hca0/device/net" 2>/dev/null | head -1)}
  address=${LEADER_ADDRESS:-}
  [[ -n $address ]] || address=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{sub("/.*", "", $4); print $4; exit}')
  [[ -n $address ]] || { echo "no IPv4 address on the fabric interface '$iface'; set LEADER_ADDRESS" >&2; exit 2; }
  common=(--leader-address "$address" --model-root "$MODEL_ROOT" --image "$IMAGE"
          --profile "$PROFILE" ${FABRIC_INTERFACE:+--fabric-interface "$FABRIC_INTERFACE"}
          ${GPU_MEMORY_UTILIZATION:+--gpu-memory-utilization "$GPU_MEMORY_UTILIZATION"})
  switch FP8_GDN --fp8-gdn
  say "start rank 1 on $WORKER, then rank 0 here (leader $address, profile $PROFILE)"
  stop
  script_on_worker install/start-node.sh --rank 1 --fabric-hca "$hca1" "${common[@]}"
  install/start-node.sh --rank 0 --fabric-hca "$hca0" "${common[@]}"
  say "loading (a few minutes; the first start also compiles CUDA kernels)"
  for ((i = 0; i < 90; i++)); do
    if curl -sf "$API/health" >/dev/null; then
      say "ready: $API/v1 model $MODEL"
      curl -s "$API/v1/chat/completions" -H 'Content-Type: application/json' -d '{"model": "'"$MODEL"'",
        "max_tokens": 256, "temperature": 0, "messages": [{"role": "user", "content": "What is 17*23? Answer with the number."}]}' |
        python3 -c 'import json,sys; m=json.load(sys.stdin)["choices"][0]["message"]; print("smoke: 17*23 =", (m.get("content") or "").strip())'
      return
    fi
    if [[ $(state) != running ]]; then docker logs --tail 40 "${NAME}0"; echo 'rank 0 stopped' >&2; exit 1; fi
    if [[ $(worker_state) != running ]]; then on_worker docker logs --tail 40 "${NAME}1"; echo 'rank 1 stopped' >&2; exit 1; fi
    sleep 10
  done
  echo 'not ready after 15 minutes; see ./start.sh logs' >&2; exit 1
}

mkdir -p "$MODEL_ROOT"; MODEL_ROOT=$(realpath "$MODEL_ROOT")
case ${1:-up} in
  up) build; download; serve ;;
  build | download | stop) "$1" ;;
  status)
    echo "image  $IMAGE"
    echo "rank 0 $(state)"; echo "rank 1 $(worker_state) ($WORKER)"
    curl -sf "$API/health" >/dev/null && echo "health ok ($API)" || echo 'health: not serving' ;;
  logs) if [[ ${2:-} == worker ]]; then on_worker docker logs -f --tail 100 "${NAME}1"; else docker logs -f --tail 100 "${NAME}0"; fi ;;
  *) sed -n '5,10p' "$0" >&2; exit 2 ;;
esac
