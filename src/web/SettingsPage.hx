package web;

import js.Browser.document;
import js.Browser.window;

class SettingsPage {

    static var container:js.html.Element;

    /* -------- Main entry -------- */
    static public function render():Void {
        container = cast document.getElementById("app");
        clear(container);

        buildHeader();
        buildForm();
        loadSettings();
    }

    /* -------- Helpers -------- */
    static function clear(el:js.html.Element):Void {
        while (el.hasChildNodes()) el.removeChild(el.firstChild);
    }

    private static function append(p:Dynamic, c:js.html.Element):Void {
        untyped p.appendChild(c);
    }

    private static function listen(target:Dynamic, type:String, handler:Dynamic->Void):Void {
        untyped target.addEventListener(type, handler);
    }

    static function el(tag:String, ?cls:String, ?parent:js.html.Element):js.html.Element {
        var e:js.html.Element = cast document.createElement(tag);
        if (cls != null) e.className = cls;
        if (parent != null) append(parent, e);
        return e;
    }

    static function btn(text:String, ?cls:String, ?parent:js.html.Element, ?onClick:Void->Void):js.html.ButtonElement {
        var b:js.html.ButtonElement = cast document.createElement("button");
        b.textContent = text;
        if (cls != null) b.className = cls;
        if (onClick != null) listen(b, "click", (_) -> onClick());
        if (parent != null) append(parent, b);
        return b;
    }

    static function label(text:String, ?cls:String, ?parent:js.html.Element):js.html.LabelElement {
        var l:js.html.LabelElement = cast document.createElement("label");
        l.textContent = text;
        if (cls != null) l.className = cls;
        if (parent != null) append(parent, l);
        return l;
    }

    static function input(?type:String, ?placeholder:String, ?value:String, ?cls:String, ?parent:js.html.Element):js.html.InputElement {
        var i:js.html.InputElement = cast document.createElement("input");
        i.type = if (type != null) type else "text";
        if (placeholder != null) i.placeholder = placeholder;
        if (value != null) i.value = value;
        if (cls != null) i.className = cls;
        if (parent != null) append(parent, i);
        return i;
    }

    static function spn(?content:String, ?cls:String, ?parent:js.html.Element):js.html.SpanElement {
        var s:js.html.SpanElement = cast document.createElement("span");
        if (content != null) s.textContent = content;
        if (cls != null) s.className = cls;
        if (parent != null) append(parent, s);
        return s;
    }

    static function div(?cls:String, ?parent:js.html.Element):js.html.DivElement {
        var d:js.html.DivElement = cast document.createElement("div");
        if (cls != null) d.className = cls;
        if (parent != null) append(parent, d);
        return d;
    }

    static function toast(message:String, isError:Bool):Void {
        var t = div("toast " + (isError ? "toast-error" : "toast-success"), container);
        t.textContent = message;
        window.setTimeout(() -> { if (t.parentElement != null) t.parentElement.removeChild(t); }, 3000);
    }

    static function field(name:String, ?hint:String, ?parent:js.html.Element):js.html.DivElement {
        var d:js.html.DivElement = div("form-field", parent);
        label(name, "field-label", d);
        if (hint != null) spn(hint, "field-hint", d);
        return d;
    }

    static function query(parent:js.html.Element, selector:String):js.html.Element {
        return cast (untyped parent.querySelector(selector));
    }

    static function queryAll(parent:js.html.Element, selector:String):Array<js.html.Element> {
        var nodeList = untyped parent.querySelectorAll(selector);
        var arr:Array<js.html.Element> = [];
        var len = nodeList.length;
        for (i in 0...len) {
            arr.push(cast nodeList.item(i));
        }
        return arr;
    }

    /* -------- Header -------- */
    static function buildHeader():Void {
        var h = div("page-header", container);
        var title = el("h1", "page-title", h);
        title.textContent = "Settings";

        var nav = div("nav-bar", h);
        btn("Servers", "nav-link", nav, () -> window.location.href = "/");
        btn("Settings", "nav-link", nav, () -> window.location.href = "/settings");
    }

    /* -------- Settings form -------- */
    static function buildForm():Void {
        var form = div("settings-form", container);

        field("Port (8080)", null, form);
        field("Factorio Username", "Required for downloading mods", form);
        field("Factorio Token", "Get from factorio.com/home/mods", form);

        var btnRow = div("form-actions", form);
        btn("Save Settings", "btn btn-primary", btnRow, doSave);
    }

    /* -------- Load settings -------- */
    static function loadSettings():Void {
        Api.getSettings(
            data -> populateForm(data),
            err -> toast(err, true)
        );
    }

    static function populateForm(data:Dynamic):Void {
        var form:js.html.Element = query(container, ".settings-form");
        if (form == null) return;

        var fields:Array<js.html.Element> = queryAll(form, ".form-field");
        if (fields.length < 3) return;

        input("number", null, Std.string(data.port), "form-input", fields[0]);
        input("text", null, data.factorioUsername != null ? data.factorioUsername : "", "form-input", fields[1]);
        // Token field - leave empty on load since server doesn't return it for security
        var tokenInput:js.html.InputElement = input("password", "Enter new token...", "", "form-input", fields[2]);
    }

    /* -------- Save -------- */
    static function doSave():Void {
        var form:js.html.Element = query(container, ".settings-form");
        if (form == null) return;

        var fields:Array<js.html.Element> = queryAll(form, ".form-field");
        var portInput:js.html.InputElement = cast(query(fields[0], "input"), js.html.InputElement);
        var userInput:js.html.InputElement = cast(query(fields[1], "input"), js.html.InputElement);
        var tokenInput:js.html.InputElement = cast(query(fields[2], "input"), js.html.InputElement);

        var settings = {
            port: Std.parseInt(portInput.value),
            factorioUsername: userInput.value,
            factorioToken: tokenInput.value
        };

        // Only send token if the user actually typed something
        if (settings.factorioToken == "") {
            settings.factorioToken = null;
        }

        Api.updateSettings(settings,
            _ -> toast("Settings saved", false),
            err -> toast("Failed to save: " + err, true)
        );
    }
}
