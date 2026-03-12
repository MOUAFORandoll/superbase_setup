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

echo "Configuration:"
echo "  Container DB : ${CONTAINER_NAME}"
echo "  Port Postgres : ${PORT}"
echo "  Port Storage : ${STORAGE_PORT}"
echo ""

# Génération du docker-compose
generate_compose() {
  cat << EOF
# Généré par init-supabase.sh - $(date -Iseconds)
# name=${NAME} port=${PORT} storage-port=${STORAGE_PORT}

version: "3.9"

services:
  ${SERVICE_DB}:
    image: supabase/postgres:15.1.0
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
      ANON_KEY: \${ANON_KEY:-eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0}
      SERVICE_KEY: \${SERVICE_KEY:-eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU}
      DATABASE_URL: postgres://postgres:postgres@${SERVICE_DB}:5432/postgres
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

volumes:
  ${VOLUME_DB}:
  ${VOLUME_STORAGE}:
EOF
}

mkdir -p "${SCRIPT_DIR}/migrations/init"

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

echo "Démarrage des containers..."
docker compose -f "${COMPOSE_FILE}" up -d

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

# Exécution des migrations personnalisées (migrations/init/*.sql)
if [[ -d "${SCRIPT_DIR}/migrations/init" ]]; then
  for f in "${SCRIPT_DIR}"/migrations/init/*.sql; do
    [[ -f "$f" ]] || continue
    echo "Application de $(basename "$f")..."
    docker exec -i "${CONTAINER_NAME}" psql -U postgres -d postgres -f - < "$f" || true
  done
fi

echo ""
echo "Supabase est initialisé."
echo "  Postgres : localhost:${PORT} (user: postgres, password: postgres, db: postgres)"
echo "  Storage  : http://localhost:${STORAGE_PORT}"
echo "  Connection string: postgres://postgres:postgres@localhost:${PORT}/postgres"
echo ""
echo "Pour arrêter: docker compose -f ${COMPOSE_FILE} down"
echo "Pour les logs: docker compose -f ${COMPOSE_FILE} logs -f"
