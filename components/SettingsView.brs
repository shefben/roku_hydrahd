' SettingsView.brs - Base URL, resolver URL, default CC styling.

sub init()
    m.baseUrlValue = m.top.findNode("baseUrlValue")
    m.resolverValue = m.top.findNode("resolverValue")
    m.ccPreview = m.top.findNode("ccPreview")
    m.ccPreviewBg = m.top.findNode("ccPreviewBg")
    m.urlEditGroup = m.top.findNode("urlEditGroup")
    m.urlEditTitle = m.top.findNode("urlEditTitle")
    m.urlKb = m.top.findNode("urlKb")

    ' Each row is its own ButtonGroup so left/right works inside the row.
    ' We track the rows in display order so onKeyEvent can move focus
    ' up/down between them.
    m.baseRow = m.top.findNode("baseRow")
    m.baseRow.buttons = ["Use hydrahd.ru", "Edit URL"]
    m.baseRow.observeField("buttonSelected", "onBaseRowSelected")

    m.resolverRow = m.top.findNode("resolverRow")
    m.resolverRow.buttons = ["Set Resolver...", "Clear"]
    m.resolverRow.observeField("buttonSelected", "onResolverRowSelected")

    m.ccSizeRow = m.top.findNode("ccSizeRow")
    m.ccSizeRow.buttons = ["Text: Small", "Text: Medium", "Text: Large"]
    m.ccSizeRow.observeField("buttonSelected", "onCcSizeSelected")

    m.ccColorRow = m.top.findNode("ccColorRow")
    m.ccColorRow.buttons = ["Text: White", "Text: Yellow", "Text: Cyan"]
    m.ccColorRow.observeField("buttonSelected", "onCcColorSelected")

    m.ccBgRow = m.top.findNode("ccBgRow")
    m.ccBgRow.buttons = ["BG: Black", "BG: Semi-Transparent", "BG: None"]
    m.ccBgRow.observeField("buttonSelected", "onCcBgSelected")

    m.urlActionsRow = m.top.findNode("urlActionsRow")
    m.urlActionsRow.buttons = ["Save", "Cancel"]
    m.urlActionsRow.observeField("buttonSelected", "onUrlActionsSelected")

    m.rowOrder = [m.baseRow, m.resolverRow, m.ccSizeRow, m.ccColorRow, m.ccBgRow]

    m.editTarget = ""
    m.baseRow.setFocus(true)

    refresh()
end sub

sub refresh()
    m.baseUrlValue.text = U_PrefDefault("baseUrl", "https://hydrahd.ru")
    r = U_PrefDefault("resolverUrl", "")
    if r = "" then r = "(not set - falls back to best-effort scrape)"
    m.resolverValue.text = r
    paintCcPreview()
end sub

sub onBaseRowSelected()
    idx = m.baseRow.buttonSelected
    if idx = 0 then
        U_PrefSet("baseUrl", "https://hydrahd.ru")
        refresh()
    else if idx = 1 then
        openUrlEditor("baseUrl", "Edit base URL", U_PrefDefault("baseUrl", "https://hydrahd.ru"))
    end if
end sub

sub onResolverRowSelected()
    idx = m.resolverRow.buttonSelected
    if idx = 0 then
        openUrlEditor("resolverUrl", "Edit resolver URL (e.g. http://192.168.1.50:8787)", U_PrefDefault("resolverUrl", ""))
    else if idx = 1 then
        U_PrefSet("resolverUrl", "")
        refresh()
    end if
end sub

sub openUrlEditor(target as String, title as String, initial as Dynamic)
    m.editTarget = target
    m.urlEditTitle.text = title
    if initial = invalid then initial = ""
    m.urlKb.text = initial
    m.urlEditGroup.visible = true
    m.urlKb.setFocus(true)
end sub

sub onUrlActionsSelected()
    idx = m.urlActionsRow.buttonSelected
    if idx = 0 then
        val = U_Trim(m.urlKb.text)
        if val = invalid then val = ""
        if m.editTarget = "baseUrl" and val = "" then val = "https://hydrahd.ru"
        U_PrefSet(m.editTarget, val)
        m.urlEditGroup.visible = false
        refresh()
        m.baseRow.setFocus(true)
    else if idx = 1 then
        m.urlEditGroup.visible = false
        m.baseRow.setFocus(true)
    end if
end sub

sub onCcSizeSelected()
    reg = CreateObject("roRegistrySection", "HydraHD")
    idx = m.ccSizeRow.buttonSelected
    if idx = 0 then reg.Write("ccTextSize", "small")
    if idx = 1 then reg.Write("ccTextSize", "medium")
    if idx = 2 then reg.Write("ccTextSize", "large")
    reg.Flush()
    paintCcPreview()
end sub

sub onCcColorSelected()
    reg = CreateObject("roRegistrySection", "HydraHD")
    idx = m.ccColorRow.buttonSelected
    if idx = 0 then reg.Write("ccTextColor", "0xffffff")
    if idx = 1 then reg.Write("ccTextColor", "0xffd24a")
    if idx = 2 then reg.Write("ccTextColor", "0x66e5ff")
    reg.Flush()
    paintCcPreview()
end sub

sub onCcBgSelected()
    reg = CreateObject("roRegistrySection", "HydraHD")
    idx = m.ccBgRow.buttonSelected
    if idx = 0 then
        reg.Write("ccBgColor", "0x000000")
        reg.Write("ccBgOpacity", "100")
    else if idx = 1 then
        reg.Write("ccBgColor", "0x000000")
        reg.Write("ccBgOpacity", "60")
    else if idx = 2 then
        reg.Write("ccBgOpacity", "0")
    end if
    reg.Flush()
    paintCcPreview()
end sub

sub paintCcPreview()
    reg = CreateObject("roRegistrySection", "HydraHD")
    sz = "medium"
    if reg.Exists("ccTextSize") then sz = reg.Read("ccTextSize")
    color = "0xffffffff"
    if reg.Exists("ccTextColor") then color = reg.Read("ccTextColor") + "ff"
    bgOpacity = 60
    if reg.Exists("ccBgOpacity") then bgOpacity = reg.Read("ccBgOpacity").ToInt()
    bgHex = "000000"
    if reg.Exists("ccBgColor") then bgHex = Mid(reg.Read("ccBgColor"), 3)
    alpha = Cint(bgOpacity * 255 / 100)
    if alpha > 255 then alpha = 255
    aHex = StrI(alpha, 16)
    if Len(aHex) = 1 then aHex = "0" + aHex
    bgFull = "0x" + bgHex + aHex

    if sz = "small" then
        m.ccPreview.font = "font:SmallBoldSystemFont"
    else if sz = "large" then
        m.ccPreview.font = "font:LargeBoldSystemFont"
    else
        m.ccPreview.font = "font:MediumBoldSystemFont"
    end if
    m.ccPreview.color = color
    m.ccPreviewBg.color = bgFull
end sub

' Find which row is currently focused, or -1.
function focusedRowIndex() as Integer
    for i = 0 to m.rowOrder.Count() - 1
        if m.rowOrder[i].hasFocus() then return i
    end for
    return -1
end function

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false

    ' Modal keyboard - back / cancel routes back to the rows.
    if m.urlEditGroup.visible then
        if key = "back" then
            m.urlEditGroup.visible = false
            m.baseRow.setFocus(true)
            return true
        end if
        if key = "down" and m.urlKb.hasFocus() then
            m.urlActionsRow.setFocus(true)
            return true
        end if
        if key = "up" and m.urlActionsRow.hasFocus() then
            m.urlKb.setFocus(true)
            return true
        end if
        return false
    end if

    rowIdx = focusedRowIndex()
    if rowIdx < 0 then return false
    if key = "down" then
        if rowIdx + 1 < m.rowOrder.Count() then
            m.rowOrder[rowIdx + 1].setFocus(true)
            return true
        end if
        return false
    end if
    if key = "up" then
        if rowIdx > 0 then
            m.rowOrder[rowIdx - 1].setFocus(true)
            return true
        end if
        ' At top row - bubble to MainScene so it can re-focus the nav bar.
        return false
    end if
    return false
end function
