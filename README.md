# Docker compose : Nextcloud 33 + OnlyOffice 10 + PostgreSQL 18 + Redis 7 + Traefik v3

Installation de Nextcloud derrière Traefik v3 via docker compose, avec OnlyOffice
connecté automatiquement et des sauvegardes borg vers BorgWarehouse.

Brouillons de note de blog : https://codimd.communecter.org/s/QicjJT2X7

Les exemples ici sont avec les DNS suivants :
- nuage.lamiete.fr
- onlyoffice.lamiete.fr

À changer bien sûr avec vos propres adresses :)

| Service | Image | Version (`.env`) |
|---|---|---|
| `nextcloud_app` | `nextcloud:${NEXTCLOUD_TAG}` | `NEXTCLOUD_TAG=33` |
| `nextcloud_db` | `postgres:${POSTGRES_TAG}-bookworm` | `POSTGRES_TAG=18` |
| `nextcloud_redis` | `redis:7.4` | — |
| `onlyoffice` | `onlyoffice/documentserver:${ONLYOFFICE_TAG}` | `ONLYOFFICE_TAG=10.0` |

Le `docker-compose.yml` est **le même sur toutes les instances** (lamiete,
codecommun…) : ce qui change d'un serveur à l'autre vit dans le `.env`
(versions, domaine, `ROUTER_NAME`) et, si besoin, dans un
`docker-compose.override.yml` local (ignoré par git).

Historique des migrations, bugs rencontrés et corrections : [`changelog/`](changelog/)
(procédures de restauration comprises).

---

## Au quotidien : le Makefile

```
make up / down / restart    démarre, arrête, redémarre la stack
make logs                   suit les logs de Nextcloud
make ps                     état des conteneurs
make occ CMD="status"       lance une commande occ

make init                   configure la sauvegarde : clé SSH, dépôt BWH, cron root (sudo)
make backup                 sauvegarde borg maintenant (sudo)
make check                  vérifie que la dernière sauvegarde est restaurable (sudo)
make list                   liste les archives du dépôt (sudo)
make mount / umount         monte les archives en lecture seule (ARCHIVE=<nom>, sudo)

make verifier               les versions du .env collent-elles à l'installé ? (rien ne change)
make update                 correctifs : sauvegarde, puis Nextcloud + OnlyOffice (sudo)
make upgrade-check          la majeure Nextcloud suivante est-elle possible ?
make upgrade                Nextcloud : majeure suivante, apps vérifiées (sudo)
make onlyoffice             (re)connecte OnlyOffice depuis le JWT_SECRET du .env
make pg-upgrade PG_CIBLE=19 PostgreSQL : version majeure (sudo)
```

`make up` et `make update` passent d'abord par `make verifier` : ils refusent de
démarrer sur une combinaison de versions dangereuse (voir « Mises à jour »).

La logique vit dans `scripts/` ; le Makefile n'est qu'une table des matières.

---

## Installation

### 1. Fichiers `.env`

Deux fichiers, à ne jamais commiter (voir `.gitignore`), en `chmod 600` :

- **`.env`** (stack) — copier `env_example` : `POSTGRES_*`, `DOMAIN`,
  `NEXTCLOUD_TRUSTED_DOMAINS`, `JWT_SECRET`, `ROUTER_NAME`, et les versions
  `NEXTCLOUD_TAG`, `POSTGRES_TAG`, `ONLYOFFICE_TAG`.
  Générer le secret OnlyOffice : `openssl rand -hex 32`.
  `ROUTER_NAME` suffixe les routeurs Traefik : **unique par instance** si
  plusieurs Nextcloud partagent le même Traefik (ex. `lamiete`, `codecommun`).
  Pour une instance existante, les versions sont **celles déjà installées**
  (`make verifier` le confirme) ; une base PostgreSQL ≤ 17 demande en plus
  `POSTGRES_MOUNT=/var/lib/postgresql/data`.
- **`scripts/.env`** (sauvegarde) — copier `scripts/env_example` : `BORG_PREFIX`,
  `BORG_REPO`, `BORG_PASSPHRASE` (remplis par `make init`, voir « 6.
  Sauvegardes »), `NC_MAINTENANCE`, `AGE_MAX_HEURES`.
  Ces variables ne vont **pas** dans le `.env` de la stack : il est passé en
  entier au conteneur PostgreSQL (`env_file`).

Puis : `make up`.

Aucun port n'est publié sur l'hôte : tout passe par Traefik (réseau `frontend`),
y compris les échanges Nextcloud ↔ OnlyOffice, qui utilisent les adresses
publiques en HTTPS. Pas de `container_name` non plus : les conteneurs
s'appellent `<dossier>-<service>-1`, et les scripts passent par
`docker compose`.

Réglages propres à un serveur : dans `docker-compose.override.yml` (ignoré par
git, chargé par `docker compose` comme par les scripts), pas dans le compose
commun. Exemple, si le serveur ne sait pas se joindre par sa propre IP publique
(NAT sans hairpin) :

```yaml
services:
  nextcloud_app:
    extra_hosts: ["nuage.codecommun.coop:172.18.0.1", "onlyoffice.codecommun.coop:172.18.0.1"]
  onlyoffice:
    extra_hosts: ["nuage.codecommun.coop:172.18.0.1", "onlyoffice.codecommun.coop:172.18.0.1"]
```

(`172.18.0.1` : passerelle du réseau `frontend`, voir `docker network inspect frontend`.)

### 2. `config.php`

```php
  'trusted_proxies' =>
  array (
    1 => '172.18.0.0/24',
  ),
  'overwritehost'     => 'nuage.lamiete.fr',
  'overwriteprotocol' => 'https',
  'overwrite.cli.url' => 'https://nuage.lamiete.fr',
  'trusted_domains' =>
  array (
    0 => 'nuage.lamiete.fr',
  ),
  'memcache.locking' => '\OC\Memcache\Redis',
  'redis' =>
  array (
    'host' => 'nextcloud_redis',
    'port' => 6379,
    'timeout' => 0.0,
    'password' => '',
  ),
```

### 3. Finalisation

```bash
make occ CMD="db:add-missing-indices"
make occ CMD="maintenance:repair --include-expensive"
make occ CMD="config:system:set maintenance_window_start --type=integer --value=1"
make occ CMD="config:system:set default_phone_region --value=FR"
make occ CMD="config:system:set serverid --type=integer --value=1"
make occ CMD="app:disable app_api"     # sauf si vous utilisez des Ex-Apps
```

### 4. Crontabs

```bash
# crontab de l'utilisateur (tâches de fond Nextcloud)
*/5 * * * * /usr/bin/docker compose -f /poule/miete/nextcloud/docker-compose.yml exec -T -u www-data nextcloud_app php -f /var/www/html/cron.php

# crontab root (posée par make init) : la sauvegarde lit data/, propriété de www-data
@daily bash /poule/miete/nextcloud/scripts/backup_nextcloud.sh >> /var/log/borg-nextcloud.log 2>&1
```

Toutes les 5 minutes, comme le recommande Nextcloud : avec `@hourly`, les tâches
de fond (notifications, nettoyages…) prenaient jusqu'à une heure de retard.
Nextcloud doit être en mode « Cron » (Administration → Paramètres de base), ou :
`make occ CMD="background:cron"`.

### 5. OnlyOffice

Plus besoin d'aller chercher le token dans le conteneur ni de le coller dans
l'admin : **une seule source de vérité, `JWT_SECRET` dans le `.env`**.

- le conteneur `onlyoffice` le reçoit en variable d'environnement
  (`JWT_ENABLED`, `JWT_SECRET`, `JWT_HEADER: Authorization`) ;
- `make onlyoffice` l'écrit (chiffré) dans le connecteur Nextcloud avec les URL
  (`DocumentServerUrl`, `DocumentServerInternalUrl`, `StorageUrl`), puis vérifie
  la connexion.

```bash
make onlyoffice
# [onlyoffice] OK — Nextcloud et le Document Server se parlent.
```

`make update` le relance automatiquement. Rejouable à volonté.

> **Document vide dans l'éditeur ?** Un bloqueur de pub (uBlock Origin…) bloque
> `Analytics.js`, dont l'éditeur a besoin pour démarrer. Désactiver le bloqueur
> sur `onlyoffice.lamiete.fr`, puis Ctrl+Maj+R. Ce fichier ne contacte pas
> Google : le traceur est désactivé dans le code d'OnlyOffice.

### 6. Sauvegardes

```bash
cp scripts/env_example scripts/.env && chmod 600 scripts/.env
make init
```

`make init` (le script du kit BorgWarehouse, comme pour Keycloak, Docuseal et
Etherpad, adapté à root) : clé SSH dédiée dans `scripts/.ssh/`, création du
dépôt sur BorgWarehouse (token API avec la seule permission « create », ou à
la main), passphrase, `borg init`, affichage de la passphrase et de la clé du
dépôt **à mettre au coffre**, ligne de cron root, première sauvegarde,
`make check`. Rejouable s'il s'interrompt. Il **refuse** de toucher un dépôt
qui contient déjà des archives (une nouvelle passphrase les rendrait
illisibles) : sur une instance déjà sauvegardée, `make check` suffit. Il
refuse aussi un dépôt qu'il ne peut pas lire (BorgWarehouse arrêté, sauvegarde
en cours, clé refusée, passphrase fausse) : corriger, puis relancer. En
méthode manuelle, relancer après avoir collé la clé publique dans BorgWarehouse.

Sans `make init` : créer le dépôt dans BorgWarehouse, renseigner
`scripts/.env`, `make backup`, `make check`, puis mettre au coffre la clé du
dépôt (`borg key export`) avec la passphrase. Sans `scripts/.ssh/`, la
sauvegarde utilise la clé SSH de root (cas de l'instance lamiete, configurée
ainsi avant `make init`).

Ce que fait `make backup` : mode maintenance → `pg_dump -Fc` → **une** archive
borg de toute la stack (sauf `database/`, remplacée par le dump) → sortie de
maintenance (garantie même en cas d'échec) → prune
(7 jours, 30 quotidiennes, 12 hebdomadaires, puis mensuelles).

---

## Passer une installation existante sur ce dépôt

Pour une instance clonée depuis `nextcloud31` ou `nextcloud32` (ou à la main).
Les dossiers `data/` et `database/` gardent les mêmes chemins : seuls le code
du dépôt et la configuration changent.

**Principe :** les deux dépôts n'ont pas d'historique commun, un `git pull`
est donc impossible. On fait pointer le dossier vers ce dépôt et on remplace
les fichiers suivis par git. `.env`, `data/` et `database/` ne sont pas suivis :
git n'y touche pas.

```bash
cd /chemin/de/l/instance
mkdir -p ~/avant-unification

# 0. Sauvegarde à la main (l'ancien dépôt n'a pas de make backup)
docker compose exec -T nextcloud_db sh -c 'pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB"' \
  > ~/avant-unification/base.dump </dev/null
# + une copie de data/ si aucune sauvegarde des fichiers n'existe

# 1. Garder une trace de l'existant
git status --short > ~/avant-unification/status.txt
git diff           > ~/avant-unification/modifs-locales.diff   # retouches faites sur le serveur
cp -a docker-compose.yml compose-onlyoffice.yml README.md .env ~/avant-unification/ 2>/dev/null
docker compose ps; docker ps --filter name=onlyoffice          # ce qui tourne vraiment

# 2. Arrêter l'ancienne stack AVEC l'ancien compose (il connaît ses container_name)
docker compose -f compose-onlyoffice.yml down    # seulement si OnlyOffice tournait par lui
docker compose down

# 3. Basculer sur ce dépôt
git remote set-url origin git@github.com:CoopCodeCommun/nextcloud.git
git fetch origin
git checkout -B main origin/main     # remplace les fichiers suivis, garde .env/data/database
git branch -u origin/main            # ensuite, de simples `git pull`
```

Si git refuse (« would be overwritten »), un fichier non suivi porte le nom
d'un fichier du dépôt : le déplacer dans `~/avant-unification/`, puis relancer.

**4. Compléter le `.env`** (voir `env_example`) avec les versions **qui tournent
aujourd'hui**, pas celles visées :

```bash
NEXTCLOUD_TAG=32                            # grep OC_VersionString data/www/html/version.php
POSTGRES_TAG=17                             # sudo cat database/PG_VERSION
POSTGRES_MOUNT=/var/lib/postgresql/data     # base <= 17 : ancienne disposition
ONLYOFFICE_TAG=10.0
ROUTER_NAME=codecommun
JWT_SECRET=...                              # vide ? openssl rand -hex 32
```

Puis la sauvegarde, dans un dépôt borg **propre à l'instance** avec un
`BORG_PREFIX` à elle : `cp scripts/env_example scripts/.env && chmod 600
scripts/.env`. `make init` vient à l'étape 5, une fois la stack démarrée (il
fait la première sauvegarde).

**5. Redémarrer et monter les versions, une étape à la fois :**

```bash
make verifier                 # tout doit être OK, sinon corriger le .env
make up && make onlyoffice    # même versions qu'avant, OnlyOffice reconnecté
make init                     # dépôt borg, cron, 1re sauvegarde + check
                              # (dépôt déjà configuré : make backup && make check)
make update                   # correctifs
make upgrade-check && make upgrade         # 32 -> 33
make pg-upgrade PG_CIBLE=18                # 17 -> 18 (retire POSTGRES_MOUNT)
```

Adapter enfin les crontabs (section Installation) : sans `container_name`, la
ligne `cron.php` passe par `docker compose -f …/docker-compose.yml exec`.

---

## Mises à jour

**Ne pas modifier les `*_TAG` du `.env` à la main** (sauf OnlyOffice) : chaque
composant a sa commande, et les garde-fous refusent le reste.

| Ce qu'on fait | Commande | Garde-fou si on se trompe |
|---|---|---|
| correctifs (33.0.x, 18.x, 10.0.x) | `make update` | — |
| Nextcloud majeure suivante | `make upgrade-check` puis `make upgrade` | `make up`/`update` refusent une autre majeure que l'installée |
| PostgreSQL majeure | `make pg-upgrade PG_CIBLE=19` | refus si `POSTGRES_TAG` ≠ version des données (sinon : base **vide** créée à côté) |
| OnlyOffice 10.1, 11… | `ONLYOFFICE_TAG` à la main, puis `make update OO_CONFIRME=1` | refus sans `OO_CONFIRME=1` |

Les vérifications se font **avant** la sauvegarde et avant tout arrêt : un refus
ne coupe rien.

### Nextcloud

`make update` suit les correctifs de `NEXTCLOUD_TAG` (33 → 33.0.x) :
sauvegarde → apps à jour → arrêt propre d'OnlyOffice → redémarrage → attente de
la migration (jusqu'à 30 min) → index et colonnes manquants → apps →
reconnexion OnlyOffice.

Majeure suivante :

```bash
make upgrade-check    # vérifie, ne change rien
make upgrade          # sauvegarde + montée
```

`make upgrade` vise **installée + 1**, jamais plus, et refuse :
- si l'image `nextcloud:<N+1>` n'existe pas encore ;
- si elle a moins de 2 correctifs (`34.0.0`, `34.0.1` : on attend ;
  `MIN_CORRECTIF=0` pour forcer) ;
- si une app activée n'a pas de version stable pour la cible sur l'app store :
  elle serait désactivée par la montée (`APPS_OK=1` pour passer outre).

Puis il écrit `NEXTCLOUD_TAG=<N+1>` dans le `.env` et enchaîne sur
`make update`. En cas d'échec avant la migration, le tag est remis.
Pour 33 → 35 : deux `make upgrade` successifs.

Ensuite, si `make occ CMD=setupchecks` le demande :
`make occ CMD="maintenance:repair --include-expensive"`.

Vérifier aussi que la version de PostgreSQL est supportée par la cible
(exigences système de Nextcloud).

### OnlyOffice

Les correctifs du tag (`10.0` → 10.0.x) arrivent avec `make update`.
Pour changer de version (10.1, 11…) : lire les notes de version, vérifier que
le connecteur (app `onlyoffice` de Nextcloud) la supporte, puis :

```bash
# dans le .env : ONLYOFFICE_TAG=10.1
make update OO_CONFIRME=1
```

### PostgreSQL

```bash
make pg-upgrade PG_CIBLE=19
```

Dump / restauration, comptage ligne à ligne des tables, mots de passe re-hachés
en scram-sha-256, `POSTGRES_TAG` (et `POSTGRES_MOUNT`) mis à jour dans le
`.env`, retour arrière automatique en cas d'échec. Vérifier avant que la version
de Nextcloud supporte la cible. L'ancienne base est gardée en `database.pgXX/`
et les dumps en `scripts/pg-upgrade/` (ignorés par git et par la sauvegarde) :
les supprimer une fois rassuré.

---

## Bug fixes & commandes utiles

Activer le mode maintenance :

`make occ CMD="maintenance:mode --on"`

Scanner les fichiers sur disque dur et reconstruire la base de donnée. Utile en
cas de suppression de fichier depuis le terminal, attention peut être très long :

```bash
docker compose exec --user www-data nextcloud_app php occ files:scan jonas
docker compose exec --user www-data nextcloud_app php occ files:scan --path="Ekopratik/files/Ekopratik/2. Administration/2.2 Salariat/2.2.1 En cours/"
```

Arborescence en erreur (`getOwner() on null` dans l'interface Fichiers) :
réparer le cache, **à relancer jusqu'à ce qu'il annonce 0 entrée** :

`make occ CMD="files:repair-tree"`

Cleaner la corbeille :

`make occ CMD="trashbin:cleanup Ekopratik"`

### Encrypted errors

La commande magique si jamais tu vois des soucis de chiffrement sur un fichier :

`docker compose exec --user www-data nextcloud_app php occ encryption:fix-encrypted-version Guillaume --path=<file>`

ex :

`docker compose exec --user www-data nextcloud_app php occ encryption:fix-encrypted-version Guillaume --path=La\ Raffinerie\ \(1\)/Groupe\ Economique/Inter-location/SUIVI\ FACTURATION\ 2022\ -\ ARCHIVE.xlsx`

Voir les logs d'erreur sur l'UI : https://nuage.lamiete.fr/settings/admin/logging

### Liens utiles

- https://belginux.com/nextcloud-corriger-les-avertissements-de-securite/#erreur-reverse-proxy
- Cycle de vie des versions Nextcloud : https://github.com/nextcloud/server/wiki/Maintenance-and-Release-Schedule
- Notes de version OnlyOffice : https://github.com/ONLYOFFICE/DocumentServer/blob/master/CHANGELOG.md
