#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=""
case "${BASH_SOURCE[0]}" in
  */*) SCRIPT_DIR="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)" ;;
  *) SCRIPT_DIR="$(pwd)" ;;
esac
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT
readonly CHART_DIR="${REPO_ROOT}/charts/matrix-rtc-operator"
readonly OK_MESSAGE="OK: matrix-rtc-operator BYO-STUNner gating + status-controller delabel verified"

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

render_chart() {
  cd "${CHART_DIR}"
  helm template t .
}

controller_body() {
  local controller="$1"

  awk -v controller="${controller}" '
    $0 ~ "^[[:space:]]*- name: " controller "$" { in_controller = 1; print; next }
    in_controller && $0 ~ "^[[:space:]]*- name: " { exit }
    in_controller { print }
  '
}

count_occurrences() {
  local needle="$1"

  grep -F -c -- "${needle}" || true
}

assert_contains() {
  local controller="$1"
  local body="$2"
  local needle="$3"
  local description="$4"

  if ! grep -F -q -- "${needle}" <<<"${body}"; then
    fail "${controller}: missing ${description}"
  fi
}

assert_count() {
  local controller="$1"
  local body="$2"
  local needle="$3"
  local expected="$4"
  local description="$5"
  local actual

  actual="$(count_occurrences "${needle}" <<<"${body}")"
  if [[ "${actual}" != "${expected}" ]]; then
    fail "${controller}: expected ${expected} ${description}, found ${actual}"
  fi
}

require_controller() {
  local rendered="$1"
  local controller="$2"
  local body

  body="$(controller_body "${controller}" <<<"${rendered}")"
  if [[ -z "${body}" ]]; then
    fail "${controller}: controller not found in rendered chart"
  fi

  printf '%s' "${body}"
}

assert_managed_stunner_controller() {
  local rendered="$1"
  local controller="$2"
  local body

  body="$(require_controller "${rendered}" "${controller}")"

  assert_contains "${controller}" "${body}" "$.metadata.labels['matrixrtc.lukacsi.org/stunner']" "stunner label selector"
  assert_contains "${controller}" "${body}" "- \"enabled\"" "stunner enabled equality value"
  assert_count "${controller}" "${body}" '$.spec.stunner.managed' 1 'managed gate reference'
  assert_count "${controller}" "${body}" '- "@definedOr": ["$.spec.stunner.managed", true]' 1 '@definedOr managed gate'
}

assert_certmanager_controller() {
  local rendered="$1"
  local controller="$2"
  local body

  body="$(require_controller "${rendered}" "${controller}")"

  assert_contains "${controller}" "${body}" "$.metadata.labels['matrixrtc.lukacsi.org/certmanager']" "certmanager label selector"
  assert_contains "${controller}" "${body}" "- \"enabled\"" "certmanager enabled equality value"
}

main() {
  local rendered
  local status_body

  rendered="$(render_chart)"

  assert_managed_stunner_controller "${rendered}" infra-to-stunner-config
  assert_managed_stunner_controller "${rendered}" infra-to-stunner-gatewayclass
  assert_managed_stunner_controller "${rendered}" infra-to-stunner-gateway

  status_body="$(require_controller "${rendered}" stunner-gateway-status-to-infra)"
  assert_count stunner-gateway-status-to-infra "${status_body}" 'app.kubernetes.io/managed-by' 0 'managed-by labels/selectors'

  assert_certmanager_controller "${rendered}" infra-to-certificate
  assert_certmanager_controller "${rendered}" infra-to-clusterissuer

  printf '%s\n' "${OK_MESSAGE}"
}

main "$@"
