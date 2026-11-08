# Migration Nextcloud 30 → 33, OnlyOffice 8 → 10, PostgreSQL 13 → 18

**Dates :** 7 et 8 novembre 2026
**Instance :** https://nuage.lamiete.fr (+ https://onlyoffice.lamiete.fr)
**Dossier :** `/poule/miete/nextcloud`

## Résumé

| Composant | Avant | Après |
|---|---|---|
| Nextcloud | 30.0.17 | 31.0.14 → 32.0.15 → **33.0.10** |
| OnlyOffice Document Server | 8.x (image non figée, clé JWT aléatoire) | 9.4.0 → **10.0.0** (JWT depuis le `.env`) |
| Connecteur OnlyOffice (app Nextcloud) | 9.x | 9.13 (NC31) → 9.15.1 (NC32) → **10.2.1** (NC33) |
| PostgreSQL | 13.23 | 18.6 |
| Sauvegarde | `backup.sh` ancien modèle, sans maintenance | kit borg unifié : `make backup / check / list` |
| Tâches de fond (`cron.php`) | toutes les heures | toutes les 5 minutes |

Pourquoi : Nextcloud 30, 31 et 32 ne sont plus maintenus (pas de version « LTS » communautaire, chaque majeure vit environ un an). Nextcloud 33 est maintenu jusqu'en février 2027, puis 34 (juin 2027) et 35 (septembre 2027). Nextcloud 33 exige PostgreSQL 14 ou plus : il fallait donc d'abord quitter PostgreSQL 13.

Règle de Nextcloud : **une seule version majeure à la fois** (30 → 31 → 32 → 33, pas de saut).

---

## Ce qui a été mis en place

### Commandes (Makefile)

```
make backup       sauvegarde borg cohérente (sudo)
make check        vérifie que la dernière sauvegarde est restaurable (sudo)
make list         liste les archives (sudo)
make update       sauvegarde, puis mise à jour Nextcloud + OnlyOffice (sudo)
make onlyoffice   (re)connecte OnlyOffice depuis le JWT_SECRET du .env
make pg-upgrade   montée de version majeure de PostgreSQL (sudo)
make occ CMD="…"  commande occ
```

### Scripts (`scripts/`)

| Script | Rôle |
|---|---|
| `backup_nextcloud.sh` | mode maintenance → `pg_dump -Fc` → une archive borg de toute la stack → sortie de maintenance (garantie par un `trap`) → prune |
| `check_backup.sh` | fraîcheur de l'archive, présence du dump, de `config.php`, des fichiers utilisateurs et du `.env` ; validation du dump avec `pg_restore` |
| `update_nextcloud.sh` | sauvegarde → apps à jour → arrêt propre d'OnlyOffice → pull + redémarrage → attente de la migration → index/colonnes manquants → apps → reconnexion OnlyOffice |
| `onlyoffice_connect.sh` | pousse URL + secret JWT dans le connecteur, puis `occ onlyoffice:documentserver --check` |
| `pg_upgrade.sh` | migration PostgreSQL par dump/restauration, avec comptage ligne à ligne et retour arrière automatique ; gère l'ancien et le nouveau montage du volume (prochaine fois : `make pg-upgrade PG_CIBLE=19`) |

La configuration borg (`BORG_REPO`, `BORG_PASSPHRASE`, `BORG_PREFIX=nuagefr`) est dans `scripts/.env` (chmod 600, ignoré par git). Dépôt : BorgWarehouse local, `ssh://borgwarehouse@localhost:2226/./ef73c56f`, répliqué par Syncthing.

### OnlyOffice connecté automatiquement

Avant : le Document Server générait une clé JWT aléatoire à chaque recréation du conteneur, qu'il fallait recopier à la main dans l'admin Nextcloud.

Maintenant : **une seule source de vérité**, `JWT_SECRET` dans le `.env` de la stack.
- le conteneur `onlyoffice` la reçoit en variable d'environnement (`JWT_ENABLED`, `JWT_SECRET`, `JWT_HEADER: Authorization`) ;
- `make onlyoffice` (appelé aussi par `make update`) l'écrit dans le connecteur, chiffrée (`--sensitive`), avec les URL.

Le Document Server a aussi des volumes nommés (`onlyoffice_data`, `_lib`, `_logs`, `_fonts`) au lieu de volumes anonymes.

### Autres changements du `docker-compose.yml`

- `NC_skeletondirectory=` : plus de fichiers d'exemple dans le dossier des nouveaux utilisateurs.
- Labels Traefik : un seul jeu de middlewares (`nextcloud_custom_header, nextcloud_redirectregex, crowdsec@file`), anciens doublons retirés.
- **Suppression de la ligne `contentSecurityPolicy` / `frame-ancestors`** dans Traefik. Elle *remplaçait* la CSP envoyée par Nextcloud par une CSP minimale, ce qui retirait des protections. Nextcloud envoie déjà lui-même `frame-ancestors 'self'` et `X-Frame-Options: SAMEORIGIN`.
- PostgreSQL : `postgres:18-bookworm`, monté sur `./database:/var/lib/postgresql` (nouvelle disposition de l'image 18, les données sont dans `database/18/docker`).
- OnlyOffice : `onlyoffice/documentserver:10.0`. Ce tag suit les correctifs 10.0.x (`make update` les récupère) ; pour 10.1 ou 11, changer le tag à la main après avoir vérifié le connecteur.

### Autres fichiers

- **`.gitignore`** créé (il n'existait pas : `.env` et `data/` apparaissaient comme fichiers à ajouter) : secrets (`.env`, `scripts/.env`, `scripts/.ssh/`), données (`data/`, `database/`, `database.*/`), fichiers de travail des scripts.
- **Sauvegarde** : exclut aussi `database.*` (ancienne base mise de côté) et `scripts/pg-upgrade/` (dumps de migration).
- **README** réécrit : versions, Makefile, installation (les deux `.env`, `config.php`, crontabs, OnlyOffice, sauvegardes), procédures de mise à jour.
- **Crontab utilisateur** : `cron.php` passé de `@hourly` à `*/5 * * * *` (recommandation Nextcloud ; Nextcloud était déjà en mode « Cron »).

---

## Étapes

### Étape 1 — Sauvegardes (7 nov.)

- Ancien `backup.sh` remplacé par `backup_nextcloud.sh` (cohérent : maintenance + dump).
- `make backup` puis `make check` validés avant toute mise à jour.

### Étape 2 — Nextcloud 30.0.17 → 31.0.14 + OnlyOffice 9.4 (7 nov.)

- Tag `nextcloud:30` → `nextcloud:31`, `onlyoffice/documentserver:9.4`.
- Choix de DS **9.4 et non 10.0** : le connecteur pour NC31 (9.13) est prévu jusqu'à DS 9.3, et la 10.0 change le comportement JWT.
- Après la mise à jour :
  - apps : calendar 5.5.24, contacts 7.3.19, deck 1.15.12, groupfolders 19.1.20, onlyoffice 9.13.0, polls 9.3.0, passwords 2026.11.10, sociallogin 6.6.0, files_mindmap 0.0.34 ;
  - `occ maintenance:repair --include-expensive` (migration des types MIME) ;
  - `occ files:repair-tree` (voir bug 4).

### Étape 3 — Nextcloud 31.0.14 → 32.0.15 (7 nov.)

- Compatibilité des apps vérifiée sur l'App Store avant de monter le tag.
- `make update` : sans incident côté Nextcloud.
- Apps : calendar 6.6.5, contacts 8.3.21, deck 1.16.9, groupfolders 20.1.19 (renommée « Team folders »), onlyoffice 9.15.1, files_mindmap 0.1.5.
- Migration MIME relancée.
- Bug 6 (OnlyOffice resté en mode arrêt).

### Étape 4 — PostgreSQL 13.23 → 18.6 (8 nov.)

`make pg-upgrade`, par dump/restauration :

1. sauvegarde borg ;
2. maintenance + arrêt de Nextcloud ;
3. `pg_dumpall --globals-only` (rôles) + `pg_dump -Fc` (base, 91 Mo compressé pour 3,4 Go) + comptage exact des lignes des 200 tables ;
4. `database/` **déplacé** en `database.pg13/` (retour arrière possible) ;
5. compose : nouvelle image + nouveau montage ;
6. base neuve, restauration (`pg_restore -j 4`, ~30 s), mots de passe re-hachés en scram-sha-256, droits d'origine remis ;
7. comptage comparé : 200 tables identiques ligne à ligne ;
8. redémarrage de Nextcloud.

Une répétition complète a été faite avant, dans un conteneur PostgreSQL 18 jetable, sur une copie de la base.

Points propres à PostgreSQL 18 :
- **Disposition des données** : `PGDATA=/var/lib/postgresql/18/docker`, volume monté sur `/var/lib/postgresql` (et non plus `…/data`).
- **Mots de passe** : l'image 18 impose `scram-sha-256` dans `pg_hba.conf`. Les mots de passe md5 venant de la 13 sont refusés (« does not have a valid SCRAM secret ») : il faut les ré-enregistrer.
- **Schéma `public`** : depuis PG 15, `CREATE` n'y est plus accordé à tous. On le redonne à l'utilisateur Nextcloud (`oc_jonas`), sinon les futures migrations de Nextcloud ne pourraient plus créer de tables.
- Nextcloud 32 affiche « PostgreSQL >=13 and <=17 is suggested » : simple avertissement, qui disparaît en 33.

### Étape 5 — Nextcloud 32.0.15 → 33.0.10 (8 nov.)

- Compatibilité vérifiée : calendar 6.6.5, contacts 8.9.5, deck 1.17.8, groupfolders 21.0.9, onlyoffice 10.2.1, passwords 2026.9.20, polls 9.3.0, sociallogin 6.6.0, files_mindmap 0.1.5.
- Image : Nextcloud 33.0.10, PHP 8.4.
- Connecteur OnlyOffice 10.2 : le secret JWT est désormais stocké chiffré → `onlyoffice_connect.sh` utilise `--sensitive`. L'option `allow_local_address` n'est pas nécessaire ici (`onlyoffice.lamiete.fr` résout vers l'IP publique).
- Le Document Server reste en 9.4 pendant cette étape ; le passage en 10.x est l'étape suivante.

**Résultat :** sans incident, ~4 min de bout en bout (07:01 → 07:05), dont ~1 min de maintenance pour la migration elle-même.
- Apps : calendar 6.6.5, contacts 8.9.5, deck 1.17.8, groupfolders 21.0.16, onlyoffice 10.2.1, passwords 2026.11.20, polls 9.3.0, sociallogin 6.6.0, files_mindmap 0.1.5.
- OnlyOffice : arrêt propre puis redémarrage automatique par le script (correction du bug 6 validée), « 9.4.0.129 is successfully connected ».
- Aucune erreur de connexion PostgreSQL ; l'avertissement « PostgreSQL <=17 suggested » a disparu.
- Migration MIME (`maintenance:repair --include-expensive`) : toml et ovpn.
- `setupchecks` : plus d'avertissement lié à la migration (restent des points « info », voir « Après la migration »).

### Étape 6 — OnlyOffice Document Server 9.4 → 10.0.0 (8 nov.)

Notes de version lues avant : rien de bloquant, ni retrait de fonctionnalité de l'édition communautaire.
- **Sécurité** (raison principale) : une cinquantaine de correctifs (XSS, contournement du bac à sable des macros, lecture de fichiers serveur pendant les conversions, détournement de session WOPI, failles de l'image Docker…).
- **Changements de comportement, sans effet ici** : JWT activé par défaut (déjà forcé dans le compose) ; `/converter` et `/command` n'acceptent plus le jeton de l'éditeur (le connecteur signe ses propres jetons) ; `ipfilter` obligatoire pour WOPI (non utilisé) ; anciens réglages `reviewDisplay`… ignorés (déjà réinitialisés par le connecteur 10.2.1).
- **Nouveautés** : bouton Télécharger dans la barre d'outils, ligne de tableau insécable, SVG convertis en formes, table de données sous les graphiques, caviardage PDF des annotations et métadonnées, nouveau magasin de plugins, option `customization.ai.disabled` pour masquer les outils IA.

Mise à jour (sans `sudo`, le Document Server ne stocke aucun document) :
```
# tag onlyoffice/documentserver:9.4 -> 10.0 dans docker-compose.yml
docker compose exec onlyoffice documentserver-prepare4shutdown.sh
docker compose up -d onlyoffice
make onlyoffice
```
Résultat : « version 10.0.0.169 is successfully connected ». Retour arrière : remettre le tag 9.4 et refaire les mêmes commandes.

### Après la migration — avertissements de l'admin (8 nov.)

- **`/ocm-provider/` et `/.well-known/webfinger` en erreur** : faux positifs. La page d'admin a été affichée pendant une sauvegarde (mode maintenance → tout répond 503). Hors maintenance : `/ocm-provider/` 200, `webfinger` 404 (normal), `caldav` redirigé. Rien à corriger dans Traefik.
- **AppAPI** : désactivée (`app:disable app_api`), aucune Ex-App utilisée. Supprime aussi une tâche de fond orpheline.
- **`serverid`** : réglé à 1 (`config:system:set serverid --type=integer --value=1`), recommandé depuis la 33.
- **Double authentification** : pas imposée pour l'instant. Pour les comptes Keycloak, elle se règlerait dans Keycloak.

---

## Bugs rencontrés et corrections

### 1. Faux négatifs dans `check_backup.sh` (SIGPIPE)

**Symptôme :** `make check` annonçait des fichiers absents de l'archive alors qu'ils y étaient.
**Cause :** `printf "$CONTENU" | grep -q …` avec `set -o pipefail`. `grep -q` s'arrête dès qu'il trouve, `printf` reçoit SIGPIPE, et pipefail transforme ça en échec.
**Correction :** `grep -q … <<< "$CONTENU"` (here-string, pas de pipe). Appliqué à toutes les stacks.

### 2. Le script de mise à jour lançait les finitions en pleine migration (31)

**Symptôme :** `make update` échouait sur `db:add-missing-indices` (doublon `unique_category_per_user`), alors que la migration se terminait normalement dans les logs.
**Cause :** juste après le redémarrage, l'**ancien** code répond encore « installé, pas de maintenance, pas de mise à jour en attente », avant que l'image ne copie le nouveau code. La boucle d'attente sortait tout de suite.
**Correction :** on attend que la version installée soit **celle de l'image** (`NEXTCLOUD_VERSION` lue avec `docker inspect`).

### 3. Erreurs « Could not boot groupfolders » / `registerConfigLexicon` pendant les montées

**Cause :** quelques secondes pendant lesquelles ancien et nouveau code cohabitent.
**Action :** aucune. Erreurs ponctuelles, jamais revenues après la migration.

### 4. Arborescence des fichiers en erreur (`getOwner() on null`)

**Symptôme :** erreur JSON dans l'interface Fichiers sur un dossier (« 1_Fonctionnement Maison (1) »). Bug Nextcloud #53934.
**Cause :** chemins désynchronisés dans `oc_filecache` pour des éléments passés par la corbeille.
**Correction :** `occ files:repair-tree`, **à relancer jusqu'à 0** (chaque passe en révèle d'autres) : 279 → 807 → 1864 → 2581 → 2491 → 1090 → 676 → 716 → 11 → 0. Un échantillon de chemins réparés a été vérifié sur le disque.

### 5. OnlyOffice : interface affichée mais document vide

**Symptôme :** la barre d'outils s'affiche, le document jamais. Côté serveur, tout est correct.
**Cause :** **uBlock Origin** bloque `web-apps/apps/common/Analytics.js` à cause de son nom. Or le démarrage de l'éditeur (`require([... 'analytics' ...])`) attend ce fichier : s'il manque, rien ne démarre.
**Est-ce un mouchard ?** Non. Le fichier contient bien l'ancien traceur Google Analytics, mais il est désactivé en dur dans le code d'OnlyOffice (`if (this.appOptions.canAnalytics && false)`). Aucune requête ne part vers Google.
**Solution :** désactiver le bloqueur sur `onlyoffice.lamiete.fr`, puis recharger avec Ctrl+Maj+R (l'éditeur a aussi un *service worker* qui garde l'ancien échec en cache). **À communiquer aux membres** : « si un document reste vide, désactivez votre bloqueur de pub sur onlyoffice.lamiete.fr ».

### 6. OnlyOffice « la connexion a été perdue » après `make update` (32)

**Symptôme :** l'éditeur se déconnecte, aucune session ne s'ouvre. `/healthcheck` répond pourtant `true`.
**Cause :** l'étape « arrêt propre » (`documentserver-prepare4shutdown.sh`) met le Document Server en mode arrêt : il refuse les nouvelles sessions jusqu'à son redémarrage. L'image 9.4 n'ayant pas changé, `up -d` ne l'a pas recréé → resté en mode arrêt.
**Correction :** redémarrage manuel ; `update_nextcloud.sh` redémarre désormais OnlyOffice lui-même s'il n'a pas été recréé.

### 7. PostgreSQL 18 : Nextcloud refusé (« does not have a valid SCRAM secret »)

**Symptôme :** pendant ~1 min après la migration, Nextcloud ne pouvait plus se connecter à la base.
**Cause :** bug de `pg_upgrade.sh`. Le nom de la base était lu par un `docker compose exec` placé **dans** le pipeline qui envoyait le SQL à psql. `compose exec -T` lit son entrée standard : il a avalé le SQL, psql n'a rien reçu, les mots de passe sont restés en md5. La répétition ne l'avait pas vu (nom de base écrit en dur). Les données, elles, étaient déjà vérifiées (étape 7 passée).
**Correction :**
- en direct : mots de passe ré-enregistrés en scram, droits remis ;
- dans le script : tous les `compose exec` hors pipeline avec `</dev/null`, contrôle « plus aucun rôle en md5 », et l'étape 8 attend une vraie lecture en base (`occ user:list`) au lieu de `occ status`, qui répond « installé » même quand la base refuse la connexion.

### 8. `occ config:app:set --sensitive` demande une confirmation

**Symptôme :** `make onlyoffice` s'arrêtait sur « Confirm this action by typing 'yes' » → « Aborted » (rien n'était écrit).
**Correction :** `printf "yes\n" | occ config:app:set … --sensitive`.

### 9. `make onlyoffice` en échec pendant une sauvegarde

**Symptôme :** « There are no commands defined in the "onlyoffice" namespace ».
**Cause :** une sauvegarde (`make backup`) tournait en parallèle et avait mis Nextcloud en maintenance. Dans ce mode, aucune app n'est chargée, donc les commandes `occ onlyoffice:*` n'existent pas. Les valeurs de configuration étaient bien écrites.
**Correction :** `onlyoffice_connect.sh` détecte la maintenance et le dit clairement au lieu d'échouer sur un message obscur. Relancer `make onlyoffice` après la sauvegarde.

### À savoir côté Traefik

Le journal d'accès (`TraefikV3/traefik.yml`) ne garde que les codes 200-299 et 400-599 : les websockets (code 101) n'y apparaissent jamais. Pour diagnostiquer OnlyOffice, ajouter `"100-199"` au filtre.

---

## Restauration (en cas de besoin)

**Revenir à PostgreSQL 13 : n'est plus possible.** Nextcloud 33 exige PostgreSQL ≥ 14, et la base a évolué depuis (migration de la 33). `database.pg13/` est l'état d'avant la 33 : il ne sert qu'avec une restauration complète de l'archive borg faite au début du `make update` vers la 33 (8 nov., ~07:01, Nextcloud 32), et fait perdre tout ce qui a été modifié depuis. Il peut être supprimé dès que `make check` passe sur la 33.

**Revenir à OnlyOffice 9.4 :** remettre le tag `onlyoffice/documentserver:9.4`, puis `prepare4shutdown`, `docker compose up -d onlyoffice`, `make onlyoffice`. Le connecteur 10.2.1 accepte encore la 9.4.

**Restaurer une archive borg :** `make list`, puis `borg extract` de l'archive `nuagefr-…` voulue (variables dans `scripts/.env`, clé SSH dans `scripts/.ssh/`). Le dump PostgreSQL est dans `scripts/pg-dump-nuagefr/`, à recharger avec `pg_restore` dans une base neuve de la **même version majeure** de PostgreSQL que celle du compose restauré.

---

## Prochaine étape : Nextcloud 34

Proposée par l'admin (34.0.5) le 8 novembre. Vérifié : image `nextcloud:34` disponible, toutes les apps compatibles (deck 1.18.6, groupfolders 22.0.6, onlyoffice 10.2.1…), PostgreSQL 18 est la version **recommandée**. Maintenue jusqu'en juin 2027.

Nouveautés (« Hub 26 Spring ») : diagramme de Gantt et dépendances dans Deck ; délégation d'agenda et de mail ; CalDAV/CardDAV externes en lecture-écriture ; Talk (appel depuis n'importe quelle app, étiquettes et tri des conversations, réponse privée) ; édition hors ligne dans Text ; nouvelle navigation. Aucun retrait de fonctionnalité identifié. Source : https://nextcloud.com/blog/nextcloud-hub26-spring/

**Décision :** attendre quelques jours de fonctionnement stable sur la 33 (sauvegardes nocturnes, `make check`, journal d'erreurs), pour ne pas mélanger d'éventuels problèmes de la 33 et de la 34. Ensuite : tag `nextcloud:34`, `make update`, migration MIME si demandée. Puis 35 (septembre 2027) de la même façon.

---

## Reste à faire

- [x] Tester l'édition d'un document dans OnlyOffice 10 (validé le 8 nov.).
- [x] Mettre à jour le README.
- [ ] `make check` sur une sauvegarde de la 33.
- [ ] Après quelques jours sans problème : `sudo rm -r database.pg13 scripts/pg-upgrade`.
- [ ] Root crontab : ne garder que `backup_nextcloud.sh` (`sudo crontab -l`), et reporter dans le README le chemin réel de son journal.
- [ ] Nettoyer les anciens volumes anonymes d'OnlyOffice (`docker volume ls -f dangling=true`, vérifier avant de supprimer).
- [ ] Supprimer les 7 archives `keycloak-*` vides du dépôt `ef73c56f` (héritées de l'ancien script).
- [ ] Prévenir les membres : document OnlyOffice vide → désactiver le bloqueur de pub sur onlyoffice.lamiete.fr.
- [ ] Double authentification : pas imposée pour l'instant (décision du 8 nov.) ; à régler dans Keycloak le jour venu.
- [ ] Nextcloud 34 (voir ci-dessus).
