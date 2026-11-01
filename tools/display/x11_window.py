#!/usr/bin/env python3
"""Test-only helper for the isolated X11 display: identify, observe, capture and close one native client window.

This is LFE-25's (#540) external operating-system evidence tool for the native qualification suite on the
isolated Xvfb session that tools/display/x11.sh starts. It exists because the product's graphics host must not
capture its own presented output (VK-19, packages/gpu-vulkan/glfw/README.md) and because the in-process close
driver cannot reach a separate launcher process. It touches no product code, adds no product interface and
installs nothing: it speaks the X protocol through the libX11 the CI image and every Linux build already have
(ctypes), so there is no helper binary to build or provision. `check` is its preparation: it proves the library
loads and that the display is the isolated one before any case relies on it.

What it does, and only this:

* ``candidates``: the top-level client windows a process owns (``_NET_WM_PID`` equal to the given pid), with the
  map state and size of each. It never picks one.
* ``identify``: the one viewable window of the pid, with its recorded identity (pid, window id, class, size,
  position, protocols). Zero candidates is ``not_found``; more than one is ``ambiguous`` and lists them, because
  a pid alone does not name a window when a process owns several (the suite's own harness windows share its pid).
  With ``--window`` the caller names the window it bound earlier and the helper re-verifies that exact one.
* ``geometry``: the window's client-area size, absolute position and map state as the X server reports them now.
* ``capture``: the presented client area of exactly that window (``XGetImage`` of the window, never the root or
  the desktop) as an unaltered lossless 8-bit RGB PNG, its bounds, the pixel format's masks, a SHA-256 of the
  file, and the colours at any requested client-area probe points taken from the same image.
* ``close``: a genuine ``WM_DELETE_WINDOW`` ``ClientMessage`` to exactly that window, only when the window
  advertises that protocol and only if ``XSendEvent`` accepted it. It never signals a process, and the answer
  ``sent`` is delivery of the request, never proof the window or the process ended.

Every action that names a window re-verifies its identity first: the window still exists, is an InputOutput
window, and still carries the pid asked for, and (when given) still has the size the caller observed. A window
that disappears between two steps is the diagnostic outcome ``vanished``, never an error that is swallowed and
never a fallback to another window. Output is one JSON object on stdout; the exit status is 0 for ``ok`` and 1
for any refusal or diagnostic (2 for a usage error). Everything that can differ between an honest tool and a
broken one is behind the ``Backend`` interface, so the identity, ambiguity, vanished-target, refused-close and
malformed-capture logic is tested without any display (tools/display/x11_window_test.py).

The helper refuses to run unless ``HETOIMASIA_NATIVE_SESSION`` is ``isolated-x11:DISPLAY`` for the very display
it is connected to: no desktop, no ambient X server and no CI display it was not given.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import struct
import sys
import zlib
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Sequence, Tuple

# Map states of an X window.
IS_UNMAPPED, IS_UNVIEWABLE, IS_VIEWABLE = 0, 1, 2
# Window classes.
INPUT_OUTPUT, INPUT_ONLY = 1, 2
# The close protocol atom name.
DELETE_WINDOW = "WM_DELETE_WINDOW"


# --- Outcomes ----------------------------------------------------------------------------------------------------------------


class Refusal(Exception):
    """A diagnostic outcome: the action was refused or could not be made, and says which."""

    outcome = "refused"

    def __init__(self, detail: str, **extra):
        super().__init__(detail)
        self.detail = detail
        self.extra = extra

    def report(self) -> dict:
        return {"ok": False, "outcome": self.outcome, "detail": self.detail, **self.extra}


class NotFound(Refusal):
    outcome = "not_found"


class Ambiguous(Refusal):
    outcome = "ambiguous"


class Vanished(Refusal):
    outcome = "vanished"


class IdentityMismatch(Refusal):
    outcome = "identity_mismatch"


class NoCloseProtocol(Refusal):
    outcome = "no_close_protocol"


class CloseRefused(Refusal):
    outcome = "close_refused"


class CaptureFailed(Refusal):
    outcome = "capture_failed"


class UnsafeDisplay(Refusal):
    outcome = "unsafe_display"


# --- The display, as the logic sees it ---------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Attributes:
    map_state: int
    window_class: int
    x: int  # absolute, root-relative
    y: int
    width: int
    height: int


@dataclass(frozen=True)
class RawImage:
    """What ``XGetImage`` answered: the pixels and the format they are in."""

    width: int
    height: int
    depth: int
    bits_per_pixel: int
    bytes_per_line: int
    byte_order: int  # 0 LSBFirst, 1 MSBFirst
    red_mask: int
    green_mask: int
    blue_mask: int
    data: bytes


class Backend:
    """The display. A real one speaks X11; the tests' one is a dictionary of windows."""

    def display_name(self) -> str:
        raise NotImplementedError

    def windows(self) -> Sequence[int]:
        """Every window below the root, parents before children."""
        raise NotImplementedError

    def attributes(self, window: int) -> Attributes:
        """Raises ``Vanished`` for a window that no longer exists."""
        raise NotImplementedError

    def pid(self, window: int) -> Optional[int]:
        """The window's ``_NET_WM_PID``, or None; raises ``Vanished``."""
        raise NotImplementedError

    def window_class(self, window: int) -> Optional[Tuple[str, str]]:
        raise NotImplementedError

    def protocols(self, window: int) -> List[str]:
        """The names in ``WM_PROTOCOLS``; raises ``Vanished``."""
        raise NotImplementedError

    def image(self, window: int, width: int, height: int) -> RawImage:
        """The window's own client area; raises ``Vanished`` or ``CaptureFailed``."""
        raise NotImplementedError

    def send_delete(self, window: int) -> bool:
        """Whether the server accepted the ``WM_DELETE_WINDOW`` message; raises ``Vanished``."""
        raise NotImplementedError

    def close(self) -> None:
        raise NotImplementedError


# --- Identity ----------------------------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Identity:
    pid: int
    window: int
    window_class: Optional[Tuple[str, str]]
    x: int
    y: int
    width: int
    height: int
    map_state: int
    protocols: Tuple[str, ...]

    def report(self) -> dict:
        return {
            "pid": self.pid,
            "window": self.window,
            "class": list(self.window_class) if self.window_class else None,
            "x": self.x,
            "y": self.y,
            "width": self.width,
            "height": self.height,
            "map_state": self.map_state,
            "protocols": list(self.protocols),
        }


def describe(backend: Backend, window: int, pid: int) -> Identity:
    attributes = backend.attributes(window)
    return Identity(
        pid=pid,
        window=window,
        window_class=backend.window_class(window),
        x=attributes.x,
        y=attributes.y,
        width=attributes.width,
        height=attributes.height,
        map_state=attributes.map_state,
        protocols=tuple(backend.protocols(window)),
    )


def candidates(backend: Backend, pid: int) -> List[Identity]:
    """The InputOutput windows of this pid, in the order the server lists them. A window that vanishes while it
    is read is left out: the listing is a snapshot, and a later step on that window reports ``vanished``."""
    found: List[Identity] = []
    for window in backend.windows():
        try:
            owner = backend.pid(window)
            if owner != pid:
                continue
            if backend.attributes(window).window_class != INPUT_OUTPUT:
                continue
            found.append(describe(backend, window, pid))
        except Vanished:
            continue
    return found


def verify(backend: Backend, pid: int, window: int, expect_size: Optional[Tuple[int, int]] = None) -> Identity:
    """Re-verify a bound window at the moment of an action: it exists, belongs to this pid, is an InputOutput window
    and (when the caller observed one) still has the size the caller observed."""
    try:
        owner = backend.pid(window)
        attributes = backend.attributes(window)
    except Vanished:
        raise Vanished("window %d no longer exists" % window, window=window, pid=pid)
    if owner != pid:
        raise IdentityMismatch("window %d belongs to pid %s, not %d" % (window, owner, pid), window=window, pid=pid, owner=owner)
    if attributes.window_class != INPUT_OUTPUT:
        raise IdentityMismatch("window %d is not an InputOutput window" % window, window=window, pid=pid)
    if expect_size is not None and (attributes.width, attributes.height) != expect_size:
        raise IdentityMismatch(
            "window %d is %dx%d, not the %dx%d the caller observed" % (window, attributes.width, attributes.height, *expect_size),
            window=window,
            pid=pid,
            width=attributes.width,
            height=attributes.height,
        )
    try:
        return describe(backend, window, pid)
    except Vanished:
        raise Vanished("window %d vanished while it was described" % window, window=window, pid=pid)


def identify(backend: Backend, pid: int, window: Optional[int] = None, expect_size: Optional[Tuple[int, int]] = None) -> Identity:
    """The one window an action may be made on. A named window is re-verified; otherwise the pid must own exactly one
    viewable window. More than one is ``ambiguous`` and none is ever picked."""
    if window is not None:
        return verify(backend, pid, window, expect_size)
    viewable = [c for c in candidates(backend, pid) if c.map_state == IS_VIEWABLE]
    if not viewable:
        raise NotFound("pid %d owns no viewable window" % pid, pid=pid)
    if len(viewable) > 1:
        raise Ambiguous(
            "pid %d owns %d viewable windows; name one with --window" % (pid, len(viewable)),
            pid=pid,
            candidates=[c.report() for c in viewable],
        )
    only = viewable[0]
    if expect_size is not None and (only.width, only.height) != expect_size:
        raise IdentityMismatch(
            "the only window of pid %d is %dx%d, not the %dx%d the caller observed" % (pid, only.width, only.height, *expect_size),
            pid=pid,
            window=only.window,
            width=only.width,
            height=only.height,
        )
    return only


# --- Capture -----------------------------------------------------------------------------------------------------------------


def _channel(value: int, mask: int) -> int:
    """One 8-bit channel of a pixel value under a contiguous mask."""
    if mask == 0:
        raise CaptureFailed("the image format has an empty colour mask")
    shift = (mask & -mask).bit_length() - 1
    bits = (mask >> shift).bit_length()
    sample = (value & mask) >> shift
    if bits == 8:
        return sample
    if bits > 8:
        return sample >> (bits - 8)
    return (sample * 255) // ((1 << bits) - 1)


def rows_of(image: RawImage) -> List[bytes]:
    """The image as 8-bit RGB rows, top row first. A format this does not understand is refused, never guessed."""
    if image.width <= 0 or image.height <= 0:
        raise CaptureFailed("the image is empty (%dx%d)" % (image.width, image.height))
    if image.bits_per_pixel not in (24, 32):
        raise CaptureFailed("unsupported pixel size %d bits" % image.bits_per_pixel)
    bytes_per_pixel = image.bits_per_pixel // 8
    if image.bytes_per_line < image.width * bytes_per_pixel:
        raise CaptureFailed("a row of %d bytes cannot hold %d pixels of %d bytes" % (image.bytes_per_line, image.width, bytes_per_pixel))
    if len(image.data) < image.bytes_per_line * image.height:
        raise CaptureFailed("the image data holds %d bytes, fewer than %d rows of %d" % (len(image.data), image.height, image.bytes_per_line))
    order = "little" if image.byte_order == 0 else "big"
    rows: List[bytes] = []
    for y in range(image.height):
        start = y * image.bytes_per_line
        out = bytearray()
        for x in range(image.width):
            offset = start + x * bytes_per_pixel
            value = int.from_bytes(image.data[offset : offset + bytes_per_pixel], order)
            out.append(_channel(value, image.red_mask))
            out.append(_channel(value, image.green_mask))
            out.append(_channel(value, image.blue_mask))
        rows.append(bytes(out))
    return rows


def png_bytes(width: int, height: int, rows: Sequence[bytes]) -> bytes:
    """A lossless 8-bit RGB PNG (filter 0, one IDAT)."""

    def chunk(kind: bytes, payload: bytes) -> bytes:
        body = kind + payload
        return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + row for row in rows)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


@dataclass
class Capture:
    identity: Identity
    path: str
    sha256: str
    width: int
    height: int
    format: dict
    probes: Dict[str, List[int]] = field(default_factory=dict)

    def report(self) -> dict:
        return {
            "ok": True,
            "outcome": "captured",
            "identity": self.identity.report(),
            "path": self.path,
            "sha256": self.sha256,
            "width": self.width,
            "height": self.height,
            "format": self.format,
            "probes": self.probes,
        }


def capture(
    backend: Backend,
    pid: int,
    window: int,
    out: str,
    probes: Sequence[Tuple[int, int]] = (),
    expect_size: Optional[Tuple[int, int]] = None,
) -> Capture:
    """Capture exactly this window's client area to a new file. The identity is re-verified first and the window must
    be viewable; the file is never overwritten; probes outside the image are a failure, not a clamp."""
    identity = verify(backend, pid, window, expect_size)
    if identity.map_state != IS_VIEWABLE:
        raise CaptureFailed("window %d is not viewable (map state %d)" % (window, identity.map_state), window=window, pid=pid)
    if os.path.exists(out):
        raise CaptureFailed("the capture file %s already exists and is never overwritten" % out)
    try:
        image = backend.image(window, identity.width, identity.height)
    except Vanished:
        raise Vanished("window %d vanished while it was captured" % window, window=window, pid=pid)
    if (image.width, image.height) != (identity.width, identity.height):
        raise CaptureFailed(
            "the server returned %dx%d for a %dx%d client area" % (image.width, image.height, identity.width, identity.height)
        )
    rows = rows_of(image)
    sampled: Dict[str, List[int]] = {}
    for x, y in probes:
        if not (0 <= x < image.width and 0 <= y < image.height):
            raise CaptureFailed("probe (%d,%d) is outside the %dx%d client area" % (x, y, image.width, image.height))
        sampled["%d,%d" % (x, y)] = list(rows[y][3 * x : 3 * x + 3])
    data = png_bytes(image.width, image.height, rows)
    temporary = out + ".partial"
    try:
        with open(temporary, "xb") as handle:
            handle.write(data)
        os.rename(temporary, out)
    except OSError as error:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise CaptureFailed("the capture could not be written: %s" % error)
    return Capture(
        identity=identity,
        path=out,
        sha256=hashlib.sha256(data).hexdigest(),
        width=image.width,
        height=image.height,
        format={
            "depth": image.depth,
            "bits_per_pixel": image.bits_per_pixel,
            "bytes_per_line": image.bytes_per_line,
            "byte_order": "lsb" if image.byte_order == 0 else "msb",
            "red_mask": image.red_mask,
            "green_mask": image.green_mask,
            "blue_mask": image.blue_mask,
        },
        probes=sampled,
    )


# --- Close -------------------------------------------------------------------------------------------------------------------


def close_window(backend: Backend, pid: int, window: int, expect_size: Optional[Tuple[int, int]] = None) -> Identity:
    """Deliver a genuine WM_DELETE_WINDOW to exactly this window. Delivery is the answer, never proof the window ended."""
    identity = verify(backend, pid, window, expect_size)
    if DELETE_WINDOW not in identity.protocols:
        raise NoCloseProtocol("window %d does not advertise %s (protocols %s)" % (window, DELETE_WINDOW, list(identity.protocols)), window=window, pid=pid)
    try:
        accepted = backend.send_delete(window)
    except Vanished:
        raise Vanished("window %d vanished before the close request was delivered" % window, window=window, pid=pid)
    if not accepted:
        raise CloseRefused("the server refused the %s message to window %d" % (DELETE_WINDOW, window), window=window, pid=pid)
    return identity


# --- The real display --------------------------------------------------------------------------------------------------------


class X11Backend(Backend):
    """libX11 through ctypes, on the display named by DISPLAY."""

    def __init__(self):
        import ctypes
        import ctypes.util

        self.c = ctypes
        name = ctypes.util.find_library("X11") or "libX11.so.6"
        try:
            self.x = ctypes.CDLL(name)
        except OSError as error:
            raise UnsafeDisplay("libX11 could not be loaded (%s): %s" % (name, error))
        c = ctypes
        Display, Window, Atom = c.c_void_p, c.c_ulong, c.c_ulong

        class XWindowAttributes(c.Structure):
            _fields_ = [
                ("x", c.c_int), ("y", c.c_int), ("width", c.c_int), ("height", c.c_int), ("border_width", c.c_int),
                ("depth", c.c_int), ("visual", c.c_void_p), ("root", Window), ("klass", c.c_int),
                ("bit_gravity", c.c_int), ("win_gravity", c.c_int), ("backing_store", c.c_int),
                ("backing_planes", c.c_ulong), ("backing_pixel", c.c_ulong), ("save_under", c.c_int),
                ("colormap", c.c_ulong), ("map_installed", c.c_int), ("map_state", c.c_int),
                ("all_event_masks", c.c_long), ("your_event_mask", c.c_long), ("do_not_propagate_mask", c.c_long),
                ("override_redirect", c.c_int), ("screen", c.c_void_p),
            ]

        class XImageFuncs(c.Structure):
            _fields_ = [(n, c.c_void_p) for n in ("create_image", "destroy_image", "get_pixel", "put_pixel", "sub_image", "add_pixel")]

        class XImage(c.Structure):
            _fields_ = [
                ("width", c.c_int), ("height", c.c_int), ("xoffset", c.c_int), ("format", c.c_int), ("data", c.c_void_p),
                ("byte_order", c.c_int), ("bitmap_unit", c.c_int), ("bitmap_bit_order", c.c_int), ("bitmap_pad", c.c_int),
                ("depth", c.c_int), ("bytes_per_line", c.c_int), ("bits_per_pixel", c.c_int),
                ("red_mask", c.c_ulong), ("green_mask", c.c_ulong), ("blue_mask", c.c_ulong),
                ("obdata", c.c_void_p), ("f", XImageFuncs),
            ]

        class XClientMessageEvent(c.Structure):
            _fields_ = [
                ("type", c.c_int), ("serial", c.c_ulong), ("send_event", c.c_int), ("display", c.c_void_p),
                ("window", Window), ("message_type", Atom), ("format", c.c_int), ("data", c.c_long * 5),
            ]

        class XEvent(c.Union):
            _fields_ = [("type", c.c_int), ("xclient", XClientMessageEvent), ("pad", c.c_long * 24)]

        class XErrorEvent(c.Structure):
            _fields_ = [
                ("type", c.c_int), ("display", c.c_void_p), ("resourceid", c.c_ulong), ("serial", c.c_ulong),
                ("error_code", c.c_ubyte), ("request_code", c.c_ubyte), ("minor_code", c.c_ubyte),
            ]

        self.XWindowAttributes, self.XImage, self.XEvent = XWindowAttributes, XImage, XEvent
        x = self.x
        x.XOpenDisplay.restype, x.XOpenDisplay.argtypes = Display, [c.c_char_p]
        x.XCloseDisplay.argtypes = [Display]
        x.XDefaultRootWindow.restype, x.XDefaultRootWindow.argtypes = Window, [Display]
        x.XInternAtom.restype, x.XInternAtom.argtypes = Atom, [Display, c.c_char_p, c.c_int]
        x.XGetAtomName.restype, x.XGetAtomName.argtypes = c.c_void_p, [Display, Atom]
        x.XFree.argtypes = [c.c_void_p]
        x.XQueryTree.argtypes = [Display, Window, c.POINTER(Window), c.POINTER(Window), c.POINTER(c.POINTER(Window)), c.POINTER(c.c_uint)]
        x.XGetWindowAttributes.argtypes = [Display, Window, c.POINTER(XWindowAttributes)]
        x.XTranslateCoordinates.argtypes = [Display, Window, Window, c.c_int, c.c_int, c.POINTER(c.c_int), c.POINTER(c.c_int), c.POINTER(Window)]
        x.XGetWindowProperty.argtypes = [
            Display, Window, Atom, c.c_long, c.c_long, c.c_int, Atom,
            c.POINTER(Atom), c.POINTER(c.c_int), c.POINTER(c.c_ulong), c.POINTER(c.c_ulong), c.POINTER(c.POINTER(c.c_ubyte)),
        ]
        x.XGetImage.restype = c.POINTER(XImage)
        x.XGetImage.argtypes = [Display, Window, c.c_int, c.c_int, c.c_uint, c.c_uint, c.c_ulong, c.c_int]
        x.XSendEvent.argtypes = [Display, Window, c.c_int, c.c_long, c.POINTER(XEvent)]
        x.XSync.argtypes = [Display, c.c_int]
        handler_type = c.CFUNCTYPE(c.c_int, c.c_void_p, c.POINTER(XErrorEvent))
        self.errors: List[int] = []

        def on_error(_display, event):
            self.errors.append(int(event.contents.error_code))
            return 0

        self._handler = handler_type(on_error)  # kept alive for the life of the connection
        x.XSetErrorHandler.argtypes = [handler_type]
        x.XSetErrorHandler(self._handler)
        self.display = x.XOpenDisplay(None)
        if not self.display:
            raise UnsafeDisplay("the X display %r could not be opened" % os.environ.get("DISPLAY"))
        self.root = x.XDefaultRootWindow(self.display)
        self._atoms: Dict[str, int] = {}

    # -- plumbing --

    def _atom(self, name: str) -> int:
        if name not in self._atoms:
            self._atoms[name] = self.x.XInternAtom(self.display, name.encode(), 0)
        return self._atoms[name]

    def _atom_name(self, atom: int) -> str:
        pointer = self.x.XGetAtomName(self.display, atom)
        if not pointer:
            return ""
        try:
            return self.c.cast(pointer, self.c.c_char_p).value.decode("latin-1")
        finally:
            self.x.XFree(pointer)

    def _checked(self, window: int):
        """Flush every request so far and raise ``Vanished`` if the server answered one with an error."""
        self.x.XSync(self.display, 0)
        if self.errors:
            codes, self.errors = list(self.errors), []
            if any(code in (3, 9, 2) for code in codes):  # BadWindow, BadDrawable, BadValue (a gone drawable)
                raise Vanished("the X server reported errors %s for window %d" % (codes, window), window=window)
            raise CaptureFailed("the X server reported errors %s for window %d" % (codes, window), window=window)

    def _property(self, window: int, name: str, kind: int, limit: int = 1024):
        c = self.c
        actual_format = c.c_int(0)
        actual = c.c_ulong(0)
        count, after = c.c_ulong(0), c.c_ulong(0)
        data = c.POINTER(c.c_ubyte)()
        self.errors = []
        status = self.x.XGetWindowProperty(
            self.display, window, self._atom(name), 0, limit, 0, kind,
            c.byref(actual), c.byref(actual_format), c.byref(count), c.byref(after), c.byref(data),
        )
        self._checked(window)
        if status != 0 or actual.value != kind or count.value == 0 or not data:
            if data:
                self.x.XFree(data)
            return None
        try:
            if actual_format.value == 32:
                values = c.cast(data, c.POINTER(c.c_ulong))
                return [int(values[i]) for i in range(count.value)]
            if actual_format.value == 8:
                return bytes(bytearray(data[i] for i in range(count.value)))
            return None
        finally:
            self.x.XFree(data)

    # -- the interface --

    def display_name(self) -> str:
        return os.environ.get("DISPLAY", "")

    def windows(self) -> Sequence[int]:
        c = self.c
        found: List[int] = []
        pending = [self.root]
        while pending:
            parent = pending.pop(0)
            root_ret, parent_ret = c.c_ulong(0), c.c_ulong(0)
            children = c.POINTER(c.c_ulong)()
            count = c.c_uint(0)
            self.errors = []
            status = self.x.XQueryTree(self.display, parent, c.byref(root_ret), c.byref(parent_ret), c.byref(children), c.byref(count))
            if status == 0:
                continue
            try:
                self.x.XSync(self.display, 0)
                self.errors = []
                for index in range(count.value):
                    child = int(children[index])
                    found.append(child)
                    pending.append(child)
            finally:
                if children:
                    self.x.XFree(children)
        return found

    def attributes(self, window: int) -> Attributes:
        c = self.c
        raw = self.XWindowAttributes()
        self.errors = []
        status = self.x.XGetWindowAttributes(self.display, window, c.byref(raw))
        self._sync_vanished(window)
        if status == 0:
            raise Vanished("window %d no longer exists" % window, window=window)
        absolute_x, absolute_y, child = c.c_int(0), c.c_int(0), c.c_ulong(0)
        self.x.XTranslateCoordinates(self.display, window, self.root, 0, 0, c.byref(absolute_x), c.byref(absolute_y), c.byref(child))
        self._sync_vanished(window)
        return Attributes(raw.map_state, raw.klass, absolute_x.value, absolute_y.value, raw.width, raw.height)

    def _sync_vanished(self, window: int) -> None:
        self.x.XSync(self.display, 0)
        if self.errors:
            codes, self.errors = list(self.errors), []
            raise Vanished("the X server reported errors %s for window %d" % (codes, window), window=window)

    def pid(self, window: int) -> Optional[int]:
        values = self._property(window, "_NET_WM_PID", 6)  # XA_CARDINAL
        return values[0] if values else None

    def window_class(self, window: int) -> Optional[Tuple[str, str]]:
        raw = self._property(window, "WM_CLASS", 31)  # XA_STRING
        if not raw:
            return None
        parts = raw.split(b"\x00")
        if len(parts) < 2:
            return None
        return (parts[0].decode("latin-1"), parts[1].decode("latin-1"))

    def protocols(self, window: int) -> List[str]:
        values = self._property(window, "WM_PROTOCOLS", 4)  # XA_ATOM
        return [self._atom_name(v) for v in (values or [])]

    def image(self, window: int, width: int, height: int) -> RawImage:
        c = self.c
        self.errors = []
        pointer = self.x.XGetImage(self.display, window, 0, 0, width, height, 0xFFFFFFFFFFFFFFFF, 2)  # AllPlanes, ZPixmap
        self.x.XSync(self.display, 0)
        if self.errors:
            codes, self.errors = list(self.errors), []
            if any(code in (3, 9) for code in codes):
                raise Vanished("window %d vanished while it was read" % window, window=window)
            raise CaptureFailed("XGetImage failed with X errors %s" % codes, window=window)
        if not pointer:
            raise CaptureFailed("XGetImage returned no image for window %d" % window, window=window)
        try:
            image = pointer.contents
            length = image.bytes_per_line * image.height
            data = c.string_at(image.data, length)
            return RawImage(
                image.width, image.height, image.depth, image.bits_per_pixel, image.bytes_per_line, image.byte_order,
                image.red_mask, image.green_mask, image.blue_mask, data,
            )
        finally:
            destroy = c.CFUNCTYPE(c.c_int, c.c_void_p)(pointer.contents.f.destroy_image)
            destroy(c.cast(pointer, c.c_void_p))

    def send_delete(self, window: int) -> bool:
        c = self.c
        event = self.XEvent()
        event.xclient.type = 33  # ClientMessage
        event.xclient.window = window
        event.xclient.message_type = self._atom("WM_PROTOCOLS")
        event.xclient.format = 32
        event.xclient.data[0] = self._atom(DELETE_WINDOW)
        event.xclient.data[1] = 0  # CurrentTime
        self.errors = []
        status = self.x.XSendEvent(self.display, window, 0, 0, c.byref(event))
        self._sync_vanished(window)
        return status != 0

    def close(self) -> None:
        if self.display:
            self.x.XCloseDisplay(self.display)
            self.display = None


def require_isolated_display(environment: Dict[str, str]) -> None:
    """The helper acts only on the isolated X11 display the runner started: consent must name the display in use."""
    consent = environment.get("HETOIMASIA_NATIVE_SESSION", "")
    display = environment.get("DISPLAY", "")
    if not consent.startswith("isolated-x11:") or not display or consent != "isolated-x11:" + display:
        raise UnsafeDisplay(
            "HETOIMASIA_NATIVE_SESSION=%r does not authorize DISPLAY=%r: this helper runs only on the isolated X11 display" % (consent, display)
        )
    if environment.get("WAYLAND_DISPLAY"):
        raise UnsafeDisplay("WAYLAND_DISPLAY is set: this helper acts only on an isolated X11 display")


# --- Command line ------------------------------------------------------------------------------------------------------------


def _size(text: str) -> Tuple[int, int]:
    width, height = text.lower().split("x")
    return int(width), int(height)


def _point(text: str) -> Tuple[int, int]:
    x, y = text.split(",")
    return int(x), int(y)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="x11_window.py", description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("check", help="prove libX11 loads and the display is the isolated one")
    for name in ("candidates", "identify", "geometry", "capture", "close"):
        action = sub.add_parser(name)
        action.add_argument("--pid", type=int, required=True)
        if name != "candidates":
            action.add_argument("--window", type=int, required=name != "identify")
            action.add_argument("--expect-size", type=_size)
        if name == "capture":
            action.add_argument("--out", required=True)
            action.add_argument("--probe", type=_point, action="append", default=[])
    return parser


def run(arguments: argparse.Namespace, backend: Backend) -> dict:
    if arguments.command == "check":
        return {"ok": True, "outcome": "ready", "display": backend.display_name()}
    pid = arguments.pid
    if arguments.command == "candidates":
        return {"ok": True, "outcome": "candidates", "pid": pid, "candidates": [c.report() for c in candidates(backend, pid)]}
    expect = getattr(arguments, "expect_size", None)
    if arguments.command == "identify":
        return {"ok": True, "outcome": "identified", "identity": identify(backend, pid, arguments.window, expect).report()}
    if arguments.command == "geometry":
        return {"ok": True, "outcome": "geometry", "identity": verify(backend, pid, arguments.window, expect).report()}
    if arguments.command == "capture":
        return capture(backend, pid, arguments.window, arguments.out, arguments.probe, expect).report()
    if arguments.command == "close":
        identity = close_window(backend, pid, arguments.window, expect)
        return {"ok": True, "outcome": "sent", "identity": identity.report()}
    raise AssertionError(arguments.command)


def main(argv: Optional[Sequence[str]] = None, backend: Optional[Backend] = None, environment: Optional[Dict[str, str]] = None) -> int:
    environment = dict(os.environ) if environment is None else environment
    arguments = build_parser().parse_args(argv)
    owned = backend is None
    try:
        if owned:
            require_isolated_display(environment)
            backend = X11Backend()
        report = run(arguments, backend)
    except Refusal as refusal:
        report = refusal.report()
    finally:
        if owned and backend is not None:
            backend.close()
    print(json.dumps(report, sort_keys=True))
    return 0 if report.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
