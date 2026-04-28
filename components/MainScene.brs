' MainScene.brs - Top-level chrome + view router.

sub init()
    m.contentHost = m.top.findNode("contentHost")
    m.topBar = m.top.findNode("topBar")
    m.hint = m.top.findNode("hint")
    m.loadingBg = m.top.findNode("loadingBg")
    m.loadingGroup = m.top.findNode("loadingGroup")
    m.loadingText = m.top.findNode("loadingText")
    m.contentDefaultY = 110

    m.navTabs = [
        { id: "navHome",     view: "HomeView",      args: invalid },
        { id: "navMovies",   view: "ListView",      args: { source: "movies",  title: "Movies" } },
        { id: "navTv",       view: "ListView",      args: { source: "tv",      title: "TV Shows" } },
        { id: "navTrending", view: "ListView",      args: { source: "popular", title: "Trending" } },
        { id: "navMyList",   view: "FavoritesView", args: invalid },
        { id: "navSearch",   view: "SearchView",    args: invalid },
        { id: "navSettings", view: "SettingsView",  args: invalid }
    ]

    m.navButtons = []
    for i = 0 to m.navTabs.Count() - 1
        btn = m.top.findNode(m.navTabs[i].id)
        m.navButtons.Push(btn)
        btn.observeField("buttonSelected", "onNavSelected")
    end for

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
    while m.contentHost.getChildCount() > 0
        m.contentHost.removeChildIndex(0)
    end while

    child = m.contentHost.createChild(viewName)
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
    isPlayer = (viewName = "PlayerView")
    m.topBar.visible = not isPlayer
    m.hint.visible = not isPlayer
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
        return false
    end if

    ' Nav-bar key handling: left/right between buttons, down into content.
    if navHasFocus() then
        if key = "left" then
            if m.activeNavIndex > 0 then
                m.activeNavIndex = m.activeNavIndex - 1
                m.navButtons[m.activeNavIndex].setFocus(true)
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
