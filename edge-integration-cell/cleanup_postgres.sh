#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# Default values
NAMESPACE="sap-eic-external-postgres"
INSTANCE=""             # optional EIC instance name (multiple EIC systems on one cluster)
PG_CLUSTER_NAME="edgedb"
DROP_DATA=false         # instance mode: also DROP the database+role (destroys data)
DRY_RUN=false
FORCE=false
VERBOSE=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    local level="$1"
    shift
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case "$level" in
        INFO)
            echo -e "${BLUE}[INFO]${NC} [${timestamp}] $*"
            ;;
        SUCCESS)
            echo -e "${GREEN}[SUCCESS]${NC} [${timestamp}] $*"
            ;;
        WARNING)
            echo -e "${YELLOW}[WARNING]${NC} [${timestamp}] $*"
            ;;
        ERROR)
            echo -e "${RED}[ERROR]${NC} [${timestamp}] $*"
            ;;
        *)
            echo "[${timestamp}] $*"
            ;;
    esac
}

# Usage function
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Cleanup PostgreSQL external services deployed via Crunchy Data Operator.

OPTIONS:
    -n, --namespace NAMESPACE    Namespace to cleanup (default: sap-eic-external-postgres)
    -i, --instance NAME          EIC instance name. Detaches ONLY the instance's isolated
                                 user "edgedb-<name>" from the shared PostgresCluster (removes
                                 its connection Secret); the cluster, operator and namespace
                                 are left intact. By default the database/role (and its data)
                                 are RETAINED (see --drop-data).
    --drop-data                  With --instance, also DROP the database and role after
                                 detaching, permanently destroying that instance's data.
    -f, --force                  Skip confirmation prompts (for automation)
    -d, --dry-run               Show what would be deleted without actually deleting
    -v, --verbose               Enable verbose output
    -h, --help                  Display this help message

EXAMPLES:
    # Interactive cleanup with confirmation
    $0

    # Force cleanup without prompts (CI/CD)
    $0 --force

    # Dry-run to see what would be deleted
    $0 --dry-run

    # Cleanup custom namespace
    $0 --namespace my-postgres-namespace

EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -i|--instance)
            INSTANCE="$2"
            shift 2
            ;;
        --drop-data)
            DROP_DATA=true
            shift
            ;;
        -f|--force)
            FORCE=true
            shift
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log ERROR "Unknown option: $1"
            usage
            ;;
    esac
done

# Verbose mode
if [[ "$VERBOSE" == "true" ]]; then
    set -x
fi

# Check if oc is available
if ! command -v oc &> /dev/null; then
    log ERROR "oc command not found. Please install OpenShift CLI."
    exit 1
fi

# Check if namespace exists
if ! oc get namespace "$NAMESPACE" &> /dev/null; then
    log WARNING "Namespace '$NAMESPACE' does not exist. Nothing to cleanup."
    exit 0
fi

# Instance cleanup: detach only this EIC instance's user from the shared cluster.
# The cluster, operator and namespace are intentionally left untouched so other EIC
# systems keep running. The database/role are retained unless --drop-data is given.
if [[ -n "$INSTANCE" ]]; then
    PG_USER="${PG_CLUSTER_NAME}-${INSTANCE}"
    if ! oc get postgrescluster "$PG_CLUSTER_NAME" -n "$NAMESPACE" &> /dev/null; then
        log WARNING "Shared PostgresCluster '$PG_CLUSTER_NAME' not found in '$NAMESPACE'. Nothing to cleanup."
        exit 0
    fi
    IDX=$(oc get postgrescluster "$PG_CLUSTER_NAME" -n "$NAMESPACE" -o json \
        | jq --arg u "$PG_USER" '.spec.users | map(.name) | index($u)')
    if [[ -z "$IDX" || "$IDX" == "null" ]]; then
        log WARNING "Database/user '$PG_USER' not present on cluster '$PG_CLUSTER_NAME'. Nothing to detach."
        # Even if detached already, honour --drop-data to clean up leftover data.
        if [[ "$DROP_DATA" != "true" ]]; then
            exit 0
        fi
        IDX=""
    fi

    if [[ "$FORCE" != "true" && "$DRY_RUN" != "true" ]]; then
        log WARNING "This will detach user '$PG_USER' from shared cluster '$PG_CLUSTER_NAME'."
        if [[ "$DROP_DATA" == "true" ]]; then
            log WARNING "--drop-data: the database and role '$PG_USER' will be DROPPED and its data destroyed."
        else
            log WARNING "The database/role '$PG_USER' and its data will be RETAINED (pass --drop-data to remove them)."
        fi
        read -rp "Are you sure you want to continue? (yes/no): " confirmation
        if [[ "$confirmation" != "yes" ]]; then
            log INFO "Cleanup cancelled by user."
            exit 0
        fi
    fi

    # 1) Detach the user from the cluster spec first, so the operator stops managing
    #    (and will not recreate) the database/role if we go on to drop it.
    if [[ -n "$IDX" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log INFO "[DRY-RUN] Would remove users[$IDX] ('$PG_USER') from PostgresCluster '$PG_CLUSTER_NAME'."
        else
            log INFO "Detaching user '$PG_USER' from shared cluster '$PG_CLUSTER_NAME'..."
            oc patch postgrescluster "$PG_CLUSTER_NAME" -n "$NAMESPACE" --type=json \
                -p "[{\"op\":\"remove\",\"path\":\"/spec/users/${IDX}\"}]"
            log SUCCESS "User '$PG_USER' detached (its connection Secret will be removed)."
        fi
    fi

    # 2) Optionally drop the database + role. Crunchy PGO intentionally does NOT drop
    #    them when a user leaves spec.users (to avoid data loss), so an instance
    #    teardown would otherwise leave orphaned tenant data on the shared cluster.
    if [[ "$DROP_DATA" != "true" ]]; then
        log INFO "Database/role '$PG_USER' retained. Re-run with --drop-data to remove them."
        exit 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log INFO "[DRY-RUN] Would drop database \"$PG_USER\" and role \"$PG_USER\" on the primary."
        exit 0
    fi

    PRIMARY_POD=$(oc get pods -n "$NAMESPACE" \
        -l "postgres-operator.crunchydata.com/cluster=${PG_CLUSTER_NAME},postgres-operator.crunchydata.com/role=master" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -z "$PRIMARY_POD" ]]; then
        log WARNING "Could not find the primary Postgres pod; database and role '$PG_USER' were NOT dropped."
        log WARNING "Drop them manually once the primary is reachable:"
        log WARNING "  psql -c 'DROP DATABASE IF EXISTS \"$PG_USER\" WITH (FORCE);'"
        log WARNING "  psql -c 'DROP ROLE IF EXISTS \"$PG_USER\";'"
        exit 0
    fi

    log INFO "Dropping database '$PG_USER' on primary pod $PRIMARY_POD..."
    if oc exec -n "$NAMESPACE" "$PRIMARY_POD" -c database -- \
        psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
        -c "DROP DATABASE IF EXISTS \"$PG_USER\" WITH (FORCE);"; then
        log SUCCESS "Database '$PG_USER' dropped."
    else
        log WARNING "Failed to drop database '$PG_USER'; drop it manually."
    fi

    log INFO "Dropping role '$PG_USER'..."
    if oc exec -n "$NAMESPACE" "$PRIMARY_POD" -c database -- \
        psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
        -c "DROP ROLE IF EXISTS \"$PG_USER\";"; then
        log SUCCESS "Role '$PG_USER' dropped."
    else
        log WARNING "Failed to drop role '$PG_USER' (it may own objects); drop it manually."
    fi

    log SUCCESS "EIC instance '$INSTANCE' PostgreSQL cleanup complete."
    exit 0
fi

# Confirmation prompt
if [[ "$FORCE" != "true" && "$DRY_RUN" != "true" ]]; then
    log WARNING "This will delete all PostgreSQL resources in namespace: $NAMESPACE"
    echo -e "${YELLOW}Resources to be deleted:${NC}"
    echo "  - PostgresCluster CRs"
    echo "  - Crunchy Postgres Operator subscription"
    echo "  - Crunchy Postgres Operator CSV"
    echo "  - Namespace: $NAMESPACE"
    echo ""
    read -rp "Are you sure you want to continue? (yes/no): " confirmation
    if [[ "$confirmation" != "yes" ]]; then
        log INFO "Cleanup cancelled by user."
        exit 0
    fi
fi

# Dry-run header
if [[ "$DRY_RUN" == "true" ]]; then
    log INFO "=== DRY-RUN MODE: No resources will be deleted ==="
fi

# Function to execute command
execute() {
    local cmd="$*"
    if [[ "$DRY_RUN" == "true" ]]; then
        log INFO "[DRY-RUN] Would execute: $cmd"
    else
        log INFO "Executing: $cmd"
        eval "$cmd"
    fi
}

# Function to wait for resource deletion
wait_for_resource_deletion() {
    local resource_type="$1"
    local namespace="$2"
    local timeout="${3:-600}"  # Default 10 minutes
    local check_interval=5
    local elapsed=0
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log INFO "[DRY-RUN] Would wait for $resource_type deletion in namespace $namespace"
        return 0
    fi
    
    log INFO "Waiting for $resource_type deletion (timeout: ${timeout}s)..."
    
    while [[ $elapsed -lt $timeout ]]; do
        local count
        count=$(oc get "$resource_type" -n "$namespace" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        
        if [[ "$count" == "0" ]]; then
            log SUCCESS "$resource_type resources deleted successfully"
            return 0
        fi
        
        log INFO "Still waiting... ($elapsed/${timeout}s elapsed, $count resource(s) remaining)"
        sleep $check_interval
        ((elapsed += check_interval))
    done
    
    log ERROR "Timeout waiting for $resource_type deletion after ${timeout}s"
    return 1
}

# Function to wait for namespace deletion with finalizer handling
wait_for_namespace_deletion() {
    local namespace="$1"
    local timeout="${2:-600}"  # Default 10 minutes
    local check_interval=5
    local elapsed=0
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log INFO "[DRY-RUN] Would wait for namespace $namespace deletion"
        return 0
    fi
    
    log INFO "Waiting for namespace deletion (timeout: ${timeout}s)..."
    
    while [[ $elapsed -lt $timeout ]]; do
        if ! oc get namespace "$namespace" &>/dev/null; then
            log SUCCESS "Namespace $namespace deleted successfully"
            return 0
        fi
        
        # Check if namespace is stuck in Terminating state
        local status
        status=$(oc get namespace "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        
        if [[ "$status" == "Terminating" ]] && [[ $elapsed -gt 60 ]]; then
            log WARNING "Namespace stuck in Terminating state. Checking for finalizers..."
            local finalizers
            finalizers=$(oc get namespace "$namespace" -o jsonpath='{.spec.finalizers}' 2>/dev/null || echo "")
            
            if [[ -n "$finalizers" && "$finalizers" != "[]" ]]; then
                log WARNING "Finalizers present: $finalizers"
                log INFO "Attempting to remove finalizers..."
                oc patch namespace "$namespace" -p '{"spec":{"finalizers":[]}}' --type=merge 2>/dev/null || true
            fi
        fi
        
        log INFO "Still waiting for namespace deletion... ($elapsed/${timeout}s elapsed)"
        sleep $check_interval
        ((elapsed += check_interval))
    done
    
    log ERROR "Timeout waiting for namespace deletion after ${timeout}s"
    log WARNING "You may need to manually investigate: oc get namespace $namespace -o yaml"
    return 1
}

log INFO "Starting PostgreSQL cleanup for namespace: $NAMESPACE"

# Step 1: Delete PostgresCluster CRs
log INFO "Step 1/5: Checking for PostgresCluster resources..."
if oc get postgrescluster -n "$NAMESPACE" &> /dev/null; then
    POSTGRES_CLUSTERS=$(oc get postgrescluster -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $1}' || echo "")
    if [[ -n "$POSTGRES_CLUSTERS" ]]; then
        log INFO "Found PostgresCluster resources: $POSTGRES_CLUSTERS"
        for cluster in $POSTGRES_CLUSTERS; do
            execute "oc delete postgrescluster $cluster -n $NAMESPACE"
        done
        
        # Wait for deletion to complete
        if [[ "$DRY_RUN" != "true" ]]; then
            wait_for_resource_deletion "postgrescluster" "$NAMESPACE" 600
        fi
    else
        log INFO "No PostgresCluster resources found."
    fi
else
    log INFO "No PostgresCluster CRD found. Skipping..."
fi

# Step 2: Delete Crunchy Postgres Operator subscription
log INFO "Step 2/5: Checking for Crunchy Postgres Operator subscription..."
SUBSCRIPTION_FOUND=false
if oc get subscription -n "$NAMESPACE" &> /dev/null; then
    SUBSCRIPTIONS=$(oc get subscription -n "$NAMESPACE" --no-headers 2>/dev/null | grep -E 'postgres|crunchy' | awk '{print $1}' || echo "")
    if [[ -n "$SUBSCRIPTIONS" ]]; then
        log INFO "Found PostgreSQL operator subscription(s): $SUBSCRIPTIONS"
        for sub in $SUBSCRIPTIONS; do
            execute "oc delete subscription $sub -n $NAMESPACE"
            SUBSCRIPTION_FOUND=true
        done
        log SUCCESS "Deleted PostgreSQL operator subscription(s)."
    else
        log WARNING "No PostgreSQL operator subscription found. Operator may have been installed manually."
        log INFO "Will attempt direct CSV deletion as fallback."
    fi
else
    log INFO "No subscriptions found in namespace."
fi

# Step 3: Wait for OLM to remove CSV automatically (or delete manually if no subscription)
log INFO "Step 3/5: Waiting for operator CSV cleanup..."
if [[ "$SUBSCRIPTION_FOUND" == "true" ]]; then
    # OLM will remove CSV automatically after subscription deletion
    log INFO "Waiting for OLM to remove CSV gracefully (timeout: 300s)..."
    if [[ "$DRY_RUN" != "true" ]]; then
        wait_for_resource_deletion "csv" "$NAMESPACE" 300 || {
            log WARNING "CSV removal timed out. Attempting manual cleanup..."
            CSV_LIST=$(oc get csv -n "$NAMESPACE" --no-headers 2>/dev/null | grep 'postgresoperator' | awk '{print $1}' || echo "")
            if [[ -n "$CSV_LIST" ]]; then
                for csv in $CSV_LIST; do
                    log INFO "Force deleting CSV: $csv"
                    execute "oc delete csv $csv -n $NAMESPACE --wait=false"
                done
            fi
        }
    fi
else
    # No subscription found, manually delete CSV
    log INFO "No subscription found. Manually deleting CSV resources..."
    CSV_LIST=$(oc get csv -n "$NAMESPACE" --no-headers 2>/dev/null | grep 'postgresoperator' | awk '{print $1}' || echo "")
    if [[ -n "$CSV_LIST" ]]; then
        log INFO "Found CSV resources: $CSV_LIST"
        
        # Delete CSV with --wait=false to avoid blocking
        for csv in $CSV_LIST; do
            execute "oc delete csv $csv -n $NAMESPACE --wait=false"
        done
        
        # Wait for specific CSV deletion (not all CSVs in namespace)
        if [[ "$DRY_RUN" != "true" ]]; then
            log INFO "Waiting for specific CSV(s) to be removed..."
            CSV_TIMEOUT=180
            CSV_CHECK_INTERVAL=5
            CSV_ELAPSED=0
            
            while [[ $CSV_ELAPSED -lt $CSV_TIMEOUT ]]; do
                CSV_REMAINING=""
                for csv in $CSV_LIST; do
                    if oc get csv "$csv" -n "$NAMESPACE" &>/dev/null; then
                        CSV_REMAINING="$CSV_REMAINING $csv"
                    fi
                done
                
                if [[ -z "$CSV_REMAINING" ]]; then
                    log SUCCESS "All CSV resources deleted successfully"
                    break
                fi
                
                CSV_COUNT=$(echo "$CSV_REMAINING" | wc -w | tr -d ' ')
                log INFO "Still waiting... ($CSV_ELAPSED/${CSV_TIMEOUT}s elapsed, $CSV_COUNT CSV(s) remaining:$CSV_REMAINING)"
                sleep $CSV_CHECK_INTERVAL
                ((CSV_ELAPSED += CSV_CHECK_INTERVAL))
            done
            
            if [[ $CSV_ELAPSED -ge $CSV_TIMEOUT ]]; then
                log WARNING "CSV deletion timed out after ${CSV_TIMEOUT}s, but continuing..."
            fi
        fi
    else
        log INFO "No CSV resources found."
    fi
fi

# Step 4: Clean up operator deployment if still present
log INFO "Step 4/5: Checking for operator deployment..."
if [[ "$DRY_RUN" != "true" ]]; then
    OPERATOR_DEPLOYMENTS=$(oc get deployment -n "$NAMESPACE" --no-headers 2>/dev/null | grep -E 'postgres|pgo' | awk '{print $1}' || echo "")
    if [[ -n "$OPERATOR_DEPLOYMENTS" ]]; then
        log WARNING "Found lingering operator deployment(s): $OPERATOR_DEPLOYMENTS"
        for deploy in $OPERATOR_DEPLOYMENTS; do
            log INFO "Deleting deployment: $deploy"
            execute "oc delete deployment $deploy -n $NAMESPACE --wait=false"
        done
    else
        log INFO "No operator deployments found."
    fi
else
    log INFO "Skipping deployment check (dry-run mode)."
fi

# Step 5: Delete namespace
log INFO "Step 5/5: Deleting namespace: $NAMESPACE..."
execute "oc delete namespace $NAMESPACE"

# Wait for namespace deletion to complete
if [[ "$DRY_RUN" != "true" ]]; then
    wait_for_namespace_deletion "$NAMESPACE" 600
fi

if [[ "$DRY_RUN" == "true" ]]; then
    log INFO "=== DRY-RUN COMPLETE: No resources were actually deleted ==="
else
    log SUCCESS "PostgreSQL cleanup completed successfully!"
    log INFO "Namespace '$NAMESPACE' and all PostgreSQL resources have been removed."
fi

