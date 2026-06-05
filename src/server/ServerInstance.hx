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
    }

    static public function instancesDir():String {
        return "data/config/instances";
    }

    static public function list():Array<ServerInstance> {
        var result:Array<ServerInstance> = [];
        var dir = instancesDir();
        if (!sys.FileSystem.exists(dir)) return result;
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
                        instance.running = false; // always false on load; running state is live
                        instance.pid = -1;
                        result.push(instance);
                    } catch (e:Dynamic) {
                        // skip invalid files
                    }
                }
            }
        } catch (e:Dynamic) {
            haxe.Log.trace("Error reading instances directory: " + e);
        }
        return result;
    }

    public function filePath():String {
        return instancesDir() + "/" + (this.id != null ? this.id : "unknown") + ".json";
    }

    public function save():Void {
        var json = haxe.Json.stringify(this, "\t");
        sys.io.File.saveContent(filePath(), json);
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
