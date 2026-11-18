// Lightpath Helper: announces the focused window on the session bus, so the streaming server
// can translate Mac shortcuts per application (terminals use Ctrl+Shift+C/V for copy/paste).
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const IFACE = `
<node>
  <interface name="org.lightpath.Helper">
    <method name="Focused"><arg type="s" direction="out" name="json"/></method>
    <signal name="FocusChanged"><arg type="s" name="json"/></signal>
  </interface>
</node>`;

function describe(w) {
    if (!w)
        return null;
    return {
        wm_class: w.get_wm_class() ?? '',
        wm_instance: w.get_wm_class_instance() ?? '',
        app_id: w.get_gtk_application_id() ?? '',
    };
}

export default class LightpathHelper extends Extension {
    enable() {
        this._dbus = Gio.DBusExportedObject.wrapJSObject(IFACE, this);
        this._dbus.export(Gio.DBus.session, '/org/lightpath/Helper');
        this._focusId = global.display.connect('notify::focus-window', () => {
            try {
                this._dbus.emit_signal('FocusChanged', new GLib.Variant('(s)', [this.Focused()]));
            } catch (e) {
                console.error(e);
            }
        });
    }

    disable() {
        if (this._focusId)
            global.display.disconnect(this._focusId);
        this._focusId = 0;
        this._dbus?.unexport();
        this._dbus = null;
    }

    Focused() {
        return JSON.stringify(describe(global.display.focus_window));
    }
}
