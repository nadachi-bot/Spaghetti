package web;

import js.Browser;

class Api {
    /* -----------------------------------------------------------------
       Low-level fetch wrapper
       ----------------------------------------------------------------- */
    static function request(
        method:String,
        path:String,
        ?body:Dynamic,
        ?onSuccess:Dynamic->Void,
        ?onError:String->Void
    ):Void {
        var opts:Dynamic = {
            method: method,
            credentials: "same-origin"
        };

        if (body != null) {
            opts.body = haxe.Json.stringify(body);
            opts.headers = { "Content-Type": "application/json" };
        }

        Browser.window.fetch(path, cast opts).then(
            (response:Dynamic) -> {
                if (response.status >= 400) {
                    untyped response.text().then(
                        (txt:String) -> { if (onError != null) onError("HTTP " + response.status + ": " + txt); },
                        (_)         -> { if (onError != null) onError("HTTP " + response.status); }
                    );
                } else if (response.status == 204) {
                    // No Content - call success with null immediately
                    if (onSuccess != null) onSuccess(null);
                } else {
                    untyped response.json().then(
                        (data:Dynamic) -> { if (onSuccess != null) onSuccess(data); },
                        (_) -> {
                            // Not JSON - try text
                            untyped response.text().then(
                                (txt:String) -> { if (onSuccess != null) onSuccess(txt); },
                                (_) -> { if (onError != null) onError("Failed to parse response"); }
                            );
                        }
                    );
                }
            },
            (err:Dynamic) -> { if (onError != null) onError("Network error"); }
        );
    }

    /* -----------------------------------------------------------------
       Servers
       ----------------------------------------------------------------- */

    static public function listServers(
        onSuccess:Array<Dynamic>->Void, ?onError:String->Void
    ):Void {
        request("GET", "/api/servers", null, onSuccess, onError);
    }

    static public function createServer(
        name:String, ?saveFile:String, ?onSuccess:Dynamic->Void, ?onError:String->Void
    ):Void {
        request("POST", "/api/servers", { name: name, saveFile: saveFile != null ? saveFile : "" }, onSuccess, onError);
    }

    static public function deleteServer(
        id:String, ?onSuccess:Void->Void, ?onError:String->Void
    ):Void {
        request("DELETE", "/api/servers/" + id, null, (d) -> { if (onSuccess != null) onSuccess(); }, onError);
    }

    static public function startServer(
        id:String, ?onSuccess:Dynamic->Void, ?onError:String->Void, ?onPolling:Void->Void
    ):Void {
        Browser.window.fetch("/api/servers/" + id + "/start", cast {
            method: "POST",
            credentials: "same-origin"
        }).then(
            (response:Dynamic) -> {
                if (response.status >= 400) {
                    untyped response.text().then(
                        (txt:String) -> { if (onError != null) onError("HTTP " + response.status + ": " + txt); },
                        (_)         -> { if (onError != null) onError("HTTP " + response.status); }
                    );
                } else if (response.status == 202) {
                    if (onPolling != null) onPolling();
                    _pollUntilRunning(id, onSuccess, onError, onPolling);
                } else {
                    if (onSuccess != null) onSuccess(null);
                }
            },
            (err:Dynamic) -> { if (onError != null) onError("Network error"); }
        );
    }

    static public function stopServer(
        id:String, ?onSuccess:Dynamic->Void, ?onError:String->Void, ?onPolling:Void->Void
    ):Void {
        Browser.window.fetch("/api/servers/" + id + "/stop", cast {
            method: "POST",
            credentials: "same-origin"
        }).then(
            (response:Dynamic) -> {
                if (response.status >= 400) {
                    untyped response.text().then(
                        (txt:String) -> { if (onError != null) onError("HTTP " + response.status + ": " + txt); },
                        (_)         -> { if (onError != null) onError("HTTP " + response.status); }
                    );
                } else if (response.status == 202) {
                    if (onPolling != null) onPolling();
                    _pollUntilStopped(id, onSuccess, onError, onPolling);
                } else {
                    if (onSuccess != null) onSuccess(null);
                }
            },
            (err:Dynamic) -> { if (onError != null) onError("Network error"); }
        );
    }

    static function _pollUntilRunning(
        id:String, onSuccess:Dynamic->Void, onError:String->Void, ?onPolling:Void->Void
    ):Void {
        Browser.window.fetch("/api/servers", cast { credentials: "same-origin" }).then(
            (response:Dynamic) -> {
                untyped response.json().then(
                    (data:Dynamic) -> {
                        var servers:Array<Dynamic> = cast data;
                        for (srv in servers) {
                            if (srv.id == id && srv.running) {
                                if (onSuccess != null) onSuccess(null);
                                return;
                            }
                        }
                        if (onPolling != null) onPolling();
                        Browser.window.setTimeout(() -> _pollUntilRunning(id, onSuccess, onError, onPolling), 1500);
                    },
                    (_) -> { if (onError != null) onError("Failed to parse server list"); }
                );
            },
            (err:Dynamic) -> { if (onError != null) onError("Network error"); }
        );
    }

    static function _pollUntilStopped(
        id:String, onSuccess:Dynamic->Void, onError:String->Void, ?onPolling:Void->Void
    ):Void {
        Browser.window.fetch("/api/servers", cast { credentials: "same-origin" }).then(
            (response:Dynamic) -> {
                untyped response.json().then(
                    (data:Dynamic) -> {
                        var servers:Array<Dynamic> = cast data;
                        for (srv in servers) {
                            if (srv.id == id && !srv.running) {
                                if (onSuccess != null) onSuccess(null);
                                return;
                            }
                        }
                        if (onPolling != null) onPolling();
                        Browser.window.setTimeout(() -> _pollUntilStopped(id, onSuccess, onError, onPolling), 1500);
                    },
                    (_) -> { if (onError != null) onError("Failed to parse server list"); }
                );
            },
            (err:Dynamic) -> { if (onError != null) onError("Network error"); }
        );
    }

    static public function getServerConfig(
        id:String, ?onSuccess:Dynamic->Void, ?onError:String->Void
    ):Void {
        request("GET", "/api/servers/" + id + "/config", null, onSuccess, onError);
    }

    static public function updateServerConfig(
        id:String, config:Dynamic, ?onSuccess:Dynamic->Void, ?onError:String->Void
    ):Void {
        request("PUT", "/api/servers/" + id + "/config", config, onSuccess, onError);
    }

    static public function getLogs(
        id:String, ?lines:Int, ?onSuccess:Dynamic->Void, ?onError:String->Void
    ):Void {
        Browser.window.fetch("/api/servers/" + id + "/logs", cast {
            method: "GET",
            credentials: "same-origin",
            headers: if (lines != null) { "x-lines": lines } else {}
        }).then(
            (response:Dynamic) -> {
                untyped response.json().then(
                    (data:Dynamic) -> { if (onSuccess != null) onSuccess(data); },
                    (_) -> { if (onError != null) onError("Parse error"); }
                );
            },
            (err:Dynamic) -> { if (onError != null) onError("Network error"); }
        );
    }

    static public function sendConsole(
        id:String, command:String, ?onSuccess:Dynamic->Void, ?onError:String->Void
    ):Void {
        request("POST", "/api/servers/" + id + "/console", { command: command }, onSuccess, onError);
    }

    /* -----------------------------------------------------------------
       Settings
       ----------------------------------------------------------------- */

    static public function getSettings(
        ?onSuccess:Dynamic->Void, ?onError:String->Void
    ):Void {
        request("GET", "/api/settings", null, onSuccess, onError);
    }

    static public function updateSettings(
        settings:Dynamic, ?onSuccess:Dynamic->Void, ?onError:String->Void
    ):Void {
        request("PUT", "/api/settings", settings, onSuccess, onError);
    }

    /* -----------------------------------------------------------------
       Versions
       ----------------------------------------------------------------- */

    static public function getVersions(
        ?onSuccess:Dynamic->Void, ?onError:String->Void
    ):Void {
        request("GET", "/api/versions", null, onSuccess, onError);
    }

    /* -----------------------------------------------------------------
       Mods
       ----------------------------------------------------------------- */

    static public function searchMods(
        query:String, ?onSuccess:Dynamic->Void, ?onError:String->Void
    ):Void {
        request("GET", "/api/mods/search?q=" + query, null, onSuccess, onError);
    }

    static public function getModDetails(
        name:String, ?onSuccess:Dynamic->Void, ?onError:String->Void
    ):Void {
        request("GET", "/api/mods/" + name, null, onSuccess, onError);
    }

    static public function toggleMod(
        id:String, modName:String, ?onSuccess:Dynamic->Void, ?onError:String->Void
    ):Void {
        request("PUT", "/api/servers/" + id + "/mods/toggle", { name: modName }, onSuccess, onError);
    }

    static public function addMod(
        id:String, name:String, ?title:String, ?version:String, ?onSuccess:Dynamic->Void, ?onError:String->Void
    ):Void {
        request("POST", "/api/servers/" + id + "/mods/add", {
            name: name,
            title: title != null ? title : name,
            version: version != null ? version : ""
        }, onSuccess, onError);
    }

    static public function removeMod(
        id:String, modName:String, ?onSuccess:Dynamic->Void, ?onError:String->Void
    ):Void {
        request("DELETE", "/api/servers/" + id + "/mods/remove", { name: modName }, onSuccess, onError);
    }

    /* -----------------------------------------------------------------
       Save file upload
       ----------------------------------------------------------------- */

    static public function uploadSaveFile(
        id:String, file:js.html.File, ?onSuccess:Dynamic->Void, ?onError:String->Void
    ):Void {
        var reader = new js.html.FileReader();
        untyped reader.onload = (e:Dynamic) -> {
            var result:String = cast reader.result;
            // Strip data URI prefix (e.g. "data:application/zip;base64,")
            var commaIdx = result.indexOf(",");
            var base64Data = if (commaIdx >= 0) result.substring(commaIdx + 1) else result;

            Browser.window.fetch("/api/servers/" + id + "/upload-save", cast {
                method: "POST",
                credentials: "same-origin",
                headers: { "Content-Type": "application/json" },
                body: haxe.Json.stringify({ fileName: file.name, fileData: base64Data })
            }).then(
                (response:Dynamic) -> {
                    if (response.status >= 400) {
                        untyped response.text().then(
                            (txt:String) -> { if (onError != null) onError("HTTP " + response.status + ": " + txt); },
                            (_)         -> { if (onError != null) onError("HTTP " + response.status); }
                        );
                    } else {
                        untyped response.json().then(
                            (data:Dynamic) -> { if (onSuccess != null) onSuccess(data); },
                            (_) -> { if (onError != null) onError("Failed to parse response"); }
                        );
                    }
                },
                (err:Dynamic) -> { if (onError != null) onError("Network error"); }
            );
        };
        untyped reader.onerror = (e:Dynamic) -> { if (onError != null) onError("Failed to read file"); };
        reader.readAsDataURL(file);
    }
}
