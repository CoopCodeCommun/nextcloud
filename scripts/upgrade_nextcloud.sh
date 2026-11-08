#!/bin/bash
set -euo pipefail

##### INSTRUCTION
#
# Montee de Nextcloud a la majeure SUIVANTE (et une seule).
# Lance par :  make upgrade              (en root : le Makefile ajoute sudo)
#              make upgrade-check        (verifications seules, rien ne change)
#
#   1. lit la version installee (N) : la cible est N+1, jamais plus
#   2. tire l'image nextcloud:N+1 et lit sa version exacte
#   3. refuse si cette version a moins de MIN_CORRECTIF correctifs
#      (34.0.0 et 34.0.1 essuient les platres) - defaut 2
#   4. interroge l'app store : chaque app installee et activee a-t-elle une
#      version stable pour N+1 ? Sinon elle serait DESACTIVEE par la montee :
#      refus, sauf APPS_OK=1
#   5. ecrit NEXTCLOUD_TAG=N+1 dans le .env, puis lance make update
#      (sauvegarde, migration, finitions, OnlyOffice) avec SAUT_MAJEUR=1
#   6. si make update echoue AVANT que Nextcloud ait change de version,
#      NEXTCLOUD_TAG est remis a N
#
#   ./upgrade_nextcloud.sh --verifier       # etapes 1 a 4 seulement
#   MIN_CORRECTIF=0 APPS_OK=1 ./upgrade_nextcloud.sh   # en connaissance de cause
#
# PostgreSQL et OnlyOffice ne sont pas touches : voir make pg-upgrade et
# ONLYOFFICE_TAG. Verifier que la version de PostgreSQL est supportee par
# la cible (https://docs.nextcloud.com : System requirements).
#####

. "$(dirname -- "$0")/commun.sh"
APP_SERVICE="nextcloud_app"
MIN_CORRECTIF="${MIN_CORRECTIF:-2}"
APPS_OK="${APPS_OK:-0}"
VERIFIER_SEUL=0; [ "${1:-}" = "--verifier" ] && { VERIFIER_SEUL=1; shift; }

occ()   { compose exec -T -u www-data "$APP_SERVICE" php occ --no-warnings "$@"; }
etape() { echo; echo "[nc-upgrade] ===== $* ====="; }
stop()  { echo "[nc-upgrade] REFUS : $*" >&2; exit 1; }

[ "$VERIFIER_SEUL" = 1 ] || [ "$(id -u)" -eq 0 ] || stop "a lancer en root (make upgrade ajoute sudo)."


#### 1. OU EN EST-ON ? ####
etape "1/5 etat actuel"
verifier_tags || exit 1
verifier_postgres || stop "PostgreSQL d'abord (voir ci-dessus)."
INSTALLEE="$(nc_version_installee)"
[ -n "$INSTALLEE" ] || stop "Nextcloud n'est pas installe."
N="$(majeure "$INSTALLEE")"
TAG="$(valeur_env NEXTCLOUD_TAG)"
[ "$(majeure "$TAG")" = "$N" ] \
  || stop "NEXTCLOUD_TAG=$TAG ne correspond pas a l'installation ($INSTALLEE) : remettre NEXTCLOUD_TAG=$N."
occ status --output=json </dev/null | grep -q '"maintenance":false' \
  || stop "Nextcloud ne repond pas ou est en maintenance."
CIBLE=$((N + 1))
echo "[nc-upgrade] installe : $INSTALLEE -> cible : $CIBLE"


#### 2. IMAGE CIBLE ####
etape "2/5 image nextcloud:$CIBLE"
docker pull -q "nextcloud:$CIBLE" >/dev/null 2>&1 \
  || stop "l'image nextcloud:$CIBLE n'existe pas (encore) sur Docker Hub."
VERSION_CIBLE="$(nc_version_image "nextcloud:$CIBLE")"
[ "$(majeure "$VERSION_CIBLE")" = "$CIBLE" ] || stop "image nextcloud:$CIBLE inattendue ($VERSION_CIBLE)."
echo "[nc-upgrade] nextcloud:$CIBLE = $VERSION_CIBLE"


#### 3. MATURITE ####
etape "3/5 maturite (au moins $CIBLE.0.$MIN_CORRECTIF)"
CORRECTIF="$(printf '%s' "$VERSION_CIBLE" | cut -d. -f3)"
[ "${CORRECTIF:-0}" -ge "$MIN_CORRECTIF" ] \
  || stop "$VERSION_CIBLE est trop jeune (moins de $MIN_CORRECTIF correctifs). Attendre, ou MIN_CORRECTIF=0."
echo "[nc-upgrade] $VERSION_CIBLE : OK"


#### 4. APPS ####
etape "4/5 compatibilite des apps avec $VERSION_CIBLE"
# Apps hors noyau ACTIVEES (les desactivees ne bloquent rien).
APPS="$(occ app:list --shipped=false --output=json </dev/null \
  | sed -n 's/.*"enabled":{\([^}]*\)}.*/\1/p' | grep -o '"[^"]*":' | tr -d '":' | tr '\n' ' ')"
[ -n "$APPS" ] || stop "liste des apps illisible."
# L'API de l'app store ne renvoie, pour une version de Nextcloud, que les
# releases compatibles. Interrogee depuis le conteneur (php y est, jq non
# garanti sur l'hote). Sortie : "app OK version" ou "app MANQUE".
# shellcheck disable=SC2086
RAPPORT="$(compose exec -T -u www-data "$APP_SERVICE" php -- "$VERSION_CIBLE" $APPS <<'PHP'
<?php
$version = $argv[1];
$json = @file_get_contents("https://apps.nextcloud.com/api/v1/platform/$version/apps.json");
if ($json === false) { fwrite(STDERR, "app store injoignable\n"); exit(2); }
$store = [];
foreach (json_decode($json, true) as $app) {
  foreach ($app['releases'] as $r) {
    if (strpos($r['version'], '-') === false) { $store[$app['id']][] = $r['version']; }
  }
}
foreach (array_slice($argv, 2) as $id) {
  if (empty($store[$id])) { echo "$id MANQUE\n"; continue; }
  usort($store[$id], 'version_compare');
  echo "$id OK ", end($store[$id]), "\n";
}
PHP
)" || stop "verification des apps impossible (app store injoignable ?)."
printf '%s\n' "$RAPPORT" | sed 's/^/[nc-upgrade]   /'
MANQUE="$(printf '%s\n' "$RAPPORT" | awk '$2 == "MANQUE" {print $1}' | tr '\n' ' ')"
if [ -n "$MANQUE" ]; then
  if [ "$APPS_OK" = 1 ]; then
    echo "[nc-upgrade] [WARN] seront DESACTIVEES par la montee : $MANQUE (APPS_OK=1)"
  else
    stop "pas de version stable pour $CIBLE : $MANQUE-> elles seraient desactivees. Attendre, ou APPS_OK=1."
  fi
fi

if [ "$VERIFIER_SEUL" = 1 ]; then
  echo; echo "[nc-upgrade] verifications OK : 'make upgrade' passerait de $INSTALLEE a $VERSION_CIBLE."
  exit 0
fi


#### 5. MONTEE ####
etape "5/5 NEXTCLOUD_TAG=$CIBLE + make update"
ecrire_env NEXTCLOUD_TAG "$CIBLE"
# Echec avant la migration (sauvegarde ratee...) : on remet le tag, sinon le
# prochain make up / update tenterait la majeure sans verification.
remettre_tag() {
  local v
  # Version illisible : on ne sait pas ou en est la migration, on ne touche a rien.
  v="$(nc_version_installee)" || { echo "[nc-upgrade] ECHEC, version installee illisible : NEXTCLOUD_TAG laisse a $CIBLE." >&2; return; }
  if [ "$(majeure "$v")" = "$N" ]; then
    ecrire_env NEXTCLOUD_TAG "$TAG"
    echo "[nc-upgrade] ECHEC avant la migration : NEXTCLOUD_TAG remis a $TAG." >&2
  else
    echo "[nc-upgrade] ECHEC PENDANT la migration : NEXTCLOUD_TAG reste a $CIBLE." >&2
    echo "             Voir les logs (make logs). Sauvegarde d'avant : make list." >&2
  fi
}
trap remettre_tag EXIT
SAUT_MAJEUR=1 bash "$SCRIPT_DIR/update_nextcloud.sh" "$@"
trap - EXIT

echo "[nc-upgrade] Nextcloud $INSTALLEE -> $(nc_version_installee). Prochaine majeure : make upgrade-check"
