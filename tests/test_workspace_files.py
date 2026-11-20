"""Exercise the production browser protocol, including binary and hidden files."""
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

import test_cli
from test_cli import FAKE_BACKEND, BOX

ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / '.build/mybox-service-tests'


def message(value):
    data = json.dumps(value).encode()
    return struct.pack('!I', len(data)) + data


def read_message(stream):
    header = stream.read(4)
    if len(header) != 4:
        raise EOFError('Browser closed its stream')
    size, = struct.unpack('!I', header)
    data = stream.read(size)
    if len(data) != size:
        raise EOFError('Truncated browser response')
    return json.loads(data)


def entry(path, kind='file', data=b''):
    return message(dict(kind='entry', entry=dict(path=path, kind=kind, bytes=len(data), modified=0, permissions=448 if kind == 'folder' else 420))) + data


class WorkspaceTransfer(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.destination = self.root / 'destination'
        self.destination.mkdir()

    def unpack(self, data, success=True):
        result = subprocess.run([NATIVE, 'workspace-unpack', self.destination], input=data, capture_output=True, timeout=10)
        self.assertEqual(result.returncode == 0, success, result.stderr)
        return self.destination / 'payload'

    def test_binary_round_trip_hidden_names_and_permissions(self):
        source = self.root / 'source'
        source.mkdir()
        (source / '.git').mkdir()
        (source / '.git' / 'config').write_bytes(b'hidden\0content')
        (source / '.env').write_bytes(b'secret=sample')
        (source / 'empty folder').mkdir()
        binary = os.urandom(2 * 1024 * 1024 + 7)
        name = 'space ü\n$(touch never);.bin'
        (source / name).write_bytes(binary)
        (source / name).chmod(0o751)
        os.utime(source / name, (1_600_000_000, 1_600_000_000))
        (source / '.git').chmod(0o750)
        packed = subprocess.run([NATIVE, 'workspace-pack', source], capture_output=True, check=True).stdout
        target = self.unpack(packed)
        self.assertEqual((target / name).read_bytes(), binary)
        self.assertEqual((target / name).stat().st_mode & 0o777, 0o751)
        self.assertEqual((target / '.git').stat().st_mode & 0o777, 0o750)
        self.assertEqual((target / name).stat().st_mtime, 1_600_000_000)
        self.assertEqual((target / '.git' / 'config').read_bytes(), b'hidden\0content')
        self.assertEqual((target / '.env').read_bytes(), b'secret=sample')
        self.assertTrue((target / 'empty folder').is_dir())

    def test_symlinks_are_never_followed(self):
        source = self.root / 'source'; source.mkdir()
        (source / '.hidden').write_text('yes')
        (source / 'link').symlink_to('/etc/passwd')
        result = subprocess.run([NATIVE, 'workspace-pack', source], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        packed = subprocess.run([NATIVE, 'workspace-pack', source, 'skip'], capture_output=True, check=True).stdout
        target = self.unpack(packed)
        self.assertEqual(list(p.name for p in target.iterdir()), ['.hidden'])

    def test_rejects_bad_frames_paths_duplicates_and_truncation(self):
        invalid = [b'', b'\0\0', struct.pack('!I', 20_000_000), message({}),
                   entry('../escape'), entry('/tmp/escape'), entry('payload/../escape'),
                   entry('payload//escape'), entry('payload/child'), entry('payload', 'link'),
                   entry('payload', 'folder') + entry('payload/a') + entry('payload/a'),
                   entry('payload', 'folder') + entry('payload/a') + entry('payload/a/child'),
                   entry('payload', data=b'123')[:-1],
                   message(dict(kind='transferEnd'))]
        for index, value in enumerate(invalid):
            with self.subTest(index=index):
                self.destination = self.root / str(index); self.destination.mkdir()
                self.unpack(value, success=False)
        self.assertFalse((self.root / 'escape').exists())

    def test_publish_never_replaces_existing_item(self):
        source = self.root / 'source'; source.write_text('new')
        target = self.root / 'target'; target.write_text('original')
        result = subprocess.run([NATIVE, 'workspace-publish', source, target], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_text(), 'original')
        self.assertEqual(source.read_text(), 'new')
        target.unlink()
        subprocess.run([NATIVE, 'workspace-publish', source, target], check=True)
        self.assertEqual(target.read_text(), 'new')

    def test_workspace_path_boundaries(self):
        for path in ('/', '/workspace-other', '/etc/passwd', '/workspace/../etc', 'workspace/a'):
            with self.subTest(path=path):
                self.assertNotEqual(subprocess.run([NATIVE, 'workspace-path', path], capture_output=True).returncode, 0)
        result = subprocess.run([NATIVE, 'workspace-path', '/workspace/./a b/'], capture_output=True, check=True)
        self.assertEqual(result.stdout.strip(), b'/workspace/a b')


# Replace only filesystem operations; normal test fixtures still validate box
# identity, startup, and firewall preparation before the browsing session opens.
BROWSER_BACKEND = r'''
def guest(value):
    return pathlib.Path(os.environ['MYBOX_TEST_GUEST']) / value.lstrip('/')
def copy(source, target):
    import shutil
    if source.is_dir(): shutil.copytree(source, target, symlinks=True)
    else: shutil.copy2(source, target, follow_symlinks=False)
if args[0] == 'exec' and len(args) >= 8 and args[5] in ('mybox-text-read', 'mybox-text-save', 'mybox-files-create-folder'):
    import subprocess
    def decode(value):
        return bytes(int(value[i + 2:i + 5], 8) for i in range(0, len(value), 5)).decode('utf-8')
    def encode(value):
        return ''.join('\\0%03o' % byte for byte in value.encode('utf-8'))
    params = args[6:]
    params[0] = encode(str(guest(decode(params[0]))))
    if args[5] == 'mybox-text-save': params[3] = str(guest(params[3]))
    guest('/tmp').mkdir(exist_ok=True)
    script = args[4].replace('/tmp/mybox-text-read.', str(guest('/tmp/mybox-text-read.')))
    environment = dict(os.environ, PATH=str(guest('/tools')) + ':' + os.environ['PATH'])
    sys.exit(subprocess.run(['/bin/sh', '-c', script, args[5], *params], env=environment).returncode)
elif args[0] == 'exec' and len(args) == 8 and args[5] == 'mybox-files-delete':
    import shutil
    def decode(value):
        return bytes(int(value[i + 2:i + 5], 8) for i in range(0, len(value), 5)).decode('utf-8')
    directory = guest(decode(args[6]))
    if not directory.is_dir() or directory.resolve() != directory: sys.exit(1)
    target = directory / decode(args[7])
    if target.is_symlink() or target.is_file(): target.unlink()
    elif target.is_dir(): shutil.rmtree(target)
    else: sys.exit(1)
elif args[0] == 'exec' and len(args) >= 7 and args[5] == 'mybox-files':
    directory = guest(args[6])
    if not directory.is_dir() or directory.resolve() != directory:
        sys.exit(1)
    if '-printf' in args[4]:
        for child in sorted(directory.iterdir()):
            info = child.lstat()
            kind = 'l' if child.is_symlink() else 'd' if child.is_dir() else 'f'
            sys.stdout.buffer.write(('\0'.join([child.name, kind, str(info.st_size), str(info.st_mtime), '644']) + '\0').encode())
    else:
        target = directory / args[7]
        if target.exists() or target.is_symlink(): sys.exit(1)
        if len(args) == 9: guest(args[8]).rename(target)
elif args[0] == 'exec' and args[2] == '/bin/mkdir':
    guest(args[-1]).mkdir(parents=True)
elif args[0] == 'exec' and args[2] == '/bin/rm':
    import shutil
    shutil.rmtree(guest(args[-1]))
elif args[0] == 'exec' and len(args) >= 7 and args[5] == 'mybox-export':
    source = guest(args[6])
    if not source.exists() or source.is_symlink() or any(x.is_symlink() for x in source.rglob('*')): sys.exit(1)
elif args[0] == 'cp':
    source = guest(args[1].split(':', 1)[1]) if args[1].startswith('mybox-') else pathlib.Path(args[1])
    target = guest(args[2].split(':', 1)[1]) if args[2].startswith('mybox-') else pathlib.Path(args[2])
    copy(source, target)
elif args[:2] == ['volume', 'create']:
'''


class WorkspaceWorker(unittest.TestCase):
    setUpFixture = test_cli.CLI.setUp
    calls = test_cli.CLI.calls

    def setUp(self):
        self.setUpFixture()
        backend = self.directory / 'container'
        backend.write_text(FAKE_BACKEND.replace('if args[:2] == ["volume", "create"]:', BROWSER_BACKEND))
        self.guest = self.directory / 'guest'; self.workspace = self.guest / 'workspace'
        self.workspace.mkdir(parents=True)
        self.environment['MYBOX_TEST_GUEST'] = str(self.guest.resolve())
        self.process = subprocess.Popen([BOX, 'files', 'demo'], env=self.environment,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(self.close)
        self.assertEqual(read_message(self.process.stdout), dict(kind='ready', version=1))

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            self.process.wait(timeout=10)
        self.process.stdout.close(); self.process.stderr.close()

    def request(self, value):
        self.process.stdin.write(message(value)); self.process.stdin.flush()
        return read_message(self.process.stdout)

    def test_nested_upload_download_hidden_files_and_no_overwrite(self):
        (self.workspace / 'nested').mkdir()
        name = 'folder ü\n$(not-a-command)'
        response = self.request(dict(kind='upload', path='/workspace/nested', names=[name]))
        self.assertEqual(response['kind'], 'accept')
        contents = os.urandom(150_000)
        transfer = (entry('payload', 'folder') + entry('payload/.env', data=b'hello') +
                    entry('payload/.git', 'folder') + entry('payload/.git/config', data=contents) + message(dict(kind='transferEnd', skipped=0)))
        self.process.stdin.write(transfer); self.process.stdin.flush()
        self.assertEqual(read_message(self.process.stdout)['kind'], 'done')
        target = self.workspace / 'nested' / name
        self.assertEqual((target / '.git/config').read_bytes(), contents)
        listing = self.request(dict(kind='list', path='/workspace/nested/' + name))
        self.assertEqual({Path(e['path']).name for e in listing['entries']}, {'.env', '.git'})
        self.assertEqual(self.request(dict(kind='upload', path='/workspace/nested', names=[name]))['kind'], 'error')
        self.assertEqual((target / '.env').read_bytes(), b'hello')
        self.assertEqual(self.request(dict(kind='download', path='/workspace/nested/' + name))['kind'], 'accept')
        downloaded = {}
        while True:
            item = read_message(self.process.stdout)
            if item['kind'] == 'transferEnd': break
            metadata = item['entry']
            if metadata['kind'] == 'file': downloaded[metadata['path']] = self.process.stdout.read(metadata['bytes'])
        self.assertEqual(downloaded, {'payload/.env': b'hello', 'payload/.git/config': contents})
        self.assertEqual(self.request(dict(kind='list', path='/workspace'))['kind'], 'listing')

    def test_invalid_requests_do_not_escape_workspace_or_poison_session(self):
        for value in [dict(kind='list', path='/etc'), dict(kind='list', path='/workspace/../etc'),
                      dict(kind='exec', path='/workspace'), dict(kind='upload', path='/workspace', names=['../bad'])]:
            self.assertEqual(self.request(value)['kind'], 'error')
        self.assertEqual(self.request(dict(kind='list', path='/workspace'))['kind'], 'listing')
        self.assertFalse((self.guest / 'bad').exists())

    def test_create_folder_preserves_names_and_refuses_existing_items(self):
        (self.workspace / 'notes').mkdir()
        name = 'folder e\u0301 雪\n$(touch injected)'
        path = '/workspace/notes/' + name
        response = self.request(dict(kind='createFolder', path=path))
        self.assertEqual(response, dict(kind='done', path=path))
        target = self.workspace / 'notes' / name
        self.assertTrue(target.is_dir())
        (target / 'keep.txt').write_text('keep')
        self.assertEqual(self.request(dict(kind='createFolder', path=path))['kind'], 'error')
        self.assertEqual((target / 'keep.txt').read_text(), 'keep')
        self.assertFalse((self.workspace / 'notes/injected').exists())
        self.assertEqual(self.request(dict(kind='createFolder', path=path + '/keep.txt'))['kind'], 'error')
        self.assertEqual((target / 'keep.txt').read_text(), 'keep')

    def test_create_folder_rejects_symlinks_missing_parents_and_outside_paths(self):
        outside = self.guest / 'outside'; outside.mkdir()
        (self.workspace / 'link').symlink_to(outside)
        (self.workspace / 'dangling').symlink_to(outside / 'missing')
        for path in ('/workspace', '/workspace/../outside/new', '/etc/new',
                     '/workspace/link/new', '/workspace/link', '/workspace/dangling',
                     '/workspace/missing/child'):
            with self.subTest(path=path):
                self.assertEqual(self.request(dict(kind='createFolder', path=path))['kind'], 'error')
        self.assertEqual(list(outside.iterdir()), [])
        self.assertFalse((self.workspace / 'missing').exists())
        self.assertEqual(self.request(dict(kind='list', path='/workspace'))['kind'], 'listing')

    def test_incomplete_upload_is_not_published(self):
        self.assertEqual(self.request(dict(kind='upload', path='/workspace', names=['unfinished']))['kind'], 'accept')
        self.process.stdin.write(entry('payload', data=b'123')[:-1]); self.process.stdin.close()
        self.process.wait(timeout=10)
        self.assertNotEqual(self.process.returncode, 0)
        self.assertFalse((self.workspace / 'unfinished').exists())

    def test_delete_files_and_folders_including_hidden_children(self):
        folder = self.workspace / 'folder with ü\n$(no-command)'
        (folder / '.git').mkdir(parents=True)
        (folder / '.git/config').write_bytes(b'private sample')
        (folder / '.env').write_text('hidden sample')
        keep = self.workspace / 'keep.txt'; keep.write_text('keep')
        hidden = self.workspace / '.delete-me'; hidden.write_text('delete')
        self.assertEqual(self.request(dict(kind='delete', path='/workspace/.delete-me'))['kind'], 'done')
        self.assertFalse(hidden.exists())
        self.assertEqual(self.request(dict(kind='delete', path='/workspace/' + folder.name))['kind'], 'done')
        self.assertFalse(folder.exists())
        self.assertEqual(keep.read_text(), 'keep')
        commands = [args for args in self.calls() if 'mybox-files-delete' in args]
        arguments = commands[-1][-2:]
        self.assertTrue(all(value.isascii() for value in arguments))
        decode = commands[-1][4].split('set -eu\n', 1)[0]
        decoded = subprocess.run(['/bin/sh', '-c', decode + "printf '%s\\0%s\\0' \"$1\" \"$2\"", 'decode', *arguments], capture_output=True, check=True)
        self.assertEqual(decoded.stdout.split(b'\0'), [b'/workspace', folder.name.encode(), b''])
        self.assertNotIn(folder.name, commands[-1][4], 'File names must be separate arguments, never shell source')
        self.assertIn('--one-file-system --preserve-root=all --', commands[-1][4])
        self.assertEqual(self.request(dict(kind='list', path='/workspace'))['kind'], 'listing')

    def test_delete_protects_workspace_and_rejects_parent_symlinks(self):
        outside = self.guest / 'outside'; outside.mkdir()
        keep = outside / 'keep.txt'; keep.write_text('keep')
        link = self.workspace / 'link'; link.symlink_to(outside, target_is_directory=True)
        for path in ('/workspace', '/workspace/.', '/workspace//', '/workspace/../outside',
                     '/outside/keep.txt', '/workspace/link/keep.txt', '/workspace/missing'):
            with self.subTest(path=path):
                self.assertEqual(self.request(dict(kind='delete', path=path))['kind'], 'error')
                self.assertEqual(keep.read_text(), 'keep')
                self.assertTrue(self.workspace.exists())
        self.assertEqual(self.request(dict(kind='delete', path='/workspace/link'))['kind'], 'done')
        self.assertFalse(link.is_symlink())
        self.assertEqual(keep.read_text(), 'keep', 'Deleting a symlink must not delete its target')

    def test_recursive_delete_does_not_follow_child_symlinks(self):
        outside = self.guest / 'outside'; outside.mkdir()
        keep = outside / 'keep.txt'; keep.write_text('keep')
        folder = self.workspace / 'remove'; folder.mkdir()
        (folder / 'link').symlink_to(outside, target_is_directory=True)
        self.assertEqual(self.request(dict(kind='delete', path='/workspace/remove'))['kind'], 'done')
        self.assertFalse(folder.exists())
        self.assertEqual(keep.read_text(), 'keep')
