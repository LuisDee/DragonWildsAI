"""Geometry helpers with NO brain imports (a leaf module, so anything can use it without import cycles)."""
from __future__ import annotations

import math
from typing import Any

# Unreal's axes and native units are documented below; the wire conversion to
# metres is performed by client_mod/scripts/sense.lua and mod/body/util.lua.
# https://dev.epicgames.com/documentation/unreal-engine/coordinate-system-and-spaces-in-unreal-engine
# https://dev.epicgames.com/documentation/unreal-engine/units-of-measurement-in-unreal-engine?lang=en-US
WIRE_COORDINATES = ("Wire positions [x, y, z] are in metres: XY horizontal, positive Z up. "
                    "The client's own position is its capsule centre; object origins and interaction points "
                    "can differ. A three-dimensional near distance includes height; it does not prove a "
                    "labelled floor or a connected path.")


def dist(a: Any, b: Any, planar: bool = False) -> float | None:
    """Metres between two positions: 3D when both have z (else 2D); ``planar`` = always 2D (map views).
    None unless both are [x, y, ...] sequences. The one distance helper (predicates, map_memory)."""
    if not (isinstance(a, (list, tuple)) and isinstance(b, (list, tuple)) and len(a) >= 2 and len(b) >= 2):
        return None
    n = 2 if planar or not (len(a) >= 3 and len(b) >= 3) else 3
    return math.dist([float(x) for x in a[:n]], [float(x) for x in b[:n]])
