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

            // Extract mods from save file if provided
            if (instance.saveFile != "") {
                var savePath = "data/saves/" + instance.saveFile;
                var modInfos = factorioManager.extractModsFromSave(savePath);
                instance.mods = [];
                for (modInfo in modInfos) {
                    var modEntry = new ModEntry();
                    modEntry.name = modInfo.name;
                    modEntry.title = modInfo.title;
                    modEntry.version = modInfo.version;
                    modEntry.enabled = true;
                    instance.mods.push(modEntry);
                }
            }

            instance.save();
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
        if (!processManager.isRunning(id)) {
            return server.jsonStatus(400, { error: "Server not running" });
        }

        if (processManager.isStopping(id)) {
            return server.jsonStatus(202, { status: "stopping" });
        }

        var success = processManager.stopInstance(id);
        if (success) {
            return server.jsonStatus(202, { status: "stopping" });
        } else {
            return server.jsonStatus(500, { error: "Failed to stop server" });
        }
    }

    static function apiGetServerConfig(req:HttpServerRequest):HttpServer.Response {
        var id = req.params.get("id");
        var instances = ServerInstance.list();
        haxe.Log.trace("apiGetServerConfig: id=" + id + ", found " + instances.length + " instances");
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

            // Re-extract mods if saveFile changed
            if (oldSaveFile != newSaveFile && newSaveFile != "") {
                var savePath = "data/saves/" + newSaveFile;
                var modInfos = factorioManager.extractModsFromSave(savePath);
                instance.mods = [];
                for (modInfo in modInfos) {
                    var modEntry = new ModEntry();
                    modEntry.name = modInfo.name;
                    modEntry.title = modInfo.title;
                    modEntry.version = modInfo.version;
                    modEntry.enabled = true;
                    instance.mods.push(modEntry);
                }
            }

            instance.save();
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
                    instance.save();
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
            instance.save();
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
                    instance.save();
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

            // Strip data URI prefix if present
            var base64Data = fileData;
            var commaIdx = fileData.lastIndexOf(",");
            if (commaIdx > 0) base64Data = fileData.substring(commaIdx + 1);

            // Decode base64 to bytes and save to instance's saves directory
            var bytes = haxe.crypto.Base64.decode(base64Data);
            var saveDir = instance.savesDir();
            ensureDir(saveDir);
            var out = sys.io.File.write(saveDir + "/" + fileName);
            out.writeBytes(bytes, 0, bytes.length);
            out.close();

            instance.saveFile = fileName;

            // Re-extract mods from the newly uploaded save
            var modInfos = factorioManager.extractModsFromSave(saveDir + "/" + fileName);
            instance.mods = [];
            for (modInfo in modInfos) {
                var modEntry = new ModEntry();
                modEntry.name = modInfo.name;
                modEntry.title = modInfo.title;
                modEntry.version = modInfo.version;
                modEntry.enabled = true;
                instance.mods.push(modEntry);
            }

            instance.save();
            return server.json({ saveFile: fileName });
        } catch (e:Dynamic) {
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
        var ts = Std.string(Math.floor(Sys.time()));
        var rand = Std.string(Math.floor(Math.random() * 10000));
        return ts + "_" + rand;
    }
}
