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
STUB_LBS=$(tmp_file)
STUB_LB_STATUSES=$(tmp_file)
STUB_LISTENERS=$(tmp_file)
STUB_STATE_DIR=$(tmp_dir)
export STUB_IC_LOG STUB_LBS STUB_LB_STATUSES STUB_LISTENERS STUB_STATE_DIR

# Stub ibmcloud: logs every call; login only works with the API key in the
# environment; the load balancer list comes from STUB_LBS; each status poll
# prints the next line of STUB_LB_STATUSES and each listener poll the next
# line of STUB_LISTENERS (the last line repeats)
cat > "${STUB_BIN}/ibmcloud" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${STUB_IC_LOG}"
next_line() {
  local N TOTAL
  N=$(( $(cat "${STUB_STATE_DIR}/$2" 2>/dev/null || echo 0) + 1 ))
  echo "${N}" > "${STUB_STATE_DIR}/$2"
  TOTAL=$(wc -l < "$1")
  if [[ ${N} -gt ${TOTAL} ]]; then
    N=${TOTAL}
  fi
  sed -n "${N}p" "$1"
}
case "$*" in
  "login "*)
    if [[ -z "${IBMCLOUD_API_KEY:-}" ]]; then
      echo "FAILED: no API key in IBMCLOUD_API_KEY" >&2
      exit 1
    fi
    echo "OK"
    ;;
  "is load-balancers --all-resource-groups --output JSON") cat "${STUB_LBS}" ;;
  "is load-balancer "*" --output JSON")
    jq -cn --arg id "$3" --arg status "$(next_line "${STUB_LB_STATUSES}" status)" '{id: $id, provisioning_status: $status}'
    ;;
  "is load-balancer-listeners "*" --output JSON") next_line "${STUB_LISTENERS}" listeners ;;
  *) echo "unexpected ibmcloud call: $*" >&2; exit 1 ;;
esac
EOF
# Stub curl: the pipeline cluster has IPv4 and IPv6 egress; only -4 gives the
# IPv4 address the endpoint tests reach the ALB from
cat > "${STUB_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "${STUB_CURL_FAIL:-0}" == "1" ]]; then
  echo "curl: (7) Failed to connect" >&2
  exit 7
fi
if [[ " $* " == *" -4 "* ]]; then
  echo "203.0.113.10"
else
  echo "2001:db8::10"
fi
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

# The VPC load balancers in the account: the ALB of the gateway (resource
# group $1) and a decoy with another hostname
write_lbs() {
  jq -cn --arg host "${LB_HOSTNAME}" --arg group "$1" '[
    {id: "r010-lb-decoy", name: "kube-other-def", hostname: "9f8e7d6c-eu-de.lb.appdomain.cloud",
     resource_group: {name: "redhat-sap-edge-roks-ci"}},
    {id: "r010-lb-1", name: "kube-c1-abc", hostname: $host, resource_group: {name: $group}}]' > "${STUB_LBS}"
}

# Listener array of the ALB (one line): accept_proxy_protocol of port 443 ($1)
# and port 15021 ($2)
listeners_json() {
  jq -cn --argjson https "$1" --argjson status "$2" '[
    {id: "l-443", port: 443, protocol: "tcp", accept_proxy_protocol: $https},
    {id: "l-15021", port: 15021, protocol: "tcp", accept_proxy_protocol: $status}]'
}

# Fresh workspace, fake oc and stub state; the defaults describe a gateway
# without the annotation whose pods already run the PROXY protocol filter,
# behind an active ALB that accepts PROXY protocol on every listener
setup() {
  WS=$(tmp_dir)
  printf 'apiVersion: v1\nkind: Config\n' > "${WS}/kubeconfig"
  FAKE_OC_LOG=$(tmp_file)
  FAKE_OC_RULES=$(tmp_file)
  FAKE_OC_STDIN_DIR=$(tmp_dir)
  EXTRA_RULES=$(tmp_file)
  export FAKE_OC_LOG FAKE_OC_RULES FAKE_OC_STDIN_DIR
  : > "${STUB_IC_LOG}"
  rm -f "${STUB_STATE_DIR}"/*
  write_lbs redhat-sap-edge-roks-ci
  echo "active" > "${STUB_LB_STATUSES}"
  listeners_json true true > "${STUB_LISTENERS}"
  export STUB_CURL_FAIL=0

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
  export LB_WAIT_ATTEMPTS=3 LB_WAIT_DELAY=0
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
grep -q "^is load-balancer-listeners r010-lb-1 " "${STUB_IC_LOG}" || { cat "${STUB_IC_LOG}"; fail "the ALB check must also run when the annotation was already set"; }
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

# Test case: lb_active
# Login with region and group, ALB found by hostname, decoy untouched
echo ""
echo "Test: lb_active"
echo "--------------------------------------------"
setup
run
expect_success
grep -qxF "login -r eu-de -g redhat-sap-edge-roks-ci" "${STUB_IC_LOG}" || { cat "${STUB_IC_LOG}"; fail "ibmcloud login not called with region and resource group"; }
grep -qxF "is load-balancers --all-resource-groups --output JSON" "${STUB_IC_LOG}" || { cat "${STUB_IC_LOG}"; fail "load balancers not listed across resource groups"; }
! grep -q "r010-lb-decoy" "${STUB_IC_LOG}" || { cat "${STUB_IC_LOG}"; fail "the decoy load balancer was queried"; }
expect_output "ALB r010-lb-1 (kube-c1-abc): active, accept_proxy_protocol on all 2 listeners"
expect_output "Public egress IP of the pipeline cluster: 203.0.113.10"
echo "✅ PASS: lb_active"

# Test case: lb_pending_then_active
echo ""
echo "Test: lb_pending_then_active"
echo "--------------------------------------------"
setup
printf 'update_pending\nupdate_pending\nactive\n' > "${STUB_LB_STATUSES}"
{ listeners_json false false; listeners_json true true; } > "${STUB_LISTENERS}"
run
expect_success
POLLS=$(grep -c "^is load-balancer r010-lb-1 --output JSON$" "${STUB_IC_LOG}" || true)
[[ "${POLLS}" -ge 3 ]] || { cat "${STUB_IC_LOG}"; fail "expected at least 3 status polls, got ${POLLS}"; }
assert_called "get events -n istio-gateways --field-selector involvedObject.name=istio-ingressgateway"
echo "✅ PASS: lb_pending_then_active"

# Test case: lb_timeout
echo ""
echo "Test: lb_timeout"
echo "--------------------------------------------"
setup
echo "update_pending" > "${STUB_LB_STATUSES}"
export LB_WAIT_ATTEMPTS=2
run
expect_failure
expect_output "update_pending"
expect_output "443=true"
expect_output "Access forbidden"
assert_called "get events -n istio-gateways --field-selector involvedObject.name=istio-ingressgateway"
echo "✅ PASS: lb_timeout"

# Test case: listener_not_accepting
echo ""
echo "Test: listener_not_accepting"
echo "--------------------------------------------"
setup
listeners_json true false > "${STUB_LISTENERS}"
export LB_WAIT_ATTEMPTS=2
run
expect_failure
expect_output "15021=false"
echo "✅ PASS: listener_not_accepting"

# Test case: lb_not_found
echo ""
echo "Test: lb_not_found"
echo "--------------------------------------------"
setup
jq -c 'map(select(.id == "r010-lb-decoy"))' "${STUB_LBS}" > "${STUB_LBS}.new"
mv "${STUB_LBS}.new" "${STUB_LBS}"
run
expect_failure
expect_output "${LB_HOSTNAME}"
echo "✅ PASS: lb_not_found"

# Test case: lb_found_in_other_group
echo ""
echo "Test: lb_found_in_other_group"
echo "--------------------------------------------"
setup
write_lbs Default
run
expect_success
expect_output "ALB r010-lb-1 (kube-c1-abc): active"
echo "✅ PASS: lb_found_in_other_group"

# Test case: egress_lookup_fails
echo ""
echo "Test: egress_lookup_fails"
echo "--------------------------------------------"
setup
export STUB_CURL_FAIL=1
run
expect_success
expect_output "Public egress IP of the pipeline cluster: unknown (lookup failed)"
echo "✅ PASS: egress_lookup_fails"

# Test case: api_key_not_leaked
echo ""
echo "Test: api_key_not_leaked"
echo "--------------------------------------------"
setup
run
expect_success
! grep -qF -- "${FAKE_IBM_KEY}" "${STUB_IC_LOG}" || fail "API key passed as an ibmcloud argument"
! grep -qF -- "${FAKE_IBM_KEY}" "${FAKE_OC_LOG}" || fail "API key passed as an oc argument"
! grep -qF -- "${FAKE_IBM_KEY}" <<< "${TASK_OUT}" || fail "API key printed"
! grep -q -- "--apikey" "${STUB_IC_LOG}" || fail "--apikey used on the ibmcloud command line"
echo "✅ PASS: api_key_not_leaked"

# Test case: pipeline_wiring
# Always runs between the ELM/EIC gate and the ConfigMap; run files list the
# task; the gate tells the user to allowlist the egress IP, not the VPC
echo ""
echo "Test: pipeline_wiring"
echo "--------------------------------------------"
python3 -I - ../../.tekton/pipelines/roks-ossm3-single-eic-validation-pipeline.yaml \
  ../../.tekton-examples/roks-ossm3-single-eic-validation-run.yaml \
  ../../.tekton/roks-ossm3-single-eic-validation-run.yaml <<'PY'
import os
import sys
import yaml


def load(path, kind):
    with open(path, encoding="utf-8") as f:
        return next(d for d in yaml.safe_load_all(f) if d and d.get("kind") == kind)


errors = []
pipeline = load(sys.argv[1], "Pipeline")
tasks = {t["name"]: t for t in pipeline["spec"]["tasks"]}
task = tasks.get("enable-client-ip-preservation")
if task is None:
    errors.append("pipeline task enable-client-ip-preservation missing")
else:
    if task.get("taskRef") != {"name": "roks-enable-client-ip-preservation"}:
        errors.append(f"taskRef: {task.get('taskRef')}")
    if task.get("runAfter") != ["approval-elm-eic-iflow-deployed"]:
        errors.append(f"runAfter: {task.get('runAfter')}")
    if "when" in task:
        errors.append("enable-client-ip-preservation must always run (no when)")
    params = {p["name"]: p["value"] for p in task.get("params", [])}
    expected = {name: f"$(params.{name})" for name in
                ("clusterName", "roksCredentialsSecretName", "ibmcloudRegion", "ibmcloudResourceGroup")}
    if params != expected:
        errors.append(f"params: {params}")
    if task.get("workspaces") != [{"name": "source", "workspace": "source"}]:
        errors.append(f"workspaces: {task.get('workspaces')}")
if tasks["validate-and-create-configmap"].get("runAfter") != ["enable-client-ip-preservation"]:
    errors.append(f"validate-and-create-configmap runAfter: {tasks['validate-and-create-configmap'].get('runAfter')}")
gate = {p["name"]: p["value"] for p in tasks["approval-elm-eic-iflow-deployed"]["params"]}["description"]
if "enable-client-ip-preservation" not in gate:
    errors.append("the ELM/EIC gate must point to enable-client-ip-preservation for the egress IP")
if "172.17.0.0/18" in gate:
    errors.append("the ELM/EIC gate still asks to allowlist the pod network")
if "must allow 172" in gate or "and 10.0.0.0/16 (VPC)" in gate:
    errors.append("the ELM/EIC gate still asks to allowlist the VPC")
if "curl -4" not in gate:
    errors.append("the ELM/EIC gate must say how to find the egress IP before approving (curl -4)")
with open("../../.tekton/README.md", encoding="utf-8") as f:
    readme = f.read()
if "curl -4" not in readme:
    errors.append(".tekton/README.md must say how to find the egress IP before the first run (curl -4)")
with open("../../roks/terraform/README.md", encoding="utf-8") as f:
    tf_readme = f.read()
if "172.17.0.0/18` (pod network) and `10.0.0.0/16` (VPC) to its allowlist" in tf_readme:
    errors.append("roks/terraform/README.md still asks to allowlist the pod network and the VPC")
if "roks-client-ip-preservation" not in tf_readme:
    errors.append("roks/terraform/README.md must point to the client IP preservation section")
jira = {p["name"]: p["value"] for p in tasks["update-jira-ticket"]["params"]}["comment"]
if "Client IP preservation" not in jira:
    errors.append("the Jira comment must report client IP preservation")
task_file = "./.tekton/tasks/roks-enable-client-ip-preservation-task.yaml"
for path in sys.argv[2:]:
    if not os.path.exists(path):
        continue
    run = load(path, "PipelineRun")
    listed = run["metadata"]["annotations"]["pipelinesascode.tekton.dev/task"]
    if task_file not in [t.strip() for t in listed.strip("[]").split(",")]:
        errors.append(f"{path}: {task_file} missing from pipelinesascode.tekton.dev/task")
if errors:
    print("\n".join(errors))
    sys.exit(1)
PY
echo "✅ PASS: pipeline_wiring"

echo ""
echo "============================================"
echo "✅ All roks-enable-client-ip-preservation tests passed"
echo "============================================"
