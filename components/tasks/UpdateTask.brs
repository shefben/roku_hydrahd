' UpdateTask.brs - mode "check": is a newer version published?
'                  mode "install": download and install `version`.

sub init()
    m.top.functionName = "doWork"
end sub

sub doWork()
    if m.top.mode = "install" then
        res = UP_Install(m.top.version, m.top.password)
        m.top.result = { mode: "install", ok: res.ok, message: res.message }
    else
        res = UP_Check()
        m.top.result = { mode: "check", current: res.current, latest: res.latest, available: res.available }
    end if
end sub
