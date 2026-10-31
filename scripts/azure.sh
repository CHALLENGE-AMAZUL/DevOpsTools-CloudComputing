#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:-plan}"
case "$ACTION" in plan|create|deploy|check|destroy) ;; *) echo 'Uso: azure.sh [plan|create|deploy|check|destroy]'; exit 2;; esac
if [[ "$ACTION" == plan ]]; then
  echo 'Plano: RG dedicado, Ubuntu 22.04, VM, VNet/subnet, NIC, NSG e IP público Standard.'
  echo 'HTTP 8080 publico; SSH 22 restrito ao IPv4 /32 do operador.'
  echo 'Fluxo: create -> deploy -> check -> gravar evidências -> destroy. Sem Azure neste modo.'
  exit 0
fi
for cmd in az python3 ssh scp tar curl git; do command -v "$cmd" >/dev/null || { echo "Instale $cmd"; exit 1; }; done
CONFIG="$ROOT/.local/config.env"
mkdir -p "$ROOT/.local"
[[ -f "$CONFIG" ]] || cp "$ROOT/config.example.env" "$CONFIG"
# Arquivo de configuração local confiável; nunca carregar arquivos recebidos de terceiros.
source "$ROOT/config.example.env"
source "$CONFIG"
: "${SUBSCRIPTION_ID:?}" "${RESOURCE_GROUP:?}" "${LOCATION:?}" "${VM_SIZE:?}" "${VM_NAME:?}" "${ADMIN_USER:?}" "${SSH_KEY:?}"
python3 - "$SUBSCRIPTION_ID" "$RESOURCE_GROUP" "$VM_NAME" "$ADMIN_USER" <<'CHECK'
import re,sys,uuid
uuid.UUID(sys.argv[1])
assert re.fullmatch(r'rg-amazul-[a-z0-9-]+',sys.argv[2]), 'RG deve começar com rg-amazul-'
for value in sys.argv[3:5]: assert re.fullmatch(r'[a-z][a-z0-9-]{1,40}',value)
CHECK
if ! az account show --subscription "$SUBSCRIPTION_ID" >/dev/null 2>&1; then
  AZURE_CORE_LOGIN_EXPERIENCE_V2=off az login --use-device-code --output none
fi
az account show --subscription "$SUBSCRIPTION_ID" --query '{name:name,id:id}' -o table
# Todas as operações fixam assinatura; não alteramos o default global do usuário.
azc() { az "$@" --subscription "$SUBSCRIPTION_ID"; }
mkdir -p "$ROOT/.local/evidence"
chmod 700 "$ROOT/.local"
LOG="$ROOT/.local/evidence/$(date -u +%Y%m%dT%H%M%SZ)-$ACTION.log"
exec > >(tee -a "$LOG") 2>&1
trap 'echo "FALHA na linha $LINENO. Recursos podem permanecer; corrija ou execute destroy."' ERR
STATE="$ROOT/.local/run-id"
if [[ "$ACTION" == create && ! -f "$STATE" ]]; then python3 -c 'import uuid; print(uuid.uuid4())' > "$STATE"; fi
[[ -f "$STATE" ]] || { echo 'Identificação local ausente; não operar sobre RG sem comprovante de propriedade.'; exit 1; }
RUN_ID="$(cat "$STATE")"
exists() { azc group exists --name "$RESOURCE_GROUP" -o tsv; }
owned() {
 [[ "$(azc group show -n "$RESOURCE_GROUP" --query tags.amazulRun -o tsv)" == "$RUN_ID" ]] || { echo 'RG pertence a outra execução. Operação recusada.'; exit 1; }
}
if [[ "$ACTION" == create ]]; then
  ALLOWED_CIDR="$(curl -4 --noproxy '*' -fsS --connect-timeout 10 --max-time 20 "https://api.ipify.org?nonce=$(date +%s)")/32"
  python3 -c 'import ipaddress,sys; n=ipaddress.ip_network(sys.argv[1]); assert n.version==4 and n.prefixlen==32' "$ALLOWED_CIDR"
  if [[ ! -e "$SSH_KEY" && ! -e "$SSH_KEY.pub" ]]; then
    mkdir -p "$(dirname "$SSH_KEY")"
    ssh-keygen -q -t ed25519 -N '' -f "$SSH_KEY" -C amazul-s1
  fi
  [[ -f "$SSH_KEY.pub" && -f "$SSH_KEY" ]] || { echo 'Par de chave SSH incompleto.'; exit 1; }
  if [[ "$(exists)" == true ]]; then owned; else
    for record in destroy.json vm.json runtime.txt source.json; do
      if [[ -f "$ROOT/.local/evidence/$record" ]]; then
        mv "$ROOT/.local/evidence/$record" "$ROOT/.local/evidence/$record.$(date -u +%Y%m%dT%H%M%SZ)"
      fi
    done
    azc group create -n "$RESOURCE_GROUP" -l "$LOCATION" --tags project=amazul sprint=1 amazulRun="$RUN_ID" -o json
  fi
  # Reexecução após falha reaproveita somente este RG. Não usar RG com recursos de outras atividades.
  if ! azc vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" >/dev/null 2>&1; then
    azc vm create -g "$RESOURCE_GROUP" -n "$VM_NAME" -l "$LOCATION" \
      --image Ubuntu2204 --size "$VM_SIZE" --admin-username "$ADMIN_USER" \
      --authentication-type ssh --ssh-key-values "$SSH_KEY.pub" \
      --vnet-name vnet-amazul --vnet-address-prefix 10.42.0.0/16 \
      --subnet subnet-app --subnet-address-prefix 10.42.1.0/24 \
      --nsg nsg-amazul --nsg-rule NONE --public-ip-address pip-amazul --public-ip-sku Standard \
      --storage-sku Standard_LRS --os-disk-size-gb 30 --os-disk-delete-option Delete --nic-delete-option Delete -o json
  fi
  for port in 22 8080; do
    SOURCE="$ALLOWED_CIDR"
    [[ "$port" == 8080 ]] && SOURCE=Internet
    azc network nsg rule create -g "$RESOURCE_GROUP" --nsg-name nsg-amazul \
      -n "allow-$port" --priority "$((port == 22 ? 1000 : 1010))" --direction Inbound --access Allow \
      --protocol Tcp --source-address-prefixes "$SOURCE" --source-port-ranges '*' \
      --destination-address-prefixes '*' --destination-port-ranges "$port" -o json
  done
  azc vm show -d -g "$RESOURCE_GROUP" -n "$VM_NAME" -o json > "$ROOT/.local/evidence/vm.json"
  echo 'Provisionamento concluído. Próximo: deploy.'
  exit 0
fi
if [[ "$(exists)" == false ]]; then
  if [[ "$ACTION" == destroy ]]; then echo 'Resource group ausente.'; else echo 'RG ausente'; exit 1; fi
else
  owned
  if [[ "$ACTION" == destroy ]]; then
    [[ "${CONFIRM_DESTROY:-}" == "$RESOURCE_GROUP" ]] || { echo "Defina CONFIRM_DESTROY=$RESOURCE_GROUP para apagar este RG inteiro."; exit 1; }
    azc resource list -g "$RESOURCE_GROUP" --query '[].{name:name,type:type}' -o table
    azc group delete -n "$RESOURCE_GROUP" --yes --no-wait
    for ((i=0;i<120;i++)); do
      [[ "$(exists)" == false ]] && break
      sleep 10
    done
    [[ "$(exists)" == false ]] || { echo 'Exclusão ainda pendente. Reexecute destroy para conferir.'; exit 1; }
  fi
fi
if [[ "$ACTION" == destroy ]]; then
  python3 - "$SUBSCRIPTION_ID" "$RESOURCE_GROUP" "$RUN_ID" > "$ROOT/.local/evidence/destroy.json" <<'PROOF'
import json,sys,datetime
print(json.dumps(dict(subscription=sys.argv[1],resource_group=sys.argv[2],run_id=sys.argv[3],exists=False,verified_at=datetime.datetime.now(datetime.timezone.utc).isoformat()),indent=2))
PROOF
  cat "$ROOT/.local/evidence/destroy.json"
  exit 0
fi
IP="$(azc network public-ip show -g "$RESOURCE_GROUP" -n pip-amazul --query ipAddress -o tsv)"
python3 -c 'import ipaddress,sys; ipaddress.IPv4Address(sys.argv[1])' "$IP"
# O IP do operador no NSG é a saída direta. Não encaminhar HTTP da VM ao proxy.
export NO_PROXY="${NO_PROXY:+$NO_PROXY,}$IP"
export no_proxy="${no_proxy:+$no_proxy,}$IP"
if [[ "$ACTION" == deploy ]]; then
  azc vm run-command invoke -g "$RESOURCE_GROUP" -n "$VM_NAME" --command-id RunShellScript \
    --scripts "@$ROOT/scripts/install-docker.sh" -o json > "$ROOT/.local/evidence/install.json"
  python3 - "$ROOT/.local/evidence/install.json" <<'READY'
import json,sys
r=json.load(open(sys.argv[1])); assert any('AMAZUL_DOCKER_READY' in v.get('message','') for v in r['value']), 'Instalacao incompleta; leia install.json'
READY
  azc vm run-command invoke -g "$RESOURCE_GROUP" -n "$VM_NAME" --command-id RunShellScript \
    --scripts 'cat /etc/ssh/ssh_host_ed25519_key.pub' -o json > "$ROOT/.local/host-key.json"
  python3 - "$ROOT/.local/host-key.json" "$IP" > "$ROOT/.local/known_hosts" <<'HOST'
import json,re,sys
r=json.load(open(sys.argv[1])); s='\n'.join(v.get('message','') for v in r['value'])
m=re.search(r'^ssh-ed25519 [A-Za-z0-9+/=]+',s,re.M); assert m, 'Host key nao encontrada'
print(sys.argv[2]+' '+m[0])
HOST
  bash "$ROOT/scripts/preparar.sh"
  python3 - "$ROOT/.local/api.env" <<'ENV'
import os,secrets,sys
from pathlib import Path
p=Path(sys.argv[1])
if not p.exists():
    p.write_text('APP_ADMIN_USERNAME=editor\nAPP_ADMIN_PASSWORD='+secrets.token_hex(24)+'\n')
if os.environ.get('API_COUNTRY_KEY'):
    lines=[line for line in p.read_text().splitlines() if not line.startswith('API_COUNTRY_KEY=')]
    lines.append('API_COUNTRY_KEY='+os.environ['API_COUNTRY_KEY'])
    p.write_text('\n'.join(lines)+'\n')
p.chmod(0o600)
ENV
  tar -czf "$ROOT/.local/app.tar.gz" -C "$ROOT/.local/backend" Dockerfile .dockerignore .mvn mvnw pom.xml src \
    -C "$ROOT" scripts/deploy-vm.sh scripts/verificar.py -C "$ROOT/.local/evidence" source.json
  scp -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$ROOT/.local/known_hosts" \
    "$ROOT/.local/app.tar.gz" "$ROOT/.local/api.env" "$ADMIN_USER@$IP:"
fi
SSH=(ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$ROOT/.local/known_hosts" "$ADMIN_USER@$IP")
if [[ "$ACTION" == deploy ]]; then
  "${SSH[@]}" 'set -eu; sudo mkdir -p /opt/amazul-java; sudo tar -xzf app.tar.gz -C /opt/amazul-java; sudo install -m 600 api.env /opt/amazul-java/api.env; rm app.tar.gz api.env; sudo bash /opt/amazul-java/scripts/deploy-vm.sh'
fi
python3 "$ROOT/scripts/verificar.py" "http://$IP:8080"
"${SSH[@]}" 'set -eu; [ "$(sudo docker inspect --format "{{.State.Health.Status}}" amazul-api)" = healthy ]; [ "$(sudo docker exec amazul-api id -u)" = 10001 ]; sudo python3 /opt/amazul-java/scripts/verificar.py http://127.0.0.1:8080 /opt/amazul-java/api.env; sudo docker ps; sudo docker exec amazul-api id; sudo docker inspect --format "{{.State.Health.Status}}" amazul-api; sudo docker image inspect amazul-api:s1 --format "{{.Id}} {{index .Config.Labels \"org.opencontainers.image.revision\"}}"; sudo docker stats --no-stream --format "{{.Name}} {{.MemUsage}}" amazul-api; sudo docker version --format "{{.Server.Version}}"' | tee "$ROOT/.local/evidence/runtime.txt"
echo "Abra no navegador: http://$IP:8080/swagger-ui/index.html"
echo "Para cadastrar com seguranca: ssh -i $SSH_KEY -N -L 18080:127.0.0.1:8080 $ADMIN_USER@$IP"
echo 'No tunel, abra http://localhost:18080/swagger-ui/index.html. Credenciais em .local/api.env; nao gravar nem publicar.'
echo 'Ao terminar a gravação, execute destroy. Registros em .local/evidence.'
