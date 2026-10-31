#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/config.example.env"
[[ ! -f "$ROOT/.local/config.env" ]] || source "$ROOT/.local/config.env"
[[ "$BACKEND_REF" =~ ^[a-f0-9]{40}$ ]] || { echo 'BACKEND_REF deve ser um commit completo.'; exit 1; }
mkdir -p "$ROOT/.local/backend-repo" "$ROOT/.local/backend" "$ROOT/.local/evidence"
git -C "$ROOT/.local/backend-repo" init -q
git -C "$ROOT/.local/backend-repo" fetch -q --depth 1 "$BACKEND_REPOSITORY" "$BACKEND_REF"
[[ "$(git -C "$ROOT/.local/backend-repo" rev-parse FETCH_HEAD)" == "$BACKEND_REF" ]]
git -C "$ROOT/.local/backend-repo" archive FETCH_HEAD | tar -x -C "$ROOT/.local/backend"
cmp "$ROOT/Dockerfile" "$ROOT/.local/backend/Dockerfile"
python3 - "$BACKEND_REPOSITORY" "$BACKEND_REF" "$ROOT/.local/evidence/source.json" <<'SOURCE'
import json,sys
from pathlib import Path
Path(sys.argv[3]).write_text(json.dumps(dict(repository=sys.argv[1],commit=sys.argv[2]),indent=2)+'\n')
SOURCE
echo "Backend preparado: $BACKEND_REF"
