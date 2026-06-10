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
     * Called at startup with ServerInstance registry already loaded.
     * Clears any stale in-memory state from a previous run and kills
     * orphaned Factorio processes that survived a manager crash.
     */
    public function loadInstances():Void {
        // No-op: registry is populated by ServerInstance.loadRegistry().
        // Any running Factorio processes from a prior manager session are lost on restart,
        // so all state flags (starting/stopping/startFailed) start fresh.

        // Kill any orphaned Factorio processes from a previous manager session
        killOrphanedFactorioProcesses();
    }

    /**
     * Find and kill any orphaned Factorio processes under data/server/ that survived
     * a manager crash or unclean shutdown.
     */
    function killOrphanedFactorioProcesses():Void {
        try {
            var proc = new sys.io.Process("sh", ["-c", "ps -eo pid,comm --no-headers 2>/dev/null | grep factorio"]);
            var buf = haxe.io.Bytes.alloc(4096);
            var allContent = new StringBuf();
            try {
                while (true) {
                    var len = proc.stdout.readBytes(buf, 0, buf.length);
                    if (len == 0) break;
                    allContent.add(buf.sub(0, len).toString());
                }
            } catch (e:haxe.io.Eof) {
                // EOF reached normally
            } catch (e:Dynamic) {
                try { proc.exitCode(); } catch (e2:Dynamic) {}
                proc.close();
                return;
            }
            try { proc.exitCode(); } catch (e:Dynamic) {}
            proc.close();

            var lines:Array<String> = allContent.toString().split("\n");
            for (line in lines) {
                var parts:Array<String> = line.split(" ");
                if (parts.length < 2) continue;
                var pid = Std.parseInt(parts[0]);
                if (pid <= 0) continue;

                // Check if this process is under our data/server/ directory
                var cmdlineLink = "/proc/" + pid + "/cmdline";
                if (!sys.FileSystem.exists(cmdlineLink)) continue;
                try {
                    var cmdline = sys.io.File.getContent(cmdlineLink);
                    // Replace null bytes with spaces for splitting
                    cmdline = StringTools.replace(cmdline, "\x00", " ");
                    if (StringTools.contains(cmdline, "data/server/")) {
                        haxe.Log.trace("Killing orphaned Factorio process " + pid);
                        Sys.command("kill", [Std.string(pid)]);
                    }
                } catch (e:Dynamic) {
                    // Process already gone or permission denied
                }
            }
        } catch (e:Dynamic) {
            haxe.Log.trace("Error during orphan cleanup: " + e);
        }
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

        // Sync mods (generates mods-list.json in modsDir)
        this.factorioManager.syncMods(instance);

        // Read the mods-list.json generated by Factorio --sync-mods and update
        // the instance's mod list. This is more reliable than extracting from
        // the save binary, as it reflects exactly what Factorio resolved.
        var modInfos = this.factorioManager.readModsListJson(instance.modsDir());
        if (modInfos.length > 0) {
            instance.mods = [];
            for (modInfo in modInfos) {
                var me = new ModEntry();
                me.name = modInfo.name;
                me.title = modInfo.title;
                me.version = modInfo.version;
                me.enabled = true;
                instance.mods.push(me);
            }
            instance.save();
            haxe.Log.trace("Loaded " + instance.mods.length + " mods from mods-list.json for " + instance.id);
        }

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

        // Start a background monitor thread to detect process exit via exitCode().
        // The loop is guarded by checkedRunning so _doStop can terminate this thread
        // by setting checkedRunning = false (after force-killing). Without this guard,
        // a stale monitor thread can loop forever calling exitCode() on an already-
        // reaped process, blocking indefinitely and making the HTTP server unresponsive.
        var _this = this;
        sys.thread.Thread.create(function() {
            while (info.checkedRunning) {
                Sys.sleep(2);
                try {
                    var code = proc.exitCode();
                    if (code != null) {
                        info.checkedRunning = false;
                    }
                } catch (e:haxe.io.Eof) {
                    // Process already reaped (another thread or force-kill consumed the exit status)
                    info.checkedRunning = false;
                } catch (e:Dynamic) {
                    // If we can't check, assume still running — loop will naturally
                    // terminate when checkedRunning is set to false by _doStop.
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
     *
     * IMPORTANT: On Hashlink, sys.io.Process.exitCode() BLOCKS until the
     * process exits. The monitor thread (created in _doStart) is responsible
     * for calling exitCode() and updating the checkedRunning flag. This
     * function must NOT call exitCode() directly — it only polls the flag.
     *
     * Shutdown sequence:
     *   1. /game.server_save()  — triggers a synchronous autosave
     *   2. /quit                — graceful shutdown (saves map, closes cleanly)
     *   3. 30s graceful window   — monitor thread detects exit via exitCode()
     *   4. SIGKILL fallback     — force kill + close streams to unblock monitor
     */
    function _doStop(id:String):Void {
        if (!processes.exists(id)) return;
        var info = processes.get(id);

        // Send save-then-quit sequence so Factorio flushes the game state
        // before shutting down. /quit triggers a clean shutdown (saves
        // the map, closes the server socket, and exits the process).
        if (isRunning(id)) {
            try {
                info.process.stdin.writeString("/game.server_save()\n");
                info.process.stdin.flush();
                Sys.sleep(2); // Give the save command time to complete
                info.process.stdin.writeString("/quit\n");
                info.process.stdin.flush();
                info.process.stdin.close();
            } catch (e:Dynamic) {
                haxe.Log.trace("Failed to send stop command for " + id + ": " + e);
            }
        }

        // Wait for the monitor thread to detect the process exit via exitCode()
        // and update checkedRunning to false. Do NOT call exitCode() here —
        // it blocks on Hashlink and would freeze this thread.
        var waited = 0;
        while (waited < 30) {
            if (!isRunning(id)) break;
            Sys.sleep(1);
            waited++;
        }

        // Force kill if still running after 30 seconds
        if (isRunning(id)) {
            haxe.Log.trace("Timeout waiting for " + id + " to exit, force killing");
            try {
                info.process.kill();
            } catch (e:Dynamic) {
                haxe.Log.trace("Force kill error for " + id + ": " + e);
            }

            // Close all process streams after kill. This helps interrupt a blocked
            // exitCode() call in the monitor thread, causing it to throw Eof and
            // exit quickly instead of waiting for the 2-second sleep cycle.
            try { info.process.stdin.close(); } catch (e:Dynamic) {}
            try { info.process.stdout.close(); } catch (e:Dynamic) {}
            try { info.process.stderr.close(); } catch (e:Dynamic) {}
            try { info.process.close(); } catch (e:Dynamic) {}

            // Give the monitor thread time to see the kill and update the flag
            // (without calling exitCode() ourselves, which would block/reap).
            var grace = 0;
            while (grace < 5 && isRunning(id)) {
                Sys.sleep(1);
                grace++;
            }

            // Mark as stopped regardless — the process can't be reaping cleanly
            // if we hit the force-kill path.
            info.checkedRunning = false;
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

        // Delete config files
        try {
            var configPath = "data/config/instances/" + id + ".json";
            if (sys.FileSystem.exists(configPath)) {
                sys.FileSystem.deleteFile(configPath);
            }
            // Also clean up the server settings file written by writeServerSettings()
            var settingsPath = ServerSettings.settingsPath(id);
            if (sys.FileSystem.exists(settingsPath)) {
                sys.FileSystem.deleteFile(settingsPath);
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
     * Get the full Factorio process log (factorio-current.log) for a server.
     * This log contains the complete Factorio runtime output including mod loading,
     * map loading, network state, warnings, and errors — unlike the --console-log
     * which only contains minimal open/close markers.
     * Uses `tail -n` via sys.io.Process to avoid blocking on actively-written
     * log files. Wrapped with `timeout 15` to guarantee the handler thread returns.
     */
    public function getProcessLogs(id:String, lines:Int = 100):Array<String> {
        var logPath = "";
        if (processes.exists(id)) {
            var instance = processes.get(id).instance;
            var versionDir = this.factorioManager.getVersionDir(instance.version);
            logPath = versionDir + "/factorio/factorio-current.log";
        } else {
            // Instance not currently tracked — try to find it from the registry
            var instances = ServerInstance.list();
            for (inst in instances) {
                if (inst.id == id) {
                    var versionDir = this.factorioManager.getVersionDir(inst.version);
                    logPath = versionDir + "/factorio/factorio-current.log";
                    break;
                }
            }
        }

        if (logPath == "" || !sys.FileSystem.exists(logPath)) {
            return [];
        }

        try {
            var extraLines = 20;
            var totalLines = lines + extraLines;
            var proc = new sys.io.Process("timeout", ["15", "tail", "-n", Std.string(totalLines), logPath]);

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

            try { proc.exitCode(); } catch (e:Dynamic) {}
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
     * Get recent log lines for a server.
     * Reads the --console-log file (minimal console-interaction events).
     * Uses `tail -n` via sys.io.Process to avoid blocking on actively-written
     * log files (sys.io.File.getContent and direct readLine can hang on Hashlink
     * and freeze the single-threaded HTTP server).
     * Wrapped with `timeout 15` to guarantee the handler thread always returns.
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
            // Wrap with `timeout 15` to prevent the handler thread from blocking
            // forever if tail hangs (e.g., file lock or pipe issue).
            var proc = new sys.io.Process("timeout", ["15", "tail", "-n", Std.string(totalLines), logPath]);

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

            // Reap the process before closing to avoid zombie accumulation.
            // On Hashlink, close() only closes streams — exitCode() reaps the process.
            try { proc.exitCode(); } catch (e:Dynamic) {}
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
