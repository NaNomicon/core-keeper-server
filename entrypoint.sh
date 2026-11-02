#!/bin/bash
# Core Keeper dedicated server entrypoint, replacing the one shipped in the
# devidian image. Reasons:
#
# 1. The upstream entrypoint calls steamcmd exactly once. On a machine whose
#    steamcmd client is out of date, that invocation spends itself on the client
#    self-update ("Update complete, launching Steamcmd..."), restarts, and loses
#    the app_update arguments — the install then fails with "Missing
#    configuration" and the container crash-loops. Warm the client, then install.
# 2. Restarts must not re-download the 568 MB server. Files are pre-installed in
#    the bind-mounted STEAM_APP_DIR; updates are opt-in via UPDATE_ON_START.
# 3. The game writes its log to a file in the install dir; the host needs to see
#    it in `docker logs`, and the join string in GameInfo.txt is worth printing.
#
# Only flags listed in the image's ARGUMENTS.txt are passed; there is no
# -worldsize. -worldmode takes a name (Normal|Hard|Creative|Casual), not a number.
set -uo pipefail

log() { echo "[ck-entrypoint] $*"; }

if [[ "${DATA_PATH}" != /* || "${DATA_PATH}" == / ]]; then
	log "DATA_PATH must be an absolute directory path (without literal quotation marks)."
	exit 1
fi
mkdir -p "$DATA_PATH" || exit 1
[[ -w "$DATA_PATH" ]] || { log "DATA_PATH is not writable: $DATA_PATH"; exit 1; }

if [[ "${UPDATE_ON_START:-false}" == "true" ]]; then
	log "warming steamcmd client before app update"
	for _ in 1 2 3; do
		"${STEAMCMDDIR}/steamcmd.sh" +quit >/tmp/ck-warm.log 2>&1 || true
		grep -q "Update complete" /tmp/ck-warm.log || break
	done
	log "installing app ${STEAM_APP_ID}"
	"${STEAMCMDDIR}/steamcmd.sh" \
		+force_install_dir "$STEAM_APP_DIR" \
		+login anonymous \
		+app_update "$STEAM_APP_ID" validate \
		+quit || log "steamcmd update failed; continuing with installed files"
fi

exepath="$STEAM_APP_DIR/CoreKeeperServer"
[[ -x "$exepath" ]] || { log "no server executable at $exepath — set UPDATE_ON_START=true or pre-install the app"; exit 1; }

server_args=(-batchmode -logfile CoreKeeperServerLog.txt)
[[ -n "${SERVER_PORT:-}" ]] && server_args+=(-port "$SERVER_PORT")
[[ -n "${MAX_PLAYERS:-}" ]] && server_args+=(-maxplayers "$MAX_PLAYERS")
[[ -n "${SERVER_PASSWORD:-}" ]] && server_args+=(-password "$SERVER_PASSWORD")
[[ -n "${WORLD_SEED:-}" ]] && server_args+=(-worldseed "$WORLD_SEED")
[[ -n "${WORLD_MODE:-}" ]] && server_args+=(-worldmode "$WORLD_MODE")
server_args+=(-datapath "$DATA_PATH" -worldname "${WORLD_NAME:-AeTao}" -world "${WORLD_ID:-0}")

for pkg in libxi6 xvfb; do
	dpkg -s "$pkg" >/dev/null 2>&1 || {
		log "installing missing package: $pkg"
		apt-get update -yy >/dev/null && apt-get install -yy "$pkg" >/dev/null
	}
done

rm -f /tmp/.X99-lock "$STEAM_APP_DIR/GameInfo.txt"
Xvfb :99 -screen 0 1x1x24 -nolisten tcp &
xvfbpid=$!

chmod +x "$exepath"
cd "$STEAM_APP_DIR" || exit 1
DISPLAY=:99 LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}:$STEAM_APP_DIR/linux64/" "$exepath" "${server_args[@]}" "$@" &
ckpid=$!
log "server pid $ckpid, port ${SERVER_PORT:-unset}, world ${WORLD_ID:-0} (${WORLD_NAME:-unset})"

tail -n +1 -F CoreKeeperServerLog.txt 2>/dev/null &
tailpid=$!

shutdown() {
	log "stop requested; giving the server 60s to save"
	kill -TERM "$ckpid" 2>/dev/null
	for _ in $(seq 1 60); do
		kill -0 "$ckpid" 2>/dev/null || break
		sleep 1
	done
	kill -KILL "$ckpid" 2>/dev/null
	kill "$tailpid" "$xvfbpid" 2>/dev/null
	wait 2>/dev/null
	exit 0
}
trap shutdown TERM INT

joined=""
while kill -0 "$ckpid" 2>/dev/null; do
	if [[ -z "$joined" && -f GameInfo.txt ]]; then
		joined=1
		log "JOIN STRING: $(cat GameInfo.txt)"
	fi
	sleep 1
done

status=0
wait "$ckpid" || status=$?
kill "$tailpid" "$xvfbpid" 2>/dev/null
log "server exited with status $status"
exit "$status"
