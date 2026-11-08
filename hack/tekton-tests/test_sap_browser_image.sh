#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-FileContributor: Manjun Jiao (@mjiao)
# SPDX-License-Identifier: Apache-2.0
# cspell:words authfile hashlib hexdigest repr

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=./lib.sh disable=SC1091
source lib.sh

echo "============================================"
echo "Test: sap-browser-image task"
echo "============================================"

TASK=../../.tekton/tasks/sap-browser-image-task.yaml
REPOSITORY=quay.apps.eic.ocp.sap.local/sap_elm_eic/sap-browser
REGISTRY_HOST=quay.apps.eic.ocp.sap.local
ROBOT_USER='sap_elm_eic+pipeline'
ROBOT_PASSWORD='FAKE-ROBOT-PASSWORD-0123'
POD=pod/sap-browser-pull-check-x1y2z
STEPS=(compute-tag check-tag build-and-push pull-check)

[[ -f "${TASK}" ]] || fail "${TASK} not found"

# Workspace: a git checkout with the files the tag covers
make_workspace() {
  WS=$(tmp_dir)
  mkdir -p "${WS}/hack/sap-browser" "${WS}/hack/other"
  printf '{"lockfileVersion": 3}\n' > "${WS}/package-lock.json"
  printf 'FROM node:24-bookworm-slim\n' > "${WS}/hack/sap-browser/Containerfile"
  printf 'console.log("flow")\n' > "${WS}/hack/sap-browser/elm-flow.mjs"
  printf 'echo other\n' > "${WS}/hack/other/script.sh"
  printf '{"name": "sap-edge"}\n' > "${WS}/package.json"
  git -C "${WS}" init -q
  git -C "${WS}" add -A
}

# Fresh state, fakes and workspace for one task run
setup() {
  make_workspace
  ALL_OUT=""
  FAKE_OC_LOG=$(tmp_file)
  FAKE_OC_RULES=$(tmp_file)
  FAKE_OC_STDIN_DIR=$(tmp_dir)
  FAKE_TOOL_LOG=$(tmp_file)
  export FAKE_OC_LOG FAKE_OC_RULES FAKE_OC_STDIN_DIR FAKE_TOOL_LOG
  RESULTS_DIR=$(tmp_dir)
  STATE_DIR=$(tmp_dir)
  CERT_DIR=$(tmp_dir)
  printf -- '-----BEGIN CERTIFICATE-----\nFAKE\n-----END CERTIFICATE-----\n' > "${CERT_DIR}/ca.crt"
  MODE=auto
  IMAGE=""
  FAKE_SKOPEO_RC=0
  FAKE_SKOPEO_STDERR=""
  FAKE_BUILDAH_RC=0
  FAKE_BUILDAH_PUSH_RC=0
  export FAKE_SKOPEO_RC FAKE_SKOPEO_STDERR FAKE_BUILDAH_RC FAKE_BUILDAH_PUSH_RC
  REGISTRY_USERNAME="${ROBOT_USER}"
  REGISTRY_PASSWORD="${ROBOT_PASSWORD}"
}

# Fake skopeo and buildah: log the call; exit codes from FAKE_SKOPEO_RC,
# FAKE_BUILDAH_RC (build) and FAKE_BUILDAH_PUSH_RC (push)
FAKE_TOOLS_DIR=$(tmp_dir)
for TOOL in skopeo buildah; do
  cat > "${FAKE_TOOLS_DIR}/${TOOL}" <<'EOF'
#!/usr/bin/env bash
TOOL=$(basename "$0")
echo "${TOOL} $*" >> "${FAKE_TOOL_LOG}"
if [[ "${TOOL}" == "skopeo" ]]; then
  [[ -z "${FAKE_SKOPEO_STDERR}" ]] || echo "${FAKE_SKOPEO_STDERR}" >&2
  exit "${FAKE_SKOPEO_RC}"
fi
if [[ " $* " == *" push "* ]]; then
  exit "${FAKE_BUILDAH_PUSH_RC}"
fi
exit "${FAKE_BUILDAH_RC}"
EOF
  chmod +x "${FAKE_TOOLS_DIR}/${TOOL}"
done
# Package installs and downloads fail loudly: the tests drop the install sections
for TOOL in dnf curl tar; do
  cat > "${FAKE_TOOLS_DIR}/${TOOL}" <<'EOF'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >> "${FAKE_TOOL_LOG}"
exit 1
EOF
  chmod +x "${FAKE_TOOLS_DIR}/${TOOL}"
done

# Run one step (the step env as in the Task; extract_task_script.py
# substitutes params in the script only). Extra args go to run_task.
export_step_env() {
  export SAP_BROWSER_MODE="${MODE}" RUNNER_IMAGE="${IMAGE}" IMAGE_REPOSITORY="${REPOSITORY}" \
    PUSH_SECRET_NAME=eic-quay-robot STATE_DIR REGISTRY_CERT_DIR="${CERT_DIR}" \
    REGISTRY_USERNAME REGISTRY_PASSWORD
}

run_step() {
  local STEP="$1"
  shift
  export_step_env
  PATH="${FAKE_TOOLS_DIR}:${PATH}" TASK_CWD="${WS}" run_task "${TASK}" \
    --step "${STEP}" \
    --param mode="${MODE}" \
    --param image="${IMAGE}" \
    --param repository="${REPOSITORY}" \
    --param pushSecretName=eic-quay-robot \
    --workspace-dir source="${WS}" \
    --results-dir "${RESULTS_DIR}" \
    --drop '# Install tools' 'echo "✅ Tools installed"' \
    "$@"
}

# Run every step in order like the TaskRun: stop at the first failing step
# (none may fail: a failure only empties the result)
run_all() {
  local STEP
  ALL_OUT=""
  for STEP in "${STEPS[@]}"; do
    run_step "${STEP}"
    ALL_OUT+="${TASK_OUT}"$'\n'
    [[ "${TASK_RC}" -eq 0 ]] || return 0
  done
}

expect_success() {
  if [[ "${TASK_RC}" -ne 0 ]]; then
    echo "${ALL_OUT:-${TASK_OUT}}"
    fail "expected exit 0, got ${TASK_RC}"
  fi
}

result() {
  cat "${RESULTS_DIR}/$1" 2>/dev/null || true
}

# A failure never fails the run: every step exits 0, the result is written and
# empty (the browser tasks are skipped), and the log says so
expect_no_image() {
  local WHAT="$1"
  if [[ "${TASK_RC}" -ne 0 ]]; then
    echo "${ALL_OUT:-${TASK_OUT}}"
    fail "${WHAT}: the task must exit 0, got ${TASK_RC}"
  fi
  [[ -f "${RESULTS_DIR}/image" ]] || fail "${WHAT}: image result not written"
  [[ -z "$(result image)" ]] || fail "${WHAT}: image should be empty, got '$(result image)'"
  [[ -f "${STATE_DIR}/failed" ]] || fail "${WHAT}: later steps are not told to skip"
  grep -qF "No SAP browser runner image: the browser tasks are skipped and the run continues on the manual path" <<< "${ALL_OUT:-${TASK_OUT}}" \
    || { echo "${ALL_OUT:-${TASK_OUT}}"; fail "${WHAT}: manual path not announced"; }
}

# Expected tag: first 12 hex of sha256 over the sorted "sha256  path" lines
# of the tracked files package-lock.json and hack/sap-browser/**
expected_image() {
  python3 -I - "${WS}" "${REPOSITORY}" <<'PY'
import hashlib
import subprocess
import sys

ws, repository = sys.argv[1], sys.argv[2]
paths = subprocess.run(
    ["git", "-C", ws, "ls-files", "-z", "--", "package-lock.json", "hack/sap-browser"],
    check=True, capture_output=True,
).stdout.decode().split("\0")
lines = ""
for path in sorted(p for p in paths if p):
    with open(f"{ws}/{path}", "rb") as f:
        lines += f"{hashlib.sha256(f.read()).hexdigest()}  {path}\n"
print(f"{repository}:sap-browser-{hashlib.sha256(lines.encode()).hexdigest()[:12]}")
PY
}

# Healthy pull check: the Pod is created and succeeds
write_pod_rules() {
  printf '%s\t%s\t%s\n' \
    "create -f - -o name" 0 "${POD}" \
    "get ${POD} -o jsonpath=*" 0 "$1" \
    > "${FAKE_OC_RULES}"
}

no_secrets_leaked() {
  ! grep -qF "${ROBOT_PASSWORD}" <<< "${ALL_OUT:-${TASK_OUT}}" || fail "the robot password was printed"
  ! grep -qF "${ROBOT_PASSWORD}" "${FAKE_TOOL_LOG}" || fail "the robot password was passed on a command line"
}

# Test case: task_definition
echo ""
echo "Test: task_definition"
echo "--------------------------------------------"
python3 -I - "${TASK}" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    task = next(d for d in yaml.safe_load_all(f) if d and d.get("kind") == "Task")

errors = []
MISSING = object()
spec = task["spec"]
if task["metadata"]["name"] != "sap-browser-image":
    errors.append("task must be named sap-browser-image")
params = {p["name"]: p.get("default", MISSING) for p in spec["params"]}
expected = {
    "mode": MISSING,
    "image": "",
    "repository": "quay.apps.eic.ocp.sap.local/sap_elm_eic/sap-browser",
    "pushSecretName": "eic-quay-robot",
}
if params.keys() != expected.keys():
    errors.append(f"params differ: {sorted(params)} vs {sorted(expected)}")
for name, default in expected.items():
    if name in params and params[name] is not default and params[name] != default:
        errors.append(f"param {name}: default should be {'<none>' if default is MISSING else repr(default)}, got {params[name]!r}")
if [r["name"] for r in spec.get("results", [])] != ["image"]:
    errors.append("expected exactly the result image")
if [w["name"] for w in spec.get("workspaces", [])] != ["source"]:
    errors.append("expected exactly the workspace 'source' (build context)")
steps = {s["name"]: s for s in spec["steps"]}
if list(steps) != ["compute-tag", "check-tag", "build-and-push", "pull-check"]:
    errors.append(f"unexpected steps {list(steps)}")
for step in spec["steps"]:
    script = step.get("script", "")
    if not script.startswith("#!/usr/bin/env bash\nset -euo pipefail\n") or "set -x" in script:
        errors.append(f"step {step['name']}: script must start with the bash shebang and set -euo pipefail, no set -x")
env = {}
for step in [spec.get("stepTemplate", {})] + spec["steps"]:
    for e in step.get("env", []):
        env[e["name"]] = e
for name in ("REGISTRY_USERNAME", "REGISTRY_PASSWORD"):
    ref = env.get(name, {}).get("valueFrom", {}).get("secretKeyRef", {})
    # optional: with mode disabled or a given image the Secret is not needed
    if ref.get("name") != "$(params.pushSecretName)" or ref.get("optional") is not True:
        errors.append(f"env {name} must come from an optional secretKeyRef on $(params.pushSecretName), got {ref}")
volumes = {v["name"]: v for v in spec.get("volumes", [])}
ca = [v for v in volumes.values() if v.get("secret", {}).get("secretName") == "$(params.pushSecretName)"]
if len(ca) != 1 or ca[0]["secret"].get("optional") is not True or ca[0]["secret"].get("items") != [{"key": "ca.crt", "path": "ca.crt"}]:
    errors.append(f"expected one optional Secret volume with only ca.crt of $(params.pushSecretName), got {ca}")
build = steps.get("build-and-push", {})
if not build.get("image", "").startswith("registry.redhat.io/rhel9/buildah"):
    errors.append("build-and-push must use registry.redhat.io/rhel9/buildah")
if "--storage-driver=vfs" not in build.get("script", ""):
    errors.append("buildah must use --storage-driver=vfs (no overlay mounts under the pipeline SA)")
if build.get("securityContext") != {"capabilities": {"add": ["SETFCAP"]}}:
    errors.append("build-and-push needs exactly the SETFCAP capability (as the Red Hat buildah task; allowed by pipelines-scc)")
if not steps.get("check-tag", {}).get("image", "").startswith("registry.redhat.io/rhel9/skopeo"):
    errors.append("check-tag must use registry.redhat.io/rhel9/skopeo")
if errors:
    print("\n".join(errors))
    sys.exit(1)
PY
echo "✅ PASS: task_definition"

# Test case: disabled_returns_empty
echo ""
echo "Test: disabled_returns_empty"
echo "--------------------------------------------"
setup
MODE=disabled
REGISTRY_USERNAME=""
REGISTRY_PASSWORD=""
# No --drop for the first step: the install section must not be reached either
export_step_env
PATH="${FAKE_TOOLS_DIR}:${PATH}" TASK_CWD="${WS}" run_task "${TASK}" --step compute-tag \
  --param mode=disabled --param image="" --param repository="${REPOSITORY}" --param pushSecretName=eic-quay-robot \
  --workspace-dir source="${WS}" --results-dir "${RESULTS_DIR}"
expect_success
run_all
expect_success
[[ -f "${RESULTS_DIR}/image" ]] || fail "image result not written"
[[ -z "$(result image)" ]] || fail "image should be empty, got '$(result image)'"
[[ ! -s "${FAKE_OC_LOG}" ]] || fail "oc must not be called: $(cat "${FAKE_OC_LOG}")"
[[ ! -s "${FAKE_TOOL_LOG}" ]] || fail "no tool may run: $(cat "${FAKE_TOOL_LOG}")"
grep -qF "browser automation disabled" <<< "${ALL_OUT}" || { echo "${ALL_OUT}"; fail "disabled message not printed"; }
echo "✅ PASS: disabled_returns_empty"

# Test case: given_image_passes_through
echo ""
echo "Test: given_image_passes_through"
echo "--------------------------------------------"
setup
IMAGE=registry.example.com/team/sap-browser:dev-7
REGISTRY_USERNAME=""
REGISTRY_PASSWORD=""
run_all
expect_success
[[ "$(result image)" == "${IMAGE}" ]] || fail "image should be '${IMAGE}', got '$(result image)'"
[[ ! -s "${FAKE_OC_LOG}" ]] || fail "oc must not be called: $(cat "${FAKE_OC_LOG}")"
[[ ! -s "${FAKE_TOOL_LOG}" ]] || fail "no tool may run: $(cat "${FAKE_TOOL_LOG}")"
echo "✅ PASS: given_image_passes_through"

# Test case: tag_from_content_hash
echo ""
echo "Test: tag_from_content_hash"
echo "--------------------------------------------"
candidate() {
  cat "${STATE_DIR}/candidate" 2>/dev/null || true
}
setup
run_step compute-tag
expect_success
WANT=$(expected_image)
[[ "$(candidate)" =~ ^${REPOSITORY}:sap-browser-[0-9a-f]{12}$ ]] || fail "unexpected image '$(candidate)'"
[[ "$(candidate)" == "${WANT}" ]] || { echo "${TASK_OUT}"; fail "image should be '${WANT}', got '$(candidate)'"; }
# Not the result yet: only an image in the registry (checked or pushed and pulled) is
[[ -f "${RESULTS_DIR}/image" && -z "$(result image)" ]] || fail "compute-tag must leave the result empty, got '$(result image)'"
FIRST="${WANT}"
# Untracked files and files outside the covered paths do not change the tag
printf 'scratch\n' > "${WS}/hack/sap-browser/untracked.txt"
printf 'echo changed\n' > "${WS}/hack/other/script.sh"
printf '{"name": "changed"}\n' > "${WS}/package.json"
run_step compute-tag
expect_success
[[ "$(candidate)" == "${FIRST}" ]] || fail "untracked or uncovered files changed the tag: '$(candidate)'"
# A covered file changes the tag
printf 'console.log("flow v2")\n' > "${WS}/hack/sap-browser/elm-flow.mjs"
run_step compute-tag
expect_success
[[ "$(candidate)" != "${FIRST}" ]] || fail "a change in hack/sap-browser must change the tag"
[[ "$(candidate)" == "$(expected_image)" ]] || fail "image should be '$(expected_image)', got '$(candidate)'"
printf '{"lockfileVersion": 3, "x": 1}\n' > "${WS}/package-lock.json"
SECOND="$(candidate)"
run_step compute-tag
expect_success
[[ "$(candidate)" != "${SECOND}" ]] || fail "a change in package-lock.json must change the tag"
# The repository is validated (it ends up in a Pod manifest)
setup
REPOSITORY_SAVED="${REPOSITORY}"
REPOSITORY='quay.example.com/x y'
run_step compute-tag
REPOSITORY="${REPOSITORY_SAVED}"
expect_no_image "invalid repository"
grep -qF "Invalid repository" <<< "${TASK_OUT}" || { echo "${TASK_OUT}"; fail "repository error not named"; }
echo "✅ PASS: tag_from_content_hash"

# Test case: existing_tag_skips_build
echo ""
echo "Test: existing_tag_skips_build"
echo "--------------------------------------------"
setup
run_all
expect_success
WANT=$(expected_image)
[[ "$(result image)" == "${WANT}" ]] || fail "image should be '${WANT}', got '$(result image)'"
grep -qE "^skopeo inspect --raw --authfile ${STATE_DIR}/auth.json --cert-dir ${CERT_DIR} docker://${WANT}$" "${FAKE_TOOL_LOG}" \
  || { cat "${FAKE_TOOL_LOG}"; fail "tag not checked with skopeo inspect"; }
# The authfile holds the robot credentials for the registry host, readable only by the step user
python3 -I - "${STATE_DIR}/auth.json" "${REGISTRY_HOST}" "${ROBOT_USER}:${ROBOT_PASSWORD}" <<'PY' || fail "authfile content"
import base64, json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    auths = json.load(f)["auths"]
assert list(auths) == [sys.argv[2]], auths.keys()
assert base64.b64decode(auths[sys.argv[2]]["auth"]).decode() == sys.argv[3]
PY
[[ "$(python3 -I -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "${STATE_DIR}/auth.json")" == "0o600" ]] || fail "authfile must be mode 600"
! grep -q "^buildah" "${FAKE_TOOL_LOG}" || fail "buildah must not run for an existing tag"
[[ ! -s "${FAKE_OC_LOG}" ]] || fail "no pull check for an existing tag: $(cat "${FAKE_OC_LOG}")"
grep -qF "already in the registry" <<< "${ALL_OUT}" || { echo "${ALL_OUT}"; fail "skip message not printed"; }
no_secrets_leaked
echo "✅ PASS: existing_tag_skips_build"

# Test case: missing_tag_builds_pushes_and_pull_checks
echo ""
echo "Test: missing_tag_builds_pushes_and_pull_checks"
echo "--------------------------------------------"
setup
FAKE_SKOPEO_RC=1
FAKE_SKOPEO_STDERR="time=\"2026-11-08T10:00:00Z\" level=fatal msg=\"Error parsing image name: reading manifest sap-browser-0123456789ab in ${REPOSITORY}: manifest unknown\""
write_pod_rules 'Succeeded||'
run_all
expect_success
WANT=$(expected_image)
[[ "$(result image)" == "${WANT}" ]] || fail "image should be '${WANT}', got '$(result image)'"
grep -qE "^buildah --storage-driver=vfs build --file hack/sap-browser/Containerfile --tag ${WANT} ${WS}$" "${FAKE_TOOL_LOG}" \
  || { cat "${FAKE_TOOL_LOG}"; fail "image not built from hack/sap-browser/Containerfile with the repository root as context"; }
grep -qE "^buildah --storage-driver=vfs push --authfile ${STATE_DIR}/auth.json --cert-dir ${CERT_DIR} ${WANT} docker://${WANT}$" "${FAKE_TOOL_LOG}" \
  || { cat "${FAKE_TOOL_LOG}"; fail "image not pushed with the robot authfile and the registry CA"; }
# Pull check: a short-lived Pod runs the image with a trivial command, then is deleted
assert_called "^create -f - -o name$"
assert_called "^get ${POD} -o jsonpath="
assert_called "^delete ${POD} --ignore-not-found --wait=false$"
python3 -I - "${FAKE_OC_STDIN_DIR}/1.yaml" "${WANT}" <<'PY' || fail "pull-check Pod manifest"
import sys
import yaml
with open(sys.argv[1], encoding="utf-8") as f:
    pod = yaml.safe_load(f)
errors = []
if pod.get("kind") != "Pod" or pod["metadata"].get("generateName") != "sap-browser-pull-check-":
    errors.append(f"expected a Pod with generateName sap-browser-pull-check-, got {pod.get('kind')} {pod.get('metadata')}")
spec = pod["spec"]
containers = spec["containers"]
if spec.get("restartPolicy") != "Never" or len(containers) != 1:
    errors.append("expected restartPolicy Never and one container")
c = containers[0]
if c.get("image") != sys.argv[2] or c.get("imagePullPolicy") != "Always":
    errors.append(f"container must pull {sys.argv[2]} with imagePullPolicy Always, got {c.get('image')} {c.get('imagePullPolicy')}")
if c.get("command") != ["/bin/true"]:
    errors.append(f"container must run a trivial command, got {c.get('command')}")
if "imagePullSecrets" in spec:
    errors.append("the runner repository is public: no imagePullSecrets")
if errors:
    print("\n".join(errors))
    sys.exit(1)
PY
grep -qF "started on this cluster" <<< "${ALL_OUT}" || { echo "${ALL_OUT}"; fail "pull check success not printed"; }
no_secrets_leaked
echo "✅ PASS: missing_tag_builds_pushes_and_pull_checks"

# Test case: build_or_push_error_skips_browser
# A failed build or push leaves no image (no push, no pull check after it)
echo ""
echo "Test: build_or_push_error_skips_browser"
echo "--------------------------------------------"
setup
FAKE_SKOPEO_RC=1
FAKE_SKOPEO_STDERR="manifest unknown"
FAKE_BUILDAH_RC=1
run_all
expect_no_image "failed build"
grep -qF "Could not build" <<< "${ALL_OUT}" || { echo "${ALL_OUT}"; fail "build error not reported"; }
! grep -q "^buildah .* push " "${FAKE_TOOL_LOG}" || fail "no push after a failed build"
[[ ! -s "${FAKE_OC_LOG}" ]] || fail "no pull check after a failed build"
setup
FAKE_SKOPEO_RC=1
FAKE_SKOPEO_STDERR="manifest unknown"
FAKE_BUILDAH_PUSH_RC=1
run_all
expect_no_image "failed push"
grep -qF "Could not push" <<< "${ALL_OUT}" || { echo "${ALL_OUT}"; fail "push error not reported"; }
[[ ! -s "${FAKE_OC_LOG}" ]] || fail "no pull check after a failed push"
no_secrets_leaked
echo "✅ PASS: build_or_push_error_skips_browser"

# Test case: check_error_skips_browser
# A registry error other than a missing tag (certificate, credentials) leaves
# no image instead of starting a long build that cannot be pushed
echo ""
echo "Test: check_error_skips_browser"
echo "--------------------------------------------"
setup
FAKE_SKOPEO_RC=1
FAKE_SKOPEO_STDERR="pinging container registry ${REGISTRY_HOST}: Get \"https://${REGISTRY_HOST}/v2/\": tls: failed to verify certificate: x509: certificate signed by unknown authority"
run_all
expect_no_image "registry error"
grep -qF "Could not check" <<< "${ALL_OUT}" || { echo "${ALL_OUT}"; fail "check error not reported"; }
grep -qF "x509" <<< "${ALL_OUT}" || { echo "${ALL_OUT}"; fail "skopeo error not shown"; }
! grep -q "^buildah" "${FAKE_TOOL_LOG}" || fail "no build after a registry error"
# Building without the robot credentials fails before calling the registry
setup
REGISTRY_PASSWORD=""
run_all
expect_no_image "missing robot credentials"
grep -qF "eic-quay-robot" <<< "${ALL_OUT}" || { echo "${ALL_OUT}"; fail "the push Secret is not named"; }
[[ ! -s "${FAKE_TOOL_LOG}" ]] || fail "no registry call without credentials: $(cat "${FAKE_TOOL_LOG}")"
echo "✅ PASS: check_error_skips_browser"

# Test case: pull_error_skips_browser_with_hint
echo ""
echo "Test: pull_error_skips_browser_with_hint"
echo "--------------------------------------------"
for REASON in ErrImagePull ImagePullBackOff; do
  setup
  FAKE_SKOPEO_RC=1
  FAKE_SKOPEO_STDERR="manifest unknown"
  write_pod_rules "Pending|${REASON}|Failed to pull image: tls: failed to verify certificate: x509: certificate signed by unknown authority"
  run_all
  expect_no_image "${REASON}"
  grep -qF "eic cannot pull from its Quay (certificate trust?)" <<< "${ALL_OUT}" || { echo "${ALL_OUT}"; fail "${REASON}: hint not printed"; }
  grep -qF "x509: certificate signed by unknown authority" <<< "${ALL_OUT}" || { echo "${ALL_OUT}"; fail "${REASON}: pull error not shown"; }
  assert_called "^delete ${POD} --ignore-not-found --wait=false$"
done
echo "✅ PASS: pull_error_skips_browser_with_hint"

echo ""
echo "============================================"
echo "✅ All sap-browser-image tests passed"
echo "============================================"
