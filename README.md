# Docker compose : Nextcloud 33 + OnlyOffice 10 + PostgreSQL 18 + Redis 7 + Traefik v3

Installation de Nextcloud derrière Traefik v3 via docker compose, avec OnlyOffice
connecté automatiquement et des sauvegardes borg vers BorgWarehouse.

Brouillons de note de blog : https://codimd.communecter.org/s/QicjJT2X7

Les exemples ici sont avec les DNS suivants :
- nuage.lamiete.fr
- onlyoffice.lamiete.fr

À changer bien sûr avec vos propres adresses :)

| Service | Image |
|---|---|
| `nextcloud_app` | `nextcloud:33` |
| `nextcloud_db` | `postgres:18-bookworm` |
| `nextcloud_redis` | `redis:7.4` |
| `onlyoffice` | `onlyoffice/documentserver:10.0` |

Historique des migrations, bugs rencontrés et corrections : [`changelog/`](changelog/)
(procédures de restauration comprises).

---

## Au quotidien : le Makefile

```
make up / down / restart    démarre, arrête, redémarre la stack
make logs                   suit les logs de Nextcloud
make ps                     état des conteneurs
make occ CMD="status"       lance une commande occ

make backup                 sauvegarde borg maintenant (sudo)
make check                  vérifie que la dernière sauvegarde est restaurable (sudo)
make list                   liste les archives du dépôt (sudo)

make update                 sauvegarde, puis met à jour Nextcloud + OnlyOffice (sudo)
make onlyoffice             (re)connecte OnlyOffice depuis le JWT_SECRET du .env
make pg-upgrade             monte PostgreSQL de version majeure (PG_CIBLE=18 par défaut, sudo)
```

La logique vit dans `scripts/` ; le Makefile n'est qu'une table des matières.

---

## Installation

### 1. Fichiers `.env`

Deux fichiers, à ne jamais commiter (voir `.gitignore`), en `chmod 600` :

- **`.env`** (stack) — copier `env_example` : `POSTGRES_*`, `DOMAIN`,
  `NEXTCLOUD_TRUSTED_DOMAINS`, `JWT_SECRET`, `ROUTER_NAME`.
  Générer le secret OnlyOffice : `openssl rand -hex 32`.
  `ROUTER_NAME` suffixe les routeurs Traefik : **unique par instance** si
  plusieurs Nextcloud partagent le même Traefik (ex. `lamiete`, `codecommun`).
- **`scripts/.env`** (sauvegarde) — copier `scripts/env_example` : `BORG_PREFIX`,
  `BORG_REPO`, `BORG_PASSPHRASE`, `NC_MAINTENANCE`, `AGE_MAX_HEURES`.
  Ces variables ne vont **pas** dans le `.env` de la stack : il est passé en
  entier au conteneur PostgreSQL (`env_file`).

Puis : `make up`.

Aucun port n'est publié sur l'hôte : tout passe par Traefik (réseau `frontend`),
y compris les échanges Nextcloud ↔ OnlyOffice, qui utilisent les adresses
publiques en HTTPS. Pas de `container_name` non plus : les conteneurs
s'appellent `<dossier>-<service>-1`, et les scripts passent par
`docker compose`. Si le serveur ne sait pas se joindre par sa propre IP
publique, décommenter les `extra_hosts` du compose.

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

# crontab root (sudo crontab -e) : la sauvegarde lit data/, propriété de www-data
# (adapter le chemin du journal)
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

1. Créer le dépôt dans BorgWarehouse et renseigner `scripts/.env`.
2. `make backup`, puis `make check`.
3. Exporter la clé du dépôt au coffre (`borg key export`) avec la passphrase.

Ce que fait `make backup` : mode maintenance → `pg_dump -Fc` → **une** archive
borg de toute la stack (sauf `database/`, remplacée par le dump) → sortie de
maintenance (garantie même en cas d'échec) → prune
(7 jours, 30 quotidiennes, 12 hebdomadaires, puis mensuelles).

---

## Mises à jour

### Nextcloud

`make update` suit les correctifs de la version majeure du tag (`nextcloud:33`).

Pour passer à la majeure suivante :
1. vérifier que les apps installées ont une version pour la nouvelle majeure
   (https://apps.nextcloud.com) ;
2. changer le tag dans `docker-compose.yml` (**une seule majeure à la fois** :
   33 → 34 → 35) ;
3. `make update` ;
4. si `make occ CMD=setupchecks` le demande :
   `make occ CMD="maintenance:repair --include-expensive"`.

Le script fait : sauvegarde → apps à jour → arrêt propre d'OnlyOffice → pull +
redémarrage → attente de la migration (jusqu'à 30 min) → index et colonnes
manquants → apps → reconnexion OnlyOffice.

### OnlyOffice

Les correctifs de la version du tag (`10.0` → 10.0.x) arrivent avec `make update`.
Pour changer de version (10.1, 11…), changer le tag `onlyoffice/documentserver:…` dans `docker-compose.yml`, puis :

```bash
docker compose exec onlyoffice documentserver-prepare4shutdown.sh
docker compose up -d onlyoffice
make onlyoffice
```

Vérifier avant que le connecteur (app `onlyoffice` de Nextcloud) supporte la
version du Document Server.

### PostgreSQL

```bash
make pg-upgrade PG_CIBLE=19
```

Dump / restauration, comptage ligne à ligne des tables, mots de passe re-hachés
en scram-sha-256, retour arrière automatique en cas d'échec. Vérifier avant que
la version de Nextcloud supporte la cible. L'ancienne base est gardée en
`database.pgXX/` et les dumps en `scripts/pg-upgrade/` (ignorés par git et par
la sauvegarde) : les supprimer une fois rassuré.

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
