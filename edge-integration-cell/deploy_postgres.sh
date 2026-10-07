#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default values
NAMESPACE="sap-eic-external-postgres"
POSTGRES_VERSION="v15"  # Default PostgreSQL version
INSTANCE=""             # optional EIC instance name (multiple EIC systems on one cluster)
PG_CLUSTER_NAME="edgedb"   # shared PostgresCluster that backs every EIC instance
# The default (no instance) database/user and its operator-generated secret.
# For an instance these become edgedb-<instance> so each EIC system gets an
# isolated database inside the shared cluster (schema/database-level isolation).
PG_USER="edgedb"
PG_DATABASE="edgedb"
SECRET_NAME="edgedb-pguser-edgedb"
DRY_RUN=false
FORCE=false
VERBOSE=false
SKIP_WAIT=false
HA_MODE=false

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

Deploy PostgreSQL external service using Crunchy Data Operator.

OPTIONS:
    -n, --namespace NAMESPACE    Namespace for deployment (default: sap-eic-external-postgres)
    -i, --instance NAME          EIC instance name. Adds an isolated database+user
                                 "edgedb-<name>" to the shared PostgresCluster so multiple
                                 EIC systems can share one cluster (database-level isolation).
                                 Name must be a lowercase DNS label (a-z, 0-9, '-').
    -v, --version VERSION        PostgreSQL version: v15, v16, v17 (default: v15)
    -f, --force                  Skip confirmation prompts (for automation)
    -d, --dry-run               Show what would be deployed without actually deploying
    --ha                         Deploy in HA mode (3 replicas with anti-affinity)
    --skip-wait                  Skip waiting for operator/cluster readiness
    --verbose                    Enable verbose output
    -h, --help                  Display this help message

EXAMPLES:
    # Interactive deployment with default settings
    $0

    # Deploy PostgreSQL v16 to custom namespace
    $0 --namespace my-postgres --version v16

    # Add an isolated database for a second EIC system (shared cluster)
    $0 --instance eic02 --force

    # Force deployment without prompts (CI/CD)
    $0 --force

    # Dry-run to preview deployment
    $0 --dry-run

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
        -v|--version)
            POSTGRES_VERSION="$2"
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
        --ha)
            HA_MODE=true
            shift
            ;;
        --skip-wait)
            SKIP_WAIT=true
            shift
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

# Verbose mode
if [[ "$VERBOSE" == "true" ]]; then
    set -x
fi

# Validate PostgreSQL version
if [[ ! "$POSTGRES_VERSION" =~ ^v1[5-7]$ ]]; then
    log ERROR "Invalid PostgreSQL version: $POSTGRES_VERSION. Must be v15, v16, or v17."
    exit 1
fi

# Resolve per-instance database/user names. The instance maps to a dedicated
# database inside the shared cluster (not a separate namespace). The name must be
# valid both as a PostgreSQL identifier and as part of the operator-generated
# Secret name ("<cluster>-pguser-<user>"), so restrict it to a DNS-1123 label.
if [[ -n "$INSTANCE" ]]; then
    if [[ ! "$INSTANCE" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
        log ERROR "Invalid instance name: '$INSTANCE'. Use a lowercase DNS label (a-z, 0-9, '-')."
        exit 1
    fi
    PG_USER="edgedb-${INSTANCE}"
    PG_DATABASE="edgedb-${INSTANCE}"
    SECRET_NAME="${PG_CLUSTER_NAME}-pguser-${PG_USER}"
fi

# Append an isolated database+user to the shared PostgresCluster (idempotent).
# Crunchy auto-creates the database and a Secret named "$SECRET_NAME" with
# host/port/dbname/user/password for the new database.
add_instance_database() {
    if oc get postgrescluster "$PG_CLUSTER_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.spec.users[*].name}' 2>/dev/null | tr ' ' '\n' | grep -qx "$PG_USER"; then
        log INFO "Database/user '$PG_USER' already present on shared cluster '$PG_CLUSTER_NAME' (idempotent)."
        return 0
    fi
    local patch="[{\"op\":\"add\",\"path\":\"/spec/users/-\",\"value\":{\"name\":\"${PG_USER}\",\"databases\":[\"${PG_DATABASE}\"],\"options\":\"SUPERUSER\"}}]"
    if [[ "$DRY_RUN" == "true" ]]; then
        log INFO "[DRY-RUN] Would patch PostgresCluster '$PG_CLUSTER_NAME' to add database/user '$PG_USER'."
        return 0
    fi
    log INFO "Adding isolated database/user '$PG_USER' to shared cluster '$PG_CLUSTER_NAME'..."
    oc patch postgrescluster "$PG_CLUSTER_NAME" -n "$NAMESPACE" --type=json -p "$patch"
    log SUCCESS "Database/user '$PG_USER' added."
}

# Check if oc is available
if ! command -v oc &> /dev/null; then
    log ERROR "oc command not found. Please install OpenShift CLI."
    exit 1
fi

# Check if already deployed (idempotency check)
IDEMPOTENT_SKIP=false
if oc get namespace "$NAMESPACE" &> /dev/null; then
    log INFO "Namespace '$NAMESPACE' already exists (idempotent - will check existing resources)."
    if oc get postgrescluster -n "$NAMESPACE" &> /dev/null 2>&1; then
        EXISTING_CLUSTERS=$(oc get postgrescluster -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $1}' || echo "")
        if [[ -n "$EXISTING_CLUSTERS" ]]; then
            log INFO "PostgresCluster(s) already exist: $EXISTING_CLUSTERS"
            
            # Check if cluster is ready
            CLUSTER_STATUS=$(oc get postgrescluster -n "$NAMESPACE" -o jsonpath='{.items[0].status.patroni.ready}' 2>/dev/null || echo "false")
            if [[ "$CLUSTER_STATUS" == "true" && -z "$INSTANCE" ]]; then
                log INFO "PostgresCluster is ready and operational."
                log SUCCESS "PostgreSQL deployment already complete (idempotent - no changes needed)."
                IDEMPOTENT_SKIP=true
            elif [[ "$CLUSTER_STATUS" == "true" && -n "$INSTANCE" ]]; then
                log INFO "Shared PostgresCluster is ready; will attach EIC instance '$INSTANCE'."
            else
                log WARNING "PostgresCluster exists but may not be ready yet. Will check status..."
            fi
        fi
    fi
fi

# Display banner
log HEADER "PostgreSQL External Service Deployment"

# Summary
log INFO "Deployment Configuration:"
log INFO "  - Namespace: $NAMESPACE"
log INFO "  - PostgreSQL Version: $POSTGRES_VERSION"
log INFO "  - Dry-run: $([ "$DRY_RUN" == "true" ] && echo "YES" || echo "NO")"
log INFO "  - Skip wait: $([ "$SKIP_WAIT" == "true" ] && echo "YES" || echo "NO")"

# Confirmation prompt
if [[ "$FORCE" != "true" && "$DRY_RUN" != "true" ]]; then
    echo ""
    log WARNING "This will deploy PostgreSQL operator and cluster to: $NAMESPACE"
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
    log INFO "All PostgreSQL resources already exist and are deployed."
    log INFO "Retrieving existing access details..."
    echo ""
    if [[ -f "$SCRIPT_DIR/external-postgres/get_external_postgres_access.sh" ]]; then
        bash "$SCRIPT_DIR/external-postgres/get_external_postgres_access.sh" -n "$NAMESPACE" --secret "$SECRET_NAME"
    else
        log WARNING "Access script not found. You can retrieve access details manually."
    fi
    echo ""
    log SUCCESS "✅ PostgreSQL deployment verification completed (idempotent)."
    log INFO "To re-deploy from scratch, run cleanup first:"
    log INFO "  bash $SCRIPT_DIR/cleanup_postgres.sh"
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

log INFO "Starting PostgreSQL deployment..."

# Step 1: Create namespace
log INFO "Step 1/7: Creating namespace: $NAMESPACE"
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

# Step 2: Apply OperatorGroup
log INFO "Step 2/7: Applying OperatorGroup configuration..."
execute "oc apply -f $SCRIPT_DIR/postgres-operator/operatorgroup.yaml"

# Step 3: Apply Subscription
log INFO "Step 3/7: Applying Subscription configuration..."
execute "oc apply -f $SCRIPT_DIR/postgres-operator/subscription.yaml"

# Step 4: Wait for operator to be ready
if [[ "$SKIP_WAIT" != "true" && "$DRY_RUN" != "true" ]]; then
    log INFO "Step 4/7: Waiting for Postgres operator to be ready (timeout: 5 minutes)..."
    if [[ -f "$SCRIPT_DIR/external-postgres/wait_for_postgres_operator_ready.sh" ]]; then
        # Run wait script with timeout
        WAIT_TIMEOUT=300  # 5 minutes
        if timeout "$WAIT_TIMEOUT" bash "$SCRIPT_DIR/external-postgres/wait_for_postgres_operator_ready.sh" 2>/dev/null; then
            log SUCCESS "Postgres operator is ready."
        else
            EXIT_CODE=$?
            if [[ $EXIT_CODE -eq 124 ]]; then
                log ERROR "Timeout waiting for Postgres operator after ${WAIT_TIMEOUT}s."
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
    log INFO "Step 4/7: Skipping operator readiness wait."
fi

# Step 5: Create PostgresCluster
log INFO "Step 5/7: Creating PostgresCluster ($POSTGRES_VERSION)..."
HA_SUFFIX=""
if [[ "$HA_MODE" == "true" ]]; then
    HA_SUFFIX="-ha"
    log INFO "HA mode enabled: deploying with 3 replicas and pod anti-affinity"
fi
POSTGRES_CLUSTER_FILE="$SCRIPT_DIR/external-postgres/postgrescluster-${POSTGRES_VERSION}${HA_SUFFIX}.yaml"
if [[ ! -f "$POSTGRES_CLUSTER_FILE" ]]; then
    log ERROR "PostgresCluster file not found: $POSTGRES_CLUSTER_FILE"
    exit 1
fi
# Apply the base cluster manifest only when the shared cluster does not yet exist.
# Re-applying it would reset spec.users to just the default user and drop databases
# previously added for other EIC instances via `oc patch`.
if oc get postgrescluster "$PG_CLUSTER_NAME" -n "$NAMESPACE" &> /dev/null; then
    log INFO "Shared PostgresCluster '$PG_CLUSTER_NAME' already exists; skipping base manifest apply."
else
    execute "oc apply -f $POSTGRES_CLUSTER_FILE"
fi

# Step 6: Wait for PostgresCluster to be ready
if [[ "$SKIP_WAIT" != "true" && "$DRY_RUN" != "true" ]]; then
    log INFO "Step 6/7: Waiting for PostgresCluster to be ready (timeout: 10 minutes)..."
    if [[ -f "$SCRIPT_DIR/external-postgres/wait_for_postgres_ready.sh" ]]; then
        # Run wait script with timeout (PostgresCluster takes longer to initialize)
        CLUSTER_WAIT_TIMEOUT=600  # 10 minutes
        if timeout "$CLUSTER_WAIT_TIMEOUT" bash "$SCRIPT_DIR/external-postgres/wait_for_postgres_ready.sh" 2>/dev/null; then
            log SUCCESS "PostgresCluster is ready."
        else
            EXIT_CODE=$?
            if [[ $EXIT_CODE -eq 124 ]]; then
                log ERROR "Timeout waiting for PostgresCluster after ${CLUSTER_WAIT_TIMEOUT}s."
                log ERROR ""
                log ERROR "The cluster is taking longer than expected to become ready."
                log ERROR "Please check:"
                log ERROR "  1. Cluster status: oc get postgrescluster -n $NAMESPACE"
                log ERROR "  2. Cluster pods: oc get pods -n $NAMESPACE"
                log ERROR "  3. Events: oc get events -n $NAMESPACE --sort-by='.lastTimestamp'"
                log ERROR ""
                log ERROR "You can continue checking manually with:"
                log ERROR "  bash $SCRIPT_DIR/external-postgres/wait_for_postgres_ready.sh"
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
    log INFO "Step 6/7: Skipping PostgresCluster readiness wait."
fi

# Step 6b: Attach isolated database for this EIC instance (shared-cluster model)
if [[ -n "$INSTANCE" ]]; then
    log INFO "Attaching EIC instance '$INSTANCE' (database/user '$PG_USER') to shared cluster..."
    add_instance_database
    # Wait for the operator to generate the per-database connection Secret.
    if [[ "$SKIP_WAIT" != "true" && "$DRY_RUN" != "true" ]]; then
        log INFO "Waiting for connection secret '$SECRET_NAME' to be created (timeout: 3 minutes)..."
        SECRET_WAIT=180
        SECRET_ELAPSED=0
        while [[ $SECRET_ELAPSED -lt $SECRET_WAIT ]]; do
            if oc get secret "$SECRET_NAME" -n "$NAMESPACE" &> /dev/null; then
                log SUCCESS "Connection secret '$SECRET_NAME' is ready."
                break
            fi
            sleep 5
            ((SECRET_ELAPSED += 5))
        done
        if [[ $SECRET_ELAPSED -ge $SECRET_WAIT ]]; then
            log WARNING "Secret '$SECRET_NAME' not found yet; it may take another moment."
        fi
    fi
fi

# Step 7: Get access details
if [[ "$DRY_RUN" != "true" ]]; then
    log INFO "Step 7/7: Retrieving PostgreSQL access details..."
    echo ""
    if [[ -f "$SCRIPT_DIR/external-postgres/get_external_postgres_access.sh" ]]; then
        bash "$SCRIPT_DIR/external-postgres/get_external_postgres_access.sh" -n "$NAMESPACE" --secret "$SECRET_NAME"
    else
        log WARNING "Access script not found. You can retrieve access details manually later."
    fi
else
    log INFO "Step 7/7: [DRY-RUN] Would retrieve access details."
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
    log SUCCESS "✅ PostgreSQL deployment completed successfully!"
    log INFO "Namespace: $NAMESPACE"
    log INFO "Version: $POSTGRES_VERSION"
    echo ""
    log INFO "Next steps:"
    log INFO "  1. Use the access details above to configure SAP EIC"
    log INFO "  2. To cleanup: bash $SCRIPT_DIR/cleanup_postgres.sh"
fi

