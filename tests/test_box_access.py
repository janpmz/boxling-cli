"""Exercise the native approval service without root, firewall changes, or UI."""
from pathlib import Path
import json
import os
import socket
import subprocess
import tempfile
import threading
import time
import unittest
from service_protocol import packet, receive

ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / '.build/mybox-service-tests'


class BoxAccess(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.policy = dict(owner=499, network='mybox-net-demo', subnet4='192.168.65.0/24',
                           subnet6='fd00::/64', gateway='192.168.65.1', ports=[], active=True)
        self.tokens = [f'{index:08d}-1111-4111-8111-111111111111' for index in range(1, 5)]

    def prompt(self, args):
        response = subprocess.run([NATIVE, 'prompt', json.dumps(args)], capture_output=True, text=True)
        if response.returncode:
            raise ValueError(response.stderr)
        return response.stdout

    def test_prompt_describes_what_the_requester_receives(self):
        self.assertIn('shell', self.prompt(['enter', 'demo']))
        self.assertIn('browse, read, create, edit, upload, download, and delete', self.prompt(['files', 'demo']))
        self.assertIn('/workspace', self.prompt(['files', 'demo']))
        reason = self.prompt(['enter', 'demo', 'cat', 'a b', 'a\nb', '\u202etest'])
        self.assertIn('receives output', reason)
        self.assertIn('"a b" "a\\nb" "\\u202etest"', reason)
        self.assertIn('copy of', self.prompt(['export', 'demo', '/workspace/x']))
        self.assertIn('write', self.prompt(['import', 'demo', 'file']))
        self.assertIn('"file" "folder"', self.prompt(['import', 'demo', 'file', 'folder']))
        for args in (['enter', 'fake\nname'], ['shell', 'demo'], ['export', 'demo'], ['enter', 'demo', 'a\0b']):
            with self.assertRaises(ValueError):
                self.prompt(args)

    def embedded_shell(self):
        return json.loads(subprocess.check_output([NATIVE, 'embedded-shell'], text=True))

    def test_file_session_uses_one_native_prompt_for_every_box_name(self):
        for box in ['nearbyy-website', 'a' * 48]:
            challenge = 'a' * 64
            status, answers, error = self.exchange('access',
                [['access-v2', challenge, ['files', box]]], {})
            self.assertEqual(status, 0, error)
            self.assertEqual(answers, [['approved', challenge]])
            self.assertEqual(len(self.calls), 1)
            reason = self.calls[0]['input'][1]
            self.assertLessEqual(len(reason), 220)
            for scope in [box, '/workspace', 'this program', 'this session',
                          'browse', 'read', 'create', 'edit', 'upload', 'download',
                          'delete', 'files and folders', 'Prepare and check the Mac firewall']:
                self.assertIn(scope, reason)

    def test_file_session_still_rejects_denied_or_stale_approval(self):
        challenge = 'a' * 64
        request = ['access-v2', challenge, ['files', 'demo']]
        for status, output in [(1, challenge), (0, 'old-challenge')]:
            result, answers, _ = self.exchange('access', [request],
                dict(auth_status=status, auth_output=output))
            self.assertNotEqual(result, 0)
            self.assertEqual(answers, [])
            self.assertEqual(len(self.calls), 1)

    def test_builtin_terminal_uses_short_shell_approval_for_every_box_name(self):
        for box in ['document-player-box', 'a' * 48]:
            request = ['enter', box] + self.embedded_shell()
            self.assertEqual(self.prompt(request), self.prompt(['enter', box]))
            challenge = 'a' * 64
            status, answers, error = self.exchange('access', [['access-v2', challenge, request]], {})
            self.assertEqual(status, 0, error)
            self.assertEqual(answers, [['approved', challenge]])
            # This is the complete reason passed to LocalAuthentication, including
            # the firewall suffix. It must fit without the extra review dialog.
            reason = self.calls[0]['input'][1]
            self.assertLessEqual(len(reason), 220)
            self.assertNotIn('__mybox_prompt', reason)
            self.assertIn(box, reason)

    def test_modified_terminal_setup_keeps_the_complete_command_review(self):
        original = self.embedded_shell()
        variants = [original + ['extra'], original[:-1]]
        for index in range(len(original)):
            changed = original.copy()
            changed[index] += '\nprintf dangerous-command'
            variants.append(changed)
        for command in variants:
            with self.subTest(command=command):
                reason = self.prompt(['enter', 'demo'] + command)
                self.assertIn('Command:', reason)
                self.assertNotEqual(reason, self.prompt(['enter', 'demo']))
        reason = self.prompt(['enter', 'demo', '/bin/bash', '-c', 'echo "mybox-terminal"; echo dangerous-command'])
        self.assertIn('dangerous-command', reason)

    def test_previous_app_shell_keeps_short_approval(self):
        legacy = json.loads(subprocess.check_output([NATIVE, 'legacy-embedded-shell'], text=True))
        self.assertEqual(self.prompt(['enter', 'demo'] + legacy), self.prompt(['enter', 'demo']))
        self.assertIn('Command:', self.prompt(['enter', 'demo'] + legacy[:-1] + [legacy[-1] + '\necho changed']))

    def test_builtin_terminal_still_requires_fresh_native_approval(self):
        challenge = 'a' * 64
        request = ['access-v2', challenge, ['enter', 'demo'] + self.embedded_shell()]
        for status, output in [(1, challenge), (0, 'old-challenge')]:
            result, answers, _ = self.exchange('access', [request], dict(auth_status=status, auth_output=output))
            self.assertNotEqual(result, 0)
            self.assertEqual(answers, [])
            self.assertEqual(len(self.calls), 1)

    def exchange(self, mode, messages, config):
        log = self.directory / 'calls.json'
        log.unlink(missing_ok=True)
        config = dict(config, log=str(log))
        conn, caller = socket.socketpair()
        with conn, caller:
            process = subprocess.Popen([NATIVE, mode, str(conn.fileno()), json.dumps(config)],
                pass_fds=(conn.fileno(),), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            conn.close()
            caller.settimeout(10)
            for message in messages:
                packet(caller, message)
            caller.shutdown(socket.SHUT_WR)
            answers = []
            try:
                while True:
                    answers.append(receive(caller))
            except (EOFError, ConnectionResetError):
                pass
            _, error = process.communicate(timeout=10)
        self.calls = json.loads(log.read_text())
        return process.returncode, answers, error.decode()

    def run_preparation(self, actions, messages, responses=None, **config):
        if responses is None:
            responses = [dict(confirmation=dict(action=action, policy=self.policy)) for action in actions]
        status, answers, error = self.exchange('prepare', messages, dict(config, responses=responses))
        if status:
            raise ValueError(error)
        for call in self.calls:
            self.assertEqual(call['executable'], '/Library/PrivilegedHelperTools/mybox-firewall-manager')
            self.assertEqual(call['input']['box'], 'demo')
            self.assertLessEqual(call['timeout'], 300)
        return answers

    def test_missing_authentication_replayed_approval_and_fresh_approval(self):
        path = str(self.directory / 'socket')
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(path); listener.listen(); listener.settimeout(10)
            challenges, errors = [], []
            def server():
                try:
                    for index in range(4):
                        conn, _ = listener.accept()
                        with conn:
                            version, challenge, args = receive(conn)
                            self.assertEqual((version, args), ('access-v2', ['enter', 'demo', 'pwd']))
                            challenges.append(challenge)
                            replies = [['denied'], ['approved', challenges[0]], ['approved', challenge], ['approved', True]]
                            packet(conn, replies[index])
                            self.assertEqual(conn.recv(1), b'')
                except Exception as error:
                    errors.append(error)
            thread = threading.Thread(target=server)
            thread.start()
            for allowed in (False, False, True, False):
                result = subprocess.run([NATIVE, 'request', path, str(os.getuid())], capture_output=True, timeout=10)
                self.assertEqual(result.returncode == 0, allowed, result.stderr)
            thread.join(10)
            self.assertFalse(thread.is_alive())
            self.assertEqual(errors, [])
            self.assertEqual(len(set(challenges)), 4)

    def test_service_rejects_canceled_authentication_and_stale_helper_output(self):
        challenge = 'a' * 64
        for status, output, allowed in [(1, challenge, False), (0, 'old', False), (0, challenge, True)]:
            result, answers, error = self.exchange('access', [['access-v2', challenge, ['enter', 'demo', 'pwd']]],
                dict(auth_status=status, auth_output=output))
            self.assertEqual(result == 0, allowed, error)
            self.assertEqual(answers, [['approved', challenge]] if allowed else [])
            self.assertIn('pwd', self.calls[0]['input'][1])

    def test_wrong_peer_and_console_owner_cannot_authenticate(self):
        for config in [dict(peer=os.getuid() + 1), dict(console=502), dict(owner=0)]:
            status, answers, _ = self.exchange('access', [['access-v2', 'a' * 64, ['enter', 'demo']]], config)
            self.assertNotEqual(status, 0)
            self.assertEqual(answers, [])
            self.assertEqual(self.calls, [])

    def test_multiple_import_items_share_one_authentication(self):
        challenge = 'a' * 64
        request = ['access-v2', challenge, ['import', 'demo', 'notes.txt', 'project']]
        status, answers, error = self.exchange('access',
            [request, ['firewall', self.tokens[0]], ['finish']],
            dict(responses=[dict(confirmation=dict(action='verify', policy=self.policy))]))
        self.assertEqual(status, 0, error)
        self.assertEqual(answers, [['approved', challenge], ['firewall', self.tokens[0]], ['finished']])
        authentications = [call for call in self.calls if call['executable'] == '/bin/launchctl']
        self.assertEqual(len(authentications), 1)
        self.assertIn('"notes.txt" "project"', authentications[0]['input'][1])

    def test_running_stopped_and_recovered_boxes_finish_without_sudo(self):
        for actions in [('verify',), ('apply', 'verify', 'verify'), ('update-ports', 'verify')]:
            with self.subTest(actions=actions):
                requests = [['firewall', token] for token in self.tokens[:len(actions)]]
                self.assertEqual(self.run_preparation(actions, requests + [['finish']]), requests + [['finished']])
                for index, call in enumerate(self.calls):
                    self.assertEqual(call['input']['policy'], self.policy if index else None)
                    self.assertIn(actions[index], call['input']['actions'])

    def test_cannot_repeat_requests_change_operations_or_finish_before_checks(self):
        for actions, messages in [
            ((), [['finish']]), ((), [['firewall', '../request']]), ((), [['enter', 'other-box']]),
            (('apply',), [['firewall', self.tokens[0]], ['firewall', self.tokens[0]]]),
            (('apply',), [['firewall', self.tokens[0]], ['finish']]),
            (('verify',), [['firewall', self.tokens[0]], ['firewall', self.tokens[1]]]),
        ]:
            with self.subTest(messages=messages), self.assertRaises(ValueError):
                self.run_preparation(actions, messages)

    def test_firewall_failure_cannot_confirm_access(self):
        replies = self.run_preparation((), [['firewall', self.tokens[0]]],
            [dict(status=1, error='The network bridge is missing.')])
        self.assertEqual(replies, [['firewall-error', self.tokens[0], 'The network bridge is missing.']])
        self.assertEqual(len(self.calls), 1)

    def test_firewall_timeout_and_terminal_controls_are_reported_without_approval(self):
        replies = self.run_preparation((), [['firewall', self.tokens[0]]], [dict(timeout=True)])
        self.assertEqual(replies[0][:2], ['firewall-error', self.tokens[0]])
        self.assertIn('timed out', replies[0][2])
        replies = self.run_preparation((), [['firewall', self.tokens[0]]], [dict(status=1, error='bad\x1b[2J' + 'x' * 3000)])
        self.assertNotIn('\x1b', replies[0][2])
        self.assertEqual(len(replies[0][2]), 2000)

    def test_expiration_and_disconnection_do_no_firewall_work(self):
        with self.assertRaises(ValueError):
            self.run_preparation((), [], times=[100, 401])
        self.assertEqual(self.calls, [])
        self.assertEqual(self.run_preparation((), []), [])
        self.assertEqual(self.calls, [])

    def test_expiration_while_receiving_request_does_no_firewall_work(self):
        with self.assertRaises(ValueError):
            self.run_preparation((), [['firewall', self.tokens[0]]], times=[100, 101, 401])
        self.assertEqual(self.calls, [])

    def test_helper_must_confirm_the_same_policy_and_allowed_action(self):
        for change in [dict(network='mybox-net-other'), dict(ports=[8080])]:
            responses = [dict(confirmation=dict(action='apply', policy=self.policy)),
                         dict(confirmation=dict(action='verify', policy=dict(self.policy, **change)))]
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.run_preparation((), [['firewall', t] for t in self.tokens[:2]], responses)
        with self.assertRaises(ValueError):
            self.run_preparation((), [['firewall', self.tokens[0]]], [dict(confirmation=dict(action='remove', policy=self.policy))])

    def action_exchange(self, args, steps, rollback_at=None, **config):
        challenge = 'b' * 64
        messages = [['access-v2', challenge, args]]
        for index, token in enumerate(self.tokens[:len(steps)]):
            if index == rollback_at:
                messages.append(['rollback'])
            messages.append(['firewall', token])
        messages += [['finish']]
        responses = [dict(confirmation=dict(action=action, policy=policy)) for action, policy in steps]
        return self.exchange('access', messages, dict(responses=responses, **config))

    def test_lifecycle_actions_use_one_native_approval_and_bounded_firewall_actions(self):
        cases = [(['start', 'demo'], ['apply', 'verify', 'verify']),
                 (['create', 'demo'], ['apply', 'verify', 'verify']),
                 (['start', 'demo'], ['verify']), (['stop', 'demo'], ['remove']),
                 (['delete', 'demo'], ['remove']), (['delete', 'demo'], []),
                 (['copy', 'demo', 'duplicate'], []), (['resize', 'demo'], []),
                 (['recover-ports', 'demo'], ['update-ports'])]
        for args, steps in cases:
            with self.subTest(args=args, steps=steps):
                status, answers, error = self.action_exchange(args, [(action, self.policy) for action in steps])
                self.assertEqual(status, 0, error)
                self.assertEqual(answers[-1], ['finished'])
                auth = [call for call in self.calls if call['executable'] == '/bin/launchctl']
                self.assertEqual(len(auth), 1)
                self.assertLessEqual(len(auth[0]['input'][1]), 220)
                if args[0] in ['stop', 'delete'] and steps:
                    self.assertEqual(self.calls[1]['input']['actions'], ['remove'])

    def test_native_action_cancellation_never_reaches_firewall(self):
        for action in ['start', 'stop', 'create', 'delete', 'resize']:
            status, answers, _ = self.action_exchange([action, 'demo'], [('remove', self.policy)], auth_status=1)
            self.assertNotEqual(status, 0)
            self.assertEqual(answers, [])
            self.assertEqual(len(self.calls), 1)

    def test_lifecycle_approval_cannot_authorize_another_action_or_repeated_removal(self):
        for args, steps in [(['stop', 'demo'], ['apply']), (['start', 'demo'], ['remove']),
                            (['resize', 'demo'], ['verify']), (['copy', 'demo', 'copy'], ['apply']),
                            (['stop', 'demo'], ['remove', 'remove']), (['create', 'demo'], [])]:
            status, _, _ = self.action_exchange(args, [(action, self.policy) for action in steps])
            self.assertNotEqual(status, 0, (args, steps))

    def port_args(self, before, after, action='add', inside='8080'):
        return ['ports', 'demo', action, inside, '8766', json.dumps(before), json.dumps(after)]

    def test_port_change_and_rollback_are_pinned_to_exact_policies(self):
        next_policy = dict(self.policy, ports=[8080])
        steps = [('verify', self.policy), ('update-ports', next_policy), ('update-ports', self.policy)]
        for count in [0, 2, 3]:
            status, answers, error = self.action_exchange(self.port_args(self.policy, next_policy), steps[:count], rollback_at=2 if count == 3 else None)
            self.assertEqual(status, 0, error)
            self.assertEqual(answers[-1], ['finished'])
            for index, call in enumerate(self.calls[1:]):
                self.assertEqual(call['input']['policy'], steps[index][1])
            self.assertNotIn('subnet', self.calls[0]['input'][1])
            self.assertIn('8766', self.calls[0]['input'][1])
        status, _, _ = self.action_exchange(self.port_args(self.policy, next_policy),
            [('verify', self.policy), ('update-ports', dict(next_policy, ports=[22]))])
        self.assertNotEqual(status, 0)

    def test_port_approval_rejects_unrelated_changes_before_authentication(self):
        for policy in [dict(self.policy, ports=[22]), dict(self.policy, network='mybox-net-other'),
                       dict(self.policy, gateway='192.168.65.2'), dict(self.policy, active=False)]:
            status, answers, _ = self.action_exchange(self.port_args(self.policy, policy), [])
            self.assertNotEqual(status, 0)
            self.assertEqual(answers, [])
            self.assertEqual(self.calls, [])
        status, _, error = self.action_exchange(self.port_args(dict(self.policy, ports=[8080]), self.policy,
            action='remove', inside=''), [])
        self.assertEqual(status, 0, error)

    def test_failed_port_update_can_only_restore_the_original_policy(self):
        next_policy = dict(self.policy, ports=[8080])
        request = ['access-v2', 'c' * 64, self.port_args(self.policy, next_policy)]
        messages = [request, ['firewall', self.tokens[0]], ['firewall', self.tokens[1]],
                    ['rollback'], ['firewall', self.tokens[2]], ['finish']]
        responses = [dict(confirmation=dict(action='verify', policy=self.policy)),
                     dict(status=1, error='update failed'),
                     dict(confirmation=dict(action='update-ports', policy=self.policy))]
        status, answers, error = self.exchange('access', messages, dict(responses=responses))
        self.assertEqual(status, 0, error)
        self.assertEqual(answers[2], ['firewall-error', self.tokens[1], 'update failed'])
        self.assertEqual(answers[-1], ['finished'])
        self.assertEqual(self.calls[-1]['input']['policy'], self.policy)
        # Failure in the unprivileged forwarder can also roll back before the
        # new firewall policy was ever requested.
        status, _, error = self.action_exchange(self.port_args(self.policy, next_policy),
            [('verify', self.policy), ('update-ports', self.policy)], rollback_at=1)
        self.assertEqual(status, 0, error)
