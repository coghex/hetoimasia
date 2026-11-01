#!/usr/bin/env python3
"""Device-free tests of tools/display/x11_window.py (LFE-25, #540).

They run the helper's identity, ambiguity, vanished-target, refused-close, malformed-capture and cleanup logic over an
in-memory display. They open no display, load no X library and control no desktop, so they run anywhere the
workflow tests do (hetoimasia:workflow-tests drives this file and requires its count of examples).
"""

import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
import zlib

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import x11_window as x  # noqa: E402


class FakeWindow:
    def __init__(self, pid=None, window_class=x.INPUT_OUTPUT, map_state=x.IS_VIEWABLE, size=(64, 48), position=(10, 20),
                 protocols=(x.DELETE_WINDOW,), cls=("lua", "Hetoimasia"), pixels=None, accept_close=True):
        self.pid = pid
        self.window_class = window_class
        self.map_state = map_state
        self.size = size
        self.position = position
        self.protocols = list(protocols)
        self.cls = cls
        self.pixels = pixels  # None: a solid colour
        self.accept_close = accept_close
        self.delivered = 0
        self.vanish_on_image = False
        self.vanish_on_send = False


class FakeDisplay(x.Backend):
    def __init__(self, windows=None):
        self.table = dict(windows or {})
        self.order = list(self.table)
        self.format = dict(bits_per_pixel=32, depth=24, byte_order=0, red=0xFF0000, green=0x00FF00, blue=0x0000FF)
        self.closed = False
        self.image_override = None

    def display_name(self):
        return ":99"

    def windows(self):
        return list(self.order)

    def _get(self, window):
        if window not in self.table:
            raise x.Vanished("window %d no longer exists" % window)
        return self.table[window]

    def attributes(self, window):
        w = self._get(window)
        return x.Attributes(w.map_state, w.window_class, w.position[0], w.position[1], w.size[0], w.size[1])

    def pid(self, window):
        return self._get(window).pid

    def window_class(self, window):
        return self._get(window).cls

    def protocols(self, window):
        return list(self._get(window).protocols)

    def image(self, window, width, height):
        w = self._get(window)
        if w.vanish_on_image:
            del self.table[window]
            raise x.Vanished("window %d vanished while it was read" % window)
        if self.image_override is not None:
            return self.image_override
        f = self.format
        bytes_per_pixel = f["bits_per_pixel"] // 8
        out = bytearray()
        for y in range(w.size[1]):
            for px in range(w.size[0]):
                r, g, b = (w.pixels(px, y) if w.pixels else (200, 100, 50))
                value = (r << 16) | (g << 8) | b
                out += value.to_bytes(bytes_per_pixel, "little" if f["byte_order"] == 0 else "big")
        return x.RawImage(w.size[0], w.size[1], f["depth"], f["bits_per_pixel"], w.size[0] * bytes_per_pixel, f["byte_order"],
                          f["red"], f["green"], f["blue"], bytes(out))

    def send_delete(self, window):
        w = self._get(window)
        if w.vanish_on_send:
            del self.table[window]
            raise x.Vanished("window %d vanished before the message" % window)
        if not w.accept_close:
            return False
        w.delivered += 1
        return True

    def close(self):
        self.closed = True


def decode_png(data):
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    offset, width, height, idat = 8, 0, 0, b""
    while offset < len(data):
        length = int.from_bytes(data[offset : offset + 4], "big")
        kind = data[offset + 4 : offset + 8]
        body = data[offset + 8 : offset + 8 + length]
        crc = int.from_bytes(data[offset + 8 + length : offset + 12 + length], "big")
        assert crc == zlib.crc32(kind + body) & 0xFFFFFFFF
        if kind == b"IHDR":
            width, height = int.from_bytes(body[:4], "big"), int.from_bytes(body[4:8], "big")
            assert body[8:] == bytes([8, 2, 0, 0, 0])
        if kind == b"IDAT":
            idat += body
        offset += 12 + length
    raw = zlib.decompress(idat)
    stride = 1 + 3 * width
    rows = []
    for y in range(height):
        assert raw[y * stride] == 0
        rows.append(raw[y * stride + 1 : (y + 1) * stride])
    return width, height, rows


PID = 4242


def read_file(path):
    with open(path, "rb") as handle:
        return handle.read()


def write_file(path, data):
    with open(path, "wb") as handle:
        handle.write(data)


class Candidates(unittest.TestCase):
    def test_lists_only_the_pids_input_output_windows_and_skips_one_that_vanishes_while_listed(self):
        display = FakeDisplay({
            1: FakeWindow(pid=PID),
            2: FakeWindow(pid=PID + 1),
            3: FakeWindow(pid=PID, window_class=x.INPUT_ONLY),
            4: FakeWindow(pid=None),
            5: FakeWindow(pid=PID, map_state=x.IS_UNMAPPED),
        })
        display.order.append(99)  # listed, gone by the time it is read
        found = x.candidates(display, PID)
        self.assertEqual([c.window for c in found], [1, 5])
        self.assertEqual(found[1].map_state, x.IS_UNMAPPED)


class Identify(unittest.TestCase):
    def test_names_the_only_viewable_window_and_records_its_identity(self):
        display = FakeDisplay({7: FakeWindow(pid=PID, size=(640, 480), position=(3, 4)), 8: FakeWindow(pid=PID, map_state=x.IS_UNMAPPED)})
        identity = x.identify(display, PID)
        self.assertEqual((identity.pid, identity.window, identity.width, identity.height, identity.x, identity.y), (PID, 7, 640, 480, 3, 4))
        self.assertEqual(identity.window_class, ("lua", "Hetoimasia"))
        self.assertIn(x.DELETE_WINDOW, identity.protocols)

    def test_no_window_is_not_found(self):
        with self.assertRaises(x.NotFound):
            x.identify(FakeDisplay({1: FakeWindow(pid=PID + 5)}), PID)

    def test_two_windows_with_one_pid_are_ambiguous_and_none_is_picked(self):
        display = FakeDisplay({1: FakeWindow(pid=PID), 2: FakeWindow(pid=PID, size=(10, 10))})
        with self.assertRaises(x.Ambiguous) as caught:
            x.identify(display, PID)
        listed = caught.exception.extra["candidates"]
        self.assertEqual([c["window"] for c in listed], [1, 2])

    def test_a_named_window_among_several_of_one_pid_is_the_one_acted_on(self):
        display = FakeDisplay({1: FakeWindow(pid=PID), 2: FakeWindow(pid=PID, size=(10, 10))})
        self.assertEqual(x.identify(display, PID, window=2).window, 2)

    def test_the_size_the_caller_observed_must_still_hold(self):
        display = FakeDisplay({1: FakeWindow(pid=PID, size=(64, 48))})
        self.assertEqual(x.identify(display, PID, 1, (64, 48)).window, 1)
        with self.assertRaises(x.IdentityMismatch):
            x.identify(display, PID, 1, (65, 48))
        with self.assertRaises(x.IdentityMismatch):
            x.identify(display, PID, None, (65, 48))

    def test_a_vanished_named_window_is_a_diagnostic_and_another_window_is_never_substituted(self):
        display = FakeDisplay({2: FakeWindow(pid=PID)})
        with self.assertRaises(x.Vanished):
            x.identify(display, PID, window=1)

    def test_a_window_of_another_pid_or_an_input_only_window_is_refused(self):
        display = FakeDisplay({1: FakeWindow(pid=PID + 1), 2: FakeWindow(pid=PID, window_class=x.INPUT_ONLY)})
        with self.assertRaises(x.IdentityMismatch):
            x.verify(display, PID, 1)
        with self.assertRaises(x.IdentityMismatch):
            x.verify(display, PID, 2)


class Capture(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)

    def path(self, name="shot.png"):
        return os.path.join(self.directory.name, name)

    def listing(self):
        return sorted(os.listdir(self.directory.name))

    def test_captures_exactly_the_client_area_lossless_with_probes_and_a_checksum(self):
        display = FakeDisplay({1: FakeWindow(pid=PID, size=(4, 3), pixels=lambda px, y: (px * 10, y * 20, 7))})
        result = x.capture(display, PID, 1, self.path(), probes=[(0, 0), (3, 2)])
        width, height, rows = decode_png(read_file(self.path()))
        self.assertEqual((width, height), (4, 3))
        self.assertEqual(list(rows[2][9:12]), [30, 40, 7])
        self.assertEqual(result.probes, {"0,0": [0, 0, 7], "3,2": [30, 40, 7]})
        import hashlib

        self.assertEqual(result.sha256, hashlib.sha256(read_file(self.path())).hexdigest())
        self.assertEqual(result.format["red_mask"], 0xFF0000)
        self.assertEqual(self.listing(), ["shot.png"])

    def test_a_24_bit_and_a_big_endian_image_decode_the_same(self):
        for bits, order in ((24, 0), (32, 1), (24, 1)):
            display = FakeDisplay({1: FakeWindow(pid=PID, size=(2, 2), pixels=lambda px, y: (11, 22, 33))})
            display.format.update(bits_per_pixel=bits, byte_order=order)
            path = self.path("shot-%d-%d.png" % (bits, order))
            x.capture(display, PID, 1, path)
            _, _, rows = decode_png(read_file(path))
            self.assertEqual(list(rows[0][:3]), [11, 22, 33])

    def test_an_unsupported_pixel_size_a_short_image_and_an_empty_one_are_refused_and_leave_no_file(self):
        display = FakeDisplay({1: FakeWindow(pid=PID, size=(2, 2))})
        for override in (
            x.RawImage(2, 2, 24, 16, 4, 0, 0xF800, 0x7E0, 0x1F, bytes(8)),
            x.RawImage(2, 2, 24, 32, 8, 0, 0xFF0000, 0xFF00, 0xFF, bytes(7)),
            x.RawImage(2, 2, 24, 32, 4, 0, 0xFF0000, 0xFF00, 0xFF, bytes(16)),
            x.RawImage(0, 0, 24, 32, 0, 0, 0xFF0000, 0xFF00, 0xFF, b""),
            x.RawImage(2, 2, 24, 32, 8, 0, 0, 0xFF00, 0xFF, bytes(16)),
        ):
            display.image_override = override
            with self.assertRaises(x.CaptureFailed):
                x.capture(display, PID, 1, self.path())
            self.assertEqual(self.listing(), [])

    def test_a_server_image_of_another_size_is_refused(self):
        display = FakeDisplay({1: FakeWindow(pid=PID, size=(2, 2))})
        display.image_override = x.RawImage(3, 2, 24, 32, 12, 0, 0xFF0000, 0xFF00, 0xFF, bytes(24))
        with self.assertRaises(x.CaptureFailed):
            x.capture(display, PID, 1, self.path())

    def test_an_unviewable_window_an_existing_file_and_a_probe_outside_are_refused(self):
        display = FakeDisplay({1: FakeWindow(pid=PID, size=(2, 2), map_state=x.IS_UNMAPPED), 2: FakeWindow(pid=PID, size=(2, 2))})
        with self.assertRaises(x.CaptureFailed):
            x.capture(display, PID, 1, self.path())
        write_file(self.path("old.png"), b"keep")
        with self.assertRaises(x.CaptureFailed):
            x.capture(display, PID, 2, self.path("old.png"))
        self.assertEqual(read_file(self.path("old.png")), b"keep")
        with self.assertRaises(x.CaptureFailed):
            x.capture(display, PID, 2, self.path("new.png"), probes=[(2, 0)])
        self.assertEqual(self.listing(), ["old.png"])

    def test_a_window_that_vanishes_during_the_read_is_vanished_and_leaves_no_file(self):
        window = FakeWindow(pid=PID, size=(2, 2))
        window.vanish_on_image = True
        display = FakeDisplay({1: window})
        with self.assertRaises(x.Vanished):
            x.capture(display, PID, 1, self.path())
        self.assertEqual(self.listing(), [])

    def test_a_target_that_cannot_be_written_is_a_capture_failure_with_no_partial_file(self):
        display = FakeDisplay({1: FakeWindow(pid=PID, size=(2, 2))})
        with self.assertRaises(x.CaptureFailed):
            x.capture(display, PID, 1, os.path.join(self.directory.name, "missing-dir", "shot.png"))
        self.assertEqual(self.listing(), [])

    def test_the_identity_is_revalidated_at_the_action_not_assumed_from_before(self):
        display = FakeDisplay({1: FakeWindow(pid=PID, size=(2, 2))})
        x.identify(display, PID)
        display.table[1].pid = PID + 1  # the window id was reused by another process in between
        with self.assertRaises(x.IdentityMismatch):
            x.capture(display, PID, 1, self.path())
        display.table[1].pid = PID
        display.table[1].size = (3, 2)
        with self.assertRaises(x.IdentityMismatch):
            x.capture(display, PID, 1, self.path(), expect_size=(2, 2))
        self.assertEqual(self.listing(), [])


class Close(unittest.TestCase):
    def test_delivers_one_close_request_to_exactly_the_named_window(self):
        display = FakeDisplay({1: FakeWindow(pid=PID), 2: FakeWindow(pid=PID)})
        x.close_window(display, PID, 2)
        self.assertEqual((display.table[1].delivered, display.table[2].delivered), (0, 1))

    def test_a_window_without_the_close_protocol_gets_nothing(self):
        display = FakeDisplay({1: FakeWindow(pid=PID, protocols=("WM_TAKE_FOCUS",))})
        with self.assertRaises(x.NoCloseProtocol):
            x.close_window(display, PID, 1)
        self.assertEqual(display.table[1].delivered, 0)

    def test_a_refused_send_is_reported_and_never_as_a_close(self):
        display = FakeDisplay({1: FakeWindow(pid=PID, accept_close=False)})
        with self.assertRaises(x.CloseRefused):
            x.close_window(display, PID, 1)

    def test_a_vanished_window_before_or_during_the_send_is_a_diagnostic(self):
        display = FakeDisplay({1: FakeWindow(pid=PID)})
        with self.assertRaises(x.Vanished):
            x.close_window(display, PID, 9)
        display.table[1].vanish_on_send = True
        with self.assertRaises(x.Vanished):
            x.close_window(display, PID, 1)

    def test_a_window_of_another_pid_is_not_closed(self):
        display = FakeDisplay({1: FakeWindow(pid=PID + 1)})
        with self.assertRaises(x.IdentityMismatch):
            x.close_window(display, PID, 1)
        self.assertEqual(display.table[1].delivered, 0)


class Isolation(unittest.TestCase):
    def test_only_the_isolated_display_the_runner_started_is_acted_on(self):
        x.require_isolated_display({"HETOIMASIA_NATIVE_SESSION": "isolated-x11::99", "DISPLAY": ":99"})
        for environment in (
            {},
            {"DISPLAY": ":99"},
            {"HETOIMASIA_NATIVE_SESSION": "desktop", "DISPLAY": ":0"},
            {"HETOIMASIA_NATIVE_SESSION": "isolated-x11::99", "DISPLAY": ":0"},
            {"HETOIMASIA_NATIVE_SESSION": "isolated-x11:", "DISPLAY": ""},
            {"HETOIMASIA_NATIVE_SESSION": "isolated-x11::99", "DISPLAY": ":99", "WAYLAND_DISPLAY": "wayland-0"},
        ):
            with self.assertRaises(x.UnsafeDisplay):
                x.require_isolated_display(environment)


class CommandLine(unittest.TestCase):
    def call(self, display, *arguments):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            status = x.main(list(arguments), backend=display, environment={})
        return status, json.loads(out.getvalue())

    def test_reports_one_json_object_and_exits_zero_on_success_and_one_on_a_refusal(self):
        display = FakeDisplay({1: FakeWindow(pid=PID), 2: FakeWindow(pid=PID)})
        status, report = self.call(display, "candidates", "--pid", str(PID))
        self.assertEqual((status, [c["window"] for c in report["candidates"]]), (0, [1, 2]))
        status, report = self.call(display, "identify", "--pid", str(PID))
        self.assertEqual((status, report["outcome"], report["ok"]), (1, "ambiguous", False))
        status, report = self.call(display, "identify", "--pid", str(PID), "--window", "2")
        self.assertEqual((status, report["identity"]["window"]), (0, 2))
        status, report = self.call(display, "close", "--pid", str(PID), "--window", "1")
        self.assertEqual((status, report["outcome"]), (0, "sent"))
        status, report = self.call(display, "geometry", "--pid", str(PID), "--window", "5")
        self.assertEqual((status, report["outcome"]), (1, "vanished"))
        status, report = self.call(display, "check")
        self.assertEqual((status, report["outcome"]), (0, "ready"))

    def test_prepare_needs_no_display_and_names_the_library_or_fails_as_unsafe_display(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            status = x.main(["prepare"], environment={})
        report = json.loads(out.getvalue())
        if status == 0:
            self.assertEqual(report["outcome"], "prepared")
        else:
            self.assertEqual((report["ok"], report["outcome"]), (False, "unsafe_display"))

    def test_a_usage_error_exits_two_before_any_display_is_touched(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as caught:
            x.main(["close", "--pid", "1"], backend=FakeDisplay(), environment={})
        self.assertEqual(caught.exception.code, 2)

    def test_the_real_backend_is_refused_without_the_isolated_consent_and_touches_no_display(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            status = x.main(["check"], environment={"DISPLAY": ":0", "HETOIMASIA_NATIVE_SESSION": "desktop"})
        self.assertEqual(status, 1)
        self.assertEqual(json.loads(out.getvalue())["outcome"], "unsafe_display")


if __name__ == "__main__":
    unittest.main(verbosity=2)
