#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-License-Identifier: Apache-2.0
# cspell:words TMPDIR pids Xvfb nolisten xdpyinfo openbox portforward rfbport nopw websockify novnc

set -euo pipefail
umask 077
# HCP defaults: port-forward access and pipeline.mjs. ROKS sets route + roks-pipeline.mjs.
access="${SAP_BROWSER_ACCESS:-port-forward}"
entry="${SAP_BROWSER_ENTRY:-pipeline.mjs}"
if [[ "$access" != port-forward && "$access" != route ]]; then
  echo 'SAP_BROWSER_ACCESS must be port-forward or route.' >&2
  exit 1
fi
if [[ ! "$entry" =~ ^[a-z0-9-]+\.mjs$ ]]; then
  echo 'SAP_BROWSER_ENTRY must name an .mjs file in the helper directory.' >&2
  exit 1
fi
export SAP_BROWSER_SESSION_DIR=/tmp/sap-browser-session
export DISPLAY=:99
export XDG_RUNTIME_DIR="$SAP_BROWSER_SESSION_DIR/xdg-runtime"
export XDG_CONFIG_HOME="$SAP_BROWSER_SESSION_DIR/xdg-config"
export XDG_CACHE_HOME="$SAP_BROWSER_SESSION_DIR/xdg-cache"
export TMPDIR="$SAP_BROWSER_SESSION_DIR"
mkdir -m 700 "$SAP_BROWSER_SESSION_DIR"
mkdir -m 700 "$XDG_RUNTIME_DIR" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"
pids=()
# Called indirectly by the EXIT trap; older ShellCheck versions miss that call.
# shellcheck disable=SC2317,SC2329
cleanup() {
  trap - EXIT INT TERM
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  for ((attempt=0; attempt<30; attempt++)); do
    alive=false
    for pid in "${pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then alive=true; fi
    done
    if [[ "$alive" == false ]]; then break; fi
    sleep 0.1
  done
  for pid in "${pids[@]}"; do kill -KILL "$pid" 2>/dev/null || true; done
  wait || true
  rm -rf "$SAP_BROWSER_SESSION_DIR"
}
trap 'cleanup' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# Run the helper from the same checked-out revision as the pipeline. Dependencies
# stay in the built image; no npm install or downloads occur during the task.
helper_source=/opt/sap-browser
if [[ "${SAP_BROWSER_SOURCE_BOUND:-false}" == true ]]; then helper_source="$SAP_BROWSER_SOURCE"; fi
mkdir "$SAP_BROWSER_SESSION_DIR/code"
tar --exclude=node_modules -C "$helper_source" -cf - . | tar -C "$SAP_BROWSER_SESSION_DIR/code" -xf -
ln -s /opt/sap-browser/node_modules "$SAP_BROWSER_SESSION_DIR/code/node_modules"

Xvfb "$DISPLAY" -screen 0 1440x900x24 -nolisten tcp -ac >"$SAP_BROWSER_SESSION_DIR/display.log" 2>&1 &
pids+=("$!")
for ((attempt=0; attempt<50; attempt++)); do
  if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
if ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
  echo 'Virtual display failed to start.' >&2
  exit 1
fi
openbox --sm-disable >"$SAP_BROWSER_SESSION_DIR/window-manager.log" 2>&1 &
pids+=("$!")
# Both listeners are loopback-only. port-forward access requires authenticated
# Kubernetes pods/portforward permission. route access goes through the OAuth-proxy
# sidecar, which checks the same permission; this script creates no Service or Route.
x11vnc -display "$DISPLAY" -localhost -rfbport 5900 -forever -shared -nopw \
  >"$SAP_BROWSER_SESSION_DIR/vnc.log" 2>&1 &
pids+=("$!")
websockify --web /usr/share/novnc 127.0.0.1:6080 127.0.0.1:5900 \
  >"$SAP_BROWSER_SESSION_DIR/web.log" 2>&1 &
pids+=("$!")

# With route access the Node entry prints the Route link instead.
if [[ "$access" == port-forward ]]; then
  printf 'From your Citrix terminal (logged into the pipeline cluster):\n'
  printf 'oc -n %s port-forward pod/%s 6080:6080\n' "$PIPELINE_NAMESPACE" "$POD_NAME"
  printf 'Then open http://127.0.0.1:6080/vnc.html in the browser on that same Citrix desktop.\n'
  printf 'Session status:\n'
  printf 'oc -n %s exec %s -c step-browser -- node /opt/sap-browser/control.mjs status\n' "$PIPELINE_NAMESPACE" "$POD_NAME"
  printf 'After review, finish the session from a second Citrix terminal:\n'
  printf 'oc -n %s exec %s -c step-browser -- node /opt/sap-browser/control.mjs finish\n' "$PIPELINE_NAMESPACE" "$POD_NAME"
fi

node "$SAP_BROWSER_SESSION_DIR/code/$entry" &
runner_pid=$!
pids+=("$runner_pid")
# If a display/proxy process dies, fail the task instead of leaving login stuck.
set +e
finished_pid=''
wait -n -p finished_pid "${pids[@]}"
exit_code=$?
set -e
if [[ "$finished_pid" != "$runner_pid" ]]; then
  echo 'A browser display service stopped unexpectedly.' >&2
  exit 1
fi
exit "$exit_code"
