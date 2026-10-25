#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=./lib.sh disable=SC1091
source lib.sh

echo "============================================"
echo "Test: roks-validate-and-get-access and roks-validate-and-create-configmap"
echo "============================================"

ACCESS_TASK=../../.tekton/tasks/roks-validate-and-get-access-task.yaml
CONFIGMAP_TASK=../../.tekton/tasks/roks-validate-and-create-configmap-task.yaml

API_SERVER="https://c100.eu-de.containers.cloud.ibm.com:31000"
SUBDOMAIN="c1-abc-0000.eu-de.containers.appdomain.cloud"
LB_HOSTNAME="0a1b2c3d-eu-de.lb.appdomain.cloud"
LB_IP="149.81.10.20"
SA_IDENTITY="system:serviceaccount:default:cluster-admin-sa"

# Fake secrets: neither may ever show up in the task output or in oc arguments
FAKE_SA_TOKEN="fake-sa-token-header.fake-sa-token-payload-0123456789.fake-sa-token-signature"
FAKE_ADMIN_KEY="FAKE-ADMIN-CLIENT-KEY-DATA-0123456789"
FAKE_SA_TOKEN_B64=$(printf '%s' "${FAKE_SA_TOKEN}" | base64 | tr -d '\n')
CA_DATA=$(printf '%s' "stub cluster CA" | base64 | tr -d '\n')
PG_CA_PEM=$'-----BEGIN CERTIFICATE-----\nstub postgres CA\n-----END CERTIFICATE-----'
REDIS_CA_PEM=$'-----BEGIN CERTIFICATE-----\nstub redis CA\n-----END CERTIFICATE-----'
PG_CA_B64=$(printf '%s' "${PG_CA_PEM}" | base64 | tr -d '\n')
REDIS_CA_B64=$(printf '%s' "${REDIS_CA_PEM}" | base64 | tr -d '\n')
HUB_KUBECONFIG_B64=$(printf 'apiVersion: v1\nkind: Config\n' | base64 | tr -d '\n')

expect_success() {
  if [[ "${TASK_RC}" -ne 0 ]]; then
    echo "${TASK_OUT}"
    fail "expected exit 0, got ${TASK_RC}"
  fi
}

# Octal permission bits of a file (GNU stat, then BSD stat)
file_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

# Captured manifest (FAKE_OC_STDIN_DIR) of the object with this metadata.name
captured_manifest() {
  local FILE
  for FILE in "${FAKE_OC_STDIN_DIR}"/*.yaml; do
    [[ -f "${FILE}" ]] || continue
    if grep -qE "^  name: $1\$" "${FILE}"; then
      echo "${FILE}"
      return 0
    fi
  done
  return 1
}

# Decoded value of a data key of a captured Secret manifest ("<absent>" if missing)
secret_value() {
  python3 -I - "$1" "$2" <<'PY'
import base64
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    doc = yaml.safe_load(f)
data = doc.get("data") or {}
if sys.argv[2] in data:
    sys.stdout.write(base64.b64decode(data[sys.argv[2]]).decode())
else:
    sys.stdout.write("<absent>")
PY
}

secret_keys() {
  python3 -I - "$1" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    doc = yaml.safe_load(f)
print(" ".join(sorted((doc.get("data") or {}).keys())))
PY
}

# Terraform outputs as roks-deploy writes them (terraform output -json, sensitive removed)
write_outputs() {
  local SERVICES="$1"
  if [[ "${SERVICES}" == "on" ]]; then
    cat > "${WS}/roks-terraform-outputs.json" <<EOF
{
  "cluster_id": {"sensitive": false, "type": "string", "value": "stub-cluster-id"},
  "cluster_name": {"sensitive": false, "type": "string", "value": "c1"},
  "ingress_hostname": {"sensitive": false, "type": "string", "value": "${SUBDOMAIN}"},
  "vpc_id": {"sensitive": false, "type": "string", "value": "r010-stub-vpc"},
  "icr_registry": {"sensitive": false, "type": "string", "value": "de.icr.io"},
  "icr_namespace": {"sensitive": false, "type": "string", "value": "c1"},
  "icr_username": {"sensitive": false, "type": "string", "value": "iamapikey"},
  "postgres_host": {"sensitive": false, "type": "string", "value": "pg.stub.databases.appdomain.cloud"},
  "postgres_port": {"sensitive": false, "type": "number", "value": 31234},
  "postgres_database": {"sensitive": false, "type": "string", "value": "ibmclouddb"},
  "postgres_admin_username": {"sensitive": false, "type": "string", "value": "admin"},
  "postgres_ca_certificate_base64": {"sensitive": false, "type": "string", "value": "${PG_CA_B64}"},
  "redis_host": {"sensitive": false, "type": "string", "value": "redis.stub.databases.appdomain.cloud"},
  "redis_port": {"sensitive": false, "type": "number", "value": 31235},
  "redis_username": {"sensitive": false, "type": "string", "value": "admin"},
  "redis_ca_certificate_base64": {"sensitive": false, "type": "string", "value": "${REDIS_CA_B64}"}
}
EOF
  else
    cat > "${WS}/roks-terraform-outputs.json" <<EOF
{
  "cluster_id": {"sensitive": false, "type": "string", "value": "stub-cluster-id"},
  "cluster_name": {"sensitive": false, "type": "string", "value": "c1"},
  "ingress_hostname": {"sensitive": false, "type": "string", "value": "${SUBDOMAIN}"},
  "postgres_host": {"sensitive": false, "type": "string", "value": null},
  "postgres_port": {"sensitive": false, "type": "string", "value": null},
  "postgres_database": {"sensitive": false, "type": "string", "value": null},
  "postgres_admin_username": {"sensitive": false, "type": "string", "value": null},
  "postgres_ca_certificate_base64": {"sensitive": false, "type": "string", "value": null},
  "redis_host": {"sensitive": false, "type": "string", "value": null},
  "redis_port": {"sensitive": false, "type": "string", "value": null},
  "redis_username": {"sensitive": false, "type": "string", "value": null},
  "redis_ca_certificate_base64": {"sensitive": false, "type": "string", "value": null}
}
EOF
  fi
}

# Fresh workspace (admin kubeconfig + outputs from roks-deploy) and fake oc
# for the access task. Rules are matched in order; the caller may prepend.
setup_access() {
  WS=$(tmp_dir)
  (
    umask 077
    cat > "${WS}/kubeconfig" <<EOF
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: ${CA_DATA}
    server: ${API_SERVER}
  name: stub
contexts:
- context:
    cluster: stub
    user: admin
  name: stub
current-context: stub
kind: Config
users:
- name: admin
  user:
    client-certificate-data: stub-cert-data
    client-key-data: ${FAKE_ADMIN_KEY}
EOF
  )
  write_outputs on

  FAKE_OC_LOG=$(tmp_file)
  FAKE_OC_RULES=$(tmp_file)
  FAKE_OC_STDIN_DIR=$(tmp_dir)
  EXTRA_RULES=$(tmp_file)
  export FAKE_OC_LOG FAKE_OC_RULES FAKE_OC_STDIN_DIR

  export CLUSTER_NAME=c1
  export HUB_KUBECONFIG_SECRET=""
  export ACCESS_RETRY_DELAY=0 TOKEN_WAIT_DELAY=0 VERIFY_RETRY_DELAY=0
}

write_access_rules() {
  {
    cat "${EXTRA_RULES}"
    printf '%s\t%s\t%s\n' \
      'get secret eic-kubeconfig -o jsonpath=*kubeconfig*' 0 "${HUB_KUBECONFIG_B64}" \
      '--kubeconfig */admin-kubeconfig whoami' 0 'IAM#admin@example.com' \
      '--kubeconfig */admin-kubeconfig auth can-i * * --all-namespaces' 0 'yes' \
      '--kubeconfig */admin-kubeconfig config view --minify --raw -o jsonpath=*.server*' 0 "${API_SERVER}" \
      '--kubeconfig */admin-kubeconfig config view --minify --raw -o jsonpath=*certificate-authority-data*' 0 "${CA_DATA}" \
      '--kubeconfig */admin-kubeconfig config view --minify --raw -o jsonpath=*insecure-skip-tls-verify*' 0 '' \
      '--kubeconfig */admin-kubeconfig -n default get sa cluster-admin-sa' 1 'Error from server (NotFound)' \
      '--kubeconfig */admin-kubeconfig -n default get secret cluster-admin-sa-token -o jsonpath=*' 0 "${FAKE_SA_TOKEN_B64}" \
      '--kubeconfig */token-kubeconfig whoami' 0 "${SA_IDENTITY}" \
      '--kubeconfig */token-kubeconfig auth can-i * * --all-namespaces' 0 'yes'
  } > "${FAKE_OC_RULES}"
}

run_access() {
  write_access_rules
  TASK_CWD="${WS}" run_task "${ACCESS_TASK}" \
    --param clusterName="${CLUSTER_NAME}" \
    --param hubKubeconfigSecretName="${HUB_KUBECONFIG_SECRET}" \
    --workspace-dir source="${WS}" \
    --drop '# Install tools' 'echo "✅ Tools installed"'
}

# Test case: env_wiring
# The scripts read params from the step env; check params, env, results and
# workspaces (the harness extracts only the script).
echo ""
echo "Test: env_wiring"
echo "--------------------------------------------"
python3 -I - "${ACCESS_TASK}" "${CONFIGMAP_TASK}" <<'PY'
import sys
import yaml


def load(path):
    with open(path, encoding="utf-8") as f:
        return next(d for d in yaml.safe_load_all(f) if d and d.get("kind") == "Task")


errors = []
cases = [
    (sys.argv[1], "roks-validate-and-get-access",
     {"clusterName": None, "hubKubeconfigSecretName": ""},
     {"CLUSTER_NAME": "$(params.clusterName)", "HUB_KUBECONFIG_SECRET": "$(params.hubKubeconfigSecretName)"},
     []),
    (sys.argv[2], "roks-validate-and-create-configmap",
     {"clusterName": None},
     {"CLUSTER_NAME": "$(params.clusterName)"},
     ["cluster-summary"]),
]
for path, name, defaults, env_values, results in cases:
    task = load(path)
    if task["metadata"]["name"] != name:
        errors.append(f"{path}: name should be {name}")
    params = {p["name"]: p.get("default") for p in task["spec"]["params"]}
    if params != defaults:
        errors.append(f"{name}: params/defaults differ: {params}")
    if [w["name"] for w in task["spec"]["workspaces"]] != ["source"]:
        errors.append(f"{name}: expected exactly the workspace 'source'")
    if [r["name"] for r in task["spec"].get("results", [])] != results:
        errors.append(f"{name}: results should be {results}")
    steps = task["spec"]["steps"]
    if len(steps) != 1:
        errors.append(f"{name}: expected one step")
    step = steps[0]
    env = {e["name"]: e for e in step.get("env", [])}
    for key, value in env_values.items():
        if env.get(key, {}).get("value") != value:
            errors.append(f"{name}: env {key} should be {value}, got {env.get(key)}")
    if any("valueFrom" in e for e in env.values()):
        errors.append(f"{name}: no Secret should be read into the env")
    if step.get("workingDir") != "$(workspaces.source.path)":
        errors.append(f"{name}: workingDir must be the source workspace")
    if "set -x" in step["script"]:
        errors.append(f"{name}: script must not use set -x")
if errors:
    print("\n".join(errors))
    sys.exit(1)
PY
echo "✅ PASS: env_wiring"

# Test case: access_writes_token_kubeconfig
echo ""
echo "Test: access_writes_token_kubeconfig"
echo "--------------------------------------------"
setup_access
run_access
expect_success

# Admin access verified with a copy of the workspace (admin) kubeconfig
assert_called "^--kubeconfig .*/admin-kubeconfig whoami$"
assert_called "^--kubeconfig .*/admin-kubeconfig auth can-i \* \* --all-namespaces$"
# ServiceAccount with cluster-admin and a long-lived token Secret
assert_called "^--kubeconfig .*/admin-kubeconfig -n default create sa cluster-admin-sa$"
assert_called "^--kubeconfig .*/admin-kubeconfig adm policy add-cluster-role-to-user cluster-admin -z cluster-admin-sa -n default$"
TOKEN_SECRET=$(captured_manifest cluster-admin-sa-token) || { cat "${FAKE_OC_LOG}"; fail "token Secret cluster-admin-sa-token not applied"; }
assert_file_contains "${TOKEN_SECRET}" "^type: kubernetes.io/service-account-token$"
assert_file_contains "${TOKEN_SECRET}" "kubernetes.io/service-account.name: cluster-admin-sa$"
assert_called "^--kubeconfig .*/admin-kubeconfig -n default apply -f -$"

# Workspace kubeconfig is now the token kubeconfig, verified before it was written
KC="${WS}/kubeconfig"
assert_file_contains "${KC}" "token: \"?${FAKE_SA_TOKEN}\"?$"
assert_file_contains "${KC}" "server: \"?${API_SERVER}\"?$"
assert_file_contains "${KC}" "certificate-authority-data: \"?${CA_DATA}\"?$"
! grep -q "${FAKE_ADMIN_KEY}" "${KC}" || fail "workspace kubeconfig still contains the admin client key"
! grep -q "insecure-skip-tls-verify" "${KC}" || fail "token kubeconfig skips TLS verification although the admin kubeconfig has a CA"
[[ "$(file_mode "${KC}")" == "600" ]] || fail "workspace kubeconfig mode is $(file_mode "${KC}"), expected 600"
assert_called "^--kubeconfig .*/token-kubeconfig whoami$"
assert_called "^--kubeconfig .*/token-kubeconfig auth can-i \* \* --all-namespaces$"

# Credentials Secret on the pipeline cluster (in-cluster config, no --kubeconfig),
# server-side apply so that a later task can add keys with its own field manager
CREDS=$(captured_manifest eic-credentials-roks-c1) || { cat "${FAKE_OC_LOG}"; fail "Secret eic-credentials-roks-c1 not applied"; }
assert_file_contains "${CREDS}" "^kind: Secret$"
assert_called "^apply -f - --server-side --field-manager=roks-validate-and-get-access --force-conflicts$"
assert_not_called "^(--kubeconfig [^ ]+ )?(-n [^ ]+ )?(delete|create) secret eic-credentials-roks-c1"
[[ "$(secret_value "${CREDS}" kubeconfig)" == "$(cat "${KC}")" ]] || fail "Secret key kubeconfig is not the token kubeconfig"
grep -q "eic-credentials-roks-c1" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "summary does not name the credentials Secret"; }
grep -qF "${SA_IDENTITY}" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "summary does not show the ServiceAccount identity"; }

echo "✅ PASS: access_writes_token_kubeconfig"

# Test case: access_secret_service_data
# Postgres/Redis connection data (no passwords) when present in the outputs file
echo ""
echo "Test: access_secret_service_data"
echo "--------------------------------------------"
setup_access
run_access
expect_success
CREDS=$(captured_manifest eic-credentials-roks-c1) || fail "Secret eic-credentials-roks-c1 not applied"
for PAIR in \
  "postgres-host=pg.stub.databases.appdomain.cloud" \
  "postgres-port=31234" \
  "postgres-database=ibmclouddb" \
  "postgres-username=admin" \
  "redis-host=redis.stub.databases.appdomain.cloud" \
  "redis-port=31235" \
  "redis-username=admin" \
  "cluster-name=c1" \
  "api-url=${API_SERVER}"; do
  KEY="${PAIR%%=*}"
  VALUE="${PAIR#*=}"
  [[ "$(secret_value "${CREDS}" "${KEY}")" == "${VALUE}" ]] || fail "Secret key ${KEY} should be '${VALUE}', got '$(secret_value "${CREDS}" "${KEY}")'"
done
[[ "$(secret_value "${CREDS}" postgres-ca.crt)" == "${PG_CA_PEM}" ]] || fail "postgres-ca.crt is not the decoded PEM"
[[ "$(secret_value "${CREDS}" redis-ca.crt)" == "${REDIS_CA_PEM}" ]] || fail "redis-ca.crt is not the decoded PEM"
! grep -qiE "password" <<< "$(secret_keys "${CREDS}")" || fail "no password key expected from this task: $(secret_keys "${CREDS}")"

# Services off (null outputs) → only the cluster keys
setup_access
write_outputs off
run_access
expect_success
CREDS=$(captured_manifest eic-credentials-roks-c1) || fail "Secret eic-credentials-roks-c1 not applied"
[[ "$(secret_keys "${CREDS}")" == "api-url cluster-id cluster-name kubeconfig" ]] || fail "unexpected keys without services: $(secret_keys "${CREDS}")"

echo "✅ PASS: access_secret_service_data"

# Test case: access_secret_on_hub
# With hubKubeconfigSecretName the Secret goes to that cluster (like ROSA)
echo ""
echo "Test: access_secret_on_hub"
echo "--------------------------------------------"
setup_access
export HUB_KUBECONFIG_SECRET=eic-kubeconfig
run_access
expect_success
assert_called "^get secret eic-kubeconfig -o jsonpath=\{\.data\.kubeconfig\}$"
assert_called "^--kubeconfig .*/hub-kubeconfig apply -f - --server-side --field-manager=roks-validate-and-get-access --force-conflicts$"
assert_not_called "^apply -f - --server-side"
echo "✅ PASS: access_secret_on_hub"

# Test case: access_no_token_in_output
echo ""
echo "Test: access_no_token_in_output"
echo "--------------------------------------------"
setup_access
run_access
expect_success
for SECRET in "${FAKE_SA_TOKEN}" "${FAKE_SA_TOKEN_B64}" "${FAKE_ADMIN_KEY}" "fake-sa-token-payload"; do
  ! grep -qF -- "${SECRET}" <<< "${TASK_OUT}" || fail "secret '${SECRET}' printed in the task output"
  ! grep -qF -- "${SECRET}" "${FAKE_OC_LOG}" || fail "secret '${SECRET}' passed as an oc argument"
done
echo "✅ PASS: access_no_token_in_output"

# Test case: access_keeps_admin_kubeconfig_when_token_fails
# The token kubeconfig is verified before it replaces the workspace kubeconfig
echo ""
echo "Test: access_keeps_admin_kubeconfig_when_token_fails"
echo "--------------------------------------------"
setup_access
printf '%s\t%s\t%s\n' '--kubeconfig */token-kubeconfig whoami' 1 'error: You must be logged in to the server (Unauthorized)' > "${EXTRA_RULES}"
run_access
[[ "${TASK_RC}" -ne 0 ]] || { echo "${TASK_OUT}"; fail "unusable token kubeconfig accepted"; }
assert_file_contains "${WS}/kubeconfig" "client-key-data: ${FAKE_ADMIN_KEY}"
! captured_manifest eic-credentials-roks-c1 >/dev/null || fail "credentials Secret stored although the token kubeconfig does not work"
echo "✅ PASS: access_keeps_admin_kubeconfig_when_token_fails"

# Test case: access_fails_without_admin_access
echo ""
echo "Test: access_fails_without_admin_access"
echo "--------------------------------------------"
setup_access
rm -f "${WS}/kubeconfig"
run_access
[[ "${TASK_RC}" -ne 0 ]] || { echo "${TASK_OUT}"; fail "missing workspace kubeconfig accepted"; }
grep -q "roks-deploy" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "error does not point to roks-deploy"; }
assert_not_called "create sa"

setup_access
printf '%s\t%s\t%s\n' '--kubeconfig */admin-kubeconfig auth can-i * * --all-namespaces' 0 'no' > "${EXTRA_RULES}"
run_access
[[ "${TASK_RC}" -ne 0 ]] || { echo "${TASK_OUT}"; fail "kubeconfig without cluster-admin accepted"; }
assert_not_called "create sa"
echo "✅ PASS: access_fails_without_admin_access"

# ---------------------------------------------------------------------------
# roks-validate-and-create-configmap
# ---------------------------------------------------------------------------

# Workspace with the token kubeconfig and the outputs; $1 = istio-ingressgateway
# Services as JSON items (svc --all-namespaces -o json)
setup_configmap() {
  WS=$(tmp_dir)
  printf 'apiVersion: v1\nkind: Config\n' > "${WS}/kubeconfig"
  write_outputs on
  RESULTS_DIR=$(tmp_dir)
  FAKE_OC_LOG=$(tmp_file)
  FAKE_OC_RULES=$(tmp_file)
  FAKE_OC_STDIN_DIR=$(tmp_dir)
  export FAKE_OC_LOG FAKE_OC_RULES FAKE_OC_STDIN_DIR
  printf '%s\t%s\t%s\n' \
    '--kubeconfig */kubeconfig get svc --all-namespaces -o json' 0 "{\"items\":[$1]}" \
    > "${FAKE_OC_RULES}"
  export CLUSTER_NAME=c1
  export LB_WAIT_ATTEMPTS=2 LB_WAIT_DELAY=0
}

run_configmap() {
  TASK_CWD="${WS}" run_task "${CONFIGMAP_TASK}" \
    --param clusterName="${CLUSTER_NAME}" \
    --workspace-dir source="${WS}" \
    --results-dir "${RESULTS_DIR}" \
    --drop '# Install tools' 'echo "✅ Tools installed"'
}

svc_item() {
  printf '{"metadata":{"name":"%s","namespace":"%s"},"status":{"loadBalancer":%s}}' "$1" "$2" "$3"
}

# Test case: configmap_uses_lb_hostname
echo ""
echo "Test: configmap_uses_lb_hostname"
echo "--------------------------------------------"
LB_STATUS="{\"ingress\":[{\"hostname\":\"${LB_HOSTNAME}\"}]}"
setup_configmap "$(svc_item istio-ingressgateway istio-system "${LB_STATUS}")"
run_configmap
expect_success
assert_called "^create configmap cluster-info-roks-c1 --from-literal=host=eic\.${SUBDOMAIN} --from-literal=ingressIP=${LB_HOSTNAME}$"
assert_called "^delete configmap cluster-info-roks-c1 --ignore-not-found=true$"
# Read from the ROKS cluster through the workspace (token) kubeconfig
assert_called "^--kubeconfig ${WS}/kubeconfig get svc --all-namespaces -o json$"
SUMMARY=$(cat "${RESULTS_DIR}/cluster-summary")
grep -qF "${LB_HOSTNAME}" <<< "${SUMMARY}" || fail "cluster-summary lacks the ingress address: ${SUMMARY}"
grep -qF "eic.${SUBDOMAIN}" <<< "${SUMMARY}" || fail "cluster-summary lacks the EIC host: ${SUMMARY}"
echo "✅ PASS: configmap_uses_lb_hostname"

# Test case: configmap_prefers_lb_ip
echo ""
echo "Test: configmap_prefers_lb_ip"
echo "--------------------------------------------"
# (JSON built in a variable: bash 3.2 brace-expands {a,b} in nested "$(... "...")")
LB_STATUS="{\"ingress\":[{\"ip\":\"${LB_IP}\",\"hostname\":\"${LB_HOSTNAME}\"}]}"
setup_configmap "$(svc_item istio-ingressgateway istio-gateways "${LB_STATUS}")"
run_configmap
expect_success
assert_called "^create configmap cluster-info-roks-c1 --from-literal=host=eic\.${SUBDOMAIN} --from-literal=ingressIP=${LB_IP}$"
echo "✅ PASS: configmap_prefers_lb_ip"

# Test case: configmap_namespace_order
# Search order as in ROSA's task: istio-system, istio-gateways, then any namespace
echo ""
echo "Test: configmap_namespace_order"
echo "--------------------------------------------"
ITEMS=$(svc_item istio-ingressgateway eic-gateways '{"ingress":[{"ip":"10.9.9.9"}]}')
ITEMS="${ITEMS},$(svc_item istio-ingressgateway istio-system '{}')"
ITEMS="${ITEMS},$(svc_item other-gateway istio-system '{"ingress":[{"ip":"10.8.8.8"}]}')"
LB_STATUS="{\"ingress\":[{\"hostname\":\"${LB_HOSTNAME}\"}]}"
ITEMS="${ITEMS},$(svc_item istio-ingressgateway istio-gateways "${LB_STATUS}")"
setup_configmap "${ITEMS}"
run_configmap
expect_success
assert_called " --from-literal=ingressIP=${LB_HOSTNAME}$"
echo "✅ PASS: configmap_namespace_order"

# Test case: configmap_fails_without_lb_address
# No placeholder address (ROSA writes 127.0.0.1): fail with diagnostics instead
echo ""
echo "Test: configmap_fails_without_lb_address"
echo "--------------------------------------------"
setup_configmap "$(svc_item istio-ingressgateway istio-system '{}')"
run_configmap
[[ "${TASK_RC}" -ne 0 ]] || { echo "${TASK_OUT}"; fail "ConfigMap task succeeded without a LoadBalancer address"; }
assert_not_called "create configmap"
[[ "$(grep -c "get svc --all-namespaces -o json" "${FAKE_OC_LOG}")" -eq 2 ]] || { cat "${FAKE_OC_LOG}"; fail "expected LB_WAIT_ATTEMPTS=2 lookups"; }
grep -q "istio-ingressgateway" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "error does not name istio-ingressgateway"; }
echo "✅ PASS: configmap_fails_without_lb_address"

echo ""
echo "============================================"
echo "✅ All roks access/ConfigMap tests passed"
echo "============================================"
