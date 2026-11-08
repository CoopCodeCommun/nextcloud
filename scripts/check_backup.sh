#!/bin/bash
set -euo pipefail

##### INSTRUCTION
#
# Verifie que la derniere sauvegarde Nextcloud est REELLEMENT restaurable, sans
# rien restaurer. Lance par :  make check
#
#   1. Une archive recente existe-t-elle ? (sinon : le cron est mort)
#   2. Contient-elle le dump, config.php, les fichiers utilisateurs, le .env ?
#   3. Le dump est-il complet ? Il est deroule ENTIEREMENT dans le pg_restore
#      du conteneur PostgreSQL (meme version que pg_dump), qui n'ecrit rien.
#      Un dump tronque a une taille credible et ne se restaure pas.
#
# Sort en code non nul si quoi que ce soit cloche : branchable en monitoring.
#####

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
STACK_DIR="${STACK_DIR:-$(dirname "$SCRIPT_DIR")}"
COMPOSE_FILE="$STACK_DIR/docker-compose.yml"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

ok()     { echo "  [ok]   $*"; }
ko()     { echo "  [KO]   $*" >&2; ERREURS=$((ERREURS + 1)); }
erreur() { echo "[check] ERREUR : $*" >&2; exit 2; }
ERREURS=0

[ -f "$ENV_FILE" ] || erreur ".env introuvable : $ENV_FILE"
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

: "${BORG_PREFIX:?BORG_PREFIX absent de scripts/.env}"
: "${BORG_REPO:?BORG_REPO absent de scripts/.env}"
: "${BORG_PASSPHRASE:?BORG_PASSPHRASE absent de scripts/.env}"
command -v borg >/dev/null || erreur "borg introuvable dans le PATH."
DB_SERVICE="${DB_SERVICE:-nextcloud_db}"
AGE_MAX_HEURES="${AGE_MAX_HEURES:-25}"

SSH_KEY="${SSH_KEY:-$SCRIPT_DIR/.ssh/${BORG_PREFIX}_ed25519}"
[ -f "$SSH_KEY" ] && export BORG_RSH="/usr/bin/ssh -oStrictHostKeyChecking=accept-new -oIdentitiesOnly=yes -i $SSH_KEY"

# Chemins tels que borg les stocke (sans le / initial).
RACINE="${STACK_DIR#/}"

echo "[check] depot : $BORG_REPO  (archives $BORG_PREFIX-*)"
echo


#### 1. FRAICHEUR ####
echo "1. Fraicheur"
DERNIERE="$(borg list --glob-archives "$BORG_PREFIX-*" --last 1 \
  --format '{archive}{TAB}{time:%Y-%m-%d %H:%M:%S}{NL}' "$BORG_REPO")"
[ -n "$DERNIERE" ] || erreur "aucune archive '$BORG_PREFIX-*' dans le depot."

ARCHIVE="${DERNIERE%%	*}"
DATE_ARCHIVE="${DERNIERE#*	}"
AGE_HEURES=$(( ( $(date +%s) - $(date -d "$DATE_ARCHIVE" +%s) ) / 3600 ))

if [ "$AGE_HEURES" -le "$AGE_MAX_HEURES" ]; then
  ok "derniere archive : $ARCHIVE (il y a ${AGE_HEURES} h)"
else
  ko "derniere archive : $ARCHIVE — ${AGE_HEURES} h, soit plus de ${AGE_MAX_HEURES} h."
  ko "le cron ne tourne plus. Verifie : sudo crontab -l"
fi


#### 2. CONTENU ####
echo
echo "2. Contenu de l'archive"
CONTENU="$(borg list --format '{size}{TAB}{path}{NL}' "$BORG_REPO::$ARCHIVE")"
fichiers_sous() {  # <prefixe> -> nb de fichiers non vides
  printf '%s\n' "$CONTENU" | awk -F'\t' -v p="$1" '$1 > 0 && index($2, p) == 1' | wc -l
}

CHEMIN_DUMP="$(printf '%s\n' "$CONTENU" | awk -F'\t' '$1 > 0 {print $2}' \
  | grep -E '/pg-dump-[^/]+/[^/]+\.dump$' | head -n1 || true)"
if [ -n "$CHEMIN_DUMP" ]; then
  ok "dump PostgreSQL present : ${CHEMIN_DUMP##*/}"
else
  ko "aucun dump PostgreSQL dans l'archive."
fi

if grep -qF "	$RACINE/data/www/html/config/config.php" <<< "$CONTENU"; then
  ok "config.php present"
else
  ko "config.php absent : l'instance ne serait pas remontable telle quelle."
fi

NB_DATA="$(fichiers_sous "$RACINE/data/www/html/data/")"
if [ "$NB_DATA" -gt 0 ]; then
  ok "$NB_DATA fichier(s) dans data/ (fichiers des utilisateurs)"
else
  ko "data/ vide ou absent : les fichiers des utilisateurs ne sont PAS sauvegardes (lance en root ?)"
fi

if grep -qF "	$RACINE/.env" <<< "$CONTENU"; then
  ok ".env de la stack present"
else
  ko ".env de la stack absent."
fi

if grep -qF "	$RACINE/database/" <<< "$CONTENU"; then
  ko "database/ (fichiers PostgreSQL bruts) est dans l'archive : l'exclusion ne marche pas."
fi


#### 3. DUMP RESTAURABLE ? ####
echo
echo "3. Le dump est-il restaurable ?"
if [ -z "$CHEMIN_DUMP" ]; then
  ko "pas de dump a verifier."
elif ! docker compose -f "$COMPOSE_FILE" ps -q "$DB_SERVICE" | grep -q .; then
  ko "conteneur $DB_SERVICE arrete : impossible de valider le dump avec pg_restore."
else
  # pipefail coupe le temps du tuyau : si pg_restore s'arrete tot, borg prend
  # un SIGPIPE (141), ce n'est pas lui qu'on juge.
  set +o pipefail
  if borg extract --stdout "$BORG_REPO::$ARCHIVE" "$CHEMIN_DUMP" 2>/dev/null \
      | docker compose -f "$COMPOSE_FILE" exec -T "$DB_SERVICE" pg_restore -f /dev/null 2>/dev/null; then
    ok "dump complet et lisible par pg_restore"
  else
    ko "dump ILLISIBLE ou TRONQUE : cette sauvegarde n'est pas restaurable."
  fi
  set -o pipefail
fi


#### VERDICT ####
echo
if [ "$ERREURS" -eq 0 ]; then
  echo "[check] La derniere sauvegarde est restaurable."
  exit 0
fi
echo "[check] $ERREURS probleme(s). Cette sauvegarde n'est pas fiable." >&2
exit 1
