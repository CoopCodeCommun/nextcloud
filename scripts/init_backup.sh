#!/bin/bash
set -euo pipefail

##### INSTRUCTION
#
# Configure la sauvegarde borg de la stack Nextcloud vers un serveur
# borgwarehouse (BWH). Lance par :  make init   (en root : le Makefile ajoute sudo)
#
# Prealable :  cp scripts/env_example scripts/.env && chmod 600 scripts/.env
#
# Enchaine : cle SSH dediee -> creation du depot sur BWH -> ecriture de
# scripts/.env -> borg init -> export de la cle -> cron ROOT -> premiere
# sauvegarde -> verification.
#
# Version Nextcloud du init_backup.sh du kit (borgwarehouse/scripts/), comme
# ceux des stacks Keycloak, Docuseal et Etherpad. Differences :
#   - ROOT obligatoire : data/ appartient a www-data. La cle SSH, le cron et le
#     journal (/var/log/borg-nextcloud-<prefixe>.log) sont donc ceux de root ;
#   - heure de la sauvegarde demandee : une heure differente par instance ;
#   - pas de BACKUP_TYPE : le script de sauvegarde est backup_nextcloud.sh ;
#   - scripts/.env part de env_example : les cles BORG_* y sont deja (vides),
#     on les REMPLACE au lieu d'ajouter des lignes a la fin.
#
# REJOUABLE : apres un arret (API injoignable, borg init rate, Ctrl-C), on le
# relance et il reprend ce qui existe au lieu de l'ecraser.
# Il REFUSE de continuer quand le depot configure :
#   - contient DEJA DES ARCHIVES : regenerer une passphrase les rendrait
#     definitivement illisibles. C'est le cas d'une instance deja sauvegardee :
#     make init n'y fait rien, make check suffit ;
#   - ne peut pas etre lu (BWH arrete, verrou, cle SSH refusee, passphrase
#     fausse) : il a peut-etre des archives. Corriger la cause, puis relancer.
#     Methode manuelle : relancer APRES avoir colle la cle publique dans BWH.
#
# TOKEN BWH : ce script ne fait QU'UN appel a l'API — le POST qui cree le depot.
# Un token avec la seule permission "create" suffit (Account > Integrations).
# Tout le reste (init, create, prune, list) passe par SSH avec la cle dediee.
# S'il fuite, un token create-only ne permet ni de lister ni de supprimer tes
# depots. Le script ne le stocke nulle part. Il est saisi au clavier, ou passe
# le temps d'une execution :   sudo BW_API_TOKEN=xxx bash scripts/init_backup.sh
#####

# pwd -P : chemin reel (/home/jonas/miete est un lien vers /poule/miete). La
# ligne de cron est reperee par ce chemin : un autre chemin la doublerait.
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
SCRIPT_BACKUP="$SCRIPT_DIR/backup_nextcloud.sh"
# Journal : /var/log/borg-nextcloud-<prefixe>.log (un par instance), fixe
# une fois le prefixe connu. LOG_FILE=... pour l'imposer.
LOG_FILE="${LOG_FILE:-}"
# Instance : ROUTER_NAME du .env de la stack (unique par instance), pour
# proposer un prefixe qui ne collisionne pas avec une autre instance.
ROUTER_NAME="$(sed -n 's/^[[:space:]]*ROUTER_NAME[[:space:]]*=[[:space:]]*//p' "$(dirname "$SCRIPT_DIR")/.env" 2>/dev/null | tail -n1 | tr -d "'\"")"

BW_API_URL_DEFAUT="http://localhost:3000"
BW_SSH_PORT_DEFAUT="2226"

dire()   { echo "[init] $*"; }
erreur() { echo "[init] ERREUR : $*" >&2; exit 1; }
demander() {  # demander <invite> [defaut] -> reponse sur stdout
  local invite="$1" defaut="${2:-}" reponse=""
  if [ -n "$defaut" ]; then
    read -r -p "$invite [$defaut] : " reponse || true
    echo "${reponse:-$defaut}"
  else
    read -r -p "$invite : " reponse || true
    echo "$reponse"
  fi
}


#### PREREQUIS ####
[ "$(id -u)" -eq 0 ] || erreur "a lancer en root (make init ajoute sudo) : la sauvegarde lit data/ (www-data)."
[ -t 0 ] || erreur "make init est interactif : lance-le depuis un terminal."
[ -f "$ENV_FILE" ] || erreur "scripts/.env introuvable. Commence par :  cp scripts/env_example scripts/.env && chmod 600 scripts/.env"
[ -f "$SCRIPT_BACKUP" ] || erreur "script introuvable : $SCRIPT_BACKUP"

for outil in borg ssh-keygen openssl curl crontab flock; do
  command -v "$outil" >/dev/null || erreur "$outil introuvable dans le PATH."
done

valeur_env() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$ENV_FILE" | tail -n1 | tr -d "'\""; }

# Remplace (ou ajoute) K=V dans scripts/.env. `cat >` reecrit le fichier en
# place : il garde son proprietaire et son chmod. La valeur passe par awk
# (ENVIRON) et non par sed : une passphrase base64 contient / et +.
ecrire_env() {
  local tmp; tmp="$(mktemp)"
  CLE="$1" VAL="$2" awk '
    BEGIN { cle = ENVIRON["CLE"]; val = ENVIRON["VAL"]; fait = 0 }
    $0 ~ "^[[:space:]]*" cle "[[:space:]]*=" { if (!fait) print cle "=" val; fait = 1; next }
    { print }
    END { if (!fait) print cle "=" val }' "$ENV_FILE" > "$tmp"
  cat "$tmp" > "$ENV_FILE"
  rm -f "$tmp"
}

BORG_PREFIX="$(valeur_env BORG_PREFIX)"
BORG_REPO="$(valeur_env BORG_REPO)"
BORG_PASSPHRASE="$(valeur_env BORG_PASSPHRASE)"
# Valeur d'exemple de env_example : ce n'est pas un depot.
case "$BORG_REPO" in *XXXXXXXX*) BORG_REPO="" ;; esac


# Comme backup_nextcloud.sh : sinon borg pose une question (invisible ici)
# et echoue si le depot a change d'adresse.
export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes


#### GARDE-FOU : ne jamais rendre des archives existantes illisibles ####
# La vraie question n'est pas "le .env est-il rempli ?" mais "y a-t-il des
# archives a proteger ?". On interroge le depot des que BORG_REPO est rempli,
# et on ne continue QUE dans deux cas sans ambiguite :
#   - borg lit le depot et il n'a aucune archive : init precedent arrete en
#     route -> on reprend ;
#   - borg dit que le depot n'est pas (encore) initialise -> on l'initialise.
# Tout autre echec (BWH injoignable, cle refusee, verrou pris par le cron,
# passphrase fausse ou absente pour un depot existant) : REFUS. Continuer
# ferait generer une cle SSH ou une passphrase pour un depot qui en a deja.
REPRISE=0
DEPOT_PREVU=0   # BORG_REPO venait de scripts/.env : ne pas creer de depot
CLE_DEDIEE=0    # une cle scripts/.ssh/ existait avant ce script
if [ -n "$BORG_REPO" ]; then
  DEPOT_PREVU=1
  [ -n "$BORG_PREFIX" ] || erreur "BORG_REPO est dans scripts/.env, mais pas BORG_PREFIX : a completer a la main."
  dire "un depot est deja configure dans scripts/.env — je l'interroge..."
  # Sans cle dediee, ssh prend la cle de root (installation faite a la main).
  CLE_EXISTANTE="$SCRIPT_DIR/.ssh/${BORG_PREFIX}_ed25519"
  if [ -f "$CLE_EXISTANTE" ]; then
    CLE_DEDIEE=1
    export BORG_RSH="/usr/bin/ssh -oStrictHostKeyChecking=accept-new -oIdentitiesOnly=yes -i $CLE_EXISTANTE"
  fi

  SORTIE_ERR="$(mktemp)"
  if ARCHIVES="$(BORG_PASSPHRASE="$BORG_PASSPHRASE" borg list --short "$BORG_REPO" 2>"$SORTIE_ERR" </dev/null)"; then
    ERR=""; LU=1
  else
    ERR="$(cat "$SORTIE_ERR")"; LU=0
  fi
  rm -f "$SORTIE_ERR"

  if [ "$LU" = 1 ] && [ -n "$ARCHIVES" ]; then
    NB="$(printf '%s\n' "$ARCHIVES" | wc -l)"
    echo >&2
    echo "[init] Le depot contient deja $NB archive(s)." >&2
    echo >&2
    echo "  Ce script s'arrete ici, VOLONTAIREMENT." >&2
    echo "  Regenerer une passphrase rendrait ces archives DEFINITIVEMENT" >&2
    echo "  ILLISIBLES — y compris celles deja envoyees chez BWH." >&2
    echo >&2
    echo "  Pour verifier la sauvegarde en place :   make check" >&2
    exit 1
  elif [ "$LU" = 1 ]; then
    [ -n "$BORG_PASSPHRASE" ] || erreur "depot lisible sans passphrase : inattendu, a examiner a la main."
    dire "depot vide : je reprends la configuration la ou elle s'est arretee."
    REPRISE=1
  elif printf '%s' "$ERR" | grep -qiE 'does not exist|is not a valid repository'; then
    dire "depot pas encore initialise : je continue."
    [ -z "$BORG_PASSPHRASE" ] || REPRISE=1
  else
    echo >&2
    echo "[init] REFUS : impossible de lire le depot $BORG_REPO :" >&2
    printf '%s\n' "$ERR" | sed 's/^/         /' >&2
    echo >&2
    echo "  Il a peut-etre deja des archives : rien n'est modifie." >&2
    echo "  Causes courantes : borgwarehouse arrete, sauvegarde en cours (verrou)," >&2
    echo "  cle SSH refusee, BORG_PASSPHRASE absente ou fausse dans scripts/.env." >&2
    echo "  Corriger, puis relancer make init (ou make check)." >&2
    exit 1
  fi
fi


#### 1. PREFIXE ET FREQUENCE ####
echo
dire "Configuration de la sauvegarde Nextcloud"
echo

# Depot deja dans scripts/.env : le prefixe nomme sa cle SSH (deja connue de
# BWH), on ne le change pas.
if [ "$REPRISE" = 0 ] && [ "$DEPOT_PREVU" = 0 ]; then
  BORG_PREFIX="$(demander "Prefixe des archives (nomme aussi la cle SSH)" "${BORG_PREFIX:-nextcloud-$(printf '%s' "${ROUTER_NAME:-$(hostname -s)}" | tr -cd 'a-zA-Z0-9_-')}")"
  # Un prefixe avec des espaces casserait le nom des archives et le glob du prune.
  case "$BORG_PREFIX" in
    ''|*[!a-zA-Z0-9_-]*) erreur "prefixe invalide : lettres, chiffres, - et _ uniquement." ;;
  esac
else
  dire "prefixe repris de scripts/.env : $BORG_PREFIX"
fi

# La frequence est demandee AVANT de creer le depot : elle determine l'alerte
# BWH et le seuil de make check, qui doivent rester coherents entre eux.
# Pas de frequence horaire : chaque sauvegarde met Nextcloud en maintenance.
echo
dire "Frequence de sauvegarde :"
echo "   1) quotidienne (recommande)"
echo "   2) hebdomadaire"
echo "   3) aucune (je poserai le cron moi-meme)"
case "$(demander "Ton choix" "1")" in
  2) JOURS="0"  ; ALERTE=864000 ; AGE_MAX=169 ;;
  3) JOURS=""   ; ALERTE=90000  ; AGE_MAX=25  ;;
  *) JOURS="*"  ; ALERTE=90000  ; AGE_MAX=25  ;;
esac
PLANIF=""
if [ -n "$JOURS" ]; then
  # Une autre instance sur le meme serveur : une autre heure, sinon deux
  # maintenances et deux borg create en meme temps.
  HEURE="$(demander "Heure de la sauvegarde (0-23, une autre par instance)" "0")"
  case "$HEURE" in
    [0-9]|1[0-9]|2[0-3]) : ;;
    *) erreur "heure invalide : 0 a 23." ;;
  esac
  PLANIF="0 $HEURE * * $JOURS"
fi
LOG_FILE="${LOG_FILE:-/var/log/borg-nextcloud-$BORG_PREFIX.log}"


#### 2. CLE SSH DEDIEE (une cle = un depot sur BWH) ####
SSH_KEY="$SCRIPT_DIR/.ssh/${BORG_PREFIX}_ed25519"
if [ "$DEPOT_PREVU" = 1 ] && [ "$CLE_DEDIEE" = 0 ]; then
  # Depot configure a la main, joint avec la cle de root (le garde-fou vient
  # de le prouver). Surtout PAS de nouvelle cle : backup_nextcloud.sh et
  # check_backup.sh l'utiliseraient des qu'elle existe, et BWH ne la connait
  # pas -> plus aucune sauvegarde.
  SSH_KEY=""
  dire "depot joint avec la cle SSH de root : pas de cle dediee."
elif [ -f "$SSH_KEY" ]; then
  dire "cle SSH existante reutilisee : $SSH_KEY"
else
  mkdir -p "$SCRIPT_DIR/.ssh"
  chmod 700 "$SCRIPT_DIR/.ssh"
  ssh-keygen -t ed25519 -N '' -C "borg-$BORG_PREFIX" -f "$SSH_KEY" >/dev/null
  dire "cle SSH generee : $SSH_KEY"
fi
if [ -n "$SSH_KEY" ]; then
  chmod 600 "$SSH_KEY"
  export BORG_RSH="/usr/bin/ssh -oStrictHostKeyChecking=accept-new -oIdentitiesOnly=yes -i $SSH_KEY"
fi


#### 3. PASSPHRASE ####
[ -n "$BORG_PASSPHRASE" ] || BORG_PASSPHRASE="$(openssl rand -base64 32)"
export BORG_PASSPHRASE


#### 4. LE DEPOT SUR BORGWAREHOUSE ####
if [ -z "$BORG_REPO" ]; then
  echo
  dire "Creation du depot sur borgwarehouse."
  dire "Un token API automatise cette etape (Account > Integrations)."
  dire "La permission 'create' SEULE suffit : c'est le seul appel qu'on fait."
  dire "Sans token, tu creeras le depot a la main dans l'interface."
  echo

  BW_API_URL="$(demander "URL de borgwarehouse" "$BW_API_URL_DEFAUT")"
  BW_SSH_PORT="$(demander "Port SSH de borgwarehouse" "$BW_SSH_PORT_DEFAUT")"

  if [ -z "${BW_API_TOKEN:-}" ]; then
    read -r -s -p "[init] Token API BWH, permission 'create' (vide = methode manuelle) : " BW_API_TOKEN || true
    echo
  fi

  if [ -n "${BW_API_TOKEN:-}" ]; then
    # Les fichiers des utilisateurs partent dans l'archive : prevoir large.
    QUOTA="$(demander "Quota du depot, en Go" "100")"
    case "$QUOTA" in ''|*[!0-9]*) erreur "quota invalide : un nombre entier de Go." ;; esac
    dire "POST $BW_API_URL/api/v1/repositories"
    REPONSE="$(curl -sS --fail-with-body -X POST "$BW_API_URL/api/v1/repositories" \
      -H "Authorization: Bearer $BW_API_TOKEN" \
      -H "Content-Type: application/json" \
      --data-binary @- <<EOF || erreur "l'appel a l'API BWH a echoue (token invalide ? URL incorrecte ?). Tu peux relancer make init : rien n'est perdu."
{
  "alias": "$BORG_PREFIX",
  "sshPublicKey": "$(cat "${SSH_KEY}.pub")",
  "storageSize": $QUOTA,
  "comment": "nextcloud — cree par make init",
  "alert": $ALERTE,
  "lanCommand": false,
  "appendOnlyMode": false
}
EOF
)"
    # Reponse : {"id":2,"repositoryName":"c1ddd097"}. L'adresse SSH n'y est pas :
    # elle est deterministe, on la reconstruit.
    NOM_DEPOT="$(printf '%s' "$REPONSE" | sed -n 's/.*"repositoryName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    [ -n "$NOM_DEPOT" ] || erreur "reponse inattendue de l'API : $REPONSE"
    HOTE_BWH="$(printf '%s' "$BW_API_URL" | sed -e 's#^https\?://##' -e 's#/.*##' -e 's#:.*##')"
    BORG_REPO="ssh://borgwarehouse@$HOTE_BWH:$BW_SSH_PORT/./$NOM_DEPOT"
    dire "depot cree : $NOM_DEPOT"
  else
    echo
    dire "Sur $BW_API_URL :"
    dire "  1. New repository"
    dire "  2. colle la cle publique ci-dessous"
    dire "  3. regle Alert (c'est elle qui previendra si une sauvegarde manque)"
    dire "  4. copie l'adresse SSH du depot (icone en haut a droite de sa vignette)"
    echo
    cat "${SSH_KEY}.pub"
    echo
  fi

  BORG_REPO="$(demander "Adresse SSH du depot" "$BORG_REPO")"
  case "$BORG_REPO" in
    ssh://*|/*) : ;;
    *) erreur "adresse invalide : elle doit commencer par ssh:// (ou / pour un depot local)." ;;
  esac
else
  dire "depot repris de scripts/.env : $BORG_REPO"
fi
export BORG_REPO


#### 5. INIT DU DEPOT ####
# On ecrit scripts/.env AVANT : si borg init echoue, la passphrase n'est pas
# perdue et make init peut etre relance (le garde-fou verra un depot sans archive).
if [ "$REPRISE" = 0 ]; then
  ecrire_env BORG_PREFIX "$BORG_PREFIX"
  ecrire_env BORG_REPO "$BORG_REPO"
  ecrire_env BORG_PASSPHRASE "'$BORG_PASSPHRASE'"
  dire "scripts/.env complete."
fi
# Hors du bloc : en reprise, la frequence choisie peut avoir change, et le
# seuil de make check doit la suivre.
ecrire_env AGE_MAX_HEURES "$AGE_MAX"
chmod 600 "$ENV_FILE"

if borg list "$BORG_REPO" >/dev/null 2>&1; then
  dire "depot deja initialise."
else
  dire "initialisation du depot (repokey-blake2)..."
  borg init -e repokey-blake2 "$BORG_REPO"
fi


#### 6. LE COFFRE-FORT ####
echo
echo "================================================================"
echo " A METTRE DANS UN COFFRE-FORT NUMERIQUE, MAINTENANT."
echo
echo " Sans ces elements, les archives sont un bloc chiffre"
echo " definitivement illisible. C'est le seul maillon que la"
echo " sauvegarde ne peut pas se sauvegarder elle-meme."
echo "================================================================"
echo
echo "Depot      : $BORG_REPO"
echo "Passphrase : $BORG_PASSPHRASE"
echo
echo "Cle du depot (borg key export) :"
echo "----------------------------------------------------------------"
borg key export "$BORG_REPO"
echo "----------------------------------------------------------------"
echo
[ "$(demander "Tape OUI quand c'est copie au coffre" "")" = "OUI" ] \
  || erreur "abandon. Le depot et scripts/.env sont en place : relance make init quand tu es pret (il reprendra ici)."


#### 7. CRON (celui de root) ####
if [ -n "$PLANIF" ]; then
  LIGNE_CRON="$PLANIF bash $SCRIPT_BACKUP >> $LOG_FILE 2>&1"
  # crontab -l sort en erreur quand le crontab est vide : on absorbe.
  CRON_ACTUEL="$(crontab -l 2>/dev/null || true)"
  # On matche le chemin ABSOLU : plusieurs instances Nextcloud peuvent
  # cohabiter sur la meme machine, un grep laxiste en priverait une.
  # Une ligne commentee (sauvegarde desactivee) ne compte pas. En deux temps :
  # avec pipefail, `grep -v | grep -q` peut echouer (SIGPIPE) et doubler la ligne.
  CRON_ACTIF="$(printf '%s\n' "$CRON_ACTUEL" | grep -v '^[[:space:]]*#' || true)"
  if grep -Fq -- "$SCRIPT_BACKUP" <<<"$CRON_ACTIF"; then
    dire "une ligne de cron root existe deja pour ce script — inchangee."
  else
    printf '%s\n%s\n' "$CRON_ACTUEL" "$LIGNE_CRON" | grep -v '^[[:space:]]*$' | crontab -
    dire "cron root pose : $LIGNE_CRON"
  fi
fi


#### 8. PREMIERE SAUVEGARDE, ET VERIFICATION ####
echo
dire "premiere sauvegarde (Nextcloud passe en maintenance le temps du dump et de l'archive)..."
bash "$SCRIPT_BACKUP"
echo
dire "verification..."
bash "$SCRIPT_DIR/check_backup.sh"
echo
dire "termine. Verifie la sauvegarde quand tu veux avec : make check"
