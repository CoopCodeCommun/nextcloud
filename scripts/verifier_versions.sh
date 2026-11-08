#!/bin/bash
set -euo pipefail

##### INSTRUCTION
#
# Verifie que les versions du .env (NEXTCLOUD_TAG, POSTGRES_TAG,
# ONLYOFFICE_TAG) sont compatibles avec ce qui est installe, SANS rien
# demarrer ni modifier. Lance par :  make verifier   (et avant make up)
#
# Refuse (code 1) si :
#   - PostgreSQL : le tag n'est pas la version des donnees de database/
#   - Nextcloud  : l'image change de majeure (-> make upgrade) ou en saute une
#   - OnlyOffice : le tag a change sans OO_CONFIRME=1
#####

. "$(dirname -- "$0")/commun.sh"

verifier_tags
IMAGE_NC="nextcloud:$(valeur_env NEXTCLOUD_TAG)"
# Image absente (premier lancement, tag change) : on la recupere pour pouvoir
# lire sa version. Un pull ne touche a aucun conteneur.
docker image inspect "$IMAGE_NC" >/dev/null 2>&1 || docker pull -q "$IMAGE_NC" >/dev/null
verifier_versions
