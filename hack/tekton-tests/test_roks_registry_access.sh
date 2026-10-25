#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=./lib.sh disable=SC1091
source lib.sh

echo "============================================"
echo "Test: roks-registry-access task"
echo "============================================"

TASK=../../.tekton/tasks/roks-registry-access-task.yaml

# Fake credentials (some unused, reserved for potential expansion)
# shellcheck disable=SC2034
FAKE_API_KEY="FAKE-IBM-APIKEY-0123456789abcdef"
FAKE_HMAC_ACCESS="FAKE-HMAC-ACCESS-KEY-0123"
FAKE_HMAC_SECRET="FAKE-HMAC-SECRET-KEY-0123456789abcdef"
FAKE_ICR_API_KEY="FAKE-ICR-APIKEY-0123456789abcdef"
FAKE_REDIS_PASSWORD="FAKE-REDIS-PASSWORD-0123456789"
HUB_KUBECONFIG_B64=$(printf 'apiVersion: v1\nkind: Config\n' | base64 | tr -d '\n')

expect_success() {
  if [[ "${TASK_RC}" -ne 0 ]]; then
    echo "${TASK_OUT}"
    fail "expected exit 0, got ${TASK_RC}"
  fi
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

# Terraform outputs with Redis on (default) or off
write_outputs() {
  local REDIS="$1"
  if [[ "${REDIS}" == "on" ]]; then
    cat > "${STUB_TF_OUTPUTS}" <<EOF
{
  "icr_registry": {"sensitive": false, "type": "string", "value": "de.icr.io"},
  "icr_namespace": {"sensitive": false, "type": "string", "value": "c1"},
  "icr_username": {"sensitive": false, "type": "string", "value": "iamapikey"},
  "icr_api_key": {"sensitive": true, "type": "string", "value": "${FAKE_ICR_API_KEY}"},
  "redis_password": {"sensitive": true, "type": "string", "value": "${FAKE_REDIS_PASSWORD}"}
}
EOF
  else
    cat > "${STUB_TF_OUTPUTS}" <<EOF
{
  "icr_registry": {"sensitive": false, "type": "string", "value": "de.icr.io"},
  "icr_namespace": {"sensitive": false, "type": "string", "value": "c1"},
  "icr_username": {"sensitive": false, "type": "string", "value": "iamapikey"},
  "icr_api_key": {"sensitive": true, "type": "string", "value": "${FAKE_ICR_API_KEY}"},
  "redis_password": {"sensitive": true, "type": "string", "value": null}
}
EOF
  fi
}

setup() {
  STUB_BIN=$(tmp_dir)
  export PATH="${STUB_BIN}:${PATH}"

  STUB_TF_LOG=$(tmp_file)
  STUB_TF_OUTPUTS=$(tmp_file)
  STUB_BUCKET_DIR=$(tmp_dir)
  export STUB_TF_LOG STUB_TF_OUTPUTS STUB_BUCKET_DIR

  # Stub terraform: logs every call; init succeeds; output -raw prints values
  # and, like terraform, fails with an error for a null value
  cat > "${STUB_BIN}/terraform" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${STUB_TF_LOG}"
case "${1:-}" in
  init)
    mkdir -p .terraform
    for ARG in "$@"; do
      case "${ARG}" in
        -backend-config=key=*) printf '%s\n' "${ARG#-backend-config=key=}" > .terraform/stub-key ;;
      esac
    done
    echo "Terraform has been successfully initialized!"
    ;;
  output)
    if [[ "${2:-}" == "-json" ]]; then
      cat "${STUB_TF_OUTPUTS}"
    elif [[ "${2:-}" == "-raw" ]]; then
      KEY="${3:-}"
      if python3 -I -c "import json,sys; o=json.load(sys.stdin); sys.exit(0 if o.get('${KEY}',{}).get('value') is None else 1)" < "${STUB_TF_OUTPUTS}"; then
        printf 'Error: Unsupported value for raw output\n\nThe value for output "%s" is null, so -raw mode cannot print it.\n' "${KEY}" >&2
        exit 1
      fi
      VALUE=$(python3 -I -c "import json,sys; o=json.load(sys.stdin); print(o['${KEY}']['value'])" < "${STUB_TF_OUTPUTS}")
      printf '%s' "${VALUE}"
    else
      echo "unexpected terraform output call: $*" >&2
      exit 1
    fi
    ;;
  version) echo "Terraform v1.13.5" ;;
  *) echo "unexpected terraform call: $*" >&2; exit 1 ;;
esac
EOF
  chmod +x "${STUB_BIN}/terraform"

  write_outputs on

  WS=$(tmp_dir)
  mkdir -p "${WS}/roks/terraform"

  FAKE_OC_LOG=$(tmp_file)
  FAKE_OC_RULES=$(tmp_file)
  FAKE_OC_STDIN_DIR=$(tmp_dir)
  export FAKE_OC_LOG FAKE_OC_RULES FAKE_OC_STDIN_DIR

  # Step env
  export CLUSTER_NAME=c1
  export TERRAFORM_STATE_BUCKET=test-state-bucket
  export TERRAFORM_STATE_ENDPOINT=https://s3.eu-de.cloud-object-storage.appdomain.cloud
  export AWS_ACCESS_KEY_ID="${FAKE_HMAC_ACCESS}"
  export AWS_SECRET_ACCESS_KEY="${FAKE_HMAC_SECRET}"
  export HUB_KUBECONFIG_SECRET=""
  export TF_INIT_RETRY_DELAY=0
}

write_oc_rules() {
  cat > "${FAKE_OC_RULES}" <<EOF
get secret eic-kubeconfig -o jsonpath=*kubeconfig*	0	${HUB_KUBECONFIG_B64}
EOF
}

run_registry_access() {
  write_oc_rules
  TASK_CWD="${WS}" run_task "${TASK}" \
    --param clusterName="${CLUSTER_NAME}" \
    --param terraformStateBucket="${TERRAFORM_STATE_BUCKET}" \
    --param terraformStateEndpoint="${TERRAFORM_STATE_ENDPOINT}" \
    --param terraformStateSecretName=roks-terraform-state \
    --param hubKubeconfigSecretName="${HUB_KUBECONFIG_SECRET}" \
    --workspace-dir source="${WS}" \
    --drop '# Install tools' 'echo "✅ Tools installed"'
}

INIT_PREFIX="init -input=false -no-color -reconfigure"

# Test case: params_and_env
# Only the params the script uses (no region/resource group: the task reads
# the Terraform state, it does not call IBM Cloud).
echo ""
echo "Test: params_and_env"
echo "--------------------------------------------"
python3 -I - "${TASK}" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    task = next(d for d in yaml.safe_load_all(f) if d and d.get("kind") == "Task")

errors = []
params = {p["name"]: p.get("default") for p in task["spec"]["params"]}
expected_defaults = {
    "clusterName": None,
    "terraformStateBucket": None,
    "terraformStateEndpoint": "https://s3.eu-de.cloud-object-storage.appdomain.cloud",
    "terraformStateSecretName": None,
    "hubKubeconfigSecretName": "",
}
if params != expected_defaults:
    errors.append(f"params/defaults differ: {params}")
env = {e["name"] for e in task["spec"]["steps"][0]["env"]}
expected_env = {
    "CLUSTER_NAME", "TERRAFORM_STATE_BUCKET", "TERRAFORM_STATE_ENDPOINT",
    "HUB_KUBECONFIG_SECRET", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY",
}
if env != expected_env:
    errors.append(f"env names differ: {sorted(env)}")
if errors:
    print("\n".join(errors))
    sys.exit(1)
PY
echo "✅ PASS: params_and_env"

# Test case: registry_secret_created
echo ""
echo "Test: registry_secret_created"
echo "--------------------------------------------"
setup
run_registry_access
expect_success

REG_SECRET=$(captured_manifest eic-registry-roks-c1) || { cat "${FAKE_OC_LOG}"; fail "Secret eic-registry-roks-c1 not applied"; }
[[ "$(secret_value "${REG_SECRET}" server)" == "de.icr.io" ]] || fail "server should be de.icr.io"
[[ "$(secret_value "${REG_SECRET}" namespace)" == "c1" ]] || fail "namespace should be the ICR namespace c1"
[[ "$(secret_keys "${REG_SECRET}")" == "namespace password server username" ]] || fail "unexpected registry Secret keys: $(secret_keys "${REG_SECRET}")"
[[ "$(secret_value "${REG_SECRET}" username)" == "iamapikey" ]] || fail "username should be iamapikey"
[[ "$(secret_value "${REG_SECRET}" password)" == "${FAKE_ICR_API_KEY}" ]] || fail "password should be the ICR API key"
grep -q "eic-registry-roks-c1" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "summary does not name the registry Secret"; }
grep -q "de.icr.io" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "summary does not show the registry server"; }
grep -q "iamapikey" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "summary does not show the username"; }

echo "✅ PASS: registry_secret_created"

# Test case: no_api_key_in_output
echo ""
echo "Test: no_api_key_in_output"
echo "--------------------------------------------"
setup
run_registry_access
expect_success

for SECRET in "${FAKE_ICR_API_KEY}" "${FAKE_REDIS_PASSWORD}" "${FAKE_HMAC_ACCESS}" "${FAKE_HMAC_SECRET}"; do
  ! grep -qF -- "${SECRET}" <<< "${TASK_OUT}" || fail "secret '${SECRET}' printed in the task output"
  ! grep -qF -- "${SECRET}" "${FAKE_OC_LOG}" || fail "secret '${SECRET}' passed as an oc argument"
  ! grep -qF -- "${SECRET}" "${STUB_TF_LOG}" || fail "secret '${SECRET}' passed as a terraform argument"
done

echo "✅ PASS: no_api_key_in_output"

# Test case: redis_password_added_with_own_field_manager
echo ""
echo "Test: redis_password_added_with_own_field_manager"
echo "--------------------------------------------"
setup
run_registry_access
expect_success

CREDS_SECRET=$(captured_manifest eic-credentials-roks-c1) || { cat "${FAKE_OC_LOG}"; fail "Secret eic-credentials-roks-c1 not patched"; }
[[ "$(secret_value "${CREDS_SECRET}" redis-password)" == "${FAKE_REDIS_PASSWORD}" ]] || fail "redis-password should be the Redis password"
# Check that it only contains redis-password (not other keys from Task 4)
[[ "$(secret_keys "${CREDS_SECRET}")" == "redis-password" ]] || fail "redis patch should only contain redis-password, got: $(secret_keys "${CREDS_SECRET}")"
# Check field manager is different from Task 4's
if grep -qE "apply -f - --server-side --field-manager=roks-validate-and-get-access" "${FAKE_OC_LOG}"; then
  fail "redis-password must use a different field manager than Task 4 (roks-validate-and-get-access)"
fi
grep -qE "apply -f - --server-side --field-manager=roks-registry-access" "${FAKE_OC_LOG}" || { cat "${FAKE_OC_LOG}"; fail "redis-password not applied with field-manager=roks-registry-access"; }

echo "✅ PASS: redis_password_added_with_own_field_manager"

# Test case: redis_off_no_redis_patch
echo ""
echo "Test: redis_off_no_redis_patch"
echo "--------------------------------------------"
setup
write_outputs off
run_registry_access
expect_success

! captured_manifest eic-credentials-roks-c1 >/dev/null || fail "eic-credentials-roks-c1 should not be patched when Redis is off"
# Registry secret should still be created
captured_manifest eic-registry-roks-c1 >/dev/null || fail "eic-registry-roks-c1 should be created even when Redis is off"
# The expected terraform error for the null redis_password is not logged
! grep -q "Error" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "misleading terraform error logged when Redis is off"; }
grep -q "Redis is not deployed" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "skipped redis-password not reported"; }

echo "✅ PASS: redis_off_no_redis_patch"

# Test case: init_uses_cos_backend
echo ""
echo "Test: init_uses_cos_backend"
echo "--------------------------------------------"
setup
run_registry_access
expect_success

INIT_LINE=$(grep "^init " "${STUB_TF_LOG}" || true)
[[ "$(grep -c "^init " "${STUB_TF_LOG}")" -eq 1 ]] || { cat "${STUB_TF_LOG}"; fail "expected exactly one terraform init"; }
for EXPECTED in \
  "${INIT_PREFIX} " \
  "-backend-config=bucket=test-state-bucket" \
  "-backend-config=key=roks/c1/terraform.tfstate" \
  "-backend-config=region=eu-de" \
  '-backend-config=endpoints={s3="https://s3.eu-de.cloud-object-storage.appdomain.cloud"}' \
  "-backend-config=use_lockfile=true" \
  "-backend-config=use_path_style=true" \
  "-backend-config=skip_credentials_validation=true" \
  "-backend-config=skip_region_validation=true" \
  "-backend-config=skip_requesting_account_id=true" \
  "-backend-config=skip_s3_checksum=true"; do
  grep -qF -- "${EXPECTED}" <<< "${INIT_LINE}" || fail "terraform init args lack '${EXPECTED}': ${INIT_LINE}"
done

echo "✅ PASS: init_uses_cos_backend"

# Test case: secret_on_hub_when_configured
echo ""
echo "Test: secret_on_hub_when_configured"
echo "--------------------------------------------"
setup
export HUB_KUBECONFIG_SECRET=eic-kubeconfig
run_registry_access
expect_success

grep -qE "^get secret eic-kubeconfig -o jsonpath=" "${FAKE_OC_LOG}" || { cat "${FAKE_OC_LOG}"; fail "hub kubeconfig not extracted"; }
grep -qE "^--kubeconfig .*/hub-kubeconfig apply -f - --server-side" "${FAKE_OC_LOG}" || { cat "${FAKE_OC_LOG}"; fail "registry secret not applied to hub"; }
# In-cluster apply should not be called
! grep -qE "^apply -f - --server-side" "${FAKE_OC_LOG}" || fail "registry secret should not be applied in-cluster when hub is configured"

echo "✅ PASS: secret_on_hub_when_configured"

echo ""
echo "============================================"
echo "✅ All roks-registry-access tests passed"
echo "============================================"
