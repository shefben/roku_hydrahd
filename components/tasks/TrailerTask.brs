' TrailerTask.brs - resolve one title's trailer to a playable MP4 URL.

sub init()
    m.top.functionName = "doWork"
end sub

sub doWork()
    href = m.top.href
    if href = invalid then href = ""
    url = TR_Resolve(m.top.videoId, m.top.title, m.top.year, m.top.kind)
    m.top.result = { href: href, url: url }
end sub
