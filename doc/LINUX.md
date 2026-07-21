# EveJS on Linux (public VPS)

Trusted friends-only host. Not a hardened public shard.

## Requirements

- Linux x64 (Ubuntu 22.04+ recommended)
- Node.js **20+ LTS** and npm
- Build tools for `better-sqlite3`: `build-essential`, `python3`
- Optional: `curl` or `wget`, `unzip`
- Open **TCP** `26000`, `26001`, `26002`, `5222` (security group + host firewall)

```bash
# Ubuntu / Debian example
sudo apt update
sudo apt install -y nodejs npm build-essential python3 curl unzip
# Prefer Node 20+ from NodeSource if distro node is too old
```

## One-shot start

From the repo root:

```bash
chmod +x Server.sh tools/DatabaseCreator/CreateDatabase.sh
./Server.sh YOUR_PUBLIC_IP_OR_DDNS
```

Examples:

```bash
./Server.sh 106.15.44.81
./Server.sh play.example.com
./Server.sh --host 106.15.44.81 --token mySecret --open-firewall
./Server.sh --skip-config   # already configured; only DB + npm + start
```

What it does (same idea as `Server.bat`):

1. `configure-multiplayer-host.js` — bind `0.0.0.0`, advertise your host, write PlayerConnect bundle  
2. Optional firewall (`--open-firewall`)  
3. Generate `_local/gameStore` if missing (`CreateDatabase.sh`)  
4. `npm ci` in `server/` if needed  
5. `export EVEJS_GAMESTORE_DATA_DIR=.../_local/gameStore/data` and `npm start`

## Verify

In the server log you must see:

```text
[SpaceWorld] Loaded ... stations
```

with **stations count much greater than 0**. If you see `0 stations`, the static DB path is wrong or generation failed.

## Friend clients

Still Windows clients today. Copy:

```text
_local/player-connect-bundle/
```

to friends (includes `server.json`, `ca.pem`, `Connect.bat`).

## Database only

```bash
./tools/DatabaseCreator/CreateDatabase.sh
./tools/DatabaseCreator/CreateDatabase.sh --force   # rebuild
```

## Run under systemd (optional)

```ini
# /etc/systemd/system/evejs.service
[Unit]
Description=EveJS multiplayer server
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/evejs/server
Environment=EVEJS_PROXY_LOCAL_INTERCEPT=1
Environment=EVEJS_GAMESTORE_DATA_DIR=/opt/evejs/_local/gameStore/data
ExecStart=/usr/bin/npm start
Restart=on-failure
User=evejs

[Install]
WantedBy=multi-user.target
```

Configure once with `./Server.sh --host ...` (or the node configure script), then enable the unit.

## FRP note

If the VPS **is** the public endpoint, you usually **do not** need FRP — open the four TCP ports on the VPS and set `--host` to the VPS public IP/DNS.

Use FRP only when the game process sits on a machine without a public IP.
