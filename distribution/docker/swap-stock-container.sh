#!/usr/bin/env bash
# Replace a running stock Lidarr container with a fork build, reusing its config,
# mounts, environment, ports, network and restart policy.
#
# Run ON THE DOCKER HOST from a directory containing this script, the Dockerfile and
# the "Lidarr/" build output directory.
#
#   ./swap-stock-container.sh <stock-container-name> [fork-container-name]
#
# For a docker compose managed container prefer editing the service image in the
# compose file and running "docker compose up -d <service>" instead; this script is
# for containers started with plain docker run.
#
# What it does:
#   1. Reads the stock container's image, mounts, env, ports, network, restart policy.
#   2. Backs up lidarr.db / config.xml from the /config mount into a tarball next to it.
#   3. Builds the fork image FROM the stock image (same init, user handling, tools).
#   4. Sets the stock container's restart policy to "no" and stops it.
#   5. Starts the fork container with the stock container's settings and the same /config.
#
# Rollback: docker stop <fork>; docker update --restart=unless-stopped <stock>; docker start <stock>
# (and restore the backup tarball into /config if you want the pre-migration database back).
set -euo pipefail

STOCK="${1:?usage: $0 <stock-container-name> [fork-container-name]}"
FORK="${2:-${STOCK}-fork}"
FORK_IMAGE="lidarr-fork:$(date +%Y%m%d-%H%M)"

cd "$(dirname "$0")"
[ -d Lidarr ] || { echo "Lidarr/ build output not found next to this script" >&2; exit 1; }
docker inspect "$STOCK" >/dev/null 2>&1 || { echo "container '$STOCK' not found" >&2; exit 1; }

if docker inspect "$FORK" >/dev/null 2>&1; then
    echo "container '$FORK' already exists; remove it first (docker rm -f $FORK)" >&2
    exit 1
fi

IMAGE=$(docker inspect -f '{{.Config.Image}}' "$STOCK")
CONFIG_SRC=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{end}}{{end}}' "$STOCK")
[ -n "$CONFIG_SRC" ] || { echo "stock container has no /config mount; adjust this script" >&2; exit 1; }

if docker run --rm --entrypoint sh "$IMAGE" -c 'test -d /app/lidarr/bin' 2>/dev/null; then
    APP_DIR=/app/lidarr/bin
elif docker run --rm --entrypoint sh "$IMAGE" -c 'test -d /app/bin' 2>/dev/null; then
    APP_DIR=/app/bin
else
    echo "could not find the Lidarr app dir inside $IMAGE" >&2
    exit 1
fi

COMPOSE_PROJECT=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$STOCK" || true)
if [ -n "$COMPOSE_PROJECT" ]; then
    echo "NOTE: '$STOCK' is managed by docker compose project '$COMPOSE_PROJECT'."
    echo "      A later 'docker compose up -d' there will restart the stock container."
    echo "      To make the switch permanent, change its image to $FORK_IMAGE in that compose file."
fi

echo "Stock image:   $IMAGE"
echo "App dir:       $APP_DIR"
echo "Config mount:  $CONFIG_SRC"

# --- 2. backup ---------------------------------------------------------------
BACKUP="$(dirname "$CONFIG_SRC")/lidarr-config-backup-$(date +%Y%m%d-%H%M%S).tgz"
FILES=()
for f in lidarr.db lidarr.db-wal lidarr.db-shm config.xml; do
    [ -e "$CONFIG_SRC/$f" ] && FILES+=("$f")
done
sudo tar czf "$BACKUP" -C "$CONFIG_SRC" "${FILES[@]}" 2>/dev/null || tar czf "$BACKUP" -C "$CONFIG_SRC" "${FILES[@]}"
echo "Backup:        $BACKUP"

# --- 3. build ------------------------------------------------------------------
docker build --build-arg "BASE_IMAGE=$IMAGE" --build-arg "APP_DIR=$APP_DIR" -t "$FORK_IMAGE" .

# --- 4. reconstruct run arguments ---------------------------------------------
ARGS=(--name "$FORK" --detach)

RESTART=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$STOCK")
[ -n "$RESTART" ] && [ "$RESTART" != "no" ] && ARGS+=(--restart "$RESTART")

NETWORK=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$STOCK")
[ -n "$NETWORK" ] && ARGS+=(--network "$NETWORK")

while IFS= read -r line; do
    [ -n "$line" ] && ARGS+=(-p "$line")
done < <(docker inspect -f '{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{if .HostIp}}{{.HostIp}}:{{end}}{{.HostPort}}:{{$p}}{{"\n"}}{{end}}{{end}}' "$STOCK")

while IFS= read -r line; do
    [ -n "$line" ] && ARGS+=(-v "$line")
done < <(docker inspect -f '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}:{{.Destination}}{{if not .RW}}:ro{{end}}{{"\n"}}{{end}}{{if eq .Type "volume"}}{{.Name}}:{{.Destination}}{{if not .RW}}:ro{{end}}{{"\n"}}{{end}}{{end}}' "$STOCK")

while IFS= read -r line; do
    [ -n "$line" ] && ARGS+=(-e "$line")
done < <(docker inspect -f '{{range .Config.Env}}{{.}}{{"\n"}}{{end}}' "$STOCK")

while IFS= read -r line; do
    [ -n "$line" ] && ARGS+=(--device "$line")
done < <(docker inspect -f '{{range .HostConfig.Devices}}{{.PathOnHost}}:{{.PathInContainer}}{{"\n"}}{{end}}' "$STOCK")

USER_SPEC=$(docker inspect -f '{{.Config.User}}' "$STOCK")
[ -n "$USER_SPEC" ] && ARGS+=(--user "$USER_SPEC")

echo "docker run ${ARGS[*]} $FORK_IMAGE"

# --- 5. switch -------------------------------------------------------------------
docker update --restart=no "$STOCK" >/dev/null
docker stop "$STOCK"
docker run "${ARGS[@]}" "$FORK_IMAGE"

echo
echo "Fork container '$FORK' started from $FORK_IMAGE. Stock container '$STOCK' is stopped with restart disabled."
echo "Follow logs with: docker logs -f $FORK"
