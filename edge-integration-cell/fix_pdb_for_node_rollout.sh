#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

PG_NAMESPACE="sap-eic-external-postgres"
PG_CLUSTER="edgedb"
REDIS_NAMESPACE="sap-eic-external-redis"
REDIS_CLUSTER="rec"
DRY_RUN=false
STATUS_ONLY=false
RECOVER_REDIS=false
RECOVERY_TIMEOUT=600
MACHINE_CONFIG_POOL="worker"
WATCH_INTERVAL=0
PG_RESOURCE="postgresclusters.postgres-operator.crunchydata.com"
REDIS_RESOURCE="redisenterpriseclusters.app.redislabs.com"

usage() {
    cat <<'EOF'
Usage: bash edge-integration-cell/fix_pdb_for_node_rollout.sh [OPTIONS]

Allow voluntary disruptions of the PostgreSQL and Redis clusters deployed by
the HCP Tekton tasks. Changes are left in place; nothing is restored on exit.
This can interrupt both services, including all replicas of an HA deployment.

Options:
  --postgres-namespace NAME  Default: sap-eic-external-postgres
  --postgres-cluster NAME    Default: edgedb
  --redis-namespace NAME     Default: sap-eic-external-redis
  --redis-cluster NAME       Default: rec
  --dry-run                 Preview and validate patches without changing resources
  --status                  Read PDB and Redis shutdown status without changing resources
  --recover-disposable-redis Recover a single-node test Redis AFTER the worker rollout;
                            databases in recovery are restarted EMPTY (Redis only)
  --machine-config-pool NAME Pool to check before recovery (default: worker)
  --recovery-timeout SECONDS Maximum recovery wait (default: 600)
  --watch SECONDS           Recheck/reapply every N seconds until Ctrl-C
  -h, --help                Show this help

Requires jq and oc (or kubectl). Uses the current context and KUBECONFIG.
Run against the cluster hosting the database pods, not the HCP management cluster.
Only PDBs owned directly by the two selected custom resources are patched.
Crunchy instance/PgBouncer minAvailable settings are also set to 0 so its
operator removes those PDBs. Redis may reconcile its PDB; use --watch during
the rollout if necessary. Stopping --watch does not restore any settings.
Exit code 2 means a selected Redis pod has been terminating for at least five
minutes. Inspect its shutdown hook and data persistence before attempting recovery.
PDB/status modes do not stop Redis pods or shorten their shutdown grace period.

Recovery mode requires Python 3 and a completed OpenShift MachineConfigPool rollout.
It uses the Redis operator's clusterRecovery procedure and retained cluster
configuration on the PVC. It never resets a healthy database, changes PostgreSQL,
or deletes PVCs. Use --dry-run to inspect the recovery plan without changing Redis.
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --postgres-namespace|--postgres-cluster|--redis-namespace|--redis-cluster|--watch|--machine-config-pool|--recovery-timeout)
            [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "Missing value for $1"
            case "$1" in
                --postgres-namespace) PG_NAMESPACE="$2" ;;
                --postgres-cluster) PG_CLUSTER="$2" ;;
                --redis-namespace) REDIS_NAMESPACE="$2" ;;
                --redis-cluster) REDIS_CLUSTER="$2" ;;
                --machine-config-pool) MACHINE_CONFIG_POOL="$2" ;;
                --recovery-timeout)
                    [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "--recovery-timeout must be a positive integer"
                    RECOVERY_TIMEOUT="$2"
                    ;;
                --watch)
                    [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "--watch must be a positive integer"
                    WATCH_INTERVAL="$2"
                    ;;
            esac
            shift 2
            ;;
        --dry-run) DRY_RUN=true; shift ;;
        --status) STATUS_ONLY=true; shift ;;
        --recover-disposable-redis) RECOVER_REDIS=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1 (see --help)" ;;
    esac
done
[[ "$DRY_RUN" == false || "$WATCH_INTERVAL" == 0 ]] || die "Use --dry-run without --watch"
[[ "$STATUS_ONLY" == false || ( "$DRY_RUN" == false && "$WATCH_INTERVAL" == 0 ) ]] \
    || die "Use --status without --dry-run or --watch"
[[ "$RECOVER_REDIS" == false || ( "$STATUS_ONLY" == false && "$WATCH_INTERVAL" == 0 ) ]] \
    || die "Use --recover-disposable-redis without --status or --watch"

command -v jq >/dev/null || die "Install jq first"
if command -v oc >/dev/null; then
    CLI=(oc)
elif command -v kubectl >/dev/null; then
    CLI=(kubectl)
else
    die "Install oc or kubectl first"
fi
# Pin the context so changing the user's current context cannot redirect a watch.
CONTEXT=$("${CLI[@]}" config current-context)
CLI+=(--context "$CONTEXT" --request-timeout=30s)
echo "Context: $CONTEXT"
if [[ "$RECOVER_REDIS" == true ]]; then
    command -v python3 >/dev/null || die "Install Python 3 for Redis recovery"
    recovery_args=(--cli "${CLI[0]}" --context "$CONTEXT" --namespace "$REDIS_NAMESPACE"
        --cluster "$REDIS_CLUSTER" --machine-config-pool "$MACHINE_CONFIG_POOL" --timeout "$RECOVERY_TIMEOUT")
    if [[ "$DRY_RUN" == true ]]; then recovery_args+=(--dry-run); fi
    exec python3 "$(dirname "${BASH_SOURCE[0]}")/recover_disposable_redis.py" "${recovery_args[@]}"
fi
echo "PostgreSQL: $PG_NAMESPACE/$PG_CLUSTER; Redis: $REDIS_NAMESPACE/$REDIS_CLUSTER"
if [[ "$STATUS_ONLY" == true ]]; then
    echo "Status only: no resources will be changed."
else
    echo "WARNING: Removing disruption protection permits service downtime. No restore is performed."
fi

# Read both owners and namespace inventories before making any changes. In
# particular, a typo or access error on the second namespace must not be hidden.
PG_JSON=$("${CLI[@]}" get "$PG_RESOURCE" "$PG_CLUSTER" -n "$PG_NAMESPACE" -o json)
REDIS_JSON=$("${CLI[@]}" get "$REDIS_RESOURCE" "$REDIS_CLUSTER" -n "$REDIS_NAMESPACE" -o json)
PG_UID=$(jq -er '.metadata.uid' <<< "$PG_JSON")
REDIS_UID=$(jq -er '.metadata.uid' <<< "$REDIS_JSON")
"${CLI[@]}" get pdb -n "$PG_NAMESPACE" -o json >/dev/null
"${CLI[@]}" get pdb -n "$REDIS_NAMESPACE" -o json >/dev/null

configure_postgres() {
    local current patch preview
    current=$("${CLI[@]}" get "$PG_RESOURCE" "$PG_CLUSTER" -n "$PG_NAMESPACE" -o json)
    [[ $(jq -r '.metadata.uid' <<< "$current") == "$PG_UID" ]] || die "PostgresCluster was replaced; rerun the script"
    jq -e '(.spec.instances | length) > 0' <<< "$current" >/dev/null || die "PostgresCluster has no instance sets"
    # JSON Patch changes only the budget fields, preserving users, storage,
    # replicas and all other instance settings. Tests guard concurrent edits.
    patch=$(jq -c '
        [.spec.instances | to_entries[]
         | select(.value.minAvailable != 0)
         | {op: "add", path: ("/spec/instances/" + (.key | tostring) + "/minAvailable"), value: 0}]
        + (if .spec.proxy.pgBouncer != null and .spec.proxy.pgBouncer.minAvailable != 0
           then [{op: "add", path: "/spec/proxy/pgBouncer/minAvailable", value: 0}]
           else [] end)
    ' <<< "$current")
    if [[ "$patch" == '[]' ]]; then
        echo "PostgreSQL instance/PgBouncer disruption budgets are already disabled."
        return
    fi
    patch=$(jq -c --argjson changes "$patch" '
        [{op: "test", path: "/metadata/uid", value: .metadata.uid},
         {op: "test", path: "/metadata/resourceVersion", value: .metadata.resourceVersion}] + $changes
    ' <<< "$current")

    # Detect older CRDs which reject or silently prune minAvailable before
    # persisting anything. Do not pretend an unsupported field is durable.
    preview=$("${CLI[@]}" patch "$PG_RESOURCE" "$PG_CLUSTER" -n "$PG_NAMESPACE" \
        --type=json -p "$patch" --dry-run=server -o json)
    jq -e 'all(.spec.instances[]; .minAvailable == 0)
        and (.spec.proxy.pgBouncer == null or .spec.proxy.pgBouncer.minAvailable == 0)' \
        <<< "$preview" >/dev/null || die "Installed Crunchy CRD does not retain minAvailable=0; check its operator version"
    echo "Set PostgreSQL instance and PgBouncer minAvailable to 0."
    if [[ "$DRY_RUN" == true ]]; then
        echo "$patch"
    else
        "${CLI[@]}" patch "$PG_RESOURCE" "$PG_CLUSTER" -n "$PG_NAMESPACE" --type=json -p "$patch"
    fi
}

relax_pdbs() {
    local namespace="$1" owner_uid="$2" inventory targets item name patch remaining
    inventory=$("${CLI[@]}" get pdb -n "$namespace" -o json)
    targets=$(jq -c --arg uid "$owner_uid" '
        .items[] | select(any(.metadata.ownerReferences[]?; .uid == $uid))
    ' <<< "$inventory")
    if [[ -z "$targets" ]]; then
        echo "No PDBs directly owned by the selected cluster in $namespace."
        return
    fi
    while IFS= read -r item; do
        name=$(jq -r '.metadata.name' <<< "$item")
        if jq -e '.spec.minAvailable == 0 and (.spec | has("maxUnavailable") | not)' \
            <<< "$item" >/dev/null; then
            echo "$namespace/$name already has minAvailable=0."
            continue
        fi
        patch=$(jq -c '
            [{op: "test", path: "/metadata/uid", value: .metadata.uid},
             {op: "test", path: "/metadata/resourceVersion", value: .metadata.resourceVersion}]
            + (if .spec | has("maxUnavailable")
               then [{op: "remove", path: "/spec/maxUnavailable"}] else [] end)
            + [{op: "add", path: "/spec/minAvailable", value: 0}]
        ' <<< "$item")
        echo "Set $namespace/$name minAvailable=0 (remove maxUnavailable if present)."
        if [[ "$DRY_RUN" == true ]]; then
            "${CLI[@]}" patch pdb "$name" -n "$namespace" --type=json -p "$patch" --dry-run=server
        else
            # Crunchy can remove a PDB between the list and patch. Treat only
            # confirmed deletion as success; RBAC/conflict errors remain errors.
            if ! "${CLI[@]}" patch pdb "$name" -n "$namespace" --type=json -p "$patch"; then
                remaining=$("${CLI[@]}" get pdb "$name" -n "$namespace" --ignore-not-found -o name) \
                    || die "Could not verify deletion of $namespace/$name after patch failure"
                [[ -z "$remaining" ]] || die "Patch failed for $namespace/$name; inspect the error and rerun"
            fi
        fi
    done <<< "$targets"
}

show_status() {
    echo "PDB status (includes other PDBs in these namespaces; status updates are asynchronous):"
    "${CLI[@]}" get pdb -n "$PG_NAMESPACE"
    "${CLI[@]}" get pdb -n "$REDIS_NAMESPACE"
}

check_redis_shutdown() {
    local controllers pods terminating
    # Redis pods belong to a StatefulSet, not directly to the REC. Follow both
    # owner UIDs so a different Redis cluster in the same namespace is excluded.
    controllers=$("${CLI[@]}" get statefulsets -n "$REDIS_NAMESPACE" -o json)
    controllers=$(jq -c --arg uid "$REDIS_UID" '
        [.items[] | select(any(.metadata.ownerReferences[]?; .uid == $uid)) | .metadata.uid]
    ' <<< "$controllers")
    pods=$("${CLI[@]}" get pods -n "$REDIS_NAMESPACE" -o json)
    terminating=$(jq -c --argjson controllers "$controllers" '
        [.items[]
         | select(any(.metadata.ownerReferences[]?; .uid as $uid | $controllers | index($uid)))
         | select(.metadata.deletionTimestamp != null)
         | (.metadata.deletionGracePeriodSeconds // .spec.terminationGracePeriodSeconds // 30) as $grace
         | (try (.metadata.deletionTimestamp | fromdateiso8601) catch null) as $deadline
         | {name: .metadata.name, node: .spec.nodeName, graceSeconds: $grace,
            terminatingSeconds: (if $deadline == null then null
                else ([0, now - ($deadline - $grace)] | max | floor) end)}]
    ' <<< "$pods")
    if [[ "$terminating" == '[]' ]]; then
        return
    fi
    echo "Redis pods already terminating in $REDIS_NAMESPACE:"
    echo "POD NODE GRACE_SECONDS TERMINATING_SECONDS"
    jq -r '.[] | [.name, .node, .graceSeconds, (.terminatingSeconds // "unknown")] | @tsv' <<< "$terminating"
    echo "Eviction/deletion has already started. PDB changes do not finish a container shutdown."
    if jq -e 'any(.[]; .terminatingSeconds == null or .terminatingSeconds >= 300)' <<< "$terminating" >/dev/null; then
        echo "ERROR: Redis shutdown needs investigation; stopping before further PDB changes." >&2
        echo "Inspect the Redis preStop hook, finalizers, and effective database persistence." >&2
        echo "A PVC alone does not mean Redis data persistence is enabled. Do not force deletion without checking." >&2
        echo "Redis preStop log: /var/opt/redislabs/log/prestop_exec_action.log (container redis-enterprise-node)." >&2
        echo "The REC field spec.redisEnterpriseTerminationGracePeriodSeconds controls future pods;" >&2
        echo "changing it does not shorten a deletion that is already in progress." >&2
        return 2
    fi
}

trap 'echo "Stopped. Changes remain in place; no PDB settings were restored."; exit 130' INT
trap 'echo "Stopped. Changes remain in place; no PDB settings were restored."; exit 143' TERM

while true; do
    # Refuse to follow a deleted/recreated Redis cluster during a watch.
    current_redis_uid=$("${CLI[@]}" get "$REDIS_RESOURCE" "$REDIS_CLUSTER" -n "$REDIS_NAMESPACE" -o jsonpath='{.metadata.uid}')
    [[ "$current_redis_uid" == "$REDIS_UID" ]] || die "RedisEnterpriseCluster was replaced; rerun the script"
    if [[ "$STATUS_ONLY" == true ]]; then
        show_status
        check_redis_shutdown
        exit 0
    fi
    check_redis_shutdown
    configure_postgres
    relax_pdbs "$PG_NAMESPACE" "$PG_UID"
    relax_pdbs "$REDIS_NAMESPACE" "$REDIS_UID"
    show_status
    [[ "$WATCH_INTERVAL" != 0 ]] || break
    echo "Rechecking in ${WATCH_INTERVAL}s. Ctrl-C stops watching without restoring settings."
    sleep "$WATCH_INTERVAL"
done

if [[ "$DRY_RUN" == true ]]; then
    echo "Dry run complete. No resources changed."
else
    echo "Updates submitted. Watch node rollout progress and PDB ALLOWED DISRUPTIONS."
    echo "Redis's operator or GitOps may revert patches later; --watch 5 reapplies them during the rollout."
fi
