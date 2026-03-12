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
- **SERVICE_KEY** : affiché à la fin du script (également présent dans `.env`)

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

## Secrets JWT

Lors du premier lancement, le script **génère automatiquement** un fichier `.env` avec :

- **PGRST_JWT_SECRET** : secret aléatoire (openssl)
- **ANON_KEY** : JWT pour le rôle `anon`
- **SERVICE_KEY** : JWT pour le rôle `service_role`

Le `.env` est créé uniquement s’il n’existe pas. Pour régénérer les secrets, supprimez `.env` puis relancez le script. **Ne commitez pas le fichier `.env`** (il est ignoré par le `.gitignore` si vous ne versionnez que le script et le README).

## Exemple : créer un bucket Storage

Avec la stack légère (sans gateway Kong), l’API Storage est directement exposée sur `http://localhost:<storage-port>`.

Exemple pour créer un bucket `avatars` public :

```bash
SERVICE_KEY="<la_valeur_affichée_par_le_script>"

curl -X POST "http://localhost:<storage-port>/bucket" \
  -H "Authorization: Bearer ${SERVICE_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "avatars",
    "public": true,
    "allowedMimeTypes": ["image/*"],
    "fileSizeLimit": "1048576"
  }'
```

Remplacez `<storage-port>` par le port choisi (ex. `5040`) et `SERVICE_KEY` par la valeur affichée à la fin de `init-supabase.sh`.

## Sécurité

En production, vérifiez les secrets dans `.env` et définissez aussi `POSTGRES_PASSWORD` si besoin. Voir la [doc Supabase self-hosting](https://supabase.com/docs/guides/self-hosting/docker).
