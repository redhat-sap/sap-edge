#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=./lib.sh disable=SC1091
source lib.sh

echo "============================================"
echo "Test: Backing Service Instance Param"
echo "============================================"

# Test case: redis_defaults
# No instance param → deploys to sap-eic-external-redis
echo ""
echo "Test: redis_defaults"
echo "--------------------------------------------"

FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)
WORKSPACE_DIR=$(tmp_dir)
RESULTS_DIR=$(tmp_dir)

# Create stub deploy_redis.sh that logs its args
mkdir -p "${WORKSPACE_DIR}/edge-integration-cell"
cat > "${WORKSPACE_DIR}/edge-integration-cell/deploy_redis.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> deploy_args.log
EOF
chmod +x "${WORKSPACE_DIR}/edge-integration-cell/deploy_redis.sh"

DEPLOY_LOG="${WORKSPACE_DIR}/edge-integration-cell/deploy_args.log"

# Set up fake oc rules
cat > "${FAKE_OC_RULES}" <<'EOF'
get secret c1-admin-kubeconfig -n clusters*	0	{"data":{"kubeconfig":"YWJjCg=="}}
get nodes*	0	node1
get pods -n sap-eic-external-redis*	0	rec-0
get svc -n sap-eic-external-redis*	0	redb
get redisenterprisecluster -n sap-eic-external-redis*	1
get redisenterprisedatabase -n sap-eic-external-redis*	1
EOF

export FAKE_OC_LOG FAKE_OC_RULES

# shellcheck disable=SC2016
run_task ../../.tekton/tasks/hcp-deploy-redis-task.yaml \
  --param hostedClusterName=c1 \
  --param hostedClusterNamespace=clusters \
  --workspace-dir source="${WORKSPACE_DIR}" \
  --results-dir "${RESULTS_DIR}" \
  --from 'echo "🔍 Verifying access to hosted cluster..."' \
  --to 'oc get redisenterprisedatabase -n' \
  --drop '# Verify the deploy_redis.sh script exists' 'chmod +x "${DEPLOY_SCRIPT}"'

assert_rc 0

# Verify deploy_redis.sh was called with -n sap-eic-external-redis
if ! grep -qF -- "-n sap-eic-external-redis" "${DEPLOY_LOG}"; then
  echo "❌ FAIL: deploy_redis.sh should be called with -n sap-eic-external-redis"
  echo "Actual args:"
  cat "${DEPLOY_LOG}"
  exit 1
fi

# Verify redis-host result contains .sap-eic-external-redis.svc.cluster.local
REDIS_HOST=$(cat "${RESULTS_DIR}/redis-host")
if [[ "${REDIS_HOST}" != *".sap-eic-external-redis.svc.cluster.local" ]]; then
  echo "❌ FAIL: redis-host should end with .sap-eic-external-redis.svc.cluster.local"
  echo "Actual: ${REDIS_HOST}"
  exit 1
fi

echo "✅ PASS: redis_defaults"

# Test case: redis_instance
# instance=eic-2 → deploys to sap-eic-external-redis-eic-2
echo ""
echo "Test: redis_instance"
echo "--------------------------------------------"

FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)
WORKSPACE_DIR=$(tmp_dir)
RESULTS_DIR=$(tmp_dir)

# Create stub deploy_redis.sh
mkdir -p "${WORKSPACE_DIR}/edge-integration-cell"
cat > "${WORKSPACE_DIR}/edge-integration-cell/deploy_redis.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> deploy_args.log
EOF
chmod +x "${WORKSPACE_DIR}/edge-integration-cell/deploy_redis.sh"

DEPLOY_LOG="${WORKSPACE_DIR}/edge-integration-cell/deploy_args.log"

# Set up fake oc rules
cat > "${FAKE_OC_RULES}" <<'EOF'
get secret c1-admin-kubeconfig -n clusters*	0	{"data":{"kubeconfig":"YWJjCg=="}}
get nodes*	0	node1
get pods -n sap-eic-external-redis-eic-2*	0	rec-0
get svc -n sap-eic-external-redis-eic-2*	0	redb
get redisenterprisecluster -n sap-eic-external-redis-eic-2*	1
get redisenterprisedatabase -n sap-eic-external-redis-eic-2*	1
EOF

export FAKE_OC_LOG FAKE_OC_RULES

# shellcheck disable=SC2016
run_task ../../.tekton/tasks/hcp-deploy-redis-task.yaml \
  --param hostedClusterName=c1 \
  --param hostedClusterNamespace=clusters \
  --param instance=eic-2 \
  --workspace-dir source="${WORKSPACE_DIR}" \
  --results-dir "${RESULTS_DIR}" \
  --from 'echo "🔍 Verifying access to hosted cluster..."' \
  --to 'oc get redisenterprisedatabase -n' \
  --drop '# Verify the deploy_redis.sh script exists' 'chmod +x "${DEPLOY_SCRIPT}"'

assert_rc 0

# Verify deploy_redis.sh was called with -n sap-eic-external-redis-eic-2
if ! grep -qF -- "-n sap-eic-external-redis-eic-2" "${DEPLOY_LOG}"; then
  echo "❌ FAIL: deploy_redis.sh should be called with -n sap-eic-external-redis-eic-2"
  echo "Actual args:"
  cat "${DEPLOY_LOG}"
  exit 1
fi

# Verify redis-host result contains .sap-eic-external-redis-eic-2.svc.cluster.local
REDIS_HOST=$(cat "${RESULTS_DIR}/redis-host")
if [[ "${REDIS_HOST}" != *".sap-eic-external-redis-eic-2.svc.cluster.local" ]]; then
  echo "❌ FAIL: redis-host should end with .sap-eic-external-redis-eic-2.svc.cluster.local"
  echo "Actual: ${REDIS_HOST}"
  exit 1
fi

echo "✅ PASS: redis_instance"

# Test case: valkey_cluster_instance
# datastoreType=valkey-cluster instance=eic-1 → deploys to sap-eic-external-valkey-cluster-eic-1
echo ""
echo "Test: valkey_cluster_instance"
echo "--------------------------------------------"

FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)
WORKSPACE_DIR=$(tmp_dir)
RESULTS_DIR=$(tmp_dir)

# Create stub deploy_valkey.sh
mkdir -p "${WORKSPACE_DIR}/edge-integration-cell/external-valkey-cluster"
cat > "${WORKSPACE_DIR}/edge-integration-cell/external-valkey-cluster/deploy_valkey.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> deploy_args.log
EOF
chmod +x "${WORKSPACE_DIR}/edge-integration-cell/external-valkey-cluster/deploy_valkey.sh"

DEPLOY_LOG="${WORKSPACE_DIR}/edge-integration-cell/external-valkey-cluster/deploy_args.log"

# Set up fake oc rules
cat > "${FAKE_OC_RULES}" <<'EOF'
get secret c1-admin-kubeconfig -n clusters*	0	{"data":{"kubeconfig":"YWJjCg=="}}
get nodes*	0	node1
get pods -l name=valkey -n sap-eic-external-valkey-cluster-eic-1*	0	valkey-0\nvalkey-1\nvalkey-2
get pods -n sap-eic-external-valkey-cluster-eic-1*	0	valkey-0
get svc -n sap-eic-external-valkey-cluster-eic-1*	0	valkey-headless
get secrets -n sap-eic-external-valkey-cluster-eic-1*	0	valkey-tls
get configmaps -n sap-eic-external-valkey-cluster-eic-1*	0	valkey-config
EOF

export FAKE_OC_LOG FAKE_OC_RULES

# shellcheck disable=SC2016
run_task ../../.tekton/tasks/hcp-deploy-valkey-task.yaml \
  --param hostedClusterName=c1 \
  --param hostedClusterNamespace=clusters \
  --param datastoreType=valkey-cluster \
  --param instance=eic-1 \
  --workspace-dir source="${WORKSPACE_DIR}" \
  --results-dir "${RESULTS_DIR}" \
  --from 'echo "🔍 Verifying access to hosted cluster..."' \
  --to 'oc get configmaps -n' \
  --drop '# Verify the deploy_valkey.sh script exists' 'chmod +x "${DEPLOY_SCRIPT}"' \
  --drop '# Install required tools' 'helm version --client'

assert_rc 0

# Verify deploy_valkey.sh was called with -n sap-eic-external-valkey-cluster-eic-1
if ! grep -qF -- "-n sap-eic-external-valkey-cluster-eic-1" "${DEPLOY_LOG}"; then
  echo "❌ FAIL: deploy_valkey.sh should be called with -n sap-eic-external-valkey-cluster-eic-1"
  echo "Actual args:"
  cat "${DEPLOY_LOG}"
  exit 1
fi

# Verify valkey-host result contains .sap-eic-external-valkey-cluster-eic-1.svc.cluster.local
VALKEY_HOST=$(cat "${RESULTS_DIR}/valkey-host")
if [[ "${VALKEY_HOST}" != *".sap-eic-external-valkey-cluster-eic-1.svc.cluster.local"* ]]; then
  echo "❌ FAIL: valkey-host should contain .sap-eic-external-valkey-cluster-eic-1.svc.cluster.local"
  echo "Actual: ${VALKEY_HOST}"
  exit 1
fi

echo "✅ PASS: valkey_cluster_instance"

# ----------------------------------------------------------------------------
# hcp-get-all-accesses: per-instance credentials Secret and certificate files
# ----------------------------------------------------------------------------
# Fixtures are base64-encoded at runtime (keeps cspell quiet).
PG_ROOT_CA_B64=$(printf 'pg-root-ca' | base64)
REDIS_PASS_B64=$(printf 'redispass' | base64)
VALKEY_PASS_B64=$(printf 'valkeypass' | base64)

# Write the shared hosted-cluster + PostgreSQL rules to $1.
write_pg_rules() {
  cat > "$1" <<EOF
get secret c1-admin-kubeconfig -n clusters*	0	{"data":{"kubeconfig":"YWJjCg=="}}
get nodes*	0	node1
get secret edgedb-pguser-edgedb -n sap-eic-external-postgres -o jsonpath={.data.host}	0	cGctaG9zdA==
get secret edgedb-pguser-edgedb -n sap-eic-external-postgres -o jsonpath={.data.port}	0	NTQzMg==
get secret edgedb-pguser-edgedb -n sap-eic-external-postgres -o jsonpath={.data.dbname}	0	ZWRnZWRi
get secret edgedb-pguser-edgedb -n sap-eic-external-postgres -o jsonpath={.data.user}	0	ZWRnZWRi
get secret edgedb-pguser-edgedb -n sap-eic-external-postgres -o jsonpath={.data.password}	0	cGFzc3dvcmQ=
get secret edgedb-pguser-edgedb -n sap-eic-external-postgres*	0
get secret pgo-root-cacert -n sap-eic-external-postgres -o json	0	{"data":{"root.crt":"${PG_ROOT_CA_B64}"}}
get secret pgo-root-cacert -n sap-eic-external-postgres*	0
EOF
}

# Append the Redis rules for namespace $2 (cert content $3) to $1.
write_redis_rules() {
  cat >> "$1" <<EOF
get RedisEnterpriseDatabase redb -n $2 -o json	0	{"spec":{"databaseSecretName":"redb-secret"}}
get RedisEnterpriseDatabase redb -n $2*	0
get secret redb-secret -n $2 -o json	0	{"data":{"password":"${REDIS_PASS_B64}","port":"NDQz","service_name":"cmVkYg=="}}
get pod rec-0 -n $2*	0
exec -n $2 rec-0*	0	$3
EOF
}

# Append the Valkey (standalone) rules for namespace $2 (CA content $3) to $1.
write_valkey_rules() {
  cat >> "$1" <<EOF
get secret valkey -n $2 -o jsonpath=*	0	${VALKEY_PASS_B64}
get secret valkey -n $2*	0
get configmap valkey-service-ca -n $2 -o jsonpath=*	0	$3
get configmap valkey-service-ca -n $2*	0
EOF
}

# Run hcp-get-all-accesses up to the Secret creation in WORKSPACE_DIR.
# Usage: run_accesses EXTRA_TASK_ARGS...
run_accesses() {
  TASK_CWD="${WORKSPACE_DIR}" run_task ../../.tekton/tasks/hcp-get-all-accesses-task.yaml \
    --param hostedClusterName=c1 \
    --param hostedClusterNamespace=clusters \
    --workspace-dir source="${WORKSPACE_DIR}" \
    --results-dir "${RESULTS_DIR}" \
    --from 'echo "🔍 Verifying access to hosted cluster..."' \
    --to '# Switch back to hosted cluster' \
    --drop 'Install required packages' 'oc version --client' \
    "$@"
  if [[ "${TASK_RC}" -ne 0 ]]; then
    echo "Task failed with output:"
    echo "${TASK_OUT}"
  fi
}

# Fail unless FILE exists with exactly CONTENT.
assert_workspace_file() {
  local FILE="${WORKSPACE_DIR}/$1"
  [[ -f "${FILE}" ]] || fail "workspace file $1 not written"
  [[ "$(cat "${FILE}")" == "$2" ]] || fail "workspace file $1: expected '$2', got '$(cat "${FILE}")'"
}

# Test case: accesses_instance
# datastoreType=redis instance=eic-2 → Redis from sap-eic-external-redis-eic-2,
# shared Postgres; Secret eic-credentials-hcp-c1-eic-2 with instance-specific
# certificate files; the Edge Node's edgelm-kubeconfig (topology A) as kubeconfig.
echo ""
echo "Test: accesses_instance"
echo "--------------------------------------------"

FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)
WORKSPACE_DIR=$(tmp_dir)
RESULTS_DIR=$(tmp_dir)
echo "restricted-kubeconfig" > "${WORKSPACE_DIR}/edgelm-kubeconfig"

write_pg_rules "${FAKE_OC_RULES}"
write_redis_rules "${FAKE_OC_RULES}" sap-eic-external-redis-eic-2 "redis-cert-eic-2"
export FAKE_OC_LOG FAKE_OC_RULES

run_accesses --param datastoreType=redis --param instance=eic-2
assert_rc 0

# Postgres stays shared; Redis comes from the instance namespace
assert_called "get secret edgedb-pguser-edgedb -n sap-eic-external-postgres"
assert_called "get RedisEnterpriseDatabase redb -n sap-eic-external-redis-eic-2"
assert_called "get secret redb-secret -n sap-eic-external-redis-eic-2"
assert_not_called "get RedisEnterpriseDatabase redb -n sap-eic-external-redis "

# Per-instance Secret; the shared name is never touched
assert_called "^delete secret eic-credentials-hcp-c1-eic-2 "
assert_called "^create secret generic eic-credentials-hcp-c1-eic-2 "
assert_not_called "eic-credentials-hcp-c1( |$)"

# Per-instance certificate files, stored in the Secret
assert_workspace_file external_redis_tls_certificate_eic-2.pem "redis-cert-eic-2"
assert_workspace_file external_postgres_db_tls_root_cert_eic-2.crt "pg-root-ca"
[[ ! -e "${WORKSPACE_DIR}/external_redis_tls_certificate.pem" ]] || fail "shared Redis cert file written in instance mode"
[[ ! -e "${WORKSPACE_DIR}/external_postgres_db_tls_root_cert.crt" ]] || fail "shared Postgres cert file written in instance mode"
assert_called "redis-tls-cert=external_redis_tls_certificate_eic-2\.pem"
assert_called "postgres-tls-root-cert=external_postgres_db_tls_root_cert_eic-2\.crt"
assert_called "kubeconfig=edgelm-kubeconfig( |$)"

# Every retrieval hint names the per-instance Secret
grep -qF "oc get secret eic-credentials-hcp-c1-eic-2 -o jsonpath='{.data.redis-password}'" <<< "${TASK_OUT}" \
  || fail "retrieval hint does not name eic-credentials-hcp-c1-eic-2"
grep -qF "oc get secret eic-credentials-hcp-c1-eic-2 -o jsonpath='{.data.kubeconfig}'" <<< "${TASK_OUT}" \
  || fail "kubeconfig retrieval hint missing"
if grep -qE "eic-credentials-hcp-c1([^-]|$)" <<< "${TASK_OUT}"; then
  fail "output mentions the shared Secret eic-credentials-hcp-c1 in instance mode"
fi

echo "✅ PASS: accesses_instance"

# Test case: accesses_defaults
# No instance → unchanged Secret eic-credentials-hcp-c1 and unsuffixed files
echo ""
echo "Test: accesses_defaults"
echo "--------------------------------------------"

FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)
WORKSPACE_DIR=$(tmp_dir)
RESULTS_DIR=$(tmp_dir)
echo "restricted-kubeconfig" > "${WORKSPACE_DIR}/edgelm-kubeconfig"

write_pg_rules "${FAKE_OC_RULES}"
write_redis_rules "${FAKE_OC_RULES}" sap-eic-external-redis "redis-cert"
export FAKE_OC_LOG FAKE_OC_RULES

run_accesses --param datastoreType=redis
assert_rc 0

assert_called "get RedisEnterpriseDatabase redb -n sap-eic-external-redis "
assert_called "^delete secret eic-credentials-hcp-c1 "
assert_called "^create secret generic eic-credentials-hcp-c1 "
assert_not_called "eic-credentials-hcp-c1-"
assert_workspace_file external_redis_tls_certificate.pem "redis-cert"
assert_workspace_file external_postgres_db_tls_root_cert.crt "pg-root-ca"
assert_called "redis-tls-cert=external_redis_tls_certificate\.pem"
assert_called "postgres-tls-root-cert=external_postgres_db_tls_root_cert\.crt"
assert_called "kubeconfig=edgelm-kubeconfig( |$)"
grep -qF "oc get secret eic-credentials-hcp-c1 -o jsonpath='{.data.redis-password}'" <<< "${TASK_OUT}" \
  || fail "retrieval hint does not name eic-credentials-hcp-c1"

echo "✅ PASS: accesses_defaults"

# Test case: accesses_two_cells_no_collision (topology B)
# eic-1 and eic-2 into one workspace (as the parallel cell1-/cell2- tasks do):
# each Secret gets its own certificate file and its own Edge Node kubeconfig.
echo ""
echo "Test: accesses_two_cells_no_collision"
echo "--------------------------------------------"

FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)
WORKSPACE_DIR=$(tmp_dir)
RESULTS_DIR=$(tmp_dir)
echo "kubeconfig-edge-node-1" > "${WORKSPACE_DIR}/edgelm-1-kubeconfig"
echo "kubeconfig-edge-node-2" > "${WORKSPACE_DIR}/edgelm-2-kubeconfig"

write_pg_rules "${FAKE_OC_RULES}"
write_valkey_rules "${FAKE_OC_RULES}" sap-eic-external-valkey-eic-1 "valkey-ca-eic-1"
write_valkey_rules "${FAKE_OC_RULES}" sap-eic-external-valkey-eic-2 "valkey-ca-eic-2"
export FAKE_OC_LOG FAKE_OC_RULES

run_accesses --param datastoreType=valkey-standalone --param instance=eic-1 \
  --param elmKubeconfigFile=edgelm-1-kubeconfig
assert_rc 0
grep -qF "oc get secret eic-credentials-hcp-c1-eic-1 -o jsonpath='{.data.valkey-password}'" <<< "${TASK_OUT}" \
  || fail "valkey retrieval hint does not name eic-credentials-hcp-c1-eic-1"

run_accesses --param datastoreType=valkey-standalone --param instance=eic-2 \
  --param elmKubeconfigFile=edgelm-2-kubeconfig
assert_rc 0

assert_workspace_file external_valkey_tls_certificate_eic-1.pem "valkey-ca-eic-1"
assert_workspace_file external_valkey_tls_certificate_eic-2.pem "valkey-ca-eic-2"
[[ ! -e "${WORKSPACE_DIR}/external_valkey_tls_certificate.pem" ]] || fail "shared Valkey cert file written in instance mode"

CREATE_1=$(grep "^create secret generic eic-credentials-hcp-c1-eic-1 " "${FAKE_OC_LOG}") \
  || fail "Secret eic-credentials-hcp-c1-eic-1 not created"
CREATE_2=$(grep "^create secret generic eic-credentials-hcp-c1-eic-2 " "${FAKE_OC_LOG}") \
  || fail "Secret eic-credentials-hcp-c1-eic-2 not created"
[[ "${CREATE_1}" == *"valkey-tls-cert=external_valkey_tls_certificate_eic-1.pem"* ]] || fail "eic-1 Secret: wrong Valkey cert file"
[[ "${CREATE_1}" == *"kubeconfig=edgelm-1-kubeconfig"* ]] || fail "eic-1 Secret: wrong kubeconfig file"
[[ "${CREATE_1}" == *"valkey-address=valkey.sap-eic-external-valkey-eic-1.svc"* ]] || fail "eic-1 Secret: wrong Valkey address"
[[ "${CREATE_2}" == *"valkey-tls-cert=external_valkey_tls_certificate_eic-2.pem"* ]] || fail "eic-2 Secret: wrong Valkey cert file"
[[ "${CREATE_2}" == *"kubeconfig=edgelm-2-kubeconfig"* ]] || fail "eic-2 Secret: wrong kubeconfig file"
[[ "${CREATE_2}" == *"valkey-address=valkey.sap-eic-external-valkey-eic-2.svc"* ]] || fail "eic-2 Secret: wrong Valkey address"
assert_not_called "eic-credentials-hcp-c1( |$)"

echo "✅ PASS: accesses_two_cells_no_collision"

# Test case: accesses_missing_kubeconfig
# elmKubeconfigFile not in the workspace → no kubeconfig key, logged, no hint
echo ""
echo "Test: accesses_missing_kubeconfig"
echo "--------------------------------------------"

FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)
WORKSPACE_DIR=$(tmp_dir)
RESULTS_DIR=$(tmp_dir)

write_pg_rules "${FAKE_OC_RULES}"
write_redis_rules "${FAKE_OC_RULES}" sap-eic-external-redis-eic-1 "redis-cert-eic-1"
export FAKE_OC_LOG FAKE_OC_RULES

run_accesses --param datastoreType=redis --param instance=eic-1 \
  --param elmKubeconfigFile=edgelm-1-kubeconfig
assert_rc 0

assert_called "^create secret generic eic-credentials-hcp-c1-eic-1 "
assert_not_called "kubeconfig="
grep -qF "No workspace file 'edgelm-1-kubeconfig': Secret 'eic-credentials-hcp-c1-eic-1' gets no kubeconfig key" <<< "${TASK_OUT}" \
  || fail "missing kubeconfig is not logged"
if grep -qF "{.data.kubeconfig}" <<< "${TASK_OUT}"; then
  fail "kubeconfig retrieval hint printed although the Secret has no kubeconfig key"
fi

echo "✅ PASS: accesses_missing_kubeconfig"

echo ""
echo "✅ ALL TESTS PASSED"
