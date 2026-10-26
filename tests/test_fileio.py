from brain import fileio


def test_atomic_write_and_read_json(tmp_path):
    p = tmp_path / "a.json"
    fileio.atomic_write(p, '{"x": 1}')
    assert fileio.read_json(p) == {"x": 1}
    assert fileio.read_json(tmp_path / "missing.json", {}) == {}
    (tmp_path / "bad.json").write_text("{", encoding="utf-8")
    assert fileio.read_json(tmp_path / "bad.json", []) == []
    assert not list(tmp_path.glob("*.tmp"))


def test_atomic_write_retries_permission_error(tmp_path, monkeypatch):
    calls = {"n": 0}
    real = fileio.os.replace

    def flaky(a, b):
        calls["n"] += 1
        if calls["n"] < 3:
            raise PermissionError("locked")
        return real(a, b)
    monkeypatch.setattr(fileio.os, "replace", flaky)
    fileio.atomic_write(tmp_path / "b.json", "{}", sleep=lambda s: None)
    assert calls["n"] == 3 and (tmp_path / "b.json").read_text() == "{}"


def test_read_new_lines_partial_and_truncate(tmp_path):
    p = tmp_path / "x.jsonl"
    fileio.append_jsonl(p, {"a": 1})
    with p.open("a", encoding="utf-8") as f:
        f.write('{"b": 2}\nnot json\n{"c": ')
    rows, off, bad = fileio.read_new_lines(p, 0)
    assert rows == [{"a": 1}, {"b": 2}] and bad == ["not json"]
    with p.open("a", encoding="utf-8") as f:
        f.write('3}\n')
    rows, off, _ = fileio.read_new_lines(p, off)
    assert rows == [{"c": 3}]
    assert fileio.read_new_lines(p, off) == ([], off, [])
    p.write_text('{"d": 4}\n', encoding="utf-8")   # truncated/rotated
    rows, _, _ = fileio.read_new_lines(p, off)
    assert rows == [{"d": 4}]
