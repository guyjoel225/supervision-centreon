# Guide d'utilisation

Ce document explique quoi lancer, quand, et ce qui se passe. Il se lit sans
connaître le contenu des rôles.

Les autres documents du dépôt répondent à d'autres questions :
[`architecture.md`](architecture.md) explique pourquoi le projet est construit
ainsi, [`variables.md`](variables.md) catalogue les réglages,
[`exploitation.md`](exploitation.md) détaille les procédures courantes.

---

## 1. Quel playbook pour quel besoin

C'est la seule table à retenir. Tout le reste en découle.

| Votre situation | Ce que vous lancez |
|---|---|
| Un central Centreon existe déjà, il interroge en **SNMP v3** | `make snmp-v3` |
| Un central Centreon existe déjà, il interroge en **SNMP v2c** | `make snmp-v2c` |
| Vous migrez un parc de la v2c vers la v3 | `make snmp-only`, versions activées dans l'inventaire |
| Vous n'avez **pas** de central et voulez tout installer | `make deploy` |
| Vous voulez seulement vérifier que la collecte fonctionne | `make verify-agents` |

Chacune de ces commandes demande au lancement le mot de passe `sudo`, puis
celui du coffre. Pour n'avoir rien à saisir, exportez
`ANSIBLE_VAULT_PASSWORD_FILE` et, si le compte dispose de `NOPASSWD` sur toutes
les machines, lancez avec `BECOME=` :

```bash
make snmp-v3 BECOME=
```

Les trois premières lignes ne touchent **que** les hôtes à superviser. Elles
n'installent aucun paquet Centreon sur eux, ne modifient ni leur fuseau
horaire, ni leur synchronisation de l'heure, ni leur `/etc/hosts`. Ce sont les
seules conçues pour tourner sur des serveurs en production.

La quatrième installe un serveur central complet et modifie beaucoup de choses
sur la machine qui le portera. Elle suppose une machine dédiée.

Dans les trois premiers cas, une étape reste à faire ensuite : **déclarer les
hôtes dans Centreon**, par playbook ou dans l'interface. Configurer les agents
ne suffit pas, et le symptôme de l'oubli est trompeur. Voir §7.

---

## 2. Ce qu'il faut avoir avant de lancer quoi que ce soit

### 2.1 Sur le contrôleur Ansible

```bash
sudo apt install -y python3-venv
python3 -m venv ~/.venvs/ansible
~/.venvs/ansible/bin/pip install ansible-core
export PATH=~/.venvs/ansible/bin:$PATH
```

Puis, depuis le dépôt :

```bash
make deps
```

### 2.2 Un accès aux machines

Connexion SSH par clé, et `sudo` sur chaque machine. Vérifiez-le avant tout
déploiement, cela évite de chercher ailleurs une cause qui est là :

```bash
ansible -i inventories/lab/hosts.yml all -m ansible.builtin.ping -K
```

Le `-K` demande le mot de passe `sudo` une fois et le réutilise partout. Il
suppose donc le même mot de passe sur toutes les machines. À défaut,
configurez `NOPASSWD` pour le compte employé.

### 2.3 L'inventaire

`inventories/lab/hosts.yml` décrit les machines. Chaque hôte à superviser va
sous `monitored_debian_family` ou `monitored_rhel_family` selon son système :

```yaml
monitored_debian_family:
  hosts:
    srv-web-01:
      ansible_host: 10.0.0.31
      centreon_host_alias: Serveur web de production
      centreon_host_groups: [Linux-Servers, Web]
```

`inventories/lab/group_vars/all/main.yml` porte les réglages partagés. Deux
comptent plus que les autres :

```yaml
ansible_user: osadmin
centreon_central_address: 10.0.0.25
```

`centreon_central_address` est l'adresse du serveur central **qui interrogera
les agents**. C'est elle qui autorise l'interrogation et ouvre le pare-feu de
chaque hôte. Une valeur erronée produit un symptôme trompeur : les agents
tournent, `snmpd` écoute, tout paraît sain, et le central ne reçoit rien.

### 2.4 Le coffre à secrets

Aucun mot de passe n'est écrit en clair dans le dépôt.

```bash
cp inventories/lab/group_vars/all/vault.yml.example inventories/lab/group_vars/all/vault.yml
$EDITOR inventories/lab/group_vars/all/vault.yml
ansible-vault encrypt inventories/lab/group_vars/all/vault.yml
```

Le fichier chiffré peut être versionné. Le fichier en clair, jamais.

| Secret | Nécessaire pour | Contrainte |
|---|---|---|
| `vault_snmp_agent_v3_auth_passphrase` | SNMP v3 | 8 caractères minimum |
| `vault_snmp_agent_v3_priv_passphrase` | SNMP v3 | 8 caractères minimum |
| `vault_snmp_agent_v2c_community` | SNMP v2c | voir §4.2 |
| `vault_centreon_web_admin_password` | Installation du central | 12 caractères, une majuscule, une minuscule, un chiffre, un caractère parmi `@$!%*?&` |
| `vault_centreon_db_root_password` | Installation du central | libre. Sert au compte `centreon_install`, celui qu'emploie l'assistant, et non au compte root de MariaDB |
| `vault_centreon_db_password` | Installation du central | libre |

Ne renseignez que ce dont vous avez besoin. Les trois derniers ne servent qu'à
installer un central.

Pour éviter de saisir la phrase de passe à chaque commande :

```bash
echo "ma-phrase" > ~/.vault_pass && chmod 600 ~/.vault_pass
export ANSIBLE_VAULT_PASSWORD_FILE=~/.vault_pass
```

---

## 3. Scénario A : central existant, interrogation en SNMP v3

C'est le cas le plus simple et le plus sûr.

**Ce qu'il faut avoir renseigné :** les deux passphrases v3 dans le coffre,
identiques à celles que le central utilise déjà, et `centreon_central_address`.

**Ce que vous lancez :**

```bash
make check LIMIT=monitored     # simulation, ne modifie rien
make snmp-v3                   # exécution
```

**Ce qui se passe sur chaque machine :** installation de `net-snmp`, dépôt de
`/etc/snmp/snmpd.conf`, création de l'utilisateur SNMP v3, ouverture du port
161 vers le central uniquement, puis démarrage de l'agent. Le déploiement se
fait par vagues : une machine témoin d'abord, le reste par quarts.

**Ce que vous devez voir à la fin :** une ligne par machine donnant son nom
système et sa charge, suivie de deux assertions vertes. C'est la preuve que la
collecte fonctionne réellement, pas seulement que les tâches se sont exécutées.

---

## 4. Scénario B : central existant, interrogation en SNMP v2c

### 4.1 Ce que ça implique

La v2c ne chiffre rien et n'authentifie personne. La communauté circule en
clair sur le réseau : quiconque écoute le lien la capture, et peut ensuite lire
toute la vue exposée par les agents. Deux protections seulement subsistent, et
le rôle applique les deux : la communauté n'est acceptée que depuis les
adresses déclarées, et le pare-feu n'ouvre le port que pour elles.

N'utilisez ce scénario que si le central en place ne sait pas faire autrement.

### 4.2 La communauté

Mettez dans le coffre celle que le central utilise **déjà** : c'est elle qui
fait foi, pas l'inverse.

```yaml
vault_snmp_agent_v2c_community: "<COMMUNAUTE_DU_CENTRAL>"
```

Le rôle refuse par défaut les communautés de moins de huit caractères et les
valeurs `public`, `private` et `community`, qui sont les premières essayées par
quiconque balaie un réseau. Si la communauté imposée par le central est dans ce
cas et qu'elle ne peut pas être changée, le déploiement s'arrête en vous
l'expliquant. Passez alors outre en connaissance de cause :

```bash
ansible-playbook -i inventories/lab/hosts.yml playbooks/snmp-v2c.yml -K --ask-vault-pass -e snmp_agent_v2c_accept_weak_community=true
```

L'avertissement sera rappelé à chaque exécution.

### 4.3 Ce que vous lancez

```bash
make snmp-v2c
```

### 4.4 Si ces hôtes sont déjà supervisés

C'est le cas le plus fréquent quand le central est en service depuis longtemps :
les machines ont déjà un `/etc/snmp/snmpd.conf` configuré à la main ou par un
autre outil. **Le playbook s'arrêtera alors, et c'est voulu.** Le rôle détecte
que le fichier a divergé de la version livrée par le paquet et qu'il ne porte
pas sa signature. Sans ce garde-fou, vous perdriez les vues en place, les
éventuelles extensions, la configuration de traps, et la supervision actuelle
tomberait en aveugle sans la moindre alerte.

Commencez donc par la simulation, qui ne modifie rien et vous dira où vous en
êtes :

```bash
ansible-playbook -i inventories/lab/hosts.yml playbooks/snmp-v2c.yml --check --diff -K --ask-vault-pass
```

**Si elle passe**, les machines n'étaient pas encore supervisées et leur
configuration est celle du paquet. Lancez `make snmp-v2c`, c'est terminé.

**Si elle s'arrête sur le garde-fou**, allez d'abord voir ce que contient la
configuration en place avant de décider :

```bash
ansible -i inventories/lab/hosts.yml monitored -m ansible.builtin.command -a "grep -vE '^\s*#|^\s*$' /etc/snmp/snmpd.conf" -K
```

Si vous n'y trouvez qu'une communauté et une vue, le rôle produit l'équivalent
et vous pouvez remplacer. Si des directives `proc`, `extend`, `trapsink` ou des
vues taillées pour d'autres besoins apparaissent, reportez-les d'abord dans les
variables du rôle : sinon vous perdrez des contrôles côté Centreon.

Procédez ensuite machine par machine, en commençant par une seule :

```bash
ansible-playbook -i inventories/lab/hosts.yml playbooks/snmp-v2c.yml -K --ask-vault-pass -e snmp_agent_replace_foreign_config=true --limit un-seul-hote
```

Vérifiez dans Centreon que ses contrôles restent verts, puis élargissez. Une
sauvegarde horodatée du fichier remplacé est conservée à côté de l'original
dans tous les cas.

---

## 5. Scénario C : migrer un parc de la v2c vers la v3

C'est le seul cas qui n'utilise ni `snmp-v3.yml` ni `snmp-v2c.yml`, puisque les
deux forcent une version unique. On passe par l'inventaire, qui seul permet
d'activer les deux à la fois.

**Étape 1.** Dans `group_vars/all/main.yml`, activez les deux versions et
renseignez les trois secrets :

```yaml
snmp_agent_enable_v2c: true
snmp_agent_enable_v3: true
```

```bash
make snmp-only
```

Les agents répondent désormais aux deux. Le central continue d'interroger en
v2c, sans interruption.

**Étape 2.** Basculez les hôtes en v3 côté Centreon, à votre rythme, et
vérifiez que la collecte tient.

**Étape 3.** Une fois tous les hôtes basculés, refermez l'ancien accès :

```yaml
snmp_agent_enable_v2c: false
```

```bash
make snmp-only
```

Faire l'inverse, c'est-à-dire couper la v2c avant d'avoir basculé, crée un trou
de supervision sur tout le parc.

---

## 6. Scénario D : installer une plateforme complète

À n'employer que si vous n'avez pas encore de central.

**Contrainte à connaître :** Centreon ne s'installe que sur Alma, RHEL, Oracle
Linux 8 ou 9, ou Debian 12, en x86_64. **Pas sur Ubuntu, ni sur EL10.** Le rôle
refuse d'emblée toute autre plateforme plutôt que d'échouer trente tâches plus
loin sur un dépôt introuvable.

**Deuxième contrainte :** la machine doit être dédiée. Si `httpd`, `nginx`,
`mariadb`, `mysqld` ou `php-fpm` y tournent déjà, le déploiement s'arrête. Il
abaisserait SELinux, ferait basculer le flux PHP de la machine entière,
durcirait une base qui ne lui appartient pas et redémarrerait le service web.
Passer outre demande `-e centreon_central_allow_shared_host=true`, après avoir
mesuré les conséquences.

```bash
make check     # simulation
make deploy    # tout : prérequis, central, agents, déclaration, vérification
make verify    # preuve de bout en bout
```

L'assistant d'installation web de Centreon, normalement parcouru à la souris en
neuf écrans, est déroulé automatiquement. Sans cela, la plateforme ne serait pas
reconstructible à l'identique.

---

## 7. Déclarer les hôtes dans Centreon

Configurer les agents ne suffit pas. Tant que les hôtes ne sont pas déclarés
côté central, ils répondent aux requêtes SNMP mais personne ne les interroge et
rien n'apparaît dans l'interface. C'est l'étape que l'on oublie, et le symptôme
est trompeur : la vérification des agents passe, et Centreon reste vide.

Deux voies, selon que vous avez ou non un accès au central.

### 7.1 Par playbook, si le central est accessible

```bash
make declare
```

Ce playbook s'exécute **sur** le serveur central : il suppose donc un accès SSH
à cette machine, et un compte disposant des droits sur son interface de
programmation. Renseignez ces deux points dans `group_vars` :

```yaml
centreon_web_admin_login: admin
centreon_api_url: "http://10.0.0.25:80/centreon/api/index.php"
```

Le mot de passe du compte vient du coffre, dans
`vault_centreon_web_admin_password`.

Ce que le playbook fait, dans cet ordre : il crée les groupes d'hôtes cités
dans l'inventaire s'ils manquent, crée les hôtes absents avec leur alias, leur
adresse, leur modèle et leur collecteur, pose la version SNMP et, selon le cas,
la communauté v2c ou les cinq macros v3, applique le modèle aux hôtes
nouvellement créés, puis exporte la configuration vers le collecteur.

Il ne recrée jamais ce qui existe, et **ne recharge le collecteur que si
quelque chose a réellement changé**. C'est important : recharger fait
redémarrer le moteur de supervision, donc interrompt brièvement la collecte de
tout le parc porté par ce collecteur. Rejouer le playbook sur un parc stable
n'a donc aucun effet.

### 7.2 À la main dans l'interface

C'est la voie à prendre si le central ne vous est pas accessible en SSH, ou si
sa configuration est gérée par une autre équipe.

Pour chaque hôte, dans **Configuration > Hosts > Hosts**, cliquez sur **Add**
et renseignez :

| Champ | Valeur |
|---|---|
| **Name** | le nom de la machine, sans espace ni caractère spécial |
| **Alias** | un libellé lisible, les espaces sont acceptés |
| **Address** | l'adresse IP ou le nom DNS de la machine |
| **SNMP Community & Version** | la communauté, puis `2c` dans la liste déroulante |
| **Monitoring server** | le collecteur qui interrogera cet hôte |
| **Templates** | `OS-Linux-SNMP-custom` |

En SNMP v3, le champ de communauté reste **vide** et les paramètres passent par
les macros de l'hôte, dans la section **Host check options** :
`SNMP_V3_USERNAME`, `SNMP_V3_AUTH_PROTOCOL`, `SNMP_V3_AUTH_PASSPHRASE`,
`SNMP_V3_PRIV_PROTOCOL` et `SNMP_V3_PRIV_PASSPHRASE`. Ces valeurs sont celles
du coffre, et doivent correspondre exactement à ce qui est configuré sur les
agents.

Cliquez sur **Save**.

### 7.3 Déployer la configuration, dans les deux cas

Rien n'est actif tant que la configuration n'a pas été exportée vers le
collecteur. Cette étape est faite automatiquement par `make declare` ; à la
main, elle se fait dans **Configuration > Pollers > Pollers**.

La colonne **Conf changed** signale les collecteurs dont la configuration a
changé depuis le dernier export. Sélectionnez le vôtre, cliquez sur **Export
configuration**, et cochez :

- **Generate Configuration Files**
- **Move Export Files**
- **Restart Monitoring Engine**, en choisissant la méthode **Reload**

`Reload` suffit quand on a créé, supprimé ou modifié des objets supervisés, ce
qui est le cas ici. `Restart` n'est nécessaire que pour un changement dans la
communication entre collecteur et central, ou dans la configuration du moteur,
et prend plus de temps.

Cliquez sur **Export**, puis lisez le journal affiché : il doit se terminer
sans erreur.

### 7.4 Les statuts ne passent pas au vert tout de suite

Comptez quelques minutes, le temps du premier cycle de contrôle. Si un hôte
reste en erreur au-delà, la cause est presque toujours l'une des trois
suivantes, dans cet ordre de fréquence : le pare-feu de l'hôte n'autorise pas
l'adresse depuis laquelle le collecteur interroge réellement, la communauté ou
les passphrases déclarées dans Centreon diffèrent de celles posées sur l'agent,
ou la version SNMP déclarée ne correspond pas à celle activée sur l'agent.

---

## 8. Vérifier

```bash
make verify-agents    # les agents : par le contrôleur en v3, par la boucle locale en v2c
make verify           # la chaîne complète, exige un central en service
```

Ces deux playbooks ne configurent rien. Ils produisent une preuve pour chaque
maillon : le démon tourne et est activé au démarrage, il écoute sur la bonne
adresse, il répond à une requête réelle, et sa vue expose les compteurs que
consommeront les plugins Centreon.

Un playbook qui se termine sans erreur ne prouve pas que la supervision
fonctionne. Il prouve que les tâches se sont exécutées. C'est la raison d'être
de ces deux-là.

---

## 9. Opérations courantes

### Ajouter un hôte

Déclarez-le dans l'inventaire, puis :

```bash
make snmp-v3 LIMIT=nouveau-serveur
```

Rejouer sur tout le parc ne présente pas de risque : le rôle ne modifie que ce
qui doit l'être.

### Ne traiter qu'une partie du parc

```bash
make snmp-v3 LIMIT=srv-web-01
make snmp-v3 LIMIT=monitored_debian_family
```

### Ne rejouer qu'une étape

```bash
ansible-playbook -i inventories/lab/hosts.yml playbooks/site.yml --tags snmp
ansible-playbook -i inventories/lab/hosts.yml playbooks/20-central.yml --tags centreon_database
```

Étiquettes disponibles : `common`, `snmp`, `central`, `declaration`, `verify`,
et pour les étapes internes du central `centreon_preflight`, `centreon_prereq`,
`centreon_repos`, `centreon_packages`, `centreon_database`, `centreon_services`,
`centreon_firewall`, `centreon_installer`, `centreon_plugins`.

### Faire tourner les secrets SNMP

Les passphrases sont partagées entre les agents et le central : les deux côtés
changent ensemble. Enchaînez sans attendre, la collecte est interrompue entre
les deux étapes.

```bash
ansible-vault edit inventories/lab/group_vars/all/vault.yml
```

```bash
ansible-playbook -i inventories/lab/hosts.yml playbooks/30-snmp-agents.yml -K --ask-vault-pass -e snmp_agent_v3_force_recreate_user=true
```

```bash
ansible-playbook -i inventories/lab/hosts.yml playbooks/40-centreon-hosts.yml -K --ask-vault-pass -e centreon_hosts_force_update_snmp_macros=true
```

---

## 10. Quand le déploiement s'arrête

Le dépôt s'arrête volontairement plutôt que de casser quelque chose, ou parce
qu'un contrôle a échoué. Chaque message dit quoi faire ; voici la raison
derrière.

**« /etc/snmp/snmpd.conf a été modifié et n'a pas été écrit par ce rôle ».** La
machine est probablement déjà supervisée par un autre outil. Écraser ce fichier
ferait tomber cette supervision en aveugle, sans alerte. Reportez la
configuration existante dans les variables du rôle, ou, après avoir vérifié
qu'elle ne sert plus, relancez avec `-e snmp_agent_replace_foreign_config=true`.

**« La communauté SNMP v2c est trop faible ».** Voir §4.2.

**« Le serveur central exige une distribution Enterprise Linux 8 ou 9 ».** La
machine visée n'est pas une plateforme sur laquelle Centreon s'installe. Voir
§6.

**« fait déjà tourner httpd, mariadb… ».** La machine n'est pas dédiée au
central. Voir §6.

**« La description … contient un caractère refusé par le moteur ».** Le moteur
de supervision interdit `~!$%^&*"|'<>?,()=` dans un nom d'objet. Une apostrophe
dans la description d'un service suffit à rendre toute la configuration
ingénérable, sur l'ensemble des hôtes. Le contrôle a lieu avant le premier
appel à Centreon, pour nommer le service fautif : sans lui, l'erreur
n'apparaîtrait qu'à la génération, sous la forme d'une « erreur de cohérence »
sans détail. Changez la description dans `centreon_hosts_services`, et notez
l'ancienne dans `anciennes_descriptions` pour que les services déjà créés sur
les hôtes soient renommés plutôt que dupliqués.

### Les diagnostics à disposition

Cinq playbooks relèvent l'état de la plateforme sans rien modifier. Ils
existent parce que les messages de Centreon désignent rarement la vraie cause :
l'interface de programmation répond « erreur de cohérence dans les fichiers
exportés » aussi bien quand aucun fichier n'a été produit que lorsqu'un nom de
service est refusé, et il lui arrive de renvoyer un message vide.

| Commande | Ce qu'elle relève |
|----------|-------------------|
| `make diag-base` | Comptes, tables et accès de la base de données |
| `make diag-installeur` | Étape et état de l'assistant d'installation web |
| `make diag-connexion` | Connexion à l'interface et à son API |
| `make diag-generation` | Échec de génération : fichiers produits, et ce que le moteur reproche |
| `make diag-agent LIMIT=<hôte>` | Configuration SNMP en place, communautés et phrases secrètes masquées |

`make diag-generation` est le plus utile des cinq. Il liste ce que la
génération a réellement écrit, puis relance la validation du moteur sur une
copie de ces fichiers. La copie compte : la configuration produite désigne ses
inclusions par leur emplacement final, où rien n'est déployé tant que la
génération n'a pas abouti, et la valider telle quelle ferait accuser un fichier
absent qui n'a rien à voir avec la panne.

`make diag-agent` sert avant de forcer l'écrasement d'un `snmpd.conf` existant.
Il montre les directives en place, et répond aux trois questions qui décident :
cette machine envoie-t-elle ses alertes vers un autre collecteur, un accès en
écriture par SNMP est-il ouvert, la configuration porte-t-elle la marque de ce
rôle. Les valeurs sensibles ne sont jamais affichées.

---

## 10 ter. Retirer un serveur de la supervision

```bash
make retirer-agent LIMIT=<hôte> OPTS="-e snmp_agent_confirmer_retrait=true"
```

Remet l'hôte dans l'état où il était : agent arrêté et désactivé,
configuration SNMP antérieure restaurée depuis la sauvegarde que le rôle avait
prise, utilisateur v3 retiré du fichier persistant, autorisations de pare-feu
supprimées. Le playbook vérifie ensuite que plus rien n'écoute sur le port
SNMP.

Deux garde-fous l'encadrent : il refuse de porter sur tout le parc, et exige
une confirmation explicite après avoir dit ce qu'elle entraîne. Les paquets ne
sont pas désinstallés, et l'hôte reste déclaré dans Centreon, la suppression
d'un hôte emportant son historique de métriques.

La procédure détaillée, avec les vérifications à faire avant, est dans
`docs/ajouter-un-serveur.md`.

---

## 11. Ce que ce dépôt ne fait pas

**Il n'envoie pas de traps.** Seule l'interrogation périodique est en place,
pas la remontée d'événements.

**Il ne gère pas IPv6.** L'écoute et les règles de pare-feu sont en IPv4.

**La vue SNMP ne couvre pas la branche TCP.** Les six services du catalogue,
processeur, charge, mémoire, espace de pagination, systèmes de fichiers et
temps de fonctionnement, n'en ont pas besoin et fonctionnent. Un service qui
interrogerait les connexions TCP échouerait : il faudrait alors ajouter
`.1.3.6.1.2.1.6` à `snmp_agent_view_oids`.

**Les cinq points de mise en production sont traités, chacun avec sa
réserve.** HTTPS, mais certificat auto-signé à défaut de mieux. SELinux en
`enforcing`, avec retour automatique en `permissive` si quelque chose casse.
Sauvegarde nocturne vérifiée, mais qui reste sur la machine. Surveillance
extérieure du central, dont l'alerte n'atteint personne tant qu'aucune
commande d'alerte n'est renseignée. Procédure de montée de version écrite,
dont l'assistant de migration reste manuel. Le détail est dans le README et
dans `docs/montee-de-version.md`.
