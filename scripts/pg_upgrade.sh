#!/bin/bash
set -euo pipefail

##### INSTRUCTION
#
# Montee de version majeure de PostgreSQL pour la stack Nextcloud
# (faite en 13 -> 18 le 8 nov. 2026 ; PG_CIBLE=19 make pg-upgrade pour la suite).
# Lance par :  make pg-upgrade   (en root : le Makefile ajoute sudo)
#
# Methode : dump / restauration (la plus sure entre deux majeures eloignees).
#   1. sauvegarde borg complete (make backup)
#   2. mode maintenance + arret de Nextcloud : plus aucune ecriture
#   3. dump de l'ancienne base (roles + base) et comptage des lignes de
#      chaque table
#   4. l'ancien dossier database/ est DEPLACE (pas supprime) en
#      database.pgXX/ : retour arriere possible
#   5. docker-compose.yml : nouvelle image (+ nouveau point de montage en
#      passant a PG 18+, qui range ses donnees dans /var/lib/postgresql/18/docker)
#   6. nouvelle base vide, restauration, puis :
#      - mots de passe re-haches en scram-sha-256 (le md5 de PG 13 serait
#        refuse par le pg_hba de l'image 18)
#      - CREATE sur le schema public pour l'utilisateur Nextcloud (retire
#        par defaut depuis PG 15 : les futures migrations en ont besoin)
#   7. comparaison des comptages ligne a ligne : le moindre ecart = echec
#   8. redemarrage de Nextcloud, sortie de maintenance, verification
#
# En cas d'echec apres l'etape 4, retour automatique a l'ancienne base.
# Une fois tout valide, l'ancien dossier peut etre supprime a la main :
#   sudo rm -r database.pgXX scripts/pg-upgrade
#####

PG_CIBLE="${PG_CIBLE:-18}"

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
STACK_DIR="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$STACK_DIR/docker-compose.yml"
DB_SERVICE="nextcloud_db"
APP_SERVICE="nextcloud_app"
WORK_DIR="$SCRIPT_DIR/pg-upgrade"

compose() { docker compose -f "$COMPOSE_FILE" "$@"; }
occ()     { compose exec -T -u www-data "$APP_SERVICE" php occ --no-warnings "$@"; }
etape()   { echo; echo "[pg-upgrade] ===== $* ====="; }
psql_db() { compose exec -T "$DB_SERVICE" sh -c 'exec psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At'; }

# Comptage exact des lignes de chaque table (meme requete avant et apres).
SQL_COMPTAGE="select table_name || ' ' || (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text
from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE' order by 1;"

[ "$(id -u)" -eq 0 ] || { echo "[pg-upgrade] a lancer en root (make pg-upgrade ajoute sudo)." >&2; exit 1; }

IMAGE_ACTUELLE="$(sed -n "/^  $DB_SERVICE:/,/^  [a-z_]*:\$/s/^ *image: *//p" "$COMPOSE_FILE" | head -1)"
VERSION_ACTUELLE="$(compose exec -T "$DB_SERVICE" sh -c 'cat "$PGDATA/PG_VERSION"')"
IMAGE_CIBLE="postgres:${PG_CIBLE}-bookworm"
OLD_DIR="$STACK_DIR/database.pg$VERSION_ACTUELLE"
echo "[pg-upgrade] actuel : $IMAGE_ACTUELLE (donnees PG $VERSION_ACTUELLE) -> cible : $IMAGE_CIBLE"

[ "$VERSION_ACTUELLE" -lt "$PG_CIBLE" ] || { echo "[pg-upgrade] deja en PG $VERSION_ACTUELLE : rien a faire."; exit 0; }
[ ! -e "$OLD_DIR" ] || { echo "[pg-upgrade] $OLD_DIR existe deja (tentative precedente ?) : a examiner avant de relancer." >&2; exit 1; }
# Deux dispositions possibles du volume :
#   ancienne (PG <= 17) : ./database:/var/lib/postgresql/data
#   nouvelle (PG >= 18) : ./database:/var/lib/postgresql   (donnees dans 18/docker)
if grep -qE '^ +- ./database:/var/lib/postgresql/data *$' "$COMPOSE_FILE"; then
  MONTAGE_ANCIEN=1
elif grep -qE '^ +- ./database:/var/lib/postgresql *$' "$COMPOSE_FILE"; then
  MONTAGE_ANCIEN=0
else
  echo "[pg-upgrade] montage ./database:/var/lib/postgresql[/data] introuvable dans le compose." >&2; exit 1
fi
[ "$MONTAGE_ANCIEN" = 1 ] || [ "$PG_CIBLE" -ge 18 ] \
  || { echo "[pg-upgrade] disposition PG 18+ deja en place : cible $PG_CIBLE impossible." >&2; exit 1; }

docker pull -q "$IMAGE_CIBLE" >/dev/null


#### 1. SAUVEGARDE ####
etape "1/8 sauvegarde borg"
bash "$SCRIPT_DIR/backup_nextcloud.sh"


#### 2. PLUS D'ECRITURE ####
etape "2/8 maintenance + arret de Nextcloud"
# Mots de passe en clair, lus AVANT l'arret : on en aura besoin pour les
# re-hacher dans la nouvelle base. Ils ne sont jamais ecrits sur disque.
NC_DBUSER="$(occ config:system:get dbuser)"
NC_DBPASS="$(occ config:system:get dbpassword)"
[ -n "$NC_DBUSER" ] && [ -n "$NC_DBPASS" ] || { echo "[pg-upgrade] dbuser/dbpassword illisibles dans config.php" >&2; exit 1; }
occ maintenance:mode --on
compose stop "$APP_SERVICE"
# Si on echoue AVANT de toucher a la base : on remet simplement Nextcloud.
trap 'echo "[pg-upgrade] ECHEC avant changement de base : redemarrage de Nextcloud." >&2;
      compose start "$APP_SERVICE"; sleep 5; occ maintenance:mode --off || true' EXIT


#### 3. DUMP + COMPTAGE ####
etape "3/8 dump de PG $VERSION_ACTUELLE"
rm -rf "$WORK_DIR"; mkdir -p "$WORK_DIR"; chmod 700 "$WORK_DIR"
compose exec -T "$DB_SERVICE" sh -c 'exec pg_dumpall -U "$POSTGRES_USER" --globals-only' > "$WORK_DIR/globals.sql"
compose exec -T "$DB_SERVICE" sh -c 'exec pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB"' > "$WORK_DIR/base.dump"
compose exec -T "$DB_SERVICE" pg_restore -l < "$WORK_DIR/base.dump" > /dev/null \
  || { echo "[pg-upgrade] dump illisible" >&2; exit 1; }
printf '%s\n' "$SQL_COMPTAGE" | psql_db > "$WORK_DIR/comptage.avant"
echo "[pg-upgrade] dump : $(du -h "$WORK_DIR/base.dump" | cut -f1), $(wc -l < "$WORK_DIR/comptage.avant") tables comptees"


#### 4. ANCIENNE BASE MISE DE COTE ####
etape "4/8 arret de PG $VERSION_ACTUELLE, database/ -> $(basename "$OLD_DIR")/"
compose stop "$DB_SERVICE"
cp -a "$COMPOSE_FILE" "$WORK_DIR/docker-compose.yml.pg$VERSION_ACTUELLE"
mv "$STACK_DIR/database" "$OLD_DIR"

retour_arriere() {
  echo "[pg-upgrade] ECHEC : retour a PG $VERSION_ACTUELLE." >&2
  compose stop "$DB_SERVICE" || true
  compose rm -f "$DB_SERVICE" || true
  cp -a "$WORK_DIR/docker-compose.yml.pg$VERSION_ACTUELLE" "$COMPOSE_FILE"
  [ -d "$STACK_DIR/database" ] && mv "$STACK_DIR/database" "$STACK_DIR/database.echec-pg$PG_CIBLE-$(date +%s)"
  mv "$OLD_DIR" "$STACK_DIR/database"
  compose up -d "$DB_SERVICE" "$APP_SERVICE"
  sleep 15
  occ maintenance:mode --off || true
  echo "[pg-upgrade] Nextcloud est revenu sur PG $VERSION_ACTUELLE. Dump conserve dans $WORK_DIR." >&2
}
trap retour_arriere EXIT


#### 5. COMPOSE ####
etape "5/8 docker-compose.yml : $IMAGE_CIBLE"
sed -i -e "/^  $DB_SERVICE:/,/^  [a-z_]*:\$/s#^\( *image: *\).*#\1$IMAGE_CIBLE#" "$COMPOSE_FILE"
# Passage a la disposition PG 18+ seulement si la cible l'exige.
if [ "$MONTAGE_ANCIEN" = 1 ] && [ "$PG_CIBLE" -ge 18 ]; then
  sed -i -e 's#^\( *- ./database:/var/lib/postgresql\)/data *$#\1#' "$COMPOSE_FILE"
  MONTAGE_ATTENDU='./database:/var/lib/postgresql *$'
elif [ "$MONTAGE_ANCIEN" = 1 ]; then
  MONTAGE_ATTENDU='./database:/var/lib/postgresql/data *$'
else
  MONTAGE_ATTENDU='./database:/var/lib/postgresql *$'
fi
compose config -q
grep -qE "image: $IMAGE_CIBLE\$" "$COMPOSE_FILE" && grep -qE "$MONTAGE_ATTENDU" "$COMPOSE_FILE" \
  || { echo "[pg-upgrade] edition du compose inattendue" >&2; exit 1; }


#### 6. NOUVELLE BASE + RESTAURATION ####
etape "6/8 nouvelle base PG $PG_CIBLE + restauration"
compose up -d "$DB_SERVICE"
# Pendant l'initialisation, le serveur temporaire n'ecoute pas en TCP :
# on attend donc la connexion TCP, signe que l'init est terminee.
for i in $(seq 1 60); do
  compose exec -T "$DB_SERVICE" pg_isready -q -h 127.0.0.1 && break
  [ "$i" -eq 60 ] && { echo "[pg-upgrade] PG $PG_CIBLE ne demarre pas" >&2; compose logs --tail 40 "$DB_SERVICE" >&2; exit 1; }
  sleep 2
done
compose exec -T "$DB_SERVICE" sh -c 'cat "$PGDATA/PG_VERSION"' | grep -qx "$PG_CIBLE"

# Roles : le superutilisateur existe deja (cree par l'image), ses lignes
# CREATE ROLE echouent sans consequence -> pas d'ON_ERROR_STOP ici.
compose exec -T "$DB_SERVICE" sh -c 'exec psql -X -q -U "$POSTGRES_USER" -d postgres' < "$WORK_DIR/globals.sql" 2>&1 \
  | grep -v 'already exists' || true

compose cp "$WORK_DIR/base.dump" "$DB_SERVICE:/tmp/base.dump"
compose exec -T "$DB_SERVICE" sh -c 'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --exit-on-error -j 4 /tmp/base.dump && rm -f /tmp/base.dump'

# Mots de passe re-haches en scram, droits identiques a l'ancienne base.
sql_lit() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }
SUPER_PASS="$(sed -n 's/^POSTGRES_PASSWORD=//p' "$STACK_DIR/.env" | tail -n1 | tr -d "'\"")"
# PIEGE (vecu en 13 -> 18) : un `compose exec` lance DANS un pipeline lit le
# stdin du pipeline et avale le SQL -> psql ne recoit rien, les mots de passe
# restent en md5. Tout ce qui interroge le conteneur se fait donc AVANT, avec
# </dev/null, et on verifie le resultat juste apres.
DB_NAME="$(compose exec -T "$DB_SERVICE" sh -c 'printf %s "$POSTGRES_DB"' </dev/null)"
[ -n "$DB_NAME" ] || { echo "[pg-upgrade] POSTGRES_DB illisible" >&2; exit 1; }
{
  echo "SET password_encryption = 'scram-sha-256';"
  echo "ALTER ROLE \"$NC_DBUSER\" PASSWORD $(sql_lit "$NC_DBPASS");"
  [ -n "$SUPER_PASS" ] && echo "ALTER ROLE CURRENT_USER PASSWORD $(sql_lit "$SUPER_PASS");"
  echo "REVOKE ALL ON DATABASE \"$DB_NAME\" FROM PUBLIC;"
  echo "GRANT CONNECT ON DATABASE \"$DB_NAME\" TO \"$NC_DBUSER\";"
  echo "GRANT ALL ON SCHEMA public TO \"$NC_DBUSER\";"
} | psql_db >/dev/null
MD5_RESTANTS="$(echo "select count(*) from pg_authid where rolcanlogin and rolpassword like 'md5%';" | psql_db)"
[ "$MD5_RESTANTS" = 0 ] || { echo "[pg-upgrade] $MD5_RESTANTS role(s) encore en md5 : refuses par PG $PG_CIBLE" >&2; exit 1; }
echo "[pg-upgrade] mots de passe re-haches en scram-sha-256."
compose exec -T "$DB_SERVICE" sh -c 'exec vacuumdb -U "$POSTGRES_USER" -d "$POSTGRES_DB" --analyze-in-stages -q' </dev/null


#### 7. COMPARAISON ####
etape "7/8 comparaison des comptages"
printf '%s\n' "$SQL_COMPTAGE" | psql_db > "$WORK_DIR/comptage.apres"
if ! diff -u "$WORK_DIR/comptage.avant" "$WORK_DIR/comptage.apres"; then
  echo "[pg-upgrade] des tables different (voir ci-dessus)." >&2
  exit 1
fi
echo "[pg-upgrade] $(wc -l < "$WORK_DIR/comptage.apres") tables identiques ligne a ligne."


#### 8. NEXTCLOUD ####
etape "8/8 redemarrage de Nextcloud"
compose up -d "$APP_SERVICE"
for i in $(seq 1 60); do
  # occ status repond "installe" meme si la base refuse la connexion : on
  # attend une vraie lecture en base avec l'utilisateur Nextcloud.
  occ user:list --limit 1 </dev/null >/dev/null 2>&1 && break
  [ "$i" -eq 60 ] && { echo "[pg-upgrade] Nextcloud n'arrive pas a lire la base" >&2; compose logs --tail 20 "$DB_SERVICE" >&2; exit 1; }
  sleep 5
done
occ maintenance:mode --off
# Connexion reelle a la base avec l'utilisateur Nextcloud (mot de passe scram).
occ user:list --limit 1 >/dev/null || { echo "[pg-upgrade] Nextcloud n'arrive pas a lire la base" >&2; exit 1; }
trap - EXIT

etape "termine"
occ status
echo "[pg-upgrade] PostgreSQL $VERSION_ACTUELLE -> $(compose exec -T "$DB_SERVICE" sh -c 'cat "$PGDATA/PG_VERSION"')"
echo "[pg-upgrade] Ancienne base conservee : $OLD_DIR  (a supprimer une fois rassure : sudo rm -r $OLD_DIR)"
echo "[pg-upgrade] Dumps conserves : $WORK_DIR  (contient les roles : sudo rm -r $WORK_DIR ensuite)"
echo "[pg-upgrade] Pensez a : make backup && make check"
