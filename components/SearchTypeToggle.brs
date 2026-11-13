' Horizontal ButtonGroup can consume DOWN before SearchView sees it.
function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if key = "down" or (key = "left" and m.top.buttonFocused = 0) then
        m.top.navigate = key
        return true
    end if
    return false
end function
