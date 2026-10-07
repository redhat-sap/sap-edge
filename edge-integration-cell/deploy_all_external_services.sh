#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
#
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default values
DEPLOY_POSTGRES=true
DEPLOY_REDIS=true
POSTGRES_NAMESPACE="sap-eic-external-postgres"
REDIS_NAMESPACE="sap-eic-external-redis"
INSTANCE=""             # optional EIC instance name (multiple EIC systems on one cluster)
POSTGRES_VERSION="v17"
REDIS_CLUSTER_TYPE="standard"
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

Comprehensive deployment of all SAP EIC external services (PostgreSQL and Redis).

OPTIONS:
    --postgres-only                Deploy only PostgreSQL (skip Redis)
    --redis-only                   Deploy only Redis (skip PostgreSQL)
    -i, --instance NAME            EIC instance name (multiple EIC systems on one cluster).
                                   PostgreSQL gets an isolated database "edgedb-<name>" in the
                                   shared cluster; Redis gets its own namespace
                                   "sap-eic-external-redis-<name>". Takes precedence over the
                                   --postgres-namespace/--redis-namespace flags.
    --postgres-namespace NS        PostgreSQL namespace (default: sap-eic-external-postgres)
    --redis-namespace NS           Redis namespace (default: sap-eic-external-redis)
    --postgres-version VERSION     PostgreSQL version: v15, v16, v17 (default: v17)
    --redis-type TYPE              Redis cluster type: standard or ha (default: standard)
    --ocp-version VERSION          Specify OpenShift version for SCC
    -f, --force                    Skip all confirmation prompts (for automation)
    -d, --dry-run                  Show what would be deployed without actually deploying
    --skip-wait                    Skip waiting for all readiness checks
    -v, --verbose                  Enable verbose output
    -h, --help                     Display this help message

EXAMPLES:
    # Interactive deployment of both PostgreSQL and Redis
    $0

    # Force deployment without prompts (CI/CD)
    $0 --force

    # Dry-run to see what would be deployed
    $0 --dry-run

    # Deploy only PostgreSQL v16
    $0 --postgres-only --postgres-version v16

    # Deploy only Redis HA cluster
    $0 --redis-only --redis-type ha

    # Deploy with custom namespaces
    $0 --postgres-namespace my-postgres --redis-namespace my-redis

REQUIREMENTS:
    - oc CLI tool installed and configured
    - Cluster admin access
    - Helper scripts in edge-integration-cell/external-postgres/ and external-redis/

EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --postgres-only)
            DEPLOY_POSTGRES=true
            DEPLOY_REDIS=false
            shift
            ;;
        --redis-only)
            DEPLOY_POSTGRES=false
            DEPLOY_REDIS=true
            shift
            ;;
        --postgres-namespace)
            POSTGRES_NAMESPACE="$2"
            shift 2
            ;;
        --redis-namespace)
            REDIS_NAMESPACE="$2"
            shift 2
            ;;
        -i|--instance)
            INSTANCE="$2"
            shift 2
            ;;
        --postgres-version)
            POSTGRES_VERSION="$2"
            shift 2
            ;;
        --redis-type)
            REDIS_CLUSTER_TYPE="$2"
            shift 2
            ;;
        --ocp-version)
            OPENSHIFT_VERSION="$2"
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

# Human-readable deploy targets for the summary/confirmation output. In instance
# mode the Redis namespace is derived by deploy_redis.sh and PostgreSQL adds an
# isolated database inside the shared cluster, so reflect that instead of the
# default namespace values (which otherwise look misleading).
REDIS_TARGET_NS="$REDIS_NAMESPACE"
PG_DB_NOTE=""
if [[ -n "$INSTANCE" ]]; then
    REDIS_TARGET_NS="sap-eic-external-redis-$INSTANCE"
    PG_DB_NOTE=", database: edgedb-$INSTANCE"
fi

# Display banner
log HEADER "SAP EIC External Services Deployment Utility"

# Summary of what will be deployed
log INFO "Deployment Configuration:"
log INFO "  - PostgreSQL: $([ "$DEPLOY_POSTGRES" == "true" ] && echo "YES (namespace: $POSTGRES_NAMESPACE$PG_DB_NOTE, version: $POSTGRES_VERSION)" || echo "NO")"
log INFO "  - Redis: $([ "$DEPLOY_REDIS" == "true" ] && echo "YES (namespace: $REDIS_TARGET_NS, type: $REDIS_CLUSTER_TYPE)" || echo "NO")"
log INFO "  - Dry-run: $([ "$DRY_RUN" == "true" ] && echo "YES" || echo "NO")"
log INFO "  - Force mode: $([ "$FORCE" == "true" ] && echo "YES" || echo "NO")"
log INFO "  - Skip wait: $([ "$SKIP_WAIT" == "true" ] && echo "YES" || echo "NO")"

# Confirmation prompt
if [[ "$FORCE" != "true" && "$DRY_RUN" != "true" ]]; then
    echo ""
    log WARNING "⚠️  This operation will DEPLOY external services."
    echo -e "${YELLOW}Services to be deployed:${NC}"
    if [[ "$DEPLOY_POSTGRES" == "true" ]]; then
        echo "  ✓ PostgreSQL (namespace: $POSTGRES_NAMESPACE$PG_DB_NOTE, version: $POSTGRES_VERSION)"
    fi
    if [[ "$DEPLOY_REDIS" == "true" ]]; then
        echo "  ✓ Redis (namespace: $REDIS_TARGET_NS, type: $REDIS_CLUSTER_TYPE)"
    fi
    echo ""
    read -rp "Type 'DEPLOY' to confirm deployment: " confirmation
    if [[ "$confirmation" != "DEPLOY" ]]; then
        log INFO "Deployment cancelled by user."
        exit 0
    fi
fi

# Dry-run header
if [[ "$DRY_RUN" == "true" ]]; then
    log INFO "════════════════════════════════════════════════════════════════"
    log INFO "                    DRY-RUN MODE ENABLED"
    log INFO "         No resources will be actually deployed"
    log INFO "════════════════════════════════════════════════════════════════"
fi

# Deployment start time
START_TIME=$(date +%s)

# Track errors
ERRORS=0

# Deploy PostgreSQL
if [[ "$DEPLOY_POSTGRES" == "true" ]]; then
    log HEADER "Deploying PostgreSQL External Service"
    
    POSTGRES_SCRIPT="$SCRIPT_DIR/deploy_postgres.sh"
    if [[ ! -f "$POSTGRES_SCRIPT" ]]; then
        log ERROR "PostgreSQL deployment script not found: $POSTGRES_SCRIPT"
        ERRORS=$((ERRORS + 1))
    else
        DEPLOY_ARGS=(
            "--namespace" "$POSTGRES_NAMESPACE"
            "--version" "$POSTGRES_VERSION"
        )

        # An instance maps to an isolated database inside the shared cluster.
        if [[ -n "$INSTANCE" ]]; then
            DEPLOY_ARGS+=("--instance" "$INSTANCE")
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            DEPLOY_ARGS+=("--dry-run")
        fi

        if [[ "$FORCE" == "true" ]]; then
            DEPLOY_ARGS+=("--force")
        fi

        if [[ "$SKIP_WAIT" == "true" ]]; then
            DEPLOY_ARGS+=("--skip-wait")
        fi

        if [[ "$VERBOSE" == "true" ]]; then
            DEPLOY_ARGS+=("--verbose")
        fi

        if bash "$POSTGRES_SCRIPT" "${DEPLOY_ARGS[@]}"; then
            log SUCCESS "PostgreSQL deployment completed successfully"
        else
            log ERROR "PostgreSQL deployment failed"
            ERRORS=$((ERRORS + 1))
        fi
    fi
    echo ""
fi

# Deploy Redis
if [[ "$DEPLOY_REDIS" == "true" ]]; then
    log HEADER "Deploying Redis External Service"
    
    REDIS_SCRIPT="$SCRIPT_DIR/deploy_redis.sh"
    if [[ ! -f "$REDIS_SCRIPT" ]]; then
        log ERROR "Redis deployment script not found: $REDIS_SCRIPT"
        ERRORS=$((ERRORS + 1))
    else
        # An instance gets its own Redis namespace (derived by deploy_redis.sh);
        # otherwise use the explicit namespace as before.
        if [[ -n "$INSTANCE" ]]; then
            DEPLOY_ARGS=(
                "--instance" "$INSTANCE"
                "--type" "$REDIS_CLUSTER_TYPE"
            )
        else
            DEPLOY_ARGS=(
                "--namespace" "$REDIS_NAMESPACE"
                "--type" "$REDIS_CLUSTER_TYPE"
            )
        fi

        if [[ -n "$OPENSHIFT_VERSION" ]]; then
            DEPLOY_ARGS+=("--ocp-version" "$OPENSHIFT_VERSION")
        fi
        
        if [[ "$DRY_RUN" == "true" ]]; then
            DEPLOY_ARGS+=("--dry-run")
        fi
        
        if [[ "$FORCE" == "true" ]]; then
            DEPLOY_ARGS+=("--force")
        fi
        
        if [[ "$SKIP_WAIT" == "true" ]]; then
            DEPLOY_ARGS+=("--skip-wait")
        fi
        
        if [[ "$VERBOSE" == "true" ]]; then
            DEPLOY_ARGS+=("--verbose")
        fi
        
        if bash "$REDIS_SCRIPT" "${DEPLOY_ARGS[@]}"; then
            log SUCCESS "Redis deployment completed successfully"
        else
            log ERROR "Redis deployment failed"
            ERRORS=$((ERRORS + 1))
        fi
    fi
    echo ""
fi

# Get combined access details
if [[ "$DRY_RUN" != "true" && "$ERRORS" -eq 0 ]]; then
    if [[ "$DEPLOY_POSTGRES" == "true" || "$DEPLOY_REDIS" == "true" ]]; then
        log HEADER "Combined Access Details"
        if [[ -f "$SCRIPT_DIR/get_all_accesses.sh" ]]; then
            if [[ -n "$INSTANCE" ]]; then
                bash "$SCRIPT_DIR/get_all_accesses.sh" --instance "$INSTANCE" 2>/dev/null || log WARNING "Could not retrieve combined access details."
            else
                bash "$SCRIPT_DIR/get_all_accesses.sh" 2>/dev/null || log WARNING "Could not retrieve combined access details."
            fi
        fi
        echo ""
    fi
fi

# Deployment end time
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# Final summary
log HEADER "Deployment Summary"
log INFO "Total time: ${DURATION} seconds"

if [[ "$DRY_RUN" == "true" ]]; then
    log INFO "Dry-run completed. No resources were actually deployed."
elif [[ $ERRORS -eq 0 ]]; then
    log SUCCESS "✅ All deployment operations completed successfully!"
    echo ""
    log INFO "Deployed services:"
    if [[ "$DEPLOY_POSTGRES" == "true" ]]; then
        log INFO "  ✓ PostgreSQL: $POSTGRES_NAMESPACE$PG_DB_NOTE ($POSTGRES_VERSION)"
    fi
    if [[ "$DEPLOY_REDIS" == "true" ]]; then
        log INFO "  ✓ Redis: $REDIS_TARGET_NS ($REDIS_CLUSTER_TYPE)"
    fi
    echo ""
    log INFO "Next steps:"
    log INFO "  1. Use the access details above to configure SAP EIC"
    log INFO "  2. To cleanup all services: bash $SCRIPT_DIR/cleanup_all_external_services.sh"
else
    log ERROR "⚠️  Deployment completed with $ERRORS error(s)."
    exit 1
fi

