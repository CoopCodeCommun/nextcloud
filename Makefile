# Table des matieres de la stack Nextcloud. La logique vit dans scripts/.
.PHONY: help up down restart logs ps occ backup check list update onlyoffice pg-upgrade

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
	@echo "  make update      sauvegarde, puis met a jour Nextcloud + OnlyOffice (sudo)"
	@echo "  make onlyoffice  (re)connecte OnlyOffice a Nextcloud depuis le JWT_SECRET du .env"
	@echo "  make pg-upgrade  monte PostgreSQL de version majeure (PG_CIBLE=18 par defaut, sudo)"

up:
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

update:
	@$(SUDO) bash scripts/update_nextcloud.sh

onlyoffice:
	@bash scripts/onlyoffice_connect.sh

pg-upgrade:
	@$(SUDO) env PG_CIBLE=$(or $(PG_CIBLE),18) bash scripts/pg_upgrade.sh
