#!/usr/bin/env python3
"""Solvhen Rebuild Server — listens for rebuild requests from Solvhen app.

Solvhen calls rebuild_self tool → POSTs to this server → builds + installs APK.

Usage:
  python3 rebuild_server.py [--port 9120] [--project /path/to/SolvhenAgent]

Requirements:
  - Flutter SDK in PATH
  - ADB in PATH (or set ANDROID_HOME)
  - Device connected via USB or WiFi ADB
"""

import http.server
import json
import subprocess
import sys
import os
from pathlib import Path

PROJECT_DIR = os.environ.get('SOLVHEN_PROJECT', 'D:\\SolvhenAgent')
DEVICE_ID = os.environ.get('SOLVHEN_DEVICE', '545b6238')
FLUTTER_CMD = 'flutter'
ADB_CMD = 'adb'


class RebuildHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        print(f"[{self.log_date_time_string()}] {args[0]}")

    def do_POST(self):
        if self.path == '/rebuild':
            try:
                length = int(self.headers.get('Content-Length', 0))
                body = self.rfile.read(length) if length > 0 else b'{}'
                data = json.loads(body) if body else {}
                action = data.get('action', 'rebuild')
                
                if action == 'rebuild':
                    result = self._rebuild()
                    self._respond(200, result)
                elif action == 'ping':
                    self._respond(200, {'status': 'ok', 'message': 'rebuild server ready'})
                else:
                    self._respond(400, {'error': f'unknown action: {action}'})
            except Exception as e:
                self._respond(500, {'error': str(e)})
        elif self.path == '/status':
            self._respond(200, {
                'status': 'ok',
                'project': PROJECT_DIR,
                'device': DEVICE_ID,
            })
        else:
            self._respond(404, {'error': 'not found'})

    def do_GET(self):
        if self.path == '/status' or self.path == '/':
            self._respond(200, {
                'status': 'ok',
                'project': PROJECT_DIR,
                'device': DEVICE_ID,
                'endpoints': ['POST /rebuild', 'GET /status'],
            })
        else:
            self._respond(404, {'error': 'not found'})

    def _respond(self, code, data):
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(json.dumps(data, ensure_ascii=False).encode('utf-8'))

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'POST, GET, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

    def _rebuild(self):
        print("\n═══════════════════════════════════════════")
        print(" REBUILD TRIGGERED")
        print("═══════════════════════════════════════════")

        # Step 1: flutter build
        print(f"[1/2] Building APK in {PROJECT_DIR}...")
        result = subprocess.run(
            [FLUTTER_CMD, 'build', 'apk', '--debug'],
            cwd=PROJECT_DIR,
            capture_output=True,
            text=True,
            timeout=300,
            shell=True,  # Windows needs shell for flutter.bat
        )
        if result.returncode != 0:
            print(f"BUILD FAILED:\n{result.stderr[-500:]}")
            return {'rebuilt': False, 'error': f'Build failed:\n{result.stderr[-300:]}'}
        print("Build OK")

        # Step 2: install
        print(f"[2/2] Installing to device {DEVICE_ID}...")
        apk_path = os.path.join(PROJECT_DIR, 'build', 'app', 'outputs', 'flutter-apk', 'app-debug.apk')
        if not os.path.exists(apk_path):
            return {'rebuilt': False, 'error': f'APK not found: {apk_path}'}

        result = subprocess.run(
            [ADB_CMD, '-s', DEVICE_ID, 'install', '-r', apk_path],
            capture_output=True,
            text=True,
            timeout=60,
            shell=True,
        )
        if result.returncode != 0:
            print(f"INSTALL FAILED:\n{result.stderr}")
            return {'rebuilt': False, 'error': f'Install failed:\n{result.stderr[-200:]}'}
        
        print("Install OK — Solvhen updated!")
        return {
            'rebuilt': True,
            'message': '编译安装成功！重启Solvhen即可看到新效果。',
            'apk': apk_path,
        }


def main():
    import argparse
    parser = argparse.ArgumentParser(description='Solvhen Rebuild Server')
    parser.add_argument('--port', type=int, default=9120)
    parser.add_argument('--project', default=PROJECT_DIR)
    parser.add_argument('--device', default=DEVICE_ID)
    args = parser.parse_args()

    global PROJECT_DIR, DEVICE_ID
    PROJECT_DIR = args.project
    DEVICE_ID = args.device

    print(f"  Solvhen Rebuild Server")
    print(f"  Project: {PROJECT_DIR}")
    print(f"  Device:  {DEVICE_ID}")
    print(f"  Port:    {args.port}")
    print(f"  Ready.")
    print()

    server = http.server.HTTPServer(('0.0.0.0', args.port), RebuildHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()


if __name__ == '__main__':
    main()
