# Raccourcis d'exploitation. Toutes les cibles supposent un environnement
# Ansible installé (voir docs/guide-utilisation.md).

# La cible lint-collections emploie une substitution de processus.
SHELL := /bin/bash

INVENTORY ?= inventories/lab/hosts.yml
LIMIT     ?= all

# ---------------------------------------------------------------------
# Authentification
# ---------------------------------------------------------------------
# Le mot de passe sudo est demandé une fois et réutilisé sur toutes les
# machines. Si le compte dispose de NOPASSWD partout, neutraliser avec :
#   make snmp-v3 BECOME=
BECOME ?= -K

# Le mot de passe du coffre est demandé, sauf si la variable
# d'environnement ANSIBLE_VAULT_PASSWORD_FILE est définie : Ansible lit
# alors le fichier lui-même, et le demander en plus serait redondant.
ifdef ANSIBLE_VAULT_PASSWORD_FILE
VAULT =
else
VAULT = --ask-vault-pass
endif

AUTH = $(BECOME) $(VAULT)

# Options supplémentaires passées à ansible-playbook, par exemple :
#   make central OPTS="-e centreon_central_reset_incomplete_install=true"
OPTS ?=

.PHONY: help deps lint lint-collections lint-variables check deploy deploy-agents snmp-only snmp-v3 snmp-v2c central agents declare verify verify-agents facts diag-base diag-installeur diag-connexion diag-generation diag-agent

help:
	@echo "deps     Installer les collections Ansible requises"
	@echo "lint     Contrôler la syntaxe et la qualité (yamllint + ansible-lint)"
	@echo "check    Simuler le déploiement sans rien modifier"
	@echo "deploy   Dérouler le déploiement complet"
	@echo "deploy-agents  Tout sauf le central, puis vérifier : utile sans serveur central"
	@echo "snmp-v3        Agents en SNMP v3 authentifié et chiffré"
	@echo "snmp-v2c       Agents en SNMP v2c : communauté en clair, si le central l'impose"
	@echo "snmp-only      Agents selon l'inventaire : permet la cohabitation v2c et v3"
	@echo "central  Installer ou mettre à jour le seul serveur central"
	@echo "agents   Configurer les seuls agents SNMP"
	@echo "declare  Déclarer les hôtes dans Centreon"
	@echo "verify   Vérifier la chaîne de bout en bout, sans rien modifier"
	@echo "verify-agents  Vérifier les agents SNMP depuis le contrôleur, sans central"
	@echo ""
	@echo "diag-base        Base de données : comptes, tables, accès"
	@echo "diag-installeur  Assistant d'installation web : étape et état"
	@echo "diag-connexion   Connexion à l'interface et à son API"
	@echo "diag-generation  Échec de génération : nomme l'objet fautif"
	@echo "diag-agent       Configuration SNMP existante, secrets masqués"
	@echo ""
	@echo ""
	@echo "Les mots de passe sudo et du coffre sont demandés au lancement."
	@echo "Pour ne rien demander : exporter ANSIBLE_VAULT_PASSWORD_FILE,"
	@echo "et lancer avec BECOME= si sudo est en NOPASSWD."
	@echo ""
	@echo "Variables : INVENTORY=$(INVENTORY) LIMIT=$(LIMIT)"

deps:
	ansible-galaxy collection install -r requirements.yml -p ./collections

lint: lint-collections lint-variables
	ansible-lint
	ansible-playbook -i $(INVENTORY) playbooks/site.yml --syntax-check

# Le contrôle syntaxique ne résout pas les modules des fichiers chargés par
# include_tasks, et le lint ne signale pas une collection absente. Une faute
# d'espace de noms passe donc les deux et n'apparaît qu'à l'exécution.
# Une variable de rôle employée dans un playbook qui ne charge pas ce rôle
# est indéfinie à l'exécution. Ni le lint ni le contrôle syntaxique ne le
# voient : la faute n'apparaît qu'au déploiement.
lint-variables:
	@python3 scripts/verifier-variables-de-role.py

lint-collections:
	@employees=$$(grep -rhoE "^[[:space:]]+[a-z_]+\.[a-z_]+\.[a-z_]+:" roles playbooks \
	  | tr -d " :" | cut -d. -f1,2 | sort -u | grep -v "^ansible.builtin$$"); \
	declarees=$$(grep "name:" requirements.yml | sed "s/.*name: //" | sort -u); \
	manquantes=$$(comm -23 <(echo "$$employees") <(echo "$$declarees")); \
	if [ -n "$$manquantes" ]; then \
	  echo "Collections employées mais non déclarées dans requirements.yml :"; \
	  echo "$$manquantes" | sed "s/^/  /"; exit 1; \
	else echo "Collections : toutes celles employées sont déclarées."; fi

check:
	ansible-playbook -i $(INVENTORY) playbooks/site.yml --limit $(LIMIT) --check --diff $(AUTH) $(OPTS)

deploy:
	ansible-playbook -i $(INVENTORY) playbooks/site.yml --limit $(LIMIT) $(AUTH) $(OPTS)

# Agents SNMP seuls, sans le rôle common. Point d'entrée pour un central
# Centreon déjà en service, et le seul acceptable sur des serveurs en production.
snmp-v3:
	ansible-playbook -i $(INVENTORY) playbooks/snmp-v3.yml --limit $(LIMIT) $(AUTH) $(OPTS)

snmp-v2c:
	ansible-playbook -i $(INVENTORY) playbooks/snmp-v2c.yml --limit $(LIMIT) $(AUTH) $(OPTS)

snmp-only:
	ansible-playbook -i $(INVENTORY) playbooks/snmp-only.yml --limit $(LIMIT) $(AUTH) $(OPTS)

# Prérequis, agents SNMP et vérification, sans toucher au serveur central.
deploy-agents:
	ansible-playbook -i $(INVENTORY) playbooks/site-agents.yml $(AUTH) $(OPTS)

central:
	ansible-playbook -i $(INVENTORY) playbooks/20-central.yml $(AUTH) $(OPTS)

agents:
	ansible-playbook -i $(INVENTORY) playbooks/30-snmp-agents.yml --limit $(LIMIT) $(AUTH) $(OPTS)

declare:
	ansible-playbook -i $(INVENTORY) playbooks/40-centreon-hosts.yml $(AUTH) $(OPTS)

verify:
	ansible-playbook -i $(INVENTORY) playbooks/99-verify.yml $(AUTH) $(OPTS)

# Utile tant que le serveur central n'existe pas : c'est le contrôleur Ansible
# qui interroge les agents à sa place.
verify-agents:
	ansible-playbook -i $(INVENTORY) playbooks/98-verify-snmp-agents.yml $(AUTH) $(OPTS)

# Les diagnostics ne modifient rien : ils relèvent l'état de la plateforme et
# nomment la cause d'une panne que l'interface de programmation résume en un
# message trop général pour être exploitable.
diag-base:
	ansible-playbook -i $(INVENTORY) playbooks/90-diagnostic-base.yml $(AUTH) $(OPTS)

diag-installeur:
	ansible-playbook -i $(INVENTORY) playbooks/91-diagnostic-installeur.yml $(AUTH) $(OPTS)

diag-connexion:
	ansible-playbook -i $(INVENTORY) playbooks/92-diagnostic-connexion.yml $(AUTH) $(OPTS)

diag-generation:
	ansible-playbook -i $(INVENTORY) playbooks/93-diagnostic-generation.yml $(AUTH) $(OPTS)

# Montre ce que contient un snmpd.conf que le rôle refuse d'écraser, sans en
# divulguer les communautés ni les phrases secrètes.
diag-agent:
	ansible-playbook -i $(INVENTORY) playbooks/94-diagnostic-agent-snmp.yml --limit $(LIMIT) $(AUTH) $(OPTS)

facts:
	ansible -i $(INVENTORY) $(LIMIT) $(BECOME) -m ansible.builtin.setup -a "filter=ansible_distribution*"
