#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=./lib.sh disable=SC1091
source lib.sh

echo "============================================"
echo "Test: roks-enable-client-ip-preservation"
echo "============================================"

TASK=../../.tekton/tasks/roks-enable-client-ip-preservation-task.yaml

LB_HOSTNAME="0a1b2c3d-eu-de.lb.appdomain.cloud"
ANNOTATION_KEY="service.kubernetes.io/ibm-load-balancer-cloud-provider-enable-features"
FAKE_IBM_KEY="FAKE-IBM-KEY-0123"
K='--kubeconfig */kubeconfig'

# Stub binaries for the calls that are not oc (oc is the harness fake)
STUB_BIN=$(tmp_dir)
STUB_IC_LOG=$(tmp_file)
export STUB_IC_LOG
cat > "${STUB_BIN}/ibmcloud" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_IC_LOG}"
exit 0
EOF
cat > "${STUB_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
echo "203.0.113.10"
EOF
chmod +x "${STUB_BIN}/ibmcloud" "${STUB_BIN}/curl"
export PATH="${STUB_BIN}:${PATH}"

expect_success() {
  if [[ "${TASK_RC}" -ne 0 ]]; then
    echo "${TASK_OUT}"
    fail "expected exit 0, got ${TASK_RC}"
  fi
}

expect_failure() {
  if [[ "${TASK_RC}" -eq 0 ]]; then
    echo "${TASK_OUT}"
    fail "expected a non-zero exit"
  fi
}

expect_output() {
  if ! grep -qF -- "$1" <<< "${TASK_OUT}"; then
    echo "${TASK_OUT}"
    fail "output does not contain '$1'"
  fi
}

# The istio-ingressgateway Service (compact JSON), with the enable-features
# annotation set to $1 unless empty
service_json() {
  jq -cn --arg host "${LB_HOSTNAME}" --arg key "${ANNOTATION_KEY}" --arg value "$1" '{
    metadata: {name: "istio-ingressgateway", namespace: "istio-gateways",
               annotations: (if $value == "" then {"meta.helm.sh/release-name": "istiogateways-001"}
                             else {"meta.helm.sh/release-name": "istiogateways-001", ($key): $value} end)},
    spec: {type: "LoadBalancer", externalTrafficPolicy: "Local"},
    status: {loadBalancer: {ingress: [{hostname: $host}]}}}'
}

# Two ingress gateway pods; $1 is their Ready condition ("True"/"False")
pods_json() {
  jq -cn --arg ready "$1" '{items: [
    {metadata: {name: "gw-a"}, status: {phase: "Running", conditions: [{type: "Ready", status: $ready}]}},
    {metadata: {name: "gw-b"}, status: {phase: "Running", conditions: [{type: "Ready", status: $ready}]}}]}'
}

# Envoy config_dump of the dynamic listeners; arguments: listener filter
# names of 0.0.0.0_8443 in order
dump_json() {
  jq -cn --args '{configs: [{active_state: {listener: {name: "0.0.0.0_8443",
    listener_filters: [$ARGS.positional[] | {name: .}]}}}]}' "$@"
}

# Fresh workspace and fake oc state; the defaults describe a gateway without
# the annotation whose pods already run the PROXY protocol filter
setup() {
  WS=$(tmp_dir)
  printf 'apiVersion: v1\nkind: Config\n' > "${WS}/kubeconfig"
  FAKE_OC_LOG=$(tmp_file)
  FAKE_OC_RULES=$(tmp_file)
  FAKE_OC_STDIN_DIR=$(tmp_dir)
  EXTRA_RULES=$(tmp_file)
  export FAKE_OC_LOG FAKE_OC_RULES FAKE_OC_STDIN_DIR
  : > "${STUB_IC_LOG}"

  SVC_JSON=$(service_json "")
  PODS_JSON=$(pods_json True)
  DUMP_JSON=$(dump_json envoy.filters.listener.proxy_protocol envoy.filters.listener.tls_inspector)

  export CLUSTER_NAME=c1
  export IBMCLOUD_REGION=eu-de
  export IBMCLOUD_RESOURCE_GROUP=redhat-sap-edge-roks-ci
  export ROKS_CREDENTIALS_SECRET_NAME=roks-ci-credentials
  export IBMCLOUD_API_KEY="${FAKE_IBM_KEY}"
  export SVC_WAIT_ATTEMPTS=3 SVC_WAIT_DELAY=0
  export LISTENER_WAIT_ATTEMPTS=3 LISTENER_WAIT_DELAY=0
}

write_rules() {
  {
    cat "${EXTRA_RULES}"
    printf '%s\t%s\t%s\n' \
      "${K} get service istio-ingressgateway -n istio-gateways -o json" 0 "${SVC_JSON}" \
      "${K} get pods -n istio-gateways -l istio=ingressgateway-com.sap.edgelm-istio-gateways -o json" 0 "${PODS_JSON}" \
      "${K} exec -n istio-gateways gw-* -c istio-proxy -- pilot-agent request GET config_dump?resource=dynamic_listeners" 0 "${DUMP_JSON}"
  } > "${FAKE_OC_RULES}"
}

run() {
  write_rules
  TASK_CWD="${WS}" run_task "${TASK}" \
    --param clusterName="${CLUSTER_NAME}" \
    --param roksCredentialsSecretName="${ROKS_CREDENTIALS_SECRET_NAME}" \
    --workspace-dir source="${WS}" \
    --drop '# Install tools' 'echo "✅ Tools installed"'
}

# Line number of the first fake oc call matching an extended regex (0 if none)
call_line() {
  local LINE
  LINE=$(grep -nE -- "$1" "${FAKE_OC_LOG}" | head -1 | cut -d: -f1)
  echo "${LINE:-0}"
}

# Test case: env_wiring
echo ""
echo "Test: env_wiring"
echo "--------------------------------------------"
python3 -I - "${TASK}" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    task = next(d for d in yaml.safe_load_all(f) if d and d.get("kind") == "Task")
errors = []
if task["metadata"]["name"] != "roks-enable-client-ip-preservation":
    errors.append("name should be roks-enable-client-ip-preservation")
params = {p["name"]: p.get("default") for p in task["spec"]["params"]}
expected = {"clusterName": None, "roksCredentialsSecretName": None,
            "ibmcloudRegion": "eu-de", "ibmcloudResourceGroup": "redhat-sap-edge-roks-ci"}
if params != expected:
    errors.append(f"params/defaults differ: {params}")
if [w["name"] for w in task["spec"]["workspaces"]] != ["source"]:
    errors.append("expected exactly the workspace 'source'")
if task["spec"].get("results"):
    errors.append("expected no results")
steps = task["spec"]["steps"]
if len(steps) != 1 or steps[0].get("name") != "enable-client-ip-preservation":
    errors.append("expected one step named enable-client-ip-preservation")
step = steps[0]
if step.get("workingDir") != "$(workspaces.source.path)":
    errors.append("workingDir must be the source workspace")
env = {e["name"]: e for e in step.get("env", [])}
for key, value in {"CLUSTER_NAME": "$(params.clusterName)",
                   "IBMCLOUD_REGION": "$(params.ibmcloudRegion)",
                   "IBMCLOUD_RESOURCE_GROUP": "$(params.ibmcloudResourceGroup)",
                   "ROKS_CREDENTIALS_SECRET_NAME": "$(params.roksCredentialsSecretName)"}.items():
    if env.get(key, {}).get("value") != value:
        errors.append(f"env {key} should be {value}, got {env.get(key)}")
ref = env.get("IBMCLOUD_API_KEY", {}).get("valueFrom", {}).get("secretKeyRef", {})
if ref != {"name": "$(params.roksCredentialsSecretName)", "key": "IBMCLOUD_API_KEY"}:
    errors.append(f"IBMCLOUD_API_KEY must come from the credentials Secret, got {ref}")
script = step["script"]
if "set -x" in script:
    errors.append("script must not use set -x")
if "ibmcloud plugin install vpc-infrastructure -f" not in script:
    errors.append("the IBM Cloud CLI install must add the vpc-infrastructure plugin")
if errors:
    print("\n".join(errors))
    sys.exit(1)
PY
echo "✅ PASS: env_wiring"

# Test case: fresh_setup
# EnvoyFilter first, every pod verified, then the annotation
echo ""
echo "Test: fresh_setup"
echo "--------------------------------------------"
setup
run
expect_success
MANIFEST="${FAKE_OC_STDIN_DIR}/1.yaml"
[[ -f "${MANIFEST}" ]] || fail "no manifest applied"
python3 -I - "${MANIFEST}" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    doc = yaml.safe_load(f)
errors = []
if doc.get("kind") != "EnvoyFilter" or doc.get("apiVersion") != "networking.istio.io/v1alpha3":
    errors.append(f"expected an EnvoyFilter, got {doc.get('apiVersion')} {doc.get('kind')}")
if doc["metadata"] != {"name": "ingressgateway-proxy-protocol", "namespace": "istio-gateways"}:
    errors.append(f"metadata: {doc['metadata']}")
spec = doc["spec"]
if spec.get("workloadSelector") != {"labels": {"istio": "ingressgateway-com.sap.edgelm-istio-gateways"}}:
    errors.append(f"workloadSelector: {spec.get('workloadSelector')}")
patches = spec.get("configPatches", [])
if len(patches) != 1:
    errors.append("expected one config patch")
else:
    p = patches[0]
    if p.get("applyTo") != "LISTENER_FILTER":
        errors.append(f"applyTo: {p.get('applyTo')}")
    if p.get("match") != {"context": "GATEWAY", "listener": {"portNumber": 8443}}:
        errors.append(f"match: {p.get('match')}")
    if p.get("patch", {}).get("operation") != "INSERT_FIRST":
        errors.append(f"operation: {p.get('patch', {}).get('operation')}")
    value = p.get("patch", {}).get("value", {})
    if value.get("name") != "envoy.filters.listener.proxy_protocol":
        errors.append(f"filter name: {value.get('name')}")
    typed = value.get("typed_config", {})
    if typed.get("@type") != "type.googleapis.com/envoy.extensions.filters.listener.proxy_protocol.v3.ProxyProtocol":
        errors.append(f"@type: {typed.get('@type')}")
    if typed.get("allow_requests_without_proxy_protocol") is not True:
        errors.append("allow_requests_without_proxy_protocol must be true")
if errors:
    print("\n".join(errors))
    sys.exit(1)
PY
assert_called "exec -n istio-gateways gw-a -c istio-proxy"
assert_called "exec -n istio-gateways gw-b -c istio-proxy"
assert_called "annotate service istio-ingressgateway -n istio-gateways --overwrite ${ANNOTATION_KEY}=proxy-protocol$"
APPLY_LINE=$(call_line 'apply -f -')
EXEC_LINE=$(call_line 'exec -n istio-gateways gw-b')
ANNOTATE_LINE=$(call_line 'annotate service')
[[ "${APPLY_LINE}" -gt 0 && "${APPLY_LINE}" -lt "${EXEC_LINE}" && "${EXEC_LINE}" -lt "${ANNOTATE_LINE}" ]] ||
  { cat "${FAKE_OC_LOG}"; fail "expected apply, then the listener checks, then the annotation"; }
echo "✅ PASS: fresh_setup"

# Test case: already_set
echo ""
echo "Test: already_set"
echo "--------------------------------------------"
setup
SVC_JSON=$(service_json "proxy-protocol")
run
expect_success
assert_called "apply -f -"
assert_not_called "annotate service"
echo "✅ PASS: already_set"

# Test case: existing_feature_value
echo ""
echo "Test: existing_feature_value"
echo "--------------------------------------------"
setup
SVC_JSON=$(service_json "foo")
run
expect_success
assert_called "annotate service istio-ingressgateway -n istio-gateways --overwrite ${ANNOTATION_KEY}=foo,proxy-protocol$"
echo "✅ PASS: existing_feature_value"

# Test case: listener_never_ready
# The ALB must not be switched while a pod lacks the filter
echo ""
echo "Test: listener_never_ready"
echo "--------------------------------------------"
setup
DUMP_JSON=$(dump_json envoy.filters.listener.tls_inspector)
export LISTENER_WAIT_ATTEMPTS=2
run
expect_failure
expect_output "gw-a"
expect_output "0.0.0.0_8443"
assert_not_called "annotate service"
echo "✅ PASS: listener_never_ready"

# Test case: service_missing
echo ""
echo "Test: service_missing"
echo "--------------------------------------------"
setup
printf '%s\t%s\t%s\n' "${K} get service istio-ingressgateway -n istio-gateways -o json" 1 \
  'Error from server (NotFound): services "istio-ingressgateway" not found' > "${EXTRA_RULES}"
export SVC_WAIT_ATTEMPTS=2
run
expect_failure
expect_output "istio-gateways/istio-ingressgateway"
assert_not_called "apply -f -"
echo "✅ PASS: service_missing"

# Test case: no_ready_pods
echo ""
echo "Test: no_ready_pods"
echo "--------------------------------------------"
setup
PODS_JSON=$(pods_json False)
export SVC_WAIT_ATTEMPTS=2
run
expect_failure
assert_not_called "apply -f -"
echo "✅ PASS: no_ready_pods"

echo ""
echo "============================================"
echo "✅ All roks-enable-client-ip-preservation tests passed"
echo "============================================"
