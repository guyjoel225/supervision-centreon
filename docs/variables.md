# Catalogue des variables

Toutes les variables des rôles sont préfixées par le nom du rôle, comme l'exige
la convention Ansible. Les rôles prennent leurs valeurs par défaut sur des
variables neutres définies dans l'inventaire, afin qu'une même information ne
soit pas écrite deux fois sous deux noms différents.

Autrement dit : **c'est l'inventaire que l'on modifie au quotidien**, pas les
`defaults` des rôles. Ceux-ci ne servent qu'à rendre chaque rôle réutilisable
isolément, hors de ce projet.

---

## Variables neutres, définies dans l'inventaire

`inventories/<env>/group_vars/all/main.yml`

| Variable | Défaut | Rôle |
|----------|--------|------|
| `ansible_user` | — | Compte SSH utilisé sur toutes les machines |
| `site_name` | `lab` | Nom du site, repris dans les métadonnées SNMP |
| `site_domain` | `lab.local` | Domaine du site |
| `common_timezone` | `UTC` | Fuseau appliqué partout, y compris à PHP sur le central |
| `common_ntp_servers` | pool public | Sources de temps |
| `centreon_central_address` | — | Adresse du central, seule autorisée à interroger les agents |
| `centreon_version` | `25.10` | Version de Centreon installée |
| `centreon_php_version` | `8.2` | Module PHP activé sur le central |
| `centreon_mariadb_version` | `10.11` | Module MariaDB activé sur le central |
| `snmp_agent_v3_user` | `centreon_ro` | Utilisateur SNMP v3 en lecture seule |
| `snmp_agent_v3_auth_protocol` | `SHA` | Protocole d'authentification |
| `snmp_agent_v3_priv_protocol` | `AES` | Protocole de chiffrement |
| `centreon_poller_name` | `Central` | Collecteur qui porte les hôtes |
| `centreon_default_host_template` | `OS-Linux-SNMP-custom` | Modèle appliqué aux hôtes |

`inventories/<env>/group_vars/centreon_central.yml`

| Variable | Défaut | Rôle |
|----------|--------|------|
| `centreon_selinux_state` | `permissive` | État SELinux du central |
| `centreon_manage_firewall` | `true` | Ouvrir les flux dans firewalld |
| `centreon_run_web_installer` | `true` | Dérouler l'assistant automatiquement |
| `centreon_send_statistics` | `false` | Envoi de statistiques d'usage à l'éditeur |
| `centreon_web_protocol` | `http` | Protocole de l'interface |
| `centreon_web_port` | `80` | Port de l'interface |
| `centreon_api_url` | dérivée | Point d'entrée de l'API, utilisé hors des rôles |

`inventories/<env>/group_vars/monitored.yml`

| Variable | Défaut | Rôle |
|----------|--------|------|
| `snmp_agent_manage_firewall` | `true` | Ouvrir le port SNMP localement |
| `snmp_agent_listen_address` | `ansible_host` | Adresse d'écoute de l'agent |
| `snmp_agent_port` | `161` | Port de l'agent |
| `centreon_host_alias` | nom d'inventaire | Libellé affiché dans Centreon |
| `centreon_host_groups` | `[Linux-Servers]` | Groupes Centreon de l'hôte |

Ces deux dernières se surchargent par machine, directement dans `hosts.yml`.

---

## Rôle `common`

| Variable | Défaut | Rôle |
|----------|--------|------|
| `common_manage_timezone` | `true` | Appliquer le fuseau. **À passer à false en production** |
| `common_timezone` | `UTC` | Fuseau horaire |
| `common_manage_hosts_file` | `true` | Alimenter `/etc/hosts` depuis l'inventaire |
| `common_ntp_enabled` | `true` | Installer et configurer chrony |
| `common_ntp_servers` | pool public | Sources de temps |
| `common_base_packages_debian` | curl, ca-certificates, python3-apt | Paquets de base |
| `common_base_packages_redhat` | curl, ca-certificates | Paquets de base |

---

## Rôle `snmp_agent`

| Variable | Défaut | Rôle |
|----------|--------|------|
| `snmp_agent_enable_v3` | `true` | Activer SNMP v3, authentifié et chiffré |
| `snmp_agent_enable_v2c` | `false` | Activer SNMP v2c. **La communauté circule en clair** |
| `snmp_agent_v2c_community` | vide | Communauté v2c |
| `snmp_agent_v2c_accept_weak_community` | `false` | Accepter une communauté de moins de 8 caractères ou valant `public`/`private`/`community`. Nécessaire quand un central en service impose la sienne |
| `snmp_agent_v2c_allowed_managers` | idem v3 | Adresses autorisées en v2c |
| `snmp_agent_v3_user` | `centreon_ro` | Nom de l'utilisateur SNMP v3 |
| `snmp_agent_v3_auth_protocol` | `SHA` | `MD5` ou `SHA` |
| `snmp_agent_v3_priv_protocol` | `AES` | `DES` ou `AES` |
| `snmp_agent_v3_auth_passphrase` | vide | Phrase d'authentification, 8 caractères minimum |
| `snmp_agent_v3_priv_passphrase` | vide | Phrase de chiffrement, 8 caractères minimum |
| `snmp_agent_v3_security_level` | `priv` | Niveau exigé du gestionnaire |
| `snmp_agent_v3_force_recreate_user` | `false` | Recréer l'utilisateur, pour une rotation |
| `snmp_agent_port` | `161` | Port d'écoute |
| `snmp_agent_listen_address` | IPv4 par défaut | Adresse de service |
| `snmp_agent_listen_loopback` | `true` | Écouter aussi sur `127.0.0.1`. En v2c, la communauté y est également acceptée : c'est ce qui permet de prouver la collecte depuis la machine elle-même, sans ouvrir l'agent à une adresse de plus le temps d'un contrôle |
| `snmp_agent_allowed_managers` | `[]` | Adresses autorisées à interroger |
| `snmp_agent_view_name` | `centreonview` | Nom de la vue de lecture |
| `snmp_agent_view_oids` | 7 branches | Périmètre exposé |
| `snmp_agent_sys_location` | `non renseigné` | Emplacement déclaré |
| `snmp_agent_sys_contact` | `non renseigné` | Contact déclaré |
| `snmp_agent_manage_firewall` | `true` | Ouvrir le port localement |
| `snmp_agent_prune_firewall_rules` | `true` | Retirer les autorisations SNMP qui ne sont plus déclarées |
| `snmp_agent_replace_foreign_config` | `false` | Autoriser l'écrasement d'un snmpd.conf modifié par un tiers |
| `snmp_agent_serial` | `[1, "25%"]` | Vagues de déploiement : une machine témoin, puis par quarts |
| `snmp_agent_max_fail_percentage` | `0` | Part d'échecs tolérée avant arrêt du déploiement |

Une liste `snmp_agent_allowed_managers` vide signifie « personne ». C'est
volontaire : le rôle refuse de s'exécuter tant que le central n'est pas déclaré
explicitement.

---

## Rôle `centreon_central`

| Variable | Défaut | Rôle |
|----------|--------|------|
| `centreon_central_version` | `25.10` | Version installée |
| `centreon_central_repo_url` | dérivée | Fichier de dépôt téléchargé |
| `centreon_central_manage_php_module` | `true` | Basculer le flux PHP. **Un reset fait basculer toute autre application PHP de la machine** |
| `centreon_central_php_version` | `8.2` | Module PHP, basculé seulement s'il diffère |
| `centreon_central_mariadb_version` | `10.11` | Module MariaDB |
| `centreon_central_packages` | `centreon-mariadb`, `centreon` | Paquets installés |
| `centreon_central_langpacks` | `glibc-langpack-fr` | Langues de l'interface |
| `centreon_central_allow_shared_host` | `false` | Installer sur une machine faisant déjà tourner un service web ou une base. **Refusé par défaut** |
| `centreon_central_selinux_state` | `permissive` | `disabled`, `permissive` ou `enforcing`. Un abaissement depuis enforcing est signalé |
| `centreon_central_manage_hostname` | `false` | Renommer la machine. **Laissé à false : renommer un serveur en service casse certificats, licences et agrégation de journaux** |
| `centreon_central_hostname` | nom d'inventaire | Nom d'hôte appliqué, si le précédent est activé |
| `centreon_central_php_timezone` | `common_timezone` | Fuseau de PHP |
| `centreon_central_manage_firewall` | `true` | Gérer firewalld |
| `centreon_central_firewall_ports` | 80, 443, 162/udp, 5556 | Flux ouverts |
| `centreon_central_db_socket` | `/var/lib/mysql/mysql.sock` | Socket Unix de MariaDB, employé pour l'administration locale |
| `centreon_central_db_host` | `localhost` | Hôte de la base |
| `centreon_central_db_port` | `3306` | Port de la base |
| `centreon_central_db_admin_user` | `centreon_install` | Compte employé par l'assistant. Pas root, dont l'authentification unix_socket ne fonctionne que pour le compte système du même nom |
| `centreon_central_db_admin_password` | secret du coffre | Mot de passe de ce compte |
| `centreon_central_web_user` | `apache` | Compte système de php-fpm, donc de l'assistant |
| `centreon_central_db_root_password` | vide | Mot de passe root MariaDB |
| `centreon_central_db_user` | `centreon` | Compte applicatif |
| `centreon_central_db_password` | vide | Mot de passe du compte applicatif |
| `centreon_central_db_configuration` | `centreon` | Base de configuration |
| `centreon_central_db_storage` | `centreon_storage` | Base de métriques |
| `centreon_central_db_harden` | `true` | Appliquer le durcissement. **Ignoré si la base préexistait au déploiement** |
| `centreon_central_reset_incomplete_install` | `false` | Détruire les bases pour repartir d'une installation propre. **Uniquement sur une installation jamais aboutie** |
| `centreon_central_run_web_installer` | `true` | Dérouler l'assistant |
| `centreon_central_web_admin_login` | `admin` | Compte administrateur |
| `centreon_central_web_admin_password` | vide | Mot de passe, 12 caractères minimum |
| `centreon_central_send_statistics` | `false` | Statistiques d'usage |
| `centreon_central_engine_parameters` | `{}` | Surcharges des chemins du moteur. Les valeurs sont lues sur la machine, seuls les écarts se déclarent ici |
| `centreon_central_broker_parameters` | `{}` | Surcharges des chemins du broker, même principe |
| `centreon_central_plugin_packages` | Linux SNMP, HTTP | Plugins installés |
| `centreon_central_services` | 10 services | Services activés au démarrage |

---

## Rôle `centreon_hosts`

| Variable | Défaut | Rôle |
|----------|--------|------|
| `centreon_hosts_api_url` | dérivée | Point d'entrée de l'API v1 |
| `centreon_hosts_api_user` | `admin` | Compte d'accès à l'API |
| `centreon_hosts_api_password` | mot de passe admin | Secret d'accès |
| `centreon_hosts_api_timeout` | `60` | Délai des appels, en secondes |
| `centreon_hosts_monitored_group` | `monitored` | Groupe d'inventaire à déclarer |
| `centreon_hosts_poller_name` | `Central` | Collecteur porteur |
| `centreon_hosts_default_host_template` | `OS-Linux-SNMP-custom` | Modèle par défaut |
| `centreon_hosts_snmp_version` | `3` | Version SNMP posée sur les hôtes |
| `centreon_hosts_snmp_v3_*` | valeurs de `snmp_agent_*` | Macros SNMP v3 |
| `centreon_hosts_force_update_snmp_macros` | `false` | Réécrire les passphrases |
| `centreon_hosts_apply_configuration` | `true` | Exporter et recharger le collecteur |
| `centreon_hosts_force_apply` | `false` | Recharger même sans changement. **Recharger interrompt la collecte de tout le parc porté par ce collecteur** |

---

## Étiquettes disponibles

| Étiquette | Portée |
|-----------|--------|
| `common` | Prérequis système |
| `central` | Installation du serveur central |
| `snmp` | Agents SNMP |
| `declaration` | Déclaration des hôtes dans Centreon |
| `verify` | Vérification complète |
| `verify_agents`, `verify_snmp`, `verify_central` | Vérification par étape |
| `centreon_preflight` | Contrôle préalable de la machine, sans rien modifier |
| `centreon_prereq`, `centreon_repos`, `centreon_packages`, `centreon_database`, `centreon_services`, `centreon_firewall`, `centreon_installer`, `centreon_plugins` | Étapes internes du central |
