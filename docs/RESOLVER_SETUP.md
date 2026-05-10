# External Resolver Setup (optional)

The channel resolves stream URLs in two layers:

1. **In-channel resolver** (default after Phase 1-4b on the `Standlone_Channel` branch). Runs entirely on the Roku, no host required. Covers ~10 of HydraHD's 16 mirrors directly plus their iframe chains. Toggle in **Settings → In-Channel Resolver** (default OFF on first install so an upgrade from a previous build is a no-op).
2. **External resolver** (`resolver/server.py`, this repo). A small Python HTTP service the channel calls when in-channel resolution returns no URL. It's the original architecture and remains the recommended fallback for the 5 CF-blocked / architecture-blocked mirrors and for cases where the in-channel path hits an unforeseen edge.

If you only ever want the in-channel path, you can leave the external resolver unconfigured and the cascade just stops there. If you want the external resolver too, run it on **either a LAN host or a cloud VPS** — both work the same. The channel doesn't care where the URL points as long as it can reach it.

## Option A — LAN host (simplest)

Run the resolver on any always-on machine on your home network: a Pi, a NAS, a desktop, or a laptop that's docked.

```bash
cd resolver
python3 server.py --host 0.0.0.0 --port 8787
```

(`server.py` only uses the Python standard library, so there's no `pip install` step. Python 3.10+ recommended.)

The server broadcasts on UDP 1901 so the channel auto-discovers it on next launch. If discovery doesn't work (VLAN, AP isolation, multi-homed network), open **Settings → Stream Resolver URL** and either re-run "Auto-discover" or paste the URL manually (e.g. `http://192.168.1.50:8787`).

### systemd unit (Linux always-on)

```ini
# /etc/systemd/system/hydrahd-resolver.service
[Unit]
Description=HydraHD Roku resolver
After=network.target

[Service]
Type=simple
User=youruser
WorkingDirectory=/path/to/roku_channel/resolver
ExecStart=/usr/bin/python3 server.py --host 0.0.0.0 --port 8787
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

Then `sudo systemctl enable --now hydrahd-resolver`.

### Windows Scheduled Task (always-on)

Open Task Scheduler, "Create Basic Task". Trigger "When the computer starts". Action: `python.exe` with arguments `F:\path\to\roku_channel\resolver\server.py --host 0.0.0.0 --port 8787`. Run whether user is logged on or not, hidden, restart if fails.

## Option B — Cloud VPS

If you don't want a LAN host, run the same `server.py` on a free or near-free cloud VM. Any provider that gives you a public IP and lets you open one TCP port works. **No part of the resolver requires the cloud — this is just a deployment target.**

Suggested zero-cost options (no expiry):

| Provider | Free tier | Notes |
|---|---|---|
| Oracle Always-Free A1 ARM | 4 OCPU, 24 GB RAM, 200 GB disk, 10 TB/mo egress | The recommended target. Permanent free tier, no hidden tier-up. ARM64; pin Python to whatever's in the Ubuntu image. |
| Google Cloud e2-micro | 1 vCPU, 1 GB RAM, 30 GB, 1 GB/mo egress | "Free Tier" lifetime per project. Egress cap is the only real constraint. |
| AWS EC2 t4g.nano | Not free; ~$3/mo | Worth mentioning if you need a US-East PoP. |

### Deploying to Oracle Always-Free A1

1. Provision an Ubuntu 22.04 ARM instance (ampere shape, 1 OCPU / 6 GB RAM is plenty).
2. SSH in. `sudo apt update && sudo apt install -y python3-pip git`.
3. `git clone <this-repo> ~/roku_channel && cd ~/roku_channel/resolver`.
4. Open the chosen port in the Oracle Cloud security list AND on `ufw` if enabled (`sudo ufw allow 8787/tcp`).
5. Run under systemd as in Option A.
6. In the channel, **Settings → External Resolver URL → Set Manually...** and paste `http://<public-ip>:8787` (or `https://...` if you front it with Caddy / nginx + Let's Encrypt). Auto-discovery only works on LAN; the cloud path requires a manual URL.

### TLS / hardening

The default `server.py` listens HTTP. If you expose it to the public internet, **front it with a reverse proxy that does TLS** (Caddy is one line, nginx is a few more). Add basic auth or a long random URL prefix if you don't want strangers using your CPU as a free resolver.

```caddyfile
resolver.example.com {
    reverse_proxy 127.0.0.1:8787
    basicauth /* {
        # generated with `caddy hash-password`
        you $2a$14$AbCdEf...
    }
}
```

The channel's request format is plain `GET /resolve?embed=...&kind=...&imdb=...&tmdb=...`. Basic auth works because `roUrlTransfer` honours `https://user:pass@host/path` (encode the password if it has special characters).

## How the channel chooses

For every Play press, `ResolveTask.brs` runs the cascade:

1. If the URL is already `.m3u8` / `.mp4`, pass it through.
2. If **In-Channel Resolver** is ON, run `R_ResolveEmbed` first. On success, use it.
3. If a **Stream Resolver URL** is set, call `<url>/resolve?embed=...`. On success, use it.
4. Last resort: regex scrape the iframe HTML for any visible `.m3u8` / `.mp4`.

So the in-channel path and the external resolver compose — turning the in-channel toggle on doesn't disable the external resolver, it just means most plays succeed before they ever hit it.

## Checking what resolved

Telnet 8085 (`telnet <roku-ip> 8085`) shows debug log lines from each resolver step. The channel logs which provider resolved the stream and which fallback layer ran. If the in-channel path is finding things directly, you'll see `R_DispatchByHost matched <provider>`; if the external resolver caught it, you'll see `resolveViaService returned ...`. If both miss, the regex scrape line is the last attempt.

## When to keep the external resolver

After the Phase 4 work, the in-channel resolver covers most providers HydraHD currently surfaces. The external resolver still earns its place when:

- A provider rolls its API and the Roku channel hasn't been re-sideloaded yet (the Python server can be edited and reloaded in seconds; the channel needs a sideload + version bump).
- You want the `/state` sync endpoint so favorites and continue-watching persist across a full uninstall (Roku registry survives "Replace existing", not full uninstall).
- A provider's HLS segments demand `Referer` and Roku's `roHttpAgent` doesn't propagate it on your specific firmware. The resolver's `/stream` proxy handles this transparently.
- You want to add a Puppeteer / Playwright handler for genuinely CF-Turnstile-gated providers that the in-channel path can't touch.

If none of these matter to you, you can run pure in-channel and forget the resolver entirely.
