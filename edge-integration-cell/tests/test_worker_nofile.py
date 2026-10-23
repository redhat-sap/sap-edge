# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-License-Identifier: Apache-2.0

"""Test worker nofile setup with a stateful fake oc, without a cluster."""

import base64
import copy
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest


DIRECTORY = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('worker_nofile', DIRECTORY / 'configure_worker_nofile.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
NAME = '96-worker-crio-limit-files'
PREFIX = MODULE.PREFIX


def file_for(entries):
    text = '[crio.runtime]\ndefault_ulimits = ' + json.dumps(entries) + '\n'
    return {'path': MODULE.CONFIG_PATH, 'mode': 420, 'overwrite': True,
            'contents': {'source': 'data:;base64,' + base64.b64encode(text.encode()).decode()}}


def fixture():
    pool = {'metadata': {'name': 'worker', 'uid': 'pool-owner', 'generation': 1},
            'spec': {'nodeSelector': {'matchLabels': {'node-role.kubernetes.io/worker': ''}},
                     'machineConfigSelector': {'matchLabels': {MODULE.ROLE: 'worker'}},
                     'configuration': {'name': 'rendered-old', 'source': []}},
            'status': {'observedGeneration': 1, 'machineCount': 3, 'readyMachineCount': 3,
                       'updatedMachineCount': 3, 'unavailableMachineCount': 0,
                       'configuration': {'name': 'rendered-old'},
                       'conditions': [{'type': 'Updated', 'status': 'True'},
                                      {'type': 'Updating', 'status': 'False'},
                                      {'type': 'Degraded', 'status': 'False'}]}}
    nodes = [{'metadata': {'name': 'worker-' + str(i), 'uid': 'node-' + str(i),
                           'labels': {'node-role.kubernetes.io/worker': ''},
                           'annotations': {PREFIX + 'state': 'Done', PREFIX + 'currentConfig': 'rendered-old',
                                           PREFIX + 'desiredConfig': 'rendered-old'}},
              'spec': {}, 'status': {'conditions': [{'type': 'Ready', 'status': 'True'}]}} for i in range(3)]
    return {'pool': pool, 'nodes': nodes, 'configs': {}, 'mutations': [], 'defaults': ['nproc=8192:16384'],
            'soft': 1024, 'hard': 524288}


def mock_cli():
    args = sys.argv[2:]
    with open(os.environ['NOFILE_TEST_CALLS'], 'a', encoding='utf-8') as calls:
        calls.write(json.dumps(args) + '\n')
    position = next(i for i, arg in enumerate(args) if arg in ('get', 'create', 'patch', 'config', 'debug'))
    verb = args[position]
    if verb == 'config':
        print('test-cluster')
        return
    path = Path(os.environ['NOFILE_TEST_STATE'])
    state = json.loads(path.read_text())
    if verb == state.get('deny'):
        print('Forbidden', file=sys.stderr)
        raise SystemExit(1)
    if verb == 'debug':
        if state.get('replace_node_during_inspection') and args[position + 1] == 'node/worker-2':
            state['nodes'][0]['metadata']['uid'] = 'replacement-node'
            path.write_text(json.dumps(state))
        defaults = state.get('defaults_by_node', {}).get(args[position + 1], state['defaults'])
        print('EIC_NOFILE_CHECK_V1\n' + str(state['soft']) + '\n' + str(state['hard']))
        print('EIC_CRIO_CONFIG_V1\n[crio.runtime]\ndefault_ulimits = ' + json.dumps(defaults))
        print('EIC_NOFILE_CHECK_END')
        return
    resource = args[position + 1]
    if verb == 'get':
        rest = args[position + 2:]
        name = rest[0] if rest and not rest[0].startswith('-') else None
        if resource == MODULE.MCP:
            if name and state.get('applied'):
                state['rollout_reads'] = state.get('rollout_reads', 0) + 1
                if state['rollout_reads'] >= 3 and not state.get('never_converge'):
                    pool = state['pool']
                    pool['metadata']['generation'] = 2
                    pool['status']['observedGeneration'] = 2
                    pool['spec']['configuration'] = {'name': 'rendered-new', 'source': [{'name': NAME}]}
                    pool['status']['configuration']['name'] = 'rendered-new'
                    for node in state['nodes']:
                        node['metadata']['annotations'][PREFIX + 'currentConfig'] = 'rendered-new'
                        node['metadata']['annotations'][PREFIX + 'desiredConfig'] = 'rendered-new'
                    state['configs']['rendered-new'] = copy.deepcopy(state['configs'][NAME])
                    state['configs']['rendered-new']['metadata'] = {'name': 'rendered-new'}
                    state['defaults'] = MODULE.tomllib.loads(MODULE.contents(MODULE.target_file(state['configs'][NAME])))['crio']['runtime']['default_ulimits']
                    if not state.get('bad_limits_after'):
                        state['soft'], state['hard'] = MODULE.parse_limits(state['defaults'])['nofile']
            result = state['pool'] if name else {'items': [state['pool']] + state.get('other_pools', [])}
        elif resource == 'nodes':
            result = {'items': state['nodes']}
        elif resource == MODULE.MC:
            if name:
                result = state['configs'].get(name)
                if result is None:
                    assert '--ignore-not-found' in args, name
                    return
            else:
                result = {'items': list(state['configs'].values())}
        else:
            raise AssertionError('Unexpected resource ' + resource)
    else:
        payload = json.load(sys.stdin)
        if verb == 'create':
            result = payload
            assert result['kind'] == 'MachineConfig'
            result['metadata'].update(uid='config-owner', resourceVersion='1', generation=1)
        else:
            assert verb == 'patch' and resource == MODULE.MC
            existing = state['configs'][NAME]
            assert payload[0] == {'op': 'test', 'path': '/metadata/uid', 'value': existing['metadata']['uid']}
            assert payload[1] == {'op': 'test', 'path': '/metadata/resourceVersion', 'value': existing['metadata']['resourceVersion']}
            result = copy.deepcopy(existing)
            result['spec']['config'] = payload[2]['value']
            result['metadata']['generation'] += 1
        if '--dry-run=server' not in args:
            state['configs'][NAME] = result
            state['mutations'].append(verb)
            state['applied'] = True
    path.write_text(json.dumps(state))
    print(json.dumps(result))


class WorkerNofileTest(unittest.TestCase):
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
                        NOFILE_TEST_STATE=str(self.state_path), NOFILE_TEST_CALLS=str(self.calls_path))
        self.state = fixture()

    def run_script(self, *args, success=True):
        self.state_path.write_text(json.dumps(self.state))
        result = subprocess.run(['bash', str(DIRECTORY / 'configure_worker_nofile.sh'),
                                 '--poll-interval', '1', *args], env=self.env,
                                capture_output=True, text=True, timeout=25)
        self.after = json.loads(self.state_path.read_text())
        self.calls = [json.loads(line) for line in self.calls_path.read_text().splitlines()]
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn('All done', result.stdout)
        self.assertFalse(any('pdb' in call or 'drain' in call for call in self.calls))
        return result

    def existing(self, entries):
        self.state['configs'][NAME] = {
            'apiVersion': 'machineconfiguration.openshift.io/v1', 'kind': 'MachineConfig',
            'metadata': {'name': NAME, 'uid': 'existing-owner', 'resourceVersion': '7', 'generation': 4,
                         'labels': {MODULE.ROLE: 'worker'}},
            'spec': {'kernelArguments': ['keep-this'], 'config': {'ignition': {'version': '3.2.0'},
                     'storage': {'files': [file_for(entries), {'path': '/etc/unrelated', 'contents': {'source': 'data:,keep'}}]}}}}
        self.state['configs']['rendered-old'] = copy.deepcopy(self.state['configs'][NAME])
        self.state['configs']['rendered-old']['metadata'] = {'name': 'rendered-old'}
        self.state['pool']['spec']['configuration']['source'] = [{'name': NAME}]

    def test_sufficient_limits_skip_machineconfig(self):
        self.state.update(soft=65536, hard=2097152)
        result = self.run_script()
        self.assertEqual(self.after['mutations'], [])
        self.assertEqual(len([c for c in self.calls if 'debug' in c]), 3)
        self.assertIn('No patch needed', result.stdout)
        self.assertIn('All done', result.stdout)

    def test_create_preserves_other_limits_and_waits_for_rendered_config(self):
        result = self.run_script()
        self.assertEqual(self.after['mutations'], ['create'])
        self.assertGreaterEqual(self.after['rollout_reads'], 3)
        self.assertEqual(self.after['defaults'], ['nproc=8192:16384', 'nofile=4096:1048576'])
        self.assertEqual(len([c for c in self.calls if 'debug' in c]), 6)
        self.assertIn('All done', result.stdout)

    def test_update_preserves_unrelated_files_and_spec(self):
        self.existing(['nofile=1024:524288'])
        self.run_script()
        resource = self.after['configs'][NAME]
        self.assertEqual(resource['spec']['kernelArguments'], ['keep-this'])
        self.assertEqual(resource['spec']['config']['storage']['files'][1]['path'], '/etc/unrelated')
        self.assertEqual(self.after['mutations'], ['patch'])
        # Old MCP status was already Updated, including the same MC name, but
        # recovery must still wait for the new rendered file contents.
        self.assertGreaterEqual(self.after['rollout_reads'], 3)

    def test_dry_run_inspects_and_validates_without_mutation(self):
        result = self.run_script('--dry-run')
        self.assertEqual(self.after['mutations'], [])
        self.assertTrue(any('create' in c and '--dry-run=server' in c for c in self.calls))
        self.assertNotIn('All done', result.stdout)

    def test_readiness_does_not_hide_failed_runtime_limits(self):
        self.state['bad_limits_after'] = True
        result = self.run_script(success=False)
        self.assertIn('runtime limits did not match', result.stderr)

    def test_timeout_never_reports_done(self):
        self.state['never_converge'] = True
        result = self.run_script('--timeout', '5', success=False)
        self.assertIn('timed out', result.stderr.lower())

    def test_preflight_errors_make_no_config_changes(self):
        scenarios = [
            ('paused', lambda: self.state['pool']['spec'].update(paused=True), 'paused'),
            ('degraded', lambda: self.state['pool']['status']['conditions'][2].update(status='True', message='drain failed'), 'drain failed'),
            ('no workers', lambda: self.state.update(nodes=[]), 'no nodes'),
            ('debug forbidden', lambda: self.state.update(deny='debug'), 'Forbidden'),
            ('different limits', lambda: self.state.update(defaults_by_node={'node/worker-1': ['nproc=100:200']}), 'different non-nofile'),
            ('control plane', lambda: self.state['nodes'][0]['metadata']['labels'].update({'node-role.kubernetes.io/master': ''}), 'worker-only'),
        ]
        for name, change, message in scenarios:
            with self.subTest(name=name):
                self.state = fixture()
                change()
                result = self.run_script(success=False)
                self.assertIn(message, result.stderr)
                self.assertEqual(self.after['mutations'], [])

    def test_existing_correct_config_with_bad_runtime_requires_diagnosis(self):
        self.existing(['nproc=8192:16384', 'nofile=4096:1048576'])
        result = self.run_script(success=False)
        self.assertIn('already requests these limits', result.stderr)
        self.assertEqual(self.after['mutations'], [])

    def test_other_pool_cannot_be_changed_implicitly(self):
        other = copy.deepcopy(self.state['pool'])
        other['metadata'].update(name='infra', uid='infra-owner')
        self.state['other_pools'] = [other]
        result = self.run_script(success=False)
        self.assertIn('also affects pool infra', result.stderr)
        self.assertEqual(self.after['mutations'], [])

    def test_worker_replacement_during_inspection_prevents_changes_and_success(self):
        for soft, hard in ((1024, 524288), (4096, 1048576)):
            with self.subTest(soft=soft, hard=hard):
                self.state = fixture()
                self.state.update(soft=soft, hard=hard, replace_node_during_inspection=True)
                result = self.run_script(success=False)
                self.assertIn('Worker state changed', result.stderr)
                self.assertEqual(self.after['mutations'], [])

    def test_higher_limits_are_never_lowered(self):
        probes = [MODULE.parse_probe('EIC_NOFILE_CHECK_V1\n1024\n2097152\nEIC_CRIO_CONFIG_V1\n'
                                     '[crio.runtime]\ndefault_ulimits=["nofile=1024:2097152"]\nEIC_NOFILE_CHECK_END')]
        self.assertEqual(MODULE.desired_limits(probes), ['nofile=4096:2097152'])
        probes[0]['soft'] = 65536
        self.assertEqual(MODULE.desired_limits(probes), ['nofile=65536:2097152'])

    def test_probe_separates_crio_logs_from_configuration(self):
        folder = Path(self.env['PATH'].split(os.pathsep)[0])
        commands = {
            'timeout': '#!/bin/sh\nshift\nexec "$@"\n',
            'chroot': '#!/bin/sh\necho \'time="now" level=info msg="Updating config"\' >&2\n'
                      'printf \'[crio.runtime]\\ndefault_ulimits=["nofile=4096:1048576"]\\n\'\n',
        }
        for name, script in commands.items():
            command = folder / name
            command.write_text(script)
            command.chmod(0o700)
        result = subprocess.run(['sh', '-ceu', MODULE.PROBE], env=self.env, capture_output=True,
                                text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        # oc debug merges the remote command's stderr into its output stream.
        probe = MODULE.parse_probe(result.stdout + result.stderr)
        self.assertEqual(probe['limits'], {'nofile': (4096, 1048576)})
        self.assertNotIn('Updating config', result.stdout + result.stderr)

        (folder / 'chroot').write_text('#!/bin/sh\necho "CRI-O unavailable" >&2\nexit 1\n')
        failed = subprocess.run(['sh', '-ceu', MODULE.PROBE], env=self.env, capture_output=True,
                                text=True, timeout=10)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn('CRI-O unavailable', failed.stderr)
        self.assertNotIn('EIC_NOFILE_CHECK_END', failed.stdout)

    def test_convergence_checks_generation_node_annotations_and_cordon(self):
        setup = MODULE.Setup(type('Args', (), {'timeout': 60, 'pool': 'worker'})())
        self.assertTrue(setup.converged(self.state['pool'], self.state['nodes']))
        self.state['pool']['metadata']['generation'] = 2
        self.assertFalse(setup.converged(self.state['pool'], self.state['nodes']))
        self.state['pool']['status']['observedGeneration'] = 2
        self.state['nodes'][0]['metadata']['annotations'][PREFIX + 'desiredConfig'] = 'newer'
        self.assertFalse(setup.converged(self.state['pool'], self.state['nodes']))
        self.state['nodes'][0]['metadata']['annotations'][PREFIX + 'desiredConfig'] = 'rendered-old'
        self.state['nodes'][0]['spec']['unschedulable'] = True
        self.assertFalse(setup.converged(self.state['pool'], self.state['nodes']))


if __name__ == '__main__':
    if sys.argv[1:2] == ['--mock-cli']:
        mock_cli()
    else:
        unittest.main()
