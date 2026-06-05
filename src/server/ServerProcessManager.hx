package server;

/**
 * Manages running Factorio server processes (start, stop, logs, console).
 */
typedef ProcessInfo = {
    var process:sys.io.Process;
    var instance:ServerInstance;
    var logBuffer:StringBuf;
    var started:Bool;
}

class ServerProcessManager {
    var processes:Map<String, ProcessInfo>;
    var factorioManager:FactorioManager;
    var managerConfig:Config;
    var startingStates:Map<String, Bool>;
    var stoppingStates:Map<String, Bool>;

    public function new(factorio:FactorioManager, config:Config) {
        this.processes = new Map();
        this.factorioManager = factorio;
        this.managerConfig = config;
        this.startingStates = new Map();
        this.stoppingStates = new Map();
    }

    /**
     * Start a Factorio server instance (async — spawns a background thread).
     * Returns true if the start was initiated, false if already running or starting.
     */
    public function startInstance(instance:ServerInstance):Bool {
        if (processes.exists(instance.id) && isRunning(instance.id)) {
            return false; // Already running
        }
        if (startingStates.exists(instance.id) && startingStates.get(instance.id)) {
            return false; // Already starting
        }

        startingStates.set(instance.id, true);

        var _this = this;
        sys.thread.Thread.create(function() {
            try {
                _this._doStart(instance);
                startingStates.set(instance.id, false);
            } catch (e:Dynamic) {
                haxe.Log.trace("Threaded start failed for " + instance.id + ": " + e);
                startingStates.set(instance.id, false);
            }
        });

        return true;
    }

    /**
     * Stop a Factorio server instance (async — spawns a background thread).
     * Returns true if the stop was initiated, false if not running or already stopping.
     */
    public function stopInstance(id:String):Bool {
        if (!processes.exists(id)) return false;
        if (!isRunning(id)) return false;
        if (stoppingStates.exists(id) && stoppingStates.get(id)) return false;

        stoppingStates.set(id, true);

        var _this = this;
        sys.thread.Thread.create(function() {
            try {
                _this._doStop(id);
                stoppingStates.set(id, false);
            } catch (e:Dynamic) {
                haxe.Log.trace("Threaded stop failed for " + id + ": " + e);
                stoppingStates.set(id, false);
            }
        });

        return true;
    }

    /**
     * Check if a server is currently in the process of starting.
     */
    public function isStarting(id:String):Bool {
        return startingStates.exists(id) && startingStates.get(id);
    }

    /**
     * Check if a server is currently in the process of stopping.
     */
    public function isStopping(id:String):Bool {
        return stoppingStates.exists(id) && stoppingStates.get(id);
    }

    /**
     * Internal: perform the actual start work inside a background thread.
     */
    function _doStart(instance:ServerInstance):Void {
        // Ensure save directory exists
        if (!sys.FileSystem.exists(instance.savesDir())) {
            sys.FileSystem.createDirectory(instance.savesDir());
        }

        // Sync mods
        this.factorioManager.syncMods(instance);

        // Get binary path
        var binary = this.factorioManager.getServerBinaryPath(instance.version);

        // Build command arguments
        var args = ["--server-settings", ServerSettings.settingsPath(instance.id)];

        // Set game settings
        this.writeServerSettings(instance);

        var logPath = instance.savesDir() + "/" + instance.id + ".log";
        args.push("--start-server");
        args.push(instance.savesDir() + "/" + instance.saveFile);
        args.push("--port");
        args.push(stringify(8000 + hash(instance.id))); // offset port per instance
        args.push("--console-log");
        args.push(logPath);

        // Add admin whitelist
        if (instance.admins != null && instance.admins.length > 0) {
            args.push("--admins");
            args.push(instance.admins.join(","));
        }

        var cmd = binary;

        haxe.Log.trace("Starting Factorio server: " + cmd + " " + args.join(" "));

        var proc = new sys.io.Process(cmd, args);
        var info:ProcessInfo = {
            process: proc,
            instance: instance,
            logBuffer: new StringBuf(),
            started: true
        };
        this.processes.set(instance.id, info);

        instance.running = true;
        instance.save();
    }

    /**
     * Internal: perform the actual stop work inside a background thread.
     */
    function _doStop(id:String):Void {
        var info = processes.get(id);

        // Send "exit" command to the console
        info.process.stdin.writeString("exit\n");
        info.process.stdin.flush();

        // Wait for process to exit (with timeout)
        var waited = 0;
        while (waited < 30) {
            if (!isRunning(id)) break;
            Sys.sleep(1);
            waited++;
        }

        // Force kill if still running
        if (isRunning(id)) {
            info.process.stdin.close();
            info.process.stdout.close();
            info.process.stderr.close();
            info.process.close();
        }

        var instance = info.instance;
        instance.running = false;
        instance.pid = -1;
        instance.save();

        this.processes.remove(id);
    }

    /**
     * Wait for a pending stop operation to complete.
     * Blocks the caller for up to `timeout` seconds.
     * Returns true if the server is no longer stopping, false on timeout.
     */
    public function waitForStop(id:String, timeout:Int = 40):Bool {
        var waited = 0;
        while (waited < timeout) {
            if (!isStopping(id) && !isRunning(id)) return true;
            Sys.sleep(1);
            waited++;
        }
        return false;
    }

    /**
     * Synchronous delete: stop the instance if running, wait for stop to finish,
     * then remove process entry and config file. Runs on the caller thread
     * (HTTP handler) so the delete is complete before the response is sent.
     */
    public function deleteInstance(id:String):Bool {
        // Stop if running
        if (isRunning(id)) {
            if (!stopInstance(id)) return false;
            if (!waitForStop(id)) {
                haxe.Log.trace("Delete timeout waiting for " + id + " to stop");
                return false;
            }
        }

        // Clean up process entry and state flags
        processes.remove(id);
        startingStates.remove(id);
        stoppingStates.remove(id);

        // Delete config file
        try {
            var configPath = "data/config/instances/" + id + ".json";
            if (sys.FileSystem.exists(configPath)) {
                sys.FileSystem.deleteFile(configPath);
            }
        } catch (e:Dynamic) {
            haxe.Log.trace("Error deleting config for " + id + ": " + e);
        }

        return true;
    }

    /**
     * Check if a server instance is running.
     */
    public function isRunning(id:String):Bool {
        if (!processes.exists(id)) return false;
        try {
            return processes.get(id).process.exitCode() == null;
        } catch (e:Dynamic) {
            return false;
        }
    }

    /**
     * Send a command to the server console.
     */
    public function sendConsoleCommand(id:String, command:String):Null<String> {
        if (!processes.exists(id)) return null;
        try {
            var info = processes.get(id);
            info.process.stdin.writeString(command + "\n");
            info.process.stdin.flush();

            // Read response
            Sys.sleep(1);
            var output = info.process.stdout.readLine();
            return output;
        } catch (e:Dynamic) {
            return "Error: " + e;
        }
    }

    /**
     * Get recent log lines for a server.
     */
    public function getLogs(id:String, lines:Int = 100):Array<String> {
        var logPath = "";
        if (processes.exists(id)) {
            var instance = processes.get(id).instance;
            logPath = instance.savesDir() + "/" + id + ".log";
        }

        if (!sys.FileSystem.exists(logPath)) {
            // Try reading from process stdout
            if (processes.exists(id)) {
                var info = processes.get(id);
                return info.logBuffer.toString().split("\n");
            }
            return [];
        }

        try {
            var content = sys.io.File.getContent(logPath);
            var allLines = content.split("\n");
            var start = if (allLines.length - lines > 0) allLines.length - lines else 0;
            return allLines.slice(start);
        } catch (e:Dynamic) {
            return [];
        }
    }

    /**
     * Get all running processes info.
     */
    public function getAllProcesses():Array<ServerInstance> {
        var result:Array<ServerInstance> = [];
        var instances = ServerInstance.list();
        for (instance in instances) {
            instance.running = this.isRunning(instance.id);
            result.push(instance);
        }
        return result;
    }

    /**
     * Write server.settings.json for a Factorio instance.
     */
    function writeServerSettings(instance:ServerInstance):Void {
        var settings = {
            "name": instance.name,
            "description": "",
            "players": instance.maxPlayers,
            "visibility": {"in-match-list": true},
            "max-users": instance.maxPlayers,
            "max-upload-in-kbps": 0,
            "require-user-password": instance.password != "",
            "whitelist-users": false,
            "max-cmdbar-lines": 2,
            "rf-autohost-port": 0,
            "gamepassword": instance.password,
            "save-file": instance.saveFile,
            "autosave-slot-mode": "manual",
            "autosave-interval": instance.autosaveInterval,
            "autosave-slot-count": instance.autosaveSlots,
            "afk-autosave-slot-count": 0,
            "autoadapter": null,
            "autosave-only-on-server": true,
            "only-advertis-autosaved-slots": false,
            "tags": [],
            "ram-size-hard-limit-in-mebibytes": 0,
            "ram-size-warn-limit-in-mebibytes": 0,
            "max-stop-for-autosave": false,
            "ignore-final-autosave": false,
            "non-networked-player": {},
            "ignore-console": false,
            "localize": true,
            "max-stop-for-script": 0,
            "min-non-network-players-for-pause": 0,
            "auto-pause-for-non-networked-players": false,
            "forged-settings-token": ""
        };

        var json = haxe.Json.stringify(settings, "\t");
        sys.io.File.saveContent(ServerSettings.settingsPath(instance.id), json);
    }

    function hash(s:String):Int {
        var h = 0;
        var i = 0;
        while (i < s.length) {
            h = (h * 31 + s.charCodeAt(i)) % 0x7FFFFFFF;
            i++;
        }
        return h;
    }

    function stringify(v:Int):String {
        return Std.string(v);
    }
}

class ServerSettings {
    static public function settingsPath(id:String):String {
        return "data/config/instances/settings-" + id + ".json";
    }
}
