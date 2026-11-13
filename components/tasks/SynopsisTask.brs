' SynopsisTask.brs - fetch one title's synopsis (and trailer id, when its
' page has one) for the home banner.

sub init()
    m.top.functionName = "doWork"
end sub

sub doWork()
    href = m.top.href
    if href = invalid then href = ""
    info = HA_FetchBannerInfo(href)
    m.top.result = { href: href, text: info.text, trailerId: info.trailerId }
end sub
