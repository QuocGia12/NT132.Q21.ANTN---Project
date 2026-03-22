#!/usr/bin/env bash

set -Eeuo pipefail

MODE="${MODE:-smoke}"
BASE_URL="${BASE_URL:-http://blood-bank.com}"
NAMESPACE="${NAMESPACE:-blood-bank}"
OUTPUT_ROOT="${OUTPUT_ROOT:-loadtest/output}"
TOP_INTERVAL="${TOP_INTERVAL:-5}"
RUNNER="${RUNNER:-local}"
K6_FILE="${K6_FILE:-loadtest/k6-webapp.js}"
K6_IMAGE="${K6_IMAGE:-grafana/k6}"
LB_HOST="${LB_HOST:-blood-bank.com}"
LB_IP="${LB_IP:-192.168.245.105}"

FRONTEND_DEPLOYMENT="${FRONTEND_DEPLOYMENT:-blood-bank-frontend-deployment}"
BACKEND_DEPLOYMENT="${BACKEND_DEPLOYMENT:-blood-bank-backend-deployment}"
INGRESS_NAMESPACE="${INGRESS_NAMESPACE:-ingress-nginx}"
INGRESS_DEPLOYMENT="${INGRESS_DEPLOYMENT:-}"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT_DIR="${OUTPUT_ROOT}/${MODE}-${TIMESTAMP}"
mkdir -p "${OUTPUT_DIR}"

PIDS=()

log() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM

  if ((${#PIDS[@]} > 0)); then
    log "Stopping background watchers"
    for pid in "${PIDS[@]}"; do
      kill "${pid}" 2>/dev/null || true
    done
    wait 2>/dev/null || true
  fi

  log "Artifacts saved to ${OUTPUT_DIR}"
  exit "${status}"
}

trap cleanup EXIT INT TERM

start_bg() {
  local name="$1"
  shift

  log "Starting ${name}"
  "$@" >"${OUTPUT_DIR}/${name}.log" 2>&1 &
  PIDS+=("$!")
}

start_top_loop() {
  local name="$1"
  shift

  log "Starting ${name}"
  (
    while true; do
      printf '===== %s =====\n' "$(date --iso-8601=seconds)"
      kubectl "$@" || true
      printf '\n'
      sleep "${TOP_INTERVAL}"
    done
  ) >"${OUTPUT_DIR}/${name}.log" 2>&1 &
  PIDS+=("$!")
}

write_cluster_snapshot() {
  log "Capturing initial cluster snapshots"

  kubectl get pods,svc,ingress -n "${NAMESPACE}" -o wide \
    >"${OUTPUT_DIR}/cluster-snapshot.log" 2>&1 || true

  kubectl describe ingress -n "${NAMESPACE}" \
    >"${OUTPUT_DIR}/ingress-describe.log" 2>&1 || true

  kubectl get events -n "${NAMESPACE}" --sort-by=.metadata.creationTimestamp \
    >"${OUTPUT_DIR}/events-initial.log" 2>&1 || true
}

build_k6_command() {
  local -a cmd

  if [[ "${RUNNER}" == "docker" ]]; then
    require_cmd docker
    cmd=(
      docker run --rm -i
      --add-host "${LB_HOST}:${LB_IP}"
      -v "${PWD}:/work"
      -w /work
      "${K6_IMAGE}"
      run
    )
  else
    require_cmd k6
    cmd=(k6 run)
  fi

  cmd+=(-e "BASE_URL=${BASE_URL}")
  cmd+=(-e "MODE=${MODE}")

  if [[ -n "${LOGIN_EMAIL:-}" ]]; then
    cmd+=(-e "LOGIN_EMAIL=${LOGIN_EMAIL}")
  fi

  if [[ -n "${LOGIN_PASSWORD:-}" ]]; then
    cmd+=(-e "LOGIN_PASSWORD=${LOGIN_PASSWORD}")
  fi

  if [[ -n "${AUTH_TOKEN:-}" ]]; then
    cmd+=(-e "AUTH_TOKEN=${AUTH_TOKEN}")
  fi

  if [[ -n "${VUS:-}" ]]; then
    cmd+=(-e "VUS=${VUS}")
  fi

  if [[ -n "${DURATION:-}" ]]; then
    cmd+=(-e "DURATION=${DURATION}")
  fi

  if [[ -n "${THINK_TIME:-}" ]]; then
    cmd+=(-e "THINK_TIME=${THINK_TIME}")
  fi

  cmd+=("${K6_FILE}")

  printf '%q ' "${cmd[@]}"
}

run_k6() {
  local k6_cmd
  k6_cmd="$(build_k6_command)"

  printf '%s\n' "${k6_cmd}" >"${OUTPUT_DIR}/k6-command.sh"
  log "Running load test with ${RUNNER} runner"

  bash -lc "${k6_cmd}" | tee "${OUTPUT_DIR}/k6.log"
}

main() {
  require_cmd kubectl

  write_cluster_snapshot

  start_bg "pods-watch" kubectl get pods -n "${NAMESPACE}" -w
  start_top_loop "top-pods" top pods -n "${NAMESPACE}"
  start_top_loop "top-nodes" top nodes
  start_bg "backend-logs" kubectl logs -n "${NAMESPACE}" "deploy/${BACKEND_DEPLOYMENT}" -f
  start_bg "frontend-logs" kubectl logs -n "${NAMESPACE}" "deploy/${FRONTEND_DEPLOYMENT}" -f

  if [[ -n "${INGRESS_DEPLOYMENT}" ]]; then
    start_bg "ingress-logs" kubectl logs -n "${INGRESS_NAMESPACE}" "deploy/${INGRESS_DEPLOYMENT}" -f
  fi

  run_k6

  kubectl get events -n "${NAMESPACE}" --sort-by=.metadata.creationTimestamp \
    >"${OUTPUT_DIR}/events-final.log" 2>&1 || true
}

main "$@"
