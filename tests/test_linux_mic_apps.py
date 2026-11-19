from __future__ import annotations

import json
import shutil
import subprocess
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "linux-mic-apps.js"


def node(objects: list[dict[str, object]]) -> list[dict[str, object]]:
    program = (
        f"const {{ activeInputProcesses }} = require({json.dumps(str(SCRIPT))});"
        "let input = '';"
        "process.stdin.on('data', (chunk) => (input += chunk));"
        "process.stdin.on('end', () => console.log(JSON.stringify("
        "activeInputProcesses(JSON.parse(input)))));"
    )
    result = subprocess.run(
        ["node", "-e", program],
        input=json.dumps(objects),
        capture_output=True,
        check=True,
        text=True,
    )
    return json.loads(result.stdout)


def stream(media_class: str, binary: str, pid: int, **extra: object) -> dict[str, object]:
    return {
        "type": "PipeWire:Interface:Node",
        "info": {
            "props": {
                "media.class": media_class,
                "application.process.binary": binary,
                "application.process.id": pid,
                **extra,
            }
        },
    }


@unittest.skipUnless(shutil.which("node"), "node is required")
class LinuxMicAppsTests(unittest.TestCase):
    def test_reports_meeting_apps_holding_a_microphone_stream(self) -> None:
        processes = node(
            [
                stream("Stream/Input/Audio", "chrome", 10),
                stream("Stream/Input/Audio", "electron", 11),
                stream("Stream/Input/Audio", "zoom", 12, **{"stream.capture.sink": True}),
                stream("Stream/Output/Audio", "slack", 13),
                {"type": "PipeWire:Interface:Link", "info": {}},
                {
                    "id": 40,
                    "type": "PipeWire:Interface:Client",
                    "info": {
                        "props": {"application.process.binary": "zoom", "application.process.id": 14}
                    },
                },
                {
                    "type": "PipeWire:Interface:Node",
                    "info": {"props": {"media.class": "Stream/Input/Audio", "client.id": 40}},
                },
            ]
        )
        self.assertEqual(
            processes,
            [
                {"bundleId": "com.google.Chrome", "pid": 10},
                {"bundleId": "us.zoom.xos", "pid": 14},
            ],
        )


if __name__ == "__main__":
    unittest.main()
