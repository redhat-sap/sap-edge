# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-License-Identifier: Apache-2.0

"""Regression checks for Redis shutdown diagnosis; no cluster is contacted."""

import datetime
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "fix_pdb_for_node_rollout.sh"


def mock_cli():
    args = sys.argv[2:]
    with open(os.environ["PDB_TEST_CALLS"], "a", encoding="utf-8") as calls:
        calls.write(json.dumps(args) + "\n")
    if args == ["config", "current-context"]:
        print("test-cluster")
        return
    position = args.index("get")
    resource = args[position + 1]
    fixture = json.loads(Path(os.environ["PDB_TEST_STATE"]).read_text())
    if resource == fixture.get("denied_resource"):
        print("Forbidden", file=sys.stderr)
        raise SystemExit(1)
    if resource.startswith("postgresclusters."):
        result = {"metadata": {"uid": "postgres-owner"}}
    elif resource.startswith("redisenterpriseclusters."):
        result = {"metadata": {"uid": "redis-owner"}}
    elif resource in ("pods", "statefulsets"):
        result = {"items": fixture[resource]}
    elif resource == "pdb":
        result = {"items": []}
    else:
        raise AssertionError("Unexpected resource: " + resource)
    if any(arg.startswith("jsonpath=") for arg in args):
        print(result["metadata"]["uid"])
    else:
        print(json.dumps(result))


class ShutdownDetectionTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        folder = Path(self.directory.name)
        self.state = folder / "state.json"
        self.calls = folder / "calls.jsonl"
        cli = folder / "oc"
        cli.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + " "
                       + shlex.quote(str(Path(__file__).resolve())) + ' --mock-cli "$@"\n')
        cli.chmod(0o700)
        self.env = dict(os.environ, PATH=str(folder) + os.pathsep + os.environ["PATH"],
                        PDB_TEST_STATE=str(self.state), PDB_TEST_CALLS=str(self.calls))
        self.fixture = {
            "statefulsets": [{"metadata": {"uid": "redis-statefulset", "ownerReferences": [
                {"uid": "redis-owner"}]}}],
            "pods": [],
        }

    def add_terminating_pod(self, elapsed=600, grace=31536000, owner="redis-statefulset"):
        # Kubernetes records the deletion deadline, not the time eviction began.
        deadline = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=grace - elapsed)
        self.fixture["pods"].append({
            "metadata": {
                "name": "rec-0", "ownerReferences": [{"uid": owner}],
                "deletionTimestamp": deadline.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "deletionGracePeriodSeconds": grace,
            },
            "spec": {"nodeName": "draining-worker", "terminationGracePeriodSeconds": 31536000},
        })

    def run_script(self, *args):
        self.state.write_text(json.dumps(self.fixture))
        result = subprocess.run(["bash", str(SCRIPT), *args], env=self.env,
                                capture_output=True, text=True, timeout=10)
        # Every scenario is read-only, including apply/watch blocked in preflight.
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertFalse(any("patch" in call or "delete" in call for call in calls), calls)
        return result

    def test_year_long_grace_is_reported_as_already_terminating(self):
        self.add_terminating_pod()
        result = self.run_script("--status")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("rec-0\tdraining-worker\t31536000\t", result.stdout)
        self.assertIn("Redis shutdown needs investigation", result.stderr)
        self.assertIn("persistence", result.stderr)

    def test_apply_dry_run_and_watch_stop_before_patches(self):
        self.add_terminating_pod()
        for args in [(), ("--dry-run",), ("--watch", "1")]:
            with self.subTest(args=args):
                result = self.run_script(*args)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)

    def test_recent_shutdown_is_reported_without_claiming_it_is_stuck(self):
        self.add_terminating_pod(elapsed=30)
        result = self.run_script("--status")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Eviction/deletion has already started", result.stdout)

    def test_uses_remaining_grace_when_deletion_was_shortened(self):
        self.add_terminating_pod(elapsed=30, grace=60)
        result = self.run_script("--status")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("rec-0\tdraining-worker\t60\t", result.stdout)

    def test_other_cluster_in_same_namespace_is_excluded(self):
        self.fixture["statefulsets"].append({"metadata": {
            "uid": "other-statefulset", "ownerReferences": [{"uid": "other-cluster"}]}})
        self.add_terminating_pod(owner="other-statefulset")
        result = self.run_script("--status")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("already terminating", result.stdout)

    def test_running_pod_is_excluded(self):
        self.add_terminating_pod()
        del self.fixture["pods"][0]["metadata"]["deletionTimestamp"]
        result = self.run_script("--status")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_status_with_no_pods_makes_no_changes(self):
        result = self.run_script("--status")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Status only", result.stdout)

    def test_read_failure_cannot_be_reported_as_healthy(self):
        self.fixture["denied_resource"] = "pods"
        result = self.run_script("--status")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Forbidden", result.stderr)

    def test_invalid_deletion_time_requires_investigation(self):
        self.add_terminating_pod()
        self.fixture["pods"][0]["metadata"]["deletionTimestamp"] = "invalid"
        result = self.run_script("--status")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("unknown", result.stdout)


if __name__ == "__main__":
    if sys.argv[1:2] == ["--mock-cli"]:
        mock_cli()
    else:
        unittest.main()
