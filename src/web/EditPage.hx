package web;

import js.Browser.document;
import js.Browser.window;
import StringTools;

class EditPage {

    static var container:js.html.Element;
    static var serverId:String = "";
    static var serverConfig:Dynamic = null;
    static var selectedVersion:String = "";
    static var modListContainer:js.html.DivElement = null;
    static var modSearchInput:js.html.InputElement = null;

    /* -------- Main entry -------- */
    static public function render():Void {
        container = cast document.getElementById("app");
        clear(container);

        serverId = extractServerId();
        if (serverId == "") {
            el("h1", null, container).textContent = "Error: No server ID";
            return;
        }

        buildHeader();
        buildFormSkeleton();
        loadServerConfig();
        loadVersions();
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

    static function select(?cls:String, ?parent:js.html.Element):js.html.SelectElement {
        var s:js.html.SelectElement = cast document.createElement("select");
        if (cls != null) s.className = cls;
        if (parent != null) append(parent, s);
        return s;
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

    /* -------- Extract server ID -------- */
    static function extractServerId():String {
        var parts = window.location.pathname.split("/");
        if (parts.length >= 3) return parts[2];
        var meta = cast(document.querySelector("meta[name=server-id]"), js.html.MetaElement);
        if (meta != null) return meta.content;
        return "";
    }

    /* -------- Header -------- */
    static function buildHeader():Void {
        var h = div("page-header", container);
        var title = el("h1", "page-title", h);
        title.textContent = "Edit Server: " + serverId;

        var nav = div("nav-bar", h);
        btn("← Back", "btn", nav, () -> window.location.href = "/");
    }

    /* -------- Form skeleton -------- */
    static function buildFormSkeleton():Void {
        var form = div("edit-form", container);

        field("Server Name", null, form);
        field("Server Password", null, form);
        field("Max Players", null, form);
        field("Autosave Interval (minutes)", null, form);
        field("Autosave Slots", null, form);
        field("Save File", null, form);

        var verField = field("Version", "Pin to specific version or leave as latest", form);
        select("form-select form-input", verField);

        field("Admins (comma-separated)", null, form);

        var btnRow = div("form-actions", form);
        btn("Save Changes", "btn btn-primary", btnRow, doSave);

        /* Mods section */
        buildModsSection(container);
    }

    /* -------- Mods section -------- */
    static function buildModsSection(parent:js.html.Element):Void {
        var section = div("mods-section", parent);
        var sectionHeader = el("h2", "section-title", section);
        sectionHeader.textContent = "Mods";

        /* Search + Add row */
        var searchRow = div("mod-search-row", section);
        modSearchInput = input("text", "Search mod portal...", null, "form-input mod-search-input", searchRow);
        btn("Search & Add", "btn mod-add-btn", searchRow, doSearchAndAdd);

        /* Mod list container */
        modListContainer = div("mod-list", section);
        var emptyMsg = spn("No mods loaded", "mod-empty-msg", modListContainer);
    }

    /* -------- Load server config -------- */
    static function loadServerConfig():Void {
        Api.getServerConfig(serverId,
            data -> {
                serverConfig = data;
                populateForm(data);
            },
            err -> toast("Failed to load server config: " + err, true)
        );
    }

    static function populateForm(cfg:Dynamic):Void {
        var form:js.html.DivElement = cast query(container, ".edit-form");
        if (form == null) return;

        var fields:Array<js.html.Element> = queryAll(form, ".form-field");
        if (fields.length < 7) return;

        var nameInput = input("text", null, cfg.name, "form-input", fields[0]);

        var passInput = input("password", null, cfg.password != null ? cfg.password : "", "form-input", fields[1]);

        var maxInput = input("number", null, Std.string(cfg.maxPlayers), "form-input", fields[2]);
        maxInput.setAttribute("min", "1");
        maxInput.setAttribute("max", "100");

        var autoInput = input("number", null, Std.string(cfg.autosaveInterval), "form-input", fields[3]);
        autoInput.setAttribute("min", "1");
        autoInput.setAttribute("max", "60");

        var slotsInput = input("number", null, Std.string(cfg.autosaveSlots), "form-input", fields[4]);
        slotsInput.setAttribute("min", "1");
        slotsInput.setAttribute("max", "20");

        /* --- Save file row: text input + hidden file picker + Upload button --- */
        var saveField = fields[5];
        clear(saveField);
        label("Save File", "field-label", saveField);

        var saveRow = div("save-field-row", saveField);
        var saveText:js.html.InputElement = cast document.createElement("input");
        saveText.type = "text";
        saveText.value = cfg.saveFile != null ? cfg.saveFile : "";
        saveText.className = "form-input save-file-input";
        saveText.placeholder = "Select or enter save file";
        saveRow.appendChild(saveText);

        var filePicker:js.html.InputElement = cast document.createElement("input");
        filePicker.type = "file";
        filePicker.accept = ".zip,.factorio";
        filePicker.className = "save-file-picker";
        saveRow.appendChild(filePicker);

        var uploadBtn:js.html.ButtonElement = cast document.createElement("button");
        uploadBtn.textContent = "Upload";
        uploadBtn.className = "btn btn-upload-save";
        saveRow.appendChild(uploadBtn);

        uploadBtn.addEventListener("click", (_) -> {
            filePicker.click();
            return false;
        });

        filePicker.addEventListener("change", (_) -> {
            var files = filePicker.files;
            if (files == null || files.length == 0) return;
            var file:js.html.File = cast files.item(0);
            if (file == null) return;

            uploadBtn.disabled = true;
            uploadBtn.textContent = "Uploading...";

            Api.uploadSaveFile(serverId, file,
                (data:Dynamic) -> {
                    var uploadedName = data.saveFile != null ? data.saveFile : file.name;
                    saveText.value = uploadedName;
                    uploadBtn.disabled = false;
                    uploadBtn.textContent = "Upload";
                    toast("Uploaded: " + uploadedName, false);
                },
                (err:String) -> {
                    uploadBtn.disabled = false;
                    uploadBtn.textContent = "Upload";
                    toast("Upload failed: " + err, true);
                }
            );
        });

        var verSelect:js.html.SelectElement = cast query(fields[6], "select");
        if (verSelect != null) {
            selectedVersion = cfg.version != null ? cfg.version : "latest";
        }

        var adminsInput = input("text", null, "", "form-input", fields[7]);
        if (cfg.admins != null) {
            adminsInput.value = cfg.admins.join(", ");
        }

        populateMods(cfg.mods);
    }

    /* -------- Populate mods -------- */
    static function populateMods(mods:Array<Dynamic>):Void {
        if (modListContainer == null) return;
        clear(modListContainer);

        if (mods == null || mods.length == 0) {
            spn("No mods loaded", "mod-empty-msg", modListContainer);
            return;
        }

        renderModList(mods);
    }

    static function renderModList(mods:Array<Dynamic>):Void {
        clear(modListContainer);

        for (mod in mods) {
            var row = div("mod-row", modListContainer);

            var checkBox:js.html.InputElement = cast document.createElement("input");
            checkBox.type = "checkbox";
            checkBox.checked = mod.enabled;
            checkBox.className = "mod-checkbox";
            untyped checkBox.addEventListener("change", (e:Dynamic) -> {
                var target:js.html.InputElement = cast e.target;
                for (m in mods) {
                    if (m.name == mod.name) {
                        m.enabled = target.checked;
                        break;
                    }
                }
                Api.toggleMod(serverId, mod.name, null, err -> toast("Failed to toggle mod: " + err, true));
            });
            row.appendChild(checkBox);

            var modInfo = div("mod-info", row);
            var modTitle = spn(mod.title != null ? mod.title : mod.name, "mod-title", modInfo);
            var modName = spn(mod.name, "mod-name", modInfo);
            var modVersion:js.html.SpanElement = null;
            if (mod.version != null && mod.version != "") {
                modVersion = spn("(v" + mod.version + ")", "mod-version", modInfo);
            }

            btn("Remove", "btn btn-mod-remove", row, () -> doRemoveMod(mod.name));
        }
    }

    /* -------- Search & Add mod -------- */
    static function doSearchAndAdd():Void {
        var searchText = StringTools.trim(modSearchInput.value);
        if (searchText == "") {
            toast("Enter a mod name to search", true);
            return;
        }

        Api.searchMods(searchText,
            data -> {
                var results:Array<Dynamic> = cast data;
                if (results == null || results.length == 0) {
                    toast("No mods found for: " + searchText, true);
                    return;
                }
                var first = results[0];
                var modName = first.name != null ? first.name : first.id != null ? first.id : searchText;
                var modTitle = first.title != null ? first.title : modName;
                var modVersion = first.version != null ? first.version : "";

                Api.addMod(serverId, modName, modTitle, modVersion,
                    _ -> {
                        toast("Added mod: " + modTitle, false);
                        loadServerConfig();
                    },
                    err -> toast("Failed to add mod: " + err, true)
                );
            },
            err -> toast("Search failed: " + err, true)
        );
    }

    /* -------- Remove mod -------- */
    static function doRemoveMod(modName:String):Void {
        Api.removeMod(serverId, modName,
            _ -> {
                toast("Removed mod: " + modName, false);
                loadServerConfig();
            },
            err -> toast("Failed to remove mod: " + err, true)
        );
    }

    /* -------- Load versions -------- */
    static function loadVersions():Void {
        Api.getVersions(
            data -> {
                var form:js.html.DivElement = cast query(container, ".edit-form");
                if (form == null) return;
                var fields:Array<js.html.Element> = queryAll(form, ".form-field");
                if (fields.length < 7) return;

                var verSelect:js.html.SelectElement = cast query(fields[6], "select");
                if (verSelect == null) return;

                while (verSelect.firstChild != null) verSelect.removeChild(verSelect.firstChild);

                var opt0:js.html.OptionElement = cast document.createElement("option");
                opt0.value = "latest";
                opt0.textContent = "latest (auto-update)";
                verSelect.appendChild(opt0);

                var versions:Array<Dynamic> = cast data;
                if (versions != null) {
                    for (v in versions) {
                        var opt:js.html.OptionElement = cast document.createElement("option");
                        opt.value = v;
                        opt.textContent = v;
                        verSelect.appendChild(opt);
                    }
                }

                if (selectedVersion != "") {
                    verSelect.value = selectedVersion;
                }
            },
            _ -> {}
        );
    }

    /* -------- Save -------- */
    static function doSave():Void {
        var form:js.html.DivElement = cast query(container, ".edit-form");
        if (form == null) return;

        var fields:Array<js.html.Element> = queryAll(form, ".form-field");
        var nameInput:js.html.InputElement = cast query(fields[0], "input");
        var passInput:js.html.InputElement = cast query(fields[1], "input");
        var maxInput:js.html.InputElement = cast query(fields[2], "input");
        var autoInput:js.html.InputElement = cast query(fields[3], "input");
        var slotsInput:js.html.InputElement = cast query(fields[4], "input");
        var saveInput:js.html.InputElement = cast query(fields[5], ".save-file-input");
        var verSelect:js.html.SelectElement = cast query(fields[6], "select");
        var adminsInput:js.html.InputElement = cast query(fields[7], "input");

        var admins:Array<String> = [];
        if (adminsInput != null && StringTools.trim(adminsInput.value) != "") {
            var parts = adminsInput.value.split(",");
            for (p in parts) {
                var trimmed = StringTools.trim(p);
                if (trimmed != "") admins.push(trimmed);
            }
        }

        var config:Dynamic = {
            name: if (nameInput != null) nameInput.value else "",
            password: if (passInput != null) passInput.value else "",
            maxPlayers: if (maxInput != null) Std.parseInt(maxInput.value) else 16,
            autosaveInterval: if (autoInput != null) Std.parseInt(autoInput.value) else 5,
            autosaveSlots: if (slotsInput != null) Std.parseInt(slotsInput.value) else 5,
            saveFile: if (saveInput != null) saveInput.value else "",
            version: if (verSelect != null) verSelect.value else "latest",
            admins: admins
        };

        if (serverConfig != null && serverConfig.mods != null) {
            config.mods = serverConfig.mods;
        }

        Api.updateServerConfig(serverId, config,
            _ -> toast("Server config saved", false),
            err -> toast("Failed to save: " + err, true)
        );
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
