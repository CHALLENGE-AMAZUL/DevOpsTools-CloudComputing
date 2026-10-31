#!/usr/bin/env bash
set -Eeuo pipefail
cd /opt/amazul-java
COMMIT="$(python3 -c 'import json; print(json.load(open("source.json"))["commit"])')"
[[ "$COMMIT" =~ ^[a-f0-9]{40}$ ]]
docker build --pull --label "org.opencontainers.image.revision=$COMMIT" -t amazul-api:s1 .
docker rm -f amazul-api >/dev/null 2>&1 || true
docker run -d --name amazul-api --restart unless-stopped --env-file api.env \
  --read-only --tmpfs /tmp:rw,noexec,nosuid,size=128m --cap-drop ALL \
  --security-opt no-new-privileges --pids-limit 256 --memory 640m --cpus 1 \
  -p 8080:8080 amazul-api:s1
for ((i=0;i<90;i++)); do
  [[ "$(docker inspect --format '{{.State.Health.Status}}' amazul-api)" == healthy ]] && break
  [[ "$(docker inspect --format '{{.State.Running}}' amazul-api)" == true ]] || { docker logs --tail 30 amazul-api; exit 1; }
  sleep 2
done
[[ "$(docker inspect --format '{{.State.Health.Status}}' amazul-api)" == healthy ]]
python3 scripts/verificar.py http://127.0.0.1:8080 api.env
