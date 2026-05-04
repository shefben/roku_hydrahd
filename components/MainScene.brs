' MainScene.brs - Top-level chrome + view router.

sub init()
    m.contentHost = m.top.findNode("contentHost")
    m.topBar = m.top.findNode("topBar")
    m.hint = m.top.findNode("hint")
    m.loadingBg = m.top.findNode("loadingBg")
    m.loadingGroup = m.top.findNode("loadingGroup")
    m.loadingText = m.top.findNode("loadingText")
    m.sideMenu = m.top.findNode("sideMenu")
    m.contentDefaultY = 110

    m.navTabs = [
        { id: "navHome",     view: "HomeView",      args: invalid },
        { id: "navMovies",   view: "ListView",      args: { source: "movies",  title: "Movies" } },
        { id: "navTv",       view: "ListView",      args: { source: "tv",      title: "TV Shows" } },
        { id: "navTrending", view: "ListView",      args: { source: "popular", title: "Trending" } },
        { id: "navMyList",   view: "FavoritesView", args: invalid },
        { id: "navSearch",   view: "SearchView",    args: invalid }
    ]
    ' Tabs reachable from the SideMenu only - no top-bar button. Settings
    ' was pushed off the visible 1920px row, so we route it through the
    ' drawer's "Options" entry instead.
    m.offBarTabs = [
        { id: "navSettings", view: "SettingsView",  args: invalid }
    ]

    m.navButtons = []
    for i = 0 to m.navTabs.Count() - 1
        btn = m.top.findNode(m.navTabs[i].id)
        m.navButtons.Push(btn)
        btn.observeField("buttonSelected", "onNavSelected")
    end for

    ' Sidebar lives on MainScene so it's reachable globally; observe its
    ' command field and dispatch.
    if m.sideMenu <> invalid then
        m.sideMenu.observeField("command", "onSideMenuCommand")
    end if

    m.activeNavIndex = 0
    m.viewStack = []
    m.activeChild = invalid

    pushView("HomeView", invalid)
    ' Park focus on the nav so the user always has a foothold even if
    ' the home view is still loading or failed to fetch.
    m.navButtons[0].setFocus(true)

    ' Auto-discover the resolver on the LAN so the user never has to
    ' type an IP. Runs in the background; if it succeeds before the
    ' user picks a mirror to play, ResolveTask will pick the new URL
    ' straight out of the registry.
    if U_PrefDefault("resolverUrl", "") = "" then startResolverDiscovery()
end sub

sub startResolverDiscovery()
    if m.discoverTask <> invalid then return
    task = CreateObject("roSGNode", "DiscoverTask")
    if task = invalid then return
    task.observeField("resolverUrl", "onResolverDiscovered")
    m.discoverTask = task
    task.control = "RUN"
end sub

sub onResolverDiscovered(event as Object)
    found = event.getData()
    if found <> invalid and found <> "" then
        U_PrefSet("resolverUrl", found)
    end if
    m.discoverTask = invalid
end sub

sub pushView(viewName as String, args as Dynamic)
    ' Clear any carry-over loading overlay from the previous view. When
    ' the user clicks a poster while HomeView is still mid-fetch (or any
    ' other transition where the outgoing view never got to set
    ' loading=false because it was destroyed first), the overlay would
    ' otherwise stay visible on top of the new view - hiding the new
    ' view's contents (e.g. DetailsView's Play/Mirror buttons) until
    ' the new view's own task completes and fires loading=false.
    setLoading(false)

    while m.contentHost.getChildCount() > 0
        m.contentHost.removeChildIndex(0)
    end while

    child = m.contentHost.createChild(viewName)
    ' Set args BEFORE registering the loading observer. DetailsView's
    ' onArgs fires fetchDetails which sets loading=true; we *want*
    ' MainScene to miss that first true so the partial DetailsView
    ' (title + poster + Play/Mirror buttons from args) is visible
    ' immediately while DetailsTask fills in the description in the
    ' background. The eventual loading=false from onDetailResult is
    ' a no-op against an already-hidden overlay, so the chrome stays
    ' in sync.
    if args <> invalid then child.args = args
    child.observeField("requestNav", "onChildNavRequest")
    child.observeField("loading", "onChildLoading")
    m.activeChild = child
    m.viewStack.Push({ name: viewName, args: args })
    setChromeForView(viewName)
end sub

sub setChromeForView(viewName as String)
    ' PlayerView wants the entire screen - hide the nav bar, hint, and
    ' move the contentHost up to (0, 0) so the Video node fills 1920x1080.
    ' Also hide the global sidebar strip on the player.
    isPlayer = (viewName = "PlayerView")
    m.topBar.visible = not isPlayer
    m.hint.visible = not isPlayer
    if m.sideMenu <> invalid then m.sideMenu.visible = not isPlayer
    if isPlayer then
        m.contentHost.translation = [0, 0]
    else
        m.contentHost.translation = [0, m.contentDefaultY]
    end if
end sub

sub focusActiveChild()
    if m.activeChild <> invalid then m.activeChild.setFocus(true)
end sub

sub replaceView(viewName as String, args as Dynamic)
    if m.viewStack.Count() > 0 then m.viewStack.Pop()
    pushView(viewName, args)
    focusActiveChild()
end sub

sub popView()
    if m.viewStack.Count() <= 1 then return
    m.viewStack.Pop()
    prev = m.viewStack.Pop()
    pushView(prev.name, prev.args)
    focusActiveChild()
end sub

sub onNavSelected(event as Object)
    sender = event.getRoSGNode()
    for i = 0 to m.navTabs.Count() - 1
        if m.navButtons[i].isSameNode(sender) then
            m.activeNavIndex = i
            m.viewStack = []
            pushView(m.navTabs[i].view, m.navTabs[i].args)
            focusActiveChild()
            return
        end if
    end for
end sub

sub onChildLoading(event as Object)
    flag = event.getData()
    setLoading(flag)
end sub

sub setLoading(flag as Boolean)
    m.loadingBg.visible = flag
    m.loadingGroup.visible = flag
end sub

sub onChildNavRequest(event as Object)
    payload = event.getData()
    if payload = invalid then return
    action = payload.action
    ' DetailsTask competes with DiscoverTask's subnet scan for Roku's
    ' tight per-channel TCP socket pool (~10-15). If discover is still
    ' running when the user clicks a poster, the page fetch can stall
    ' or look frozen. Cancel discover before opening any subview - the
    ' SSDP probe path finishes in <1.5s anyway, and a missed scan just
    ' means the user falls back to a manual Settings entry or a retry.
    if m.discoverTask <> invalid then
        m.discoverTask.control = "STOP"
        m.discoverTask = invalid
    end if
    if action = "open" then
        pushView(payload.view, payload.args)
        focusActiveChild()
    else if action = "replace" then
        replaceView(payload.view, payload.args)
    else if action = "back" then
        popView()
    else if action = "navTab" then
        ' SideMenu fires this to switch the user to a different top-
        ' level tab, identical to clicking that nav button.
        switchToTab(payload.tabId)
    else if action = "exit" then
        ' main.brs is observing exitRequested and returns when set.
        m.top.exitRequested = true
    end if
end sub

sub switchToTab(tabId as String)
    if tabId = "" or tabId = invalid then return
    for i = 0 to m.navTabs.Count() - 1
        if m.navTabs[i].id = tabId then
            m.activeNavIndex = i
            m.viewStack = []
            pushView(m.navTabs[i].view, m.navTabs[i].args)
            focusActiveChild()
            return
        end if
    end for
    ' Off-bar tabs (currently just Settings) have no nav button to
    ' highlight. Leave activeNavIndex pointing at the previous bar tab
    ' so UP-into-nav still lands on a valid button.
    for i = 0 to m.offBarTabs.Count() - 1
        if m.offBarTabs[i].id = tabId then
            m.viewStack = []
            pushView(m.offBarTabs[i].view, m.offBarTabs[i].args)
            focusActiveChild()
            return
        end if
    end for
end sub

' SideMenu sits at MainScene-level. Its `command` field carries the
' button the user picked: { action: "navTab", tabId: ... } /
' { action: "exit" } / { action: "collapsed" }. We dispatch directly
' rather than going through the requestNav path used by views.
sub onSideMenuCommand()
    if m.sideMenu = invalid then return
    cmd = m.sideMenu.command
    if cmd = invalid then return
    if cmd.action = "collapsed" then
        ' User dismissed the strip without picking anything - put focus
        ' back on the active view's main widget so arrows aren't dead.
        focusActiveChild()
        return
    end if
    if cmd.action = "exit" then
        m.top.exitRequested = true
        return
    end if
    if cmd.action = "navTab" then
        ' Slide the panel back out before switching tabs - otherwise it
        ' stays visible overlapping the new view's content.
        m.sideMenu.callFunc("collapseSilent", invalid)
        switchToTab(cmd.tabId)
        return
    end if
end sub

function navHasFocus() as Boolean
    for i = 0 to m.navButtons.Count() - 1
        if m.navButtons[i].hasFocus() then
            m.activeNavIndex = i
            return true
        end if
    end for
    return false
end function

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false

    ' OPTIONS (`*` on the Roku remote) is reserved for the active
    ' view: poster grids use it to toggle favorites, DetailsView uses
    ' it as a shortcut for Save-to-List. We don't intercept it here.

    if key = "back" then
        if m.viewStack.Count() > 1 then
            popView()
            return true
        end if
        ' On a root view (Home, Movies, etc.) BACK has no view to pop,
        ' so it doubles as the menu trigger. This is the most
        ' discoverable shortcut - LEFT-on-navHome works too but the
        ' user has to UP to nav first; BACK works from anywhere.
        ' Use the field-based trigger (expandRequest) instead of
        ' callFunc("openMenu") - callFunc has bitten us before with
        ' silent failures around parameter arity.
        if m.sideMenu <> invalid and m.sideMenu.visible then
            m.sideMenu.expandRequest = true
            return true
        end if
        return false
    end if

    ' Nav-bar key handling: left/right between buttons, down into content.
    if navHasFocus() then
        if key = "left" then
            if m.activeNavIndex > 0 then
                m.activeNavIndex = m.activeNavIndex - 1
                m.navButtons[m.activeNavIndex].setFocus(true)
                return true
            end if
            ' Already at the leftmost nav button - LEFT here opens the
            ' side drawer (panel expanded directly, not just the strip).
            ' Nav buttons bubble directional keys reliably; LEFT-from-
            ' RowList-col-0 does NOT bubble on Roku.
            if m.sideMenu <> invalid and m.sideMenu.visible then
                m.sideMenu.expandRequest = true
                return true
            end if
            return true
        end if
        if key = "right" then
            if m.activeNavIndex < m.navButtons.Count() - 1 then
                m.activeNavIndex = m.activeNavIndex + 1
                m.navButtons[m.activeNavIndex].setFocus(true)
            end if
            return true
        end if
        if key = "down" then
            focusActiveChild()
            return true
        end if
        return false
    end if

    ' From inside content, ^ at the top edge bubbles up here - jump to nav.
    if key = "up" then
        m.navButtons[m.activeNavIndex].setFocus(true)
        return true
    end if

    return false
end function
