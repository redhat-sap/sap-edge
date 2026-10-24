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

# Test case: accesses_instance
# datastoreType=redis instance=eic-2 → queries Redis in sap-eic-external-redis-eic-2, Postgres in sap-eic-external-postgres
echo ""
echo "Test: accesses_instance"
echo "--------------------------------------------"

FAKE_OC_LOG=$(tmp_file)
FAKE_OC_RULES=$(tmp_file)
WORKSPACE_DIR=$(tmp_dir)
RESULTS_DIR=$(tmp_dir)

# Set up fake oc rules (more specific rules first)
cat > "${FAKE_OC_RULES}" <<'EOF'
get secret c1-admin-kubeconfig -n clusters*	0	{"data":{"kubeconfig":"YWJjCg=="}}
get nodes*	0	node1
get secret edgedb-pguser-edgedb -n sap-eic-external-postgres -o jsonpath={.data.host}	0	cGctaG9zdA==
get secret edgedb-pguser-edgedb -n sap-eic-external-postgres -o jsonpath={.data.port}	0	NTQzMg==
get secret edgedb-pguser-edgedb -n sap-eic-external-postgres -o jsonpath={.data.dbname}	0	ZWRnZWRi
get secret edgedb-pguser-edgedb -n sap-eic-external-postgres -o jsonpath={.data.user}	0	ZWRnZWRi
get secret edgedb-pguser-edgedb -n sap-eic-external-postgres -o jsonpath={.data.password}	0	cGFzc3dvcmQ=
get secret edgedb-pguser-edgedb -n sap-eic-external-postgres*	0
get secret pgo-root-cacert -n sap-eic-external-postgres*	1
get RedisEnterpriseDatabase redb -n sap-eic-external-redis-eic-2 -o json	0	{"spec":{"databaseSecretName":"redb-secret"}}
get RedisEnterpriseDatabase redb -n sap-eic-external-redis-eic-2*	0
get secret redb-secret -n sap-eic-external-redis-eic-2 -o json	0	{"data":{"password":"cmVkaXNwYXNz","port":"NDQz","service_name":"cmVkYg=="}}
get pod rec-0 -n sap-eic-external-redis-eic-2*	1
exec -n sap-eic-external-redis-eic-2 rec-0*	1
delete secret eic-credentials-hcp-c1*	0	deleted
create secret generic eic-credentials-hcp-c1*	0	created
EOF

export FAKE_OC_LOG FAKE_OC_RULES

run_task ../../.tekton/tasks/hcp-get-all-accesses-task.yaml \
  --param hostedClusterName=c1 \
  --param hostedClusterNamespace=clusters \
  --param datastoreType=redis \
  --param instance=eic-2 \
  --workspace-dir source="${WORKSPACE_DIR}" \
  --results-dir "${RESULTS_DIR}" \
  --from 'echo "🔍 Verifying access to hosted cluster..."' \
  --to '# Switch back to hosted cluster' \
  --drop 'Install required packages' 'oc version --client'

# Debug: show output if failed
if [[ "${TASK_RC}" -ne 0 ]]; then
  echo "Task failed with output:"
  echo "${TASK_OUT}"
fi

assert_rc 0

# Verify Postgres was queried from sap-eic-external-postgres (shared, no instance suffix)
assert_called "get secret edgedb-pguser-edgedb -n sap-eic-external-postgres"

# Verify Redis was queried from sap-eic-external-redis-eic-2 (with instance suffix)
assert_called "get RedisEnterpriseDatabase redb -n sap-eic-external-redis-eic-2"
assert_called "get secret redb-secret -n sap-eic-external-redis-eic-2"

# Verify NOT called without instance suffix
assert_not_called "get RedisEnterpriseDatabase redb -n sap-eic-external-redis "

echo "✅ PASS: accesses_instance"

echo ""
echo "✅ ALL TESTS PASSED"
