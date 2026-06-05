package server;

/**
 * Global configuration for the server manager.
 */
class Config {
    public var port:Int;
    public var factorioUsername:String;
    public var factorioToken:String;

    public function new() {
        this.port = 8080;
        this.factorioUsername = "";
        this.factorioToken = "";
    }

    static function configPath():String {
        return "data/config/manager.json";
    }

    static public function load():Config {
        var c:Config = new Config();
        if (sys.FileSystem.exists(configPath())) {
            var json:String = sys.io.File.getContent(configPath());
            var data:Dynamic = haxe.Json.parse(json);
            if (data.port != null) c.port = cast data.port;
            if (data.factorioUsername != null) c.factorioUsername = cast data.factorioUsername ?? "";
            if (data.factorioToken != null) c.factorioToken = cast data.factorioToken ?? "";
        }
        return c;
    }

    public function save():Void {
        var json:String = haxe.Json.stringify(this, "\t");
        sys.io.File.saveContent(configPath(), json);
    }
}
