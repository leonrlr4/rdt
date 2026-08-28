pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The Reddit feed itself: one tab per configured feed, and a reading view for
// a single post's comments.
//
// The panel never fetches on open. BarWidget.qml already holds the last poll,
// so opening paints immediately and a refresh lands underneath -- see its
// onOpenedChanged. Only comments are fetched on demand, because pulling the
// comment tree for every post in a feed would spend the whole rate limit on
// posts nobody opened.
//
// BarWidget.qml owns the bar pill and hands this panel the button to anchor
// against.
Panel {
  id: root
  moduleName: "leonrlr4.rdt"
  ipcTarget: "leonrlr4.rdt"
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot, not this nested panel, so
  // everything the bar identifies a panel by has to be that widget.
  property var hostWidget: null
  property var widget: null
  readonly property var barIdentity: hostWidget || root

  readonly property var feeds: widget ? widget.feeds : []
  readonly property bool hasError: widget ? widget.hasError : false
  readonly property bool loading: widget ? widget.loading : false
  readonly property bool showImages: widget ? widget.showImages : true

  // ---- theme-bound roles
  //
  // Every colour below is a binding onto the active theme's tokens, so
  // switching theme repaints the panel without this plugin knowing anything
  // about palettes. There is not a literal colour anywhere in this file.
  //
  // Secondary text is the surface's own text at reduced alpha rather than
  // `Color.muted`. `muted` does follow the theme, but when a theme leaves it
  // undefined the shell falls back to `color8` — which on this machine's theme
  // resolves to #322F3B, a 1.5:1 ratio against the popup background, i.e.
  // unreadable. Alpha over the surface text keeps a predictable ratio under
  // any palette: the values below measure 5.4:1 and 4.7:1 here, both above the
  // 4.5:1 floor for body text, and nothing that carries words goes under 0.55.
  function shade(base, a) { return Qt.rgba(base.r, base.g, base.b, a) }

  readonly property color textPrimary: Color.popups.text
  readonly property color textSecondary: shade(Color.popups.text, 0.62)
  readonly property color textTertiary: shade(Color.popups.text, 0.55)
  readonly property color accentText: Color.popups.border
  // Distinct hues from the palette, so a glance separates "where is this
  // from" from "how popular is it" without reading either.
  readonly property color subredditText: Color.popups.border
  readonly property color scoreText: Color.accent
  readonly property color authorText: Color.accent
  // A post already read keeps its title, at the weight of secondary text.
  readonly property color titleReadText: shade(Color.popups.text, 0.62)
  // Your own upvote. Reddit's `likes` is populated only because the request is
  // authenticated as you, so this says "I voted on this", not "this is popular".
  readonly property color votedText: Color.accent
  readonly property real avatarSize: Style.space(20)
  readonly property color hairline: shade(Color.popups.text, 0.12)
  readonly property color rowHoverFill: shade(Color.popups.text, 0.07)
  readonly property color rowSelectedFill: shade(Color.popups.text, 0.10)
  readonly property color chipFill: shade(Color.popups.text, 0.06)

  property int activeTab: 0
  readonly property var activeFeed: {
    if (!feeds || feeds.length === 0) return null
    return feeds[Math.min(activeTab, feeds.length - 1)] || null
  }
  readonly property var activePosts: {
    if (browsing) return browsePosts
    return activeFeed && activeFeed.posts ? activeFeed.posts : []
  }

  // Keyboard cursor over the post list. Arrows move it, Enter opens the post
  // under it -- the panel already catches keys for tab switching, and leaving
  // Enter dead would make the list navigable but not usable from the keyboard.
  property int selectedIndex: 0

  function moveSelection(delta) {
    if (activePosts.length === 0) return
    selectedIndex = Math.max(0, Math.min(activePosts.length - 1, selectedIndex + delta))
    postList.positionViewAtIndex(selectedIndex, ListView.Contain)
  }

  function activateSelection() {
    if (reading || activePosts.length === 0) return
    var post = activePosts[Math.min(selectedIndex, activePosts.length - 1)]
    if (post) openComments(post)
  }

  // Switching tab must move the view, not just the cursor. Assigning 0 to
  // selectedIndex is a no-op whenever it is already 0 -- which it is unless
  // you have moved the keyboard cursor -- so the ListView kept the scroll
  // position from the previous tab. Past the end of a shorter feed, that is a
  // blank panel with the posts loaded and simply out of frame.
  onActiveTabChanged: {
    selectedIndex = 0
    postList.positionViewAtBeginning()
  }

  // ---- browsing a subreddit that is not one of your tabs
  //
  // Clicking r/something opens it here rather than adding a tab: looking is
  // not the same as keeping, and the star is what turns one into the other.
  property string browsingSub: ""
  property var browsePosts: []
  property bool browseLoading: false
  property string browseError: ""
  readonly property bool browsing: browsingSub !== ""

  readonly property var pinnedFeeds: widget ? widget.feedList : []
  readonly property bool browsingIsPinned:
    browsing && Model.hasFeed(pinnedFeeds, browsingSub)

  function openSub(name) {
    var sub = String(name || "").trim()
    if (sub === "") return
    if (searching) closeSearch()

    // Already one of your tabs? Switch to it. Opening a browse view of a
    // subreddit that is sitting right there as a tab looks like nothing
    // happened -- and from inside that tab, it genuinely is nothing.
    for (var i = 0; i < feeds.length; i++) {
      if (Model.feedKey(feeds[i].feed) === Model.feedKey(sub)) {
        closeComments()
        closeBrowse()
        activeTab = i
        return
      }
    }

    closeComments()
    browsingSub = sub
    browsePosts = []
    browseError = ""
    browseLoading = true
    selectedIndex = 0
    browseProc.command = [
      "/usr/bin/python3", widget.pluginDir + "/bin/reddit-fetch",
      "feed", "--feeds", "r/" + sub.replace(/^r\//, ""),
      "--limit", "25", "--seen-file", widget.seenFile
    ]
    browseProc.running = true
  }

  function closeBrowse() {
    Qt.callLater(restoreKeyFocus)
    browsingSub = ""
    browsePosts = []
    browseError = ""
    browseLoading = false
    selectedIndex = 0
    postList.positionViewAtBeginning()
  }

  function applyBrowse(text) {
    browseLoading = false
    var data
    try {
      data = JSON.parse(text)
    } catch (e) {
      browseError = "Could not read the response."
      return
    }
    if (!data.ok) {
      browseError = String(data.message || Model.errorHint(data.error))
      return
    }
    var feed = (data.feeds || [])[0]
    if (feed && feed.error) {
      browseError = String(feed.message || Model.errorHint(feed.error))
      return
    }
    browsePosts = feed ? feed.posts : []
    postList.positionViewAtBeginning()
  }

  // Pin or unpin the subreddit being browsed.
  function togglePin() {
    if (!browsing || !widget) return
    var next = browsingIsPinned
      ? Model.withoutFeed(pinnedFeeds, browsingSub)
      : Model.withFeed(pinnedFeeds, "r/" + browsingSub.replace(/^r\//, ""))
    widget.persistFeeds(next.join(","))
  }

  function unpinFeed(feed) {
    if (!widget) return
    widget.persistFeeds(Model.withoutFeed(pinnedFeeds, feed).join(","))
  }

  // ---- searching for a subreddit
  //
  // Clicking a name only reaches subreddits that happen to be in your feed.
  // This is how you reach one you cannot already see.
  property bool searching: false
  property string searchQuery: ""
  property var searchResults: []
  property bool searchLoading: false
  property string searchError: ""
  // The query the running process was started for. Assigning `running = true`
  // to a Process that is already running is a no-op, so without this every
  // keystroke that arrived mid-flight was silently dropped and the results
  // belonged to whatever query happened to win the race.
  property string searchInFlight: ""

  function openSearch() {
    closeComments()
    closeBrowse()
    searching = true
    searchQuery = ""
    searchResults = []
    searchError = ""
  }

  // The key catcher is focused once, when the panel opens. Anything that
  // takes focus afterwards -- the search field does -- leaves every shortcut
  // dead until it is handed back.
  function restoreKeyFocus() {
    if (!searching) keyCatcher.forceActiveFocus()
  }

  function closeSearch() {
    searchInFlight = ""
    searching = false
    searchQuery = ""
    searchResults = []
    searchError = ""
    searchLoading = false
    Qt.callLater(restoreKeyFocus)
  }

  function runSearch() {
    var query = searchQuery.trim()
    if (query === "" || !widget) {
      searchResults = []
      searchLoading = false
      return
    }
    if (searchProc.running) return   // onExited re-runs for the latest query
    searchInFlight = query
    searchLoading = true
    searchError = ""
    searchProc.command = [
      "/usr/bin/python3", widget.pluginDir + "/bin/reddit-fetch",
      "search", query, "--limit", "12"
    ]
    searchProc.running = true
  }

  function applySearch(text) {
    searchLoading = false
    var data
    try {
      data = JSON.parse(text)
    } catch (e) {
      searchError = "Could not read the response."
      return
    }
    if (!data.ok) {
      searchError = String(data.message || Model.errorHint(data.error))
      return
    }
    searchResults = data.subreddits || []
  }

  // ---- reading view
  property var openPost: null
  property var comments: []
  property bool commentsLoading: false
  property string commentsError: ""
  readonly property bool reading: openPost !== null

  // A clock the relative timestamps can bind to. Without it "3h" is whatever
  // it was when the row was built and never ages while the panel sits open.
  property double nowMs: Date.now()

  function unreadFor(postId) {
    if (!widget) return false
    var ids = widget.unreadIds || []
    for (var i = 0; i < ids.length; i++) if (ids[i] === postId) return true
    return false
  }

  function openComments(post) {
    openPost = post
    comments = []
    commentsError = ""
    commentsLoading = true
    if (widget) widget.markRead(post.id)
    commentsProc.command = [
      "/usr/bin/python3", widget.pluginDir + "/bin/reddit-fetch",
      "comments", String(post.id), "--limit", "40", "--depth", "3"
    ]
    commentsProc.running = true
    Qt.callLater(restoreKeyFocus)
  }

  function closeComments() {
    Qt.callLater(restoreKeyFocus)
    openPost = null
    comments = []
    commentsError = ""
    commentsLoading = false
  }

  function applyComments(text) {
    commentsLoading = false
    var data
    try {
      data = JSON.parse(text)
    } catch (e) {
      commentsError = "Could not read the comment response."
      return
    }
    if (!data.ok) {
      commentsError = String(data.message || Model.errorHint(data.error))
      return
    }
    comments = data.comments || []
    // The feed row this was opened from has no avatar field at all -- only
    // the comments endpoint resolves one. Without swapping the post over,
    // openPost.avatar stays undefined, which is both a missing picture and
    // an "Unable to assign [undefined] to QUrl" every time the panel paints.
    if (data.post) openPost = data.post
  }

  // Escape backs out of a post before it closes the panel: the reading view is
  // a level, not a mode.
  function back() {
    if (reading) closeComments()
    else if (searching) closeSearch()
    else if (browsing) closeBrowse()
    else close()
  }

  onOpenedChanged: {
    if (!opened) { closeComments(); closeBrowse(); closeSearch() }
    else nowMs = Date.now()
  }

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  // Typing "neovim" is six keystrokes and one request, not six.
  Timer {
    id: searchDebounce
    interval: 350
    onTriggered: root.runSearch()
  }

  Process {
    id: searchProc
    running: false
    stdout: StdioCollector {
      id: searchOut
      waitForEnd: true
      onStreamFinished: root.applySearch(searchOut.text)
    }
    onExited: function (exitCode) {
      if (root.searchLoading && root.searchResults.length === 0
          && root.searchError === "") {
        root.searchLoading = false
        root.searchError = "The fetch helper exited without output."
      }
      // Keystrokes that arrived while this was in flight never started a
      // process of their own.
      if (root.searching && root.searchQuery.trim() !== root.searchInFlight)
        root.runSearch()
    }
  }

  Process {
    id: browseProc
    running: false
    stdout: StdioCollector {
      id: browseOut
      waitForEnd: true
      onStreamFinished: root.applyBrowse(browseOut.text)
    }
    onExited: function (exitCode) {
      if (root.browseLoading) {
        root.browseLoading = false
        root.browseError = "The fetch helper exited without output."
      }
    }
  }

  Process {
    id: commentsProc
    running: false
    stdout: StdioCollector {
      id: commentsOut
      waitForEnd: true
      onStreamFinished: root.applyComments(commentsOut.text)
    }
    onExited: function (exitCode) {
      if (root.commentsLoading) {
        root.commentsLoading = false
        root.commentsError = "The fetch helper exited without output."
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    // 80% of the display. fittedContentHeight still clamps it to the space
    // left beside the bar, so it cannot run off the screen.
    contentHeight: panel.fittedContentHeight(panel.screenH * 0.8)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Only while the field actually has focus, which is the contract
      // PanelKeyCatcher documents. Blocking for the whole of search mode also
      // swallowed Escape and Enter.
      blocked: searchField.activeFocus
      onCloseRequested: root.back()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onActivateRequested: root.activateSelection()
      onMoveRequested: function (dx, dy) {
        if (root.reading) {
          // A fifth of the view per press: enough to make progress through a
          // long thread, little enough to keep your place.
          if (dy !== 0) readingScroll.scrollBy(dy * readingScroll.height * 0.2)
          return
        }
        if (dx !== 0 && root.feeds.length > 0)
          root.activeTab = Math.max(0, Math.min(root.feeds.length - 1, root.activeTab + dx))
        if (dy !== 0) root.moveSelection(dy)
      }
      onTextKey: function (t) {
        if (t === "/") root.openSearch()
        else if (t === "r" || t === "R") { if (root.widget) root.widget.forceRefresh() }
        else if (t === "a" || t === "A") { if (root.widget) root.widget.markAllRead() }
      }

      Column {
        anchors.fill: parent
        spacing: Style.space(8)

        // ---- header
        Item {
          width: parent.width
          // Both of headerRow's children hide while searching, which collapses
          // it to nothing. Without the search field in this max(), the header
          // has no height, and a vertically centred 30px input gets drawn half
          // outside the panel with its text cut off.
          height: Math.max(headerRow.implicitHeight,
                           searchField.visible ? searchField.implicitHeight : 0)

          Row {
            id: headerRow
            spacing: Style.space(6)

            // Back out of the reading view. Sized as its own item rather than
            // a bare glyph: a Text that collapses to zero width when it has
            // nothing to show takes its hit area down with it, which is how
            // this button managed to be invisible and unclickable at once.
            Rectangle {
              id: backButton
              visible: root.reading || root.browsing
              width: Style.space(26)
              height: Style.space(26)
              radius: Style.cornerRadius
              anchors.verticalCenter: parent.verticalCenter
              // Alpha on the fill, not `opacity`: opacity multiplies into
              // children, so a 5% backing plate would take the chevron down
              // to 5% with it and the button would be invisible again.
              color: Qt.rgba(Color.popups.text.r, Color.popups.text.g,
                             Color.popups.text.b, backHover.hovered ? 0.14 : 0.06)

              Text {
                anchors.centerIn: parent
                // nf-fa-chevron_left, written as an escape so the glyph cannot
                // be lost in transit the way a literal one can.
                text: "\uf053"
                font.family: Style.font.family
                font.pixelSize: Style.font.iconSmall
                color: root.textPrimary
              }

              HoverHandler { id: backHover }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.back()
              }
            }

            Text {
              visible: !root.searching
              text: {
                if (root.reading) return "r/" + (root.openPost ? root.openPost.subreddit : "")
                if (root.browsing) return "r/" + root.browsingSub.replace(/^r\//, "")
                return "Reddit"
              }
              font.family: Style.font.family
              font.pixelSize: Style.font.subtitle
              font.bold: true
              color: root.textPrimary
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          TextField {
            id: searchField
            visible: root.searching
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.rightMargin: Style.space(28)
            anchors.verticalCenter: parent.verticalCenter
            placeholderText: "Search subreddits"
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            foreground: root.textPrimary
            accent: root.accentText

            onVisibleChanged: if (visible) forceActiveFocus()
            onTextChanged: {
              root.searchQuery = text
              searchDebounce.restart()
            }
            Keys.onEscapePressed: root.closeSearch()
            Keys.onReturnPressed: {
              if (root.searchResults.length > 0)
                root.openSub(root.searchResults[0].name)
            }
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(10)

            // Find a subreddit that is not in your feed and cannot be
            // clicked into. "/" does the same from the keyboard.
            Text {
              visible: !root.reading && !root.searching
              text: "\uf002"
              font.family: Style.font.family
              font.pixelSize: Style.font.iconSmall
              color: root.textSecondary
              anchors.verticalCenter: parent.verticalCenter

              MouseArea {
                anchors.fill: parent
                anchors.margins: -Style.space(5)
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openSearch()
              }
            }

            // Pin the subreddit being browsed as a tab. Filled once pinned.
            Text {
              visible: root.browsing
              text: root.browsingIsPinned ? "\uf005" : "\uf006"
              font.family: Style.font.family
              font.pixelSize: Style.font.iconSmall
              color: root.browsingIsPinned ? root.votedText : root.textSecondary
              anchors.verticalCenter: parent.verticalCenter

              MouseArea {
                anchors.fill: parent
                anchors.margins: -Style.space(5)
                cursorShape: Qt.PointingHandCursor
                onClicked: root.togglePin()
              }
            }

            Text {
              visible: !root.reading && !root.browsing
                && root.widget && root.widget.unreadCount > 0
              text: root.widget ? root.widget.unreadCount + " new" : ""
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: root.accentText
              anchors.verticalCenter: parent.verticalCenter

              MouseArea {
                anchors.fill: parent
                anchors.margins: -Style.space(4)
                cursorShape: Qt.PointingHandCursor
                onClicked: if (root.widget) root.widget.markAllRead()
              }
            }

            Text {
              text: "\uf021"
              font.family: Style.font.family
              font.pixelSize: Style.font.iconSmall
              color: root.loading ? root.textTertiary : root.textSecondary
              anchors.verticalCenter: parent.verticalCenter

              MouseArea {
                anchors.fill: parent
                anchors.margins: -Style.space(4)
                cursorShape: Qt.PointingHandCursor
                onClicked: if (root.widget) root.widget.forceRefresh()
              }
            }
          }
        }

        // ---- error banner. Shown above whatever posts are cached rather than
        //      instead of them: a failed poll should not blank the feed.
        Rectangle {
          visible: root.hasError && !root.reading
          width: parent.width
          height: errorText.implicitHeight + Style.space(12)
          radius: Style.cornerRadius
          color: root.shade(Color.urgent, 0.20)

          Text {
            id: errorText
            anchors.centerIn: parent
            width: parent.width - Style.space(16)
            text: root.widget ? root.widget.errorMessage : ""
            wrapMode: Text.WordWrap
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            color: root.textPrimary
          }
        }

        // ---- feed tabs
        //
        // A ListView, not a Row: pin a handful of subreddits and the names run
        // past the panel edge, and a Row has no way to reach what it pushed
        // off. The last tab's close button was simply outside the window.
        ListView {
          id: tabList
          visible: !root.reading && !root.browsing && !root.searching
            && root.feeds.length > 1
          width: parent.width
          height: visible ? Style.space(26) : 0
          orientation: ListView.Horizontal
          spacing: Style.space(4)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          model: root.feeds

          // Keeps a tab reachable when the selection moves by keyboard.
          currentIndex: root.activeTab
          onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

          delegate: Rectangle {
            id: tabChip
            required property int index
            required property var modelData

            readonly property bool selected: index === root.activeTab
            height: tabList.height
            // The close button's width is reserved whether or not it is
            // showing. Growing the chip on hover shifted every tab after it,
            // and pushed the last one's button off the edge of the panel.
            width: tabLabel.implicitWidth + Style.space(14) + Style.space(20)
            radius: Style.cornerRadius
            color: selected ? root.chipFill : "transparent"

            Text {
              id: tabLabel
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: parent.left
              anchors.leftMargin: Style.space(7)
              text: Model.feedLabel(tabChip.modelData.feed)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              color: tabChip.selected ? root.accentText : root.textTertiary
            }

            HoverHandler { id: tabHover }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.activeTab = tabChip.index
            }

            // Unpin. Always in the same place, faded in on hover, with a
            // target the height of the chip.
            Item {
              width: Style.space(20)
              height: parent.height
              anchors.right: parent.right
              z: 2
              opacity: tabHover.hovered || closeHover.hovered ? 1 : 0
              visible: opacity > 0
              Behavior on opacity { NumberAnimation { duration: 90 } }

              Rectangle {
                anchors.centerIn: parent
                width: Style.space(16)
                height: Style.space(16)
                radius: width / 2
                color: closeHover.hovered ? root.rowSelectedFill : "transparent"

                Text {
                  anchors.centerIn: parent
                  text: "\uf00d"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: closeHover.hovered ? root.textPrimary : root.textTertiary
                }
              }

              HoverHandler { id: closeHover }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.unpinFeed(tabChip.modelData.feed)
              }
            }
          }
        }

        // ---- body: post list, or one post's comments
        Item {
          width: parent.width
          height: parent.height - y

          // Search results
          ListView {
            anchors.fill: parent
            visible: root.searching
            clip: true
            spacing: 0
            model: root.searchResults

            delegate: Item {
              id: resultRow
              required property var modelData
              required property int index
              width: ListView.view.width
              height: resultColumn.implicitHeight + Style.space(16)

              readonly property bool pinned: Model.hasFeed(root.pinnedFeeds,
                                                           modelData.name)

              Rectangle {
                anchors.fill: parent
                anchors.bottomMargin: 1
                radius: Style.cornerRadius
                color: resultHover.hovered ? root.rowHoverFill : "transparent"
              }

              Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.leftMargin: Style.space(10)
                height: 1
                color: root.hairline
                visible: index < root.searchResults.length - 1
              }

              Column {
                id: resultColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(3)

                Row {
                  spacing: Style.space(8)

                  Text {
                    id: resultName
                    text: "r/" + modelData.name
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    color: root.subredditText
                  }

                  Text {
                    text: Model.compactNumber(modelData.subscribers) + " members"
                    anchors.baseline: resultName.baseline
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: root.textTertiary
                  }

                  // Already a tab: say so, rather than letting you pin twice.
                  Text {
                    visible: resultRow.pinned
                    text: "\uf005"
                    anchors.baseline: resultName.baseline
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: root.votedText
                  }
                }

                Text {
                  visible: modelData.description !== ""
                  width: parent.width
                  text: modelData.description
                  wrapMode: Text.WordWrap
                  maximumLineCount: 2
                  elide: Text.ElideRight
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: root.textSecondary
                }
              }

              HoverHandler { id: resultHover }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openSub(modelData.name)
              }
            }
          }

          Text {
            anchors.centerIn: parent
            visible: root.searching && root.searchResults.length === 0
            width: parent.width - Style.space(40)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: {
              if (root.searchError !== "") return root.searchError
              if (root.searchLoading) return "Searching…"
              if (root.searchQuery.trim() === "") return "Type to find a subreddit"
              return "Nothing found"
            }
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            color: root.textTertiary
          }

          // Post list
          ListView {
            id: postList
            anchors.fill: parent
            visible: !root.reading && !root.searching
            clip: true
            spacing: 0
            model: root.activePosts
            currentIndex: root.selectedIndex
            // No highlight range. ApplyRange pins currentIndex inside a band
            // of the viewport, and since the cursor only moves by keyboard it
            // sat at 0 -- which locked the whole list to its first screen and
            // snapped any drag straight back. moveSelection scrolls the view
            // itself, which follows the cursor without owning the scroll.

            delegate: Item {
              required property var modelData
              required property int index
              width: ListView.view.width
              height: postColumn.implicitHeight + Style.space(18)

              Rectangle {
                anchors.fill: parent
                anchors.bottomMargin: 1
                radius: Style.cornerRadius
                color: rowHover.hovered ? root.rowHoverFill
                     : (index === root.selectedIndex ? root.rowSelectedFill
                                                     : "transparent")
              }

              // A hairline between rows. Title and meta are only two points
              // apart, so without a rule two adjacent posts read as one
              // four-line block.
              Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.leftMargin: Style.space(10)
                height: 1
                color: root.hairline
                visible: index < root.activePosts.length - 1
              }

              // An unread post gets a spine rather than a bolder title: it
              // marks the row without changing how the title reads.
              Rectangle {
                visible: root.unreadFor(modelData.id)
                width: Style.space(2)
                height: parent.height - Style.space(10)
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                radius: width
                color: root.accentText
              }

              // Reddit's own 140px square crop, which is a fifth of the size
              // of the preview rendition and all a row needs.
              Image {
                id: rowThumb
                visible: root.showImages && modelData.thumbnail !== ""
                source: visible ? modelData.thumbnail : ""
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                width: visible ? Style.space(44) : 0
                height: Style.space(44)
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: true
                smooth: true
                clip: true
              }

              // A subreddit with media switched off gets no thumbnail from
              // Reddit at all, for any post. The domain still says where the
              // row goes, so the space is not simply left blank.
              Text {
                id: rowDomain
                visible: !rowThumb.visible && modelData.domain !== ""
                text: modelData.domain
                width: visible ? Math.min(implicitWidth, Style.space(96)) : 0
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignRight
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: root.textTertiary
              }

              Column {
                id: postColumn
                anchors.left: parent.left
                anchors.right: rowThumb.visible ? rowThumb.left
                             : (rowDomain.visible ? rowDomain.left : parent.right)
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(3)

                Text {
                  width: parent.width
                  text: modelData.title
                  wrapMode: Text.WordWrap
                  maximumLineCount: 3
                  elide: Text.ElideRight
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  color: root.unreadFor(modelData.id) ? root.textPrimary
                                                      : root.titleReadText
                }

                Row {
                  spacing: Style.space(9)

                  Text {
                    text: "r/" + modelData.subreddit
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: root.subredditText

                    // Above the row's own handler, which opens the post.
                    MouseArea {
                      anchors.fill: parent
                      anchors.margins: -Style.space(2)
                      z: 2
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.openSub(modelData.subreddit)
                    }
                  }

                  Text {
                    text: (modelData.liked === true ? "\uf164 " : "\uf062 ")
                      + Model.compactNumber(modelData.score)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: modelData.liked === true ? root.votedText
                                                    : root.scoreText
                  }

                  Text {
                    text: "\uf0e5 " + Model.compactNumber(modelData.comments)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: root.textSecondary
                  }

                  Text {
                    text: Model.relativeTime(modelData.created, root.nowMs)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: root.textTertiary
                  }
                }
              }

              HoverHandler { id: rowHover }

              MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                cursorShape: Qt.PointingHandCursor
                onClicked: function (mouse) {
                  root.selectedIndex = index
                  // Middle click is the "I'll read it properly" gesture, so it
                  // hands the post to the browser and marks it read.
                  if (mouse.button === Qt.MiddleButton) {
                    if (root.widget) {
                      root.widget.markRead(modelData.id)
                      root.widget.openInBrowser(modelData.permalink)
                    }
                  } else {
                    root.openComments(modelData)
                  }
                }
              }
            }
          }

          // Empty / first-load state
          Text {
            anchors.centerIn: parent
            visible: !root.reading && root.activePosts.length === 0
            text: {
              if (root.browseError !== "") return root.browseError
              if (root.browsing && root.browseLoading) return "Loading…"
              if (root.hasError) return ""
              return root.loading ? "Loading…" : "Nothing here yet"
            }
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            color: root.textTertiary
          }

          // Reading view
          Flickable {
            id: readingScroll
            anchors.fill: parent
            visible: root.reading
            clip: true
            contentHeight: readingColumn.implicitHeight
            boundsBehavior: Flickable.StopAtBounds

            // Named so the key handler can drive it: a post and its comments
            // run far past the panel, and arrows doing nothing while reading
            // was the one place the keyboard stopped working.
            function scrollBy(pixels) {
              var maxY = Math.max(0, contentHeight - height)
              contentY = Math.max(0, Math.min(maxY, contentY + pixels))
            }

            Column {
              id: readingColumn
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: parent.width
                text: root.openPost ? root.openPost.title : ""
                wrapMode: Text.WordWrap
                font.family: Style.font.family
                font.pixelSize: Style.font.subtitle
                font.bold: true
                color: root.textPrimary
              }

              Row {
                spacing: Style.space(7)

                Image {
                  id: postAvatar
                  visible: root.showImages && root.openPost
                    && root.openPost.avatar !== ""
                  source: visible ? root.openPost.avatar : ""
                  width: visible ? root.avatarSize : 0
                  height: root.avatarSize
                  anchors.verticalCenter: parent.verticalCenter
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  cache: true
                  smooth: true
                  clip: true

                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.openPost ? "u/" + root.openPost.author : ""
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: root.authorText
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.openPost
                    ? (root.openPost.liked === true ? "\uf164 " : "\uf062 ")
                      + Model.compactNumber(root.openPost.score) : ""
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: root.openPost && root.openPost.liked === true
                    ? root.votedText : root.scoreText
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.openPost
                    ? Model.relativeTime(root.openPost.created, root.nowMs) : ""
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: root.textTertiary
                }
              }

              Repeater {
                model: root.showImages && root.openPost ? root.openPost.media : []

                AnimatedImage {
                  required property var modelData
                  width: Math.min(Style.space(260), readingColumn.width)
                  height: Style.space(190)
                  source: modelData.url
                  fillMode: Image.PreserveAspectFit
                  horizontalAlignment: Image.AlignLeft
                  asynchronous: true
                  cache: true
                  playing: true
                }
              }

              // Every picture the post has: one for an image or link post, six
              // for a gallery. Height follows each image's real aspect ratio so
              // the column does not jump as they arrive.
              Repeater {
                model: root.showImages && root.openPost ? root.openPost.images : []

                Item {
                  required property var modelData
                  width: readingColumn.width
                  height: modelData.width > 0
                    ? Math.min(Style.space(300),
                               width * modelData.height / modelData.width)
                    : Style.space(200)

                  Image {
                    anchors.fill: parent
                    source: modelData.url
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    cache: true
                    smooth: true
                    clip: true
                  }

                  // Reddit video is a DASH stream this panel cannot play, so
                  // the frame is marked as what it is rather than pretending
                  // to be a still, and the click goes to the browser.
                  Rectangle {
                    visible: root.openPost && root.openPost.isVideo
                    anchors.centerIn: parent
                    width: Style.space(44)
                    height: Style.space(44)
                    radius: width / 2
                    color: root.shade(Color.popups.background, 0.72)

                    Text {
                      anchors.centerIn: parent
                      text: "\uf04b"
                      font.family: Style.font.family
                      font.pixelSize: Style.font.iconLarge
                      color: root.textPrimary
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (root.widget && root.openPost)
                      root.widget.openInBrowser(root.openPost.permalink)
                  }
                }
              }

              Text {
                width: parent.width
                visible: root.openPost
                  && root.openPost.selftext !== ""
                text: root.openPost ? root.openPost.selftext : ""
                wrapMode: Text.WordWrap
                // Reddit writes CommonMark and Qt renders it, so bold, lists,
                // quotes and links arrive as formatting instead of as the
                // asterisks and brackets they are written with.
                textFormat: Text.MarkdownText
                linkColor: root.accentText
                onLinkActivated: function (link) {
                  if (root.widget) root.widget.openInBrowser(link)
                }
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                color: root.textPrimary
              }

              Text {
                width: parent.width
                text: "Open in browser \uf08e"
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                color: root.accentText

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: if (root.widget && root.openPost)
                    root.widget.openInBrowser(root.openPost.permalink)
                }
              }

              Rectangle {
                width: parent.width
                height: 1
                color: root.hairline
              }

              // Loading, failed, and genuinely-empty are three different
              // things, and a post with no replies is common enough that
              // silence would read as a broken panel.
              Text {
                visible: root.commentsLoading || root.commentsError !== ""
                  || root.comments.length === 0
                width: parent.width
                text: {
                  if (root.commentsError !== "") return root.commentsError
                  if (root.commentsLoading) return "Loading comments…"
                  return "No comments yet"
                }
                wrapMode: Text.WordWrap
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                color: root.textTertiary
              }

              Repeater {
                model: root.comments

                Item {
                  id: commentRow
                  required property var modelData
                  readonly property real indent: modelData.depth * Style.space(14)

                  width: readingColumn.width
                  readonly property int mediaCount:
                    root.showImages && modelData.media ? modelData.media.length : 0
                  implicitHeight: commentBody.y + commentBody.implicitHeight
                    + mediaCount * (Style.space(150) + Style.space(5))
                    + Style.space(9)

                  // A guide line down each level of nesting. Indentation alone
                  // stops answering "a reply to what?" by about the second
                  // level, and a reply that wraps to five lines leaves its
                  // parent far off the top of the panel.
                  Rectangle {
                    visible: commentRow.modelData.depth > 0
                    x: commentRow.indent - Style.space(8)
                    width: 1
                    height: parent.height - Style.space(3)
                    color: root.hairline
                  }

                  // The commenter's avatar. Reddit puts none on a comment, so
                  // the whole thread's are resolved in one request -- see
                  // attach_avatars in bin/reddit-fetch.
                  Image {
                    id: commentAvatar
                    visible: root.showImages && commentRow.modelData.avatar !== ""
                    source: visible ? commentRow.modelData.avatar : ""
                    x: commentRow.indent
                    y: 0
                    width: visible ? root.avatarSize : 0
                    height: root.avatarSize
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    cache: true
                    smooth: true
                    clip: true

                  }

                  Text {
                    id: commentByline
                    x: commentRow.indent
                       + (commentAvatar.visible ? root.avatarSize + Style.space(6) : 0)
                    width: parent.width - x
                    elide: Text.ElideRight
                    textFormat: Text.StyledText
                    text: "<font color='" + root.authorText + "'>u/"
                      + commentRow.modelData.author + "</font>   "
                      + "<font color='"
                      + (commentRow.modelData.liked === true ? root.votedText
                                                             : root.scoreText)
                      + "'>" + (commentRow.modelData.liked === true
                                ? "\uf164 " : "\uf062 ")
                      + Model.compactNumber(commentRow.modelData.score)
                      + "</font>   "
                      + Model.relativeTime(commentRow.modelData.created, root.nowMs)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: root.textTertiary
                  }

                  Repeater {
                    id: commentMedia
                    model: root.showImages ? commentRow.modelData.media : []

                    // AnimatedImage rather than Image: these are almost always
                    // GIFs, and a still first frame of a reaction GIF is worse
                    // than not showing it.
                    AnimatedImage {
                      required property var modelData
                      required property int index
                      x: commentRow.indent
                      y: commentBody.y + commentBody.implicitHeight
                         + Style.space(5) + index * (Style.space(150) + Style.space(5))
                      // Reddit's 200px rendition, never wider than the column
                      // it sits in.
                      width: Math.min(Style.space(200),
                                      commentRow.width - commentRow.indent)
                      height: Style.space(150)
                      source: modelData.url
                      fillMode: Image.PreserveAspectFit
                      horizontalAlignment: Image.AlignLeft
                      asynchronous: true
                      cache: true
                      playing: true
                    }
                  }

                  Text {
                    id: commentBody
                    x: commentByline.x
                    y: Math.max(commentByline.implicitHeight,
                                commentAvatar.visible ? root.avatarSize : 0)
                       + Style.space(2)
                    width: parent.width - x
                    text: commentRow.modelData.body
                    wrapMode: Text.WordWrap
                    textFormat: Text.MarkdownText
                    linkColor: root.accentText
                    onLinkActivated: function (link) {
                      if (root.widget) root.widget.openInBrowser(link)
                    }
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    color: root.textPrimary
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
