# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-License-Identifier: Apache-2.0

"""Exercise the public recovery flag against a stateful fake Kubernetes CLI."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'fix_pdb_for_node_rollout.sh'


def mock_cli():
    args = sys.argv[2:]
    with open(os.environ['RECOVERY_TEST_CALLS'], 'a', encoding='utf-8') as output:
        output.write(json.dumps(args) + '\n')
    if args == ['config', 'current-context']:
        print('test-cluster')
        return
    path = Path(os.environ['RECOVERY_TEST_STATE'])
    state = json.loads(path.read_text())
    position = next(i for i, arg in enumerate(args) if arg in ('get', 'patch', 'exec', 'logs'))
    verb = args[position]
    resource = args[position + 1]
    if state.get('deny') == resource:
        print('Forbidden', file=sys.stderr)
        raise SystemExit(1)
    if verb == 'get':
        if resource.startswith('redisenterpriseclusters.'):
            state['cluster_reads'] = state.get('cluster_reads', 0) + 1
            if state.get('replace_rec') and state['cluster_reads'] > 1:
                state['rec']['metadata']['uid'] = 'replacement'
            if state.get('resume') and state['cluster_reads'] > 1:
                state['rec']['spec'].pop('clusterRecovery', None)
                state['rec']['status']['state'] = 'Running'
            result = state['rec']
        elif resource.startswith('machineconfigpools.'):
            result = state['pool']
        elif resource.startswith('redisenterprisedatabases.'):
            result = {'items': state['redbs']}
        elif resource == 'statefulsets':
            result = {'items': state['statefulsets']}
        elif resource == 'pods':
            result = {'items': state['pods']}
        elif resource == 'nodes':
            result = state['node']
        else:
            raise AssertionError('Unexpected read: ' + resource)
    elif verb == 'logs':
        print(state['logs'])
        return
    elif verb == 'patch':
        assert resource.startswith('redisenterpriseclusters.')
        patch = json.loads(args[args.index('-p') + 1])
        assert patch[0] == {'op': 'test', 'path': '/metadata/uid', 'value': state['rec']['metadata']['uid']}
        assert patch[1]['path'] == '/metadata/resourceVersion'
        result = json.loads(json.dumps(state['rec']))
        result['spec']['clusterRecovery'] = not state.get('prune_recovery', False)
        if '--dry-run=server' not in args:
            state['mutations'].append('clusterRecovery')
            state['rec']['status']['state'] = 'Running'
            state['pods'][0]['metadata']['uid'] = 'new-pod'
            state['pods'][0]['status']['conditions'][0]['status'] = 'True'
            state['inspection']['bootstrapped'] = True
            for database in state['inspection']['databases']:
                database['status'] = 'recovery'
    elif verb == 'exec':
        command = args[args.index('--') + 1:]
        if command[0] == '/opt/redislabs/bin/python3':
            if state.get('api_error'):
                print('Redis API unavailable', file=sys.stderr)
                raise SystemExit(1)
            result = state['inspection']
        else:
            assert command[:3] == ['rladmin', 'recover', 'db']
            assert command[4:] == ['only_configuration']
            if state.get('recover_error'):
                print('Database recovery failed', file=sys.stderr)
                raise SystemExit(1)
            identifier = command[3]
            state['mutations'].append(identifier)
            for database in state['inspection']['databases']:
                if identifier == 'db:' + str(database['uid']):
                    database['status'] = 'active'
            result = 'Database recovery completed'
    path.write_text(json.dumps(state))
    print(json.dumps(result))


class DisposableRecoveryTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        folder = Path(directory.name)
        self.state_path = folder / 'state.json'
        self.calls_path = folder / 'calls.jsonl'
        cli = folder / 'oc'
        cli.write_text('#!/bin/sh\nexec ' + shlex.quote(sys.executable) + ' '
                       + shlex.quote(str(Path(__file__).resolve())) + ' --mock-cli "$@"\n')
        cli.chmod(0o700)
        self.env = dict(os.environ, PATH=str(folder) + os.pathsep + os.environ['PATH'],
                        RECOVERY_TEST_STATE=str(self.state_path), RECOVERY_TEST_CALLS=str(self.calls_path))
        self.state = {
            'mutations': [],
            'rec': {'metadata': {'uid': 'rec-owner', 'resourceVersion': '1'},
                    'spec': {'nodes': 1, 'persistentSpec': {'enabled': True}},
                    'status': {'state': 'RunningRollingUpdate'}},
            'pool': {'status': {'machineCount': 3, 'updatedMachineCount': 3, 'readyMachineCount': 3,
                               'conditions': [{'type': 'Updated', 'status': 'True'},
                                              {'type': 'Updating', 'status': 'False'},
                                              {'type': 'Degraded', 'status': 'False'}]}},
            'statefulsets': [{'metadata': {'uid': 'sts-owner', 'ownerReferences': [{'uid': 'rec-owner'}]}}],
            'pods': [{'metadata': {'name': 'custom-0', 'uid': 'old-pod', 'ownerReferences': [{'uid': 'sts-owner'}]},
                      'spec': {'nodeName': 'worker-1'},
                      'status': {'phase': 'Running', 'conditions': [{'type': 'Ready', 'status': 'False'}],
                                 'containerStatuses': [{'name': 'redis-enterprise-node', 'state': {'running': {}}}]}}],
            'node': {'status': {'conditions': [{'type': 'Ready', 'status': 'True'}]}},
            'redbs': [{'spec': {'redisEnterpriseCluster': {'name': 'custom'}}, 'status': {'databaseUID': '1'}}],
            'inspection': {'bootstrapped': False, 'configuration_available': True,
                           'databases': [{'uid': 1, 'name': 'redb', 'status': 'active'}]},
            'logs': 'No pod has been labeled as master pod yet. Waiting...',
        }

    def bootstrapped(self):
        self.state['rec']['status']['state'] = 'Running'
        self.state['pods'][0]['status']['conditions'][0]['status'] = 'True'
        self.state['inspection']['bootstrapped'] = True

    def run_script(self, *extra, success=True):
        self.state_path.write_text(json.dumps(self.state))
        result = subprocess.run(['bash', str(SCRIPT), '--recover-disposable-redis',
                                 '--redis-namespace', 'custom-redis', '--redis-cluster', 'custom', *extra],
                                env=self.env, text=True, capture_output=True, timeout=15)
        self.after = json.loads(self.state_path.read_text())
        self.calls = [json.loads(line) for line in self.calls_path.read_text().splitlines()]
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        for call in self.calls:
            self.assertFalse(any('postgres' in a or a in ('pdb', 'delete') for a in call), call)
            if '-n' in call:
                self.assertEqual(call[call.index('-n') + 1], 'custom-redis')
        return result

    def test_lost_master_recovers_cluster_then_empty_database(self):
        result = self.run_script()
        self.assertEqual(self.after['mutations'], ['clusterRecovery', 'db:1'])
        self.assertIn('all databases are active', result.stdout)

    def test_healthy_instance_is_unchanged(self):
        self.bootstrapped()
        result = self.run_script()
        self.assertEqual(self.after['mutations'], [])
        self.assertIn('no reset', result.stdout)

    def test_dry_run_never_changes_cluster_or_databases(self):
        self.run_script('--dry-run')
        self.assertEqual(self.after['mutations'], [])
        self.assertTrue(any('patch' in c and '--dry-run=server' in c for c in self.calls))

    def test_resume_restores_only_recovery_database(self):
        self.bootstrapped()
        self.state['inspection']['databases'] += [{'uid': 2, 'name': 'another', 'status': 'recovery'}]
        self.run_script()
        self.assertEqual(self.after['mutations'], ['db:2'])

    def test_resume_in_progress_cluster_recovery(self):
        self.bootstrapped()
        self.state['rec']['spec']['clusterRecovery'] = True
        self.state['resume'] = True
        self.state['inspection']['databases'][0]['status'] = 'recovery'
        self.run_script()
        self.assertEqual(self.after['mutations'], ['db:1'])

    def test_preconditions_block_before_any_mutation(self):
        scenarios = [
            ('HA', lambda: self.state['rec']['spec'].update(nodes=3)),
            ('no PVC', lambda: self.state['rec']['spec']['persistentSpec'].update(enabled=False)),
            ('rollout', lambda: self.state['pool']['status'].update(updatedMachineCount=2)),
            ('terminating', lambda: self.state['pods'][0]['metadata'].update(deletionTimestamp='2026-01-01T00:00:00Z')),
            ('Pending', lambda: self.state['pods'][0]['status'].update(phase='Pending')),
            ('cordoned', lambda: self.state['node'].update(spec={'unschedulable': True})),
            ('missing configuration', lambda: self.state['inspection'].update(configuration_available=False)),
            ('different bootstrap failure', lambda: self.state.update(logs='Connection refused')),
            ('new database', lambda: self.state['redbs'][0].update(status={})),
            ('API rejection', lambda: self.state.update(deny='pods')),
            ('replaced REC', lambda: self.state.update(replace_rec=True)),
            ('unsupported API', lambda: self.state.update(prune_recovery=True)),
        ]
        original = json.dumps(self.state)
        for name, change in scenarios:
            with self.subTest(name=name):
                self.state = json.loads(original)
                self.calls_path.unlink(missing_ok=True)
                change()
                self.run_script(success=False)
                self.assertEqual(self.after['mutations'], [])

    def test_other_rec_pods_are_ignored(self):
        other = json.loads(json.dumps(self.state['pods'][0]))
        other['metadata']['ownerReferences'] = [{'uid': 'other-sts'}]
        self.state['pods'].append(other)
        self.run_script()
        self.assertEqual(self.after['mutations'], ['clusterRecovery', 'db:1'])

    def test_database_errors_do_not_report_success(self):
        self.bootstrapped()
        self.state['inspection']['databases'][0]['status'] = 'recovery'
        self.state['recover_error'] = True
        result = self.run_script(success=False)
        self.assertNotIn('all databases are active', result.stdout)

    def test_current_api_failure_is_not_hidden_by_stale_cr_status(self):
        self.bootstrapped()
        self.state['api_error'] = True
        self.run_script(success=False)
        self.assertEqual(self.after['mutations'], [])

    def test_database_dry_run_is_read_only(self):
        self.bootstrapped()
        self.state['inspection']['databases'][0]['status'] = 'recovery'
        self.run_script('--dry-run')
        self.assertEqual(self.after['mutations'], [])

    def test_unrelated_bootstrapped_readiness_failure_is_not_reset(self):
        self.bootstrapped()
        self.state['pods'][0]['status']['conditions'][0]['status'] = 'False'
        result = self.run_script(success=False)
        self.assertIn('bootstrapped but unhealthy', result.stderr)
        self.assertEqual(self.after['mutations'], [])

    def test_incomplete_recovery_has_a_bounded_wait(self):
        self.state['rec']['spec']['clusterRecovery'] = True
        self.state['rec']['status']['state'] = 'RecoveringFirstPod'
        result = self.run_script('--recovery-timeout', '1', success=False)
        self.assertIn('timed out', result.stderr)
        self.assertEqual(self.after['mutations'], [])

    def test_invalid_recovery_arguments_fail_before_cluster_access(self):
        for args in [('--status',), ('--watch', '1'), ('--recovery-timeout', '0')]:
            with self.subTest(args=args):
                result = subprocess.run(['bash', str(SCRIPT), '--recover-disposable-redis', *args],
                                        env=self.env, text=True, capture_output=True, timeout=5)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.calls_path.exists())


if __name__ == '__main__':
    if sys.argv[1:2] == ['--mock-cli']:
        mock_cli()
    else:
        unittest.main()
