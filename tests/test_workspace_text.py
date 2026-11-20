"""Execute production guest scripts against a temporary filesystem.

The small adapters supply GNU command spellings on macOS; they do not duplicate
the read, revision-check, locking, recovery, or publication algorithms.
"""
import concurrent.futures
import os
from pathlib import Path
import subprocess
import unittest

import test_workspace_files as workspace_files
from test_workspace_files import read_message, message, BOX


GNU_ADAPTER = r'''#!/usr/bin/python3
import fcntl, hashlib, os, pathlib, shutil, stat, sys
name = pathlib.Path(sys.argv[0]).name
args = [a for a in sys.argv[1:] if a != '--']
if name == 'stat':
    info = os.stat(args[-1])
    print('%s:%s:%s:%s:%s' % (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns))
elif name == 'flock': fcntl.flock(int(args[-1]), fcntl.LOCK_EX)
elif name == 'sha256sum': print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest() + '  -')
elif name == 'chmod':
    if args[0].startswith('--reference='): mode = stat.S_IMODE(os.stat(args[0].split('=', 1)[1]).st_mode)
    else: mode = int(args[0], 8)
    os.chmod(args[-1], mode)
elif name == 'cp': shutil.copy2(args[-2], args[-1])
elif name == 'mv': os.replace(args[-2], args[-1])
elif name == 'ln':
    try: os.link(args[-2], args[-1])
    except FileExistsError: sys.exit(1)
'''


class WorkspaceText(unittest.TestCase):
    setUpFixture = workspace_files.WorkspaceWorker.setUpFixture
    calls = workspace_files.WorkspaceWorker.calls
    close = workspace_files.WorkspaceWorker.close
    request = workspace_files.WorkspaceWorker.request

    def setUp(self):
        workspace_files.WorkspaceWorker.setUp(self)
        tools = self.guest / 'tools'
        tools.mkdir()
        for name in ('stat', 'flock', 'chmod', 'cp', 'mv', 'ln', 'sha256sum'):
            target = tools / name
            target.write_text(GNU_ADAPTER)
            target.chmod(0o700)

    # Inherited transfer cases are covered by WorkspaceWorker itself.
    def read(self, path='/workspace/todo.md'):
        return self.request(dict(kind='readText', path=path))

    def save(self, text, revision, path='/workspace/todo.md'):
        return self.request(dict(kind='saveText', path=path, text=text, revision=revision))

    def test_editor_round_trip_and_recovery(self):
        original = 'first\r\n雪 👩🏽‍💻\r\nlast'
        target = self.workspace / 'todo.md'
        target.write_bytes(original.encode())
        target.chmod(0o751)
        snapshot = self.read()
        self.assertEqual(snapshot['text'], original)
        self.assertEqual(snapshot['kind'], 'text')
        saved = self.save('changed\r\n雪 👩🏽‍💻\r\nlast', snapshot['revision'])
        self.assertEqual(saved['kind'], 'savedText', saved)
        self.assertEqual(target.read_bytes(), saved['text'].encode())
        self.assertEqual(target.stat().st_mode & 0o777, 0o751)
        recovery = self.guest / saved['recoveryPath'].lstrip('/')
        self.assertEqual(recovery.read_bytes(), original.encode())
        self.assertFalse(list(self.workspace.glob('.mybox-edit.*')))
        again = self.save('another update', saved['revision'])
        self.assertEqual(again['kind'], 'savedText', again)
        self.assertEqual(again['recoveryPath'], saved['recoveryPath'])
        self.assertEqual(recovery.read_bytes(), saved['text'].encode())
        self.assertEqual(len(list(self.workspace.glob('.mybox-recovery-*'))), 1)
        self.assertFalse(list(self.workspace.glob('.mybox-backup.*')))

    def test_editor_stale_revision_never_overwrites_new_text(self):
        target = self.workspace / 'todo.md'
        target.write_text('base\n')
        old = self.read()
        target.write_text('agent changed it\n')
        response = self.save('my edit\n', old['revision'])
        self.assertEqual(response['kind'], 'textConflict', response)
        self.assertEqual(response['text'], 'agent changed it\n')
        self.assertEqual(target.read_text(), 'agent changed it\n')

    def test_editor_creation_and_deletion_require_matching_version(self):
        missing = self.read()
        self.assertEqual(missing['revision'], 'missing')
        created = self.save('', 'missing')
        self.assertEqual(created['kind'], 'savedText', created)
        self.assertEqual(self.save('replace', 'missing')['kind'], 'textConflict')
        (self.workspace / 'todo.md').unlink()
        deleted = self.save('restore', created['revision'])
        self.assertEqual(deleted['kind'], 'textConflict')
        self.assertEqual(deleted['revision'], 'missing')
        self.assertFalse((self.workspace / 'todo.md').exists())

    def test_editor_refuses_binary_large_files_and_links(self):
        target = self.workspace / 'todo.md'
        for content in (b'a\x00b', b'\xff', b'x' * (1048576 + 1)):
            target.write_bytes(content)
            self.assertEqual(self.read()['kind'], 'error')
        outside = self.guest / 'outside'; outside.mkdir()
        (outside / 'keep').write_text('keep')
        target.unlink(); target.symlink_to(outside / 'keep')
        self.assertEqual(self.read()['kind'], 'error')
        self.assertEqual(self.save('bad', 'missing')['kind'], 'error')
        link = self.workspace / 'link'; link.symlink_to(outside)
        self.assertEqual(self.read('/workspace/link/keep')['kind'], 'error')
        self.assertEqual((outside / 'keep').read_text(), 'keep')
        self.assertEqual(self.read('/etc/passwd')['kind'], 'error')
        self.assertEqual(self.save('bad', 'invalid')['kind'], 'error')

    def test_editor_exact_names_and_no_shell_evaluation(self):
        name = 'note e\u0301 雪\n$(touch injected) `true`.txt'
        path = '/workspace/' + name
        response = self.save('$(touch injected)\n`true`\n', 'missing', path)
        self.assertEqual(response['kind'], 'savedText', response)
        self.assertEqual((self.workspace / name).read_text(), '$(touch injected)\n`true`\n')
        self.assertFalse((self.workspace / 'injected').exists())
        self.assertEqual(self.read(path)['text'], response['text'])

    def test_editor_concurrent_checked_saves_accept_only_one(self):
        target = self.workspace / 'todo.md'; target.write_text('base')
        revision = self.read()['revision']
        second = subprocess.Popen([BOX, 'files', 'demo'], env=self.environment,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertEqual(read_message(second.stdout)['kind'], 'ready')
            def write_second():
                second.stdin.write(message(dict(kind='saveText', path='/workspace/todo.md', text='second', revision=revision)))
                second.stdin.flush()
                return read_message(second.stdout)
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                other = pool.submit(write_second)
                own = self.save('first', revision)
                responses = [own, other.result(timeout=20)]
            self.assertCountEqual([r['kind'] for r in responses], ['savedText', 'textConflict'])
            accepted = next(r for r in responses if r['kind'] == 'savedText')
            self.assertEqual(target.read_text(), accepted['text'])
        finally:
            second.stdin.close(); second.wait(timeout=10)
            second.stdout.close(); second.stderr.close()
