# Procédure : déployer les agents vers un central existant en v2c

Procédure d'intervention, à suivre dans l'ordre, pour raccorder des serveurs en
production à un serveur central Centreon déjà en service qui interroge en
SNMP v2c.

Le partage des rôles gouverne tout ce document : **vous posez les agents, le
central ne change pas.** Il interroge déjà des machines, il en interrogera
quelques-unes de plus. Rien de ce dépôt ne doit toucher au central.

Ce qui explique le pourquoi de chaque étape est dans
[ajouter-un-serveur.md](ajouter-un-serveur.md) ; ce document-ci donne la
séquence et les points d'arrêt.

---

## Étape 0. Obtenir ce qui ne se devine pas

Quatre informations, auprès de l'équipe qui exploite le central. Ne commencez
pas sans elles : les deux premières, fausses, produisent une panne silencieuse
que rien ne journalise.

| Information | Pourquoi elle est indispensable |
|---|---|
| Adresse du central | C'est la seule que le pare-feu des agents autorisera |
| Communauté en vigueur | Elle doit être identique des deux côtés, sinon l'agent ignore les requêtes sans rien dire |
| Qui déclare les hôtes | Le central est à eux : soit ils déclarent, soit ils vous ouvrent un accès à leur interface de programmation |
| Modèles de services employés | Ils déterminent les branches SNMP que la vue doit exposer |

Sur le dernier point : leurs modèles n'interrogeront pas forcément les mêmes
branches que les nôtres. Un contrôle qui échoue alors que l'agent répond est
presque toujours une branche absente de la vue. Le rapprochement est dans
[catalogue-supervision.md](catalogue-supervision.md).

---

## Étape 1. Vérifier que les deux chemins réseau existent

Deux choses doivent être vraies, et **la seconde ne se déduit pas de la
première**. Elles empruntent des chemins différents, souvent des règles de
pare-feu différentes.

Depuis le contrôleur Ansible, vers chaque serveur, en SSH :

```bash
ssh -o BatchMode=yes <compte>@<serveur> 'hostname; sudo -n true && echo "sudo ok"'
```

Depuis le **central**, vers chaque serveur, en UDP sur le port 161. Demandez à
l'équipe de la lancer, ou faites-vous ouvrir un accès :

```bash
snmpget -v2c -c <communaute> -t 3 -r 0 <serveur> 1.3.6.1.2.1.1.5.0
```

Tant que l'agent n'est pas posé, cette commande échouera : c'est normal. Elle
sert de point de comparaison, et vous la relancerez à l'étape 5. Ce qui
importe ici est de savoir qui peut la lancer, et de l'avoir organisé avant.

---

## Étape 2. Préparer le contrôleur

Dans `inventories/production/group_vars/all/main.yml` :

```yaml
# Adresse du central existant, seule autorisée à interroger les agents.
centreon_central_address: <adresse du central>

# En v2c, la communauté circule en clair sur le réseau. La restriction par
# adresse source est donc la seule protection réelle, et non un supplément.
snmp_agent_allowed_managers:
  - "{{ centreon_central_address }}"
```

La communauté va dans le coffre, jamais dans un fichier en clair ni dans un
message :

```bash
ansible-vault edit inventories/production/group_vars/all/vault.yml
```

```yaml
vault_snmp_agent_v2c_community: "<COMMUNAUTE_FOURNIE_PAR_L_EQUIPE_CENTRALE>"
```

Reliez-la aux variables du rôle dans `secrets_mapping.yml` du même répertoire :

```yaml
snmp_agent_v2c_community: "{{ vault_snmp_agent_v2c_community }}"
```

Déclarez enfin les serveurs dans `inventories/production/hosts.yml`, dans le
groupe de leur famille de distribution. Pour chacun, trois lignes qui écartent
ce qui ne relève pas de la supervision :

```yaml
            srv-app-01:
              ansible_host: <adresse>
              centreon_host_alias: Serveur applicatif de production
              centreon_host_groups: [Linux-Servers]
              common_manage_timezone: false
              common_ntp_enabled: false
              common_manage_hosts_file: false
```

Sans ces trois lignes, le déploiement remplacerait le service d'horloge de la
machine par chrony, imposerait le fuseau du parc et réécrirait sa résolution de
noms. Rien de cela ne sert à la collecte.

Contrôlez que l'inventaire reste lisible :

```bash
ansible-inventory -i inventories/production/hosts.yml --host srv-app-01
```

---

## Étape 3. Établir ce qui va changer sur chaque serveur

À faire **avant** de déployer, serveur par serveur. Sur une machine en service,
la question n'est pas seulement « vais-je détruire quelque chose », mais
« vais-je interrompre quelque chose, même une minute ».

```bash
make diag-agent LIMIT=srv-app-01
```

Ce relevé montre les directives SNMP en place sans jamais afficher une
communauté. Trois réponses décident de la suite.

**La configuration porte-t-elle la marque de ce rôle ?** Si oui, la machine est
déjà gérée, il n'y a rien à faire. Si un agent existe sans cette marque, elle
est probablement supervisée par un autre outil : voir l'étape 4.

**Une destination de traps est-elle déclarée ?** La machine envoie alors ses
alertes ailleurs, et quelqu'un compte dessus.

**Un accès en écriture est-il ouvert ?** Un tiers peut modifier cette machine
par SNMP. Signalez-le, c'est un problème indépendant du vôtre.

Complétez par ce que le déploiement touchera :

```bash
ssh <compte>@<serveur> 'ss -lntup | grep ":161"; systemctl is-active systemd-timesyncd chrony; sudo ufw status 2>/dev/null | head -1'
```

Le port 161 doit être libre. Si `systemd-timesyncd` est actif, les trois lignes
de l'étape 2 le protègent. Si le pare-feu est inactif, le rôle ne l'activera
pas : l'activer couperait les connexions établies, y compris votre session.

---

## Étape 4. Déployer, un serveur d'abord

Simulez, pour voir ce qui changerait sans rien écrire :

```bash
make check LIMIT=srv-app-01
```

Puis déployez sur **un seul** serveur :

```bash
make snmp-v2c LIMIT=srv-app-01
```

Ce point d'entrée bascule le rôle en v2c, désactive la v3, et ne touche à aucun
serveur central.

**Deux arrêts possibles, et ils sont voulus.**

Si le rôle refuse d'écraser `/etc/snmp/snmpd.conf`, c'est qu'il ne l'a pas
écrit. Ne forcez qu'après avoir établi, à l'étape 3, que la configuration en
place ne sert plus :

```bash
make snmp-v2c LIMIT=srv-app-01 OPTS="-e snmp_agent_replace_foreign_config=true"
```

Une sauvegarde horodatée est conservée à côté du fichier dans tous les cas.

Si le rôle refuse la communauté, c'est qu'elle fait moins de huit caractères.
Les communautés héritées valent souvent `public` ou `private`, qui sont les
valeurs par défaut de tous les agents du monde. Si l'équipe ne peut pas la
changer :

```bash
make snmp-v2c LIMIT=srv-app-01 OPTS="-e snmp_agent_v2c_accept_weak_community=true"
```

Le rôle acceptera, en le disant. Quiconque atteint ce réseau pourra alors lire
l'intégralité de la vue SNMP de ces serveurs.

---

## Étape 5. Prouver la collecte, depuis le bon point de vue

C'est l'étape où l'on se trompe le plus souvent.

```bash
make verify-agents LIMIT=srv-app-01
```

Cette vérification prouve que l'agent répond **au contrôleur Ansible**. Elle ne
prouve rien sur le central : si le contrôleur est autorisé et que le central ne
l'est pas, elle réussit et la collecte échouera quand même.

**La seule preuve qui vaille** est la commande de l'étape 1, relancée depuis le
central, qui doit désormais répondre :

```bash
snmpget -v2c -c <communaute> -t 3 -r 0 <serveur> 1.3.6.1.2.1.1.5.0
```

Une réponse portant le nom du serveur clôt la question. Un dépassement de délai
signale un filtrage entre les deux réseaux, ou une adresse de central erronée
dans les gestionnaires autorisés.

Une fois ce serveur prouvé, déployez les suivants, par petits lots :

```bash
make snmp-v2c LIMIT=srv-app-02,srv-app-03
```

---

## Étape 6. Faire déclarer les hôtes dans le central

Cette étape ne vous appartient pas, sauf accès à leur interface de
programmation. Transmettez à l'équipe, pour chaque serveur : son nom, son
adresse, la version v2c, et le fait que la communauté est celle qu'ils ont
fournie.

Demandez-leur de confirmer, après export de leur configuration, que les
services remontent des valeurs et non des erreurs. Un service en `UNKNOWN` chez
eux alors que votre `snmpget` répond désigne presque toujours une branche SNMP
absente de la vue, exigée par leurs modèles de services et non par les nôtres.

---

## Si cela se passe mal

Le retour est prévu et ne demande pas d'improviser :

```bash
make retirer-agent LIMIT=srv-app-01 OPTS="-e snmp_agent_confirmer_retrait=true"
```

L'agent est arrêté et désactivé, la configuration SNMP antérieure restaurée
depuis la sauvegarde prise au déploiement, la communauté retirée, et les
autorisations de pare-feu supprimées. La machine revient à l'état où vous
l'avez trouvée.

---

## Fiche de relevé

À tenir pendant l'intervention, un serveur par ligne. Elle vous servira le jour
où un contrôle tombera sans raison apparente.

| Serveur | Agent préexistant | Pare-feu actif | Déployé le | `snmpget` depuis le central | Déclaré dans Centreon |
|---|---|---|---|---|---|
| | | | | | |
