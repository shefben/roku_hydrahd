sub init()
    m.top.functionName = "doWork"
end sub

sub doWork()
    items = HA_Search(m.top.query)
    if items = invalid then items = []
    m.top.result = { items: items }
end sub
