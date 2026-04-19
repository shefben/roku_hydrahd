' SettingsView.brs - Base URL, resolver URL, default CC styling.

sub init()
    m.baseUrlValue = m.top.findNode("baseUrlValue")
    m.resolverValue = m.top.findNode("resolverValue")
    m.ccPreview = m.top.findNode("ccPreview")
    m.ccPreviewBg = m.top.findNode("ccPreviewBg")
    m.urlEditGroup = m.top.findNode("urlEditGroup")
    m.urlEditTitle = m.top.findNode("urlEditTitle")
    m.urlKb = m.top.findNode("urlKb")

    m.top.findNode("useDefaultBase").observeField("buttonSelected", "onUseDefaultBase")
    m.top.findNode("editBase").observeField("buttonSelected", "onEditBase")
    m.top.findNode("setResolver").observeField("buttonSelected", "onEditResolver")
    m.top.findNode("clearResolver").observeField("buttonSelected", "onClearResolver")
    m.top.findNode("urlSave").observeField("buttonSelected", "onUrlSave")
    m.top.findNode("urlCancel").observeField("buttonSelected", "onUrlCancel")

    for each id in ["ccSizeSmall", "ccSizeMed", "ccSizeLarge", "ccColorWhite", "ccColorYellow", "ccColorCyan", "ccBgBlack", "ccBgSemi", "ccBgNone"]
        m.top.findNode(id).observeField("buttonSelected", "onCcChange")
    end for

    m.editTarget = ""
    m.top.findNode("useDefaultBase").setFocus(true)

    refresh()
end sub

sub refresh()
    m.baseUrlValue.text = U_PrefDefault("baseUrl", "https://hydrahd.ru")
    r = U_PrefDefault("resolverUrl", "")
    if r = "" then r = "(not set - falls back to best-effort scrape)"
    m.resolverValue.text = r
    paintCcPreview()
end sub

sub onUseDefaultBase()
    U_PrefSet("baseUrl", "https://hydrahd.ru")
    refresh()
end sub

sub onEditBase()
    m.editTarget = "baseUrl"
    m.urlEditTitle.text = "Edit base URL"
    m.urlKb.text = U_PrefDefault("baseUrl", "https://hydrahd.ru")
    m.urlEditGroup.visible = true
    m.urlKb.setFocus(true)
end sub

sub onEditResolver()
    m.editTarget = "resolverUrl"
    m.urlEditTitle.text = "Edit resolver URL (e.g. http://192.168.1.50:8787)"
    m.urlKb.text = U_PrefDefault("resolverUrl", "")
    m.urlEditGroup.visible = true
    m.urlKb.setFocus(true)
end sub

sub onClearResolver()
    U_PrefSet("resolverUrl", "")
    refresh()
end sub

sub onUrlSave()
    val = U_Trim(m.urlKb.text)
    if val = invalid then val = ""
    if m.editTarget = "baseUrl" and val = "" then val = "https://hydrahd.ru"
    U_PrefSet(m.editTarget, val)
    m.urlEditGroup.visible = false
    refresh()
end sub

sub onUrlCancel()
    m.urlEditGroup.visible = false
end sub

sub onCcChange(event as Object)
    sender = event.getRoSGNode()
    id = sender.id
    reg = CreateObject("roRegistrySection", "HydraHD")
    if id = "ccSizeSmall" then reg.Write("ccTextSize", "small")
    if id = "ccSizeMed" then reg.Write("ccTextSize", "medium")
    if id = "ccSizeLarge" then reg.Write("ccTextSize", "large")
    if id = "ccColorWhite" then reg.Write("ccTextColor", "0xffffff")
    if id = "ccColorYellow" then reg.Write("ccTextColor", "0xffd24a")
    if id = "ccColorCyan" then reg.Write("ccTextColor", "0x66e5ff")
    if id = "ccBgBlack" then
        reg.Write("ccBgColor", "0x000000")
        reg.Write("ccBgOpacity", "100")
    end if
    if id = "ccBgSemi" then
        reg.Write("ccBgColor", "0x000000")
        reg.Write("ccBgOpacity", "60")
    end if
    if id = "ccBgNone" then reg.Write("ccBgOpacity", "0")
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
