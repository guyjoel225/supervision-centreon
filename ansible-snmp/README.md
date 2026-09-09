# Playbook Ansible — Déploiement SNMP v2c

## Structure

```
ansible-snmp/
├── playbook-snmp.yml
├── inventory.ini
├── templates/
│   └── snmpd.conf.j2
├── group_vars/
│   └── all/
│       └── vault.yml.example
└── README.md
```

## Prérequis

- Ansible >= 2.14
- Collections : `community.general`, `ansible.posix`
  ```bash
  ansible-galaxy collection install community.general ansible.posix
  ```
- Accès SSH + sudo sur les serveurs cibles
- Python présent sur les cibles (géré nativement par la plupart des distros)

## Mise en place

1. Adapter `inventory.ini` avec vos serveurs réels.
2. Copier et chiffrer le vault :
   ```bash
   cp group_vars/all/vault.yml.example group_vars/all/vault.yml
   # éditer la community string dans vault.yml
   ansible-vault encrypt group_vars/all/vault.yml
   ```
3. Ajuster les variables dans `playbook-snmp.yml` :
   - `snmp_supervision_network` : sous-réseau autorisé à interroger l'agent
   - `snmp_supervision_host` : IP du serveur de supervision (traps)
   - `snmp_syslocation` / `snmp_syscontact`

## Exécution

```bash
# Dry-run (vérifier ce qui va changer)
ansible-playbook -i inventory.ini playbook-snmp.yml --ask-vault-pass --check --diff

# Déploiement réel
ansible-playbook -i inventory.ini playbook-snmp.yml --ask-vault-pass

# Sur un seul serveur
ansible-playbook -i inventory.ini playbook-snmp.yml --ask-vault-pass --limit srv-prod-01
```

## Ce que fait le playbook

1. Installe `snmpd` (paquets adaptés selon Debian/RedHat).
2. Sauvegarde la config d'origine (`snmpd.conf.orig`), une seule fois.
3. Déploie `snmpd.conf` depuis un template Jinja2, avec validation syntaxique
   avant application (`validate: /usr/sbin/snmpd -Cf %s -c %s`).
4. Ouvre le port UDP 161 uniquement pour l'IP du serveur de supervision
   (UFW ou firewalld selon la distro).
5. Active et démarre le service.
6. Vérifie que l'agent répond via `snmpwalk` en fin de run.

## Points de sécurité intégrés

- `rocommunity` (lecture seule uniquement, jamais `rwcommunity`).
- Community string stockée chiffrée (Ansible Vault), jamais en clair dans le repo.
- Restriction par sous-réseau, pas d'écoute ouverte à tous.
- Vue SNMP limitée (`systemview`) pour ne pas exposer toute la MIB.
- Firewall configuré pour restreindre l'accès au seul serveur de supervision.

## Pour aller plus loin

- Passage à SNMPv3 (authentification + chiffrement) recommandé à moyen terme.
- Ajouter un tag `--tags firewall` ou `--tags config` si vous voulez découper
  les tâches pour des relances ciblées.
