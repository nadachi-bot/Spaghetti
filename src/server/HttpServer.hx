package server;

/**
 * Minimal HTTP server built on sys.net.Socket.
 * Handles routing, request parsing, and response generation.
 */

typedef HttpRoute = {
    var method:String;
    var path:EReg;
    var regexString:String;
    var params:Array<String>;
    var handler:(HttpServerRequest -> HttpServerResponse);
}

typedef HttpServerRequest = {
    var method:String;
    var path:String;
    var headers:Map<String, String>;
    var body:String;
    var params:Map<String, String>;
}

typedef HttpServerResponse = {
    var status:Int;
    var statusText:String;
    var headers:Map<String, String>;
    var body:String;
}

typedef Request = HttpServerRequest;
typedef Response = HttpServerResponse;

class HttpServer {
    var socket:sys.net.Socket;
    var routes:Array<HttpRoute>;

    function setReuseAddress(sock:sys.net.Socket):Void {
        #if python
        try {
            // On the Python target sys.net.Socket wraps a Python socket.socket
            // stored in the internal _hx___s field. Calling setsockopt with
            // SOL_SOCKET=1, SO_REUSEADDR=2, value=1 lets us rebind a port
            // immediately after the old process exits, avoiding TIME_WAIT.
            var handle = Reflect.field(sock, "_hx___s");
            Reflect.field(handle, "setsockopt")(1, 2, 1);
        } catch (e:Dynamic) {
            haxe.Log.trace("Warning: SO_REUSEADDR could not be set: " + e);
        }
        #else
        #end
    }

    public function new(port:Int) {
        this.socket = new sys.net.Socket();
        setReuseAddress(this.socket);
        this.socket.setBlocking(true);
        this.socket.bind(new sys.net.Host("0.0.0.0"), port);
        this.socket.listen(128);
        this.routes = [];
        haxe.Log.trace("HTTP server listening on port " + port);
    }

    public function get(path:String, handler:Request -> Response):Void {
        addRoute("GET", path, handler);
    }

    public function post(path:String, handler:Request -> Response):Void {
        addRoute("POST", path, handler);
    }

    public function put(path:String, handler:Request -> Response):Void {
        addRoute("PUT", path, handler);
    }

    public function delete(path:String, handler:Request -> Response):Void {
        addRoute("DELETE", path, handler);
    }

    function addRoute(method:String, pathTemplate:String, handler:Request -> Response):Void {
        // Convert :param to regex captures
        var params:Array<String> = [];
        var parts = pathTemplate.split(":");
        for (i in 1...parts.length) {
            var part = parts[i];
            var paramEnd = part.indexOf("/");
            if (paramEnd >= 0) {
                var paramName = part.substring(0, paramEnd);
                params.push(paramName);
                parts[i] = "([^/]+)" + part.substring(paramEnd);
            } else {
                params.push(part);
                parts[i] = "([^/]+)";
            }
        }
        // Join with empty string since the : has already been consumed by split
        var regexStr = parts.join("");
        regexStr = "^" + regexStr + "$";

        this.routes.push({
            method: method,
            path: new EReg(regexStr, ""),
            regexString: regexStr,
            params: params,
            handler: handler
        });
    }

    public function start():Void {
        haxe.Log.trace("Starting HTTP server event loop...");
        while (true) {
            try {
                var client = this.socket.accept();
                // Handle each client in its own thread so a slow handler
                // (e.g., getLogs reading an actively-written log file)
                // doesn't block the accept loop and freeze the entire server.
                sys.thread.Thread.create(function() {
                    try {
                        this.handleClient(client);
                    } catch (e:Dynamic) {
                        haxe.Log.trace("Error handling client in thread: " + e);
                    }
                });
            } catch (e:Dynamic) {
                haxe.Log.trace("Error accepting connection: " + e);
            }
        }
    }

    function handleClient(client:sys.net.Socket):Void {
        var clientClosed = false;
        try {
            var parsed = readAndParseRequest(client);
            if (parsed == null) {
                client.close();
                clientClosed = true;
                return;
            }
            var response = routeRequest(parsed);
            sendResponse(client, response);
        } catch (e:Dynamic) {
            haxe.Log.trace("Error handling client: " + e);
        }
        if (!clientClosed) {
            try { client.close(); } catch (e:Dynamic) {}
        }
    }

    function readAndParseRequest(client:sys.net.Socket):Null<Request> {
        var headerLines:Array<String> = [];
        var contentLength = 0;

        while (true) {
            try {
                var chunk = client.input.readLine();
                if (chunk == null) break;

                if (headerLines.length == 0) {
                    // First line is the request line (METHOD PATH HTTP/x.x)
                    var parts = chunk.split(" ");
                    if (parts.length < 2) return null;
                    headerLines.push(chunk);
                } else if (chunk == "") {
                    // Empty line = end of headers, read body next
                    for (i in 1...headerLines.length) {
                        var lowerLine = headerLines[i].toLowerCase();
                        if (lowerLine.substr(0, 15) == "content-length:") {
                            var valPart = headerLines[i].split(":")[1];
                            var start = 0;
                            while (start < valPart.length && valPart.charAt(start) == " ") start++;
                            contentLength = Std.parseInt(valPart.substr(start));
                        }
                    }

                    var body = "";
                    if (contentLength > 0) {
                        // Read body in chunks to avoid issues with large payloads
                        // on the Python target where readString(n) may hang.
                        var remaining = contentLength;
                        var sb = new StringBuf();
                        while (remaining > 0) {
                            var chunkSize = remaining;
                            if (chunkSize > 8192) chunkSize = 8192;
                            var chunk = client.input.readString(chunkSize);
                            if (chunk == "" || chunk == null) break;
                            sb.add(chunk);
                            remaining -= chunk.length;
                        }
                        body = sb.toString();
                    }

                    // Parse request line
                    var requestParts = headerLines[0].split(" ");
                    // Strip query string from path (e.g., "/api/servers?id=1" -> "/api/servers")
                    var fullPath = requestParts[1];
                    var path = fullPath;
                    var params:Map<String, String> = new Map();
                    var qIdx = fullPath.indexOf("?");
                    if (qIdx >= 0) {
                        path = fullPath.substring(0, qIdx);
                        // Parse query string into params so handlers can read them
                        var queryStr = fullPath.substring(qIdx + 1);
                        var pairs = queryStr.split("&");
                        for (pair in pairs) {
                            var eqIdx = pair.indexOf("=");
                            if (eqIdx >= 0) {
                                var k = StringTools.urlDecode(pair.substring(0, eqIdx));
                                var v = StringTools.urlDecode(pair.substring(eqIdx + 1));
                                params.set(k, v);
                            } else {
                                params.set(StringTools.urlDecode(pair), "");
                            }
                        }
                    }
                    var headers:Map<String, String> = new Map();
                    for (i in 1...headerLines.length) {
                        var line = headerLines[i];
                        var colonIdx = line.indexOf(":");
                        if (colonIdx > 0) {
                            var key = line.substring(0, colonIdx).toLowerCase();
                            var rawVal = line.substring(colonIdx + 1);
                            // Strip \r if present (CRLF line endings)
                            var crIdx = rawVal.indexOf("\r");
                            if (crIdx >= 0) rawVal = rawVal.substring(0, crIdx);
                            var start = 0;
                            while (start < rawVal.length && (rawVal.charAt(start) == " " || rawVal.charAt(start) == "\t")) start++;
                            var end = rawVal.length;
                            while (end > start && (rawVal.charAt(end - 1) == " " || rawVal.charAt(end - 1) == "\t")) end--;
                            headers.set(key, rawVal.substring(start, end));
                        }
                    }

                    return {
                        method: requestParts[0],
                        path: path,
                        headers: headers,
                        body: body,
                        params: params
                    };
                } else {
                    headerLines.push(chunk);
                }
            } catch (e:Dynamic) {
                break;
            }
        }

        return null; // Connection closed or error
    }

    function routeRequest(req:Request):Response {
        for (route in routes) {
            if (req.method != route.method) continue;

            // Create a fresh EReg per request to avoid stale matched() state on Hashlink
            var re = new EReg(route.regexString, "");
            if (re.match(req.path)) {
                for (i in 0...route.params.length) {
                    req.params.set(route.params[i], re.matched(i + 1));
                }
                return route.handler(req);
            }
        }

        return {
            status: 404,
            statusText: "Not Found",
            headers: new Map(),
            body: "{\"error\":\"Not Found\"}"
        };
    }

    static var statusTexts:Map<Int, String> = null;

    function getStatusText(code:Int):String {
        if (statusTexts == null) {
            statusTexts = new Map();
            statusTexts.set(200, "OK");
            statusTexts.set(201, "Created");
            statusTexts.set(204, "No Content");
            statusTexts.set(301, "Moved Permanently");
            statusTexts.set(302, "Found");
            statusTexts.set(304, "Not Modified");
            statusTexts.set(400, "Bad Request");
            statusTexts.set(401, "Unauthorized");
            statusTexts.set(403, "Forbidden");
            statusTexts.set(404, "Not Found");
            statusTexts.set(405, "Method Not Allowed");
            statusTexts.set(500, "Internal Server Error");
        }
        return statusTexts.get(code) ?? "Unknown";
    }

    function sendResponse(socket:sys.net.Socket, resp:Response):Void {
        var statusText = getStatusText(resp.status);
        var out = socket.output;

        try {
            // Write status line
            out.writeString("HTTP/1.1 " + resp.status + " " + statusText + "\r\n");

            // Write headers
            for (key in resp.headers.keys()) {
                out.writeString(key + ": " + resp.headers.get(key) + "\r\n");
            }

            if (!resp.headers.exists("Content-Type")) {
                out.writeString("Content-Type: application/json\r\n");
            }

            // Calculate actual byte length for Content-Length
            var bodyBytes = haxe.io.Bytes.ofString(resp.body);
            out.writeString("Content-Length: " + bodyBytes.length + "\r\n");
            out.writeString("Connection: close\r\n");
            out.writeString("\r\n");

            // Write body separately to avoid large string concatenation
            out.writeBytes(bodyBytes, 0, bodyBytes.length);
            out.flush();
        } catch (e:Dynamic) {
            // Client may have disconnected
        }
    }

    public function json(data:Dynamic):Response {
        var headers:Map<String, String> = new Map();
        headers.set("Content-Type", "application/json");
        return {
            status: 200,
            statusText: "OK",
            headers: headers,
            body: haxe.Json.stringify(data)
        };
    }

    public function jsonStatus(code:Int, data:Dynamic):Response {
        var headers:Map<String, String> = new Map();
        headers.set("Content-Type", "application/json");
        return {
            status: code,
            statusText: getStatusText(code),
            headers: headers,
            body: haxe.Json.stringify(data)
        };
    }

    /** Return a JSON response from a pre-serialized string. */
    public function jsonStr(body:String):Response {
        var headers:Map<String, String> = new Map();
        headers.set("Content-Type", "application/json");
        return {
            status: 200,
            statusText: "OK",
            headers: headers,
            body: body
        };
    }

    public function text(contentType:String, body:String):Response {
        var headers:Map<String, String> = new Map();
        headers.set("Content-Type", contentType);
        return {
            status: 200,
            statusText: "OK",
            headers: headers,
            body: body
        };
    }

    public function html(body:String):Response {
        return text("text/html; charset=utf-8", body);
    }

    public function noContent():Response {
        return {
            status: 204,
            statusText: "No Content",
            headers: new Map(),
            body: ""
        };
    }

    public function serveFile(filePath:String, contentType:String):Null<Response> {
        if (!sys.FileSystem.exists(filePath)) {
            return null;
        }
        var content = sys.io.File.getContent(filePath);
        return text(contentType, content);
    }

}
