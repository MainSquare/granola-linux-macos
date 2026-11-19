#!/usr/bin/env python3
"""Write one PNG image of a given size from a Windows .ico file."""

from __future__ import annotations

import struct
import sys
from pathlib import Path

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def ico_png(data: bytes, size: int) -> bytes:
    reserved, kind, count = struct.unpack_from("<HHH", data, 0)
    if reserved != 0 or kind != 1:
        raise ValueError("not an .ico file")
    for index in range(count):
        width, height, _, _, _, _, length, offset = struct.unpack_from(
            "<BBBBHHII", data, 6 + 16 * index
        )
        image = data[offset : offset + length]
        if (width or 256) == size and (height or 256) == size and image.startswith(PNG_SIGNATURE):
            return image
    raise ValueError(f"no {size}x{size} PNG image in the .ico file")


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: ico_png.py ICO SIZE OUTPUT", file=sys.stderr)
        return 2
    try:
        image = ico_png(Path(sys.argv[1]).read_bytes(), int(sys.argv[2]))
    except (OSError, ValueError, struct.error) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    Path(sys.argv[3]).write_bytes(image)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
