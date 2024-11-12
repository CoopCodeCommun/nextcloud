# nextcloud

Installation nextcloud derrière Traefik via docker compose

## Modif du fichier config.php

ex avec le domaine nuage.mondns.fr

```php
  'trusted_proxies' =>                                          
  array (                  
    1 => '172.18.0.0/24',                                       
  ),                                                            
  'overwritehost'     => 'nuage.mondns.fr',
  'overwriteprotocol' => 'https',
  'overwrite.cli.url' => 'https://nuage.mondns.fr',
  'trusted_domains' => 
  array (
    0 => 'nuage.mondns.fr',
  ),
  'redis' => 
  array (
    'host' => 'nextcloud_redis', 
    'port' => 6379,
    'timeout' => 0.0,
    'password' => '',
  ),

```


## A lancer après l'install :

`docker compose exec --user www-data nextcloud_app php occ db:add-missing-indices`
`docker compose exec --user www-data nextcloud_app php occ maintenance:repair --include-expensive`
`docker compose exec --user www-data nextcloud_app php occ config:system:set maintenance_window_start --type=integer --value=1`
`docker compose exec --user www-data nextcloud_app php occ config:system:set default_phone_region --value=“FR”`

### Pour Onlyoffice :

Aller chercher le token
`docker compose exec onlyoffice /var/www/onlyoffice/documentserver/npm/json -f /etc/onlyoffice/documentserver/local.json 'services.CoAuthoring.secret.session.string'`

allow to set onlyoffice as local container (a checker si tjrs necessaire dans v30?)
`docker compose exec --user www-data nextcloud_app php occ --no-warnings config:system:set allow_local_remote_servers --value=true`


<!-- docker exec -u www-data app-server php occ --no-warnings config:system:set onlyoffice DocumentServerUrl --value="/ds-vpath/"
docker exec -u www-data app-server php occ --no-warnings config:system:set onlyoffice DocumentServerInternalUrl --value="http://onlyoffice-document-server/"
docker exec -u www-data app-server php occ --no-warnings config:system:set onlyoffice StorageUrl --value="http://nginx-server/"
docker exec -u www-data app-server php occ --no-warnings config:system:set onlyoffice jwt_secret --value="secret"
 -->
Attention : dans parametre avancé du serveur, ajouter: 
- Adresse du ONLYOFFICE Docs pour les demandes internes du serveur : http://onlyoffice/ 
- Adresse du serveur pour les demandes internes du ONLYOFFICE Docs : http://nextcloud_app/

### Pour libresign :

`docker compose exec --user www-data nextcloud_app php occ libresign:install --java`
`docker compose exec --user www-data nextcloud_app php occ libresign:install --pdftk`
`docker compose exec --user www-data nextcloud_app php occ libresign:install --jsignpdf`


## Bug fixes


### encrypted errors

La commande magique si jamais tu vois des soucis de chiffrement sur un fichier :

Tu vas dans le conteneur nextlcloud avec `dex nextcloud_app`

`docker compose exec --user www-data nextcloud_app php occ encryption:fix-encrypted-version Guillaume --path=<file>`
	ex :
`docker compose exec --user www-data nextcloud_app php occ encryption:fix-encrypted-version Guillaume --path=La\ Raffinerie\ \(1\)/Groupe\ Economique/Inter-location/SUIVI\ FACTURATION\ 2022\ -\ ARCHIVE.xlsx `

Voir les logs d'erreur sur l'ui : https://nuage.tierslieux.re/settings/admin/logging

Tu peux aussi lancer la commande depuis l'extérieur, si tu es dans le dossier du compose, comme pour celle ci :


###

Autres erreurs courrantes :

https://belginux.com/nextcloud-corriger-les-avertissements-de-securite/#erreur-reverse-proxy