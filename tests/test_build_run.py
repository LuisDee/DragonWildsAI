"""tools/build_run.py: the fresh build spot comes from the census (40+ m from every built piece) on ground he walked."""
from tools.build_run import fresh_spot, nearest_piece


def _route(x0, y0, n=12, z=-31.0):
    return {"pts": [[x0 + i * 0.5, y0, z] for i in range(n)]}


def test_fresh_spot_clear_of_every_piece_on_walked_ground():
    pieces = [[100.0, 100.0, -31.0], [100.0, 150.0, -31.0]]
    nav = {"routes": [_route(102, 104), _route(160, 100), _route(100, 200)], "water_cells": []}
    s = fresh_spot(pieces, [100.0, 100.0, -31.0], nav)
    assert s is not None and min(((s[0] - p[0]) ** 2 + (s[1] - p[1]) ** 2) ** 0.5 for p in pieces) >= 40.0
    assert abs(s[1] - 100) <= 8 and s[0] >= 140  # the walked ground east, not the one under the base or the far one


def test_no_spot_without_walked_ground_or_near_water():
    pieces = [[100.0, 100.0, -31.0]]
    assert fresh_spot(pieces, [100.0, 100.0, -31.0], {"routes": [], "water_cells": []}) is None
    wet = {"routes": [_route(160, 100)], "water_cells": [f"{int(162 // 2)}:{int(100 // 2)}"]}
    assert fresh_spot(pieces, [100.0, 100.0, -31.0], wet) is None


def test_nearest_piece_for_the_run_row():
    assert nearest_piece([0.0, 0.0, 0.0], [[30.0, 40.0, 0.0], [100.0, 0.0, 0.0]]) == {"position": [30.0, 40.0, 0.0], "distance_m": 50.0}
    assert nearest_piece([0.0, 0.0, 0.0], []) is None


def test_home_is_where_most_of_his_pieces_stand():
    from tools.build_run import home
    led = [{"at": [96.2, 1850.1, -31.8]}, {"at": [99.2, 1853.1, -31.8]}, {"at": [94.7, 1853.1, -31.8]}, {"at": [484.3, 1780.1, -40.8]}]
    assert home(led)[0] < 100 and home([]) is None
