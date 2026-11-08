#!/bin/bash
set -euo pipefail

##### INSTRUCTION
#
# Sauvegarde de la stack Nextcloud vers un depot borgwarehouse (BWH).
# Lance par :  make backup   (ou le cron root, voir plus bas)
#
# Principe (meme modele que la stack Ghost) :
#   mode maintenance ON -> pg_dump coherent -> UNE archive borg de tout le
#   dossier de la stack -> mode maintenance OFF -> prune.
#
# L'archive contient donc le dump PostgreSQL, data/www/html (config.php, apps,
# et surtout data/ : les fichiers des utilisateurs), le .env et le
# docker-compose.yml : tout pour remonter l'instance de zero, coherent au meme
# instant.
#
# Le mode maintenance garantit que la base et les fichiers correspondent : sans
# lui, un fichier envoye pendant la sauvegarde peut exister dans le dump sans
# etre dans l'archive (ou l'inverse). Il ne dure que le temps du dump et du
# borg create (quelques minutes, a minuit). Un trap le desactive TOUJOURS, meme
# si le script echoue. NC_MAINTENANCE=0 dans scripts/.env pour s'en passer.
#
# Exclusions :
#   database/      fichiers bruts PostgreSQL — les copier a chaud donne une base
#                  potentiellement corrompue ; le dump est la seule forme fiable
#   .git/          deja sur GitHub
#   scripts/.ssh/  la cle privee du depot : on ne l'archive pas dans le depot
#                  qu'elle protege
#
# DROITS : data/www/html/data appartient a www-data. La sauvegarde doit tourner
# en ROOT (cron root). Le Makefile ajoute sudo tout seul.
#
# CONFIGURATION : aucun secret ici. Tout est dans scripts/.env (chmod 600,
# ignore par git). PAS dans le .env de la stack : la passphrase n'a rien a
# faire avec les variables du compose.
#####

## Surveillance optionnelle via Sentry (l'ancien backup.sh l'utilisait) :
# export SENTRY_DSN=''
# eval "$(sentry-cli bash-hook)"


SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
STACK_DIR="${STACK_DIR:-$(dirname "$SCRIPT_DIR")}"
COMPOSE_FILE="$STACK_DIR/docker-compose.yml"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

[ -f "$ENV_FILE" ] || { echo "[nc-borg] .env introuvable : $ENV_FILE (cp env_example .env)" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

PREFIX="${BORG_PREFIX:?BORG_PREFIX doit etre renseigne dans scripts/.env}"
NC_MAINTENANCE="${NC_MAINTENANCE:-1}"
DB_SERVICE="${DB_SERVICE:-nextcloud_db}"
APP_SERVICE="${APP_SERVICE:-nextcloud_app}"

# Cle SSH dediee si presente, sinon la config SSH systeme (cle de root).
SSH_KEY="${SSH_KEY:-$SCRIPT_DIR/.ssh/${PREFIX}_ed25519}"

# Le dump est depose DANS la stack pour partir dans la meme archive.
DUMP_DIR="${DUMP_DIR:-$SCRIPT_DIR/pg-dump-$PREFIX}"


#### PREPARATION ####
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes
export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes

# Une seule sauvegarde a la fois : sinon deux executions partagent DUMP_DIR, la
# premiere a finir le supprime et l'autre archive SANS dump, silencieusement.
exec 9>"$SCRIPT_DIR/.backup-$PREFIX.lock"
flock -n 9 || { echo "[nc-borg] une sauvegarde est deja en cours — abandon." >&2; exit 1; }

: "${BORG_REPO:?BORG_REPO doit etre renseigne dans scripts/.env}"
: "${BORG_PASSPHRASE:?BORG_PASSPHRASE doit etre renseigne dans scripts/.env}"
for outil in borg docker flock; do
  command -v "$outil" >/dev/null || { echo "[nc-borg] $outil introuvable dans le PATH" >&2; exit 1; }
done
[ -f "$COMPOSE_FILE" ] || { echo "[nc-borg] compose introuvable : $COMPOSE_FILE" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || echo "[nc-borg] [WARN] pas root : data/ (www-data) sera illisible." >&2

# compose() : + docker-compose.override.yml s'il existe
. "$SCRIPT_DIR/commun.sh"
occ()     { compose exec -T -u www-data "$APP_SERVICE" php occ "$@"; }

DATE_NOW=$(date +%Y-%m-%d-%H-%M)

if [ -f "$SSH_KEY" ]; then
  chmod 600 "$SSH_KEY" 2>/dev/null || true
  export BORG_RSH="/usr/bin/ssh -oStrictHostKeyChecking=accept-new -oIdentitiesOnly=yes -i $SSH_KEY"
fi


#### NETTOYAGE GARANTI ####
MAINTENANCE_ACTIVEE=0
nettoyage() {
  if [ "$MAINTENANCE_ACTIVEE" = 1 ]; then
    occ maintenance:mode --off >/dev/null 2>&1 \
      && echo "$(date +%H:%M:%S) mode maintenance OFF" \
      || echo "[nc-borg] ATTENTION : impossible de sortir du mode maintenance !" \
              "Lancer : docker compose exec -u www-data $APP_SERVICE php occ maintenance:mode --off" >&2
  fi
  rm -rf "$DUMP_DIR"
}
trap nettoyage EXIT


#### MODE MAINTENANCE ####
if [ "$NC_MAINTENANCE" = 1 ]; then
  occ maintenance:mode --on >/dev/null
  MAINTENANCE_ACTIVEE=1
  echo "$DATE_NOW mode maintenance ON"
fi


#### DUMP POSTGRES ####
rm -rf "$DUMP_DIR"
mkdir -p "$DUMP_DIR"
chmod 700 "$DUMP_DIR"

DB_NAME="$(compose exec -T "$DB_SERVICE" printenv POSTGRES_DB)"
DUMP_FILE="$DUMP_DIR/$DB_NAME.dump"
echo "$DATE_NOW dump de la base '$DB_NAME' (pg_dump -Fc dans $DB_SERVICE)"
# User et base lus DANS le conteneur ; le mot de passe ne transite pas ici.
compose exec -T "$DB_SERVICE" sh -c 'exec pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB"' > "$DUMP_FILE"

[ -s "$DUMP_FILE" ] || { echo "[nc-borg] dump vide ($DUMP_FILE) — abandon" >&2; exit 1; }
echo "$(date +%H:%M:%S) dump : $(du -h "$DUMP_FILE" | cut -f1)"


#### BORG CREATE ####
# Codes borg : 0 ok, 1 avertissement (fichier qui bouge, illisible), >=2 erreur.
borg_tolerant() {
  local rc=0
  "$@" || rc=$?
  if [ "$rc" -ge 2 ]; then
    echo "[nc-borg] ERREUR : '$1 $2' a echoue (code $rc)" >&2
    exit "$rc"
  fi
  [ "$rc" -eq 1 ] && echo "[nc-borg] (avertissement borg, code 1 — voir ci-dessus)" >&2
  return 0
}

echo "$DATE_NOW on cree l'archive borg (dossier complet de la stack)"
borg_tolerant /usr/bin/borg create -s --compression lz4 \
  --exclude "$STACK_DIR/database" \
  --exclude "$STACK_DIR/database.*" \
  --exclude "$SCRIPT_DIR/pg-upgrade" \
  --exclude "$STACK_DIR/.git" \
  --exclude "$SCRIPT_DIR/.ssh" \
  --exclude "$SCRIPT_DIR/.backup-*.lock" \
  "$BORG_REPO::$PREFIX-$DATE_NOW" \
  "$STACK_DIR"

# Sortie du mode maintenance des que l'archive est faite (le prune n'en a pas
# besoin) ; le trap ne refera rien.
if [ "$MAINTENANCE_ACTIVEE" = 1 ]; then
  occ maintenance:mode --off >/dev/null
  MAINTENANCE_ACTIVEE=0
  echo "$(date +%H:%M:%S) mode maintenance OFF"
fi


#### PRUNE ####
# --glob-archives : ne touche QUE les archives de cette sauvegarde.
echo "$DATE_NOW on prune les vieux borg :"
borg_tolerant /usr/bin/borg prune --list \
  --glob-archives "$PREFIX-*" \
  --keep-within=7d --keep-daily=30 --keep-weekly=12 --keep-monthly=-1 --keep-yearly=-1 \
  "$BORG_REPO"

echo "$(date +%Y-%m-%d-%H-%M) termine"
