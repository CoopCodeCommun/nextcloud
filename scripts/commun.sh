# shellcheck shell=bash
##### INSTRUCTION
#
# Bibliotheque commune aux scripts de la stack (a sourcer, pas a lancer) :
#   . "$(dirname "$0")/commun.sh"
#
#   - compose()       docker compose, + docker-compose.override.yml s'il existe
#                     (reglages propres a un serveur, ignores par git)
#   - valeur_env K    lit une variable du .env de la stack
#   - ecrire_env K V  la remplace (ou l'ajoute) SANS changer proprietaire ni droits
#   - verifier_*      garde-fous de version, voir plus bas
#
# Les versions des images vivent dans le .env de chaque instance
# (NEXTCLOUD_TAG, POSTGRES_TAG, ONLYOFFICE_TAG) : le compose est identique
# sur tous les serveurs.
#####

SCRIPT_DIR="${SCRIPT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
STACK_DIR="${STACK_DIR:-$(dirname "$SCRIPT_DIR")}"
COMPOSE_FILE="$STACK_DIR/docker-compose.yml"
OVERRIDE_FILE="$STACK_DIR/docker-compose.override.yml"
STACK_ENV="$STACK_DIR/.env"

# PIEGE : `-f docker-compose.yml` desactive le chargement automatique de
# l'override. On l'ajoute donc nous-memes, comme le ferait `docker compose` seul.
compose() {
  if [ -f "$OVERRIDE_FILE" ]; then
    docker compose -f "$COMPOSE_FILE" -f "$OVERRIDE_FILE" "$@"
  else
    docker compose -f "$COMPOSE_FILE" "$@"
  fi
}

valeur_env() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$STACK_ENV" | tail -n1 | tr -d "'\""; }

# Ecrit K=V dans le .env. `cat >` reecrit le fichier en place : le .env garde
# son proprietaire et son chmod 600, meme lance en root (sed -i, lui, le
# recreerait en root:root et le rendrait illisible pour make onlyoffice).
ecrire_env() {
  local cle="$1" val="$2" tmp
  tmp="$(mktemp)"
  if grep -qE "^[[:space:]]*$cle[[:space:]]*=" "$STACK_ENV"; then
    sed -E "s|^[[:space:]]*$cle[[:space:]]*=.*|$cle=$val|" "$STACK_ENV" > "$tmp"
  else
    { cat "$STACK_ENV"; echo "$cle=$val"; } > "$tmp"
  fi
  cat "$tmp" > "$STACK_ENV"
  rm -f "$tmp"
}
supprimer_env() {
  local tmp; tmp="$(mktemp)"
  grep -vE "^[[:space:]]*$1[[:space:]]*=" "$STACK_ENV" > "$tmp" || true
  cat "$tmp" > "$STACK_ENV"; rm -f "$tmp"
}

# Majeure d'un numero de version : 33.0.10 -> 33
majeure() { printf '%s' "${1%%.*}"; }

# Version de Nextcloud INSTALLEE (le code dans data/, celui que compare
# l'entrypoint de l'image). Vide si pas encore installe.
nc_version_installee() {
  local f="$STACK_DIR/data/www/html/version.php"
  [ -r "$f" ] || return 0
  sed -n "s/^\$OC_VersionString = '\([^']*\)'.*/\1/p" "$f"
}

# Version de Nextcloud contenue dans une image (locale).
nc_version_image() {
  docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null \
    | sed -n 's/^NEXTCLOUD_VERSION=//p'
}

# Version(s) PostgreSQL des donnees presentes dans database/, lues depuis le
# disque (et pas depuis le conteneur, qui peut deja tourner sur une base
# vide fraichement creee). Une ligne par cluster : "<version> <disposition>"
#   ancien  : database/PG_VERSION          (montage .../data, PG <= 17)
#   nouveau : database/18/docker/PG_VERSION (montage /var/lib/postgresql, PG >= 18)
# database/ appartient a l'utilisateur postgres : on lit via un conteneur.
pg_clusters() {
  [ -d "$STACK_DIR/database" ] || return 0
  # Image deja presente (celle du conteneur base actuel) : un tag errone dans
  # le .env ne doit ni tirer une image ni masquer le vrai diagnostic.
  local id image
  id="$(compose ps -aq nextcloud_db 2>/dev/null | head -n1 || true)"
  image="$( [ -n "$id" ] && docker inspect -f '{{.Config.Image}}' "$id" 2>/dev/null || true)"
  image="${image:-postgres:$(valeur_env POSTGRES_TAG)-bookworm}"
  docker run --rm --network none --entrypoint sh \
    -v "$STACK_DIR/database:/d:ro" "$image" -c '
      [ -f /d/PG_VERSION ] && echo "$(cat /d/PG_VERSION) ancien"
      for f in /d/*/docker/PG_VERSION; do [ -f "$f" ] && echo "$(cat "$f") nouveau"; done
      true' </dev/null
}


#### GARDE-FOUS ####
# Chaque fonction affiche l'erreur et renvoie 1 si la configuration du .env
# ne correspond pas a ce qui est installe.

verifier_tags() {
  local k ok=0
  for k in NEXTCLOUD_TAG POSTGRES_TAG ONLYOFFICE_TAG ROUTER_NAME; do
    [ -n "$(valeur_env "$k")" ] || { echo "[versions] $k absent du .env (voir env_example)" >&2; ok=1; }
  done
  return $ok
}

# PostgreSQL : le tag doit etre EXACTEMENT la version des donnees. Une image
# plus recente ne "monte" pas la base : elle cree un cluster VIDE a cote
# (database/19/docker) et Nextcloud se retrouve sur une base vide.
verifier_postgres() {
  local tag montage clusters n version dispo
  tag="$(valeur_env POSTGRES_TAG)"; tag="${tag%%-*}"
  montage="$(valeur_env POSTGRES_MOUNT)"; montage="${montage:-/var/lib/postgresql}"
  clusters="$(pg_clusters)" || { echo "[versions] lecture de database/ impossible" >&2; return 1; }
  n="$(printf '%s' "$clusters" | grep -c . || true)"
  if [ "$n" -eq 0 ]; then
    echo "[versions] PostgreSQL : pas encore de base (nouvelle installation) -> PG $tag."
    return 0
  fi
  if [ "$n" -gt 1 ]; then
    echo "[versions] ERREUR : plusieurs bases dans database/ :" >&2
    printf '%s\n' "$clusters" | sed 's/^/             PG /' >&2
    echo "           A examiner a la main avant toute chose." >&2
    return 1
  fi
  read -r version dispo <<<"$clusters"
  if [ "$version" != "$tag" ]; then
    echo "[versions] ERREUR : la base est en PostgreSQL $version, le .env demande POSTGRES_TAG=$tag." >&2
    if [ "$tag" -gt "$version" ] 2>/dev/null; then
      echo "           Une montee de version se fait par : make pg-upgrade PG_CIBLE=$tag" >&2
      echo "           (remettre d'abord POSTGRES_TAG=$version dans le .env)" >&2
    else
      echo "           Retour en arriere impossible : remettre POSTGRES_TAG=$version." >&2
    fi
    return 1
  fi
  if [ "$dispo" = ancien ] && [ "$montage" != /var/lib/postgresql/data ]; then
    echo "[versions] ERREUR : base PG $version a l'ancienne disposition : il faut" >&2
    echo "           POSTGRES_MOUNT=/var/lib/postgresql/data dans le .env." >&2
    return 1
  fi
  if [ "$dispo" = nouveau ] && [ "$montage" != /var/lib/postgresql ]; then
    echo "[versions] ERREUR : base PG $version dans database/$version/docker : retirer" >&2
    echo "           POSTGRES_MOUNT du .env (ou POSTGRES_MOUNT=/var/lib/postgresql)." >&2
    return 1
  fi
  echo "[versions] PostgreSQL : base PG $version = POSTGRES_TAG. OK"
}

# Nextcloud : l'image doit etre la MEME majeure que l'installation, ou la
# suivante si SAUT_MAJEUR=1 (positionne par make upgrade). Jamais deux
# majeures d'un coup, jamais de retour en arriere.
# Appeler APRES le pull : on lit la version dans l'image locale.
verifier_nextcloud() {
  local image installee cible mi mc
  image="nextcloud:$(valeur_env NEXTCLOUD_TAG)"
  installee="$(nc_version_installee)"
  cible="$(nc_version_image "$image")"
  if [ -z "$cible" ]; then
    echo "[versions] ERREUR : image $image absente en local (docker compose pull)." >&2; return 1
  fi
  if [ -z "$installee" ]; then
    echo "[versions] Nextcloud : pas encore installe -> $cible."; return 0
  fi
  mi="$(majeure "$installee")"; mc="$(majeure "$cible")"
  if [ "$mc" -lt "$mi" ]; then
    echo "[versions] ERREUR : Nextcloud $installee installe, l'image $image est en $cible." >&2
    echo "           Retour en arriere impossible : remettre NEXTCLOUD_TAG=$mi." >&2
    return 1
  fi
  if [ "$mc" -gt $((mi + 1)) ]; then
    echo "[versions] ERREUR : Nextcloud $installee -> $cible saute une majeure." >&2
    echo "           Remettre NEXTCLOUD_TAG=$mi, puis monter une majeure a la fois : make upgrade" >&2
    return 1
  fi
  if [ "$mc" -eq $((mi + 1)) ] && [ "${SAUT_MAJEUR:-0}" != 1 ]; then
    echo "[versions] ERREUR : NEXTCLOUD_TAG=$(valeur_env NEXTCLOUD_TAG) ferait passer Nextcloud de $installee a $cible." >&2
    echo "           Les majeures passent par 'make upgrade' (verifie les apps) :" >&2
    echo "           remettre NEXTCLOUD_TAG=$mi, puis make upgrade." >&2
    return 1
  fi
  echo "[versions] Nextcloud : $installee -> $cible. OK"
}

# OnlyOffice : un changement de tag doit etre voulu (compatibilite du
# connecteur verifiee a la main) : OO_CONFIRME=1.
verifier_onlyoffice() {
  local voulu actuel id
  voulu="onlyoffice/documentserver:$(valeur_env ONLYOFFICE_TAG)"
  id="$(compose ps -q onlyoffice 2>/dev/null || true)"
  [ -n "$id" ] || { echo "[versions] OnlyOffice : pas de conteneur -> $voulu."; return 0; }
  actuel="$(docker inspect -f '{{.Config.Image}}' "$id")"
  if [ "$actuel" != "$voulu" ] && [ "${OO_CONFIRME:-0}" != 1 ]; then
    echo "[versions] ERREUR : OnlyOffice passerait de $actuel a $voulu." >&2
    echo "           Verifier que le connecteur (app onlyoffice) supporte cette version," >&2
    echo "           puis relancer avec OO_CONFIRME=1 (ex. make update OO_CONFIRME=1)." >&2
    return 1
  fi
  echo "[versions] OnlyOffice : $voulu. OK"
}

verifier_versions() {
  verifier_tags || return 1
  local ok=0
  verifier_postgres   || ok=1
  verifier_nextcloud  || ok=1
  verifier_onlyoffice || ok=1
  return $ok
}
