# EveJS Multiplayer / Remote Host

Run the server on one PC and let friends join with a one-click client script.

This is intended for **trusted LAN / private internet play with friends**, not a hardened public shard.

## What changed for multiplayer

| Area | Behavior |
|------|----------|
| Same-account sessions | Selecting a character evicts any other live session on that account (avoids `clientID` collision) |
| Listeners | Host setup binds game / image / proxy / XMPP to `0.0.0.0` |
| Advertised URLs | Host setup rewrites `gameServerHost`, image URL, proxy URLs, and `xmppConnectHost` to your LAN/public IP |
| Auth defaults | Auto-create accounts **on**, password skip **off** |
| Login population | Login screen `cluster_usercount` uses live session count |
| Friend online status | Watchlist/friend online checks are one-way (not mutual-only) |
| PlayerConnect | Token-gated `/playerconnect/health` + `/playerconnect/ca.pem` on the proxy port |

## Host PC (you)

### Requirements

- Windows
- Node.js LTS
- This EveJS repo fully set up once (`npm ci`, local database, certificates)
- Optional: Windows Firewall allow for TCP `26000`, `26001`, `26002`, `5222`

### One-click host

Double-click:

```text
Server.bat
```

Optional explicit IP:

```text
Server.bat 192.168.1.10
```

It will:

1. Detect your LAN IP (or use the IP you passed)
2. Rewrite `evejs.config.local.json` for remote clients
3. Export `_local\player-connect-bundle\` for friends
4. Try to open Windows Firewall ports
5. Ensure local database + npm deps
6. Start the server (server-only, no menu)

(`StartMultiplayerHost.bat` is the older interactive variant.)

### Manual host configure only

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\PlayerConnect\ConfigureMultiplayerHost.ps1 -HostAddress auto -OpenFirewall
```

Or:

```powershell
node tools\PlayerConnect\configure-multiplayer-host.js --host 192.168.1.10
```

Then restart / start the server:

```text
StartServer.bat
```

### Give this to friends

Copy the whole folder:

```text
_local\player-connect-bundle\
```

It contains:

- `Connect.bat` / `Connect.ps1` — one-click join
- `server.json` — host, ports, token
- `ca.pem` — EveJS CA certificate
- `README.txt`
- optional `tools\blue_dll_patch.ps1` assets

Do **not** post that folder publicly; it includes the PlayerConnect token.

### Internet (not just LAN)

1. Use your public IP or a dynamic DNS hostname as `--host`
2. Port-forward TCP `26000`, `26001`, `26002`, `5222` on your router to the host PC
3. Prefer a VPN (ZeroTier / Tailscale / WireGuard) instead of exposing ports to the whole internet

## Friend PC

### Requirements

- Windows
- A **copied** EVE client for **build 3396210** (full shared cache: `EVE\tq`, `ResFiles`, `index_tranquility.txt`)
- Do **not** patch the same install used for live Tranquility

### One-click join

1. Receive the `player-connect-bundle` folder
2. Double-click **`Client.bat`** (or `Connect.bat`)
3. First run: pick the client `tq` folder  
   Optional: `Client.bat "D:\Games\EVE-Copy\EVE\tq"`
4. Script installs the CA, points `start.ini` at the host, patches `blue.dll` when possible, health-checks the host, then launches the game
5. Log in with any username/password  
   - First login creates the account when the host left auto-create enabled  
   - Password is required after that (`devSkipPasswordValidation` is off)

## Ports

| Port | Service |
|------|---------|
| 26000 | Game TCP |
| 26001 | Image HTTP |
| 26002 | Proxy / microservices / PlayerConnect |
| 5222 | XMPP chat |

## Revert to localhost-only

```powershell
node tools\PlayerConnect\configure-multiplayer-host.js --localhost-only --skip-bundle
```

Then restart the server and re-run ClientSETUP Step 5 if your local `start.ini` still points at the old LAN IP.

## Security notes

- This is still an emulator for friends, not production CCP security
- Keep `devSkipPasswordValidation` **false** on a shared host
- `devAutoCreateAccounts` is convenient for friends; turn it off if you want invite-only accounts
- Rotate `playerConnectToken` if a bundle leaks
- Prefer VPN over open internet port forwards

## Related

- [SETUP.md](SETUP.md)
- [LAUNCHERS.md](LAUNCHERS.md)
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
