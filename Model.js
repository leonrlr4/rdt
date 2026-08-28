.pragma library

// Presentation helpers for the Reddit widget.
//
// Everything here is a pure function of its arguments. All of the logic worth
// testing -- auth selection, normalization, unread bookkeeping -- lives in
// bin/reddit-fetch, where it is covered by tests/test_fetch.py. What is left
// here is formatting that is verified by looking at the bar, so it is kept
// deliberately trivial.

// Feed names as the user types them in settings -> a clean list.
function parseFeeds(raw) {
    var out = []
    var seen = {}
    var parts = String(raw || "").split(",")
    for (var i = 0; i < parts.length; i++) {
        var name = parts[i].trim().replace(/^\/+|\/+$/g, "")
        if (name === "") continue
        var key = name.toLowerCase()
        if (seen[key]) continue
        seen[key] = true
        out.push(name)
    }
    return out.length > 0 ? out : ["best"]
}

// Feed names compare case-insensitively and without their r/ prefix, so
// pinning "linux" when "r/Linux" is already a tab does not add a second one.
function feedKey(feed) {
    var name = String(feed || "").trim().replace(/^\/+|\/+$/g, "").toLowerCase()
    if (name === "home") return "best"
    return name.indexOf("r/") === 0 ? name.slice(2) : name
}

function hasFeed(feeds, feed) {
    var key = feedKey(feed)
    for (var i = 0; i < feeds.length; i++) if (feedKey(feeds[i]) === key) return true
    return false
}

// Pinning appends: a new tab belongs after the ones already there, not in
// front of them.
function withFeed(feeds, feed) {
    return hasFeed(feeds, feed) ? feeds.slice() : feeds.concat([feed])
}

// Unpinning everything leaves the subscribed front page rather than an empty
// panel; parseFeeds applies the same floor when the setting is read back.
function withoutFeed(feeds, feed) {
    var key = feedKey(feed)
    var out = []
    for (var i = 0; i < feeds.length; i++) {
        if (feedKey(feeds[i]) !== key) out.push(feeds[i])
    }
    return out.length > 0 ? out : ["best"]
}

// "best"/"home" is the subscribed front page; everything else is a subreddit.
function feedLabel(feed) {
    var name = String(feed || "").trim()
    var lower = name.toLowerCase()
    if (lower === "best" || lower === "home" || lower === "") return "Home"
    return lower.indexOf("r/") === 0 ? name : "r/" + name
}

// Reddit-style score shortening: 1200 -> "1.2k".
function compactNumber(value) {
    var n = Number(value) || 0
    var sign = n < 0 ? "-" : ""
    n = Math.abs(n)
    if (n < 1000) return sign + n
    if (n < 1000000) {
        var k = n / 1000
        return sign + (k < 10 ? k.toFixed(1).replace(/\.0$/, "") : Math.round(k)) + "k"
    }
    var m = n / 1000000
    return sign + (m < 10 ? m.toFixed(1).replace(/\.0$/, "") : Math.round(m)) + "m"
}

// Coarse age, the way a feed reads it: minutes, then hours, then days.
function relativeTime(createdUtcSeconds, nowMs) {
    var created = Number(createdUtcSeconds) || 0
    if (created <= 0) return ""
    var seconds = Math.max(0, ((nowMs === undefined ? Date.now() : nowMs) / 1000) - created)
    if (seconds < 60) return "now"
    var minutes = Math.floor(seconds / 60)
    if (minutes < 60) return minutes + "m"
    var hours = Math.floor(minutes / 60)
    if (hours < 24) return hours + "h"
    var days = Math.floor(hours / 24)
    if (days < 30) return days + "d"
    var months = Math.floor(days / 30)
    if (months < 12) return months + "mo"
    return Math.floor(months / 12) + "y"
}

// The bar has one line to say what went wrong, so each code gets a short
// phrase and the panel carries the longer message from the script.
function errorLabel(code) {
    switch (code) {
    case "no_browser":     return "no browser"
    case "not_logged_in":  return "log in"
    case "keyring_locked": return "keyring"
    case "auth_expired":   return "session"
    case "decrypt_failed": return "locked"
    case "rate_limited":   return "throttled"
    case "offline":        return "offline"
    case "http_error":     return "error"
    default:               return "error"
    }
}

// What the user should actually do about it. The script's own message is
// preferred when it has one; this is the fallback and the panel's hint line.
function errorHint(code) {
    switch (code) {
    case "no_browser":
        return "Log in to Reddit in Chromium, Chrome, Brave, Vivaldi or Edge."
    case "not_logged_in":
        return "Your browser has no Reddit session. Log in to Reddit there."
    case "keyring_locked":
        return "Unlock your keyring so the browser's cookie key can be read."
    case "auth_expired":
        return "Open Reddit in your browser to refresh the session."
    case "decrypt_failed":
        return "Reddit cookies were found but could not be decrypted."
    case "rate_limited":
        return "Reddit is rate limiting. The next poll will back off."
    case "offline":
        return "Could not reach Reddit."
    default:
        return "Reddit returned an unexpected response."
    }
}

// Merge a fresh poll into what the panel is already showing.
//
// New posts are appended rather than spliced into rank order: while the panel
// is open the reader's eye is on a row, and re-sorting under the cursor moves
// whatever they were about to click. Ranking is only allowed to apply on a
// fresh open, which the caller signals by passing an empty `current`.
function mergePosts(current, incoming) {
    if (!current || current.length === 0) return incoming.slice()

    var index = {}
    for (var i = 0; i < current.length; i++) index[current[i].id] = i

    var merged = current.slice()
    for (var j = 0; j < incoming.length; j++) {
        var post = incoming[j]
        var at = index[post.id]
        if (at === undefined) merged.push(post)
        else merged[at] = post   // same row, refreshed score and comment count
    }
    return merged
}

// Posts across every feed, deduplicated the way the unread count is: a post
// from a subreddit you subscribe to arrives once from its own feed and once
// from /best.
function flattenFeeds(feeds) {
    var out = []
    var seen = {}
    for (var i = 0; i < (feeds || []).length; i++) {
        var posts = feeds[i].posts || []
        for (var j = 0; j < posts.length; j++) {
            if (seen[posts[j].id]) continue
            seen[posts[j].id] = true
            out.push(posts[j])
        }
    }
    return out
}
