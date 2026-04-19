' HomeView.brs - RowList of categories from the hydrahd index page.

sub init()
    m.rows = m.top.findNode("rows")
    m.empty = m.top.findNode("empty")
    m.rows.observeField("rowItemSelected", "onItemSelected")
    m.rows.itemComponentName = "PosterItem"
    m.rows.setFocus(true)

    m.task = createObject("roSGNode", "HomeTask")
    m.task.observeField("result", "onResult")
    m.top.loading = true
    m.task.control = "RUN"
end sub

sub onResult()
    bundle = m.task.result
    m.top.loading = false
    if bundle = invalid or bundle.rows = invalid or bundle.rows.Count() = 0 then
        m.empty.text = "Failed to load - press OK to retry, or * to search."
        m.empty.visible = true
        m.empty.focusable = true
        m.empty.setFocus(true)
        return
    end if
    rows = bundle.rows

    rootContent = createObject("roSGNode", "ContentNode")
    for each row in rows
        rowNode = rootContent.createChild("ContentNode")
        rowNode.title = row.title
        for each item in row.items
            cell = rowNode.createChild("ContentNode")
            cell.title = item.title
            cell.HDPosterUrl = item.poster
            cell.SDPosterUrl = item.poster
            cell.shortDescriptionLine1 = item.rating
            cell.shortDescriptionLine2 = item.year
            cell.releaseDate = item.quality
            cell.id = item.id
            cell.contentType = item.kind
            cell.url = item.href
        end for
    end for
    m.rows.content = rootContent
    if rootContent.getChildCount() > 0 then
        m.rows.jumpToRowItem = [0, 0]
    end if
    ' Re-grab focus now that there's actually something to focus on.
    m.rows.setFocus(true)
end sub

' OK on the empty state retries the load.
sub retryLoad()
    m.empty.visible = false
    if m.task <> invalid then m.task.unobserveField("result")
    m.task = createObject("roSGNode", "HomeTask")
    m.task.observeField("result", "onResult")
    m.top.loading = true
    m.task.control = "RUN"
end sub

sub onItemSelected()
    sel = m.rows.rowItemSelected
    if sel = invalid then return
    rowIdx = sel[0]
    colIdx = sel[1]
    rowContent = m.rows.content.getChild(rowIdx)
    if rowContent = invalid then return
    item = rowContent.getChild(colIdx)
    if item = invalid then return
    payload = {
        action: "open"
        view: "DetailsView"
        args: {
            kind: item.contentType
            id: item.id
            href: item.url
            title: item.title
            poster: item.HDPosterUrl
        }
    }
    m.top.requestNav = payload
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if m.empty.visible and (key = "OK" or key = "play") then
        retryLoad()
        return true
    end if
    return false
end function
