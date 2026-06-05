package web.test;

import web.test.TestRunner;
import web.test.Expectation;
import js.Browser;

class ApiTests {
    static var runner : TestRunner;
    static var originalFetch : Dynamic;
    static var mockResponses : Array<Dynamic>;
    static var capturedRequests : Array<Dynamic>;

    static public function run():Void {
        runner = new TestRunner();

        describe("Api.request() - 204 No Content handling", function() {
            it("should handle 204 response without calling response.json()", function() {
                setupMockFetch();
                mockResponses = [{
                    status: 204,
                    ok: true,
                    json: function() {
                        // This should NEVER be called for 204
                        throw "response.json() should not be called for 204";
                    },
                    text: function() {
                        throw "response.text() should not be called for 204";
                    }
                }];
                capturedRequests = [];

                // Import web.Api dynamically - it's in the generated bundle
                var Api = untyped js.Browser.window.web.Api;
                if (Api == null) throw "Api class not found on window.web.Api";

                var successCalled = false;
                var errorCalled = false;
                var successData : Dynamic = "not-set";

                Api.request("DELETE", "/api/servers/test-id", null,
                    function(data:Dynamic) {
                        successCalled = true;
                        successData = data;
                    },
                    function(err:String) {
                        errorCalled = true;
                        throw "onError should not be called for 204: " + err;
                    }
                );

                waitForAsync(function() {
                    if (!successCalled) throw "onSuccess was not called";
                    if (errorCalled) throw "onError should not be called for 204";
                    runner.expect(successData).toBeNull();
                });
            });
        });

        describe("Api.deleteServer()", function() {
            it("should call onSuccess on 204 response", function() {
                setupMockFetch();
                mockResponses = [{
                    status: 204,
                    ok: true,
                    json: function() { throw "should not parse json"; },
                    text: function() { throw "should not parse text"; }
                }];
                capturedRequests = [];

                var Api = untyped js.Browser.window.web.Api;
                var successCalled = false;
                var errorCalled = false;

                Api.deleteServer("srv-123",
                    function() { successCalled = true; },
                    function(err:String) { errorCalled = true; throw "Error: " + err; }
                );

                waitForAsync(function() {
                    if (!successCalled) throw "onSuccess was not called";
                    if (errorCalled) throw "onError should not be called";
                    runner.expect(capturedRequests.length).toBe(1);
                    runner.expect(capturedRequests[0].method).toBe("DELETE");
                    runner.expect(capturedRequests[0].url).toContain("/api/servers/srv-123");
                });
            });
        });

        describe("Api.request() - JSON success responses", function() {
            it("should parse JSON response on 200 status", function() {
                setupMockFetch();
                var jsonResponse = { id: "srv-456", name: "Test Server", running: false };
                mockResponses = [{
                    status: 200,
                    ok: true,
                    json: function() {
                        var p = new js.Promise();
                        js.Browser.window.setTimeout(function() { p.resolve(jsonResponse); }, 10);
                        return p;
                    },
                    text: function() { throw "should not call text"; }
                }];
                capturedRequests = [];

                var Api = untyped js.Browser.window.web.Api;
                var receivedData : Dynamic = null;
                var successCalled = false;

                Api.request("GET", "/api/servers", null,
                    function(data:Dynamic) {
                        successCalled = true;
                        receivedData = data;
                    },
                    function(err:String) {
                        throw "onError called: " + err;
                    }
                );

                waitForAsync(function() {
                    if (!successCalled) throw "onSuccess was not called";
                    runner.expect(receivedData.id).toBe("srv-456");
                    runner.expect(receivedData.name).toBe("Test Server");
                });
            });

            it("should handle error on 400+ status", function() {
                setupMockFetch();
                mockResponses = [{
                    status: 404,
                    ok: false,
                    text: function() {
                        var p = new js.Promise();
                        js.Browser.window.setTimeout(function() { p.resolve("Not found"); }, 10);
                        return p;
                    },
                    json: function() { throw "should not call json"; }
                }];
                capturedRequests = [];

                var Api = untyped js.Browser.window.web.Api;
                var successCalled = false;
                var error_msg : String = "";

                Api.request("GET", "/api/servers/nonexistent", null,
                    function(data:Dynamic) {
                        successCalled = true;
                    },
                    function(err:String) {
                        error_msg = err;
                    }
                );

                waitForAsync(function() {
                    if (successCalled) throw "onSuccess should not be called for 404";
                    runner.expect(error_msg).toContain("404");
                    runner.expect(error_msg).toContain("Not found");
                });
            });
        });

        describe("Api.listServers()", function() {
            it("should call GET /api/servers and return array", function() {
                setupMockFetch();
                var serverList = [
                    { id: "srv-1", name: "Server 1", running: true },
                    { id: "srv-2", name: "Server 2", running: false }
                ];
                mockResponses = [{
                    status: 200,
                    ok: true,
                    json: function() {
                        var p = new js.Promise();
                        js.Browser.window.setTimeout(function() { p.resolve(serverList); }, 10);
                        return p;
                    },
                    text: function() { throw "should not call text"; }
                }];
                capturedRequests = [];

                var Api = untyped js.Browser.window.web.Api;
                var receivedList : Array<Dynamic> = null;
                var successCalled = false;

                Api.listServers(
                    function(arr:Array<Dynamic>) {
                        successCalled = true;
                        receivedList = arr;
                    },
                    function(err:String) { throw "Error: " + err; }
                );

                waitForAsync(function() {
                    if (!successCalled) throw "onSuccess was not called";
                    runner.expect(receivedList.length).toBe(2);
                    runner.expect(receivedList[0].id).toBe("srv-1");
                });
            });
        });

        describe("Api.createServer()", function() {
            it("should POST /api/servers with name and saveFile", function() {
                setupMockFetch();
                mockResponses = [{
                    status: 201,
                    ok: true,
                    json: function() {
                        var p = new js.Promise();
                        js.Browser.window.setTimeout(function() {
                            p.resolve({ id: "new-srv", name: "My Server" });
                        }, 10);
                        return p;
                    },
                    text: function() { throw "should not call text"; }
                }];
                capturedRequests = [];

                var Api = untyped js.Browser.window.web.Api;
                var createdData : Dynamic = null;
                var successCalled = false;

                Api.createServer("My Server", "mysave.zip",
                    function(data:Dynamic) {
                        successCalled = true;
                        createdData = data;
                    },
                    function(err:String) { throw "Error: " + err; }
                );

                waitForAsync(function() {
                    if (!successCalled) throw "onSuccess was not called";
                    runner.expect(capturedRequests[0].method).toBe("POST");
                    runner.expect(createdData.id).toBe("new-srv");
                });
            });
        });

        // Run all tests
        runner.run();
    }

    /* -----------------------------------------------------------------
       Async test helpers
       ----------------------------------------------------------------- */

    static function waitForAsync(check:Void->Void, timeout:Float = 2000.0):Void {
        var start = js.Date.now();
        var done = false;

        function tick():Void {
            if (done) return;
            if (js.Date.now() - start > timeout) {
                throw "Async test timed out after " + timeout + "ms";
            }
            try {
                check();
                done = true;
            } catch (e:String) {
                // If the callback hasn't fired yet, keep waiting
                // We detect "not ready" by specific messages
                if (e.indexOf("onSuccess was not called") >= 0 ||
                    e.indexOf("not set") >= 0) {
                    js.Browser.window.setTimeout(tick, 20);
                } else {
                    done = true;
                    throw e;
                }
            }
        }
        tick();
    }

    static function setupMockFetch():Void {
        originalFetch = Browser.window.fetch;

        untyped Browser.window.fetch = function(url:Dynamic, opts:Dynamic):Dynamic {
            var request = {
                url: Std.string(url),
                method: if (opts != null && opts.method != null) opts.method else "GET",
                options: opts
            };
            capturedRequests.push(request);

            var p = new js.Promise();
            var respIdx = mockResponses.length > 0 ? 0 : -1;
            var resp = if (respIdx >= 0 && respIdx < mockResponses.length) mockResponses[respIdx] else null;

            js.Browser.window.setTimeout(function() {
                p.resolve(resp);
                if (respIdx >= 0 && respIdx < mockResponses.length) {
                    mockResponses.shift();
                }
            }, 10);
            return p;
        };
    }

    static function restoreFetch():Void {
        if (originalFetch != null) {
            untyped Browser.window.fetch = originalFetch;
        }
    }
}
