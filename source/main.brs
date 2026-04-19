' main.brs - Channel entry point.

sub Main(args as Dynamic)
    seedDefaults()

    screen = CreateObject("roSGScreen")
    port = CreateObject("roMessagePort")
    screen.setMessagePort(port)

    scene = screen.CreateScene("MainScene")
    screen.show()

    if args <> invalid and args.contentId <> invalid then
        scene.deepLink = args
    end if

    while true
        msg = wait(0, port)
        if type(msg) = "roSGScreenEvent" then
            if msg.isScreenClosed() then return
        end if
    end while
end sub

' Write per-channel defaults the first time the channel runs. Users can
' override anything here later via the Settings screen.
sub seedDefaults()
    reg = CreateObject("roRegistrySection", "HydraHD")
    if not reg.Exists("baseUrl") then
        reg.Write("baseUrl", "https://hydrahd.ru")
    end if
    if not reg.Exists("resolverUrl") then
        reg.Write("resolverUrl", "http://192.168.3.180:8787")
    end if
    reg.Flush()
end sub
