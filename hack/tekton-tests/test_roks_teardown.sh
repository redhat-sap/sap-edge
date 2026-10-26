#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=./lib.sh disable=SC1091
source lib.sh

echo "============================================"
echo "Test: roks-teardown task"
echo "============================================"

TASK=../../.tekton/tasks/roks-teardown-task.yaml
CLUSTER=redhat-roks-eic-pr7
# ROKS cluster IDs: 20 lowercase letters and digits
THIS_CID="c7000000000000000001"
OTHER_CID="c8000000000000000002"

# Fake credentials: none of them may ever show up in the task output or in
# the argv logs of the stubs.
FAKE_API_KEY="FAKE-IBM-APIKEY-0123456789abcdef"
FAKE_HMAC_ACCESS="FAKE-HMAC-ACCESS-KEY-0123"
FAKE_HMAC_SECRET="FAKE-HMAC-SECRET-KEY-0123456789abcdef"
FAKE_PG_PASSWORD="FakePostgresPassword123"
FAKE_REDIS_PASSWORD="FAKE-REDIS-PASSWORD-0123456789"
FAKE_ICR_API_KEY="FAKE-ICR-APIKEY-0123456789abcdef"
export FAKE_REDIS_PASSWORD FAKE_ICR_API_KEY
HUB_KUBECONFIG_B64=$(printf 'apiVersion: v1\nkind: Config\n' | base64 | tr -d '\n')

STUB_BIN=$(tmp_dir)
export PATH="${STUB_BIN}:${PATH}"

# Stub terraform: logs every call (also to the shared sequence log); init can
# fail a given number of times; output -raw cluster_id prints STUB_TF_CLUSTER_ID
# (fails when empty), output -json prints sensitive values (a leak would show);
# each destroy takes the next outcome from STUB_TF_DESTROY_PLAN (default ok):
#   ok                 empties the state
#   fail               fails, state unchanged (cluster still in it)
#   fail-cluster-gone  deletes the cluster from the state, then fails on a subnet
#   lock               fails with a state lock error
# state list prints the state.
cat > "${STUB_BIN}/terraform" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${STUB_TF_LOG}"
printf 'tf %s\n' "$*" >> "${STUB_SEQ_LOG}"
case "${1:-}" in
  init)
    if [[ -s "${STUB_TF_INIT_FAILURES}" ]]; then
      sed -i.bak '1d' "${STUB_TF_INIT_FAILURES}"
      echo "Error: Failed to query available provider packages" >&2
      exit 1
    fi
    echo "Terraform has been successfully initialized!"
    ;;
  output)
    case "${2:-} ${3:-}" in
      "-raw cluster_id")
        if [[ -z "${STUB_TF_CLUSTER_ID}" ]]; then
          echo 'Error: Output "cluster_id" not found' >&2
          exit 1
        fi
        printf '%s' "${STUB_TF_CLUSTER_ID}"
        ;;
      "-json ")
        printf '{"icr_api_key":{"sensitive":true,"value":"%s"},"redis_password":{"sensitive":true,"value":"%s"}}\n' \
          "${FAKE_ICR_API_KEY}" "${FAKE_REDIS_PASSWORD}"
        ;;
      *) echo "unexpected terraform output call: $*" >&2; exit 1 ;;
    esac
    ;;
  destroy)
    OUTCOME=$(sed -n 1p "${STUB_TF_DESTROY_PLAN}")
    if [[ -s "${STUB_TF_DESTROY_PLAN}" ]]; then
      sed -i.bak '1d' "${STUB_TF_DESTROY_PLAN}"
    fi
    case "${OUTCOME:-ok}" in
      ok)
        : > "${STUB_TF_STATE}"
        echo "Destroy complete! Resources: 25 destroyed."
        ;;
      fail)
        echo "Error: waiting for cluster deletion: timeout while waiting for state to become 'deleted'" >&2
        exit 1
        ;;
      fail-cluster-gone)
        grep -vx 'ibm_container_vpc_cluster.cluster' "${STUB_TF_STATE}" > "${STUB_TF_STATE}.new" || true
        mv "${STUB_TF_STATE}.new" "${STUB_TF_STATE}"
        echo "Error: deleting subnet: the subnet is in use by a load balancer" >&2
        exit 1
        ;;
      lock)
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
LOCK
        exit 1
        ;;
      *) echo "unknown stub destroy outcome ${OUTCOME}" >&2; exit 1 ;;
    esac
    ;;
  state)
    [[ "${2:-}" == "list" ]] || { echo "unexpected terraform state call: $*" >&2; exit 1; }
    cat "${STUB_TF_STATE}"
    ;;
  version) echo "Terraform v1.13.5" ;;
  *) echo "unexpected terraform call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "${STUB_BIN}/terraform"

# Stub ibmcloud: logs every call (also to the sequence log); login only works
# with the API key in the environment; load balancers and volumes come from
# JSON files; a delete removes the object unless its ID is listed in STUB_STUCK.
# A delete call that gets data on stdin (it could read the rest of the
# caller's list) is logged as "stdin-consumed".
cat > "${STUB_BIN}/ibmcloud" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${STUB_IC_LOG}"
printf 'ic %s\n' "$*" >> "${STUB_SEQ_LOG}"
case "$*" in
  "config --check-version=false") ;;
  "login "*)
    if [[ -z "${IBMCLOUD_API_KEY:-}" ]]; then
      echo "FAILED: no API key in IBMCLOUD_API_KEY" >&2
      exit 1
    fi
    printf 'API endpoint: https://cloud.ibm.com\nAuthenticating...\nOK\n'
    ;;
  "target "*) echo "Targeted" ;;
  "is load-balancers "*) cat "${STUB_LBS}" ;;
  "is volumes "*) cat "${STUB_VOLS}" ;;
  "is load-balancer-delete "* | "is volume-delete "*)
    if [[ -n "$(cat)" ]]; then printf 'stdin-consumed %s\n' "$*" >> "${STUB_IC_LOG}"; fi
    FILE="${STUB_LBS}"
    if [[ "$2" == "volume-delete" ]]; then
      FILE="${STUB_VOLS}"
    fi
    if grep -qx -- "$3" "${STUB_STUCK}"; then
      exit 0
    fi
    jq --arg id "$3" 'map(select(.id != $id))' "${FILE}" > "${FILE}.new"
    mv "${FILE}.new" "${FILE}"
    ;;
  *) echo "unexpected ibmcloud call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "${STUB_BIN}/ibmcloud"

# Load balancers and volumes in the account. "full": leftovers of this cluster
# in the dedicated group plus decoys in another group / of another cluster;
# "unrelated": only the decoys.
write_inventory() {
  local CI='{"id": "rg-ci", "name": "redhat-sap-edge-roks-ci"}'
  local DEFAULT='{"id": "rg-default", "name": "Default"}'
  local THIS_LB="" THIS_VOLS=""
  if [[ "$1" == "full" ]]; then
    THIS_LB="{\"id\": \"r010-lb-this\", \"name\": \"kube-${THIS_CID}-1a2b3c4d\", \"resource_group\": ${CI}, \"provisioning_status\": \"active\"},"
    THIS_VOLS="{\"id\": \"r010-vol-this-tag\", \"name\": \"pvc-0a1b2c3d\", \"resource_group\": ${CI}, \"user_tags\": [\"clusterid:${THIS_CID}\", \"namespace:edgelm\"], \"status\": \"available\"},
  {\"id\": \"r010-vol-this-name\", \"name\": \"${THIS_CID}-pvc-4e5f\", \"resource_group\": ${CI}, \"user_tags\": [], \"status\": \"available\"},"
  fi
  cat > "${STUB_LBS}" <<JSON
[
  ${THIS_LB}
  {"id": "r010-lb-other-cluster", "name": "kube-${OTHER_CID}-5e6f7a8b", "resource_group": ${CI}, "provisioning_status": "active"},
  {"id": "r010-lb-other-group", "name": "kube-${THIS_CID}-9c0d1e2f", "resource_group": ${DEFAULT}, "provisioning_status": "active"},
  {"id": "r010-lb-unrelated", "name": "my-own-lb", "resource_group": ${CI}, "provisioning_status": "active"}
]
JSON
  cat > "${STUB_VOLS}" <<JSON
[
  ${THIS_VOLS}
  {"id": "r010-vol-other-cluster", "name": "pvc-6a7b", "resource_group": ${CI}, "user_tags": ["clusterid:${OTHER_CID}"], "status": "available"},
  {"id": "r010-vol-other-group", "name": "pvc-8c9d", "resource_group": ${DEFAULT}, "user_tags": ["clusterid:${THIS_CID}"], "status": "available"},
  {"id": "r010-vol-untagged", "name": "pvc-0e1f", "resource_group": ${CI}, "user_tags": null, "status": "available"}
]
JSON
}

# roks-terraform-outputs.json as roks-deploy writes it (non-sensitive outputs)
write_outputs_file() {
  printf '{"cluster_id": {"sensitive": false, "type": "string", "value": "%s"}, "cluster_name": {"sensitive": false, "type": "string", "value": "%s"}}\n' \
    "$2" "$1" > "${WS}/roks-terraform-outputs.json"
}

# Fresh stubs, state and workspace (as left by roks-deploy: terraform.tfvars
# with the PostgreSQL password, roks-terraform-outputs.json), default env.
setup() {
  STUB_TF_LOG=$(tmp_file)
  STUB_IC_LOG=$(tmp_file)
  STUB_SEQ_LOG=$(tmp_file)
  STUB_TF_INIT_FAILURES=$(tmp_file)
  STUB_TF_DESTROY_PLAN=$(tmp_file)
  STUB_TF_STATE=$(tmp_file)
  STUB_LBS=$(tmp_file)
  STUB_VOLS=$(tmp_file)
  STUB_STUCK=$(tmp_file)
  STUB_TF_CLUSTER_ID="${THIS_CID}"
  export STUB_TF_LOG STUB_IC_LOG STUB_SEQ_LOG STUB_TF_INIT_FAILURES STUB_TF_DESTROY_PLAN STUB_TF_STATE
  export STUB_LBS STUB_VOLS STUB_STUCK STUB_TF_CLUSTER_ID
  cat > "${STUB_TF_STATE}" <<'EOF'
data.ibm_resource_group.group
ibm_container_vpc_cluster.cluster
ibm_cr_namespace.icr
ibm_iam_service_id.icr
ibm_is_subnet.zone["eu-de-1"]
ibm_is_vpc.vpc
terraform_data.vpe_cleanup
EOF
  write_inventory unrelated

  WS=$(tmp_dir)
  mkdir -p "${WS}/roks/terraform"
  (
    umask 077
    printf 'cluster_name = "%s"\ndeploy_postgres = true\npostgres_admin_password = "%s"\n' \
      "${CLUSTER}" "${FAKE_PG_PASSWORD}" > "${WS}/roks/terraform/terraform.tfvars"
  )
  write_outputs_file "${CLUSTER}" "${THIS_CID}"

  FAKE_OC_LOG=$(tmp_file)
  FAKE_OC_RULES=$(tmp_file)
  printf 'get secret eic-kubeconfig -o jsonpath=*kubeconfig*\t0\t%s\n' "${HUB_KUBECONFIG_B64}" > "${FAKE_OC_RULES}"
  export FAKE_OC_LOG FAKE_OC_RULES

  # Step env (params and Secrets, see the task's env list)
  export CLUSTER_NAME="${CLUSTER}"
  export IBMCLOUD_REGION=eu-de
  export IBMCLOUD_RESOURCE_GROUP=redhat-sap-edge-roks-ci
  export TERRAFORM_STATE_BUCKET=test-state-bucket
  export TERRAFORM_STATE_ENDPOINT=https://s3.eu-de.cloud-object-storage.appdomain.cloud
  export HUB_KUBECONFIG_SECRET=""
  export IBMCLOUD_API_KEY="${FAKE_API_KEY}"
  export AWS_ACCESS_KEY_ID="${FAKE_HMAC_ACCESS}"
  export AWS_SECRET_ACCESS_KEY="${FAKE_HMAC_SECRET}"
  export TF_INIT_RETRY_DELAY=0 TF_DESTROY_RETRY_DELAY=0 SWEEP_WAIT_SECONDS=1 SWEEP_POLL_SECONDS=0
}

run_teardown() {
  TASK_CWD="${WS}" run_task "${TASK}" \
    --param clusterName="${CLUSTER_NAME}" \
    --param roksCredentialsSecretName=roks-ci-credentials \
    --param terraformStateBucket="${TERRAFORM_STATE_BUCKET}" \
    --workspace-dir source="${WS}" \
    --drop '# Install tools' 'echo "✅ Tools installed"'
}

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

# Line number of the first / last sequence-log entry matching an ERE (0 if none)
seq_first() {
  local N
  N=$(grep -nE "$1" "${STUB_SEQ_LOG}" | head -1 | cut -d: -f1)
  echo "${N:-0}"
}
seq_last() {
  local N
  N=$(grep -nE "$1" "${STUB_SEQ_LOG}" | tail -1 | cut -d: -f1)
  echo "${N:-0}"
}

destroy_count() {
  grep -c "^destroy " "${STUB_TF_LOG}" || true
}

INIT_PREFIX="init -input=false -no-color -reconfigure"

# Test case: env_wiring
# The script reads params and Secrets from the step env; check the env list,
# the param defaults and the tool installation (dropped in the runs below).
echo ""
echo "Test: env_wiring"
echo "--------------------------------------------"
python3 -I - "${TASK}" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    task = next(d for d in yaml.safe_load_all(f) if d and d.get("kind") == "Task")

errors = []
if task["metadata"]["name"] != "roks-teardown":
    errors.append("task must be named roks-teardown")
params = {p["name"]: p.get("default") for p in task["spec"]["params"]}
expected_defaults = {
    "clusterName": None,
    "ibmcloudRegion": "eu-de",
    "ibmcloudResourceGroup": "redhat-sap-edge-roks-ci",
    "roksCredentialsSecretName": None,
    "terraformStateBucket": None,
    "terraformStateEndpoint": "https://s3.eu-de.cloud-object-storage.appdomain.cloud",
    "hubKubeconfigSecretName": "",
}
if params != expected_defaults:
    errors.append(f"params/defaults differ: {params}")

steps = task["spec"]["steps"]
if len(steps) != 1:
    errors.append("expected exactly one step")
step = steps[0]
env = {e["name"]: e for e in step["env"]}
expected_values = {
    "CLUSTER_NAME": "$(params.clusterName)",
    "IBMCLOUD_REGION": "$(params.ibmcloudRegion)",
    "IBMCLOUD_RESOURCE_GROUP": "$(params.ibmcloudResourceGroup)",
    "TERRAFORM_STATE_BUCKET": "$(params.terraformStateBucket)",
    "TERRAFORM_STATE_ENDPOINT": "$(params.terraformStateEndpoint)",
    "HUB_KUBECONFIG_SECRET": "$(params.hubKubeconfigSecretName)",
}
# The API key and the COS HMAC keys of the credentials Secret (no Postgres
# password: destroy works from the state)
expected_secrets = {
    "IBMCLOUD_API_KEY": ("$(params.roksCredentialsSecretName)", "IBMCLOUD_API_KEY"),
    "AWS_ACCESS_KEY_ID": ("$(params.roksCredentialsSecretName)", "AWS_ACCESS_KEY_ID"),
    "AWS_SECRET_ACCESS_KEY": ("$(params.roksCredentialsSecretName)", "AWS_SECRET_ACCESS_KEY"),
}
for name, value in expected_values.items():
    if env.get(name, {}).get("value") != value:
        errors.append(f"env {name} should be {value}, got {env.get(name)}")
for name, (secret, key) in expected_secrets.items():
    ref = env.get(name, {}).get("valueFrom", {}).get("secretKeyRef", {})
    if ref.get("name") != secret or ref.get("key") != key or ref.get("optional", False):
        errors.append(f"env {name} should come from Secret {secret} key {key} (required), got {ref}")
if set(env) != set(expected_values) | set(expected_secrets):
    errors.append(f"unexpected env names: {sorted(set(env) - set(expected_values) - set(expected_secrets))}")
# Well above the 2h Terraform cluster delete timeout, like roks-deploy
if step.get("timeout") != "336h":
    errors.append(f"step timeout should be 336h like roks-deploy, got {step.get('timeout')}")
if step.get("workingDir") != "$(workspaces.source.path)":
    errors.append("workingDir must be the source workspace")
if [w["name"] for w in task["spec"]["workspaces"]] != ["source"]:
    errors.append("expected exactly the workspace 'source'")
script = step["script"]
if "set -x" in script:
    errors.append("script must not use set -x")
for needed in (
    "dnf install -y jq ",
    'TERRAFORM_VERSION="1.13.5"',
    'sha256sum -c --ignore-missing "terraform_${TERRAFORM_VERSION}_SHA256SUMS"',
    "ibmcloud plugin install container-service -f",
    "ibmcloud plugin install vpc-infrastructure -f",
):
    if needed not in script:
        errors.append(f"script lacks '{needed}'")
if "--apikey" in script:
    errors.append("the API key must not be passed on the ibmcloud command line")
if errors:
    print("\n".join(errors))
    sys.exit(1)
PY
echo "✅ PASS: env_wiring"

# Test case: destroy_uses_same_state_key
echo ""
echo "Test: destroy_uses_same_state_key"
echo "--------------------------------------------"
setup
run_teardown
expect_success

INIT_LINE=$(grep "^init " "${STUB_TF_LOG}" || true)
[[ "$(grep -c "^init " "${STUB_TF_LOG}")" -eq 1 ]] || { cat "${STUB_TF_LOG}"; fail "expected exactly one terraform init"; }
# Same flag set as roks-deploy and roks-registry-access
for EXPECTED in \
  "${INIT_PREFIX} " \
  "-backend-config=bucket=test-state-bucket" \
  "-backend-config=key=roks/${CLUSTER}/terraform.tfstate" \
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
[[ "$(sed -n 1p "${STUB_TF_LOG}")" == "${INIT_LINE}" ]] || { cat "${STUB_TF_LOG}"; fail "init is not the first terraform call"; }
[[ "$(destroy_count)" -eq 1 ]] || { cat "${STUB_TF_LOG}"; fail "expected exactly one terraform destroy"; }
grep -q "^destroy .*-auto-approve" "${STUB_TF_LOG}" || fail "terraform destroy without -auto-approve"

# Retried init
setup
echo "fail once" > "${STUB_TF_INIT_FAILURES}"
run_teardown
expect_success
[[ "$(grep -c "^init " "${STUB_TF_LOG}")" -eq 2 ]] || { cat "${STUB_TF_LOG}"; fail "expected two terraform init attempts"; }

echo "✅ PASS: destroy_uses_same_state_key"

# Test case: destroy_refresh_false_and_cluster_var
# Destroy straight from the state: no refresh (the admin-kubeconfig data source
# fails once the cluster is gone), only the variables Terraform needs, the
# deploy flags left at their defaults.
echo ""
echo "Test: destroy_refresh_false_and_cluster_var"
echo "--------------------------------------------"
setup
run_teardown
expect_success
DESTROY_LINE=$(grep "^destroy " "${STUB_TF_LOG}" | head -1)
for EXPECTED in " -input=false" " -auto-approve" " -refresh=false" " -var cluster_name=${CLUSTER}" " -var region=eu-de"; do
  grep -qF -- "${EXPECTED}" <<< "${DESTROY_LINE}" || fail "terraform destroy args lack '${EXPECTED}': ${DESTROY_LINE}"
done
! grep -qE "deploy_postgres|deploy_redis|postgres_admin_password|-var-file" <<< "${DESTROY_LINE}" || fail "destroy must not pass deploy flags or a password: ${DESTROY_LINE}"
[[ -d "${WS}/roks/terraform/.kube" ]] || fail "kubeconfig directory not created"
echo "✅ PASS: destroy_refresh_false_and_cluster_var"

# Test case: destroy_partial_state
echo ""
echo "Test: destroy_partial_state"
echo "--------------------------------------------"
# A failed attempt is retried and the task succeeds; while the cluster is still
# in the state (it may still exist), nothing is swept between the attempts.
setup
write_inventory full
printf 'fail\nok\n' > "${STUB_TF_DESTROY_PLAN}"
run_teardown
expect_success
[[ "$(destroy_count)" -eq 2 ]] || { cat "${STUB_TF_LOG}"; fail "expected two terraform destroy attempts"; }
FIRST_IS=$(seq_first "^ic is ")
SECOND_DESTROY=$(seq_last "^tf destroy ")
[[ "${FIRST_IS}" -gt "${SECOND_DESTROY}" ]] || { cat "${STUB_SEQ_LOG}"; fail "swept while the cluster was still in the state"; }

# The first attempt deleted the cluster but failed on a subnet that a leftover
# load balancer still uses: the leftovers are swept before the next attempt.
setup
write_inventory full
printf 'fail-cluster-gone\nok\n' > "${STUB_TF_DESTROY_PLAN}"
run_teardown
expect_success
[[ "$(destroy_count)" -eq 2 ]] || { cat "${STUB_TF_LOG}"; fail "expected two terraform destroy attempts"; }
FIRST_DESTROY=$(seq_first "^tf destroy ")
LB_DELETE=$(seq_first "^ic is load-balancer-delete r010-lb-this ")
SECOND_DESTROY=$(seq_last "^tf destroy ")
[[ "${FIRST_DESTROY}" -lt "${LB_DELETE}" && "${LB_DELETE}" -lt "${SECOND_DESTROY}" ]] || { cat "${STUB_SEQ_LOG}"; fail "leftover load balancer not swept between the attempts"; }

# Partial apply: the cluster was never created (no cluster_id output, no
# outputs file); destroy removes what the state tracks and the task succeeds.
setup
STUB_TF_CLUSTER_ID=""
export STUB_TF_CLUSTER_ID
rm -f "${WS}/roks-terraform-outputs.json"
printf 'ibm_is_vpc.vpc\nibm_resource_instance.cos\n' > "${STUB_TF_STATE}"
run_teardown
expect_success
[[ ! -s "${STUB_TF_STATE}" ]] || fail "state not destroyed"

echo "✅ PASS: destroy_partial_state"

# Test case: destroy_failure_lists_state_and_hints
echo ""
echo "Test: destroy_failure_lists_state_and_hints"
echo "--------------------------------------------"
setup
write_inventory full
printf 'fail\nfail\nfail\n' > "${STUB_TF_DESTROY_PLAN}"
run_teardown
expect_failure
[[ "$(destroy_count)" -eq 3 ]] || { cat "${STUB_TF_LOG}"; fail "expected three terraform destroy attempts"; }
grep -q "^state list" "${STUB_TF_LOG}" || fail "terraform state list not called"
for EXPECTED in "ibm_container_vpc_cluster.cluster" "ibm_cr_namespace.icr" 'ibm_is_subnet.zone["eu-de-1"]' \
  "force-unlock" \
  "terraform -chdir=roks/terraform state rm ibm_container_vpc_cluster.cluster" \
  "terraform -chdir=roks/terraform state rm ibm_cr_namespace.icr" \
  "ibm_iam_service_id.icr" \
  "make roks-init CLUSTER=${CLUSTER}" \
  "make roks-destroy CLUSTER=${CLUSTER}"; do
  grep -qF -- "${EXPECTED}" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "output lacks '${EXPECTED}'"; }
done
# The final list names the resources left in the state (not data sources)
REMAINING_SECTION=$(sed -n '/still present/,$p' <<< "${TASK_OUT}")
for EXPECTED in "Terraform state: ibm_container_vpc_cluster.cluster" "Terraform state: ibm_is_vpc.vpc"; do
  grep -qF -- "${EXPECTED}" <<< "${REMAINING_SECTION}" || { echo "${TASK_OUT}"; fail "remaining list lacks '${EXPECTED}'"; }
done
! grep -q "data.ibm_resource_group" <<< "${REMAINING_SECTION}" || fail "data source listed as remaining"
# The cluster is still in the state: no sweep; the pipeline artifacts still go
! grep -q -- "-delete " "${STUB_IC_LOG}" || { cat "${STUB_IC_LOG}"; fail "swept although the cluster is still in the state"; }
assert_called "^delete configmap cluster-info-roks-${CLUSTER} --ignore-not-found=true$"
echo "✅ PASS: destroy_failure_lists_state_and_hints"

# Test case: state_lock_stops_retries
echo ""
echo "Test: state_lock_stops_retries"
echo "--------------------------------------------"
setup
echo "lock" > "${STUB_TF_DESTROY_PLAN}"
run_teardown
expect_failure
[[ "$(destroy_count)" -eq 1 ]] || { cat "${STUB_TF_LOG}"; fail "a locked state must not be retried"; }
grep -qF "terraform -chdir=roks/terraform force-unlock 6f0f3c1e-1a2b-4c3d-9e8f-0123456789ab" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "force-unlock guidance with the lock ID not printed"; }
! grep -q "force-unlock" "${STUB_TF_LOG}" || fail "the task must not force-unlock by itself"
echo "✅ PASS: state_lock_stops_retries"

# Test case: sweep_scoped_to_group_and_cluster
# Only load balancers / volumes in redhat-sap-edge-roks-ci whose name or tags
# contain this cluster's ID; never the same ID in another group, never another
# cluster's objects in the group.
echo ""
echo "Test: sweep_scoped_to_group_and_cluster"
echo "--------------------------------------------"
setup
write_inventory full
run_teardown
expect_success
grep -qE "^is load-balancers( |$)" "${STUB_IC_LOG}" || fail "load balancers not listed"
grep -qE "^is volumes( |$)" "${STUB_IC_LOG}" || fail "volumes not listed"
for DELETED in "load-balancer-delete r010-lb-this" "volume-delete r010-vol-this-tag" "volume-delete r010-vol-this-name"; do
  grep -qE "^is ${DELETED} (.* )?--force( |$)" "${STUB_IC_LOG}" || { cat "${STUB_IC_LOG}"; fail "'${DELETED} --force' not called"; }
done
DELETED_IDS=$(sed -n 's/^is [a-z-]*-delete \([^ ]*\).*/\1/p' "${STUB_IC_LOG}" | sort -u | tr '\n' ' ')
[[ "${DELETED_IDS}" == "r010-lb-this r010-vol-this-name r010-vol-this-tag " ]] || fail "unexpected deletions: ${DELETED_IDS}"
[[ "$(jq -r '[.[].id] | join(",")' "${STUB_LBS}")" == "r010-lb-other-cluster,r010-lb-other-group,r010-lb-unrelated" ]] || fail "unexpected remaining load balancers"
[[ "$(jq -r '[.[].id] | join(",")' "${STUB_VOLS}")" == "r010-vol-other-cluster,r010-vol-other-group,r010-vol-untagged" ]] || fail "unexpected remaining volumes"
# The sweep runs after the destroy
[[ "$(seq_first "^ic is ")" -gt "$(seq_last "^tf destroy ")" ]] || { cat "${STUB_SEQ_LOG}"; fail "swept before terraform destroy"; }
! grep -q "^stdin-consumed" "${STUB_IC_LOG}" || { cat "${STUB_IC_LOG}"; fail "an ibmcloud delete call read the caller's stdin"; }

# A leftover that does not go away fails the task and is listed
setup
write_inventory full
echo "r010-vol-this-tag" > "${STUB_STUCK}"
run_teardown
expect_failure
REMAINING_SECTION=$(sed -n '/still present/,$p' <<< "${TASK_OUT}")
grep -q "r010-vol-this-tag" <<< "${REMAINING_SECTION}" || { echo "${TASK_OUT}"; fail "remaining volume not listed at the end"; }
! grep -q "r010-lb-this" <<< "${REMAINING_SECTION}" || { echo "${TASK_OUT}"; fail "deleted load balancer listed as remaining"; }

# A list that is not a JSON array (error text, no output, an object) is a
# failure, not "nothing left"
for BAD_LIST in "FAILED: not authorized" "" '{"volumes": []}'; do
  setup
  printf '%s' "${BAD_LIST}" > "${STUB_VOLS}"
  run_teardown
  expect_failure
  ! grep -q "volume-delete" "${STUB_IC_LOG}" || fail "volume deleted from an unreadable list"
  grep -q "listing failed" <<< "$(sed -n '/still present/,$p' <<< "${TASK_OUT}")" || { echo "${TASK_OUT}"; fail "failed listing not reported for '${BAD_LIST}'"; }
done

echo "✅ PASS: sweep_scoped_to_group_and_cluster"

# Test case: sweep_refused_outside_dedicated_group
echo ""
echo "Test: sweep_refused_outside_dedicated_group"
echo "--------------------------------------------"
setup
write_inventory full
export IBMCLOUD_RESOURCE_GROUP=Default
run_teardown
expect_success
[[ "$(destroy_count)" -eq 1 ]] || fail "terraform destroy not called"
! grep -q "^is " "${STUB_IC_LOG}" || { cat "${STUB_IC_LOG}"; fail "swept although the resource group is not redhat-sap-edge-roks-ci"; }
grep -q "redhat-sap-edge-roks-ci" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "refusal does not name the dedicated group"; }
grep -q "⚠️.*Default" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "refusal not warned about"; }
echo "✅ PASS: sweep_refused_outside_dedicated_group"

# Test case: no_sweep_without_cluster_id
echo ""
echo "Test: no_sweep_without_cluster_id"
echo "--------------------------------------------"
# Neither the state nor the outputs file has a cluster ID
setup
write_inventory full
STUB_TF_CLUSTER_ID=""
export STUB_TF_CLUSTER_ID
rm -f "${WS}/roks-terraform-outputs.json"
run_teardown
expect_success
! grep -q "^is " "${STUB_IC_LOG}" || { cat "${STUB_IC_LOG}"; fail "swept without a cluster ID"; }
grep -q "⚠️.*cluster ID" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "skipped sweep not warned about"; }
# The cluster ID is read before the destroy
[[ "$(seq_first "^tf output -raw cluster_id")" -lt "$(seq_first "^tf destroy ")" ]] || { cat "${STUB_SEQ_LOG}"; fail "cluster ID not read before destroy"; }

# The outputs file belongs to another cluster: ignored
setup
write_inventory full
STUB_TF_CLUSTER_ID=""
export STUB_TF_CLUSTER_ID
write_outputs_file redhat-roks-eic-pr8 "${OTHER_CID}"
run_teardown
expect_success
! grep -q "^is " "${STUB_IC_LOG}" || { cat "${STUB_IC_LOG}"; fail "swept with the cluster ID of another cluster's outputs file"; }

# An imprecise cluster ID is not used
setup
write_inventory full
STUB_TF_CLUSTER_ID="c7"
export STUB_TF_CLUSTER_ID
run_teardown
expect_success
! grep -q "^is " "${STUB_IC_LOG}" || { cat "${STUB_IC_LOG}"; fail "swept with an imprecise cluster ID"; }

# Fallback: no cluster_id output, but the outputs file of this cluster has it
setup
write_inventory full
STUB_TF_CLUSTER_ID=""
export STUB_TF_CLUSTER_ID
run_teardown
expect_success
grep -q "^is load-balancer-delete r010-lb-this " "${STUB_IC_LOG}" || { cat "${STUB_IC_LOG}"; fail "cluster ID from roks-terraform-outputs.json not used"; }

echo "✅ PASS: no_sweep_without_cluster_id"

# Test case: ibmcloud_logged_in_before_destroy
# The VPE cleanup destroy hook calls ibmcloud: log in (API key from the
# environment, never in argv) with region and resource group before destroy.
echo ""
echo "Test: ibmcloud_logged_in_before_destroy"
echo "--------------------------------------------"
setup
run_teardown
expect_success
grep -qxF "login -r eu-de -g redhat-sap-edge-roks-ci" "${STUB_IC_LOG}" || { cat "${STUB_IC_LOG}"; fail "ibmcloud login not called with region and resource group"; }
LOGIN=$(seq_first "^ic login ")
FIRST_DESTROY=$(seq_first "^tf destroy ")
[[ "${LOGIN}" -gt 0 && "${LOGIN}" -lt "${FIRST_DESTROY}" ]] || { cat "${STUB_SEQ_LOG}"; fail "ibmcloud login does not precede terraform destroy"; }
! grep -q -- "--apikey" "${STUB_IC_LOG}" || fail "API key passed on the ibmcloud command line"

# Without the API key the task stops before destroying anything
setup
export IBMCLOUD_API_KEY=""
run_teardown
expect_failure
[[ "$(destroy_count)" -eq 0 ]] || fail "terraform destroy called without an API key"

echo "✅ PASS: ibmcloud_logged_in_before_destroy"

# Test case: hub_artifacts_deleted
echo ""
echo "Test: hub_artifacts_deleted"
echo "--------------------------------------------"
setup
export HUB_KUBECONFIG_SECRET=eic-kubeconfig
run_teardown
expect_success
grep -qE "^get secret eic-kubeconfig -o jsonpath=" "${FAKE_OC_LOG}" || { cat "${FAKE_OC_LOG}"; fail "hub kubeconfig not extracted"; }
for SECRET_NAME in "eic-credentials-roks-${CLUSTER}" "eic-registry-roks-${CLUSTER}"; do
  assert_called "^--kubeconfig .*/hub-kubeconfig delete secret ${SECRET_NAME} --ignore-not-found=true$"
done
assert_not_called "^delete secret eic-"

# Unreadable hub kubeconfig: the cluster is still destroyed, the Secrets are
# reported as remaining
setup
export HUB_KUBECONFIG_SECRET=missing-hub-secret
run_teardown
expect_failure
[[ "$(destroy_count)" -eq 1 ]] || fail "terraform destroy skipped because of the hub kubeconfig"
REMAINING_SECTION=$(sed -n '/still present/,$p' <<< "${TASK_OUT}")
grep -q "eic-credentials-roks-${CLUSTER}" <<< "${REMAINING_SECTION}" || { echo "${TASK_OUT}"; fail "credentials Secret not reported"; }
grep -q "eic-registry-roks-${CLUSTER}" <<< "${REMAINING_SECTION}" || { echo "${TASK_OUT}"; fail "registry Secret not reported"; }
assert_not_called "delete secret eic-"
assert_called "^delete configmap cluster-info-roks-${CLUSTER} --ignore-not-found=true$"
assert_called "^delete secret edgelm-kubeconfig-generated-${CLUSTER} --ignore-not-found=true$"

echo "✅ PASS: hub_artifacts_deleted"

# Test case: configmap_deleted_in_cluster_when_hub_set
# roks-validate-and-create-configmap always writes the ConfigMap on the
# pipeline cluster (where the test pods run), even with a hub.
echo ""
echo "Test: configmap_deleted_in_cluster_when_hub_set"
echo "--------------------------------------------"
setup
export HUB_KUBECONFIG_SECRET=eic-kubeconfig
run_teardown
expect_success
assert_called "^delete configmap cluster-info-roks-${CLUSTER} --ignore-not-found=true$"
assert_not_called "^--kubeconfig .* delete configmap"

# Without a hub everything is deleted on the pipeline cluster
setup
run_teardown
expect_success
assert_called "^delete configmap cluster-info-roks-${CLUSTER} --ignore-not-found=true$"
assert_called "^delete secret eic-credentials-roks-${CLUSTER} --ignore-not-found=true$"
assert_called "^delete secret eic-registry-roks-${CLUSTER} --ignore-not-found=true$"
assert_not_called "^--kubeconfig"

echo "✅ PASS: configmap_deleted_in_cluster_when_hub_set"

# Test case: generated_kubeconfig_secret_deleted
# ossm3-generate-sa-based-kubeconfig stores the restricted kubeconfig as
# Secret edgelm-kubeconfig-generated-<cluster> on the pipeline cluster, also
# when a hub is set.
echo ""
echo "Test: generated_kubeconfig_secret_deleted"
echo "--------------------------------------------"
setup
export HUB_KUBECONFIG_SECRET=eic-kubeconfig
run_teardown
expect_success
assert_called "^delete secret edgelm-kubeconfig-generated-${CLUSTER} --ignore-not-found=true$"
assert_not_called "^--kubeconfig .* delete secret edgelm-kubeconfig-generated"
grep -q "edgelm-kubeconfig-generated-${CLUSTER} (pipeline cluster)" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "deleted Secret not reported"; }

setup
run_teardown
expect_success
assert_called "^delete secret edgelm-kubeconfig-generated-${CLUSTER} --ignore-not-found=true$"

# A failed delete is reported as remaining
setup
printf 'delete secret edgelm-kubeconfig-generated-*\t1\tError from server (Forbidden)\n' >> "${FAKE_OC_RULES}"
run_teardown
expect_failure
REMAINING_SECTION=$(sed -n '/still present/,$p' <<< "${TASK_OUT}")
grep -q "Secret edgelm-kubeconfig-generated-${CLUSTER} on the pipeline cluster" <<< "${REMAINING_SECTION}" || { echo "${TASK_OUT}"; fail "undeleted generated kubeconfig Secret not reported"; }

echo "✅ PASS: generated_kubeconfig_secret_deleted"

# Test case: tfvars_removed
# terraform.tfvars from roks-deploy may hold the PostgreSQL password.
echo ""
echo "Test: tfvars_removed"
echo "--------------------------------------------"
setup
run_teardown
expect_success
[[ ! -e "${WS}/roks/terraform/terraform.tfvars" ]] || fail "terraform.tfvars left in the workspace after success"

setup
printf 'fail\nfail\nfail\n' > "${STUB_TF_DESTROY_PLAN}"
run_teardown
expect_failure
[[ ! -e "${WS}/roks/terraform/terraform.tfvars" ]] || fail "terraform.tfvars left in the workspace after a failure"

# No tfvars at all (fresh workspace, e.g. a rerun) is fine
setup
rm -f "${WS}/roks/terraform/terraform.tfvars"
run_teardown
expect_success

echo "✅ PASS: tfvars_removed"

# Test case: no_secret_in_output
echo ""
echo "Test: no_secret_in_output"
echo "--------------------------------------------"
check_no_secrets() {
  local SECRET
  for SECRET in "${FAKE_API_KEY}" "${FAKE_HMAC_ACCESS}" "${FAKE_HMAC_SECRET}" "${FAKE_PG_PASSWORD}" \
    "${FAKE_REDIS_PASSWORD}" "${FAKE_ICR_API_KEY}"; do
    ! grep -qF -- "${SECRET}" <<< "${TASK_OUT}" || fail "secret '${SECRET}' printed in the task output ($1)"
    ! grep -qF -- "${SECRET}" "${STUB_TF_LOG}" || fail "secret '${SECRET}' passed as a terraform argument ($1)"
    ! grep -qF -- "${SECRET}" "${STUB_IC_LOG}" || fail "secret '${SECRET}' passed as an ibmcloud argument ($1)"
    ! grep -qF -- "${SECRET}" "${FAKE_OC_LOG}" || fail "secret '${SECRET}' passed as an oc argument ($1)"
  done
}
# Success with a hub and a sweep
setup
write_inventory full
export HUB_KUBECONFIG_SECRET=eic-kubeconfig
run_teardown
expect_success
check_no_secrets success
# Failure path (state list, recovery hints)
setup
printf 'fail-cluster-gone\nfail\nfail\n' > "${STUB_TF_DESTROY_PLAN}"
run_teardown
expect_failure
check_no_secrets failure
echo "✅ PASS: no_secret_in_output"

# Test case: invalid_cluster_name_fails
echo ""
echo "Test: invalid_cluster_name_fails"
echo "--------------------------------------------"
for NAME in "Redhat_ROKS" "roks-eic-pr7" "redhat-roks-eic-pr7-0123456789x" "redhat-roks-"; do
  setup
  export CLUSTER_NAME="${NAME}"
  run_teardown
  expect_failure
  [[ ! -s "${STUB_TF_LOG}" ]] || fail "terraform called despite the invalid cluster name '${NAME}'"
  [[ ! -s "${STUB_IC_LOG}" ]] || fail "ibmcloud called despite the invalid cluster name '${NAME}'"
  [[ ! -s "${FAKE_OC_LOG}" ]] || fail "oc called despite the invalid cluster name '${NAME}'"
  grep -q "redhat-" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "error for '${NAME}' does not explain the naming rule"; }
done
echo "✅ PASS: invalid_cluster_name_fails"

echo ""
echo "============================================"
echo "✅ All roks-teardown tests passed"
echo "============================================"
