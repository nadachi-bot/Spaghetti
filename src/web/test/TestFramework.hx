package web.test;

/* Lightweight test framework for browser-side testing */

class TestRunner {
    static var tests:Array<Dynamic> = [];
    var name : String;
    var passed : Int;
    var failed : Int;
    var results : Array<String>;
    var currentSuite : String;
    var pending : Bool = false;

    public function new() {
        passed = 0;
        failed = 0;
        results = [];
    }

    /* -----------------------------------------------------------------
       Test definition helpers
       ----------------------------------------------------------------- */

    static public function describe(name:String, fn:Void->Void):Void {
        tests.push({ name: name, run: fn });
    }

    /* -----------------------------------------------------------------
       Assertions
       ----------------------------------------------------------------- */

    public function it(testName:String, fn:Void->Void):Void {
        currentSuite = testName;
        try {
            fn();
            passed++;
            results.push("[PASS] " + currentSuite + " - " + testName);
        } catch (e:String) {
            failed++;
            results.push("[FAIL] " + currentSuite + " - " + testName + ": " + e);
        } catch (e:haxe.PosInfo) {
            failed++;
            results.push("[FAIL] " + currentSuite + " - " + testName + ": exception");
        }
    }

    public function expect(value:Dynamic):Expectation {
        return new Expectation(value, currentSuite);
    }

    /* -----------------------------------------------------------------
       Execution
       ----------------------------------------------------------------- */

    public function run():Void {
        passed = 0;
        failed = 0;
        results = [];

        for (test in TestRunner.tests) {
            currentSuite = test.name;
            try {
                test.run();
            } catch (e:String) {
                failed++;
                results.push("[FAIL] " + test.name + ": " + e);
            }
        }

        printResults();
    }

    function printResults():Void {
        var buf:String = "\n";
        buf += "========================================\n";
        buf += "  Test Results\n";
        buf += "========================================\n";

        for (r in results) {
            buf += "  " + r + "\n";
        }

        buf += "========================================\n";
        buf += "  Passed: " + passed + "\n";
        buf += "  Failed: " + failed + "\n";
        buf += "  Total:  " + (passed + failed) + "\n";
        buf += "========================================\n";

        // Print to console
        js.Browser.window.console.log(buf);

        // Also print to a DOM element if available
        var el = js.Browser.document.getElementById("test-output");
        if (el != null) {
            el.innerHTML = buf.replace("\n", "<br>");
        }

        // Signal completion
        if (failed == 0) {
            js.Browser.window.console.log("All tests passed!");
        } else {
            js.Browser.window.console.error(failed + " test(s) failed!");
        }

        // Expose result for external test runners
        untyped js.Browser.window.__testResult = {
            passed: passed,
            failed: failed,
            total: passed + failed,
            results: results
        };

        // Trigger a custom event so Puppeteer can listen
        untyped js.Browser.window.dispatchEvent(new js.html.Event("tests-done"));
    }
}

/* -----------------------------------------------------------------
   Expectation chain
   ----------------------------------------------------------------- */

class Expectation {
    var actual : Dynamic;
    var suite : String;
    var isNot : Bool;

    public function new(actual:Dynamic, suite:String) {
        this.actual = actual;
        this.suite = suite;
        this.isNot = false;
    }

    public function toBe(expected:Dynamic):Expectation {
        if (isNot) {
            if (actual == expected)
                throw "Expected " + actual + " to NOT be " + expected;
        } else {
            if (actual != expected)
                throw "Expected " + actual + " to be " + expected + ", got " + actual;
        }
        return this;
    }

    public function toEqual(expected:Dynamic):Expectation {
        // Deep-ish equality via JSON stringify
        var aJson = haxe.Json.stringify(actual);
        var eJson = haxe.Json.stringify(expected);
        if (isNot) {
            if (aJson == eJson)
                throw "Expected values to NOT be equal";
        } else {
            if (aJson != eJson)
                throw "Expected " + eJson + ", got " + aJson;
        }
        return this;
    }

    public function toBeDefined():Expectation {
        if (isNot) {
            if (actual != null)
                throw "Expected value to be undefined/null";
        } else {
            if (actual == null)
                throw "Expected value to be defined, got null/undefined";
        }
        return this;
    }

    public function toBeNull():Expectation {
        if (isNot) {
            if (actual == null)
                throw "Expected value to NOT be null";
        } else {
            if (actual != null)
                throw "Expected null, got " + actual;
        }
        return this;
    }

    public function toBeTrue():Expectation {
        if (isNot) {
            if (actual == true)
                throw "Expected value to NOT be true";
        } else {
            if (actual != true)
                throw "Expected true, got " + actual;
        }
        return this;
    }

    public function toBeFalse():Expectation {
        if (isNot) {
            if (actual == false)
                throw "Expected value to NOT be false";
        } else {
            if (actual != false)
                throw "Expected false, got " + actual;
        }
        return this;
    }

    public function toContain(needle:String):Expectation {
        var str = Std.string(actual);
        if (isNot) {
            if (str.indexOf(needle) >= 0)
                throw "Expected string to NOT contain '" + needle + "'";
        } else {
            if (str.indexOf(needle) < 0)
                throw "Expected '" + str + "' to contain '" + needle + "'";
        }
        return this;
    }

    public function toHaveLength(expected:Int):Expectation {
        var arr:Array<Dynamic> = cast actual;
        if (arr == null)
            throw "Actual value is not an array";
        if (isNot) {
            if (arr.length == expected)
                throw "Expected array to NOT have length " + expected;
        } else {
            if (arr.length != expected)
                throw "Expected length " + expected + ", got " + arr.length;
        }
        return this;
    }

    public function notTo():Expectation {
        isNot = true;
        return this;
    }
}
