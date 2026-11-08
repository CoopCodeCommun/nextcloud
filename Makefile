# Table des matieres de la stack Nextcloud. La logique vit dans scripts/.
.PHONY: help up down restart logs ps occ backup check list verifier update upgrade upgrade-check onlyoffice pg-upgrade

DC := docker compose

# La sauvegarde lit data/ (proprietaire www-data) : root obligatoire.
# On ajoute sudo tout seul si on ne l'est pas.
SUDO := $(shell [ "$$(id -u)" -eq 0 ] || echo sudo)

help:
	@echo "Stack Nextcloud — cibles disponibles :"
	@echo ""
	@echo "  make up        demarre la stack"
	@echo "  make down      arrete la stack (les donnees restent dans data/ et database/)"
	@echo "  make restart   redemarre la stack"
	@echo "  make logs      suit les logs de Nextcloud"
	@echo "  make ps        etat des conteneurs"
	@echo "  make occ CMD=\"status\"   lance une commande occ"
	@echo ""
	@echo "  make backup    lance une sauvegarde maintenant (sudo)"
	@echo "  make check     verifie que la derniere sauvegarde est restaurable (sudo)"
	@echo "  make list      liste les archives du depot (sudo)"
	@echo ""
	@echo "  make verifier       versions du .env compatibles avec l'installe ? (rien ne change)"
	@echo "  make update         correctifs : sauvegarde, puis Nextcloud + OnlyOffice (sudo)"
	@echo "                      (OO_CONFIRME=1 si ONLYOFFICE_TAG a change)"
	@echo "  make upgrade-check  la majeure Nextcloud suivante est-elle possible ?"
	@echo "  make upgrade        Nextcloud : majeure suivante, apps verifiees (sudo)"
	@echo "  make onlyoffice     (re)connecte OnlyOffice a Nextcloud depuis le JWT_SECRET du .env"
	@echo "  make pg-upgrade PG_CIBLE=19   PostgreSQL : version majeure (sudo)"
	@echo ""
	@echo "  Versions : NEXTCLOUD_TAG, POSTGRES_TAG, ONLYOFFICE_TAG dans le .env"

# Garde-fous avant de demarrer : un tag errone dans le .env ne doit ni sauter
# une majeure Nextcloud, ni demarrer PostgreSQL sur une base vide.
up: verifier
	$(DC) up -d

down:
	$(DC) down

restart:
	$(DC) restart

logs:
	$(DC) logs -f nextcloud_app

ps:
	$(DC) ps

occ:
	$(DC) exec -u www-data nextcloud_app php occ $(CMD)

backup:
	@$(SUDO) bash scripts/backup_nextcloud.sh

check:
	@$(SUDO) bash scripts/check_backup.sh

list:
	@$(SUDO) bash -c 'set -a; . scripts/.env; set +a; borg list --glob-archives "$$BORG_PREFIX-*" "$$BORG_REPO"'

verifier:
	@bash scripts/verifier_versions.sh

update:
	@$(SUDO) env OO_CONFIRME=$(OO_CONFIRME) bash scripts/update_nextcloud.sh

upgrade:
	@$(SUDO) env MIN_CORRECTIF=$(MIN_CORRECTIF) APPS_OK=$(APPS_OK) bash scripts/upgrade_nextcloud.sh

upgrade-check:
	@env MIN_CORRECTIF=$(MIN_CORRECTIF) bash scripts/upgrade_nextcloud.sh --verifier

onlyoffice:
	@bash scripts/onlyoffice_connect.sh

pg-upgrade:
	@$(SUDO) env PG_CIBLE=$(PG_CIBLE) bash scripts/pg_upgrade.sh
