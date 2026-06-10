package server;

import server.HttpServer;

class Main {
    static var config:Config;
    static var factorioManager:FactorioManager;
    static var processManager:ServerProcessManager;
    static var server:HttpServer;

    static function main():Void {
        haxe.Log.trace("Starting Factorio Server Manager...");

        // Load configuration
        config = Config.load();

        // Initialize managers
        factorioManager = new FactorioManager(config);
        processManager = new ServerProcessManager(factorioManager, config);

        // Ensure directories exist
        ensureDir("data/config");
        ensureDir(ServerInstance.instancesDir());
        ensureDir("data/server");
        ensureDir("data/server/mods");
        ensureDir("data/saves");

        // Load instance registry into memory (thread-safe, no disk races)
        ServerInstance.loadRegistry();
        processManager.loadInstances();

        // Setup HTTP server
        server = new HttpServer(config.port);

        // API Routes
        setupRoutes();

        // Start server
        server.start();
    }

    static function setupRoutes():Void {
        // Static files / Web UI
        server.get("/", function(req:HttpServerRequest) { return serveHtml("index"); });
        server.get("/settings", function(req:HttpServerRequest) { return serveHtml("settings"); });
        server.get("/edit/:id", function(req:HttpServerRequest) {
            var id = req.params.get("id");
            return serveHtml("edit", id);
        });
        // Static assets
        server.get("/style.css", function(req:HttpServerRequest) { return serveStatic("style.css", "text/css"); });
        server.get("/app.js", function(req:HttpServerRequest) { return serveStatic("app.js", "application/javascript"); });

        // API: Servers
        server.get("/api/servers", apiListServers);
        server.post("/api/servers", apiCreateServer);
        server.delete("/api/servers/:id", apiDeleteServer);

        // API: Server control
        server.post("/api/servers/:id/start", apiStartServer);
        server.post("/api/servers/:id/stop", apiStopServer);

        // API: Server info
        server.get("/api/servers/:id/config", apiGetServerConfig);
        server.put("/api/servers/:id/config", apiUpdateServerConfig);

        // API: Logs & Console
        server.get("/api/servers/:id/logs", apiGetLogs);
        server.get("/api/servers/:id/process-logs", apiGetProcessLogs);
        server.post("/api/servers/:id/console", apiSendConsole);

        // API: Settings
        server.get("/api/settings", apiGetSettings);
        server.put("/api/settings", apiUpdateSettings);

        // API: Factorio versions
        server.get("/api/versions", apiGetVersions);

        // API: Mods
        server.get("/api/mods/search", apiSearchMods);
        server.get("/api/mods/:name", apiGetModDetails);

        // API: Server Mods
        server.put("/api/servers/:id/mods/toggle", apiToggleMod);
        server.post("/api/servers/:id/mods/add", apiAddMod);
        server.delete("/api/servers/:id/mods/remove", apiRemoveMod);

        // API: Save file upload
        server.post("/api/servers/:id/upload-save", apiUploadSave);
    }

    // --- Web UI serving ---

    static function serveHtml(page:String, ?id:String):HttpServer.Response {
        var path = "dist/web/" + page + ".html";
        var resp = server.serveFile(path, "text/html; charset=utf-8");
        if (resp != null) {
            // Inject server ID for edit pages
            if (id != null) {
                resp.body = StringTools.replace(resp.body, "<!--SERVER_ID-->", id);
            }
            return resp;
        }
        return server.text("text/html", "<html><body><h1>Factorio Server Manager</h1><p>Loading...</p></body></html>");
    }

    static function serveStatic(file:String, contentType:String):HttpServer.Response {
        var filePath = "dist/web/" + file;
        return server.serveFile(filePath, contentType) ?? server.jsonStatus(404, { error: "Not found" });
    }

    // --- API Handlers ---

    /**
     * Copy a save file from the base data/saves/ directory to an instance's savesDir.
     * Falls back to checking the instance's personal saves directory if the shared
     * pool does not contain the file (happens when the file was uploaded directly via
     * the upload-save endpoint rather than placed in the shared pool).
     */
    static function copySaveToInstance(instance:ServerInstance):Bool {
        var srcPath = "data/saves/" + instance.saveFile;
        var dstDir = instance.savesDir();
        var dstPath = dstDir + "/" + instance.saveFile;

        // File may already be in the instance's personal saves dir (uploaded directly),
        // so skip the copy if the destination already exists.
        if (sys.FileSystem.exists(dstPath)) {
            haxe.Log.trace("copySaveToInstance: " + instance.saveFile + " already in " + instance.id + "'s saves dir, skipping copy");
            return true;
        }

        if (!sys.FileSystem.exists(srcPath)) {
            haxe.Log.trace("copySaveToInstance: source " + srcPath + " not found, and file not in instance dir either");
            return false;
        }

        // Ensure destination subdirectory matches the relative path structure
        var lastSlash = instance.saveFile.lastIndexOf("/");
        if (lastSlash > 0) {
            var dstSubDir = dstDir + "/" + instance.saveFile.substring(0, lastSlash);
            if (!sys.FileSystem.exists(dstSubDir)) {
                sys.FileSystem.createDirectory(dstSubDir);
            }
        }

        sys.io.File.copy(srcPath, dstPath);
        return true;
    }

    static function apiListServers(req:HttpServerRequest):HttpServer.Response {
        var instances = processManager.getAllProcesses();
        return server.json(instances);
    }

    static function apiCreateServer(req:HttpServerRequest):HttpServer.Response {
        try {
            var data = haxe.Json.parse(req.body);
            var instance = new ServerInstance();
            instance.id = generateId();
            instance.name = (data.name != null ? cast data.name : "New Server");
            instance.saveFile = (data.saveFile != null ? cast data.saveFile : "");

            if (instance.name == "" || instance.name == null) {
                instance.name = "Server_" + instance.id;
            }

            // Copy save file to instance's directory (mods will be loaded from
            // mods-list.json on first server start via --sync-mods)
            if (instance.saveFile != "") {
                copySaveToInstance(instance);
            }

            // Atomically save and register to prevent race with concurrent list() calls
            ServerInstance.saveAndRegister(instance);
            return server.jsonStatus(201, instance);
        } catch (e:Dynamic) {
            return server.jsonStatus(400, { error: "Failed to create server: " + e });
        }
    }

    static function apiDeleteServer(req:HttpServerRequest):HttpServer.Response {
        var id = req.params.get("id");
        try {
            // deleteInstance() handles: stop if running, wait for stop, then delete config
            var success = processManager.deleteInstance(id);
            if (success) {
                ServerInstance.unregisterInstance(id);
                return server.noContent();
            } else {
                return server.jsonStatus(500, { error: "Failed to delete server" });
            }
        } catch (e:Dynamic) {
            return server.jsonStatus(500, { error: "Failed to delete server: " + e });
        }
    }

    static function apiStartServer(req:HttpServerRequest):HttpServer.Response {
        var id = req.params.get("id");
        var instances = ServerInstance.list();
        var instance = null;
        for (i in instances) {
            if (i.id == id) {
                instance = i;
                break;
            }
        }

        if (instance == null) {
            return server.jsonStatus(404, { error: "Server not found" });
        }

        if (processManager.isRunning(id)) {
            return server.jsonStatus(400, { error: "Server already running" });
        }

        if (processManager.isStarting(id)) {
            return server.jsonStatus(202, { status: "starting" });
        }

        var success = processManager.startInstance(instance);
        if (success) {
            return server.jsonStatus(202, { status: "starting" });
        } else {
            return server.jsonStatus(500, { error: "Failed to start server" });
        }
    }

    static function apiStopServer(req:HttpServerRequest):HttpServer.Response {
        var id = req.params.get("id");

        // Idempotent: if the server is not running (already stopped or never started),
        // the desired state is achieved — return success.
        if (!processManager.isRunning(id)) {
            return server.jsonStatus(200, { status: "stopped" });
        }

        if (processManager.isStopping(id)) {
            return server.jsonStatus(202, { status: "stopping" });
        }

        var success = processManager.stopInstance(id);
        if (success) {
            return server.jsonStatus(202, { status: "stopping" });
        } else {
            // stopInstance() returned false while isRunning was true — unlikely race.
            // Mark as stopped to keep state clean.
            return server.jsonStatus(200, { status: "stopped" });
        }
    }

    static function apiGetServerConfig(req:HttpServerRequest):HttpServer.Response {
        var id = req.params.get("id");
        var instances = ServerInstance.list();
        for (i in instances) {
            if (i.id == id) {
                return server.json(i);
            }
        }
        return server.jsonStatus(404, { error: "Server not found" });
    }

    static function apiUpdateServerConfig(req:HttpServerRequest):HttpServer.Response {
        var id = req.params.get("id");
        try {
            var instances = ServerInstance.list();
            var instance = null;
            for (i in instances) {
                if (i.id == id) {
                    instance = i;
                    break;
                }
            }

            if (instance == null) {
                return server.jsonStatus(404, { error: "Server not found" });
            }

            var data = haxe.Json.parse(req.body);
            var oldSaveFile = instance.saveFile ?? "";
            var newSaveFile = data.saveFile != null ? cast data.saveFile : oldSaveFile;

            if (data.name != null) instance.name = cast data.name;
            if (data.password != null) instance.password = cast data.password;
            if (data.admins != null) instance.admins = cast data.admins;
            if (data.autosaveInterval != null) instance.autosaveInterval = cast data.autosaveInterval;
            if (data.autosaveSlots != null) instance.autosaveSlots = cast data.autosaveSlots;
            if (data.maxPlayers != null) instance.maxPlayers = cast data.maxPlayers;
            if (data.version != null) instance.version = cast data.version;
            instance.saveFile = newSaveFile;
            if (data.mods != null) instance.mods = ServerInstance.parseMods(data.mods);

            // Clear mods if saveFile changed; they will be reloaded from
            // mods-list.json on next server start via --sync-mods
            if (oldSaveFile != newSaveFile) {
                instance.mods = [];

                // Copy new save file to instance's directory
                if (newSaveFile != "") {
                    copySaveToInstance(instance);
                }
            }

            ServerInstance.saveAndRegister(instance);
            return server.json(instance);
        } catch (e:Dynamic) {
            return server.jsonStatus(400, { error: "Failed to update config: " + e });
        }
    }

    static function apiGetLogs(req:HttpServerRequest):HttpServer.Response {
        var id = req.params.get("id");
        var lines = 100;
        if (req.headers.exists("x-lines")) {
            lines = Std.parseInt(req.headers.get("x-lines"));
        }
        var logs = processManager.getLogs(id, lines);
        return server.json(logs);
    }

    static function apiGetProcessLogs(req:HttpServerRequest):HttpServer.Response {
        var id = req.params.get("id");
        var lines = 100;
        if (req.headers.exists("x-lines")) {
            lines = Std.parseInt(req.headers.get("x-lines"));
        }
        var logs = processManager.getProcessLogs(id, lines);
        return server.json(logs);
    }

    static function apiSendConsole(req:HttpServerRequest):HttpServer.Response {
        var id = req.params.get("id");
        var data = haxe.Json.parse(req.body);
        var command = cast (data.command ?? ""), String;
        var output = processManager.sendConsoleCommand(id, command);
        return server.json({ output: output });
    }

    static function apiGetSettings(req:HttpServerRequest):HttpServer.Response {
        // Don't return the token for security
        var safe = {
            port: config.port,
            factorioUsername: config.factorioUsername
        };
        return server.json(safe);
    }

    static function apiUpdateSettings(req:HttpServerRequest):HttpServer.Response {
        try {
            var data = haxe.Json.parse(req.body);
            if (data.port != null) config.port = cast data.port;
            if (data.factorioUsername != null) config.factorioUsername = cast data.factorioUsername;
            if (data.factorioToken != null) config.factorioToken = cast data.factorioToken;

            config.save();
            return server.jsonStatus(200, { status: "saved" });
        } catch (e:Dynamic) {
            return server.jsonStatus(400, { error: "Failed to save settings: " + e });
        }
    }

    static function apiGetVersions(req:HttpServerRequest):HttpServer.Response {
        var versions = factorioManager.listInstalledVersions();
        return server.json(versions);
    }

    static function apiSearchMods(req:HttpServerRequest):HttpServer.Response {
        var q = req.headers.get("q") ?? req.params.get("q") ?? "";
        // Query string parsing
        var fullPath = req.path;
        var queryStart = fullPath.indexOf("?");
        if (queryStart >= 0) {
            var queryStr = fullPath.substring(queryStart + 1);
            var pairs = queryStr.split("&");
            for (pair in pairs) {
                var parts = pair.split("=");
                if (parts.length == 2 && parts[0] == "q") {
                    q = parts[1];
                }
            }
        }

        var results = factorioManager.searchMods(q);
        return server.json(results);
    }

    static function apiGetModDetails(req:HttpServerRequest):HttpServer.Response {
        var name = req.params.get("name");
        var details = factorioManager.getModDetails(name);
        if (details != null) {
            return server.json(details);
        }
        return server.jsonStatus(404, { error: "Mod not found" });
    }

    static function apiToggleMod(req:HttpServerRequest):HttpServer.Response {
        var id = req.params.get("id");
        try {
            var instances = ServerInstance.list();
            var instance = null;
            for (i in instances) {
                if (i.id == id) {
                    instance = i;
                    break;
                }
            }
            if (instance == null) {
                return server.jsonStatus(404, { error: "Server not found" });
            }

            var data = haxe.Json.parse(req.body);
            var modName = cast (data.name ?? ""), String;
            if (instance.mods == null) instance.mods = [];

            for (mod in instance.mods) {
                if (mod.name == modName) {
                    mod.enabled = !mod.enabled;
                    ServerInstance.saveAndRegister(instance);
                    return server.json(instance);
                }
            }
            return server.jsonStatus(404, { error: "Mod not found" });
        } catch (e:Dynamic) {
            return server.jsonStatus(400, { error: "Failed to toggle mod: " + e });
        }
    }

    static function apiAddMod(req:HttpServerRequest):HttpServer.Response {
        var id = req.params.get("id");
        try {
            var instances = ServerInstance.list();
            var instance = null;
            for (i in instances) {
                if (i.id == id) {
                    instance = i;
                    break;
                }
            }
            if (instance == null) {
                return server.jsonStatus(404, { error: "Server not found" });
            }

            var data = haxe.Json.parse(req.body);
            var modName = cast (data.name ?? ""), String;
            var modTitle = cast (data.title ?? modName), String;
            var modVersion = cast (data.version ?? ""), String;

            if (instance.mods == null) instance.mods = [];

            // Check if mod already exists
            for (mod in instance.mods) {
                if (mod.name == modName) {
                    return server.jsonStatus(400, { error: "Mod already exists" });
                }
            }

            var modEntry = new ModEntry();
            modEntry.name = modName;
            modEntry.title = modTitle;
            modEntry.version = modVersion;
            modEntry.enabled = true;
            instance.mods.push(modEntry);
            ServerInstance.saveAndRegister(instance);
            return server.jsonStatus(201, instance);
        } catch (e:Dynamic) {
            return server.jsonStatus(400, { error: "Failed to add mod: " + e });
        }
    }

    static function apiRemoveMod(req:HttpServerRequest):HttpServer.Response {
        var id = req.params.get("id");
        try {
            var instances = ServerInstance.list();
            var instance = null;
            for (i in instances) {
                if (i.id == id) {
                    instance = i;
                    break;
                }
            }
            if (instance == null) {
                return server.jsonStatus(404, { error: "Server not found" });
            }

            var data = haxe.Json.parse(req.body);
            var modName = cast (data.name ?? ""), String;
            if (instance.mods == null) instance.mods = [];

            for (i in 0...instance.mods.length) {
                if (instance.mods[i].name == modName) {
                    instance.mods.splice(i, 1);
                    ServerInstance.saveAndRegister(instance);
                    return server.json(instance);
                }
            }
            return server.jsonStatus(404, { error: "Mod not found" });
        } catch (e:Dynamic) {
            return server.jsonStatus(400, { error: "Failed to remove mod: " + e });
        }
    }

    static function apiUploadSave(req:HttpServerRequest):HttpServer.Response {
        var id = req.params.get("id");
        try {
            var instances = ServerInstance.list();
            var instance = null;
            for (i in instances) {
                if (i.id == id) {
                    instance = i;
                    break;
                }
            }
            if (instance == null) {
                return server.jsonStatus(404, { error: "Server not found" });
            }

            var data = haxe.Json.parse(req.body);
            var fileName = cast (data.fileName ?? ""), String;
            var fileData = cast (data.fileData ?? ""), String;

            if (fileName == "" || fileData == "") {
                return server.jsonStatus(400, { error: "Missing fileName or fileData" });
            }

            haxe.Log.trace("apiUploadSave: receiving file " + fileName + " for instance " + id);

            // Strip data URI prefix if present
            var base64Data = fileData;
            var commaIdx = fileData.lastIndexOf(",");
            if (commaIdx > 0) base64Data = fileData.substring(commaIdx + 1);

            // Decode base64 to bytes and save to instance's saves directory.
            // haxe.crypto.Base64.decode on the Python target is O(n^2) and blocks
            // for minutes on large files (~3MB base64). We defer the decode to a
            // background thread by writing the base64 to a temp file first.
            var saveDir = instance.savesDir();
            ensureDir(saveDir);
            var tmpB64 = saveDir + "/_upload.b64";
            sys.io.File.saveContent(tmpB64, base64Data);

            // Save fileName immediately so the caller knows the upload was accepted.
            instance.saveFile = fileName;
            ServerInstance.saveAndRegister(instance);

            // Decode base64 in the background so the response returns within
            // the HTTP timeout. Mods will be loaded from mods-list.json on
            // next server start via --sync-mods.
            var _tmpB64 = tmpB64;
            var _saveDir = saveDir;
            var _fileName = fileName;
            var _id = id;
            sys.thread.Thread.create(function() {
                try {
                    // Decode base64 using system command (fast on Python target)
                    var decodeCmd = "base64 -d " + _tmpB64 + " > " + (_saveDir + "/" + _fileName);
                    var proc = new sys.io.Process("bash", ["-c", decodeCmd]);
                    proc.stdout.readAll().toString();
                    proc.stderr.readAll().toString();
                    var exitCode = proc.exitCode();
                    proc.close();
                    if (exitCode != 0) {
                        haxe.Log.trace("apiUploadSave background: base64 decode failed with code " + exitCode);
                        return;
                    }
                    haxe.Log.trace("apiUploadSave: wrote file to " + _saveDir + "/" + _fileName);
                    sys.FileSystem.deleteFile(_tmpB64);

                    // Clear mods so they get reloaded from mods-list.json on next start
                    var inst = ServerInstance.getRegistered(_id);
                    if (inst != null) {
                        inst.mods = [];
                        ServerInstance.saveAndRegister(inst);
                    }
                } catch (e:Dynamic) {
                    haxe.Log.trace("apiUploadSave background: failed for " + _id + ": " + e);
                    try {
                        sys.FileSystem.deleteFile(_tmpB64);
                    } catch (_:Dynamic) {}
                }
            });

            return server.json({ saveFile: fileName });
        } catch (e:Dynamic) {
            haxe.Log.trace("apiUploadSave error: " + e);
            return server.jsonStatus(500, { error: "Failed to upload save: " + e });
        }
    }

    // --- Helpers ---

    static function ensureDir(path:String):Void {
        if (!sys.FileSystem.exists(path) && !isDirectory(path)) {
            sys.FileSystem.createDirectory(path);
        }
    }

    static function isDirectory(path:String):Bool {
        try {
            return sys.FileSystem.isDirectory(path);
        } catch (e:Dynamic) {
            return false;
        }
    }

    static function generateId():String {
        var ts = Sys.time();
        var secs = Std.int(ts);
        var us = Std.int((ts - secs) * 1000000);
        var r1 = Std.int(Math.random() * 0xFFFF);
        var r2 = Std.int(Math.random() * 0xFFFF);
        return Std.string(secs) + "_" + Std.string(us) + "_" + Std.string(r1) + "_" + Std.string(r2);
    }
}
