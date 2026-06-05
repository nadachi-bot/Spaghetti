package server;

/**
 * Represents a mod entry for a server instance.
 */
class ModEntry {
    public var name:String;
    public var title:String;
    public var version:String;
    public var enabled:Bool;

    public function new() {
        this.name = "";
        this.title = "";
        this.version = "";
        this.enabled = true;
    }
}
