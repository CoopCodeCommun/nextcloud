# Table des matieres de la stack Nextcloud. La logique vit dans scripts/.
.PHONY: help up down restart logs ps occ init backup check list mount umount verifier update upgrade upgrade-check onlyoffice pg-upgrade

DC := docker compose

# La sauvegarde lit data/ (proprietaire www-data) : root obligatoire.
# On ajoute sudo tout seul si on ne l'est pas.
SUDO := $(shell [ "$$(id -u)" -eq 0 ] || echo sudo)

# Point de montage de make mount (lisible par root seulement, comme data/),
# un par instance (nom du dossier... ou COMPOSE_PROJECT_NAME du .env).
PROJET := $(or $(shell sed -n 's/^[[:space:]]*COMPOSE_PROJECT_NAME[[:space:]]*=[[:space:]]*//p' .env 2>/dev/null | tail -n1 | tr -d "'\""),$(notdir $(CURDIR)))
MOUNTPOINT ?= /tmp/borg-mount-$(PROJET)

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
	@echo "  make init      configure la sauvegarde : cle SSH, depot BWH, cron root (sudo)"
	@echo "  make backup    lance une sauvegarde maintenant (sudo)"
	@echo "  make check     verifie que la derniere sauvegarde est restaurable (sudo)"
	@echo "  make list      liste les archives du depot (sudo)"
	@echo "  make mount [ARCHIVE=<nom>] / make umount   archives en lecture seule (sudo)"
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

init:
	@$(SUDO) bash scripts/init_backup.sh

backup:
	@$(SUDO) bash scripts/backup_nextcloud.sh

check:
	@$(SUDO) bash scripts/check_backup.sh

# Cle dediee scripts/.ssh/<prefixe>_ed25519 si elle existe (make init),
# sinon la cle de root (installation faite a la main).
BORG_ENV = set -a; . scripts/.env; set +a; \
	cle="$(CURDIR)/scripts/.ssh/$${BORG_PREFIX}_ed25519"; \
	test ! -f "$$cle" || export BORG_RSH="/usr/bin/ssh -oStrictHostKeyChecking=accept-new -oIdentitiesOnly=yes -i $$cle";

list:
	@$(SUDO) bash -c '$(BORG_ENV) borg list --glob-archives "$$BORG_PREFIX-*" "$$BORG_REPO"'

mount:
	@$(SUDO) bash -c '$(BORG_ENV) mkdir -p "$(MOUNTPOINT)"; \
	 cible="$$BORG_REPO"; test -z "$(ARCHIVE)" || cible="$$BORG_REPO::$(ARCHIVE)"; \
	 borg mount -o ro "$$cible" "$(MOUNTPOINT)" && echo "[mount] $(MOUNTPOINT) (sudo ls) - demonter : make umount"'

umount:
	@$(SUDO) borg umount "$(MOUNTPOINT)" && echo "[umount] $(MOUNTPOINT) demonte"

verifier:
	@bash scripts/verifier_versions.sh

update:
	@$(SUDO) env OO_CONFIRME=$(OO_CONFIRME) TIMEOUT=$(TIMEOUT) bash scripts/update_nextcloud.sh

upgrade:
	@$(SUDO) env MIN_CORRECTIF=$(MIN_CORRECTIF) APPS_OK=$(APPS_OK) TIMEOUT=$(TIMEOUT) bash scripts/upgrade_nextcloud.sh

upgrade-check:
	@env MIN_CORRECTIF=$(MIN_CORRECTIF) bash scripts/upgrade_nextcloud.sh --verifier

onlyoffice:
	@bash scripts/onlyoffice_connect.sh

pg-upgrade:
	@$(SUDO) env PG_CIBLE=$(PG_CIBLE) bash scripts/pg_upgrade.sh
