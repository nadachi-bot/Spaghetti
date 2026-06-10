package web;

import js.Browser.document;
import js.Browser.window;
import StringTools;

class ServersPage {

    static var container:js.html.Element;
    static var serverList:js.html.Element;
    static var logModal:js.html.Element;
    static var consoleModal:js.html.Element;
    static var currentLogServer:String = "";
    static var logInterval:Dynamic = null;
    static var transitionStates:Map<String, String> =
        [];
    static var __serverSnapshot:Array<Dynamic> = [];

    /* -------- Main entry -------- */
    static public function render():Void {
        container = cast document.getElementById("app");
        clear(container);

        buildHeader();
        buildServerList();
        buildLogModal();
        buildConsoleModal();
        loadServers();
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

    static function btn(text:String, ?cls:String, ?parent:js.html.Element, ?onClick:String->Void):js.html.ButtonElement {
        var b:js.html.ButtonElement = cast document.createElement("button");
        b.textContent = text;
        if (cls != null) b.className = cls;
        if (onClick != null) listen(b, "click", (_) -> onClick(b.textContent));
        if (parent != null) append(parent, b);
        return b;
    }

    static function text(content:String, ?cls:String, ?parent:js.html.Element):js.html.ParagraphElement {
        var p:js.html.ParagraphElement = cast document.createElement("p");
        p.textContent = content;
        if (cls != null) p.className = cls;
        if (parent != null) append(parent, p);
        return p;
    }

    static function input(?type:String, ?placeholder:String, ?cls:String, ?parent:js.html.Element):js.html.InputElement {
        var i:js.html.InputElement = cast document.createElement("input");
        if (type != null) i.type = type; else i.type = "text";
        if (placeholder != null) i.placeholder = placeholder;
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

    /* -------- Header -------- */
    static function buildHeader():Void {
        var h = div("page-header", container);
        var title = el("h1", "page-title", h);
        title.textContent = "Factorio Server Manager";

        var nav = div("nav-bar", h);
        btn("Servers", "nav-link", nav, _ -> window.location.href = "/");
        btn("Settings", "nav-link", nav, _ -> window.location.href = "/settings");

        btn("+ New Server", "btn btn-primary", h, _ -> showAddDialog());
    }

    /* -------- Server list -------- */
    static function buildServerList():Void {
        serverList = div("server-list", container);
    }

    static function loadServers():Void {
        Api.listServers(
            servers -> { __serverSnapshot = cast servers; renderServerList(__serverSnapshot); },
            err -> toast(err, true)
        );
    }

    static function renderServerList(servers:Array<Dynamic>):Void {
        clear(serverList);
        if (servers.length == 0) {
            text("No servers yet. Click \"+ New Server\" to create one.", null, serverList);
            return;
        }
        for (srv in servers) {
            renderServerCard(srv);
        }
    }

    static function renderServerCard(srv:Dynamic):Void {
        var card = div("server-card", serverList);

        var header = div("card-header", card);
        spn(srv.name != null ? srv.name : srv.id, "server-name", header);
        var statusText = transitionStates.get(srv.id) != null ?
            (transitionStates.get(srv.id) == "starting" ? "⟳ Starting..." : "⟳ Stopping...") :
            (srv.running ? "● Running" : "○ Stopped");
        var statusClass = transitionStates.get(srv.id) != null ?
            "status transitioning" :
            (srv.running ? "status running" : "status stopped");
        spn(statusText, statusClass, header);

        var info = div("card-info", card);
        spn("Version: " + srv.version, null, info);
        spn("  Max: " + srv.maxPlayers + " players", null, info);
        if (srv.mods != null && srv.mods.length > 0) spn("  |  " + srv.mods.length + " mods", null, info);

        var actions = div("card-actions", card);
        if (transitionStates.get(srv.id) != null) {
            btn("-", "btn btn-disabled", actions);
        } else if (srv.running) {
            btn("Stop", "btn btn-stop", actions, _ -> stopServer(srv.id));
        } else {
            btn("Start", "btn btn-start", actions, _ -> startServer(srv.id));
        }
        btn("Logs", "btn", actions, _ -> openLogs(srv.id));
        btn("Console", "btn", actions, _ -> openConsole(srv.id));
        btn("Edit", "btn", actions, _ -> window.location.href = "/edit/" + srv.id);
        btn("Delete", "btn btn-delete", actions, _ -> confirmDelete(srv.id));
    }

    /* -------- Add server dialog -------- */
    static var __pendingSaveFile:js.html.File = null;

    static function showAddDialog():Void {
        __pendingSaveFile = null;

        var overlay = div("modal-overlay", container);
        var modal = div("modal", overlay);
        spn("Create New Server", "modal-title", modal);

        var form = div("modal-form", modal);
        var nameInput = input("text", "Server name", "form-input", form);

        // Save file label (shows selected file name)
        var saveLabel = spn("No save file selected", "form-input form-input--readonly", form);

        // Hidden file picker
        var filePicker:js.html.InputElement = cast document.createElement("input");
        untyped filePicker.type = "file";
        untyped filePicker.accept = ".zip,.factorio";
        untyped filePicker.style.display = "none";
        append(form, filePicker);

        // Upload button
        var uploadBtn:js.html.ButtonElement = cast document.createElement("button");
        uploadBtn.textContent = "Upload save file";
        uploadBtn.className = "btn";
        append(form, uploadBtn);

        // Handle file selection
        var onClick = (e:Dynamic) -> {
            __pendingSaveFile = null;
            saveLabel.textContent = "No save file selected";
            untyped filePicker.click();
        };
        listen(uploadBtn, "click", onClick);
        untyped filePicker.onchange = (e:Dynamic) -> {
            var files:Dynamic = untyped filePicker.files;
            if (files != null && files.length > 0) {
                __pendingSaveFile = cast files[0];
                saveLabel.textContent = __pendingSaveFile.name;
            }
        };

        var btnRow = div("modal-buttons", modal);
        btn("Create", "btn btn-primary", btnRow,
            _ -> {
                var n = StringTools.trim(nameInput.value);
                if (n == "") { toast("Name required", true); return; }

                // Create server first, then upload save file if selected
                Api.createServer(n, "",
                    (result:Dynamic) -> {
                        var serverId = result.id;
                        if (__pendingSaveFile != null) {
                            toast("Uploading save file...", false);
                            Api.uploadSaveFile(serverId, __pendingSaveFile,
                                _ -> {
                                    toast("Server created", false);
                                    loadServers();
                                    closeOverlay(overlay);
                                },
                                (err) -> {
                                    toast("Server created but save upload failed: " + err, true);
                                    loadServers();
                                    closeOverlay(overlay);
                                }
                            );
                        } else {
                            toast("Server created", false);
                            loadServers();
                            closeOverlay(overlay);
                        }
                    },
                    (err) -> {
                        toast(err, true);
                    }
                );
            }
        );
        btn("Cancel", "btn", btnRow, _ -> closeOverlay(overlay));

        listen(overlay, "click", e -> {
            if (cast e.target == overlay) closeOverlay(overlay);
        });
    }

    static function closeOverlay(overlay:js.html.Element):Void {
        if (overlay.parentElement != null) overlay.parentElement.removeChild(overlay);
    }

    /* -------- Server actions -------- */
    static function startServer(id:String):Void {
        transitionStates.set(id, "starting");
        Api.startServer(id,
            _ -> { toast("Server started", false); transitionStates.remove(id); loadServers(); },
            err -> { toast(err, true); transitionStates.remove(id); loadServers(); },
            () -> renderServerList(__serverSnapshot)
        );
    }

    static function stopServer(id:String):Void {
        transitionStates.set(id, "stopping");
        Api.stopServer(id,
            _ -> { toast("Server stopped", false); transitionStates.remove(id); loadServers(); },
            err -> { toast(err, true); transitionStates.remove(id); loadServers(); },
            () -> renderServerList(__serverSnapshot)
        );
    }

    static function confirmDelete(id:String):Void {
        if (cast js.Browser.window.confirm("Delete this server? This cannot be undone.") == false) return;
        Api.deleteServer(id,
            () -> { toast("Server deleted", false); loadServers(); },
            err -> toast(err, true)
        );
    }

    /* -------- Logs modal -------- */
    static function buildLogModal():Void {
        logModal = div("modal-overlay log-modal hidden", container);
        div("modal", logModal);
    }

    static function openLogs(id:String):Void {
        currentLogServer = id;
        logModal.classList.remove("hidden");

        var modalContent = cast(logModal.firstChild, js.html.Element);
        clear(modalContent);

        spn("Server Logs - " + id, "modal-title", modalContent);
        var logArea = el("pre", "log-area", modalContent);
        btn("Close", "btn", modalContent, _ -> closeLogs());

        refreshLogs();
        logInterval = window.setInterval(() -> refreshLogs(), 3000);
    }

    static function refreshLogs():Void {
        Api.getProcessLogs(currentLogServer, 200,
            data -> {
                var logArea = cast(query(logModal, "pre.log-area"), js.html.PreElement);
                if (logArea == null) return;
                var lines:Array<Dynamic> = cast data;
                var txt = "";
                if (lines != null) {
                    for (l in lines) txt += l + "\n";
                }
                logArea.textContent = txt;
                logArea.scrollTop = logArea.scrollHeight;
            },
            _ -> {}
        );
    }

    static function closeLogs():Void {
        logModal.classList.add("hidden");
        if (logInterval != null) {
            window.clearInterval(logInterval);
            logInterval = null;
        }
    }

    /* -------- Console modal -------- */
    static function buildConsoleModal():Void {
        consoleModal = div("modal-overlay console-modal hidden", container);
        div("modal", consoleModal);
    }

    static function openConsole(id:String):Void {
        currentLogServer = id;
        consoleModal.classList.remove("hidden");

        var modalContent = cast(consoleModal.firstChild, js.html.Element);
        clear(modalContent);

        spn("Server Console - " + id, "modal-title", modalContent);

        var output = el("pre", "console-output", modalContent);
        var inputRow = div("console-input-row", modalContent);
        var cmdInput = input("text", "Type command...", "console-input", inputRow);
        btn("Send", "btn btn-primary", inputRow,
            _ -> {
                var cmd = StringTools.trim(cmdInput.value);
                if (cmd == "") return;
                Api.sendConsole(id, cmd,
                    data -> {
                        output.textContent += "\n> " + cmd + "\n" + (data != null ? cast data.output : "");
                        output.scrollTop = output.scrollHeight;
                    },
                    err -> {
                        output.textContent += "\nError: " + err;
                        output.scrollTop = output.scrollHeight;
                    }
                );
                cmdInput.value = "";
            }
        );
        btn("Close", "btn", inputRow, _ -> closeConsole());

        refreshConsoleLog();
        logInterval = window.setInterval(() -> refreshConsoleLog(), 3000);
    }

    static function refreshConsoleLog():Void {
        Api.getLogs(currentLogServer, 200,
            data -> {
                var output = cast(query(consoleModal, "pre.console-output"), js.html.PreElement);
                if (output == null) return;
                var lines:Array<Dynamic> = cast data;
                var txt = "";
                if (lines != null) {
                    for (l in lines) txt += l + "\n";
                }
                output.textContent = txt;
                output.scrollTop = output.scrollHeight;
            },
            _ -> {}
        );
    }

    static function closeConsole():Void {
        consoleModal.classList.add("hidden");
        if (logInterval != null) {
            window.clearInterval(logInterval);
            logInterval = null;
        }
    }

    /* -------- Query helpers -------- */
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
}
