import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import "Model.js" as Model

// Reddit in the bar: an unread count on the pill, the posts themselves in the
// popup.
//
// Auth comes from whichever Chromium-family browser you are already signed in
// to -- see bin/reddit-fetch. Nothing to configure, and nothing to paste.
//
// Left click opens the feed, right click forces a refresh.
BarWidget {
  id: root
  moduleName: "leonrlr4.rdt"

  // ---- settings (see manifest.json's barWidget.schema)
  readonly property string feedsSetting: String(setting("feeds", "best") || "best")
  readonly property var feedList: Model.parseFeeds(feedsSetting)
  // 0 means no background polling at all: the feed is fetched when you open
  // the panel and nowhere else. That is the default, because a bar widget that
  // wakes up every few minutes to spend a request on posts nobody is looking
  // at is a cost with no reader. Set a value to get a live unread count back.
  readonly property int refreshMinutes: {
    var minutes = parseInt(setting("refreshMinutes", 0), 10)
    return minutes > 0 ? Math.max(2, minutes) : 0
  }
  readonly property bool backgroundPolling: refreshMinutes > 0
  readonly property int postLimit: Math.max(5, Math.min(100, parseInt(setting("limit", 25), 10) || 25))
  readonly property string browserSetting: String(setting("browser", "") || "").trim()
  readonly property bool hideWhenRead: setting("hideWhenRead", false) === true
  readonly property bool showImages: setting("showImages", true) !== false

  readonly property string pluginDir:
    Quickshell.env("HOME") + "/.config/omarchy/plugins/leonrlr4.rdt"
  // Read state is a cache, not configuration: putting it in `settings` would
  // write it into shell.json, which the shell hot-reloads on save -- the
  // plugin would restart itself every poll.
  readonly property string seenFile:
    Quickshell.env("HOME") + "/.cache/rdt/seen.json"

  // ---- live state
  property var feeds: []            // [{feed, posts:[], error?}]
  property int unreadCount: 0
  property var unreadIds: []
  property string errorCode: ""
  property string errorMessage: ""
  property double lastSuccess: 0
  property bool loading: false

  readonly property bool hasError: errorCode !== ""
  readonly property bool everLoaded: lastSuccess > 0
  readonly property var allPosts: Model.flattenFeeds(feeds)

  // nf-fa-reddit_alien. Verified present in the Nerd Font the bar renders
  // with; a missing glyph here would paint a tofu box rather than fail loudly.
  readonly property string glyph: ""

  readonly property string pillText: {
    if (hasError) return glyph + " " + Model.errorLabel(errorCode)
    if (!everLoaded) return glyph + " …"
    return unreadCount > 0 ? glyph + " " + unreadCount : glyph
  }

  // ---- fetching
  //
  // On demand by default: opening the panel is what asks for posts. Background
  // polling is opt-in, and even then the tick is deliberately much shorter than
  // the interval, with the decision made from the time of the last *success*
  // rather than the timer's own cadence -- a laptop that suspends for an hour
  // resumes with one poll due rather than twelve, and a failed poll retries on
  // the next tick instead of waiting out a whole interval.
  readonly property int retrySeconds: 60

  // Toggling the panel shut and open again should not spend a second request.
  readonly property int openThrottleSeconds: 30

  function secondsSinceFetch() {
    return lastSuccess === 0 ? Number.POSITIVE_INFINITY
                             : (Date.now() - lastSuccess) / 1000
  }

  function due() {
    if (loading || !backgroundPolling) return false
    return secondsSinceFetch() >= (hasError ? retrySeconds : refreshMinutes * 60)
  }

  function refreshIfStale(maxAgeSeconds) {
    if (loading) return
    if (secondsSinceFetch() >= maxAgeSeconds) refresh()
  }

  function refresh() {
    if (loading) return
    loading = true
    fetchProc.command = [
      "/usr/bin/python3", pluginDir + "/bin/reddit-fetch",
      "--browser", browserSetting,
      "feed",
      "--feeds", feedList.join(","),
      "--limit", String(postLimit),
      "--seen-file", seenFile
    ].filter(function (arg, i, all) {
      // Drop `--browser ""` so the script auto-detects instead of being told
      // to look for a browser named "".
      return !(all[i - 1] === "--browser" && arg === "") && !(arg === "--browser" && all[i + 1] === "")
    })
    fetchProc.running = true
  }

  function forceRefresh() {
    lastSuccess = 0
    refresh()
  }

  function applyResult(text) {
    loading = false
    var data
    try {
      data = JSON.parse(text)
    } catch (e) {
      // A parse failure means the script died in a way it was supposed to
      // report as JSON. Surface it rather than leaving a stale pill.
      errorCode = "http_error"
      errorMessage = "The fetch helper returned unreadable output."
      return
    }

    if (!data.ok) {
      errorCode = String(data.error || "http_error")
      errorMessage = String(data.message || Model.errorHint(errorCode))
      // Keep whatever posts are already on screen; a transient failure should
      // not blank a feed the user is reading.
      return
    }

    errorCode = ""
    errorMessage = ""
    feeds = data.feeds || []
    unreadIds = data.unreadIds || []
    unreadCount = data.unread || 0
    lastSuccess = Date.now()
  }

  // Mark everything currently on screen as read. Fire-and-forget: the pill is
  // updated locally so it responds to the click, and the next poll confirms.
  function markAllRead() {
    if (unreadIds.length === 0) return
    markProc.command = [
      "/usr/bin/python3", pluginDir + "/bin/reddit-fetch",
      "mark-read", "--seen-file", seenFile, "--ids", unreadIds.join(",")
    ]
    markProc.running = true
    unreadIds = []
    unreadCount = 0
  }

  function markRead(postId) {
    if (!postId) return
    markProc.command = [
      "/usr/bin/python3", pluginDir + "/bin/reddit-fetch",
      "mark-read", "--seen-file", seenFile, "--ids", String(postId)
    ]
    markProc.running = true
    var remaining = []
    for (var i = 0; i < unreadIds.length; i++)
      if (unreadIds[i] !== postId) remaining.push(unreadIds[i])
    unreadIds = remaining
    unreadCount = remaining.length
  }

  // Persist the tab list. This is a settings write, so it lands in shell.json
  // and the shell reloads -- fine here, and the same path the first-party clock
  // uses to remember a cycled format, because it happens when you click a star
  // and not on a timer. The rule this does not break is the one about read
  // state: that changes every poll, which is why it lives in a cache file.
  function persistFeeds(value) {
    var entry = { id: moduleName }
    for (var key in settings) if (key !== "id") entry[key] = settings[key]
    entry.feeds = value
    // Applied locally first so the tab appears on the click itself; the
    // shell.json write comes back through the bar as the same value.
    settings = entry
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(moduleName, entry)
  }

  function openInBrowser(url) {
    if (!url) return
    if (bar && typeof bar.run === "function") bar.run("xdg-open " + url)
  }

  Timer {
    interval: 15000
    running: root.backgroundPolling
    repeat: true
    onTriggered: if (root.due()) root.refresh()
  }

  // One fetch shortly after load, so the pill carries a real count from login
  // instead of an ellipsis until the first click. Delayed rather than fired
  // from Component.onCompleted because the bar injects `settings` after the
  // component finishes loading -- fetching immediately would poll the default
  // feed and then have to do it again.
  Timer {
    interval: 1200
    running: true
    repeat: false
    onTriggered: root.refresh()
  }

  Process {
    id: fetchProc
    running: false
    stdout: StdioCollector {
      id: fetchOut
      waitForEnd: true
      onStreamFinished: root.applyResult(fetchOut.text)
    }
    // Only the exit code is declared: the signal's second parameter is a
    // QProcess::ExitStatus, a C++ enum qmllint cannot resolve, and naming it
    // costs the handler its compiled path for a value this never reads.
    onExited: function (exitCode) {
      // Covers the case where the helper never printed anything at all --
      // missing interpreter, plugin directory moved. StdioCollector would
      // otherwise leave `loading` stuck true and stop the widget forever.
      if (root.loading) {
        root.loading = false
        root.errorCode = "http_error"
        root.errorMessage = "The fetch helper exited without output (code "
          + exitCode + ")."
      }
    }
  }

  Process {
    id: markProc
    running: false
    stdout: StdioCollector { waitForEnd: true }
  }

  // ---- panel plumbing. Shape contract required by Bar.findPanelWidget:
  //      open/close/opened must live on the bar-widget root, not the panel.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing:
    panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("widget" in target) target.widget = root
  }

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  // Opening is what asks for posts. It still feels instant: the panel paints
  // the last result immediately and this refresh lands underneath it --
  // stale-while-revalidate rather than a spinner over an empty list.
  onOpenedChanged: if (opened) refreshIfStale(openThrottleSeconds)

  // Editing the feed list should show the new feeds, not the old ones.
  //
  // Watches the settings *string*, not the parsed array: the bar re-assigns
  // `settings` on every injectProps pass, and a var property holding a freshly
  // built array counts as changed even when its contents are identical. Keying
  // the refetch off the array would turn every re-injection into a request.
  onFeedsSettingChanged: if (everLoaded) forceRefresh()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  visible: !(hideWhenRead && !hasError && everLoaded && unreadCount === 0)

  readonly property real openPanelIndicatorWidth: button.labelWidth

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "leonrlr4.rdt"

    function refresh(): void { root.broadcast("forceRefresh") }
    function markAllRead(): void { root.broadcast("markAllRead") }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Vertical bars get the glyph alone; a count beside it would not fit the
    // icon slot.
    text: root.vertical ? root.glyph : root.pillText
    hasVisualContent: true
    active: root.unreadCount > 0 && !root.hasError
    tooltipText: root.hasError
      ? Model.errorHint(root.errorCode)
      : (root.unreadCount > 0 ? root.unreadCount + " new" : "Reddit")
    horizontalMargin: 8.75
    verticalPadding: 8.75

    onPressed: function (b) {
      if (b === Qt.RightButton) root.forceRefresh()
      else root.togglePanel()
    }
  }
}
