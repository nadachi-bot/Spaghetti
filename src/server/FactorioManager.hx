package server;

/**
 * Manages Factorio server versions, downloads, and mod synchronization.
 */
class FactorioManager {
    var managerConfig:Config;
    var cachedLatestVersion:String;
    var cachedVersionTime:Float;
    static var CACHE_TTL = 300.0; // Cache latest version for 5 minutes

    public function new(config:Config) {
        this.managerConfig = config;
        this.cachedLatestVersion = null;
        this.cachedVersionTime = 0;
    }

    /**
     * Get the path to the Factorio server headless binary for a given version.
     * Downloads the version if it doesn't exist locally.
     */
    public function getServerBinaryPath(version:String):String {
        if (version == "latest") {
            version = getLatestVersion();
        }

        var versionDir = "data/server/" + version;
        var binaryPath = versionDir + "/factorio/bin/x64/factorio";

        if (!sys.FileSystem.exists(binaryPath)) {
            downloadFactorioVersion(version, versionDir);
        }

        return binaryPath;
    }

    /**
     * Get the latest available Factorio version from the download server.
     * Caches the result for CACHE_TTL seconds to avoid repeated HTTP calls.
     */
    function getLatestVersion():String {
        // Return cached value if still valid
        if (this.cachedLatestVersion != null && (Sys.time() - this.cachedVersionTime) < FactorioManager.CACHE_TTL) {
            return this.cachedLatestVersion;
        }

        try {
            var url = "https://factorio.com/get-download/stable/headless/linux64";
            var proc = new sys.io.Process("curl", ["-sIL", url]);
            var result = proc.stdout.readAll().toString();
            try { proc.exitCode(); } catch (e:Dynamic) {}
            proc.close();

            // Parse redirect Location header
            var lines = result.split("\n");
            var redirectUrl = "";
            for (line in lines) {
                var trimmed = trim(line);
                if (StringTools.startsWith(trimmed, "Location:") || StringTools.startsWith(trimmed, "location:")) {
                    redirectUrl = trimmed.substring(trimmed.indexOf(":") + 1);
                    trimmed = trim(redirectUrl);
                    break;
                }
            }

            // Extract version from redirect URL like:
            // https://dl.factorio.com/releases/2.0.76_.../factorio-headless_linux_2.0.76.tar.xz
            if (redirectUrl != "") {
                var version = extractVersionFromUrl(redirectUrl);
                if (version != "") return version;
            }

            haxe.Log.trace("Failed to parse version from redirect URL: " + redirectUrl);
            return "latest-release";
        } catch (e:Dynamic) {
            haxe.Log.trace("Failed to fetch latest version: " + e);
            return "latest-release"; // fallback
        }
    }

    function extractVersionFromUrl(url:String):String {
        // Pattern: factorio-headless_linux_<version>.tar.xz or similar
        var tarIndex = url.indexOf("factorio-headless_linux_");
        if (tarIndex >= 0) {
            var afterPrefix = url.substring(tarIndex + "factorio-headless_linux_".length);
            var dotIndex = afterPrefix.indexOf(".tar");
            if (dotIndex > 0) {
                var version = afterPrefix.substring(0, dotIndex);
                return version;
            }
        }
        return "";
    }

    function trim(s:String):String {
        var start = 0;
        while (start < s.length && (s.charAt(start) == " " || s.charAt(start) == "\t")) start++;
        var end = s.length;
        while (end > start && (s.charAt(end - 1) == " " || s.charAt(end - 1) == "\t" || s.charAt(end - 1) == "\n" || s.charAt(end - 1) == "\r")) end--;
        return s.substring(start, end);
    }

    function getFallback(data:Dynamic, field:String, defaultVal:Dynamic):Dynamic {
        var val = Reflect.field(data, field);
        return val != null ? val : defaultVal;
    }

    function getFileSize(path:String):Int {
        try {
            var proc = new sys.io.Process("stat", ["-c%s", path]);
            var result = proc.stdout.readLine();
            try { proc.exitCode(); } catch (e:Dynamic) {}
            proc.close();
            var size = Std.parseInt(result);
            return size != null ? size : 0;
        } catch (e:Dynamic) {
            return 0;
        }
    }


    /**
     * List all installed Factorio versions.
     */
    public function listInstalledVersions():Array<String> {
        var result:Array<String> = [];
        if (!sys.FileSystem.exists("data/server")) return result;

        var entries = sys.FileSystem.readDirectory("data/server");
        for (entry in entries) {
            var fullPath = "data/server/" + entry;
            if (sys.FileSystem.isDirectory(fullPath)) {
                result.push(entry);
            }
        }
        return result;
    }

    /**
     * Download a specific Factorio server version.
     * Uses the get-download endpoint which redirects to the actual .tar.xz archive.
     */
    function downloadFactorioVersion(version:String, targetDir:String):Void {
        haxe.Log.trace("Downloading Factorio " + version);

        if (!sys.FileSystem.exists(targetDir)) {
            sys.FileSystem.createDirectory(targetDir);
        }

        var url = "https://factorio.com/get-download/" + version + "/headless/linux64/latest";

        try {
            var tempFile = "/tmp/factorio-" + version + ".tar.xz";
            downloadFile(url, tempFile);

            // Check if we actually got something (curl -L follows redirects)
            if (!sys.FileSystem.exists(tempFile) || getFileSize(tempFile) == 0) {
                throw "Download resulted in empty file";
            }

            // Extract .tar.xz
            var args = ["-xJf", tempFile, "-C", targetDir];
            var proc = new sys.io.Process("tar", args);
            try { proc.exitCode(); } catch (e:Dynamic) {}
            proc.close();

            // Make binaries executable
            makeExecutableRecursive(targetDir);

            // Cleanup
            try { sys.FileSystem.deleteFile(tempFile); } catch (e:Dynamic) {}
            haxe.Log.trace("Downloaded Factorio " + version);
        } catch (e:Dynamic) {
            haxe.Log.trace("Failed to download Factorio " + version + ": " + e);
            throw "Failed to download Factorio version " + version;
        }
    }

    function makeExecutableRecursive(path:String):Void {
        if (sys.FileSystem.isDirectory(path)) {
            var entries = sys.FileSystem.readDirectory(path);
            for (entry in entries) {
                var fullPath = path + "/" + entry;
                makeExecutableRecursive(fullPath);
            }
        } else {
            try {
                var chmodProc = new sys.io.Process("chmod", ["+x", path]);
                try { chmodProc.exitCode(); } catch (e:Dynamic) {}
                chmodProc.close();
            } catch (e:Dynamic) {}
        }
    }

    /**
     * Write mod portal credentials to Factorio's player-data.json so that
     * --sync-mods can authenticate with the mod portal.
     */
    function setModPortalCredentials(versionDir:String):Void {
        var username = this.managerConfig.factorioUsername ?? "";
        var token = this.managerConfig.factorioToken ?? "";
        if (username == "" || token == "") {
            haxe.Log.trace("Factorio credentials not configured — skipping player-data.json update");
            return;
        }

        var playerDataPath = versionDir + "/factorio/player-data.json";
        try {
            var existing = sys.io.File.getContent(playerDataPath);
            var data = haxe.Json.parse(existing);
            Reflect.setField(data, "service-username", username);
            Reflect.setField(data, "service-token", token);
            sys.io.File.saveContent(playerDataPath, haxe.Json.stringify(data, "\t"));
            haxe.Log.trace("Wrote mod portal credentials to " + playerDataPath);
        } catch (e:Dynamic) {
            // File may not exist yet — create it
            try {
                var data = {
                    "service-username": username,
                    "service-token": token
                };
                sys.io.File.saveContent(playerDataPath, haxe.Json.stringify(data, "\t"));
                haxe.Log.trace("Created " + playerDataPath + " with mod portal credentials");
            } catch (e2:Dynamic) {
                haxe.Log.trace("Failed to write player-data.json: " + e2);
            }
        }
    }

    /**
     * Sync mods for a server instance using Factorio's built-in --sync-mods flag.
     * Factorio downloads mods from the portal into the specified mod directory,
     * using credentials stored in player-data.json.
     * Wraps the binary call with `timeout 180` to prevent indefinite blocking.
     */
    public function syncMods(instance:ServerInstance):Void {
        if (instance.mods == null || instance.mods.length == 0) return;

        var modsDir = instance.modsDir();
        if (!sys.FileSystem.exists(modsDir)) {
            sys.FileSystem.createDirectory(modsDir);
        }

        // Resolve the Factorio binary path
        var binaryPath = getServerBinaryPath(instance.version);
        var versionDir = binaryPath.substring(0, binaryPath.lastIndexOf("/factorio/"));

        // Ensure mod portal credentials are written
        setModPortalCredentials(versionDir);

        // Build the save file path
        var savePath = instance.savesDir() + "/" + instance.saveFile;
        if (!sys.FileSystem.exists(savePath)) {
            haxe.Log.trace("Save file not found: " + savePath + " — cannot sync mods");
            return;
        }

        // Run factorio --sync-mods <save> --mod-directory <dir> --verbose
        var args = [
            "--sync-mods", savePath,
            "--mod-directory", modsDir,
            "--verbose"
        ];

        haxe.Log.trace("Syncing mods: " + binaryPath + " " + args.join(" "));

        try {
            // Wrap with `timeout 180` (3 min) to guarantee `readAll()` returns
            var proc = new sys.io.Process("timeout", ["180", binaryPath].concat(args));

            // Drain stdout and stderr (Factorio outputs download progress)
            var stdout = proc.stdout.readAll().toString();
            var stderr = proc.stderr.readAll().toString();
            var exitCode = proc.exitCode();
            proc.close();

            if (exitCode != null && exitCode == 124) {
                haxe.Log.trace("Mod sync timed out (180s) for instance " + instance.id);
            }

            var stdoutTrunc = if (stdout.length > 800) stdout.substring(0, 800) + "..." else stdout;
            var stderrTrunc = if (stderr.length > 800) stderr.substring(0, 800) + "..." else stderr;
            if (stdoutTrunc != "") haxe.Log.trace("sync-mods output: " + stdoutTrunc);
            if (stderrTrunc != "") haxe.Log.trace("sync-mods errors: " + stderrTrunc);

            // Clean up any mods that are in the directory but disabled in config
            removeDisabledMods(instance, modsDir);

            haxe.Log.trace("Mod sync complete for instance " + instance.id);
        } catch (e:Dynamic) {
            haxe.Log.trace("Mod sync failed for instance " + instance.id + ": " + e);
        }
    }

    /**
     * Remove mods from the mod directory that are disabled in the instance config.
     */
    function removeDisabledMods(instance:ServerInstance, modsDir:String):Void {
        var enabledNames:Array<String> = [];
        for (mod in instance.mods) {
            if (mod.enabled) {
                enabledNames.push(mod.name);
            }
        }

        var installed = sys.FileSystem.readDirectory(modsDir);
        for (modFile in installed) {
            if (!StringTools.endsWith(modFile, ".zip")) continue;
            var modName = modFile.substring(0, modFile.length - 4);
            var isFound = false;
            for (name in enabledNames) {
                if (name == modName) {
                    isFound = true;
                    break;
                }
            }
            if (!isFound) {
                haxe.Log.trace("Removing disabled mod: " + modFile);
                try { sys.FileSystem.deleteFile(modsDir + "/" + modFile); } catch (e:Dynamic) {}
            }
        }
    }

    /**
     * Search the Factorio mod portal.
     * Uses POST /api/search with JSON body containing query, username, and token.
     */
    public function searchMods(query:String):Array<Dynamic> {
        if (this.managerConfig.factorioToken == "" || this.managerConfig.factorioUsername == "") {
            return [];
        }

        try {
            var url = "https://mods.factorio.com/api/search";
            var body = haxe.Json.stringify({
                query: query,
                username: this.managerConfig.factorioUsername,
                token: this.managerConfig.factorioToken
            });

            var args = [
                "-sS", "-X", "POST", url,
                "-H", "Content-Type: application/json",
                "-d", body
            ];
            var proc = new sys.io.Process("curl", args);
            var result = proc.stdout.readLine();
            try { proc.exitCode(); } catch (e:Dynamic) {}
            proc.close();

            if (result == null || result == "") return [];
            var data = haxe.Json.parse(result);
            var rawMods = getFallback(data, "modList", getFallback(data, "mods", getFallback(data, "results", [])));
            return cast(rawMods, Array<Dynamic>);
        } catch (e:Dynamic) {
            haxe.Log.trace("Mod search failed: " + e);
            return [];
        }
    }

    /**
     * Get mod details from the portal.
     */
    public function getModDetails(modName:String):Dynamic {
        try {
            var url = "https://mods.factorio.com/api/mods/" + urlEncode(modName);
            var response = downloadTextWithCookies(url);
            return haxe.Json.parse(response);
        } catch (e:Dynamic) {
            haxe.Log.trace("Failed to get mod details: " + e);
            return null;
        }
    }

    /**
     * Extract mods from a save file and return their info.
     * Factorio level*.dat files are binary, so we use `strings` to extract mod names,
     * then query the mod portal API for version details.
     */
    public function extractModsFromSave(savePath:String):Array<ModInfo> {
        var result:Array<ModInfo> = [];
        var seenModNames:Array<String> = [];

        try {
            // Factorio saves are zip files; we need to read level*.dat inside
            // Saves may have nested structures (e.g., null2/level-init.dat)
            var tempDir = "/tmp/factorio-save-extract-" + Date.now().getTime();
            var mkdirProc = new sys.io.Process("mkdir", ["-p", tempDir]);
            try { mkdirProc.exitCode(); } catch (e:Dynamic) {}
            mkdirProc.close();

            // Wrap with `timeout 30` to guarantee `readAll()` returns
            var unzipProc = new sys.io.Process("timeout", ["30", "unzip", "-o", savePath, "-d", tempDir]);
            // Must drain ALL output or process will block / throw Eof
            unzipProc.stdout.readAll().toString();
            unzipProc.stderr.readAll().toString();
            try { unzipProc.exitCode(); } catch (e:Dynamic) {}
            unzipProc.close();

            // Recursively find level*.dat files
            var levelFiles = findLevelFiles(tempDir);

            for (levelFile in levelFiles) {
                var modEntries = extractModNamesFromBinary(levelFile);
                for (entry in modEntries) {
                    // entry format: "modname:version"
                    var colonIdx = entry.lastIndexOf(":");
                    if (colonIdx < 0) continue;
                    var modName = entry.substring(0, colonIdx);
                    var binaryVersion = entry.substring(colonIdx + 1);

                    if (!arrayContains(seenModNames, modName)) {
                        seenModNames.push(modName);
                        // Skip API calls here to avoid blocking the HTTP server.
                        // Title can be fetched later via /api/mods/:name endpoint.
                        result.push({
                            name: modName,
                            version: binaryVersion,
                            title: modName
                        });
                    }
                }
            }

            // Cleanup
            var rmProc = new sys.io.Process("rm", ["-rf", tempDir]);
            try { rmProc.exitCode(); } catch (e:Dynamic) {}
            rmProc.close();
        } catch (e:Dynamic) {
            haxe.Log.trace("Failed to extract mods from save: " + e);
        }

        return result;
    }

    /**
     * Extract mod names from a binary level data file using the `strings` command.
     * We look for mod-data file patterns like `nullius_2.0.0.json` or `alien-biomes.0.7.3.json`
     * which give us both mod name and version in one shot.
     */
    function extractModNamesFromBinary(levelFile:String):Array<String> {
        var modNames:Array<String> = [];
        var seen:Array<String> = [];

        try {
            // Wrap with `timeout 15` to guarantee `readAll()` returns
            var stringsProc = new sys.io.Process("timeout", ["15", "strings", levelFile]);
            var output = stringsProc.stdout.readAll().toString();
            try { stringsProc.exitCode(); } catch (e:Dynamic) {}
            stringsProc.close();

            var lines = output.split("\n");
            // Pattern: modname_version.json, modname_version.lua, modname.version.json
            // Example: nullius_1.7.0.json, boblogistics_0.17.0.lua, alien-biomes.0.7.3.json
            var modDataPattern = ~/^([a-zA-Z][a-zA-Z0-9_-]+)[_.](\d+\.\d+\.\d+)\.(json|lua)$/;

            for (line in lines) {
                if (line == "") continue;
                if (modDataPattern.match(line)) {
                    var modName = modDataPattern.matched(1);
                    var version = modDataPattern.matched(2);
                    if (!arrayContains(seen, modName)) {
                        seen.push(modName);
                        modNames.push(modName + ":" + version);
                    }
                }
            }
        } catch (e:Dynamic) {
            haxe.Log.trace("Failed to extract strings from " + levelFile + ": " + e);
        }

        return modNames;
    }

    function arrayContains<T>(arr:Array<T>, val:Dynamic):Bool {
        for (item in arr) {
            if (item == val) return true;
        }
        return false;
    }

    /**
     * Recursively find level*.dat files in a directory.
     */
    function findLevelFiles(dir:String):Array<String> {
        var result:Array<String> = [];
        if (!sys.FileSystem.exists(dir) || !sys.FileSystem.isDirectory(dir)) return result;

        var entries = sys.FileSystem.readDirectory(dir);
        for (entry in entries) {
            var fullPath = dir + "/" + entry;
            if (sys.FileSystem.isDirectory(fullPath)) {
                result = result.concat(findLevelFiles(fullPath));
            } else if (StringTools.endsWith(entry, ".dat")) {
                // Skip .datmetadata and .dat0, .dat1 - we want level.dat or level-init.dat
                if (entry == "level.dat" || StringTools.startsWith(entry, "level-")) {
                    result.push(fullPath);
                }
            }
        }
        return result;
    }

    /**
     * Download text content from a URL.
     */
    function downloadText(url:String):String {
        var proc = new sys.io.Process("curl", ["-sS", "-L", url]);
        var result = proc.stdout.readLine();
        try { proc.exitCode(); } catch (e:Dynamic) {}
        proc.close();
        return result ?? "";
    }

    /**
     * Download text content with cookies.
     */
    function downloadTextWithCookies(url:String):String {
        var proc = new sys.io.Process("curl", [
            "-sS", "-L", url,
            "-H", "Cookie: auth_token=" + this.managerConfig.factorioToken
        ]);
        var result = proc.stdout.readLine();
        try { proc.exitCode(); } catch (e:Dynamic) {}
        proc.close();
        return result ?? "";
    }

    /**
     * Download a file from a URL.
     * curl -o writes directly to the file, so there is no stdout to read.
     */
    function downloadFile(url:String, outputPath:String):Void {
        var proc = new sys.io.Process("curl", ["-sS", "-L", "-o", outputPath, url]);
        try { proc.exitCode(); } catch (e:Dynamic) {}
        proc.close();
    }

    /**
     * Download a file with custom headers (for mod portal auth).
     */
    function downloadFileWithCookies(url:String, outputPath:String, headers:Array<String>):Void {
        var args = ["-sS", "-L", "-o", outputPath];
        for (header in headers) {
            args.push("-H");
            args.push(header);
        }
        args.push(url);

        var proc = new sys.io.Process("curl", args);
        try { proc.exitCode(); } catch (e:Dynamic) {}
        proc.close();
    }

    function urlEncode(s:String):String {
        var result = new StringBuf();
        var i = 0;
        while (i < s.length) {
            var c = s.charCodeAt(i);
            if (c >= 48 && c <= 57) { // 0-9
                result.add(String.fromCharCode(c));
            } else if (c >= 65 && c <= 90) { // A-Z
                result.add(String.fromCharCode(c));
            } else if (c >= 97 && c <= 122) { // a-z
                result.add(String.fromCharCode(c));
            } else {
                result.add("%");
                result.add(toHex2(c));
            }
            i++;
        }
        return result.toString();
    }

    function toHex2(n:Int):String {
        var hexChars = "0123456789abcdef";
        var hi = (n >> 4) & 0xF;
        var lo = n & 0xF;
        return String.fromCharCode(hexChars.charCodeAt(hi)) + String.fromCharCode(hexChars.charCodeAt(lo));
    }
}

typedef ModInfo = {
    var name:String;
    var version:String;
    var title:String;
}
