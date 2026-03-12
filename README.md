# Supabase Setup (Docker)

Initialisation de Supabase en local avec Docker : un script génère le `docker-compose` et démarre les containers au format `{name}_superbase`.

## Prérequis

- Docker et Docker Compose
- Bash

## Usage

```bash
./init-supabase.sh --name <nom_projet> --port <port_postgres> --storage-port <port_storage>
```

**Exemples :**

```bash
# Crée le container "monapp_superbase", Postgres sur 15432, Storage sur 5040
./init-supabase.sh --name monapp --port 15432 --storage-port 5040

# Générer uniquement le docker-compose sans démarrer
./init-supabase.sh --name monapp --port 15432 --storage-port 5040 --no-start
```

- **`--name`** : nom du projet. Le container Postgres sera nommé `{name}_superbase`.
- **`--port`** : port exposé pour PostgreSQL (ex. 15432).
- **`--storage-port`** : port exposé pour l’API Storage (ex. 5040).

## Après initialisation

- **PostgreSQL** : `localhost:<port>` (user: `postgres`, password: `postgres`, db: `postgres`)
- **Connection string** : `postgres://postgres:postgres@localhost:<port>/postgres`
- **Storage API** : `http://localhost:<storage-port>`

L’image `supabase/postgres` applique au premier démarrage le schéma par défaut Supabase (extensions, rôles `anon`/`authenticated`/`service_role`, etc.).

## Tables et migrations personnalisées

Les fichiers SQL dans `migrations/init/*.sql` sont exécutés après le démarrage de la base (ordre alphabétique). Vous pouvez y définir vos tables métier.

Exemple : éditer `migrations/init/01_custom_schema.sql`.

## Commandes utiles

```bash
# Démarrer (si déjà généré)
docker compose up -d

# Arrêter
docker compose down

# Logs
docker compose logs -f
```

## Sécurité

En production, définir des secrets (`.env`) : `POSTGRES_PASSWORD`, `ANON_KEY`, `SERVICE_KEY`, etc. Voir la [doc Supabase self-hosting](https://supabase.com/docs/guides/self-hosting/docker).
