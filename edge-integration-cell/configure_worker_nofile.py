# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-License-Identifier: Apache-2.0

"""Configure worker nofile limits before installing PostgreSQL, Redis and EIC.

Requires oc, Python 3.11+ and cluster-admin access on self-managed OpenShift.
Node inspection creates temporary oc debug pods, including during --dry-run.
Changing the MachineConfig can drain and reboot workers. No PDBs are changed.
"""

import argparse
import base64
import copy
import json
import math
import shutil
import signal
import subprocess
import sys
import time
from urllib.parse import unquote_to_bytes

try:
    import tomllib
except ImportError:
    sys.exit('ERROR: Python 3.11 or newer is required (standard-library TOML parser).')


MCP = 'machineconfigpools.machineconfiguration.openshift.io'
MC = 'machineconfigs.machineconfiguration.openshift.io'
ROLE = 'machineconfiguration.openshift.io/role'
PREFIX = 'machineconfiguration.openshift.io/'
CONFIG_PATH = '/etc/crio/crio.conf.d/99-eic-nofile.conf'
SOFT, HARD = 4096, 1048576
PROBE = '''crio_error=$(mktemp)
trap 'rm -f "$crio_error"' EXIT
printf 'EIC_NOFILE_CHECK_V1\\n'
ulimit -Sn
ulimit -Hn
printf 'EIC_CRIO_CONFIG_V1\\n'
if ! timeout 20 chroot /host crio status config 2>"$crio_error"; then
    cat "$crio_error" >&2
    exit 1
fi
printf '\\nEIC_NOFILE_CHECK_END\\n'
'''


class SetupError(Exception):
    """The configuration could not be safely applied or verified."""


def require(condition, message):
    if not condition:
        raise SetupError(message)


def matches(labels, selector):
    if not selector:
        return False
    if any(labels.get(k) != v for k, v in selector.get('matchLabels', {}).items()):
        return False
    for expression in selector.get('matchExpressions', []):
        key, operator = expression['key'], expression['operator']
        values = expression.get('values', [])
        if operator == 'In' and (key not in labels or labels[key] not in values):
            return False
        if operator == 'NotIn' and key in labels and labels[key] in values:
            return False
        if operator == 'Exists' and key not in labels:
            return False
        if operator == 'DoesNotExist' and key in labels:
            return False
        require(operator in ('In', 'NotIn', 'Exists', 'DoesNotExist'), 'Unsupported label selector operator.')
    return True


def limit(value):
    if str(value) in ('-1', 'unlimited'):
        return math.inf
    number = int(value)
    require(number >= 0, 'Invalid negative ulimit value.')
    return number


def parse_limits(values):
    require(isinstance(values, list), 'CRI-O default_ulimits is not a list.')
    result = {}
    for entry in values:
        name, bounds = entry.split('=', 1)
        soft, hard = bounds.split(':', 1)
        require(name not in result, 'Duplicate CRI-O ulimit: ' + name)
        require(limit(soft) <= limit(hard), 'Soft ulimit exceeds hard ulimit: ' + name)
        result[name] = (limit(soft), limit(hard))
    return result


def parse_probe(output):
    require('EIC_NOFILE_CHECK_V1\n' in output and '\nEIC_NOFILE_CHECK_END' in output,
            'Incomplete node inspection output; no configuration was inferred.')
    body = output.split('EIC_NOFILE_CHECK_V1\n', 1)[1].split('\nEIC_NOFILE_CHECK_END', 1)[0]
    readings, config = body.split('EIC_CRIO_CONFIG_V1\n', 1)
    values = readings.strip().splitlines()
    require(len(values) == 2, 'Invalid nofile readings from debug container.')
    defaults = tomllib.loads(config)['crio']['runtime'].get('default_ulimits', [])
    return {'soft': limit(values[0]), 'hard': limit(values[1]), 'defaults': defaults,
            'limits': parse_limits(defaults)}


def desired_limits(probes):
    non_file = [{k: v for k, v in p['limits'].items() if k != 'nofile'} for p in probes]
    require(all(values == non_file[0] for values in non_file),
            'Workers have different non-nofile ulimits; review those settings before applying a common override.')
    soft = max([SOFT] + [p['soft'] for p in probes] + [p['limits'].get('nofile', (0, 0))[0] for p in probes])
    hard = max([HARD, soft] + [p['hard'] for p in probes] + [p['limits'].get('nofile', (0, 0))[1] for p in probes])
    def value(number):
        return '-1' if number == math.inf else str(number)
    entries = [entry for entry in probes[0]['defaults'] if entry.split('=', 1)[0] != 'nofile']
    return entries + ['nofile=' + value(soft) + ':' + value(hard)]


def contents(file):
    source = file.get('contents', {}).get('source', '')
    require(source.startswith('data:') and ',' in source, 'Expected inline data in the nofile MachineConfig.')
    require(not file.get('contents', {}).get('compression') and not file.get('append'),
            'Compressed or appended nofile configuration requires manual review.')
    header, data = source.split(',', 1)
    raw = unquote_to_bytes(data)
    return (base64.b64decode(raw, validate=True) if ';base64' in header else raw).decode()


def target_file(resource):
    files = resource.get('spec', {}).get('config', {}).get('storage', {}).get('files', [])
    found = [file for file in files if file['path'] == CONFIG_PATH]
    require(len(found) <= 1, 'Multiple entries manage the nofile file.')
    return found[0] if found else None


def has_contents(resource, expected):
    file = target_file(resource)
    return file is not None and contents(file) == expected


class Setup:
    def __init__(self, args):
        self.args = args
        self.cli = ['oc', '--request-timeout=30s']
        self.deadline = time.monotonic() + args.timeout
        self.pool_uid = None
        self.name = '96-' + args.pool + '-crio-limit-files'

    def command(self, *args, payload=None, timeout=40):
        remaining = self.deadline - time.monotonic()
        require(remaining > 0, 'Timed out waiting for workers. Inspect oc describe mcp ' + self.args.pool)
        process = subprocess.Popen(self.cli + list(args), stdin=subprocess.PIPE if payload is not None else None,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            output, error = process.communicate(payload, timeout=min(timeout, remaining))
        except (subprocess.TimeoutExpired, KeyboardInterrupt) as problem:
            # Allow oc debug to delete its temporary pod on interruption.
            process.send_signal(signal.SIGINT)
            try:
                process.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()
            if isinstance(problem, KeyboardInterrupt):
                raise
            raise SetupError('Command timed out; inspect worker status and any remaining debug pods.') from problem
        require(process.returncode == 0, error.strip() or output.strip() or 'oc command failed')
        return output

    def get(self, resource, name=None, optional=False):
        args = ['get', resource]
        if name:
            args.append(name)
        if optional:
            args.append('--ignore-not-found')
        output = self.command(*args, '-o', 'json')
        return json.loads(output) if output.strip() else None

    def pool(self):
        pool = self.get(MCP, self.args.pool)
        require(self.pool_uid in (None, pool['metadata']['uid']), 'MachineConfigPool was replaced; rerun the script.')
        self.pool_uid = pool['metadata']['uid']
        require(not pool['metadata'].get('deletionTimestamp'), 'MachineConfigPool is being deleted.')
        require(not pool['spec'].get('paused'), 'MachineConfigPool is paused; resume it before running this script.')
        for condition in pool.get('status', {}).get('conditions', []):
            if condition['type'].endswith('Degraded') and condition['status'] == 'True':
                raise SetupError('MachineConfigPool is degraded: ' + condition.get('message', condition['type']))
        return pool

    def nodes(self, pool):
        nodes = [node for node in self.get('nodes')['items']
                 if matches(node['metadata'].get('labels', {}), pool['spec']['nodeSelector'])]
        require(nodes, 'The selected worker pool has no nodes.')
        for node in nodes:
            labels = node['metadata'].get('labels', {})
            require(not any(role in labels for role in ('node-role.kubernetes.io/master',
                                                        'node-role.kubernetes.io/control-plane')),
                    'This script targets worker-only nodes; control-plane nodes require separate configuration.')
        return nodes

    def check_scope(self, pool):
        labels = {ROLE: self.args.pool}
        require(matches(labels, pool['spec']['machineConfigSelector']),
                'Pool does not select the expected MachineConfig role label: ' + self.args.pool)
        for other in self.get(MCP)['items']:
            if other['metadata']['uid'] != self.pool_uid:
                require(not matches(labels, other['spec'].get('machineConfigSelector')),
                        'Role label also affects pool ' + other['metadata']['name'] +
                        '; configure custom worker pools separately with --pool.')

    def converged(self, pool, nodes):
        status = pool.get('status', {})
        conditions = {c['type']: c['status'] for c in status.get('conditions', [])}
        desired = pool['spec'].get('configuration', {}).get('name')
        count = len(nodes)
        if not (desired and status.get('observedGeneration', 0) >= pool['metadata']['generation']
                and status.get('configuration', {}).get('name') == desired
                and conditions.get('Updated') == 'True' and conditions.get('Updating') == 'False'
                and conditions.get('Degraded') == 'False'
                and status.get('machineCount') == count and status.get('readyMachineCount') == count
                and status.get('updatedMachineCount') == count and status.get('unavailableMachineCount', 0) == 0):
            return False
        for node in nodes:
            annotations = node['metadata'].get('annotations', {})
            if (node['metadata'].get('deletionTimestamp') or node.get('spec', {}).get('unschedulable')
                    or not any(c['type'] == 'Ready' and c['status'] == 'True' for c in node['status']['conditions'])
                    or annotations.get(PREFIX + 'state') != 'Done'
                    or annotations.get(PREFIX + 'currentConfig') != desired
                    or annotations.get(PREFIX + 'desiredConfig') != desired):
                return False
        return True

    def wait_ready(self, expected=None, generation=None):
        while time.monotonic() < self.deadline:
            pool = self.pool()
            nodes = self.nodes(pool)
            ready = self.converged(pool, nodes)
            if expected is not None:
                applied = self.get(MC, self.name)
                require(applied['metadata']['generation'] == generation and has_contents(applied, expected),
                        'The nofile MachineConfig changed during rollout; inspect it before rerunning.')
                desired = pool['spec'].get('configuration', {})
                ready = ready and any(source['name'] == self.name for source in desired.get('source', []))
                if ready:
                    ready = has_contents(self.get(MC, desired['name']), expected)
            if ready:
                return pool, nodes
            status = pool.get('status', {})
            print('Waiting for ' + self.args.pool + ': updated ' + str(status.get('updatedMachineCount', 0))
                  + '/' + str(len(nodes)) + ', ready ' + str(status.get('readyMachineCount', 0))
                  + '/' + str(len(nodes)) + '; waiting for the requested configuration.', flush=True)
            time.sleep(min(self.args.poll_interval, max(0, self.deadline - time.monotonic())))
        raise SetupError('Worker rollout timed out. Run oc describe mcp ' + self.args.pool +
                         ' and inspect machine-config-daemon logs; setup is not complete.')

    def inspect(self, nodes):
        probes = []
        for node in nodes:
            name = node['metadata']['name']
            print('Inspecting container limits and running CRI-O configuration on ' + name + ' ...', flush=True)
            output = self.command('debug', 'node/' + name, '--quiet', '--', 'sh', '-ceu', PROBE, timeout=120)
            probe = parse_probe(output)
            print(name + ': nofile soft=' + str(probe['soft']) + ', hard=' + str(probe['hard']), flush=True)
            probes.append(probe)
        return probes

    def plan(self, pool, probes):
        entries = desired_limits(probes)
        text = '[crio.runtime]\ndefault_ulimits = ' + json.dumps(entries) + '\n'
        file = {'path': CONFIG_PATH, 'mode': 420, 'overwrite': True,
                'contents': {'source': 'data:;base64,' + base64.b64encode(text.encode()).decode()}}
        existing = self.get(MC, self.name, optional=True)
        for config in self.get(MC)['items']:
            if (config['metadata']['name'] != self.name
                    and matches(config['metadata'].get('labels', {}), pool['spec']['machineConfigSelector'])):
                require(target_file(config) is None,
                        CONFIG_PATH + ' is already managed by ' + config['metadata']['name'] + '; review that config.')
        if existing is None:
            resource = {'apiVersion': 'machineconfiguration.openshift.io/v1', 'kind': 'MachineConfig',
                        'metadata': {'name': self.name, 'labels': {ROLE: self.args.pool}},
                        'spec': {'config': {'ignition': {'version': '3.2.0'}, 'storage': {'files': [file]}}}}
            return ['create', '-f', '-', '-o', 'json'], resource, text, entries
        require(existing['metadata'].get('labels', {}).get(ROLE) == self.args.pool,
                'Existing MachineConfig has an unexpected role; refusing to retarget it.')
        old = target_file(existing)
        if old:
            old_text = contents(old)
            old_values = tomllib.loads(old_text)
            require(old_values == {'crio': {'runtime': {'default_ulimits': old_values.get('crio', {}).get('runtime', {}).get('default_ulimits')}}},
                    'Existing nofile drop-in contains other settings; preserve those manually before using this script.')
            require(old_values != tomllib.loads(text),
                    'MachineConfig already requests these limits, but containers still receive lower limits. Inspect CRI-O overrides.')
        config = copy.deepcopy(existing['spec']['config'])
        files = config.setdefault('storage', {}).setdefault('files', [])
        if old:
            files[files.index(old)] = file
        else:
            files.append(file)
        patch = [
            {'op': 'test', 'path': '/metadata/uid', 'value': existing['metadata']['uid']},
            {'op': 'test', 'path': '/metadata/resourceVersion', 'value': existing['metadata']['resourceVersion']},
            {'op': 'replace', 'path': '/spec/config', 'value': config},
        ]
        return ['patch', MC, self.name, '--type=json', '--patch-file=/dev/stdin', '-o', 'json'], patch, text, entries

    def run(self):
        require(shutil.which('oc'), 'Install the OpenShift oc CLI first.')
        context = self.command('config', 'current-context').strip()
        require(context, 'No current Kubernetes context is selected.')
        self.cli += ['--context', context]
        print('Context: ' + context + '; worker pool: ' + self.args.pool, flush=True)
        print('Checking nofile >= 4096:1048576. Run this before installing PostgreSQL, Redis and EIC.', flush=True)
        print('Inspection uses temporary node debug pods. A configuration change may drain/reboot workers.', flush=True)
        pool = self.pool()
        self.check_scope(pool)
        pool, nodes = self.wait_ready()
        probes = self.inspect(nodes)
        if all(p['soft'] >= SOFT and p['hard'] >= HARD for p in probes):
            # Recheck after probing so a newly started rollout cannot be reported complete.
            current = self.pool()
            current_nodes = self.nodes(current)
            require(self.converged(current, current_nodes)
                    and current['spec']['configuration']['name'] == pool['spec']['configuration']['name']
                    and {n['metadata']['uid'] for n in nodes} == {n['metadata']['uid'] for n in current_nodes},
                    'Worker state changed during inspection; rerun to verify the new state.')
            print('No patch needed: all workers already meet the nofile requirements.', flush=True)
        else:
            arguments, payload, expected, entries = self.plan(pool, probes)
            print('Required CRI-O defaults (existing other limits preserved): ' + json.dumps(entries), flush=True)
            preview = json.loads(self.command(*arguments, '--dry-run=server', payload=json.dumps(payload)))
            require(has_contents(preview, expected), 'Server dry-run did not retain the intended nofile configuration.')
            if self.args.dry_run:
                print('Dry run complete: would apply ' + self.name + ', wait for workers, and verify fresh container limits.')
                return
            # Do not mix this change into a rollout that started during inspection.
            current = self.pool()
            current_nodes = self.nodes(current)
            require(self.converged(current, current_nodes)
                    and current['spec']['configuration']['name'] == pool['spec']['configuration']['name']
                    and {n['metadata']['uid'] for n in nodes} == {n['metadata']['uid'] for n in current_nodes},
                    'Worker state changed during inspection; wait for it and rerun.')
            applied = json.loads(self.command(*arguments, payload=json.dumps(payload)))
            print('Applied ' + self.name + '. Waiting for the worker rollout ...', flush=True)
            pool, nodes = self.wait_ready(expected, applied['metadata']['generation'])
            final = self.inspect(nodes)
            require(all(p['soft'] >= SOFT and p['hard'] >= HARD and p['limits'] == parse_limits(entries) for p in final),
                    'Workers updated, but runtime limits did not match the requested values; inspect conflicting CRI-O configuration.')
            current = self.pool()
            current_nodes = self.nodes(current)
            require(self.converged(current, current_nodes)
                    and current['spec']['configuration']['name'] == pool['spec']['configuration']['name']
                    and {n['metadata']['uid'] for n in nodes} == {n['metadata']['uid'] for n in current_nodes},
                    'Worker state changed during final verification; rerun to verify the new state.')
        if self.args.dry_run:
            print('Dry run complete. No MachineConfig changes were needed.')
        else:
            print('All done: all ' + str(len(nodes)) + ' workers are Ready and verified with nofile >= 4096:1048576.\n'
                  'You can now continue with PostgreSQL, Redis and EIC installation.', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--pool', default='worker', help='Worker MachineConfigPool and role label (default: worker)')
    parser.add_argument('--timeout', type=int, default=1800, help='Total timeout in seconds (default: 1800)')
    parser.add_argument('--poll-interval', type=int, default=10, help='Rollout polling interval in seconds (default: 10)')
    parser.add_argument('--dry-run', action='store_true', help='Inspect workers and validate the patch without applying it')
    args = parser.parse_args()
    require(args.pool != 'master', 'Only worker pools are supported.')
    require(args.timeout > 0 and args.poll_interval > 0, 'Timeout and polling interval must be positive.')
    Setup(args).run()


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print('Stopped. Any submitted MachineConfig remains in place; verify its rollout before proceeding.', file=sys.stderr)
        sys.exit(130)
    except (SetupError, OSError, ValueError, KeyError, TypeError) as error:
        print('ERROR: ' + str(error), file=sys.stderr)
        sys.exit(1)
