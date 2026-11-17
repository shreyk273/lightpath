#!/usr/bin/env python3
"""Plays an application on the PC that uses the clipboard, through its own GNOME remote desktop session.

  pc_app.py read [mime]                 print the PC clipboard (raw bytes)
  pc_app.py copy <mime> <file> <secs>   copy the file's bytes, serving pastes for <secs>
"""
import os, sys, time
from gi.repository import Gio, GLib

RD = 'org.gnome.Mutter.RemoteDesktop'
IF = RD + '.Session'
addr = Gio.dbus_address_get_for_bus_sync(Gio.BusType.SESSION, None)
c = Gio.DBusConnection.new_for_address_sync(
    addr, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
path = c.call_sync(RD, '/org/gnome/Mutter/RemoteDesktop', RD, 'CreateSession', None,
                   GLib.VariantType('(o)'), 0, 3000, None).unpack()[0]
payload = b''


def call(method, params=None, reply=None):
    return c.call_sync(RD, path, IF, method, params, reply, 0, 3000, None)


def on_signal(conn, sender, obj, iface, name, params):
    if name == 'SelectionTransfer':
        mime, serial = params.unpack()
        r, fds = c.call_with_unix_fd_list_sync(RD, path, IF, 'SelectionWrite', GLib.Variant('(u)', (serial,)),
                                               GLib.VariantType('(h)'), 0, 3000, None, None)
        fd = fds.get(r.unpack()[0])
        os.set_blocking(fd, True)
        view = memoryview(payload)
        while view:
            view = view[os.write(fd, view):]
        os.close(fd)
        call('SelectionWriteDone', GLib.Variant('(ub)', (serial, True)))


def pump(seconds):
    end = time.time() + seconds
    while time.time() < end:
        GLib.MainContext.default().iteration(False)
        time.sleep(0.002)


c.signal_subscribe(None, IF, None, path, None, 0, on_signal)
call('Start')
call('EnableClipboard', GLib.Variant('(a{sv})', ({},)))
pump(0.1)
if sys.argv[1] == 'read':
    mime = sys.argv[2] if len(sys.argv) > 2 else 'text/plain;charset=utf-8'
    r, fds = c.call_with_unix_fd_list_sync(RD, path, IF, 'SelectionRead', GLib.Variant('(s)', (mime,)),
                                           GLib.VariantType('(h)'), 0, 3000, None, None)
    fd = fds.get(r.unpack()[0])
    data = bytearray()
    deadline = time.time() + 5
    while time.time() < deadline:
        pump(0.002)
        try:
            chunk = os.read(fd, 1 << 20)
        except BlockingIOError:
            continue
        if not chunk:
            break
        data += chunk
    sys.stdout.buffer.write(bytes(data))
else:
    mime, src, seconds = sys.argv[2], sys.argv[3], float(sys.argv[4])
    payload = open(src, 'rb').read()
    offers = ['text/plain;charset=utf-8', 'UTF8_STRING', 'text/plain'] if mime.startswith('text') else [mime]
    call('SetSelection', GLib.Variant('(a{sv})', ({'mime-types': GLib.Variant('as', offers)},)))
    pump(seconds)
call('Stop')
