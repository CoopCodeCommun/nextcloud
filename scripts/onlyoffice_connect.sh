#!/bin/bash
set -euo pipefail

##### INSTRUCTION
#
# Connecte Nextcloud au Document Server OnlyOffice, sans clic dans l'admin.
# Lance par :  make onlyoffice   (et automatiquement par make update)
#
# UNE seule source de verite : JWT_SECRET dans le .env de la stack.
#   - le conteneur onlyoffice la recoit en variable d'environnement
#     (docker-compose.yml), il ne genere donc plus de cle aleatoire ;
#   - ce script la pousse dans la config de l'app onlyoffice de Nextcloud,
#     avec les URL, puis verifie la connexion.
#
# Rejouable a volonte : il ne fait qu'ecrire les memes valeurs. Apres une
# recreation du Document Server ou une mise a jour de Nextcloud, plus besoin
# d'aller recopier la cle a la main.
#####

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
STACK_DIR="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$STACK_DIR/docker-compose.yml"
APP_SERVICE="${APP_SERVICE:-nextcloud_app}"
OO_SERVICE="${OO_SERVICE:-onlyoffice}"

# On ne charge du .env de la stack que ce dont on a besoin.
valeur_env() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$STACK_DIR/.env" | tail -n1 | tr -d "'\""; }
DOMAIN="$(valeur_env DOMAIN)"
JWT_SECRET="$(valeur_env JWT_SECRET)"
[ -n "$DOMAIN" ]     || { echo "[onlyoffice] DOMAIN absent du .env" >&2; exit 1; }
[ -n "$JWT_SECRET" ] || { echo "[onlyoffice] JWT_SECRET absent du .env" >&2; exit 1; }

# Doit correspondre au JWT_HEADER du conteneur onlyoffice (docker-compose.yml).
JWT_HEADER="${JWT_HEADER:-Authorization}"
DS_URL="https://onlyoffice.$DOMAIN/"
NC_URL="https://nuage.$DOMAIN/"

compose() { docker compose -f "$COMPOSE_FILE" "$@"; }
occ()     { compose exec -T -u www-data "$APP_SERVICE" php occ --no-warnings "$@"; }


#### 1. LE DOCUMENT SERVER REPOND-IL ? ####
echo "[onlyoffice] attente du Document Server..."
for i in $(seq 1 60); do
  if [ "$(compose exec -T "$OO_SERVICE" curl -s http://localhost/healthcheck 2>/dev/null)" = "true" ]; then
    echo "[onlyoffice] Document Server pret."
    break
  fi
  [ "$i" -eq 60 ] && { echo "[onlyoffice] le Document Server ne repond pas apres 5 min." >&2; exit 1; }
  sleep 5
done

# Le secret effectivement charge par le DS doit etre celui du .env : sinon le
# conteneur a ete cree sans la variable, et rien ne pourra se connecter.
SECRET_DS="$(compose exec -T "$OO_SERVICE" /var/www/onlyoffice/documentserver/npm/json \
  -f /etc/onlyoffice/documentserver/local.json 'services.CoAuthoring.secret.session.string' 2>/dev/null || true)"
if [ "$SECRET_DS" != "$JWT_SECRET" ]; then
  echo "[onlyoffice] ERREUR : le Document Server n'utilise pas le JWT_SECRET du .env." >&2
  echo "             Recreer le conteneur : docker compose up -d --force-recreate $OO_SERVICE" >&2
  exit 1
fi


#### 2. CONFIGURATION DU CONNECTEUR ####
occ app:enable onlyoffice >/dev/null
occ config:app:set onlyoffice DocumentServerUrl         --value="$DS_URL"   >/dev/null
occ config:app:set onlyoffice DocumentServerInternalUrl --value="$DS_URL"   >/dev/null
occ config:app:set onlyoffice StorageUrl                --value="$NC_URL"   >/dev/null
occ config:app:set onlyoffice jwt_header                --value="$JWT_HEADER" >/dev/null
# --sensitive : stocke chiffre par Nextcloud (le connecteur 10.2+ fait de meme)
# et masque dans config:list. Le secret n apparait pas dans la sortie.
printf "yes\n" | occ config:app:set onlyoffice jwt_secret --sensitive --value="$JWT_SECRET" >/dev/null
echo "[onlyoffice] connecteur configure : $DS_URL (JWT depuis le .env)"


#### 3. VERIFICATION ####
# En mode maintenance (ex. une sauvegarde en cours), Nextcloud ne charge
# aucune app : la commande onlyoffice:* n'existe pas. Les valeurs ci-dessus
# sont pourtant bien ecrites ; seule la verification est impossible.
if occ maintenance:mode 2>/dev/null | grep -q enabled; then
  echo "[onlyoffice] Nextcloud est en maintenance (sauvegarde ?) : configuration ecrite," >&2
  echo "             verification impossible. Relancer 'make onlyoffice' apres." >&2
  exit 1
fi
if occ onlyoffice:documentserver --check; then
  echo "[onlyoffice] OK — Nextcloud et le Document Server se parlent."
else
  echo "[onlyoffice] ECHEC de la verification de connexion (voir ci-dessus)." >&2
  exit 1
fi
