#!/usr/bin/env python3
"""Disposable subprocess journeys; never opens live user task or memory state."""
import argparse
import concurrent.futures
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--helper', required=True, type=Path)
parser.add_argument('--runtime-dir', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
ARGS = parser.parse_args()
sys.path.insert(0, str(ARGS.runtime_dir))
from planisphere_tasks import TaskStore, fingerprint
import planisphere_work_views as work_views

def identity():
    return str(uuid.uuid4())

def request(action, **fields):
    return dict(action=action, profile='synthetic-person', operation_id=identity(), **fields)

def fact(record_id='fact', revision=0, body='Synthetic preference: use blue.'):
    return request('commit', record_id=record_id, expected_revision=revision, body=body,
                   source_excerpt=body, event_id=identity(), attribution='human_statement', kind='preference')

class JourneyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='memory-journey-', dir='/private/tmp')
        self.base = Path(self.temp.name).resolve()
        self.root = self.base / 'private-memory'

    def tearDown(self):
        self.temp.cleanup()

    def call(self, payload, *, expected=0, crash=None, root=None):
        env = dict(os.environ)
        if crash:
            env['PLANISPHERE_MEMORY_TEST_CRASH'] = crash
        result = subprocess.run([str(ARGS.helper), '--state-directory', str(root or self.root)],
                                input=json.dumps(payload), text=True, capture_output=True,
                                env=env, timeout=15)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return json.loads(result.stdout) if result.stdout else None

    def test_no_vault_cross_chat_journey_uses_existing_owner(self):
        # Both namespaces and both observed chats are synthetic. Original task code is unchanged.
        project_root = self.base / 'empty-project'
        project_root.mkdir()
        owner_root = self.base / 'task-owner'
        chat_a, chat_b = identity(), identity()
        scope = dict(host='codex', session_id=chat_a, cwd=str(project_root), basis='prototype fixture')
        owner = TaskStore(owner_root, scope)
        turn = identity()
        owner.begin(turn, fingerprint('Prepare the sample; keep publication held.'), event_sequence=1)
        record = dict(task_id='sample-task', outcome='Prepare the sample',
                      origin=dict(message_id=turn, text='Prepare the sample; keep publication held.'),
                      status='active', next_action='Prepare a local sample', retrieval_query='sample release hold',
                      subtasks=[dict(id='sample', text='Prepare a local sample', status='open', evidence=[])],
                      corrections=[dict(id='hold', text='Publication remains held.', status='open', evidence=[])],
                      evidence=['Synthetic direct instruction'])
        task_state = owner.put(record, 0, turn, 'Fixture instruction interpretation')
        self.call(request('bootstrap'))
        self.call(request('bind_owner', owner_id=fingerprint(scope), host_id='fixture-installation', project_id='fixture-project'))
        self.call(request('reference_task', reference_id='task-link', owner_id=fingerprint(scope),
                          task_id=record['task_id'], source_revision=task_state['revision']))
        self.call(fact())
        self.call(fact(revision=1, body='Synthetic correction: use green.'))
        turn2 = identity()
        owner.begin(turn2, fingerprint('Use green; publication is still held.'), event_sequence=2)
        corrected = copy.deepcopy(record)
        corrected['corrections'].append(dict(id='color', text='Use green.', status='resolved', evidence=['Synthetic second instruction']))
        task_state = owner.put(corrected, task_state['revision'], turn2, 'Apply color correction, preserve publication hold')
        self.call(request('reference_task', reference_id='task-link', owner_id=fingerprint(scope),
                          task_id=record['task_id'], source_revision=task_state['revision']))
        # Every helper call is a new process. The new chat has no task in its direct session scope.
        resumed = self.call(request('resume'))
        self.assertEqual(resumed['records'][0]['body'], 'Synthetic correction: use green.')
        new_owner = TaskStore(self.base / 'new-chat-owner', dict(scope, session_id=chat_b))
        self.assertIsNone(new_owner.get()['active'])
        snapshot = dict(observed_at=time.time(), host_id='local',
                        projects=[dict(projectId='fixture-project', hostId='local', projectKind='local',
                                       path=str(project_root), label='Synthetic project')],
                        threads=[dict(id=chat, hostId='local', kind='codex', cwd=str(project_root),
                                      projectId='fixture-project', title='Synthetic chat') for chat in [chat_a, chat_b]])
        settings = dict(state_root=str(owner_root), work_views=dict(host_id='local'))
        view = work_views.command(settings, dict(session_id=chat_b, cwd=str(project_root), host='codex'),
                                  dict(action='project-work-get', project_id='fixture-project', snapshot=snapshot))
        self.assertEqual(view['task_count'], 1)
        recovered = view['tasks'][0]['record']
        self.assertEqual(recovered['task_id'], 'sample-task')
        self.assertEqual(recovered['corrections'][0]['status'], 'open')
        self.assertEqual(recovered['corrections'][1]['text'], 'Use green.')
        self.assertEqual(resumed['task_references'][0]['source_revision'], str(task_state['revision']))
        deleted = self.call(request('forget', record_id='fact', expected_revision=2))
        self.assertEqual(deleted['deletion_state'], 'complete')
        self.assertEqual(self.call(request('resume'))['records'], [])
        self.assertFalse(self.call(request('forget_reference', reference_id='task-link'))['source_deleted'])
        self.assertEqual(owner.get()['active']['task_id'], 'sample-task')
        self.assertEqual(owner.get()['active']['corrections'][0]['status'], 'open')

    def test_crash_after_record_commit_recovers_projection_once(self):
        create = fact()
        self.call(create, crash='committed', expected=86)
        state = self.call(request('status'))
        self.assertEqual(state['records'], 1)
        self.assertEqual(state['pending_projections'], 0)
        self.call(create)
        self.assertEqual(len(list(self.root.glob('*.md'))), 1)

    def test_crash_after_file_publication_recovers_without_duplicate(self):
        create = fact()
        self.call(create, crash='projection_published', expected=86)
        self.assertEqual(self.call(request('recover'))['pending_projections'], 0)
        self.call(create)
        self.assertEqual(len(list(self.root.glob('*.md'))), 1)

    def test_interrupted_forget_purges_files_and_database(self):
        canary = 'private-canary-' + identity()
        create = fact(body=canary)
        self.call(create)
        self.call(request('forget', record_id='fact', expected_revision=1), crash='forget_committed', expected=86)
        self.assertEqual(self.call(request('recover'))['pending_deletions'], 0)
        for file in self.root.iterdir():
            self.assertNotIn(canary.encode(), file.read_bytes(), file.name)
        delayed = dict(create, record_id='new-id', operation_id=identity())
        self.call(delayed, expected=1)
        self.assertEqual(self.call(request('resume'))['records'], [])

    def test_competing_corrections_have_one_winner(self):
        self.call(fact())
        payloads = [fact(revision=1, body=f'Writer {i}') for i in range(2)]
        def run(payload):
            r = subprocess.run([str(ARGS.helper), '--state-directory', str(self.root)],
                               input=json.dumps(payload), text=True, capture_output=True, timeout=15)
            return r.returncode, json.loads(r.stdout)
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(run, payloads))
        self.assertEqual(sorted(r[0] for r in results), [0, 1], results)
        self.assertEqual(self.call(request('inspect', record_id='fact'))['revision'], 2)

    def test_concurrent_first_use_is_idempotent(self):
        for attempt in range(8):
            root = self.base / f'startup-{attempt}'
            def run(_):
                return self.call(request('bootstrap'), root=root)
            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                results = list(pool.map(run, range(4)))
            self.assertTrue(all(r['profile'] == 'synthetic-person' for r in results))
            self.assertEqual(len(list(root.glob('memory.sqlite3'))), 1)

    def test_external_projection_symlink_is_not_followed(self):
        self.call(fact())
        projection = next(self.root.glob('*.md'))
        outside = self.base / 'outside.txt'
        outside.write_text('Preserve external file')
        projection.unlink()
        projection.symlink_to(outside)
        result = self.call(request('forget', record_id='fact', expected_revision=1))
        self.assertEqual(result['deletion_state'], 'pending')
        self.assertEqual(outside.read_text(), 'Preserve external file')

    def test_replaced_generation_is_not_acknowledged(self):
        self.call(fact('claim'))
        declaration = request('bundle', bundle_id='g', question='Which sample?', declaration_event='declared',
                              all_of=[dict(record_id='claim', revision=1)])
        self.call(declaration)
        epoch = self.call(request('session', session_id='chat'))
        offer = self.call(request('offer', bundle_id='g', budget_bytes=2048, **epoch))
        self.call(fact('claim', revision=1, body='Corrected sample'))
        self.call(request('ack', offer_id=offer['offer_id'], **epoch), expected=1)
        gap = self.call(request('offer', bundle_id='g', budget_bytes=2048, **epoch))
        self.assertEqual(gap['gaps'][0]['reason'], 'stale')


if __name__ == '__main__':
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(JourneyTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    names = ['planisphere_tasks.py', 'planisphere_feedback.py', 'planisphere_work_views.py']
    report = dict(scope='Disposable synthetic subprocess journeys; no live vaults or host hook installation',
                  tests_run=result.testsRun, failures=len(result.failures), errors=len(result.errors),
                  helper_sha256=hashlib.sha256(ARGS.helper.read_bytes()).hexdigest(),
                  runtime_directory=str(ARGS.runtime_dir),
                  runtime_sources={name: hashlib.sha256((ARGS.runtime_dir/name).read_bytes()).hexdigest() for name in names},
                  cases=[t.id().split('.')[-1] for t in unittest.defaultTestLoader.loadTestsFromTestCase(JourneyTests)])
    ARGS.output.parent.mkdir(parents=True, exist_ok=True)
    ARGS.output.write_text(json.dumps(report, indent=2) + '\n')
    sys.exit(not result.wasSuccessful())
