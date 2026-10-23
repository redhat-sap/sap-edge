#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-License-Identifier: Apache-2.0
# jq programs deliberately contain literal $variables, including in jq_helpers.
# shellcheck disable=SC2016

set -euo pipefail

POOL=worker
TIMEOUT=1800
POLL_INTERVAL=10
DRY_RUN=false
MCP=machineconfigpools.machineconfiguration.openshift.io
MC=machineconfigs.machineconfiguration.openshift.io
ROLE=machineconfiguration.openshift.io/role
CONFIG_PATH=/etc/crio/crio.conf.d/99-eic-nofile.conf
POOL_UID=
APPLIED_UID=
APPLIED_GENERATION=
EXPECTED=

usage() {
    cat <<'EOF'
Usage: bash edge-integration-cell/configure_worker_nofile.sh [OPTIONS]

Configure worker nofile limits before installing PostgreSQL, Redis and EIC.
Inspect every worker, patch CRI-O only if necessary, wait for the rollout,
and verify new containers receive at least nofile=4096:1048576 (soft:hard).

Options:
  --pool NAME              Worker MachineConfigPool and role label (default: worker)
  --timeout SECONDS        Total timeout (default: 1800)
  --poll-interval SECONDS  Rollout polling interval (default: 10)
  --dry-run                Inspect and validate without applying a MachineConfig
  -h, --help               Show this help

Requires Bash, oc, jq, awk, base64 and GNU timeout (or gtimeout), plus
cluster-admin access on self-managed OpenShift. Uses the current context
and KUBECONFIG. On macOS, GNU timeout is available in Homebrew coreutils.
Inspection creates temporary node debug pods, including during --dry-run.
Changing the MachineConfig can drain/reboot workers. No PDBs are changed.
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pool|--timeout|--poll-interval)
            [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "Missing value for $1"
            case "$1" in
                --pool) POOL=$2 ;;
                --timeout|--poll-interval)
                    [[ "$2" =~ ^[1-9][0-9]*$ && ${#2} -le 7 ]] || die "$1 must be a positive integer of at most 7 digits"
                    if [[ "$1" == --timeout ]]; then TIMEOUT=$2; else POLL_INTERVAL=$2; fi
                    ;;
            esac
            shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1 (see --help)" ;;
    esac
done
[[ "$POOL" != master && "$POOL" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || die "Select a worker pool, not the master pool"
for dependency in oc jq awk base64 mktemp; do
    command -v "$dependency" >/dev/null || die "Install $dependency first"
done
TIMEOUT_CMD=$(command -v timeout || command -v gtimeout) || die "Install GNU coreutils for timeout (or gtimeout)"
DEADLINE=$((SECONDS + TIMEOUT))
NAME="96-${POOL}-crio-limit-files"
umask 077
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/eic-nofile.XXXXXXXX")
trap 'rm -rf -- "$WORK_DIR"' EXIT
trap 'echo "Stopped. Any submitted MachineConfig remains in place; verify its rollout before proceeding." >&2; exit 130' INT TERM
CLI=(oc --request-timeout=30s)

# Bound CLI calls as well as rollout polling. SIGINT lets oc debug clean up
# its temporary pod; a stuck client is killed after a further ten seconds.
oc_call() {
    local remaining=$((DEADLINE - SECONDS)) status=0
    ((remaining > 0)) || die "Worker rollout timed out. Inspect oc describe mcp $POOL; setup is not complete"
    ((remaining <= 120)) || remaining=120
    "$TIMEOUT_CMD" --foreground --signal=INT --kill-after=10 "${remaining}s" "${CLI[@]}" "$@" || status=$?
    case "$status" in
        0) ;;
        124|137) die "Command timed out; inspect worker status and any remaining debug pods" ;;
        *) die "oc $1 failed (exit $status); setup is not complete" ;;
    esac
}

# JSON operations stay in jq; this script runs with Bash 3.2 or newer.
cat > "$WORK_DIR/nofile.jq" <<'JQ'
def matches($labels; $selector):
    ($selector != null and $selector != {}) and
    all(($selector.matchLabels // {} | to_entries)[]; $labels[.key] == .value) and
    all(($selector.matchExpressions // [])[];
        . as $e |
        if .operator == "In" then ($labels | has($e.key)) and (($e.values // []) | index($labels[$e.key])) != null
        elif .operator == "NotIn" then (($e.values // []) | index($labels[$e.key])) == null
        elif .operator == "Exists" then $labels | has($e.key)
        elif .operator == "DoesNotExist" then $labels | has($e.key) | not
        else error("Unsupported label selector operator") end);
def bound:
    if . == "unlimited" or . == "-1" then -1
    elif test("^[0-9]+$") then tonumber
    else error("Invalid ulimit value") end;
def at_least($a; $b): $a == -1 or ($b != -1 and $a >= $b);
def maximum: if index(-1) != null then -1 else max end;
def limits:
    if type != "array" then error("CRI-O default_ulimits is not an array") else . end |
    reduce .[] as $entry ({};
        (if ($entry | type) == "string" and ($entry | test("^[a-zA-Z0-9_]+=(-1|[0-9]+):(-1|[0-9]+)$"))
         then $entry | capture("^(?<name>[^=]+)=(?<soft>[^:]+):(?<hard>.+)$")
         else error("Unsupported CRI-O ulimit entry") end) as $p |
        if has($p.name) then error("Duplicate CRI-O ulimit: " + $p.name)
        elif at_least(($p.hard | bound); ($p.soft | bound)) | not then error("Soft ulimit exceeds hard ulimit")
        else .[$p.name] = [($p.soft | bound), ($p.hard | bound)] end);
def sufficient: at_least(.soft; 4096) and at_least(.hard; 1048576);
def converged($pool; $nodes):
    $pool.status as $s | $pool.spec.configuration.name as $desired | ($nodes | length) as $count |
    ($s.conditions | map({key: .type, value: .status}) | from_entries) as $conditions |
    $desired != null and ($s.observedGeneration // 0) >= $pool.metadata.generation and
    $s.configuration.name == $desired and $conditions.Updated == "True" and
    $conditions.Updating == "False" and $conditions.Degraded == "False" and
    $s.machineCount == $count and $s.readyMachineCount == $count and
    $s.updatedMachineCount == $count and ($s.unavailableMachineCount // 0) == 0 and
    all($nodes[];
        (.metadata.deletionTimestamp == null) and (.spec.unschedulable != true) and
        any(.status.conditions[]?; .type == "Ready" and .status == "True") and
        .metadata.annotations["machineconfiguration.openshift.io/state"] == "Done" and
        .metadata.annotations["machineconfiguration.openshift.io/currentConfig"] == $desired and
        .metadata.annotations["machineconfiguration.openshift.io/desiredConfig"] == $desired);
JQ

jq_helpers() { jq -L "$WORK_DIR" "$@"; }

load_state() {
    local uid degraded inventory
    POOL_JSON=$(oc_call get "$MCP" "$POOL" -o json)
    uid=$(jq -er '.metadata.uid' <<< "$POOL_JSON")
    [[ -z "$POOL_UID" || "$POOL_UID" == "$uid" ]] || die "MachineConfigPool was replaced; rerun the script"
    POOL_UID=$uid
    jq -e '.metadata.deletionTimestamp == null' <<< "$POOL_JSON" >/dev/null || die "MachineConfigPool is being deleted"
    jq -e '.spec.paused != true' <<< "$POOL_JSON" >/dev/null || die "MachineConfigPool is paused; resume it first"
    degraded=$(jq -r '[.status.conditions[]? | select((.type | endswith("Degraded")) and .status == "True") | (.message // .type)] | join("; ")' <<< "$POOL_JSON")
    [[ -z "$degraded" ]] || die "MachineConfigPool is degraded: $degraded"
    inventory=$(oc_call get nodes -o json)
    NODES_JSON=$(jq_helpers -c --argjson pool "$POOL_JSON" 'include "nofile";
        [.items[] | select(matches(.metadata.labels; $pool.spec.nodeSelector))]' <<< "$inventory")
    jq -e 'length > 0' <<< "$NODES_JSON" >/dev/null || die "The selected worker pool has no nodes"
    jq -e 'all(.[]; .metadata.labels | has("node-role.kubernetes.io/master") or has("node-role.kubernetes.io/control-plane") | not)' \
        <<< "$NODES_JSON" >/dev/null || die "This script targets worker-only nodes; control-plane nodes require separate configuration"
}

check_scope() {
    local pools selected
    pools=$(oc_call get "$MCP" -o json)
    selected=$(jq_helpers -c --arg role "$ROLE" --arg pool "$POOL" 'include "nofile";
        [.items[] | select(matches({($role): $pool}; .spec.machineConfigSelector)) | .metadata.uid]' <<< "$pools")
    jq -e --arg uid "$POOL_UID" '. == [$uid]' <<< "$selected" >/dev/null ||
        die "The role label must select only pool $POOL; it also affects another pool or does not select this pool. Configure custom pools separately with --pool"
}

converged() {
    jq_helpers -en --argjson pool "$POOL_JSON" --argjson nodes "$NODES_JSON" \
        'include "nofile"; converged($pool; $nodes)' >/dev/null
}

snapshot() {
    jq -cn --argjson pool "$POOL_JSON" --argjson nodes "$NODES_JSON" \
        '[$pool.spec.configuration.name, ($nodes | map(.metadata.uid) | sort)]'
}

assert_stable() {
    local before=$1
    load_state
    if ! converged || [[ $(snapshot) != "$before" ]]; then
        die "Worker state changed during inspection; wait for it and rerun"
    fi
}

target_file() {
    jq -c --arg path "$CONFIG_PATH" '[.spec.config.storage.files[]? | select(.path == $path)] |
        if length > 1 then error("Multiple entries manage the nofile file") else .[0] end' <<< "$1"
}

percent_decode() {
    local data=$1 result='' prefix hex byte
    while [[ "$data" == *%* ]]; do
        prefix=${data%%\%*}; result+=$prefix; data=${data#*%}; hex=${data:0:2}
        [[ "$hex" =~ ^[0-9a-fA-F]{2}$ && "$hex" != 00 ]] || die "Invalid percent encoding in nofile data URL"
        printf -v byte '%b' "\\x$hex"
        result+=$byte; data=${data:2}
    done
    printf '%s' "$result$data"
}

file_contents() {
    local source header data
    jq -e '(.contents.compression // "") == "" and ((.append // []) | length) == 0' <<< "$1" >/dev/null ||
        die "Compressed or appended nofile configuration requires manual review"
    source=$(jq -er '.contents.source' <<< "$1") || die "Expected inline data in the nofile MachineConfig"
    [[ "$source" == data:*,* ]] || die "Expected inline data in the nofile MachineConfig"
    header=${source%%,*}; data=$(percent_decode "${source#*,}") || return 1
    if [[ "$header" == *\;base64 ]]; then
        printf '%s' "$data" | base64 --decode || die "Invalid base64 nofile configuration"
    else
        printf '%s' "$data"
    fi
}

has_contents() {
    local file text
    file=$(target_file "$1") || die "Cannot inspect the nofile MachineConfig"
    [[ "$file" != null ]] || return 1
    text=$(file_contents "$file") || die "Cannot decode the nofile MachineConfig"
    [[ "$text" == "$EXPECTED" ]]
}

wait_ready() {
    local applied desired rendered remaining delay ready
    while ((SECONDS < DEADLINE)); do
        load_state
        ready=false
        if converged; then ready=true; fi
        if [[ -n "$APPLIED_UID" ]]; then
            applied=$(oc_call get "$MC" "$NAME" -o json)
            if ! jq -e --arg uid "$APPLIED_UID" --argjson generation "$APPLIED_GENERATION" \
                '.metadata.uid == $uid and .metadata.generation == $generation' <<< "$applied" >/dev/null ||
                ! has_contents "$applied"; then
                die "The nofile MachineConfig changed during rollout; inspect it before rerunning"
            fi
            if ! jq -e --arg name "$NAME" 'any(.spec.configuration.source[]?; .name == $name)' <<< "$POOL_JSON" >/dev/null; then
                ready=false
            fi
            if [[ "$ready" == true ]]; then
                desired=$(jq -er '.spec.configuration.name' <<< "$POOL_JSON")
                rendered=$(oc_call get "$MC" "$desired" -o json)
                if ! has_contents "$rendered"; then ready=false; fi
            fi
        fi
        [[ "$ready" != true ]] || return 0
        jq -r --arg pool "$POOL" '"Waiting for " + $pool + ": updated " + ((.status.updatedMachineCount // 0) | tostring) +
            "/" + ((.status.machineCount // 0) | tostring) + ", ready " + ((.status.readyMachineCount // 0) | tostring) +
            "; waiting for the requested configuration."' <<< "$POOL_JSON"
        remaining=$((DEADLINE - SECONDS)); delay=$POLL_INTERVAL
        ((delay <= remaining)) || delay=$remaining
        ((delay <= 0)) || sleep "$delay"
    done
    die "Worker rollout timed out. Run oc describe mcp $POOL and inspect machine-config-daemon logs; setup is not complete"
}

# CRI-O emits a TOML array of simple name=soft:hard strings. Parse only this
# supported grammar; do not source/evaluate configuration as shell code.
# Strict mode rejects other settings in an existing file before replacing it.
extract_defaults() {
    local strict=${1:-0} array
    array=$(awk -v strict="$strict" '
        function bad() { failed=1; exit 1 }
        {
            sub(/\r$/, ""); sub(/#.*/, ""); gsub(/^[ \t]+|[ \t]+$/, "")
            if ($0 == "") next
            if (collecting) {
                value=value " " $0
                if ($0 ~ /\]$/) collecting=0
                next
            }
            if ($0 ~ /^\[/) {
                runtime=($0 == "[crio.runtime]")
                if (runtime) runtime_seen++
                if (strict && !runtime && $0 != "[crio]") bad()
                next
            }
            if (runtime && $0 ~ /^default_ulimits[ \t]*=/) {
                if (++seen > 1) bad()
                sub(/^default_ulimits[ \t]*=[ \t]*/, ""); value=$0
                collecting=($0 !~ /\]$/)
            } else if (strict) bad()
        }
        END {
            if (failed || collecting || runtime_seen != 1 || (strict && seen != 1)) exit 1
            if (!seen) value="[]"
            gsub(/\047/, "\042", value)
            sub(/,[ \t]*\]$/, "]", value)
            print value
        }') || die "Unsupported CRI-O default_ulimits syntax or other settings in the nofile file; review it manually"
    jq_helpers -ce 'include "nofile"; . as $entries | limits | $entries' <<< "$array" ||
        die "Cannot parse CRI-O default_ulimits safely"
}

PROBE=$(cat <<'SH'
crio_error=$(mktemp)
trap 'rm -f "$crio_error"' EXIT
printf 'EIC_NOFILE_CHECK_V1\n'
ulimit -Sn
ulimit -Hn
printf 'EIC_CRIO_CONFIG_V1\n'
if ! timeout 20 chroot /host crio status config 2>"$crio_error"; then
    cat "$crio_error" >&2
    exit 1
fi
printf '\nEIC_NOFILE_CHECK_END\n'
SH
)

inspect() {
    local node output body soft hard defaults probe
    : > "$WORK_DIR/probes.jsonl"
    jq -r '.[].metadata.name' <<< "$NODES_JSON" > "$WORK_DIR/nodes"
    while IFS= read -r node; do
        echo "Inspecting container limits and running CRI-O configuration on $node ..."
        output=$(oc_call debug "node/$node" --quiet -- sh -ceu "$PROBE")
        output=${output//$'\r'/}
        [[ "$output" == *$'EIC_NOFILE_CHECK_V1\n'* && "$output" == *$'\nEIC_NOFILE_CHECK_END'* ]] || die "Incomplete node inspection output"
        body=${output#*$'EIC_NOFILE_CHECK_V1\n'}; body=${body%%$'\nEIC_NOFILE_CHECK_END'*}
        soft=${body%%$'\n'*}; body=${body#*$'\n'}
        hard=${body%%$'\n'*}; body=${body#*$'\n'}
        [[ "$body" == EIC_CRIO_CONFIG_V1$'\n'* ]] || die "Invalid nofile readings from debug container"
        defaults=$(extract_defaults <<< "${body#*$'\n'}")
        probe=$(jq_helpers -cn --arg soft "$soft" --arg hard "$hard" --argjson defaults "$defaults" 'include "nofile";
            {soft: ($soft | bound), hard: ($hard | bound), defaults: $defaults, limits: ($defaults | limits)}')
        printf '%s\n' "$probe" >> "$WORK_DIR/probes.jsonl"
        echo "$node: nofile soft=$soft, hard=$hard"
    done < "$WORK_DIR/nodes"
    PROBES=$(jq -sc . "$WORK_DIR/probes.jsonl")
}

plan() {
    local configs conflicting existing old old_text old_defaults source file
    ENTRIES=$(jq_helpers -ce 'include "nofile";
        (map(.limits | del(.nofile)) | unique | length) as $variants |
        if $variants != 1 then error("Workers have different non-nofile ulimits; review before applying a common override") else . end |
        ([4096] + map(.soft) + map(.limits.nofile[0] // 0) | maximum) as $soft |
        ([1048576, $soft] + map(.hard) + map(.limits.nofile[1] // 0) | maximum) as $hard |
        (.[0].defaults | map(select(startswith("nofile=") | not))) + ["nofile=\($soft):\($hard)"]' <<< "$PROBES")
    EXPECTED=$(printf '[crio.runtime]\ndefault_ulimits = %s\n' "$ENTRIES")
    source=$(printf '%s\n' "$EXPECTED" | base64 | tr -d '\r\n')
    file=$(jq -cn --arg path "$CONFIG_PATH" --arg source "data:;base64,$source" \
        '{path: $path, mode: 420, overwrite: true, contents: {source: $source}}')
    configs=$(oc_call get "$MC" -o json)
    conflicting=$(jq_helpers -r --argjson pool "$POOL_JSON" --arg name "$NAME" --arg path "$CONFIG_PATH" 'include "nofile";
        .items[] | select(.metadata.name != $name and matches(.metadata.labels; $pool.spec.machineConfigSelector)) |
        select(any(.spec.config.storage.files[]?; .path == $path)) | .metadata.name' <<< "$configs")
    [[ -z "$conflicting" ]] || die "$CONFIG_PATH is already managed by $conflicting; review that config"
    existing=$(oc_call get "$MC" "$NAME" --ignore-not-found -o json)
    if [[ -z "$existing" ]]; then
        jq -n --arg name "$NAME" --arg role "$ROLE" --arg pool "$POOL" --argjson file "$file" '
            {apiVersion: "machineconfiguration.openshift.io/v1", kind: "MachineConfig",
             metadata: {name: $name, labels: {($role): $pool}},
             spec: {config: {ignition: {version: "3.2.0"}, storage: {files: [$file]}}}}' > "$WORK_DIR/payload.json"
        APPLY_ARGS=(create -f - -o json)
    else
        jq -e --arg role "$ROLE" --arg pool "$POOL" '.metadata.labels[$role] == $pool' <<< "$existing" >/dev/null ||
            die "Existing MachineConfig has an unexpected role; refusing to retarget it"
        old=$(target_file "$existing")
        if [[ "$old" != null ]]; then
            old_text=$(file_contents "$old")
            old_defaults=$(extract_defaults 1 <<< "$old_text")
            if jq_helpers -en --argjson old "$old_defaults" --argjson new "$ENTRIES" \
                'include "nofile"; ($old | limits) == ($new | limits)' >/dev/null; then
                die "MachineConfig already requests these limits, but containers still receive lower limits. Inspect CRI-O overrides"
            fi
        fi
        jq --arg path "$CONFIG_PATH" --argjson file "$file" '
            .spec.config as $config | ($config.storage.files // []) as $files |
            ($config | .storage.files = (if any($files[]; .path == $path)
                then $files | map(if .path == $path then $file else . end) else $files + [$file] end)) as $updated |
            [{op: "test", path: "/metadata/uid", value: .metadata.uid},
             {op: "test", path: "/metadata/resourceVersion", value: .metadata.resourceVersion},
             {op: "replace", path: "/spec/config", value: $updated}]' <<< "$existing" > "$WORK_DIR/payload.json"
        APPLY_ARGS=(patch "$MC" "$NAME" --type=json --patch-file=/dev/stdin -o json)
    fi
}

CONTEXT=$(oc_call config current-context)
[[ -n "$CONTEXT" ]] || die "No current Kubernetes context is selected"
CLI+=(--context "$CONTEXT")
echo "Context: $CONTEXT; worker pool: $POOL"
echo "Checking nofile >= 4096:1048576. Run this before installing PostgreSQL, Redis and EIC."
echo "Inspection uses temporary node debug pods. A configuration change may drain/reboot workers."
load_state
check_scope
wait_ready
BEFORE=$(snapshot)
inspect
if jq_helpers -e 'include "nofile"; all(.[]; sufficient)' <<< "$PROBES" >/dev/null; then
    assert_stable "$BEFORE"
    echo "No patch needed: all workers already meet the nofile requirements."
else
    plan
    echo "Required CRI-O defaults (existing other limits preserved): $ENTRIES"
    PREVIEW=$(oc_call "${APPLY_ARGS[@]}" --dry-run=server < "$WORK_DIR/payload.json")
    has_contents "$PREVIEW" || die "Server dry-run did not retain the intended nofile configuration"
    if [[ "$DRY_RUN" == true ]]; then
        echo "Dry run complete: would apply $NAME, wait for workers, and verify fresh container limits."
        exit 0
    fi
    assert_stable "$BEFORE"
    APPLIED=$(oc_call "${APPLY_ARGS[@]}" < "$WORK_DIR/payload.json")
    APPLIED_UID=$(jq -er '.metadata.uid' <<< "$APPLIED")
    APPLIED_GENERATION=$(jq -er '.metadata.generation' <<< "$APPLIED")
    echo "Applied $NAME. Waiting for the worker rollout ..."
    wait_ready
    BEFORE=$(snapshot)
    inspect
    jq_helpers -e --argjson entries "$ENTRIES" 'include "nofile";
        ($entries | limits) as $wanted | all(.[]; sufficient and .limits == $wanted)' <<< "$PROBES" >/dev/null ||
        die "Workers updated, but runtime limits did not match the requested values; inspect conflicting CRI-O configuration"
    assert_stable "$BEFORE"
fi
if [[ "$DRY_RUN" == true ]]; then
    echo "Dry run complete. No MachineConfig changes were needed."
else
    echo "All done: all $(jq length <<< "$NODES_JSON") workers are Ready and verified with nofile >= 4096:1048576."
    echo "You can now continue with PostgreSQL, Redis and EIC installation."
fi
