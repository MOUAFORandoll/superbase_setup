#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Script d'initialisation Supabase avec Docker
# Usage: ./init-supabase.sh --name <name> --port <port> --storage-port <port>
# Crée le container au format <name>_superbase et initialise les tables par défaut
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"

usage() {
  echo "Usage: $0 --name <name> --port <port> --storage-port <port> [--no-start]"
  echo ""
  echo "Options:"
  echo "  --name         Nom du projet (utilisé pour le container: <name>_superbase)"
  echo "  --port         Port exposé pour PostgreSQL (ex: 5432)"
  echo "  --storage-port Port exposé pour l'API Storage (ex: 5000)"
  echo "  --no-start     Génère uniquement le docker-compose sans lancer les containers"
  echo ""
  echo "Exemple: $0 --name monapp --port 15432 --storage-port 5040"
  exit 1
}

NAME=""
PORT=""
STORAGE_PORT=""
NO_START=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --name)
      NAME="$2"
      shift 2
      ;;
    --port)
      PORT="$2"
      shift 2
      ;;
    --storage-port)
      STORAGE_PORT="$2"
      shift 2
      ;;
    --no-start)
      NO_START=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Option inconnue: $1"
      usage
      ;;
  esac
done

if [[ -z "$NAME" ]] || [[ -z "$PORT" ]] || [[ -z "$STORAGE_PORT" ]]; then
  echo "Erreur: --name, --port et --storage-port sont requis."
  usage
fi

# Validation: nom alphanumérique et underscore uniquement
if ! [[ "$NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "Erreur: le nom doit contenir uniquement lettres, chiffres, tirets et underscores."
  exit 1
fi

# Validation: ports numériques
for p in PORT STORAGE_PORT; do
  val="${!p}"
  if ! [[ "$val" =~ ^[0-9]+$ ]] || [[ "$val" -lt 1 ]] || [[ "$val" -gt 65535 ]]; then
    echo "Erreur: $p ($val) doit être un nombre entre 1 et 65535."
    exit 1
  fi
done

CONTAINER_NAME="${NAME}_superbase"
SERVICE_DB="${NAME}-db"
SERVICE_STORAGE="${NAME}-storage"
VOLUME_DB="${NAME}_db_data"
VOLUME_STORAGE="${NAME}_storage_data"
ENV_FILE="${SCRIPT_DIR}/.env"
KONG_DIR="${SCRIPT_DIR}/kong"

# Génère un JWT signé avec HS256 (payload JSON: iss, role, exp)
# Usage: jwt_sign "<payload_json>" "<secret>"
jwt_sign() {
  local payload="$1"
  local secret="$2"
  local header='{"alg":"HS256","typ":"JWT"}'
  base64_url() { base64 2>/dev/null | tr -d '\n' | tr '+/' '-_' | tr -d '='; }
  local header_b64 payload_b64 msg sig
  header_b64=$(echo -n "$header" | base64_url)
  payload_b64=$(echo -n "$payload" | base64_url)
  msg="${header_b64}.${payload_b64}"
  sig=$(echo -n "$msg" | openssl dgst -sha256 -hmac "$secret" -binary | base64_url)
  echo "${msg}.${sig}"
}

# Génère PGRST_JWT_SECRET, ANON_KEY, SERVICE_KEY et écrit .env
generate_jwt_env() {
  local secret
  secret=$(openssl rand -base64 48 | tr -d '\n')
  # Expiration lointaine (2038)
  local exp="2147483646"
  local anon_payload="{\"iss\":\"supabase\",\"role\":\"anon\",\"exp\":${exp}}"
  local service_payload="{\"iss\":\"supabase\",\"role\":\"service_role\",\"exp\":${exp}}"
  local anon_key service_key
  anon_key=$(jwt_sign "$anon_payload" "$secret")
  service_key=$(jwt_sign "$service_payload" "$secret")

  cat > "${ENV_FILE}" << ENVEOF
# Généré par init-supabase.sh - $(date -Iseconds)
# Ne pas commiter ce fichier (secrets).

PGRST_JWT_SECRET=${secret}
ANON_KEY=${anon_key}
SERVICE_KEY=${service_key}
ENVEOF
  echo "Secrets générés et écrits dans: ${ENV_FILE}"
}

# Lit une variable depuis le .env généré
get_env_var() {
  local key="$1"
  if [[ -f "${ENV_FILE}" ]]; then
    grep -E "^${key}=" "${ENV_FILE}" | sed -E "s/^${key}=//" | head -n1 || true
  fi
}

echo "Configuration:"
echo "  Container DB : ${CONTAINER_NAME}"
echo "  Port Postgres : ${PORT}"
echo "  Port Storage : ${STORAGE_PORT}"
echo ""

# Arrêt et suppression de l'ancienne stack pour ce projet (containers + volumes définis dans le compose)
if [[ -f "${COMPOSE_FILE}" ]]; then
  echo "Nettoyage de l'ancienne stack Docker (down -v)..."
  (cd "${SCRIPT_DIR}" && docker compose -f "${COMPOSE_FILE}" down -v 2>/dev/null || true)
fi

# Nettoyage des fichiers générés précédemment (réécrits à chaque run)
rm -f "${COMPOSE_FILE}"

# Génération des fichiers de configuration (Kong + docker-compose)
generate_kong_config() {
  mkdir -p "${KONG_DIR}"
  cat > "${KONG_DIR}/kong.yml" << EOF
_format_version: "3.0"
services:
  - name: storage-service
    url: http://${SERVICE_STORAGE}:5000
    routes:
      - name: storage-route
        paths:
          - /storage/v1
EOF
}

generate_compose() {
  cat << EOF
# Généré par init-supabase.sh - $(date -Iseconds)
# name=${NAME} port=${PORT} storage-port=${STORAGE_PORT}

services:
  ${SERVICE_DB}:
    image: supabase/postgres:15.14.1.096
    container_name: ${CONTAINER_NAME}
    restart: always
    environment:
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: postgres
    ports:
      - "${PORT}:5432"
    volumes:
      - ${VOLUME_DB}:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5

  ${SERVICE_STORAGE}:
    image: supabase/storage-api:latest
    container_name: ${NAME}_superbase_storage
    depends_on:
      ${SERVICE_DB}:
        condition: service_healthy
    environment:
      PGRST_JWT_SECRET: \${PGRST_JWT_SECRET:-super-secret-jwt-token-with-at-least-32-characters-long}
      ANON_KEY: \${ANON_KEY:-eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0}
      SERVICE_KEY: \${SERVICE_KEY:-eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU}
      DATABASE_URL: postgres://supabase_admin:postgres@${SERVICE_DB}:5432/postgres
      FILE_SIZE_LIMIT: 52428800
      STORAGE_BACKEND: file
      FILE_STORAGE_BACKEND_PATH: /var/lib/storage
      TENANT_ID: ${NAME}
      REGION: local
      GLOBAL_S3_BUCKET: storage
    volumes:
      - ${VOLUME_STORAGE}:/var/lib/storage
    ports:
      - "${STORAGE_PORT}:5000"

  kong:
    image: kong:3.7
    container_name: ${NAME}_superbase_kong
    restart: always
    environment:
      KONG_DATABASE: off
      KONG_DECLARATIVE_CONFIG: /usr/local/kong/declarative/kong.yml
      KONG_PROXY_LISTEN: 0.0.0.0:3030
    depends_on:
      ${SERVICE_STORAGE}:
        condition: service_started
    ports:
      - "3030:3030"
    volumes:
      - ./kong:/usr/local/kong/declarative:ro

volumes:
  ${VOLUME_DB}:
  ${VOLUME_STORAGE}:
EOF
}

mkdir -p "${SCRIPT_DIR}/migrations/init"

# Génération des secrets JWT (création de .env si absent)
if [[ ! -f "${ENV_FILE}" ]]; then
  generate_jwt_env
else
  echo "Fichier .env existant conservé (supprimez-le pour régénérer les secrets)."
fi

SERVICE_KEY_VALUE="$(get_env_var "SERVICE_KEY")"

generate_kong_config

# Fichier SQL d'init optionnel (exécuté au premier démarrage si présent)
if [[ ! -f "${SCRIPT_DIR}/migrations/init/01_custom_schema.sql" ]]; then
  cat > "${SCRIPT_DIR}/migrations/init/01_custom_schema.sql" << 'SQLEOF'
-- Tables par défaut personnalisées (optionnel)
-- L'image supabase/postgres applique déjà le schéma Supabase (auth, extensions, rôles).
-- Ajoutez ici vos tables métier.

-- Exemple: table profils liée à auth.users
-- CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
-- CREATE TABLE IF NOT EXISTS public.profiles (
--   id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
--   email TEXT,
--   display_name TEXT,
--   created_at TIMESTAMPTZ DEFAULT now(),
--   updated_at TIMESTAMPTZ DEFAULT now()
-- );
-- ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
-- CREATE POLICY "Profils publics en lecture" ON public.profiles FOR SELECT USING (true);
-- CREATE POLICY "Utilisateur peut modifier son profil" ON public.profiles FOR ALL USING (auth.uid() = id);

SELECT 1;
SQLEOF
  echo "Fichier créé: migrations/init/01_custom_schema.sql (personnalisable)"
fi

generate_compose > "${COMPOSE_FILE}"
echo "Fichier écrit: ${COMPOSE_FILE}"

if [[ "$NO_START" == true ]]; then
  echo "Option --no-start: containers non démarrés."
  exit 0
fi

# Phase 1 : démarrer uniquement la base pour appliquer les droits storage avant le démarrage de Storage
echo "Démarrage de PostgreSQL..."
(cd "${SCRIPT_DIR}" && docker compose -f "${COMPOSE_FILE}" up -d "${SERVICE_DB}")

echo "Attente du démarrage de PostgreSQL..."
for i in {1..30}; do
  if docker exec "${CONTAINER_NAME}" pg_isready -U postgres -q 2>/dev/null; then
    echo "PostgreSQL est prêt."
    break
  fi
  if [[ $i -eq 30 ]]; then
    echo "Timeout: PostgreSQL ne répond pas. Vérifiez: docker compose -f ${COMPOSE_FILE} logs ${SERVICE_DB}"
    exit 1
  fi
  sleep 1
done

# Exécution des migrations personnalisées AVANT de démarrer Storage
if [[ -d "${SCRIPT_DIR}/migrations/init" ]]; then
  for f in "${SCRIPT_DIR}"/migrations/init/*.sql; do
    [[ -f "$f" ]] || continue
    echo "Application de $(basename "$f")..."
    docker exec -i "${CONTAINER_NAME}" psql -q -U postgres -d postgres -f - < "$f" >/dev/null 2>&1 || true
  done
fi

# Phase 2 : démarrer Storage (les migrations personnalisées sont déjà appliquées)
echo "Démarrage des services (DB + Storage)..."
(cd "${SCRIPT_DIR}" && docker compose -f "${COMPOSE_FILE}" up -d)

echo ""
echo "Supabase est initialisé."
echo "  Postgres : localhost:${PORT} (user: postgres, password: postgres, db: postgres)"
echo "  Storage  : http://localhost:${STORAGE_PORT}"
echo "  Connection string: postgres://postgres:postgres@localhost:${PORT}/postgres"
echo "  Kong proxy : http://localhost:3030 (Storage: /storage/v1/...)"
if [[ -n "${SERVICE_KEY_VALUE:-}" ]]; then
  echo "  SERVICE_KEY : ${SERVICE_KEY_VALUE}"
fi
echo ""
echo "Pour arrêter: docker compose -f ${COMPOSE_FILE} down"
echo "Pour les logs: docker compose -f ${COMPOSE_FILE} logs -f"
