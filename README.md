# Docker compose : Nextcloud 30 (hub 9) + Onlyoffice 8.2 + Traefik v3 + Redis 7

Installation nextcloud derrière Traefik v3 via docker compose

Brouillons de note de blog : https://codimd.communecter.org/s/QicjJT2X7

Les exemples ici sont avec les dns suivants :
- nuage.lamiete.fr
- onlyoffice.lamiete.fr

A changer bien sur avec vos propres adresses :)


## A lancer après l'install :

### Modif du fichier config.php

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
  'redis' => 
  array (
    'host' => 'nextcloud_redis', 
    'port' => 6379,
    'timeout' => 0.0,
    'password' => '',
  ),

```

### Commande de finalisation d'install :

`docker compose exec --user www-data nextcloud_app php occ db:add-missing-indices`
`docker compose exec --user www-data nextcloud_app php occ maintenance:repair --include-expensive`
`docker compose exec --user www-data nextcloud_app php occ config:system:set maintenance_window_start --type=integer --value=1`
`docker compose exec --user www-data nextcloud_app php occ config:system:set default_phone_region --value=“FR”`

### Crontab 

```bash
crontab -e
@hourly /usr/bin/docker exec --user www-data nextcloud_app php -f /var/www/html/cron.php
```

### Onlyoffice :

Aller chercher le token pour le rajouter dans le .env du docker
`docker compose exec onlyoffice /var/www/onlyoffice/documentserver/npm/json -f /etc/onlyoffice/documentserver/local.json 'services.CoAuthoring.secret.session.string'`

<!-- allow to set onlyoffice as local container (a checker si tjrs necessaire dans v30?)
`docker compose exec --user www-data nextcloud_app php occ --no-warnings config:system:set allow_local_remote_servers --value=true`
 -->

`docker compose exec --user www-data nextcloud_app php occ --no-warnings config:system:set onlyoffice DocumentServerUrl --value="https://onlyoffice.lamiete.fr/"`
`docker compose exec --user www-data nextcloud_app php occ --no-warnings config:system:set onlyoffice DocumentServerInternalUrl --value="https://onlyoffice.lamiete.fr/"`
`docker compose exec --user www-data nextcloud_app php occ --no-warnings config:system:set onlyoffice StorageUrl --value="https://nuage.lamiete.fr/"`
`docker compose exec --user www-data nextcloud_app php occ --no-warnings config:system:set onlyoffice jwt_secret --value="<TOKEN JWT DANS ENV>"`

### Libresign :

`docker compose exec --user www-data nextcloud_app php occ libresign:install --java`
`docker compose exec --user www-data nextcloud_app php occ libresign:install --pdftk`
`docker compose exec --user www-data nextcloud_app php occ libresign:install --jsignpdf`


## Bug fixes & commandes utiles

Activer le mode maintenance : 

`docker compose exec --user www-data nextcloud_app php occ maintenance:mode --on`

Scanner les fichiers sur disque dur et reconstruire la base de donnée. utile en cas de suppression de fichier depuis le terminal, attention peut être très long :

`docker compose exec --user www-data nextcloud_app php occ files:scan jonas`
`docker compose exec --user www-data nextcloud_app php occ files:scan --path="Ekopratik/files/Ekopratik/2. Administration/2.2 Salariat/2.2.1 En cours/"`

Cleaner la corbeille : 

`docker compose exec --user www-data nextcloud_app php occ trashbin:cleanup Ekopratik`


### encrypted errors

La commande magique si jamais tu vois des soucis de chiffrement sur un fichier :

Tu vas dans le conteneur nextlcloud avec `dex nextcloud_app`

`docker compose exec --user www-data nextcloud_app php occ encryption:fix-encrypted-version Guillaume --path=<file>`
	ex :
`docker compose exec --user www-data nextcloud_app php occ encryption:fix-encrypted-version Guillaume --path=La\ Raffinerie\ \(1\)/Groupe\ Economique/Inter-location/SUIVI\ FACTURATION\ 2022\ -\ ARCHIVE.xlsx `

Voir les logs d'erreur sur l'ui : https://nuage.tierslieux.re/settings/admin/logging

Tu peux aussi lancer la commande depuis l'extérieur, si tu es dans le dossier du compose, comme pour celle ci :


### Lien utiles :

https://belginux.com/nextcloud-corriger-les-avertissements-de-securite/#erreur-reverse-proxy