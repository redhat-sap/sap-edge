#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default values
NAMESPACE_BASE="sap-eic-external-redis"
NAMESPACE=""            # resolved after arg parse (see instance derivation)
INSTANCE=""             # optional EIC instance name (multiple EIC systems on one cluster)
REDIS_CLUSTER_TYPE="standard"  # standard or ha
DRY_RUN=false
FORCE=false
VERBOSE=false
SKIP_WAIT=false
OPENSHIFT_VERSION=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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
        HEADER)
            echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${CYAN}║${NC} $*"
            echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
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

Deploy Redis external service using Redis Enterprise Operator.

OPTIONS:
    -n, --namespace NAMESPACE    Namespace for deployment (default: sap-eic-external-redis)
    -i, --instance NAME          EIC instance name. Deploys an isolated Redis instance into
                                 namespace "${NAMESPACE_BASE}-<name>" so multiple EIC systems
                                 can share one cluster. Ignored if --namespace is given.
    --type TYPE                  Cluster type: standard or ha (default: standard)
    -f, --force                  Skip confirmation prompts (for automation)
    -d, --dry-run               Show what would be deployed without actually deploying
    --skip-wait                  Skip waiting for operator/cluster readiness
    --ocp-version VERSION        Specify OpenShift version for SCC (auto-detected if not provided)
    --verbose                    Enable verbose output
    -h, --help                  Display this help message

EXAMPLES:
    # Interactive deployment with default settings
    $0

    # Deploy HA cluster to custom namespace
    $0 --namespace my-redis --type ha

    # Deploy an isolated instance for a second EIC system
    $0 --instance eic02 --force

    # Force deployment without prompts (CI/CD)
    $0 --force

    # Dry-run to preview deployment
    $0 --dry-run

    # Specify OpenShift version for SCC
    $0 --ocp-version 4.16

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
        --type)
            REDIS_CLUSTER_TYPE="$2"
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
        --skip-wait)
            SKIP_WAIT=true
            shift
            ;;
        --ocp-version)
            OPENSHIFT_VERSION="$2"
            shift 2
            ;;
        --verbose)
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

# Validate cluster type
if [[ ! "$REDIS_CLUSTER_TYPE" =~ ^(standard|ha)$ ]]; then
    log ERROR "Invalid cluster type: $REDIS_CLUSTER_TYPE. Must be 'standard' or 'ha'."
    exit 1
fi

# Check if oc is available
if ! command -v oc &> /dev/null; then
    log ERROR "oc command not found. Please install OpenShift CLI."
    exit 1
fi

# Detect OpenShift version if not provided
if [[ -z "$OPENSHIFT_VERSION" ]]; then
    log INFO "Detecting OpenShift version..."
    OCP_VERSION=$(oc version -o json 2>/dev/null | jq -r '.openshiftVersion // empty' || echo "")
    if [[ -n "$OCP_VERSION" ]]; then
        log INFO "Detected OpenShift version: $OCP_VERSION"
        OPENSHIFT_VERSION="$OCP_VERSION"
    else
        log WARNING "Could not detect OpenShift version. Will skip SCC creation."
        log WARNING "Use --ocp-version flag to specify version manually."
    fi
fi

# Check if already deployed (idempotency check)
IDEMPOTENT_SKIP=false
if oc get namespace "$NAMESPACE" &> /dev/null; then
    log INFO "Namespace '$NAMESPACE' already exists (idempotent - will check existing resources)."
    if oc get redisenterprisecluster -n "$NAMESPACE" &> /dev/null 2>&1; then
        EXISTING_CLUSTERS=$(oc get redisenterprisecluster -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $1}' || echo "")
        if [[ -n "$EXISTING_CLUSTERS" ]]; then
            log INFO "RedisEnterpriseCluster(s) already exist: $EXISTING_CLUSTERS"
            
            # Check if database also exists
            if oc get redisenterprisedatabase -n "$NAMESPACE" &> /dev/null 2>&1; then
                EXISTING_DBS=$(oc get redisenterprisedatabase -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $1}' || echo "")
                if [[ -n "$EXISTING_DBS" ]]; then
                    log INFO "RedisEnterpriseDatabase(s) already exist: $EXISTING_DBS"
                    log SUCCESS "Redis deployment already complete (idempotent - no changes needed)."
                    IDEMPOTENT_SKIP=true
                fi
            fi
        fi
    fi
fi

# Display banner
log HEADER "Redis External Service Deployment"

# Summary
log INFO "Deployment Configuration:"
log INFO "  - Namespace: $NAMESPACE"
log INFO "  - Cluster Type: $REDIS_CLUSTER_TYPE"
log INFO "  - OpenShift Version: ${OPENSHIFT_VERSION:-not detected}"
log INFO "  - Dry-run: $([ "$DRY_RUN" == "true" ] && echo "YES" || echo "NO")"
log INFO "  - Skip wait: $([ "$SKIP_WAIT" == "true" ] && echo "YES" || echo "NO")"

# Confirmation prompt
if [[ "$FORCE" != "true" && "$DRY_RUN" != "true" ]]; then
    echo ""
    log WARNING "This will deploy Redis operator and cluster to: $NAMESPACE"
    echo ""
    read -rp "Do you want to continue? (yes/no): " confirmation
    if [[ "$confirmation" != "yes" ]]; then
        log INFO "Deployment cancelled by user."
        exit 0
    fi
fi

# Dry-run header
if [[ "$DRY_RUN" == "true" ]]; then
    log INFO "════════════════════════════════════════════════════════════════"
    log INFO "                    DRY-RUN MODE ENABLED"
    log INFO "           No resources will be actually deployed"
    log INFO "════════════════════════════════════════════════════════════════"
fi

# Check if we can skip deployment (idempotent)
if [[ "$IDEMPOTENT_SKIP" == "true" && "$DRY_RUN" != "true" ]]; then
    log INFO "════════════════════════════════════════════════════════════════"
    log INFO "All Redis resources already exist and are deployed."
    log INFO "Retrieving existing access details..."
    echo ""
    if [[ -f "$SCRIPT_DIR/external-redis/get_redis_access.sh" ]]; then
        bash "$SCRIPT_DIR/external-redis/get_redis_access.sh" -n "$NAMESPACE"
    else
        log WARNING "Access script not found. You can retrieve access details manually."
    fi
    echo ""
    log SUCCESS "✅ Redis deployment verification completed (idempotent)."
    log INFO "To re-deploy from scratch, run cleanup first:"
    log INFO "  bash $SCRIPT_DIR/cleanup_redis.sh"
    exit 0
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

# Deployment start time
START_TIME=$(date +%s)

log INFO "Starting Redis deployment..."

# Step 1: Create namespace
log INFO "Step 1/9: Creating namespace: $NAMESPACE"
if [[ "$DRY_RUN" != "true" ]]; then
    if ! oc get namespace "$NAMESPACE" &> /dev/null; then
        execute "oc create namespace $NAMESPACE"
        log SUCCESS "Namespace created."
    else
        log INFO "Namespace already exists."
    fi
else
    log INFO "[DRY-RUN] Would create namespace"
fi

# Render operator manifests into the target namespace. The committed YAML pins the
# default namespace (used by the GitOps path); for script-driven installs we point
# metadata.namespace (stripped, supplied via `oc apply -n`) and the OperatorGroup
# targetNamespaces at $NAMESPACE so each EIC instance gets its own operator install.
OG_RENDERED="$(mktemp)"
SUB_RENDERED="$(mktemp)"
trap 'rm -f "$OG_RENDERED" "$SUB_RENDERED"' EXIT
sed -e '/^  namespace:/d' \
    -e "s|^\( *- \)${NAMESPACE_BASE}\$|\1${NAMESPACE}|" \
    "$SCRIPT_DIR/redis-operator/operatorgroup.yaml" > "$OG_RENDERED"
sed -e '/^  namespace:/d' \
    "$SCRIPT_DIR/redis-operator/subscription.yaml" > "$SUB_RENDERED"

# Step 2: Apply OperatorGroup
log INFO "Step 2/9: Applying OperatorGroup configuration..."
execute "oc apply -n $NAMESPACE -f $OG_RENDERED"

# Step 3: Apply Subscription
log INFO "Step 3/9: Applying Subscription configuration..."
execute "oc apply -n $NAMESPACE -f $SUB_RENDERED"

# Step 4: Apply Security Context Constraint (SCC)
log INFO "Step 4/9: Applying Security Context Constraint (SCC)..."
if [[ -n "$OPENSHIFT_VERSION" ]]; then
    # Determine SCC file based on OpenShift version
    if [[ "$OPENSHIFT_VERSION" =~ ^4\.([0-9]+) ]]; then
        MINOR_VERSION="${BASH_REMATCH[1]}"
        if [[ "$MINOR_VERSION" -ge 16 ]]; then
            SCC_FILE="$SCRIPT_DIR/redis-operator/security_context_constraint_v2.yaml"
            log INFO "Using SCC v2 for OpenShift 4.16+"
        else
            SCC_FILE="$SCRIPT_DIR/redis-operator/security_context_constraint.yaml"
            log INFO "Using SCC v1 for OpenShift < 4.16"
        fi
        
        if [[ -f "$SCC_FILE" ]]; then
            execute "oc apply -f $SCC_FILE"
        else
            log ERROR "SCC file not found: $SCC_FILE"
            exit 1
        fi
    else
        log WARNING "Could not parse OpenShift version. Skipping SCC creation."
    fi
else
    log WARNING "OpenShift version not detected. Skipping SCC creation."
    log INFO "You may need to apply SCC manually later."
fi

# Step 5: Wait for operator to be ready
if [[ "$SKIP_WAIT" != "true" && "$DRY_RUN" != "true" ]]; then
    log INFO "Step 5/9: Waiting for Redis operator to be ready (timeout: 5 minutes)..."
    if [[ -f "$SCRIPT_DIR/external-redis/wait_for_redis_operator_ready.sh" ]]; then
        # Run wait script with timeout
        WAIT_TIMEOUT=300  # 5 minutes
        if timeout "$WAIT_TIMEOUT" bash "$SCRIPT_DIR/external-redis/wait_for_redis_operator_ready.sh" -n "$NAMESPACE" 2>/dev/null; then
            log SUCCESS "Redis operator is ready."
        else
            EXIT_CODE=$?
            if [[ $EXIT_CODE -eq 124 ]]; then
                log ERROR "Timeout waiting for Redis operator after ${WAIT_TIMEOUT}s."
                log ERROR ""
                log ERROR "The operator installation is taking longer than expected."
                log ERROR "This could indicate:"
                log ERROR "  1. Network issues downloading operator images"
                log ERROR "  2. Cluster resource constraints"
                log ERROR "  3. OLM (Operator Lifecycle Manager) issues"
                log ERROR ""
                log ERROR "Please check:"
                log ERROR "  1. Subscription status: oc get subscription -n $NAMESPACE"
                log ERROR "  2. Install plans: oc get installplan -n $NAMESPACE"
                log ERROR "  3. Operator pods: oc get pods -n $NAMESPACE"
                log ERROR ""
                log ERROR "To continue deployment later with existing resources:"
                log ERROR "  bash $0 --skip-wait"
                exit 1
            else
                log ERROR "Wait script failed with exit code: $EXIT_CODE"
                exit 1
            fi
        fi
    else
        log WARNING "Wait script not found. Sleeping 60s..."
        sleep 60
    fi
else
    log INFO "Step 5/9: Skipping operator readiness wait."
fi

# Step 6: Create RedisEnterpriseCluster
log INFO "Step 6/9: Creating RedisEnterpriseCluster ($REDIS_CLUSTER_TYPE)..."
if [[ "$REDIS_CLUSTER_TYPE" == "ha" ]]; then
    REDIS_CLUSTER_FILE="$SCRIPT_DIR/external-redis/redis_enterprise_cluster_ha.yaml"
else
    REDIS_CLUSTER_FILE="$SCRIPT_DIR/external-redis/redis_enterprise_cluster.yaml"
fi

if [[ ! -f "$REDIS_CLUSTER_FILE" ]]; then
    log ERROR "RedisEnterpriseCluster file not found: $REDIS_CLUSTER_FILE"
    exit 1
fi
execute "oc apply -n $NAMESPACE -f $REDIS_CLUSTER_FILE"

# Step 7: Wait for RedisEnterpriseCluster to be ready
if [[ "$SKIP_WAIT" != "true" && "$DRY_RUN" != "true" ]]; then
    log INFO "Step 7/9: Waiting for RedisEnterpriseCluster to be ready (timeout: 8 minutes)..."
    if [[ -f "$SCRIPT_DIR/external-redis/wait_for_rec_running_state.sh" ]]; then
        # Run wait script with timeout
        CLUSTER_WAIT_TIMEOUT=480  # 8 minutes
        if timeout "$CLUSTER_WAIT_TIMEOUT" bash "$SCRIPT_DIR/external-redis/wait_for_rec_running_state.sh" -n "$NAMESPACE" 2>/dev/null; then
            log SUCCESS "RedisEnterpriseCluster is ready."
        else
            EXIT_CODE=$?
            if [[ $EXIT_CODE -eq 124 ]]; then
                log ERROR "Timeout waiting for RedisEnterpriseCluster after ${CLUSTER_WAIT_TIMEOUT}s."
                log ERROR ""
                log ERROR "The cluster is taking longer than expected to become ready."
                log ERROR "Please check:"
                log ERROR "  1. Cluster status: oc get redisenterprisecluster -n $NAMESPACE"
                log ERROR "  2. Cluster pods: oc get pods -n $NAMESPACE"
                log ERROR "  3. Events: oc get events -n $NAMESPACE --sort-by='.lastTimestamp'"
                log ERROR ""
                log ERROR "You can continue checking manually with:"
                log ERROR "  bash $SCRIPT_DIR/external-redis/wait_for_rec_running_state.sh -n $NAMESPACE"
                exit 1
            else
                log ERROR "Wait script failed with exit code: $EXIT_CODE"
                exit 1
            fi
        fi
    else
        log WARNING "Wait script not found. Sleeping 120s..."
        sleep 120
    fi
else
    log INFO "Step 7/9: Skipping RedisEnterpriseCluster readiness wait."
fi

# Step 8: Create RedisEnterpriseDatabase
log INFO "Step 8/9: Creating RedisEnterpriseDatabase..."
REDIS_DB_FILE="$SCRIPT_DIR/external-redis/redis_enterprise_database.yaml"
if [[ ! -f "$REDIS_DB_FILE" ]]; then
    log ERROR "RedisEnterpriseDatabase file not found: $REDIS_DB_FILE"
    exit 1
fi

if [[ "$DRY_RUN" != "true" ]]; then
    # Wait for REC API endpoint to be ready (admission webhook needs this)
    log INFO "Waiting for Redis Enterprise Cluster API to be fully ready..."
    API_READY_WAIT=60
    API_CHECK_INTERVAL=5
    API_ELAPSED=0
    
    while [[ $API_ELAPSED -lt $API_READY_WAIT ]]; do
        # Check if the REC service is responding
        REC_SERVICE=$(oc get svc rec -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
        if [[ -n "$REC_SERVICE" ]]; then
            # Check if we can reach the API port
            if oc exec -n "$NAMESPACE" rec-0 -- curl -ks https://localhost:9443/v1/cluster > /dev/null 2>&1; then
                log SUCCESS "Redis Enterprise Cluster API is ready."
                break
            fi
        fi
        log INFO "Waiting for API endpoint... ($API_ELAPSED/${API_READY_WAIT}s elapsed)"
        sleep "$API_CHECK_INTERVAL"
        ((API_ELAPSED += API_CHECK_INTERVAL))
    done
    
    if [[ $API_ELAPSED -ge $API_READY_WAIT ]]; then
        log WARNING "API endpoint check timed out. Will proceed with retry logic."
    fi
    
    # Retry logic for admission webhook readiness
    MAX_RETRIES=10
    RETRY_COUNT=0
    RETRY_DELAY=20
    
    while [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; do
        RETRY_COUNT=$((RETRY_COUNT + 1))
        log INFO "Attempt $RETRY_COUNT/$MAX_RETRIES: Creating RedisEnterpriseDatabase..."
        
        if oc apply -n "$NAMESPACE" -f "$REDIS_DB_FILE" 2>&1; then
            log SUCCESS "RedisEnterpriseDatabase created successfully."
            break
        else
            if [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; then
                log WARNING "Failed to create RedisEnterpriseDatabase (admission webhook not ready)."
                log WARNING "Retrying in ${RETRY_DELAY}s... (attempt $RETRY_COUNT/$MAX_RETRIES)"
                sleep "$RETRY_DELAY"
            else
                log ERROR "Failed to create RedisEnterpriseDatabase after $MAX_RETRIES attempts."
                log ERROR ""
                log ERROR "The Redis Enterprise Cluster API endpoint (port 9443) is not ready yet."
                log ERROR "This is normal - the cluster needs more time to fully initialize."
                log ERROR ""
                log ERROR "Please wait 1-2 minutes and run the following command manually:"
                log ERROR "  oc apply -n $NAMESPACE -f $REDIS_DB_FILE"
                log ERROR ""
                log ERROR "Or re-run the deployment script with --skip-wait:"
                log ERROR "  bash $0 --skip-wait"
                exit 1
            fi
        fi
    done
else
    log INFO "[DRY-RUN] Would create RedisEnterpriseDatabase (with retry logic)"
fi

# Step 9: Wait for RedisEnterpriseDatabase to be ready and get access details
if [[ "$SKIP_WAIT" != "true" && "$DRY_RUN" != "true" ]]; then
    log INFO "Step 9/9: Waiting for RedisEnterpriseDatabase to be active..."
    if [[ -f "$SCRIPT_DIR/external-redis/wait_for_redb_active_status.sh" ]]; then
        bash "$SCRIPT_DIR/external-redis/wait_for_redb_active_status.sh" -n "$NAMESPACE"
        log SUCCESS "RedisEnterpriseDatabase is active."
    else
        log WARNING "Wait script not found. Sleeping 60s..."
        sleep 60
    fi
    
    # Get access details
    log INFO "Retrieving Redis access details..."
    echo ""
    if [[ -f "$SCRIPT_DIR/external-redis/get_redis_access.sh" ]]; then
        bash "$SCRIPT_DIR/external-redis/get_redis_access.sh" -n "$NAMESPACE"
    else
        log WARNING "Access script not found. You can retrieve access details manually later."
    fi
else
    log INFO "Step 9/9: Skipping database readiness wait."
fi

# Deployment end time
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# Final summary
echo ""
log HEADER "Deployment Summary"
log INFO "Total time: ${DURATION} seconds"

if [[ "$DRY_RUN" == "true" ]]; then
    log INFO "Dry-run completed. No resources were actually deployed."
else
    log SUCCESS "✅ Redis deployment completed successfully!"
    log INFO "Namespace: $NAMESPACE"
    log INFO "Cluster Type: $REDIS_CLUSTER_TYPE"
    echo ""
    log INFO "Next steps:"
    log INFO "  1. Use the access details above to configure SAP EIC"
    log INFO "  2. To cleanup: bash $SCRIPT_DIR/cleanup_redis.sh"
fi

