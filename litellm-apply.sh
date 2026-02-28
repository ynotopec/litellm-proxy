#!/usr/bin/env bash
# litellm-apply.sh  --  Install / Upgrade LiteLLM (K8s-native, stateless config)
# Usage (exemples) :
#   ./litellm-apply.sh --namespace llm --config ~/litellm-config.yaml
#   ./litellm-apply.sh --reset-data           # ⚠️ supprime les PVC Postgres/Redis (perte données)
#   ./litellm-apply.sh --provider redis=valkey  # migre Redis -> Valkey (service compatible)
#   ./litellm-apply.sh --rotate-salt --rotate-master
#
# Points clés :
# - Évite `:latest` (images épinglées).
# - Règle des ressources réalistes (évite OOM 137 sur Postgres).
# - Attend la readiness de PG/Redis avant de redémarrer LiteLLM.
# - Conserve noms de Service (compatibilité : redis-litellm-master, postgres-litellm).
# - IngressClass = public (ton choix par défaut).
set -euo pipefail
IFS=$'\n\t'

###############################################################################
# Flags & Defaults
###############################################################################
NAMESPACE_DEFAULT="llm"
CONFIG_FILE_DEFAULT=~/litellm-config.yaml
CHART_VERSION_CLI=""

ROTATE_SALT=false
ROTATE_MASTER=false
RECREATE_SECRETS=false
FORCE_OVERRIDE=false
RESET_DATA=false

# Providers (pour migration légère)
REDIS_PROVIDER="bitnami"   # bitnami|valkey
POSTGRES_PROVIDER="bitnami" # (placeholder si tu veux basculer vers un opérateur plus tard)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)        NAMESPACE_DEFAULT="$2"; shift 2;;
    --config)           CONFIG_FILE_DEFAULT="$2"; shift 2;;
    --chart-version)    CHART_VERSION_CLI="$2"; shift 2;;
    --rotate-salt)      ROTATE_SALT=true; shift;;
    --rotate-master)    ROTATE_MASTER=true; shift;;
    --recreate-secrets) RECREATE_SECRETS=true; shift;;
    --force-override)   FORCE_OVERRIDE=true; shift;;
    --reset-data)       RESET_DATA=true; shift;;
    --provider)
      # format: key=value (ex: redis=valkey)
      kv="${2:-}"; shift 2
      case "$kv" in
        redis=valkey) REDIS_PROVIDER="valkey";;
        redis=bitnami) REDIS_PROVIDER="bitnami";;
        postgres=bitnami) POSTGRES_PROVIDER="bitnami";;
        *) echo "Provider inconnu: $kv" >&2; exit 1;;
      esac
      ;;
    -h|--help)
      grep '^#' "$0" | sed -e 's/^# \{0,1\}//'
      exit 0;;
    *) echo "Arg inconnu: $1" >&2; exit 1;;
  esac
done

###############################################################################
# Charger .env si présent
###############################################################################
if [[ -f .env ]]; then
  # shellcheck disable=SC2046
  export $(grep -v '^#' .env | xargs)
fi

###############################################################################
# Paramètres
###############################################################################
APP_NAME="${APP_NAME:-litellm}"
NAMESPACE="${NAMESPACE:-$NAMESPACE_DEFAULT}"
#DOMAIN_ROOT="${DOMAIN_ROOT:-ai-dev.fake-domain.name}"
#LITELLM_HOST="${LITELLM_HOST:-api-${NAMESPACE}.${DOMAIN_ROOT}}"
DOMAIN_ROOT="${DOMAIN_ROOT:-ai-dev.fake-domain.name}"
LITELLM_HOST="${LITELLM_HOST:-api-ai.${DOMAIN_ROOT}}"

CHART_REPO_NAME="${CHART_REPO_NAME:-unique}"
CHART_REPO_URL="${CHART_REPO_URL:-https://unique-ag.github.io/helm-charts/}"
CHART="${CHART:-litellm}"
CHART_VERSION="${CHART_VERSION_CLI:-${CHART_VERSION:-}}"

PG_NAME="${PG_NAME:-postgres-litellm}"
REDIS_NAME="${REDIS_NAME:-redis-litellm}"

CONFIG_FILE="${CONFIG_FILE:-$CONFIG_FILE_DEFAULT}"

# Images tags épinglés (modifiables via env)
POSTGRES_IMAGE_REG="${POSTGRES_IMAGE_REG:-docker.io}"
POSTGRES_IMAGE_REPO="${POSTGRES_IMAGE_REPO:-bitnami/postgresql}"
POSTGRES_IMAGE_TAG="${POSTGRES_IMAGE_TAG:-17.6.0-debian-12-r4}"

REDIS_IMAGE_REG="${REDIS_IMAGE_REG:-docker.io}"
REDIS_IMAGE_REPO="${REDIS_IMAGE_REPO:-bitnami/redis}"
REDIS_IMAGE_TAG="${REDIS_IMAGE_TAG:-8.2.1-debian-12-r0}"

# Valkey (si --provider redis=valkey)
VALKEY_IMAGE_REG="${VALKEY_IMAGE_REG:-docker.io}"
VALKEY_IMAGE_REPO="${VALKEY_IMAGE_REPO:-bitnami/valkey}"
VALKEY_IMAGE_TAG="${VALKEY_IMAGE_TAG:-8.0.1-debian-12-r0}"

LITELLM_IMAGE="${LITELLM_IMAGE:-ghcr.io/berriai/litellm}"
LITELLM_TAG="${LITELLM_TAG:-main-stable}"  # pin utile si tu as un digest connu
LITELLM_CPU_REQ="${LITELLM_CPU_REQ:-200m}"
LITELLM_MEM_REQ="${LITELLM_MEM_REQ:-512Mi}"
LITELLM_CPU_LIM="${LITELLM_CPU_LIM:-1}"
LITELLM_MEM_LIM="${LITELLM_MEM_LIM:-1Gi}"

# Ressources DB/Cache
POSTGRES_CPU_REQ="${POSTGRES_CPU_REQ:-200m}"
POSTGRES_MEM_REQ="${POSTGRES_MEM_REQ:-1Gi}"
POSTGRES_CPU_LIM="${POSTGRES_CPU_LIM:-1}"
POSTGRES_MEM_LIM="${POSTGRES_MEM_LIM:-2Gi}"

REDIS_CPU_REQ="${REDIS_CPU_REQ:-200m}"
REDIS_MEM_REQ="${REDIS_MEM_REQ:-512Mi}"
REDIS_CPU_LIM="${REDIS_CPU_LIM:-1}"
REDIS_MEM_LIM="${REDIS_MEM_LIM:-1Gi}"

###############################################################################
# Helpers
###############################################################################
_b64_nowrap() {
  if base64 --help 2>&1 | grep -q '\-w'; then
    base64 -w0
  else
    base64 | tr -d '\n'
  fi
}

_wait_rollout() {
  local kind="$1" name="$2" ns="$3" to="${4:-5m}"
  kubectl -n "$ns" rollout status "$kind/$name" --timeout="$to"
}

_need_bin() {
  command -v "$1" >/dev/null 2>&1 || { echo "❌ binaire manquant: $1" >&2; exit 1; }
}

HELM_BIN="${HELM_BIN:-helm}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
YQ_BIN="$(command -v yq || true)"
JQ_BIN="$(command -v jq || true)"
_need_bin "$HELM_BIN"
_need_bin "$KUBECTL_BIN"

###############################################################################
# Namespace
###############################################################################
$KUBECTL_BIN get ns "$NAMESPACE" >/dev/null 2>&1 || $KUBECTL_BIN create ns "$NAMESPACE"

###############################################################################
# Valeurs critiques (Secrets)
###############################################################################
PROXY_MASTER_KEY="${PROXY_MASTER_KEY:-}"
LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-}"
LITELLM_SALT_KEY="${LITELLM_SALT_KEY:-}"
COMMON_PASSWORD="${COMMON_PASSWORD:-}"

SECRET_NAME="litellm-secrets"

###############################################################################
# Lire Secret existant
###############################################################################
EXIST_PROXY_MASTER=""
EXIST_LITELLM_MASTER=""
EXIST_SALT=""
EXIST_DB_PW=""

if $KUBECTL_BIN -n "$NAMESPACE" get secret "$SECRET_NAME" >/dev/null 2>&1 && ! $RECREATE_SECRETS; then
  echo "ℹ️  Secret $SECRET_NAME trouvé - lecture…"
  _get_s () { $KUBECTL_BIN -n "$NAMESPACE" get secret "$SECRET_NAME" -o jsonpath="{.data.$1}" 2>/dev/null | base64 -d 2>/dev/null || true; }
  EXIST_PROXY_MASTER="$(_get_s PROXY_MASTER_KEY)"
  EXIST_LITELLM_MASTER="$(_get_s LITELLM_MASTER_KEY)"
  EXIST_SALT="$(_get_s LITELLM_SALT_KEY)"
  EXIST_DB_PW="$(_get_s DATABASE_PASSWORD)"

  if ! $FORCE_OVERRIDE; then
    if [[ -n "$EXIST_PROXY_MASTER" && -n "$PROXY_MASTER_KEY" && "$EXIST_PROXY_MASTER" != "$PROXY_MASTER_KEY" && $ROTATE_MASTER == false ]]; then
      echo "❌ Conflit PROXY_MASTER_KEY (cluster ≠ env). Ajoute --force-override ou --rotate-master." >&2; exit 1
    fi
    if [[ -n "$EXIST_LITELLM_MASTER" && -n "$LITELLM_MASTER_KEY" && "$EXIST_LITELLM_MASTER" != "$LITELLM_MASTER_KEY" && $ROTATE_MASTER == false ]]; then
      echo "❌ Conflit LITELLM_MASTER_KEY (cluster ≠ env). Ajoute --force-override ou --rotate-master." >&2; exit 1
    fi
    if [[ -n "$EXIST_SALT" && -n "$LITELLM_SALT_KEY" && "$EXIST_SALT" != "$LITELLM_SALT_KEY" && $ROTATE_SALT == false ]]; then
      echo "❌ Conflit LITELLM_SALT_KEY (cluster ≠ env). Ajoute --force-override ou --rotate-salt." >&2; exit 1
    fi
    if [[ -n "$EXIST_DB_PW" && -n "$COMMON_PASSWORD" && "$EXIST_DB_PW" != "$COMMON_PASSWORD" ]]; then
      echo "❌ Conflit DATABASE_PASSWORD/COMMON_PASSWORD (cluster ≠ env). Ajoute --force-override." >&2; exit 1
    fi
  fi

  [[ -z "$PROXY_MASTER_KEY"   && -n "$EXIST_PROXY_MASTER" ]] && PROXY_MASTER_KEY="$EXIST_PROXY_MASTER"
  [[ -z "$LITELLM_MASTER_KEY" && -n "$EXIST_LITELLM_MASTER" ]] && LITELLM_MASTER_KEY="$EXIST_LITELLM_MASTER"
  if [[ $ROTATE_SALT == false && -n "$EXIST_SALT" ]]; then
    [[ -z "$LITELLM_SALT_KEY" ]] && LITELLM_SALT_KEY="$EXIST_SALT"
  fi
  [[ -z "$COMMON_PASSWORD" && -n "$EXIST_DB_PW" ]] && COMMON_PASSWORD="$EXIST_DB_PW"
else
  echo "🔰 Pas de Secret existant (ou --recreate-secrets)."
fi

###############################################################################
# Générer valeurs manquantes
###############################################################################
[[ -z "$COMMON_PASSWORD" ]]     && COMMON_PASSWORD="$(echo -n "${LITELLM_HOST}" | _b64_nowrap)"
[[ -z "$PROXY_MASTER_KEY" || $ROTATE_MASTER == true ]] && PROXY_MASTER_KEY="sk-$(openssl rand -hex 16)"
[[ -z "$LITELLM_MASTER_KEY" ]]  && LITELLM_MASTER_KEY="$PROXY_MASTER_KEY"
[[ -z "$LITELLM_SALT_KEY" || $ROTATE_SALT == true ]] && LITELLM_SALT_KEY="sk-$(openssl rand -hex 24)"

export REDIS_NAME PG_NAME LITELLM_HOST

###############################################################################
# Helm repos
###############################################################################
$HELM_BIN repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
$HELM_BIN repo add "$CHART_REPO_NAME" "$CHART_REPO_URL" >/dev/null 2>&1 || true
$HELM_BIN repo update

if [[ -z "$CHART_VERSION" && -n "$JQ_BIN" ]]; then
  CHART_VERSION="$($HELM_BIN search repo "${CHART_REPO_NAME}/${CHART}" -o json | $JQ_BIN -r '.[0].version' 2>/dev/null || echo "")"
fi

###############################################################################
# (Optionnel) Reset données = suppression des PVC
###############################################################################
if $RESET_DATA; then
  echo "⚠️  --reset-data : suppression PVC Postgres/Redis dans $NAMESPACE"
  $KUBECTL_BIN -n "$NAMESPACE" delete pvc data-postgres-litellm-0 --ignore-not-found
  $KUBECTL_BIN -n "$NAMESPACE" delete pvc redis-data-redis-litellm-master-0 --ignore-not-found
fi

###############################################################################
# Install / upgrade Postgres (Bitnami)
###############################################################################
if [[ "$POSTGRES_PROVIDER" == "bitnami" ]]; then
  $HELM_BIN upgrade --install "$PG_NAME" bitnami/postgresql -n "$NAMESPACE" \
    --set global.postgresql.auth.username=litellm_user \
    --set global.postgresql.auth.password="${COMMON_PASSWORD}" \
    --set global.postgresql.auth.database=litellm_db \
    --set primary.persistence.enabled=true \
    --set fullnameOverride="${PG_NAME}" \
    --set image.registry="${POSTGRES_IMAGE_REG}" \
    --set image.repository="${POSTGRES_IMAGE_REPO}" \
    --set image.tag="${POSTGRES_IMAGE_TAG}" \
    --set image.pullPolicy=IfNotPresent \
    --set primary.resources.requests.cpu="${POSTGRES_CPU_REQ}" \
    --set primary.resources.requests.memory="${POSTGRES_MEM_REQ}" \
    --set primary.resources.limits.cpu="${POSTGRES_CPU_LIM}" \
    --set primary.resources.limits.memory="${POSTGRES_MEM_LIM}"
else
  echo "❌ Provider Postgres non géré: $POSTGRES_PROVIDER" >&2
  exit 1
fi

###############################################################################
# Install / upgrade Redis / Valkey
###############################################################################
if [[ "$REDIS_PROVIDER" == "bitnami" ]]; then
  $HELM_BIN upgrade --install "$REDIS_NAME" bitnami/redis -n "$NAMESPACE" \
    --set auth.password="${COMMON_PASSWORD}" \
    --set architecture=standalone \
    --set fullnameOverride="${REDIS_NAME}" \
    --set image.registry="${REDIS_IMAGE_REG}" \
    --set image.repository="${REDIS_IMAGE_REPO}" \
    --set image.tag="${REDIS_IMAGE_TAG}" \
    --set image.pullPolicy=IfNotPresent \
    --set master.resources.requests.cpu="${REDIS_CPU_REQ}" \
    --set master.resources.requests.memory="${REDIS_MEM_REQ}" \
    --set master.resources.limits.cpu="${REDIS_CPU_LIM}" \
    --set master.resources.limits.memory="${REDIS_MEM_LIM}"
elif [[ "$REDIS_PROVIDER" == "valkey" ]]; then
  # Valkey standalone avec mêmes noms/labels de Service pour compatibilité
  $HELM_BIN upgrade --install "$REDIS_NAME" bitnami/valkey -n "$NAMESPACE" \
    --set auth.password="${COMMON_PASSWORD}" \
    --set architecture=standalone \
    --set fullnameOverride="${REDIS_NAME}" \
    --set image.registry="${VALKEY_IMAGE_REG}" \
    --set image.repository="${VALKEY_IMAGE_REPO}" \
    --set image.tag="${VALKEY_IMAGE_TAG}" \
    --set image.pullPolicy=IfNotPresent \
    --set master.resources.requests.cpu="${REDIS_CPU_REQ}" \
    --set master.resources.requests.memory="${REDIS_MEM_REQ}" \
    --set master.resources.limits.cpu="${REDIS_CPU_LIM}" \
    --set master.resources.limits.memory="${REDIS_MEM_LIM}"
else
  echo "❌ Provider Redis non géré: $REDIS_PROVIDER" >&2
  exit 1
fi

###############################################################################
# Secret YAML (app)
###############################################################################
TMPDIR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR"' EXIT

cat >"$TMPDIR/secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: litellm-secrets
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  PROXY_MASTER_KEY: "${PROXY_MASTER_KEY}"
  LITELLM_MASTER_KEY: "${LITELLM_MASTER_KEY}"
  LITELLM_SALT_KEY: "${LITELLM_SALT_KEY}"
  DATABASE_URL: "postgresql://litellm_user:${COMMON_PASSWORD}@${PG_NAME}:5432/litellm_db"
  DATABASE_PASSWORD: "${COMMON_PASSWORD}"
  REDIS_PASSWORD: "${COMMON_PASSWORD}"
EOF

if $RECREATE_SECRETS; then
  $KUBECTL_BIN -n "$NAMESPACE" delete secret "$SECRET_NAME" --ignore-not-found
fi
$KUBECTL_BIN apply -f "$TMPDIR/secret.yaml"

###############################################################################
# Config LiteLLM (ConfigMap)
###############################################################################
if [[ -z "$YQ_BIN" ]]; then
  echo "❌ yq requis pour extraire .model_list de ${CONFIG_FILE}" >&2; exit 1
fi

#yq eval '.model_list' "$CONFIG_FILE" > "$TMPDIR/model_list.yaml"
cat "$CONFIG_FILE" | yq eval '.model_list' - > "$TMPDIR/model_list.yaml"

cat >"$TMPDIR/config.yaml" <<'EOC'
model_list:
EOC
sed 's/^/  /' "$TMPDIR/model_list.yaml" >> "$TMPDIR/config.yaml"

cat >>"$TMPDIR/config.yaml" <<'EOC'

general_settings:
  master_key: os.environ/PROXY_MASTER_KEY
  alerting: []
  proxy_batch_write_at: 60
  database_connection_pool_limit: 10
  disable_spend_logs: false
  disable_error_logs: false

litellm_settings:
  request_timeout: 600
  set_verbose: false
  json_logs: true
  cache: true
  cache_params:
    type: redis
    host: redis-litellm-master
    port: 6379
    password: os.environ/REDIS_PASSWORD

router_settings:
  redis_host: redis-litellm-master
  redis_port: 6379
  redis_password: os.environ/REDIS_PASSWORD
  # Fallback de gpt-4o-primary vers gpt-4o-backup
  fallbacks:
    - { ai-chat: ["ai-backup"] }

  # Optionnel : fallback global si un model group est mal configuré
  default_fallbacks: ["ai-backup"]

  # Optionnel : nombre de retries avant de déclencher le fallback
  num_retries: 2
EOC

CONFIGMAP_FILE="$TMPDIR/litellm-configmap.yaml"
{
  echo "apiVersion: v1"
  echo "kind: ConfigMap"
  echo "metadata:"
  echo "  name: litellm-config"
  echo "  namespace: $NAMESPACE"
  echo "data:"
  echo "  config.yaml: |"
  sed 's/^/    /' "$TMPDIR/config.yaml"
} > "$CONFIGMAP_FILE"

$KUBECTL_BIN apply -f "$CONFIGMAP_FILE"

###############################################################################
# Attendre readiness PG/Redis avant LiteLLM
###############################################################################
echo "⏳ Attente readiness Postgres/Redis…"
$KUBECTL_BIN -n "$NAMESPACE" rollout status statefulset/"$PG_NAME" --timeout=5m
$KUBECTL_BIN -n "$NAMESPACE" rollout status statefulset/"${REDIS_NAME}-master" --timeout=5m

###############################################################################
# Deployment LiteLLM (resources + image pinned)
###############################################################################
DEPLOYMENT_FILE="$TMPDIR/litellm-deploy.yaml"
cat >"$DEPLOYMENT_FILE" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ${APP_NAME}
  template:
    metadata:
      labels:
        app: ${APP_NAME}
    spec:
      containers:
        - name: litellm
          image: ${LITELLM_IMAGE}:${LITELLM_TAG}
          command: ["litellm", "--config=/app/config.yaml"]
          resources:
            requests:
              cpu: "${LITELLM_CPU_REQ}"
              memory: "${LITELLM_MEM_REQ}"
            limits:
              cpu: "${LITELLM_CPU_LIM}"
              memory: "${LITELLM_MEM_LIM}"
          volumeMounts:
            - name: config
              mountPath: /app/config.yaml
              subPath: config.yaml
          env:
            - name: PROXY_MASTER_KEY
              valueFrom:
                secretKeyRef:
                  name: litellm-secrets
                  key: LITELLM_MASTER_KEY
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: litellm-secrets
                  key: DATABASE_URL
            - name: STORE_MODEL_IN_DB
              value: "True"
            - name: REDIS_HOST
              value: redis-litellm-master
            - name: REDIS_PORT
              value: "6379"
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: litellm-secrets
                  key: REDIS_PASSWORD
          ports:
            - containerPort: 4000
          readinessProbe:
            httpGet:
              path: /health/liveliness
              port: 4000
            initialDelaySeconds: 40
            periodSeconds: 30
            timeoutSeconds: 10
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /health/liveliness
              port: 4000
            initialDelaySeconds: 40
            periodSeconds: 30
            timeoutSeconds: 10
            failureThreshold: 3
      volumes:
        - name: config
          configMap:
            name: litellm-config
EOF

APPLY_OUTPUT="$($KUBECTL_BIN apply -f "$DEPLOYMENT_FILE")"
if echo "$APPLY_OUTPUT" | grep -q 'unchanged'; then
  echo "ℹ️  Déploiement inchangé — restart des pods..."
  $KUBECTL_BIN rollout restart deployment "$APP_NAME" -n "$NAMESPACE"
else
  echo "✅ Déploiement modifié — pas de restart manuel nécessaire."
fi
_wait_rollout "deployment" "$APP_NAME" "$NAMESPACE" "5m"

###############################################################################
# Service LiteLLM
###############################################################################
SERVICE_FILE="$TMPDIR/litellm-service.yaml"
cat >"$SERVICE_FILE" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
spec:
  type: ClusterIP
  ports:
    - port: 4000
      targetPort: 4000
      protocol: TCP
      name: http
  selector:
    app: ${APP_NAME}
EOF
$KUBECTL_BIN apply -f "$SERVICE_FILE"

###############################################################################
# Ingress LiteLLM
###############################################################################
INGRESS_FILE="$TMPDIR/litellm-ingress.yaml"
cat >"$INGRESS_FILE" <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
spec:
  ingressClassName: public
  tls:
    - hosts:
        - ${LITELLM_HOST}
      secretName: ${LITELLM_HOST}-tls
  rules:
    - host: ${LITELLM_HOST}
      http:
        paths:
          - path: /
            pathType: ImplementationSpecific
            backend:
              service:
                name: ${APP_NAME}
                port:
                  number: 4000
EOF
$KUBECTL_BIN apply -f "$INGRESS_FILE"

###############################################################################
# Done
###############################################################################
echo "-------------------------"
echo "✔️  Déploiement/upgrade terminé !"
echo "URL          : https://${LITELLM_HOST}"
echo "Namespace    : ${NAMESPACE}"
echo "DB/Redis pwd : ${COMMON_PASSWORD}"
echo "PROXY_MASTER : ${PROXY_MASTER_KEY}"
echo "SALT_KEY     : ${LITELLM_SALT_KEY}  (sauvegarde hors cluster !)"
echo "helm history : helm history ${APP_NAME} -n ${NAMESPACE}"
