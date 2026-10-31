"""Geometry helpers with NO brain imports (a leaf module, so anything can use it without import cycles)."""
from __future__ import annotations

import math
from typing import Any

# Unreal's axes and native units are documented below; the wire conversion to
# metres is performed by client_mod/scripts/sense.lua and mod/body/util.lua.
# https://dev.epicgames.com/documentation/unreal-engine/coordinate-system-and-spaces-in-unreal-engine
# https://dev.epicgames.com/documentation/unreal-engine/units-of-measurement-in-unreal-engine?lang=en-US
WIRE_COORDINATES = ("Wire positions [x, y, z] are in metres: XY horizontal, positive Z up; your own position is "
                    "your body's centre, about 0.9 m above your feet.")


def dist(a: Any, b: Any, planar: bool = False) -> float | None:
    """Metres between two positions: 3D when both have z (else 2D); ``planar`` = always 2D (map views).
    None unless both are [x, y, ...] sequences. The one distance helper (predicates, map_memory)."""
    if not (isinstance(a, (list, tuple)) and isinstance(b, (list, tuple)) and len(a) >= 2 and len(b) >= 2):
        return None
    n = 2 if planar or not (len(a) >= 3 and len(b) >= 3) else 3
    return math.dist([float(x) for x in a[:n]], [float(x) for x in b[:n]])


def direction(frm, to) -> str:
    """Compass words from one position to another: north = -Y, east = +X (Unreal's left-handed axes seen from
    above). Checked against the wiki's own geography over the game's region polygons (data/places_26161880.json
    centroids): Bramblemead Valley is south of the Whispering Swamp, the Fractured Plains east of the Stormtouched
    Highlands, Umbral Sands directly east of Ghornfell, Dowdun Reach south of Silverthorn Keep, Emberwood the most
    western part of Fellhollow: all hold with this mapping, none with +X = north."""
    east, north = to[0] - frm[0], frm[1] - to[1]
    ang = (math.degrees(math.atan2(east, north)) + 360) % 360  # 0 = north, 90 = east
    return ("N", "NE", "E", "SE", "S", "SW", "W", "NW")[int(((ang + 22.5) % 360) // 45)]
