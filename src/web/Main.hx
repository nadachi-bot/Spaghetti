package web;

import js.Browser.window;
import js.Browser.document;

class Main {
    static function main():Void {
        // Detect which page we are on by checking the URL path
        var path = window.location.pathname;

        if (path == "/edit" || StringTools.contains(path, "/edit/")) {
            EditPage.render();
        } else if (path == "/settings") {
            SettingsPage.render();
        } else {
            ServersPage.render();
        }
    }
}
