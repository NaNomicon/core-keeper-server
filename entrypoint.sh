#!/bin/bash
# Core Keeper dedicated server entrypoint, replacing the one shipped in the
# devidian image. Two reasons this exists:
#
# 1. The upstream entrypoint calls steamcmd exactly once. On a machine whose
#    steamcmd client is out of date, that invocation spends itself on the
#    client self-update ("Update complete, launching Steamcmd..."), restarts,
#    and loses the app_update arguments — the install then fails with
#    "Missing configuration" and the container loops. Warming the client and
#    then installing in a second invocation fixes it.
# 2. Restarts should not re-download the server. Server files are pre-installed
#    into the bind-mounted STEAM_APP_DIR; updates are opt-in.
set -uo pipefail

export LD_LIBRARY_PATH="${STEAM_APP_DIR}/linux64:$LD_LIBRARY_PATH:../Steamworks SDK Redist/linux64/"

log() { echo "[ck-entrypoint] $*" >&2; }

if [[ "${DATA_PATH}" != /* || "${DATA_PATH}" == / ]]; then
	echo "[ck-entrypoint] DATA_PATH must be an absolute directory path (without literal quotation marks)." >&2
	exit 1
fi

mkdir -p "$DATA_PATH" || exit 1
if [[ ! -w "$DATA_PATH" ]]; then
	echo "[ck-entrypoint] DATA_PATH is not writable: $DATA_PATH" >&2
	exit 1
fi

if [[ "${UPDATE_ON_START:-false}" == "true" ]]; then
	log "warming steamcmd client before app update"
	"${STEAMCMDDIR}/steamcmd.sh" +quit >/dev/null 2>&1 || log "client warm-up returned non-zero; continuing"
	log "installing app ${STEAM_APP_ID}"
	"${STEAMCMDDIR}/steamcmd.sh" \
		+force_install_dir "$STEAM_APP_DIR" \
		+login anonymous \
		+app_update "$STEAM_APP_ID" validate \
		+quit || log "steamcmd update failed; continuing with installed files"
fi

exepath="$STEAM_APP_DIR/CoreKeeperServer"
if [[ ! -x "$exepath" ]]; then
	echo "[ck-entrypoint] no server executable at $exepath — set UPDATE_ON_START=true or install the app first" >&2
	exit 1
fi

server_args=(-batchmode -logfile /proc/self/fd/1)
[[ -n "${SERVER_PORT:-}" ]] && server_args+=(-port "$SERVER_PORT")
[[ -n "${MAX_PLAYERS:-}" ]] && server_args+=(-maxplayers "$MAX_PLAYERS")
[[ -n "${SERVER_PASSWORD:-}" ]] && server_args+=(-password "$SERVER_PASSWORD")
[[ -n "${WORLD_SEED:-}" ]] && server_args+=(-worldseed "$WORLD_SEED")
[[ -n "${WORLD_MODE:-}" ]] && server_args+=(-worldmode "$WORLD_MODE")
[[ -n "${WORLD_SIZE:-}" ]] && server_args+=(-worldsize "$WORLD_SIZE")
server_args+=(-datapath "$DATA_PATH" -worldname "${WORLD_NAME:-AeTao}" -world "${WORLD_ID:-0}")

for pkg in libxi6 xvfb; do
	if ! dpkg -s "$pkg" >/dev/null 2>&1; then
		log "installing missing package: $pkg"
		apt-get update -yy >/dev/null && apt-get install -yy "$pkg" >/dev/null
	fi
done

rm -f /tmp/.X99-lock
Xvfb :99 -screen 0 1x1x24 -nolisten tcp &
xvfbpid=$!

chmod +x "$exepath"
DISPLAY=:99 "$exepath" "${server_args[@]}" "$@" &
ckpid=$!
log "server pid $ckpid, port ${SERVER_PORT:-unset}, world ${WORLD_ID:-0} (${WORLD_NAME:-unset})"

# Let the server run its own shutdown save before we take it down hard.
shutdown() {
	log "stop requested; giving the server 60s to save"
	kill -TERM "$ckpid" 2>/dev/null
	for _ in $(seq 1 60); do
		kill -0 "$ckpid" 2>/dev/null || break
		sleep 1
	done
	kill -KILL "$ckpid" 2>/dev/null
	kill "$xvfbpid" 2>/dev/null
	wait 2>/dev/null
	exit 0
}
trap shutdown TERM INT

wait "$ckpid"
status=$?
kill "$xvfbpid" 2>/dev/null
exit "$status"
