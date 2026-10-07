#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# Default values
NAMESPACE_BASE="sap-eic-external-redis"
NAMESPACE=""            # resolved after arg parse (see instance derivation)
INSTANCE=""             # optional EIC instance name (multiple EIC systems on one cluster)
DRY_RUN=false
FORCE=false
VERBOSE=false
OPENSHIFT_VERSION=""

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

Cleanup Redis external services deployed via Redis Enterprise Operator.

OPTIONS:
    -n, --namespace NAMESPACE    Namespace to cleanup (default: sap-eic-external-redis)
    -i, --instance NAME          EIC instance name. Cleans up namespace "${NAMESPACE_BASE}-<name>".
                                 Ignored if --namespace is given.
    -f, --force                  Skip confirmation prompts (for automation)
    -d, --dry-run               Show what would be deleted without actually deleting
    -v, --verbose               Enable verbose output
    --ocp-version VERSION       Specify OpenShift version (4.16+, <4.16) for SCC cleanup
    -h, --help                  Display this help message

EXAMPLES:
    # Interactive cleanup with confirmation
    $0

    # Force cleanup without prompts (CI/CD)
    $0 --force

    # Dry-run to see what would be deleted
    $0 --dry-run

    # Cleanup with OpenShift version specified
    $0 --ocp-version 4.16

    # Cleanup custom namespace
    $0 --namespace my-redis-namespace

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
        --ocp-version)
            OPENSHIFT_VERSION="$2"
            shift 2
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

# Resolve namespace: explicit --namespace always wins; otherwise derive from the
# instance name (one namespace per EIC system) or fall back to the legacy default.
if [[ -z "$NAMESPACE" ]]; then
    if [[ -n "$INSTANCE" ]]; then
        NAMESPACE="${NAMESPACE_BASE}-${INSTANCE}"
    else
        NAMESPACE="$NAMESPACE_BASE"
    fi
fi

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

# Detect OpenShift version if not provided
if [[ -z "$OPENSHIFT_VERSION" ]]; then
    log INFO "Detecting OpenShift version..."
    OCP_VERSION=$(oc version -o json 2>/dev/null | jq -r '.openshiftVersion // empty' || echo "")
    if [[ -n "$OCP_VERSION" ]]; then
        log INFO "Detected OpenShift version: $OCP_VERSION"
        OPENSHIFT_VERSION="$OCP_VERSION"
    else
        log WARNING "Could not detect OpenShift version. SCC cleanup will be skipped."
        log WARNING "Use --ocp-version flag to specify version manually."
    fi
fi

# Confirmation prompt
if [[ "$FORCE" != "true" && "$DRY_RUN" != "true" ]]; then
    log WARNING "This will delete all Redis resources in namespace: $NAMESPACE"
    echo -e "${YELLOW}Resources to be deleted:${NC}"
    echo "  - RedisEnterpriseDatabase CRs"
    echo "  - RedisEnterpriseCluster CRs"
    echo "  - Redis Enterprise Operator subscription"
    echo "  - Redis Enterprise Operator CSV"
    echo "  - Redis Enterprise SCC (if OpenShift version detected)"
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

log INFO "Starting Redis cleanup for namespace: $NAMESPACE"

# Step 1: Delete RedisEnterpriseDatabase CRs
log INFO "Step 1/7: Checking for RedisEnterpriseDatabase resources..."
if oc get redisenterprisedatabase -n "$NAMESPACE" &> /dev/null; then
    REDIS_DBS=$(oc get redisenterprisedatabase -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $1}' || echo "")
    if [[ -n "$REDIS_DBS" ]]; then
        log INFO "Found RedisEnterpriseDatabase resources: $REDIS_DBS"
        for db in $REDIS_DBS; do
            execute "oc delete redisenterprisedatabase $db -n $NAMESPACE"
        done
        
        # Wait for deletion to complete
        if [[ "$DRY_RUN" != "true" ]]; then
            wait_for_resource_deletion "redisenterprisedatabase" "$NAMESPACE" 300
        fi
    else
        log INFO "No RedisEnterpriseDatabase resources found."
    fi
else
    log INFO "No RedisEnterpriseDatabase CRD found. Skipping..."
fi

# Step 2: Delete RedisEnterpriseCluster CRs
log INFO "Step 2/7: Checking for RedisEnterpriseCluster resources..."
if oc get redisenterprisecluster -n "$NAMESPACE" &> /dev/null; then
    REDIS_CLUSTERS=$(oc get redisenterprisecluster -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $1}' || echo "")
    if [[ -n "$REDIS_CLUSTERS" ]]; then
        log INFO "Found RedisEnterpriseCluster resources: $REDIS_CLUSTERS"
        for cluster in $REDIS_CLUSTERS; do
            execute "oc delete redisenterprisecluster $cluster -n $NAMESPACE"
        done
        
        # Wait for deletion to complete
        if [[ "$DRY_RUN" != "true" ]]; then
            wait_for_resource_deletion "redisenterprisecluster" "$NAMESPACE" 600
        fi
    else
        log INFO "No RedisEnterpriseCluster resources found."
    fi
else
    log INFO "No RedisEnterpriseCluster CRD found. Skipping..."
fi

# Step 3: Delete Redis Enterprise Operator subscription
log INFO "Step 3/7: Checking for Redis Enterprise Operator subscription..."
SUBSCRIPTION_FOUND=false
if oc get subscription -n "$NAMESPACE" &> /dev/null; then
    SUBSCRIPTIONS=$(oc get subscription -n "$NAMESPACE" --no-headers 2>/dev/null | grep -E 'redis' | awk '{print $1}' || echo "")
    if [[ -n "$SUBSCRIPTIONS" ]]; then
        log INFO "Found Redis operator subscription(s): $SUBSCRIPTIONS"
        for sub in $SUBSCRIPTIONS; do
            execute "oc delete subscription $sub -n $NAMESPACE"
            SUBSCRIPTION_FOUND=true
        done
        log SUCCESS "Deleted Redis operator subscription(s)."
    else
        log WARNING "No Redis operator subscription found. Operator may have been installed manually."
        log INFO "Will attempt direct CSV deletion as fallback."
    fi
else
    log INFO "No subscriptions found in namespace."
fi

# Step 4: Wait for OLM to remove CSV automatically (or delete manually if no subscription)
log INFO "Step 4/7: Waiting for operator CSV cleanup..."
if [[ "$SUBSCRIPTION_FOUND" == "true" ]]; then
    # OLM will remove CSV automatically after subscription deletion
    log INFO "Waiting for OLM to remove CSV gracefully (timeout: 300s)..."
    if [[ "$DRY_RUN" != "true" ]]; then
        wait_for_resource_deletion "csv" "$NAMESPACE" 300 || {
            log WARNING "CSV removal timed out. Attempting manual cleanup..."
            CSV_LIST=$(oc get csv -n "$NAMESPACE" --no-headers 2>/dev/null | grep 'redis-enterprise-operator' | awk '{print $1}' || echo "")
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
    CSV_LIST=$(oc get csv -n "$NAMESPACE" --no-headers 2>/dev/null | grep 'redis-enterprise-operator' | awk '{print $1}' || echo "")
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

# Step 5: Clean up operator deployment if still present
log INFO "Step 5/7: Checking for operator deployment..."
if [[ "$DRY_RUN" != "true" ]]; then
    OPERATOR_DEPLOYMENTS=$(oc get deployment -n "$NAMESPACE" --no-headers 2>/dev/null | grep -E 'redis' | awk '{print $1}' || echo "")
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

# Step 6: Delete Redis Enterprise SCC
log INFO "Step 6/7: Checking for Redis Enterprise SCC..."
if [[ -n "$OPENSHIFT_VERSION" ]]; then
    # Determine SCC name based on OpenShift version
    if [[ "$OPENSHIFT_VERSION" =~ ^4\.([0-9]+) ]]; then
        MINOR_VERSION="${BASH_REMATCH[1]}"
        if [[ "$MINOR_VERSION" -ge 16 ]]; then
            SCC_NAME="redis-enterprise-scc-v2"
        else
            SCC_NAME="redis-enterprise-scc"
        fi
        
        # The Redis Enterprise SCC is cluster-scoped and shared by every Redis
        # instance on the cluster. Only remove it once no RedisEnterpriseCluster
        # remains in any namespace, otherwise we would break the other EIC systems.
        REMAINING_RECS=$(oc get redisenterprisecluster -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$REMAINING_RECS" != "0" ]]; then
            log WARNING "Found $REMAINING_RECS RedisEnterpriseCluster(s) still present in other namespaces."
            log INFO "Keeping shared SCC '$SCC_NAME' (removed only on the last instance teardown)."
        elif oc get scc "$SCC_NAME" &> /dev/null; then
            execute "oc delete scc $SCC_NAME"
            log SUCCESS "Deleted Redis Enterprise SCC: $SCC_NAME"
        else
            log INFO "No Redis Enterprise SCC found: $SCC_NAME"
        fi
    else
        log WARNING "Could not parse OpenShift version. Skipping SCC cleanup."
    fi
else
    log WARNING "OpenShift version not detected. Skipping SCC cleanup."
    log INFO "To cleanup SCC manually, run:"
    log INFO "  oc delete scc redis-enterprise-scc-v2  # For OpenShift 4.16+"
    log INFO "  oc delete scc redis-enterprise-scc     # For OpenShift < 4.16"
fi

# Step 7: Delete namespace
log INFO "Step 7/7: Deleting namespace: $NAMESPACE..."
execute "oc delete namespace $NAMESPACE"

# Wait for namespace deletion to complete
if [[ "$DRY_RUN" != "true" ]]; then
    wait_for_namespace_deletion "$NAMESPACE" 600
fi

if [[ "$DRY_RUN" == "true" ]]; then
    log INFO "=== DRY-RUN COMPLETE: No resources were actually deleted ==="
else
    log SUCCESS "Redis cleanup completed successfully!"
    log INFO "Namespace '$NAMESPACE' and all Redis resources have been removed."
fi

