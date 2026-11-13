' Intercept LEFT before the native RowList consumes it at column zero.
function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press or key <> "left" then return false
    focused = m.top.rowItemFocused
    if focused = invalid or focused.Count() < 2 then return false
    if focused[1] <> 0 then return false
    m.top.openMenu = true
    return true
end function
