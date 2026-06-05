package server;

/**
 * Manages running Factorio server processes (start, stop, logs, console).
 */
typedef ProcessInfo = {
    var process:sys.io.Process;
    var instance:ServerInstance;
    var logBuffer:StringBuf;
    var started:Bool;
    /** Cached running state — updated by background monitor so isRunning() is non-blocking */
    var checkedRunning:Bool;
}

class ServerProcessManager {
    var processes:Map<String, ProcessInfo>;
    var factorioManager:FactorioManager;
    var managerConfig:Config;
    var startingStates:Map<String, Bool>;
    var stoppingStates:Map<String, Bool>;
    var startFailedStates:Map<String, Bool>;
    var startFailMessages:Map<String, String>;

    public function new(factorio:FactorioManager, config:Config) {
        this.processes = new Map();
        this.factorioManager = factorio;
        this.managerConfig = config;
        this.startingStates = new Map();
        this.stoppingStates = new Map();
        this.startFailedStates = new Map();
        this.startFailMessages = new Map();
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
                startFailedStates.set(instance.id, false);
            } catch (e:Dynamic) {
                var msg = "Start failed: " + e;
                haxe.Log.trace(msg);
                startFailedStates.set(instance.id, true);
                startFailMessages.set(instance.id, Std.string(msg));
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

        // Compute a valid port (34197-35196) from the instance id
        var portBase = 34197;
        var portOffset = 0;
        var idChars = instance.id;
        var j = 0;
        while (j < idChars.length && portOffset < 10000) {
            portOffset += idChars.charCodeAt(j);
            j++;
        }
        var port = portBase + (portOffset % 1000);

        // Build command arguments
        var args = ["--server-settings", ServerSettings.settingsPath(instance.id)];

        // Set game settings
        this.writeServerSettings(instance);

        var logPath = instance.savesDir() + "/" + instance.id + ".log";
        args.push("--start-server");
        args.push(instance.savesDir() + "/" + instance.saveFile);
        args.push("--port");
        args.push(Std.string(port));
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
            started: true,
            checkedRunning: true
        };
        this.processes.set(instance.id, info);

        // Start a background monitor thread to avoid blocking HTTP thread with exitCode()
        var _this = this;
        sys.thread.Thread.create(function() {
            while (true) {
                Sys.sleep(2);
                try {
                    var code = proc.exitCode();
                    if (code != null) {
                        info.checkedRunning = false;
                        break; // Process exited, stop monitoring
                    }
                } catch (e:Dynamic) {
                    // If we can't check, assume still running
                }
            }
        });

        // Brief health check — wait up to 3s for the process to stay alive
        Sys.sleep(1);
        if (!info.checkedRunning) {
            throw "Factorio process exited immediately";
        }

        instance.running = true;
        instance.save();
    }

    /**
     * Internal: perform the actual stop work inside a background thread.
     */
    function _doStop(id:String):Void {
        if (!processes.exists(id)) return;
        var info = processes.get(id);

        // Send "exit" command if process is still alive
        if (isRunning(id)) {
            try {
                info.process.stdin.writeString("exit\n");
                info.process.stdin.flush();
            } catch (e:Dynamic) {
                haxe.Log.trace("Failed to write exit command for " + id + ": " + e);
            }
        }

        // Wait for process to exit (with timeout)
        var waited = 0;
        while (waited < 30) {
            if (!isRunning(id)) break;
            Sys.sleep(1);
            waited++;
        }

        // Force kill if still running
        if (isRunning(id)) {
            haxe.Log.trace("Force killing Factorio process " + id);
            try {
                info.process.kill();
                info.checkedRunning = false; // Force mark as stopped immediately
            } catch (e:Dynamic) {
                haxe.Log.trace("Force kill error for " + id + ": " + e);
                // Fallback: try closing streams
                try {
                    info.process.stdin.close();
                    info.process.stdout.close();
                    info.process.stderr.close();
                    info.process.close();
                    info.checkedRunning = false;
                } catch (e2:Dynamic) {
                    haxe.Log.trace("Stream close fallback error for " + id + ": " + e2);
                }
            }
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
     * Wait for a pending start operation to complete.
     * Blocks the caller for up to `timeout` seconds.
     * Returns true if the server is no longer starting, false on timeout.
     */
    public function waitForStart(id:String, timeout:Int = 30):Bool {
        var waited = 0;
        while (waited < timeout) {
            if (!isStarting(id)) return true;
            Sys.sleep(1);
            waited++;
        }
        return false;
    }

    /**
     * Check if a start operation failed for this instance.
     */
    public function hasStartFailed(id:String):Bool {
        return startFailedStates.exists(id) && startFailedStates.get(id);
    }

    /**
     * Get the failure message if a start operation failed.
     */
    public function getStartFailMessage(id:String):String {
        if (startFailMessages.exists(id)) {
            return startFailMessages.get(id);
        }
        return "Unknown start failure";
    }

    /**
     * Synchronous delete: stop the instance if running, wait for stop to finish,
     * then remove process entry and config file. Runs on the caller thread
     * (HTTP handler) so the delete is complete before the response is sent.
     */
    public function deleteInstance(id:String):Bool {
        // If currently starting, wait for the start thread to finish
        if (isStarting(id)) {
            if (!waitForStart(id)) {
                haxe.Log.trace("Delete timeout waiting for " + id + " to finish starting");
                // Clear state anyway so we can proceed with cleanup
                startingStates.set(id, false);
            }
        }

        // If already stopping (e.g., a prior /stop request), wait for it to finish
        if (isStopping(id)) {
            if (!waitForStop(id)) {
                haxe.Log.trace("Delete timeout waiting for " + id + " to finish stopping");
                return false;
            }
        }

        // Stop if still running (hasn't been stopped by a prior request)
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
        startFailedStates.remove(id);
        startFailMessages.remove(id);

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
     * Uses the cached checkedRunning flag updated by the background monitor thread
     * to avoid blocking the HTTP event loop with exitCode().
     */
    public function isRunning(id:String):Bool {
        if (!processes.exists(id)) return false;
        return processes.get(id).checkedRunning;
    }

    /**
     * Send a command to the server console.
     * Does not block on stdout — Factorio stdout is typically not useful
     * for console responses (logs go to the --console-log file instead).
     */
    public function sendConsoleCommand(id:String, command:String):Null<String> {
        if (!processes.exists(id)) return null;
        try {
            var info = processes.get(id);
            info.process.stdin.writeString(command + "\n");
            info.process.stdin.flush();
            return "Command sent: " + command;
        } catch (e:Dynamic) {
            return "Error: " + e;
        }
    }

    /**
     * Get recent log lines for a server.
     * Uses `tail -n` via sys.io.Process to avoid blocking on actively-written
     * log files (sys.io.File.getContent and direct readLine can hang on Hashlink
     * and freeze the single-threaded HTTP server).
     */
    public function getLogs(id:String, lines:Int = 100):Array<String> {
        var logPath = "";
        if (processes.exists(id)) {
            var instance = processes.get(id).instance;
            logPath = instance.savesDir() + "/" + id + ".log";
        }

        if (!sys.FileSystem.exists(logPath)) {
            return [];
        }

        try {
            var extraLines = 20;
            var totalLines = lines + extraLines;
            var proc = new sys.io.Process("tail", ["-n", Std.string(totalLines), logPath]);

            try {
                proc.stdin.close();
            } catch (e:Dynamic) {}

            var allContent = new StringBuf();
            var input = proc.stdout;

            try {
                var buf = haxe.io.Bytes.alloc(4096);
                while (true) {
                    var len = input.readBytes(buf, 0, buf.length);
                    if (len == 0) break;
                    allContent.add(buf.sub(0, len).toString());
                }
            } catch (e:haxe.io.Eof) {
                // EOF reached normally
            } catch (e:Dynamic) {
                // Read error
            }

            proc.close();

            var rawContent = allContent.toString();
            var rawLines = rawContent.split("\n");
            var tailLines = [];
            for (line in rawLines) {
                if (line != "") tailLines.push(line);
            }

            if (tailLines.length > lines) {
                return tailLines.slice(tailLines.length - lines);
            }
            return tailLines;
        } catch (e:Dynamic) {
            return [];
        }
    }

    /**
     * Get all running processes info.
     * Each instance includes live state flags (running, starting, stopping, startFailed)
     * computed from the backend process manager.
     */
    public function getAllProcesses():Array<ServerInstance> {
        var result:Array<ServerInstance> = [];
        var instances = ServerInstance.list();
        for (instance in instances) {
            instance.running = this.isRunning(instance.id);
            instance.starting = this.isStarting(instance.id);
            instance.stopping = this.isStopping(instance.id);
            instance.startFailed = this.hasStartFailed(instance.id);
            if (instance.startFailed) {
                instance.startFailMessage = this.getStartFailMessage(instance.id);
            }
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
}

class ServerSettings {
    static public function settingsPath(id:String):String {
        return "data/config/instances/settings-" + id + ".json";
    }
}
