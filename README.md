# bye-bye-gfw

Idempotent bash scripts to deploy a personal anti-GFW proxy stack on a fresh
Ubuntu 22.04 VPS. Single command, no panel UI, no Hiddify, no Docker — just
Xray + Hysteria2 + Caddy with a generated subscription URL.

Designed for 1–3 personal users with a domain on Cloudflare. Tested on DMIT
LAX.AN5.Pro.TINY (1 vCPU / 2 GB / 20 GB / Cogent AS9929 + 4837), should work
on any reasonable VPS.

## What you get

Three independent inbounds, all listening at the same time so any one being
blocked doesn't take you offline:

| Protocol | Server | Port | Notes |
|---|---|---|---|
| VLESS + XTLS-Vision + REALITY | VPS IP | 443/tcp | mimics TLS handshake to a real CDN site, no cert needed |
| Hysteria2 + Salamander | `hy2.<domain>` | 443/udp + 20000–29999/udp hopping | Let's Encrypt via Cloudflare DNS-01, Brutal CC |
| VLESS + WebSocket + TLS | `cdn.<domain>` | 2087/tcp via Cloudflare proxy | self-signed origin cert, CF SSL "Full" |

Plus:
- **Cloudflare WARP outbound** for streaming (Netflix, Disney+, HBO, OpenAI,
  Anthropic) — bypasses datacenter-IP blocks.
- **Routing rules** — `geosite:cn` direct, `geosite:category-ads-all` blocked,
  outbound `geoip:cn` blocked (anti-reflection).
- **Subscription URL with UA detection** — paste one URL into Shadowrocket /
  Clash Verge Rev / Hiddify Next, get the right config format automatically.

## Quick start

On a fresh Ubuntu 22.04 VPS, as root:

```bash
apt update && apt install -y git
git clone git@github.com:charlespolart/bye-bye-gfw.git
cd bye-bye-gfw
cp config.env.example config.env
vim config.env       # fill in DOMAIN, VPS_IPV4/IPV6, CLOUDFLARE_API_TOKEN
sudo ./bootstrap.sh all
```

That's it. About 5 minutes end-to-end. The script prints your subscription URL
at the end. Copy it into your client and you're connected.

To run a single phase: `sudo ./bootstrap.sh 4` (replace 4 with the phase
number). Re-running any phase is safe — everything is idempotent.

## Requirements

- **VPS**: Ubuntu 22.04 LTS specifically (Python 3.10 default; 24.04+ has 3.12
  which Hiddify-Manager needs but we don't use Hiddify, so 24.04 *might* work
  — not tested).
- **Domain on Cloudflare DNS** with a Cloudflare API token scoped to it
  (Zone:DNS:Edit). Phase 2 creates the records via API.
- **Open ports**: 80/tcp, 443/tcp, 443/udp, 2087/tcp, 8443/tcp,
  20000–29999/udp, plus the SSH custom port (default 52217).
- **RAM ≥ 1 GB**, **disk ≥ 5 GB free**.

## Phases

| # | What | Idempotent | Needs |
|---|---|---|---|
| 1 | system hardening, deploy user, SSH custom port, UFW, fail2ban, BBR | yes | root |
| 2 | DNS records via Cloudflare API + dig verification | yes | CF API token |
| 3 | install Xray + Hysteria2 + Caddy, generate REALITY keypair | yes | root |
| 4 | write the 3 inbound configs, iptables NAT for HY2 hopping, start services | yes | phase 3 done |
| 5 | wgcf + WARP WireGuard outbound, streaming routing rules | yes | phase 4 done |
| 6 | (folded into 4 + 5) | — | — |
| 7 | Caddy on 8443 with UA detection, generate Clash YAML + v2ray base64, ACME via HTTP-01 | yes | phase 4 done |
| 8 | external monitoring (Uptime Kuma) — *not implemented*, optional | — | — |
| 9 | validation tests (services, ports, REALITY camouflage, NAT, BBR, speedtest) | yes | all phases |
| 10 | generate `/root/DEPLOYMENT_NOTES.md` with secrets + ops procedures | yes | phase 4+ |

## Architecture (port map)

```
                 ╭──────────────── client ──────────────╮
                 │  Shadowrocket / Clash Verge Rev / …  │
                 ╰──────────────────────────────────────╯
                              │
       ┌─────── REALITY ──────┼────── Hysteria2 ───────┬─── CDN ───┐
       │ (TCP/443, SNI=Tesla) │ (UDP/443, hopping)     │ (TCP/443) │
       │                      │                        │  via CF   │
   154.17.22.241:443/tcp  154.17.22.241:443/udp        │           │
                                                       │   ┌───────┴──────┐
                                                       └─→ │ Cloudflare   │ → 154.17.22.241:2087
                                                           │ orange-cloud │       │
                                                           └──────────────┘       ▼
                                                                          Caddy /WS_PATH → 127.0.0.1:9100
                                                                                                   │
                                                                                                   ▼
                                                                                                Xray VLESS+WS

                 sub.<domain>:8443  ←  Caddy (auto-LE)  ←  /<token>/ (UA-detected)
                 cdn.<domain>:2087  ←  Caddy (origin self-signed for "Full" SSL)
                 hy2.<domain>       ←  Hysteria2 (auto-LE via CF DNS-01, UDP only)
```

Outbound from Xray:
- streaming (Netflix/Disney/HBO/OpenAI/Anthropic) → WARP via wgcf
- everything else → direct egress on VPS IP
- `geosite:cn` → direct (DNS direct too, faster for Chinese sites)
- `geosite:category-ads-all` → block

## File layout

```
bye-bye-gfw/
├── README.md                  ← you are here
├── bootstrap.sh               ← entrypoint, dispatches phases
├── config.env.example         ← template
├── config.env                 ← gitignored, your values
├── lib/
│   └── common.sh              ← log, write_file, state_mark, ensure_pkg
├── scripts/
│   ├── 01-hardening.sh
│   ├── 02-dns-check.sh
│   ├── 03-stack-install.sh
│   ├── 04-inbounds.sh
│   ├── 05-warp-outbound.sh
│   ├── 07-subscription.sh
│   ├── 09-tests.sh
│   └── 10-finalize-docs.sh
└── notes/                     ← gitignored
    └── DEPLOYMENT_NOTES.md    ← generated by phase 10, has all secrets
```

On the deployed VPS:
```
/usr/local/bin/{xray,hysteria,caddy,wgcf}      binaries
/etc/xray/configs.d/                           Xray config (one file per concern)
/etc/hysteria/config.yaml                      Hysteria2
/etc/caddy/Caddyfile                           Caddy
/etc/caddy/origin/cdn.{crt,key}                self-signed CDN origin cert
/etc/wgcf/                                     WARP account + profile
/etc/bye-bye-gfw/                              secrets, mode 600
/var/www/sub/<token>/                          generated sub configs
/var/lib/bye-bye-gfw/state                     phase completion markers
/root/DEPLOYMENT_NOTES.md                      ops doc (mode 600)
```

## Operations cheat-sheet

```bash
# service status
sudo systemctl status xray hysteria-server caddy

# tail logs
sudo journalctl -u xray -f
sudo journalctl -u hysteria-server -f
sudo journalctl -u caddy -f

# validate configs without restarting
sudo /usr/local/bin/xray run -confdir /etc/xray/configs.d -test
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

# regenerate sub configs (after rotating user UUID etc)
sudo ./bootstrap.sh 7

# regenerate DEPLOYMENT_NOTES
sudo ./bootstrap.sh 10

# pull notes to local
scp -P 52217 deploy@<vps>:/root/DEPLOYMENT_NOTES.md ~/Downloads/

# backup all configs to a tarball
sudo tar -czf /root/bye-bye-gfw-$(date +%F).tar.gz \
  /etc/bye-bye-gfw /etc/wgcf /etc/xray/configs.d \
  /etc/hysteria/config.yaml /etc/caddy /var/www/sub
```

## IP gets blacklisted from China — what now

The GFW typically blacklists the IP, not the protocol. Mitigations in order:

1. **Quick** — switch your client's proxy-group to `CDN-LAX` only. CF IPs
   aren't blocked. Your REALITY/HY2 inbounds stay broken until step 2.
2. **Permanent** — provision a new VPS, redeploy:
   ```bash
   git clone <repo>     # on new VPS
   cd bye-bye-gfw
   cp config.env.example config.env  &&  vim config.env  # new IP
   sudo ./bootstrap.sh all
   ```
3. Update DNS — phase 2 talks to the Cloudflare API and updates A/AAAA in place.

## Sensitive periods (lockdown windows)

The GFW tightens during these. If REALITY/HY2 misbehave, switch clients to the
CDN inbound only.

| Approx. date | Event |
|---|---|
| March 5–15 | Two Sessions (NPC + CPPCC) |
| June 4 | Tiananmen anniversary |
| October 1 | National Day |
| Mid-November | Plenum / Party meetings |

## Known issues / notes

- **Ubuntu 22.04 specifically.** Debian 12 doesn't work for Hiddify (which we
  don't use anymore), and the install scripts here happen to also assume some
  Ubuntu paths. 24.04 is untested.
- **Cloudflare zone SSL must be "Full"** (not "Flexible", not "Off"). The CDN
  inbound uses a self-signed origin cert. To upgrade to a real cert: rebuild
  Caddy with `xcaddy --with github.com/caddy-dns/cloudflare` and switch to
  `acme_dns cloudflare`.
- **Sub URL on port 8443**, not 443. Xray REALITY owns 443/tcp. The port is in
  Cloudflare's HTTPS-proxy allowlist if you ever want to put `sub.` behind CF.
- **Don't run other web services on this VPS.** Caddy/Xray/Hysteria assume they
  own the box.
- **Phase numbers skip 6 and 8** because phase 6 is folded into 4 and 5, and
  phase 8 (external monitoring) is optional and intentionally not implemented
  (deploy Uptime Kuma yourself on a separate host if you want alerts).

## License

Personal project, no license declared. Fork/copy if useful, no warranty.
