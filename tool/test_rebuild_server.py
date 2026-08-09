import http.client
import json
import threading
import unittest

import rebuild_server


class _FakeHandler(rebuild_server.RebuildHandler):
    def log_message(self, fmt, *args):
        pass

    def _rebuild(self):
        return {"rebuilt": True, "message": "test"}


class RebuildServerSecurityTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        rebuild_server.SERVER_TOKEN = "t" * 43
        rebuild_server.ALLOWED_CLIENTS = set()
        rebuild_server._seen_nonces.clear()
        cls.server = rebuild_server.http.server.ThreadingHTTPServer(
            ("127.0.0.1", 0), _FakeHandler
        )
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.port = cls.server.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=2)

    def _post(self, headers=None):
        body = json.dumps({"action": "rebuild"})
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=2)
        connection.request(
            "POST",
            "/rebuild",
            body=body,
            headers={"Content-Type": "application/json", **(headers or {})},
        )
        response = connection.getresponse()
        payload = json.loads(response.read())
        connection.close()
        return response.status, payload

    def test_requires_bearer_and_one_time_nonce(self):
        self.assertEqual(self._post()[0], 401)
        self.assertEqual(
            self._post({"Authorization": "Bearer wrong"})[0],
            401,
        )
        headers = {
            "Authorization": f"Bearer {rebuild_server.SERVER_TOKEN}",
            "X-Solvhen-Nonce": "n" * 24,
        }
        status, payload = self._post(headers)
        self.assertEqual(status, 200)
        self.assertTrue(payload["rebuilt"])
        self.assertEqual(self._post(headers)[0], 401)

    def test_status_does_not_disclose_without_auth(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=2)
        connection.request("GET", "/status")
        response = connection.getresponse()
        self.assertEqual(response.status, 401)
        self.assertNotIn("project", response.read().decode("utf-8"))
        connection.close()


if __name__ == "__main__":
    unittest.main()
