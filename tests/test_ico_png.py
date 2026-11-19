from __future__ import annotations

import importlib.util
import struct
import sys
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "ico_png.py"
SPEC = importlib.util.spec_from_file_location("ico_png", SCRIPT)
assert SPEC and SPEC.loader
ICO_PNG = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = ICO_PNG
SPEC.loader.exec_module(ICO_PNG)


def make_ico(images: list[tuple[int, bytes]]) -> bytes:
    header = struct.pack("<HHH", 0, 1, len(images))
    offset = 6 + 16 * len(images)
    entries = b""
    for size, image in images:
        entries += struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(image), offset)
        offset += len(image)
    return header + entries + b"".join(image for _, image in images)


class IcoPngTests(unittest.TestCase):
    def test_returns_the_png_of_the_requested_size(self) -> None:
        small = ICO_PNG.PNG_SIGNATURE + b"small"
        large = ICO_PNG.PNG_SIGNATURE + b"large"
        data = make_ico([(16, small), (256, large)])
        self.assertEqual(ICO_PNG.ico_png(data, 16), small)
        self.assertEqual(ICO_PNG.ico_png(data, 256), large)

    def test_rejects_missing_size(self) -> None:
        with self.assertRaises(ValueError):
            ICO_PNG.ico_png(make_ico([(16, ICO_PNG.PNG_SIGNATURE)]), 32)


if __name__ == "__main__":
    unittest.main()
