import threading
import urllib.error
import urllib.request
import unittest
from unittest.mock import patch

import start


class FakePipe:
    def __init__(self, lines=None):
        self.lines = list(lines or [])
        self.writes = []
        self.closed = False

    def write(self, value):
        self.writes.append(value)

    def flush(self):
        pass

    def readline(self):
        return self.lines.pop(0) if self.lines else ""

    def close(self):
        self.closed = True


class FakeProc:
    def __init__(self, stdout_lines):
        self.stdin = FakePipe()
        self.stdout = FakePipe(stdout_lines)
        self.returncode = None
        self.terminated = False
        self.killed = False

    def poll(self):
        return self.returncode

    def terminate(self):
        self.terminated = True
        self.returncode = -15

    def wait(self, timeout=None):
        return self.returncode

    def kill(self):
        self.killed = True
        self.returncode = -9


class ClearRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.original_state = (
            start.state.tunnel_proc,
            start.state.dvt_proc,
            start.state.rsd_host,
            start.state.rsd_port,
            start.state.last_seq,
            start.state.last_loc,
        )
        start.state.tunnel_proc = None
        start.state.dvt_proc = None
        start.state.rsd_host = "fd00::1"
        start.state.rsd_port = "12345"
        start.state.last_seq = 7
        start.state.last_loc = (25.0, 121.0)

    def tearDown(self):
        (
            start.state.tunnel_proc,
            start.state.dvt_proc,
            start.state.rsd_host,
            start.state.rsd_port,
            start.state.last_seq,
            start.state.last_loc,
        ) = self.original_state

    def test_clear_restarts_stale_dvt_stream_after_broken_pipe(self):
        stale_proc = FakeProc(["ERR [Errno 32] Broken pipe\n"])
        restarted_proc = FakeProc(["CLEARED\n"])
        start.state.dvt_proc = stale_proc
        restarts = []

        def restart_dvt():
            restarts.append(True)
            start.state.dvt_proc = restarted_proc

        with patch.object(start, "start_dvt_stream", side_effect=restart_dvt):
            start.clear()

        self.assertEqual(stale_proc.stdin.writes, ["CLEAR\n"])
        self.assertTrue(stale_proc.terminated)
        self.assertEqual(restarted_proc.stdin.writes, ["CLEAR\n"])
        self.assertEqual(restarts, [True])
        self.assertIsNone(start.state.last_loc)


class RemovedStepTriggerEndpointTests(unittest.TestCase):
    def test_step_trigger_endpoint_is_not_served(self):
        server = start.ThreadingHTTPServer(("127.0.0.1", 0), start.Handler)
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        try:
            url = f"http://127.0.0.1:{server.server_address[1]}/api/step-trigger"
            request = urllib.request.Request(url, method="POST")
            with self.assertRaises(urllib.error.HTTPError) as raised:
                urllib.request.urlopen(request, timeout=2)
            self.assertEqual(raised.exception.code, 404)
        finally:
            server.shutdown()
            thread.join(timeout=2)
            server.server_close()


if __name__ == "__main__":
    unittest.main()
