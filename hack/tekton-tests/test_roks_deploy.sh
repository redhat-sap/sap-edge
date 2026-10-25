#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=./lib.sh disable=SC1091
source lib.sh

echo "============================================"
echo "Test: roks-deploy task"
echo "============================================"

TASK=../../.tekton/tasks/roks-deploy-task.yaml

# Fake credentials: none of them may ever show up in the task output or in
# roks-terraform-outputs.json.
FAKE_API_KEY="FAKE-IBM-APIKEY-0123456789abcdef"
FAKE_HMAC_ACCESS="FAKE-HMAC-ACCESS-KEY-0123"
FAKE_HMAC_SECRET="FAKE-HMAC-SECRET-KEY-0123456789abcdef"
FAKE_PG_PASSWORD="FakePostgresPassword123"
FAKE_REDIS_PASSWORD="FAKE-REDIS-PASSWORD-0123456789"
FAKE_ICR_API_KEY="FAKE-ICR-APIKEY-0123456789abcdef"
FAKE_JWT_SIGNATURE="FAKE-JWT-SIGNATURE-0123456789"

# base64url without padding, as in a JWT
b64url() {
  printf '%s' "$1" | base64 | tr -d '\n=' | tr '/+' '_-'
}

# IAM token of the logged-in identity (a service ID)
LOGIN_IAM_ID="iam-ServiceId-1111-pipeline"
STUB_LOGIN_IAM_ID="${LOGIN_IAM_ID}"
export STUB_LOGIN_IAM_ID
STUB_IAM_TOKEN="$(b64url '{"alg":"RS256"}').$(b64url "{\"iam_id\":\"${LOGIN_IAM_ID}\",\"sub\":\"ServiceId-1111-pipeline\",\"account\":{\"bss\":\"acct\"}}").${FAKE_JWT_SIGNATURE}"
export STUB_IAM_TOKEN

STUB_BIN=$(tmp_dir)
export PATH="${STUB_BIN}:${PATH}"

# Stub terraform: logs every call; init remembers the state key; apply fails
# like the IBM provider when the kubeconfig directory is missing, "creates"
# the state object in the fake bucket only when it does not exist yet, and
# downloads a fake admin kubeconfig; output -json prints canned outputs
# including sensitive ones.
cat > "${STUB_BIN}/terraform" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${STUB_TF_LOG}"
case "${1:-}" in
  init)
    if [[ -s "${STUB_TF_INIT_FAILURES}" ]]; then
      sed -i.bak '1d' "${STUB_TF_INIT_FAILURES}"
      echo "Error: Failed to query available provider packages" >&2
      exit 1
    fi
    mkdir -p .terraform
    for ARG in "$@"; do
      case "${ARG}" in
        -backend-config=key=*) printf '%s\n' "${ARG#-backend-config=key=}" > .terraform/stub-key ;;
      esac
    done
    echo "Terraform has been successfully initialized!"
    ;;
  apply)
    if [[ "${STUB_TF_LOCKED:-false}" == "true" ]]; then
      cat <<'LOCK' >&2
Acquiring state lock. This may take a few moments...

Error: Error acquiring the state lock

Error message: operation error S3: PutObject, https response error
StatusCode: 412, RequestID: 0000-request-id, HostID: , api error
PreconditionFailed: At least one of the pre-conditions you specified did not hold
Lock Info:
  ID:        6f0f3c1e-1a2b-4c3d-9e8f-0123456789ab
  Path:      test-state-bucket/roks/redhat-roks-eic-pr7/terraform.tfstate
  Operation: OperationTypeApply
  Who:       root@roks-deploy-pod
  Version:   1.13.5
  Created:   2026-10-25 10:00:00.000000000 +0000 UTC
  Info:

Terraform acquires a state lock to protect the state from being written
by multiple users at the same time. Please resolve the issue above and try
again. For most commands, you can disable locking with the "-lock=false"
flag, but this is not recommended.
LOCK
      exit 1
    fi
    KEY=$(cat .terraform/stub-key)
    KUBE_DIR=$(sed -n 's/^kubeconfig_dir *= *"\(.*\)"$/\1/p' terraform.tfvars)
    if [[ -z "${KUBE_DIR}" || ! -d "${KUBE_DIR}" ]]; then
      echo "Error: config_dir '${KUBE_DIR}' does not exist" >&2
      exit 1
    fi
    STATE="${STUB_BUCKET_DIR}/${KEY}"
    if [[ -f "${STATE}" ]]; then
      echo "No changes. Your infrastructure matches the configuration."
    else
      mkdir -p "$(dirname "${STATE}")"
      echo "state" > "${STATE}"
      echo "create ${KEY}" >> "${STUB_TF_CREATES}"
      echo "Apply complete! Resources: 31 added, 0 changed, 0 destroyed."
    fi
    mkdir -p "${KUBE_DIR}/stub-kube"
    echo "client-certificate: admin.pem" > "${KUBE_DIR}/stub-kube/config.yml"
    ;;
  output)
    [[ "${2:-}" == "-json" ]] || { echo "unexpected terraform output call: $*" >&2; exit 1; }
    cat "${STUB_TF_OUTPUTS}"
    ;;
  version) echo "Terraform v1.13.5" ;;
  *) echo "unexpected terraform call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "${STUB_BIN}/terraform"

# Stub ibmcloud: logs every call; serves the IAM token, the current target
# and the API key owner (info fails when STUB_KEY_INFO_FAILS=true); reset makes
# the logged-in identity the owner unless STUB_RESET_FIXES_OWNER=false.
cat > "${STUB_BIN}/ibmcloud" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${STUB_IC_LOG}"
case "$*" in
  "config --check-version=false") ;;
  "login --apikey "*) printf 'API endpoint: https://cloud.ibm.com\nAuthenticating...\nOK\n' ;;
  "target -r "*) echo "Targeted: $*" ;;
  "target --output json") cat "${STUB_TARGET_JSON}" ;;
  "iam oauth-tokens --output json") printf '{"iam_token":"Bearer %s","uaa_token":""}\n' "${STUB_IAM_TOKEN}" ;;
  "ks api-key info --cluster "*)
    if [[ "${STUB_KEY_INFO_FAILS}" == "true" ]]; then
      echo "FAILED: the API key owner could not be retrieved" >&2
      exit 1
    fi
    cat "${STUB_KEY_OWNER}"
    ;;
  "ks api-key reset --region "*)
    if [[ "${STUB_RESET_FIXES_OWNER}" == "true" ]]; then
      printf '{"ID":"%s","Name":"pipeline","Email":""}\n' "${STUB_LOGIN_IAM_ID}" > "${STUB_KEY_OWNER}"
    fi
    echo "OK"
    ;;
  *) echo "unexpected ibmcloud call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "${STUB_BIN}/ibmcloud"

STUB_TF_OUTPUTS=$(tmp_file)
cat > "${STUB_TF_OUTPUTS}" <<EOF
{
  "admin_kubeconfig_path": {"sensitive": false, "type": "string", "value": "./.kube/stub-kube/config.yml"},
  "cluster_id": {"sensitive": false, "type": "string", "value": "stub-cluster-id"},
  "cluster_name": {"sensitive": false, "type": "string", "value": "redhat-roks-eic-pr7"},
  "ingress_hostname": {"sensitive": false, "type": "string", "value": "redhat-roks-eic-pr7-abc-0000.eu-de.containers.appdomain.cloud"},
  "resource_group_id": {"sensitive": false, "type": "string", "value": "a80f479864f944c1b3d9a62e98e70a62"},
  "vpc_id": {"sensitive": false, "type": "string", "value": "r010-stub-vpc"},
  "icr_registry": {"sensitive": false, "type": "string", "value": "de.icr.io"},
  "icr_namespace": {"sensitive": false, "type": "string", "value": "redhat-roks-eic-pr7"},
  "icr_username": {"sensitive": false, "type": "string", "value": "iamapikey"},
  "icr_api_key": {"sensitive": true, "type": "string", "value": "${FAKE_ICR_API_KEY}"},
  "postgres_host": {"sensitive": false, "type": "string", "value": "pg.stub.databases.appdomain.cloud"},
  "postgres_port": {"sensitive": false, "type": "number", "value": 31234},
  "postgres_database": {"sensitive": false, "type": "string", "value": "ibmclouddb"},
  "postgres_admin_username": {"sensitive": false, "type": "string", "value": "admin"},
  "redis_host": {"sensitive": false, "type": "string", "value": "redis.stub.databases.appdomain.cloud"},
  "redis_port": {"sensitive": false, "type": "number", "value": 31235},
  "redis_username": {"sensitive": false, "type": "string", "value": "admin"},
  "redis_password": {"sensitive": true, "type": "string", "value": "${FAKE_REDIS_PASSWORD}"}
}
EOF
export STUB_TF_OUTPUTS

FLAT_KUBECONFIG='apiVersion: v1\nclusters:\n- cluster:\n    certificate-authority-data: stub-ca-data\n    server: https://c100.eu-de.containers.cloud.ibm.com:31000\n  name: stub\nusers:\n- name: admin\n  user:\n    client-certificate-data: stub-cert-data\n    client-key-data: stub-key-data'

# What `ibmcloud target --output json` reports as the targeted resource group
target_group() {
  printf '{"api_endpoint":"https://cloud.ibm.com","region":{"name":"eu-de"},"resource_group":{"guid":"rg-guid","name":"%s"}}\n' "$1" > "${STUB_TARGET_JSON}"
}

# Line number of the first ibmcloud call matching an ERE (0 if none)
ic_line() {
  local N
  N=$(grep -nE "$1" "${STUB_IC_LOG}" | head -1 | cut -d: -f1)
  echo "${N:-0}"
}

FOREIGN_OWNER='{"id":"IBMid-0000USER","name":"Some User","email":"some.user@example.com"}'

# Fresh stubs, fake bucket and workspace (a fresh git-clone with
# roks/terraform but without the .kube directory), default params/secrets.
# Pass "keep-bucket" to keep the fake state bucket of the previous run.
setup() {
  STUB_TF_LOG=$(tmp_file)
  STUB_IC_LOG=$(tmp_file)
  STUB_TF_CREATES=$(tmp_file)
  STUB_TF_INIT_FAILURES=$(tmp_file)
  STUB_KEY_OWNER=$(tmp_file)
  if [[ "${1:-}" != "keep-bucket" ]]; then
    STUB_BUCKET_DIR=$(tmp_dir)
  fi
  STUB_TF_LOCKED=false
  STUB_KEY_INFO_FAILS=false
  STUB_RESET_FIXES_OWNER=true
  STUB_TARGET_JSON=$(tmp_file)
  export STUB_TF_LOG STUB_IC_LOG STUB_TF_CREATES STUB_TF_INIT_FAILURES STUB_KEY_OWNER STUB_BUCKET_DIR STUB_TF_LOCKED
  export STUB_KEY_INFO_FAILS STUB_RESET_FIXES_OWNER STUB_TARGET_JSON
  printf '{"ID":"%s","Name":"redhat-sap-edge-roks-ci","Email":""}\n' "${LOGIN_IAM_ID}" > "${STUB_KEY_OWNER}"
  target_group redhat-sap-edge-roks-ci

  WS=$(tmp_dir)
  mkdir -p "${WS}/roks/terraform"

  FAKE_OC_LOG=$(tmp_file)
  FAKE_OC_RULES=$(tmp_file)
  printf 'config view --flatten --raw --kubeconfig *\t0\t%s\n' "${FLAT_KUBECONFIG}" > "${FAKE_OC_RULES}"
  printf 'config view --kubeconfig * -o jsonpath=*\t0\thttps://c100.eu-de.containers.cloud.ibm.com:31000\n' >> "${FAKE_OC_RULES}"
  export FAKE_OC_LOG FAKE_OC_RULES

  # Step env (params and Secrets, see the task's env list)
  export CLUSTER_NAME=redhat-roks-eic-pr7
  export PR_NUMBER=7
  export IBMCLOUD_REGION=eu-de
  export IBMCLOUD_RESOURCE_GROUP=redhat-sap-edge-roks-ci
  export OPENSHIFT_VERSION=4.21_openshift
  export WORKER_FLAVOR=bx2.16x64
  export WORKERS_PER_ZONE=1
  export TERRAFORM_STATE_BUCKET=test-state-bucket
  export TERRAFORM_STATE_ENDPOINT=https://s3.eu-de.cloud-object-storage.appdomain.cloud
  export DEPLOY_POSTGRES=true
  export DEPLOY_REDIS=true
  export POSTGRES_ADMIN_PASSWORD_SECRET_NAME=roks-postgres-admin-password
  export IBMCLOUD_API_KEY="${FAKE_API_KEY}"
  export AWS_ACCESS_KEY_ID="${FAKE_HMAC_ACCESS}"
  export AWS_SECRET_ACCESS_KEY="${FAKE_HMAC_SECRET}"
  export POSTGRES_ADMIN_PASSWORD="${FAKE_PG_PASSWORD}"
  export TF_INIT_RETRY_DELAY=0
}

run_deploy() {
  TASK_CWD="${WS}" run_task "${TASK}" \
    --param clusterName="${CLUSTER_NAME}" \
    --param roksIbmcloudSecretName=roks-ibmcloud \
    --param terraformStateBucket="${TERRAFORM_STATE_BUCKET}" \
    --param terraformStateSecretName=roks-terraform-state \
    --workspace-dir source="${WS}" \
    --drop '# Install tools' 'echo "✅ Tools installed"'
}

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

INIT_PREFIX="init -input=false -no-color -reconfigure"

# Test case: env_wiring
# The script reads params and Secrets from the step env; check the env list
# and the param defaults (the harness extracts only the script).
echo ""
echo "Test: env_wiring"
echo "--------------------------------------------"
python3 -I - "${TASK}" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    task = next(d for d in yaml.safe_load_all(f) if d and d.get("kind") == "Task")

params = {p["name"]: p.get("default") for p in task["spec"]["params"]}
expected_defaults = {
    "clusterName": None,
    "prNumber": "",
    "ibmcloudRegion": "eu-de",
    "ibmcloudResourceGroup": "redhat-sap-edge-roks-ci",
    "openshiftVersion": "4.21_openshift",
    "workerFlavor": "bx2.16x64",
    "workersPerZone": "1",
    "roksIbmcloudSecretName": None,
    "terraformStateBucket": None,
    "terraformStateEndpoint": "https://s3.eu-de.cloud-object-storage.appdomain.cloud",
    "terraformStateSecretName": None,
    "postgresAdminPasswordSecretName": "roks-postgres-admin-password",
    "deployPostgres": "true",
    "deployRedis": "true",
}
errors = []
if params != expected_defaults:
    errors.append(f"params/defaults differ: {params}")

step = task["spec"]["steps"][0]
env = {e["name"]: e for e in step["env"]}
expected_values = {
    "CLUSTER_NAME": "$(params.clusterName)",
    "PR_NUMBER": "$(params.prNumber)",
    "IBMCLOUD_REGION": "$(params.ibmcloudRegion)",
    "IBMCLOUD_RESOURCE_GROUP": "$(params.ibmcloudResourceGroup)",
    "OPENSHIFT_VERSION": "$(params.openshiftVersion)",
    "WORKER_FLAVOR": "$(params.workerFlavor)",
    "WORKERS_PER_ZONE": "$(params.workersPerZone)",
    "TERRAFORM_STATE_BUCKET": "$(params.terraformStateBucket)",
    "TERRAFORM_STATE_ENDPOINT": "$(params.terraformStateEndpoint)",
    "DEPLOY_POSTGRES": "$(params.deployPostgres)",
    "DEPLOY_REDIS": "$(params.deployRedis)",
    "POSTGRES_ADMIN_PASSWORD_SECRET_NAME": "$(params.postgresAdminPasswordSecretName)",
}
expected_secrets = {
    "IBMCLOUD_API_KEY": ("$(params.roksIbmcloudSecretName)", "IBMCLOUD_API_KEY", False),
    "AWS_ACCESS_KEY_ID": ("$(params.terraformStateSecretName)", "AWS_ACCESS_KEY_ID", False),
    "AWS_SECRET_ACCESS_KEY": ("$(params.terraformStateSecretName)", "AWS_SECRET_ACCESS_KEY", False),
    "POSTGRES_ADMIN_PASSWORD": ("$(params.postgresAdminPasswordSecretName)", "POSTGRES_ADMIN_PASSWORD", True),
}
for name, value in expected_values.items():
    if env.get(name, {}).get("value") != value:
        errors.append(f"env {name} should be {value}, got {env.get(name)}")
for name, (secret, key, optional) in expected_secrets.items():
    ref = env.get(name, {}).get("valueFrom", {}).get("secretKeyRef", {})
    if ref.get("name") != secret or ref.get("key") != key or bool(ref.get("optional", False)) != optional:
        errors.append(f"env {name} should come from Secret {secret} key {key} (optional={optional}), got {ref}")
if "set -x" in step["script"]:
    errors.append("script must not use set -x")
if step.get("workingDir") != "$(workspaces.source.path)":
    errors.append("workingDir must be the source workspace")
if [w["name"] for w in task["spec"]["workspaces"]] != ["source"]:
    errors.append("expected exactly the workspace 'source'")
if errors:
    print("\n".join(errors))
    sys.exit(1)
PY
echo "✅ PASS: env_wiring"

# Test case: init_uses_cos_backend
echo ""
echo "Test: init_uses_cos_backend"
echo "--------------------------------------------"
setup
run_deploy
expect_success

INIT_LINE=$(grep "^init " "${STUB_TF_LOG}" || true)
[[ "$(grep -c "^init " "${STUB_TF_LOG}")" -eq 1 ]] || { cat "${STUB_TF_LOG}"; fail "expected exactly one terraform init"; }
for EXPECTED in \
  "${INIT_PREFIX} " \
  "-backend-config=bucket=test-state-bucket" \
  "-backend-config=key=roks/redhat-roks-eic-pr7/terraform.tfstate" \
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
# init runs before apply, and the HMAC keys stay in the environment
[[ "$(sed -n 1p "${STUB_TF_LOG}")" == "${INIT_LINE}" ]] || { cat "${STUB_TF_LOG}"; fail "init is not the first terraform call"; }
! grep -qF "${FAKE_HMAC_ACCESS}" "${STUB_TF_LOG}" || fail "HMAC access key passed on the command line"
grep -qxF "apply -input=false -no-color -auto-approve" "${STUB_TF_LOG}" || { cat "${STUB_TF_LOG}"; fail "terraform apply -auto-approve not called"; }

# Logged in with the API key, region and resource group
grep -qxF "login --apikey ${FAKE_API_KEY} -r eu-de -g redhat-sap-edge-roks-ci" "${STUB_IC_LOG}" || { cat "${STUB_IC_LOG}"; fail "ibmcloud login not called as expected"; }

echo "✅ PASS: init_uses_cos_backend"

# Test case: init_retried_after_failure
echo ""
echo "Test: init_retried_after_failure"
echo "--------------------------------------------"
setup
echo "fail once" > "${STUB_TF_INIT_FAILURES}"
run_deploy
expect_success
[[ "$(grep -c "^init " "${STUB_TF_LOG}")" -eq 2 ]] || { cat "${STUB_TF_LOG}"; fail "expected two terraform init attempts"; }
echo "✅ PASS: init_retried_after_failure"

# Test case: tfvars_contents
echo ""
echo "Test: tfvars_contents"
echo "--------------------------------------------"
setup
export PR_NUMBER=7 WORKERS_PER_ZONE=2 WORKER_FLAVOR=bxf.16x64 OPENSHIFT_VERSION=4.20_openshift
run_deploy
expect_success

TFVARS="${WS}/roks/terraform/terraform.tfvars"
[[ -f "${TFVARS}" ]] || fail "terraform.tfvars not written"
[[ "$(file_mode "${TFVARS}")" == "600" ]] || fail "terraform.tfvars mode is $(file_mode "${TFVARS}"), expected 600"
for EXPECTED in \
  '^cluster_name *= "redhat-roks-eic-pr7"$' \
  '^region *= "eu-de"$' \
  '^resource_group *= "redhat-sap-edge-roks-ci"$' \
  '^openshift_version *= "4\.20_openshift"$' \
  '^worker_flavor *= "bxf\.16x64"$' \
  '^workers_per_zone *= 2$' \
  '^pr_number *= "7"$' \
  '^kubeconfig_dir *= "\./\.kube"$' \
  '^deploy_postgres *= true$' \
  '^deploy_redis *= true$' \
  "^postgres_admin_password *= \"${FAKE_PG_PASSWORD}\"$"; do
  grep -qE "${EXPECTED}" "${TFVARS}" || { sed 's/^postgres_admin_password.*/postgres_admin_password = (redacted)/' "${TFVARS}"; fail "terraform.tfvars lacks ${EXPECTED}"; }
done
! grep -qE '^(zones|pod_subnet|deploy_quay)' "${TFVARS}" || fail "zones/pod_subnet must keep their defaults; there is no deploy_quay*"
# The kubeconfig directory exists (the IBM provider fails otherwise)
[[ -d "${WS}/roks/terraform/.kube" ]] || fail "kubeconfig directory not created"

# Flags off (any case), no Postgres password needed or written
setup
export DEPLOY_POSTGRES=False DEPLOY_REDIS=FALSE POSTGRES_ADMIN_PASSWORD="" PR_NUMBER=""
run_deploy
expect_success
TFVARS="${WS}/roks/terraform/terraform.tfvars"
grep -qE '^deploy_postgres *= false$' "${TFVARS}" || fail "deploy_postgres = false not written"
grep -qE '^deploy_redis *= false$' "${TFVARS}" || fail "deploy_redis = false not written"
grep -qE '^pr_number *= ""$' "${TFVARS}" || fail "empty pr_number not written"
! grep -q "postgres_admin_password" "${TFVARS}" || fail "postgres_admin_password written although deploy_postgres is false"

echo "✅ PASS: tfvars_contents"

# Test case: rerun_same_state_key
# Second run of the same PR (fresh workspace, state already in the bucket):
# identical init/state key, plain apply again, nothing created a second time.
echo ""
echo "Test: rerun_same_state_key"
echo "--------------------------------------------"
setup
run_deploy
expect_success
FIRST_INIT=$(grep "^init " "${STUB_TF_LOG}")
CREATES_LOG="${STUB_TF_CREATES}"

setup keep-bucket
STUB_TF_CREATES="${CREATES_LOG}"
export STUB_TF_CREATES
run_deploy
expect_success
SECOND_INIT=$(grep "^init " "${STUB_TF_LOG}")
[[ "${FIRST_INIT}" == "${SECOND_INIT}" ]] || fail "init differs between runs: '${FIRST_INIT}' vs '${SECOND_INIT}'"
grep -qxF "apply -input=false -no-color -auto-approve" "${STUB_TF_LOG}" || fail "second run did not call terraform apply"
grep -q "No changes" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "second run did not reuse the existing state"; }
[[ "$(grep -c "^create " "${STUB_TF_CREATES}")" -eq 1 ]] || { cat "${STUB_TF_CREATES}"; fail "infrastructure created more than once"; }
# One path only: init, apply, output (no import/state surgery/destroy, no CLI cluster create)
! grep -vE '^(version|init|apply|output)( |$)' "${STUB_TF_LOG}" || fail "unexpected terraform subcommand on rerun"
! grep -qE "cluster[- ]create|cluster create" "${STUB_IC_LOG}" || fail "cluster created via the CLI"
[[ -f "${WS}/kubeconfig" ]] || fail "rerun did not write the workspace kubeconfig"

echo "✅ PASS: rerun_same_state_key"

# Test case: infra_key_reset_only_when_owner_differs
echo ""
echo "Test: infra_key_reset_only_when_owner_differs"
echo "--------------------------------------------"
# Owner is the logged-in service ID (with and without the iam- prefix)
for OWNER in "${LOGIN_IAM_ID}" "${LOGIN_IAM_ID#iam-}"; do
  setup
  printf '{"ID":"%s","Name":"redhat-sap-edge-roks-ci","Email":""}\n' "${OWNER}" > "${STUB_KEY_OWNER}"
  run_deploy
  expect_success
  grep -qxF "ks api-key info --cluster stub-cluster-id --output json -q" "${STUB_IC_LOG}" || { cat "${STUB_IC_LOG}"; fail "api-key info not called for the cluster id"; }
  ! grep -q "api-key reset" "${STUB_IC_LOG}" || fail "api-key reset called although the owner (${OWNER}) is the logged-in identity"
done

# Owner is somebody else (lowercase JSON keys) → exactly one reset in eu-de,
# after re-targeting and confirming the dedicated resource group
setup
echo "${FOREIGN_OWNER}" > "${STUB_KEY_OWNER}"
run_deploy
expect_success
[[ "$(grep -c "^ks api-key reset " "${STUB_IC_LOG}")" -eq 1 ]] || { cat "${STUB_IC_LOG}"; fail "expected exactly one api-key reset"; }
grep -qE "^ks api-key reset --region eu-de( |$)" "${STUB_IC_LOG}" || { cat "${STUB_IC_LOG}"; fail "api-key reset not called with --region eu-de"; }
grep -q "IBMid-0000USER" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "previous owner not reported"; }
RESET_LINE=$(ic_line "^ks api-key reset ")
TARGET_LINE=$(ic_line "^target -r eu-de -g redhat-sap-edge-roks-ci$")
TARGET_CHECK_LINE=$(ic_line "^target --output json$")
INFO_LINE=$(ic_line "^ks api-key info ")
[[ "${TARGET_LINE}" -gt 0 && "${TARGET_LINE}" -lt "${TARGET_CHECK_LINE}" && "${TARGET_CHECK_LINE}" -lt "${INFO_LINE}" && "${INFO_LINE}" -lt "${RESET_LINE}" ]] ||
  { cat "${STUB_IC_LOG}"; fail "expected target -g redhat-sap-edge-roks-ci, then target --output json, then info, then reset"; }
# Verified afterwards: info read again, success claimed only then
[[ "$(grep -c "^ks api-key info " "${STUB_IC_LOG}")" -eq 2 ]] || { cat "${STUB_IC_LOG}"; fail "owner not re-read after the reset"; }
grep -q "now belongs to ${LOGIN_IAM_ID}" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "verified reset not reported"; }

echo "✅ PASS: infra_key_reset_only_when_owner_differs"

# Test case: infra_key_reset_only_in_dedicated_group
# The reset acts on the CLI's targeted resource group: never reset unless that
# is exactly redhat-sap-edge-roks-ci (the Default group runs the user's cluster).
echo ""
echo "Test: infra_key_reset_only_in_dedicated_group"
echo "--------------------------------------------"
setup
export IBMCLOUD_RESOURCE_GROUP=Default
echo "${FOREIGN_OWNER}" > "${STUB_KEY_OWNER}"
run_deploy
expect_success
! grep -q "api-key reset" "${STUB_IC_LOG}" || { cat "${STUB_IC_LOG}"; fail "api-key reset called for resource group Default"; }
grep -q "not resetting" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "skipped reset not explained"; }

# Param is right, but the CLI still targets another group → no reset
setup
target_group Default
echo "${FOREIGN_OWNER}" > "${STUB_KEY_OWNER}"
run_deploy
expect_success
grep -qxF "target -r eu-de -g redhat-sap-edge-roks-ci" "${STUB_IC_LOG}" || { cat "${STUB_IC_LOG}"; fail "dedicated group not re-targeted"; }
! grep -q "api-key reset" "${STUB_IC_LOG}" || { cat "${STUB_IC_LOG}"; fail "api-key reset called while the CLI targets Default"; }
grep -q "Default" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "targeted group not reported"; }

echo "✅ PASS: infra_key_reset_only_in_dedicated_group"

# Test case: infra_key_unreadable_owner_no_reset
# Unknown owner is not "different owner": warn, show the JSON keys, no reset.
echo ""
echo "Test: infra_key_unreadable_owner_no_reset"
echo "--------------------------------------------"
setup
STUB_KEY_INFO_FAILS=true
export STUB_KEY_INFO_FAILS
run_deploy
expect_success
! grep -q "api-key reset" "${STUB_IC_LOG}" || fail "api-key reset called although api-key info failed"
grep -q "⚠️" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "no warning for the failed api-key info"; }

setup
echo '{"Owner":"someone","Created":"2026-10-25"}' > "${STUB_KEY_OWNER}"
run_deploy
expect_success
! grep -q "api-key reset" "${STUB_IC_LOG}" || fail "api-key reset called although no owner ID/email was parsed"
grep -qF '["Created","Owner"]' <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "top-level JSON keys not printed"; }

setup
echo 'Owner: Some User' > "${STUB_KEY_OWNER}"
run_deploy
expect_success
! grep -q "api-key reset" "${STUB_IC_LOG}" || fail "api-key reset called for non-JSON api-key info output"

echo "✅ PASS: infra_key_unreadable_owner_no_reset"

# Test case: infra_key_reset_unverified_warns
# The owner is still foreign after the reset → loud warning, no success claim.
echo ""
echo "Test: infra_key_reset_unverified_warns"
echo "--------------------------------------------"
setup
STUB_RESET_FIXES_OWNER=false
export STUB_RESET_FIXES_OWNER
echo "${FOREIGN_OWNER}" > "${STUB_KEY_OWNER}"
run_deploy
expect_success
[[ "$(grep -c "^ks api-key reset " "${STUB_IC_LOG}")" -eq 1 ]] || { cat "${STUB_IC_LOG}"; fail "expected exactly one api-key reset"; }
! grep -q "now belongs to" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "success claimed although the owner did not change"; }
grep -q "still" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "unverified reset not warned about"; }

echo "✅ PASS: infra_key_reset_unverified_warns"

# Test case: writes_workspace_kubeconfig
echo ""
echo "Test: writes_workspace_kubeconfig"
echo "--------------------------------------------"
setup
run_deploy
expect_success
grep -qxF "config view --flatten --raw --kubeconfig ${WS}/roks/terraform/.kube/stub-kube/config.yml" "${FAKE_OC_LOG}" || { cat "${FAKE_OC_LOG}"; fail "admin kubeconfig not flattened from admin_kubeconfig_path"; }
[[ -f "${WS}/kubeconfig" ]] || fail "workspace kubeconfig not written"
[[ "$(file_mode "${WS}/kubeconfig")" == "600" ]] || fail "workspace kubeconfig mode is $(file_mode "${WS}/kubeconfig"), expected 600"
assert_file_contains "${WS}/kubeconfig" "client-key-data: stub-key-data"
assert_file_contains "${WS}/kubeconfig" "server: https://c100.eu-de.containers.cloud.ibm.com:31000"
! grep -q "admin.pem" "${WS}/kubeconfig" || fail "workspace kubeconfig still references certificate files"
echo "✅ PASS: writes_workspace_kubeconfig"

# Test case: no_secret_in_output
echo ""
echo "Test: no_secret_in_output"
echo "--------------------------------------------"
setup
run_deploy
expect_success
OUTPUTS_FILE="${WS}/roks-terraform-outputs.json"
[[ -f "${OUTPUTS_FILE}" ]] || fail "roks-terraform-outputs.json not written"
for SECRET in "${FAKE_API_KEY}" "${FAKE_HMAC_ACCESS}" "${FAKE_HMAC_SECRET}" "${FAKE_PG_PASSWORD}" \
  "${FAKE_REDIS_PASSWORD}" "${FAKE_ICR_API_KEY}" "${FAKE_JWT_SIGNATURE}"; do
  ! grep -qF -- "${SECRET}" <<< "${TASK_OUT}" || fail "secret '${SECRET}' printed in the task output"
  ! grep -qF -- "${SECRET}" "${OUTPUTS_FILE}" || fail "secret '${SECRET}' written to roks-terraform-outputs.json"
done
jq -e 'has("redis_password") or has("icr_api_key") | not' "${OUTPUTS_FILE}" >/dev/null || fail "sensitive outputs kept in roks-terraform-outputs.json"
jq -e '[.[] | select(.sensitive == true)] | length == 0' "${OUTPUTS_FILE}" >/dev/null || fail "an output marked sensitive was kept"
for KEY in admin_kubeconfig_path cluster_id cluster_name ingress_hostname vpc_id resource_group_id \
  icr_registry icr_namespace icr_username postgres_host postgres_port redis_host redis_port; do
  jq -e --arg k "${KEY}" 'has($k)' "${OUTPUTS_FILE}" >/dev/null || fail "non-sensitive output ${KEY} missing"
done
[[ "$(jq -r '.ingress_hostname.value' "${OUTPUTS_FILE}")" == "redhat-roks-eic-pr7-abc-0000.eu-de.containers.appdomain.cloud" ]] || fail "outputs file does not keep terraform's {value: ...} structure"
# Nothing marked sensitive is printed by the summary either, but endpoints are
grep -qF "pg.stub.databases.appdomain.cloud" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "summary lacks the PostgreSQL endpoint"; }
echo "✅ PASS: no_secret_in_output"

# Test case: invalid_cluster_name_fails
echo ""
echo "Test: invalid_cluster_name_fails"
echo "--------------------------------------------"
for NAME in "Redhat_ROKS" "redhat-ROKS" "roks-eic-pr7" "redhat-roks-eic-pr7-0123456789x" "redhat-roks-"; do
  setup
  export CLUSTER_NAME="${NAME}"
  run_deploy
  [[ "${TASK_RC}" -ne 0 ]] || { echo "${TASK_OUT}"; fail "cluster name '${NAME}' accepted"; }
  [[ ! -s "${STUB_TF_LOG}" ]] || fail "terraform called despite the invalid cluster name '${NAME}'"
  [[ ! -s "${STUB_IC_LOG}" ]] || fail "ibmcloud called despite the invalid cluster name '${NAME}'"
  grep -q "redhat-" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "error for '${NAME}' does not explain the naming rule"; }
done
echo "✅ PASS: invalid_cluster_name_fails"

# Test case: invalid_postgres_password_fails
# Checked before any terraform call (a tfvars parse error would print the
# line with the password) and never printed.
echo ""
echo "Test: invalid_postgres_password_fails"
echo "--------------------------------------------"
for PASSWORD in "" "Short1abc" "-StartsWithDash1234" "lower-case-only-123" "UPPER-CASE-ONLY-123" \
  "NoDigitsAtAllHereX" 'Quote"Injection1234' $'TrailingNewline1234\n'; do
  setup
  export POSTGRES_ADMIN_PASSWORD="${PASSWORD}"
  run_deploy
  [[ "${TASK_RC}" -ne 0 ]] || { echo "${TASK_OUT}"; fail "invalid Postgres password accepted"; }
  [[ ! -s "${STUB_TF_LOG}" ]] || fail "terraform called despite an invalid Postgres password"
  FIRST_LINE="${PASSWORD%%$'\n'*}"
  if [[ -n "${FIRST_LINE}" ]]; then
    ! grep -qF -- "${FIRST_LINE}" <<< "${TASK_OUT}" || fail "invalid Postgres password printed"
  fi
  grep -q "roks-postgres-admin-password" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "error does not name the Secret"; }
done
echo "✅ PASS: invalid_postgres_password_fails"

# Test case: state_lock_prints_unlock_guidance
echo ""
echo "Test: state_lock_prints_unlock_guidance"
echo "--------------------------------------------"
setup
STUB_TF_LOCKED=true
export STUB_TF_LOCKED
run_deploy
[[ "${TASK_RC}" -ne 0 ]] || { echo "${TASK_OUT}"; fail "state lock error did not fail the task"; }
grep -qF "terraform -chdir=roks/terraform force-unlock 6f0f3c1e-1a2b-4c3d-9e8f-0123456789ab" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "force-unlock guidance with the lock ID not printed"; }
grep -qF "make roks-init CLUSTER=redhat-roks-eic-pr7" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "guidance does not show how to init the state locally"; }
! grep -q "force-unlock" "${STUB_TF_LOG}" || fail "the task must not force-unlock by itself"
[[ ! -f "${WS}/kubeconfig" ]] || fail "kubeconfig written although apply failed"
echo "✅ PASS: state_lock_prints_unlock_guidance"
