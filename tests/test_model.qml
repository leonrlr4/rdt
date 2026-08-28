// Tests for Model.js, the panel's presentation helpers.
//
//     /usr/lib/qt6/bin/qml -platform offscreen tests/test_model.qml
//
// Exits 0 when every check passes and 1 when any fails. Failing names are
// collected in `failed` for a debugger rather than printed: the qml runtime
// under -platform offscreen swallows console.log, warn and error alike --
// verified against a two-line file that printed nothing either. The exit code
// is the contract this suite offers.
//
// Most of the plugin's logic lives in bin/reddit-fetch precisely because QML
// had no test harness. The feed-list functions below are the exception: they
// have to run inside the panel, synchronously, on a click, and their edge
// cases (case, the r/ prefix, unpinning the last tab) are real enough to be
// worth pinning down.

import QtQuick
import "../Model.js" as Model

Item {
  id: root

  property int checks: 0
  property var failed: []

  function check(name, actual, expected) {
    checks++
    var a = JSON.stringify(actual)
    var e = JSON.stringify(expected)
    // Recorded, not thrown: an exception out of Component.onCompleted skips
    // the exit timer, and the process hangs instead of failing.
    if (a !== e) failed.push(name + ": expected " + e + ", got " + a)
  }

  Timer {
    id: exitTimer
    interval: 0
    onTriggered: Qt.exit(root.failed.length === 0 ? 0 : 1)
  }

  Component.onCompleted: {
    // ---- safeMediaUrl: what the shell may be told to fetch
    check("a reddit image host passes",
          Model.safeMediaUrl("https://i.redd.it/a.png"), "https://i.redd.it/a.png")
    check("a giphy host passes",
          Model.safeMediaUrl("https://media.giphy.com/media/x/200w.gif"),
          "https://media.giphy.com/media/x/200w.gif")
    check("an unknown host is dropped",
          Model.safeMediaUrl("https://evil.example/a.png"), "")
    check("http is dropped", Model.safeMediaUrl("http://i.redd.it/a.png"), "")
    // userinfo before the host is how a URL is made to look like one thing
    // and resolve to another.
    check("a userinfo prefix cannot spoof the host",
          Model.safeMediaUrl("https://i.redd.it@evil.example/a.png"), "")
    check("a host prefix is not a match",
          Model.safeMediaUrl("https://i.redd.it.evil.example/a.png"), "")
    check("empty is dropped", Model.safeMediaUrl(""), "")
    check("undefined is dropped", Model.safeMediaUrl(undefined), "")
    check("case is ignored",
          Model.safeMediaUrl("https://I.Redd.It/a.png"), "https://I.Redd.It/a.png")

    // ---- isBrowsableUrl: what may be handed to xdg-open
    check("plain https passes",
          Model.isBrowsableUrl("https://www.reddit.com/r/linux/"), true)
    check("https with a query passes",
          Model.isBrowsableUrl("https://e.com/a?b=c"), true)
    check("http is refused", Model.isBrowsableUrl("http://e.com/"), false)
    check("file is refused", Model.isBrowsableUrl("file:///etc/passwd"), false)
    check("javascript is refused",
          Model.isBrowsableUrl("javascript:alert(1)"), false)
    check("a bare word is refused", Model.isBrowsableUrl("xdg-open"), false)
    check("a relative path is refused", Model.isBrowsableUrl("/etc/passwd"), false)
    check("empty is refused", Model.isBrowsableUrl(""), false)
    check("undefined is refused", Model.isBrowsableUrl(undefined), false)
    // Shell metacharacters cannot execute through an argv vector, but a URL
    // carrying them is not a URL and has no business reaching a launcher.
    check("a semicolon is refused",
          Model.isBrowsableUrl("https://e.com/a;rm -rf ~"), false)
    check("a backtick is refused",
          Model.isBrowsableUrl("https://e.com/`id`"), false)
    check("a space is refused", Model.isBrowsableUrl("https://e.com/a b"), false)
    check("a newline is refused",
          Model.isBrowsableUrl("https://e.com/a\nhttps://evil"), false)
    check("scheme-relative is refused", Model.isBrowsableUrl("//e.com/a"), false)
    check("an over-long url is refused",
          Model.isBrowsableUrl("https://e.com/" + new Array(2100).join("x")), false)

    // ---- feedKey: what makes two feed names the same feed
    check("feedKey strips the prefix", Model.feedKey("r/linux"), "linux")
    check("feedKey lowercases", Model.feedKey("r/Linux"), "linux")
    check("feedKey trims slashes", Model.feedKey("/r/linux/"), "linux")
    check("feedKey folds home into best", Model.feedKey("home"), "best")
    check("feedKey leaves best alone", Model.feedKey("best"), "best")

    // ---- hasFeed
    check("hasFeed matches across prefix and case",
          Model.hasFeed(["best", "r/Linux"], "linux"), true)
    check("hasFeed rejects a different sub",
          Model.hasFeed(["best", "r/linux"], "rust"), false)
    check("hasFeed on an empty list", Model.hasFeed([], "linux"), false)

    // ---- withFeed: pinning
    check("withFeed appends rather than prepends",
          Model.withFeed(["best", "r/linux"], "r/rust"),
          ["best", "r/linux", "r/rust"])
    check("withFeed will not add a duplicate",
          Model.withFeed(["best", "r/linux"], "linux"), ["best", "r/linux"])
    check("withFeed will not add a case variant",
          Model.withFeed(["r/Linux"], "r/linux"), ["r/Linux"])
    check("withFeed does not mutate its argument", (function () {
      var original = ["best"]
      Model.withFeed(original, "r/rust")
      return original
    })(), ["best"])

    // ---- withoutFeed: unpinning
    check("withoutFeed removes the match",
          Model.withoutFeed(["best", "r/linux", "r/rust"], "r/linux"),
          ["best", "r/rust"])
    check("withoutFeed matches without the prefix",
          Model.withoutFeed(["best", "r/linux"], "linux"), ["best"])
    check("withoutFeed ignores an absent feed",
          Model.withoutFeed(["best"], "r/rust"), ["best"])
    // Unpinning the last tab has to leave something to show.
    check("withoutFeed never empties the list",
          Model.withoutFeed(["r/linux"], "r/linux"), ["best"])

    // ---- parseFeeds, which reads the setting back
    check("parseFeeds splits and trims",
          Model.parseFeeds("best, r/linux ,r/rust"),
          ["best", "r/linux", "r/rust"])
    check("parseFeeds drops blanks", Model.parseFeeds("best,,r/linux"),
          ["best", "r/linux"])
    check("parseFeeds falls back to best", Model.parseFeeds(""), ["best"])
    check("parseFeeds deduplicates", Model.parseFeeds("best,BEST"), ["best"])

    // ---- feedLabel, which names the tab
    check("feedLabel names the front page", Model.feedLabel("best"), "Home")
    check("feedLabel keeps a prefix it was given",
          Model.feedLabel("r/linux"), "r/linux")
    check("feedLabel adds a missing prefix",
          Model.feedLabel("linux"), "r/linux")

    // ---- compactNumber
    check("compactNumber leaves small scores", Model.compactNumber(999), "999")
    check("compactNumber shortens thousands", Model.compactNumber(1200), "1.2k")
    check("compactNumber drops a trailing zero", Model.compactNumber(1000), "1k")
    check("compactNumber rounds large thousands",
          Model.compactNumber(21000), "21k")
    check("compactNumber shortens millions",
          Model.compactNumber(1500000), "1.5m")
    check("compactNumber handles negatives", Model.compactNumber(-1200), "-1.2k")

    // ---- relativeTime, against a fixed clock
    var now = 1787900000000
    check("relativeTime seconds", Model.relativeTime(now / 1000 - 30, now), "now")
    check("relativeTime minutes", Model.relativeTime(now / 1000 - 300, now), "5m")
    check("relativeTime hours", Model.relativeTime(now / 1000 - 7200, now), "2h")
    check("relativeTime days", Model.relativeTime(now / 1000 - 172800, now), "2d")
    check("relativeTime is blank without a timestamp",
          Model.relativeTime(0, now), "")

    // ---- flattenFeeds dedupes the way the unread count does
    check("flattenFeeds drops a post seen in two feeds",
          Model.flattenFeeds([{posts: [{id: "a"}, {id: "b"}]},
                              {posts: [{id: "b"}, {id: "c"}]}]).length, 3)

    exitTimer.start()
  }
}
