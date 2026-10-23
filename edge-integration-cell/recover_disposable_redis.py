# SPDX-FileCopyrightText: 2026 SAP edge team
# SPDX-License-Identifier: Apache-2.0

"""Post-rollout recovery for a single-node Redis with disposable database data.

Invoked by fix_pdb_for_node_rollout.sh --recover-disposable-redis.
Cluster configuration is restored through the operator; only databases already
in recovery are restored empty. No PVCs, Secrets or PostgreSQL objects are changed.
"""

import argparse
import json
import subprocess
import sys
import time


REC = "redisenterpriseclusters.app.redislabs.com"
REDB = "redisenterprisedatabases.app.redislabs.com"
MCP = "machineconfigpools.machineconfiguration.openshift.io"
CONTAINER = "redis-enterprise-node"

# Inspect through loopback inside the selected pod. Credentials remain in the
# container and only the listed non-secret fields are returned to the caller.
INSPECT = r'''
import base64, json, ssl, urllib.request
from pathlib import Path
result = {
    'bootstrapped': Path('/etc/opt/redislabs/node.id').is_file(),
    'configuration_available': Path('/opt/persistent/ccs/ccs-redis.rdb').is_file(),
}
if result['bootstrapped']:
    credentials = Path('/opt/redislabs/credentials')
    auth = (credentials.joinpath('username').read_text().strip() + ':' +
            credentials.joinpath('password').read_text().strip())
    request = urllib.request.Request('https://localhost:9443/v1/bdbs', headers={
        'Authorization': 'Basic ' + base64.b64encode(auth.encode()).decode()})
    # The Redis management API uses its self-signed certificate on loopback.
    with urllib.request.urlopen(request, context=ssl._create_unverified_context(), timeout=15) as response:
        result['databases'] = [{k: db.get(k) for k in ('uid', 'name', 'status')}
                               for db in json.load(response)]
print(json.dumps(result))
'''


class RecoveryError(Exception):
    """A recovery precondition or operation failed."""


def require(condition, message):
    if not condition:
        raise RecoveryError(message)


def ready(pod):
    return any(c['type'] == 'Ready' and c['status'] == 'True'
               for c in pod.get('status', {}).get('conditions', []))


class Recovery:
    def __init__(self, args):
        self.args = args
        self.cli = [args.cli, '--context', args.context, '--request-timeout=30s']
        self.uid = None
        self.deadline = time.monotonic() + args.timeout

    def command(self, *args):
        remaining = self.deadline - time.monotonic()
        require(remaining > 0, 'Recovery timed out; inspect the operator logs and rerun to resume.')
        try:
            result = subprocess.run(self.cli + list(args), text=True, capture_output=True,
                                    timeout=min(35, remaining), check=False)
        except subprocess.TimeoutExpired as error:
            raise RecoveryError('Command timed out; inspect Redis state before rerunning.') from error
        require(result.returncode == 0, result.stderr.strip() or result.stdout.strip() or 'Command failed')
        return result.stdout

    def get(self, resource, name=None, namespaced=True):
        args = ['get', resource]
        if name:
            args.append(name)
        if namespaced:
            args += ['-n', self.args.namespace]
        return json.loads(self.command(*args, '-o', 'json'))

    def cluster(self):
        cluster = self.get(REC, self.args.cluster)
        require(not cluster['metadata'].get('deletionTimestamp'), 'Selected REC is being deleted.')
        uid = cluster['metadata']['uid']
        require(self.uid in (None, uid), 'Selected REC was replaced; refusing to follow the new cluster.')
        self.uid = uid
        require(cluster['spec'].get('nodes') == 1, 'Recovery mode requires exactly one Redis node; HA clusters are excluded.')
        require(cluster['spec'].get('persistentSpec', {}).get('enabled') is True,
                'Recovery requires a persistent volume containing the saved cluster configuration.')
        return cluster

    def pool_ready(self):
        pool = self.get(MCP, self.args.machine_config_pool, namespaced=False)
        status = pool.get('status', {})
        conditions = {c['type']: c['status'] for c in status.get('conditions', [])}
        count = status.get('machineCount', 0)
        require(count > 0 and status.get('updatedMachineCount') == count
                and status.get('readyMachineCount') == count
                and conditions.get('Updated') == 'True'
                and conditions.get('Updating') == 'False'
                and conditions.get('Degraded') == 'False',
                'Worker rollout is not complete and healthy; finish the rollout before Redis recovery.')

    def pods(self):
        controllers = {s['metadata']['uid'] for s in self.get('statefulsets')['items']
                       if any(o['uid'] == self.uid for o in s['metadata'].get('ownerReferences', []))}
        return [p for p in self.get('pods')['items']
                if any(o['uid'] in controllers for o in p['metadata'].get('ownerReferences', []))]

    def single_pod(self):
        pods = self.pods()
        require(len(pods) == 1, 'Expected one owned Redis pod; resolve scheduling or operator errors first.')
        pod = pods[0]
        require(not pod['metadata'].get('deletionTimestamp'),
                'Redis is still terminating; resolve the shutdown/drain before post-rollout recovery.')
        require(pod.get('status', {}).get('phase') == 'Running',
                'Redis pod is not Running; resolve scheduling, storage or image errors first.')
        require(any(c['name'] == CONTAINER and c.get('state', {}).get('running') is not None
                    for c in pod.get('status', {}).get('containerStatuses', [])),
                'Redis container is not running; inspect its startup logs first.')
        node = self.get('nodes', pod['spec']['nodeName'], namespaced=False)
        require(ready(node) and not node.get('spec', {}).get('unschedulable'),
                'Redis worker is not Ready and schedulable; finish node maintenance first.')
        return pod

    def inspect(self, pod):
        return json.loads(self.command('exec', '-n', self.args.namespace, pod['metadata']['name'],
                                       '-c', CONTAINER, '--', '/opt/redislabs/bin/python3', '-c', INSPECT))

    def wait_running(self):
        previous = None
        while time.monotonic() < self.deadline:
            cluster = self.cluster()
            state = cluster.get('status', {}).get('state')
            if state != previous:
                print('Redis cluster state: ' + str(state), flush=True)
                previous = state
            pods = self.pods()
            if (state == 'Running' and not cluster['spec'].get('clusterRecovery')
                    and len(pods) == 1 and not pods[0]['metadata'].get('deletionTimestamp') and ready(pods[0])):
                return self.single_pod()
            time.sleep(min(5, max(0, self.deadline - time.monotonic())))
        raise RecoveryError('Recovery timed out; inspect the operator logs and rerun to resume.')

    def databases(self, snapshot):
        databases = snapshot.get('databases')
        require(isinstance(databases, list), 'Could not read current Redis database state.')
        for database in databases:
            require(str(database.get('uid', '')).isdigit(), 'Redis returned an invalid database ID.')
            require(database.get('status') in ('active', 'recovery'),
                    'Database is neither active nor in recovery; inspect its Redis status first.')
        return databases

    def run(self):
        print('Disposable Redis recovery: ' + self.args.namespace + '/' + self.args.cluster, flush=True)
        print('Databases in recovery will restart EMPTY. Healthy databases are left alone.', flush=True)
        self.pool_ready()
        cluster = self.cluster()
        in_progress = bool(cluster['spec'].get('clusterRecovery'))
        if in_progress:
            if self.args.dry_run:
                print('Dry run: would wait for the existing cluster recovery and restore recovery databases empty.')
                return
            pod = self.wait_running()
        else:
            pod = self.single_pod()
            snapshot = self.inspect(pod)
            if not snapshot['bootstrapped']:
                require(cluster.get('status', {}).get('state') in ('Running', 'RunningRollingUpdate'),
                        'REC is not in the known post-restart state; inspect the operator before recovery.')
                require(snapshot['configuration_available'], 'No saved Redis cluster configuration found on the PVC.')
                databases = [d for d in self.get(REDB)['items']
                             if d.get('spec', {}).get('redisEnterpriseCluster', {}).get('name') == self.args.cluster]
                require(any(d.get('status', {}).get('databaseUID') for d in databases),
                        'No previously created database found; this may be an initial deployment, not recovery.')
                logs = self.command('logs', '-n', self.args.namespace, pod['metadata']['name'],
                                    '-c', 'bootstrapper', '--tail=30')
                require('No pod has been labeled as master pod yet' in logs,
                        'Bootstrap failure differs from the known single-node restart; inspect bootstrapper logs.')
                print('Detected lost master after single-node restart; recover the saved cluster configuration.', flush=True)
                # Recheck identity, pool and pod before requesting destructive recovery.
                cluster = self.cluster()
                self.pool_ready()
                current = self.single_pod()
                require(current['metadata']['uid'] == pod['metadata']['uid'] and not self.inspect(current)['bootstrapped'],
                        'Redis pod changed or bootstrapped during inspection; rerun to reassess.')
                patch = [
                    {'op': 'test', 'path': '/metadata/uid', 'value': self.uid},
                    {'op': 'test', 'path': '/metadata/resourceVersion', 'value': cluster['metadata']['resourceVersion']},
                    {'op': 'add', 'path': '/spec/clusterRecovery', 'value': True},
                ]
                arguments = ['patch', REC, self.args.cluster, '-n', self.args.namespace,
                             '--type=json', '-p', json.dumps(patch), '-o', 'json']
                preview = json.loads(self.command(*arguments, '--dry-run=server'))
                require(preview['spec'].get('clusterRecovery') is True, 'Installed REC API does not retain clusterRecovery.')
                if self.args.dry_run:
                    print('Dry run: would request clusterRecovery, wait for Ready, then restore recovery databases empty.')
                    return
                self.command(*arguments)
                pod = self.wait_running()
            else:
                require(ready(pod) and cluster.get('status', {}).get('state') == 'Running',
                        'Redis is bootstrapped but unhealthy; inspect readiness errors before recovery.')

        databases = self.databases(self.inspect(pod))
        for database in databases:
            if database['status'] == 'active':
                print('Database db:' + str(database['uid']) + ' is active; no reset.', flush=True)
                continue
            identifier = 'db:' + str(database['uid'])
            print('Restore ' + identifier + ' configuration with an EMPTY database.', flush=True)
            if self.args.dry_run:
                continue
            self.cluster()
            self.pool_ready()
            current = self.single_pod()
            require(current['metadata']['uid'] == pod['metadata']['uid'] and ready(current),
                    'Redis pod changed or became unready; rerun to resume.')
            latest = {str(d['uid']): d['status'] for d in self.databases(self.inspect(current))}
            if latest.get(str(database['uid'])) == 'active':
                continue
            require(latest.get(str(database['uid'])) == 'recovery', 'Database state changed; rerun to reassess.')
            print(self.command('exec', '-n', self.args.namespace, pod['metadata']['name'], '-c', CONTAINER,
                               '--', 'rladmin', 'recover', 'db', identifier, 'only_configuration').strip(), flush=True)
        if self.args.dry_run:
            print('Dry run complete. No resources changed.')
            return
        self.cluster()
        final_pod = self.single_pod()
        require(ready(final_pod), 'Redis pod is not Ready after recovery.')
        final = self.databases(self.inspect(final_pod))
        require({str(d['uid']) for d in final} == {str(d['uid']) for d in databases},
                'Database inventory changed during recovery; inspect Redis before proceeding.')
        require(all(d['status'] == 'active' for d in final), 'Some Redis databases are not active after recovery.')
        print('Redis is Ready and all databases are active. PostgreSQL and PDBs were unchanged.', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', required=True)
    parser.add_argument('--context', required=True)
    parser.add_argument('--namespace', required=True)
    parser.add_argument('--cluster', required=True)
    parser.add_argument('--machine-config-pool', default='worker')
    parser.add_argument('--timeout', type=int, default=600)
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    require(args.timeout > 0, 'Timeout must be positive.')
    Recovery(args).run()


if __name__ == '__main__':
    try:
        main()
    except (RecoveryError, OSError, ValueError, KeyError) as error:
        print('ERROR: ' + str(error), file=sys.stderr)
        sys.exit(1)
