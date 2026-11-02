# Core Keeper dedicated server (Coolify, vps07)

Runs the official Core Keeper dedicated server (Steam app `1963720`) in Direct Connect mode so GOG / Epic / Microsoft / Steam clients can join by `IP;PORT;;PASSWORD`.

## Why this file exists

Coolify loads a compose app's content from its Git workdir — it does not accept inline compose through the API. This repo is that workdir. The container image is pinned; the **game build is not** — the image runs SteamCMD on startup, so a restart may pick up a newer server build. Check `docker logs core-keeper-dedicated | grep "Ck1"` after any restart.

## Host layout on vps07

| Host path | Container path | Contents |
|---|---|---|
| `/srv/corekeeper/server-files` | `/home/steam/core-keeper-dedicated` | Game server install from SteamCMD (~500 MB, regenerable) |
| `/srv/corekeeper/data` | `/home/steam/core-keeper-data` | Save data root — the world files sit **directly** in it |

With `-datapath` set, the server treats the given directory as the exact save root: it reads and
writes `worlds/`, `worldinfos/`, `worldgenparams/`, `servermaps/`, `mods/`, `modloader/`,
`ServerConfig.json` and `Admins.json` in it, and does **not** append `DedicatedServer/`. (That
subdirectory is where the *Windows* build nests them under its default `LocalLow` path.) Putting the
files one level deeper makes the server log `no existing save file, starting with empty world` and
generate a fresh world, which then overwrites index `<id>` on save — the previous save survives only
as `<id>.world.gzip.pugbackup`.

World files to place under `/srv/corekeeper/data/` before the first boot:

```
worlds/<id>.world.gzip        # brotli-compressed despite the .gzip suffix
worldinfos/<id>.worldinfo
worldgenparams/<id>.json
servermaps/<id>.mapparts.gzip  # shared fog-of-war map, optional but wanted
ServerConfig.json              # world name, mode, max players
```

`<id>` must match `WORLD_ID` (default `0`). A successful load logs
`successfully loaded world file into SerializeWorld` and `World creation version is Ck130`; the
absence of that line is the signal that the layout is wrong.

## Ports

UDP `27015` published directly by Docker — Traefik does not proxy game UDP, so no Coolify FQDN is involved. The host firewall needs `27015/udp` open; the provider firewall must allow it too.

Direct Connect is enabled only by the `-port` flag, which the image sets from `SERVER_PORT`. Without it the server falls back to Steam relay and GOG clients cannot join at all.

## Environment

| Variable | Effect | Flag passed |
|---|---|---|
| `WORLD_ID` | world index | `-world` |
| `WORLD_NAME` | name shown to clients | `-worldname` |
| `SERVER_PORT` | Direct Connect port | `-port` |
| `SERVER_PASSWORD` | join password, max 28 chars | `-password` |

Values come from Coolify's environment for this app, not from this repo.

## Empty-server behaviour (measured on the Windows build, 2026-11-02)

With no players the process stays up but the simulation is paused (`timescale = 0`): no crop growth, no day/night, no mob movement. The world resumes where it stopped on the first join. Idle cost was ~1.5% of one core and ~300 MB resident after a session; a connected player pushed it to ~20% of a core and the host logged occasional 55 ms frame-budget misses.

## Mods

`DedicatedServer/mods/` is configuration only; mods load from `StreamingAssets/Mods` inside the install, which this image recreates on update. No mods are in use for world `AeTao`.

## Backups

World snapshots live off-box in B2 at `b2://nanomicon-1-projects/core-keeper/<timestamp>/` and locally at `~/para/1-projects/personal/core-keeper-backups/<timestamp>/`. Snapshot procedure: stop the container (`docker stop $(docker ps -q --filter name=core-keeper)`, up to 2 minutes for the final save), copy the whole `/srv/corekeeper/data` tree, then `b2 sync` it. Never copy while a save is in flight.

## Install / update procedure (the steamcmd trap)

SteamCMD on a host whose client is out of date spends its first invocations on the client self-update, restarts itself, and loses the `app_update` arguments. The install then fails with `Missing configuration` (or `Missing file permissions`) while the log shows repeated 41 MB self-update cycles. Both the devidian image and the plain `cm2network/steamcmd` image reproduce it, so it is steamcmd behaviour, not an image bug.

Warm the client, then install, into the bind mount:

```bash
ssh vps07 'docker run --rm -v /srv/corekeeper/server-files:/home/steam/core-keeper-dedicated \
  cm2network/steamcmd:latest bash -c "
    s=/home/steam/steamcmd/steamcmd.sh
    for i in 1 2 3; do \$s +quit > /tmp/w.\$i 2>&1; grep -q \"Update complete\" /tmp/w.\$i || break; done
    \$s +force_install_dir /home/steam/core-keeper-dedicated +login anonymous +app_update 1963720 validate +quit"' 
```

That downloads ~568 MB and leaves `CoreKeeperServer`, `_launch.sh` and `ARGUMENTS.txt` in place. To refresh the game build later, set `UPDATE_ON_START=true` and redeploy — `entrypoint.sh` performs the same warm-up itself, then flips back to `false`.

## Why this repo ships its own entrypoint

`entrypoint.sh` replaces the image's entrypoint: it performs the steamcmd warm-up above (upstream calls steamcmd exactly once), it only touches SteamCMD when `UPDATE_ON_START=true` so an ordinary restart starts the installed binary immediately, and it gives the server 60 s on `docker stop` before killing it.

The bind mount for it uses an absolute host path (`/srv/corekeeper/entrypoint.sh`) because Coolify's compose build pack copies only `docker-compose.yaml` to the host — there is no git clone in the application directory, so binding a tracked file resolves to a path that does not exist and docker substitutes an empty directory (the container then dies with exit 126, `Is a directory`). Deploy a changed entrypoint with:

```bash
curl -fsSL https://raw.githubusercontent.com/NaNomicon/core-keeper-server/main/entrypoint.sh \
  | ssh vps07 'sudo -n tee /srv/corekeeper/entrypoint.sh >/dev/null && sudo -n chmod 755 /srv/corekeeper/entrypoint.sh'
```
