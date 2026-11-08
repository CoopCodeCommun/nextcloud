#!/bin/bash
set -euo pipefail

##### INSTRUCTION
#
# Mise a jour de la stack Nextcloud + OnlyOffice, avec sauvegarde prealable.
# Lance par :  make update   (en root : le Makefile ajoute sudo)
#
#   0. pull des images + GARDE-FOUS (scripts/commun.sh) : on refuse AVANT de
#      toucher a quoi que ce soit si une version ne colle pas
#   1. sauvegarde borg coherente (mode maintenance + pg_dump + fichiers)
#   2. mise a jour des apps sur la version ACTUELLE (avant le saut de version)
#   3. OnlyOffice : deconnexion propre des editeurs (prepare4shutdown), sinon
#      les documents ouverts peuvent perdre leurs dernieres modifications
#   4. up -d : l'image Nextcloud joue elle-meme `occ upgrade` au demarrage
#      quand la version change
#   5. attente de la fin de la montee de version
#   6. finitions : index/colonnes manquants, mise a jour des apps
#   7. reconnexion OnlyOffice depuis le .env, et verification
#
# Les versions sont celles du .env (NEXTCLOUD_TAG=33...) : `make update` suit
# les CORRECTIFS, il ne change jamais de majeure. Il refuse :
#   - une majeure Nextcloud differente de l'installee (-> make upgrade, qui
#     le relance avec SAUT_MAJEUR=1 pour exactement +1)
#   - un POSTGRES_TAG different de la version des donnees (-> make pg-upgrade)
#   - un ONLYOFFICE_TAG change, sauf OO_CONFIRME=1
#
#   ./update_nextcloud.sh              # sauvegarde puis mise a jour
#   ./update_nextcloud.sh --no-backup  # sans sauvegarde (a eviter)
#####

. "$(dirname -- "$0")/commun.sh"
APP_SERVICE="nextcloud_app"
OO_SERVICE="onlyoffice"
# Une montee majeure avec beaucoup de fichiers peut etre longue.
TIMEOUT="${TIMEOUT:-1800}"

occ()     { compose exec -T -u www-data "$APP_SERVICE" php occ --no-warnings "$@"; }
etape()   { echo; echo "[nc-update] ===== $* ====="; }
version() { occ status --output=json 2>/dev/null | sed -n 's/.*"versionstring":"\([^"]*\)".*/\1/p'; }

[ "$(id -u)" -eq 0 ] || { echo "[nc-update] a lancer en root (make update ajoute sudo)." >&2; exit 1; }
[ -f "$COMPOSE_FILE" ] || { echo "[nc-update] compose introuvable : $COMPOSE_FILE" >&2; exit 1; }

VERSION_AVANT="$(version || true)"
echo "[nc-update] version actuelle : ${VERSION_AVANT:-inconnue}"


#### 0. IMAGES + GARDE-FOUS ####
etape "0/7 images + verification des versions"
# Le pull ne touche a aucun conteneur : on peut lire la version des nouvelles
# images et refuser avant la sauvegarde et la coupure.
compose pull
verifier_versions || { echo "[nc-update] ABANDON : rien n'a ete modifie." >&2; exit 1; }


#### 1. SAUVEGARDE ####
if [ "${1:-}" = "--no-backup" ]; then
  etape "sauvegarde IGNOREE (--no-backup)"
else
  etape "1/7 sauvegarde"
  bash "$SCRIPT_DIR/backup_nextcloud.sh"
fi


#### 2. APPS A JOUR SUR LA VERSION ACTUELLE ####
etape "2/7 mise a jour des apps (version actuelle)"
occ app:update --all || echo "[nc-update] [WARN] app:update a signale un probleme, on continue."


#### 3. ONLYOFFICE : DECONNEXION PROPRE ####
etape "3/7 OnlyOffice : enregistrement des documents ouverts"
# PIEGE : prepare4shutdown laisse le Document Server en mode "arret" : il
# refuse toute nouvelle session ("la connexion a ete perdue") alors que son
# /healthcheck repond toujours true. Il faut donc le redemarrer ensuite.
OO_AVANT="$(compose ps -q "$OO_SERVICE" || true)"
if [ -n "$OO_AVANT" ]; then
  compose exec -T "$OO_SERVICE" documentserver-prepare4shutdown.sh \
    || echo "[nc-update] [WARN] prepare4shutdown a echoue, on continue."
fi


#### 4. NOUVELLES IMAGES ####
etape "4/7 redemarrage sur les nouvelles images"
compose up -d
# Image OnlyOffice inchangee => conteneur non recree => toujours en mode
# arret : on le redemarre nous-memes.
if [ -n "$OO_AVANT" ] && [ "$(compose ps -q "$OO_SERVICE")" = "$OO_AVANT" ]; then
  echo "[nc-update] OnlyOffice non recree : redemarrage pour sortir du mode arret."
  compose restart "$OO_SERVICE"
fi


#### 5. ATTENTE DE LA MONTEE DE VERSION ####
etape "5/7 montee de version (max ${TIMEOUT}s)"
# L'image copie le nouveau code puis lance `occ upgrade`. PIEGE : juste apres
# le redemarrage, l'ANCIEN code repond encore "installe, pas de maintenance,
# pas de mise a jour en attente" — avant que la copie ne commence. On attend
# donc que la version installee soit CELLE DE L'IMAGE, pas seulement un statut
# propre (sinon on lance les finitions en plein milieu de la migration).
VERSION_CIBLE="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$(compose ps -q "$APP_SERVICE")" \
  | sed -n 's/^NEXTCLOUD_VERSION=//p')"
echo "[nc-update] version de l'image : ${VERSION_CIBLE:-inconnue}"
ATTENTE=0
while :; do
  STATUS="$(occ status --output=json 2>/dev/null || true)"
  if { [ -z "$VERSION_CIBLE" ] || printf '%s' "$STATUS" | grep -q "\"versionstring\":\"$VERSION_CIBLE\""; } \
     && printf '%s' "$STATUS" | grep -q '"installed":true' \
     && printf '%s' "$STATUS" | grep -q '"maintenance":false' \
     && printf '%s' "$STATUS" | grep -q '"needsDbUpgrade":false'; then
    break
  fi
  if [ "$ATTENTE" -ge "$TIMEOUT" ]; then
    echo "[nc-update] ECHEC : Nextcloud n'a pas fini sa mise a jour en ${TIMEOUT}s." >&2
    compose logs --tail 60 "$APP_SERVICE" >&2 || true
    echo "[nc-update] Sauvegarde d'avant mise a jour : make list (archives nuagefr-*)." >&2
    exit 1
  fi
  sleep 10
  ATTENTE=$((ATTENTE + 10))
done
VERSION_APRES="$(version)"
echo "[nc-update] Nextcloud : ${VERSION_AVANT:-?} -> $VERSION_APRES"


#### 6. FINITIONS ####
etape "6/7 finitions base de donnees et apps"
occ db:add-missing-indices
occ db:add-missing-columns
occ db:add-missing-primary-keys
occ app:update --all || echo "[nc-update] [WARN] app:update a signale un probleme."
occ app:list --disabled --shipped=false 2>/dev/null | sed 's/^/[nc-update] app desactivee : /' || true


#### 7. ONLYOFFICE ####
etape "7/7 OnlyOffice"
bash "$SCRIPT_DIR/onlyoffice_connect.sh"

etape "termine"
occ status
echo "[nc-update] Avertissements restants : make occ CMD=setupchecks"
