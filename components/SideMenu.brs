' SideMenu.brs - Slide-out left-edge nav drawer, fully remote-driven.
'
' Collapsed state: a thin vertical strip at x=0 with a "›" chevron.
' Pressing LEFT from the leftmost grid column in the host view focuses
' the strip (parent calls callFunc("focusStrip", invalid)). The strip
' brightens to show focus. OK or RIGHT expands the panel.
'
' Expanded state: a 280-wide panel slides in from the left with a
' vertical ButtonGroup. The first entry "< Close" returns to the
' collapsed state. The remaining entries fire `command` updates that
' the parent forwards to MainScene.

sub init()
    m.strip = m.top.findNode("strip")
    m.stripChevron = m.top.findNode("stripChevron")
    m.stripToggle = m.top.findNode("stripToggle")
    m.panel = m.top.findNode("panel")
    m.menuBg = m.top.findNode("menuBg")
    m.expandAnim = m.top.findNode("expandAnim")
    m.expandInterp = m.top.findNode("expandInterp")

    m.expanded = false
    ' Action codes parallel to the buttons array; index 0 closes the
    ' drawer, the rest map to MainScene nav tabs (or "exit").
    m.actions = ["close", "search", "favorites", "movies", "tv", "settings", "home", "exit"]
    m.menuBg.buttons = [
        "< Close",
        "Search",
        "Favorites",
        "Browse Movies",
        "Browse TV Shows",
        "Options",
        "Home",
        "Exit"
    ]
    m.menuBg.observeField("buttonSelected", "onButton")
    m.top.observeField("focusedChild", "onFocusedChild")
    m.top.observeField("expandRequest", "onExpandRequest")

    m.tabMap = {
        search:    "navSearch"
        favorites: "navMyList"
        movies:    "navMovies"
        tv:        "navTv"
        settings:  "navSettings"
        home:      "navHome"
    }
    updateStripVisual(false)
end sub

sub updateStripVisual(focused as Boolean)
    if focused then
        m.strip.opacity = 1.0
        m.stripChevron.opacity = 1.0
    else
        m.strip.opacity = 0.3
        m.stripChevron.opacity = 0.4
    end if
end sub

' --- Public API (callFunc-able) -----------------------------------------
'
' Roku's callFunc REQUIRES the called function to accept exactly one
' parameter, even when the caller passes invalid. A 0-arity function
' fails silently (callFunc returns invalid, function never runs) -
' that's the bug that made LEFT-on-navHome look like a dead key.
' Each public function here takes a `_unused as Dynamic` placeholder.

function focusStrip(_unused as Dynamic) as Object
    if m.expanded then
        m.menuBg.setFocus(true)
        return invalid
    end if
    m.stripToggle.setFocus(true)
    return invalid
end function

' Directly expand the panel and put focus on the first button. Used
' as the user-facing trigger - lighting up a 6px strip is too subtle.
function openMenu(_unused as Dynamic) as Object
    expand()
    return invalid
end function

function isExpanded(_unused as Dynamic) as Object
    return m.expanded
end function

' Snap the panel back to collapsed without notifying the parent. Used
' if the parent view is being torn down or wants to reset state.
function collapseSilent(_unused as Dynamic) as Object
    if not m.expanded then return invalid
    m.expanded = false
    m.expandInterp.keyValue = [[0, 0], [-280, 0]]
    m.expandAnim.control = "stop"
    m.expandAnim.control = "start"
    return invalid
end function

' Field-based trigger as a belt-and-suspenders backup for callFunc.
' MainScene sets `expandRequest = true` and we expand from here. This
' path doesn't depend on callFunc's parameter-arity rules at all.
sub onExpandRequest()
    if m.top.expandRequest then
        expand()
        m.top.expandRequest = false
    end if
end sub

' --- Internal -----------------------------------------------------------

sub expand()
    if m.expanded then return
    m.expanded = true
    m.expandInterp.keyValue = [[-280, 0], [0, 0]]
    m.expandAnim.control = "stop"
    m.expandAnim.control = "start"
    ' Land focus on the first button (the close arrow) so the user
    ' instantly knows where they are and can press DOWN to navigate.
    m.menuBg.jumpToItem = 0
    m.menuBg.setFocus(true)
end sub

sub collapse()
    if not m.expanded then return
    m.expanded = false
    m.expandInterp.keyValue = [[0, 0], [-280, 0]]
    m.expandAnim.control = "stop"
    m.expandAnim.control = "start"
    m.stripToggle.setFocus(true)
    ' Tell the parent to put focus back on its grid - never leave
    ' the user stranded after a collapse animation.
    m.top.command = { action: "collapsed" }
end sub

sub onButton()
    idx = m.menuBg.buttonSelected
    if idx = invalid or idx < 0 or idx >= m.actions.Count() then return
    action = m.actions[idx]
    if action = "close" then
        collapse()
        return
    end if
    if action = "exit" then
        m.top.command = { action: "exit" }
        return
    end if
    tabId = m.tabMap[action]
    if tabId = invalid or tabId = "" then return
    m.top.command = { action: "navTab", tabId: tabId }
end sub

sub onFocusedChild()
    fc = m.top.focusedChild
    isStrip = (fc <> invalid and fc.isSameNode(m.stripToggle))
    updateStripVisual(isStrip)
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if not m.expanded then
        ' Collapsed state - only the strip toggle has focus here.
        if m.stripToggle.hasFocus() then
            if key = "OK" then
                expand()
                return true
            end if
            if key = "right" or key = "back" then
                ' RIGHT/BACK cancels the highlight and hands focus back
                ' to the parent's content so the user is never stuck
                ' on the strip without an obvious escape.
                m.top.command = { action: "collapsed" }
                return true
            end if
            ' Up / down / left bubble out: UP lets MainScene grab the
            ' top nav, others are harmless no-ops.
        end if
        return false
    end if
    ' Expanded state.
    if key = "left" or key = "back" or key = "right" then
        collapse()
        return true
    end if
    return false
end function
