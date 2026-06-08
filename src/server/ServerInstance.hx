package server;

/**
 * Configuration for an individual Factorio server instance.
 */
class ServerInstance {
    public var id:String;
    public var name:String;
    public var password:String;
    public var admins:Array<String>;
    public var autosaveInterval:Int;
    public var autosaveSlots:Int;
    public var maxPlayers:Int;
    public var version:String; // "latest" or specific version string
    public var saveFile:String; // filename of the save
    public var mods:Array<ModEntry>;
    public var running:Bool;
    public var pid:Int;

    // Transient state flags — only set by ServerProcessManager, not persisted
    public var starting:Bool;
    public var stopping:Bool;
    public var startFailed:Bool;
    public var startFailMessage:String;

    public function new() {
        this.id = "";
        this.name = "";
        this.password = "";
        this.admins = [];
        this.autosaveInterval = 5;
        this.autosaveSlots = 5;
        this.maxPlayers = 16;
        this.version = "latest";
        this.saveFile = "";
        this.mods = [];
        this.running = false;
        this.pid = -1;
        this.starting = false;
        this.stopping = false;
        this.startFailed = false;
        this.startFailMessage = "";
    }

    static public function instancesDir():String {
        return "data/config/instances";
    }

    public function filePath():String {
        return instancesDir() + "/" + (this.id != null ? this.id : "unknown") + ".json";
    }

    public function save():Void {
        var json = haxe.Json.stringify(this, "\t");
        // Atomic write: write to a temp file then rename.
        // On POSIX, rename is atomic, so readers (list()) will
        // see either the old content or the new content, never partial.
        var tmpPath = filePath() + ".tmp";
        sys.io.File.saveContent(tmpPath, json);
        sys.FileSystem.rename(tmpPath, filePath());
    }

    public function modsDir():String {
        return "data/server/mods/" + (this.id != null ? this.id : "unknown");
    }

    public function savesDir():String {
        return "data/saves/" + (this.id != null ? this.id : "unknown");
    }

    static function safeStr(v:Dynamic, defaultVal:String):String {
        if (v == null) return defaultVal;
        return cast(v, String) ?? defaultVal;
    }

    static function safeInt(v:Dynamic, defaultVal:Int):Int {
        if (v == null) return defaultVal;
        return cast(v, Int);
    }

    static function safeArr(v:Dynamic):Array<String> {
        if (v == null) return [];
        var rawArr = cast(v, Array<Dynamic>);
        if (rawArr == null) return [];
        var result:Array<String> = [];
        for (item in rawArr) {
            if (item != null) result.push(Std.string(item));
        }
        return result;
    }

    /**
     * In-memory registry of all instances, protected by a mutex.
     * This avoids race conditions when concurrent HTTP handlers create or
     * enumerate instances while another handler is mid-write to disk.
     */
    static var registry:Map<String, ServerInstance> = null;
    static var mutex:sys.thread.Mutex = new sys.thread.Mutex();

    static function _withMutex(f:Void->Void):Void {
        mutex.acquire();
        try {
            f();
        } catch (e:Dynamic) {
            mutex.release();
            throw e;
        }
        mutex.release();
    }

    /** Load all instances from disk into the in-memory registry (call once at startup). */
    static public function loadRegistry():Void {
        _withMutex(_doLoadRegistry);
    }

    static function _doLoadRegistry():Void {
        registry = new Map();
        var dir = instancesDir();
        if (!sys.FileSystem.exists(dir)) return;
        try {
            var entries = sys.FileSystem.readDirectory(dir);
            for (entry in entries) {
                if (StringTools.endsWith(entry, ".json")) {
                    try {
                        var json = sys.io.File.getContent(dir + "/" + entry);
                        var data = haxe.Json.parse(json);
                        var instance = new ServerInstance();
                        instance.id = safeStr(data.id, "");
                        instance.name = safeStr(data.name, "");
                        instance.password = safeStr(data.password, "");
                        instance.admins = safeArr(data.admins);
                        instance.autosaveInterval = safeInt(data.autosaveInterval, 5);
                        instance.autosaveSlots = safeInt(data.autosaveSlots, 5);
                        instance.maxPlayers = safeInt(data.maxPlayers, 16);
                        instance.version = safeStr(data.version, "latest");
                        instance.saveFile = safeStr(data.saveFile, "");
                        instance.mods = parseMods(data.mods);
                        instance.running = false;
                        instance.pid = -1;
                        registry.set(instance.id, instance);
                    } catch (e:Dynamic) {
                        // skip invalid files
                    }
                }
            }
        } catch (e:Dynamic) {
            haxe.Log.trace("Error reading instances directory: " + e);
        }
    }

    /** Return the list of instances from the in-memory registry (thread-safe). */
    static public function list():Array<ServerInstance> {
        var result:Array<ServerInstance> = null;
        _withMutex(function() {
            if (registry == null) {
                result = [];
                return;
            }
            result = [];
            for (k in registry.keys()) {
                result.push(registry.get(k));
            }
        });
        return result;
    }

    /**
     * Register a newly-created instance in the in-memory registry.
     * Called by apiCreateServer so concurrent GET requests see the instance immediately.
     */
    static public function registerInstance(instance:ServerInstance):Void {
        _withMutex(function() {
            if (registry != null) registry.set(instance.id, instance);
        });
    }

    /**
     * Atomically save to disk AND register in the in-memory registry.
     * Prevents race conditions where a concurrent list() call sees the
     * file on disk but not in the registry (or vice versa).
     */
    static public function saveAndRegister(instance:ServerInstance):Void {
        _withMutex(function() {
            instance.save();
            if (registry != null) registry.set(instance.id, instance);
        });
    }

    /**
     * Remove an instance from the in-memory registry.
     * Called by apiDeleteServer so subsequent GET requests no longer see it.
     */
    static public function unregisterInstance(id:String):Void {
        _withMutex(function() {
            if (registry != null) registry.remove(id);
        });
    }

    static public function parseMods(rawMods:Dynamic):Array<ModEntry> {
        if (rawMods == null) return [];
        try {
            var modArr = cast(rawMods, Array<Dynamic>);
            if (modArr == null) return [];
            var result:Array<ModEntry> = [];
            for (raw in modArr) {
                var mod = new ModEntry();
                mod.name = safeStr(raw.name, "");
                mod.title = safeStr(raw.title, mod.name);
                mod.version = safeStr(raw.version, "");
                var en = raw.enabled;
                mod.enabled = (en == true); // default true, only false if explicitly false
                if (mod.name != "") {
                    result.push(mod);
                }
            }
            return result;
        } catch (e:Dynamic) {
            return [];
        }
    }
}
