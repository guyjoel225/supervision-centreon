# Ajouter un serveur à la supervision

Procédure complète pour mettre un serveur en service sous supervision, sans
rien casser de ce qui y tourne déjà. Elle vaut pour une machine du parc comme
pour un serveur extérieur au laboratoire.

Le principe qui gouverne tout ce document : **un serveur en production ne se
modifie que là où c'est nécessaire à la supervision.** Fuseau horaire,
synchronisation d'horloge, résolution de noms et paquets appartiennent à son
exploitant. La supervision y dépose un agent SNMP en lecture seule, et rien
d'autre.

---

## 1. Ce qu'il faut avant de commencer

Trois choses, à vérifier plutôt qu'à supposer.

**Le contrôleur Ansible doit joindre le serveur en SSH, sans mot de passe.**
Depuis le contrôleur :

```bash
ssh -o BatchMode=yes <compte>@<adresse> 'hostname; . /etc/os-release; echo $PRETTY_NAME'
```

Si la connexion est refusée, la clé publique du contrôleur n'est pas autorisée
sur le serveur. Ajoutez-la dans le fichier `~/.ssh/authorized_keys` du compte
visé, sur le serveur.

**Ce compte doit pouvoir devenir root.** Toujours depuis le contrôleur :

```bash
ssh <compte>@<adresse> 'sudo -n true && echo "sudo sans mot de passe" || echo "mot de passe demandé"'
```

Si un mot de passe est demandé, il devra être fourni au lancement, et c'est
alors le même pour tous les hôtes de l'exécution. Quand le compte diffère d'une
machine à l'autre, le plus simple est de configurer `sudo` sans mot de passe
pour ce compte, ou de ranger son mot de passe dans le coffre sous
`ansible_become_password`.

**Le serveur ne doit pas être déjà supervisé par un autre outil.** Un agent
SNMP existant signifie souvent qu'une autre supervision l'interroge, et
l'écraser la rendrait aveugle sans alerte :

```bash
make diag-agent LIMIT=<nom-dans-l-inventaire>
```

Ce relevé montre les directives en place sans jamais afficher une communauté ni
une phrase secrète. Trois réponses décident : la machine envoie-t-elle ses
alertes ailleurs, un accès en écriture par SNMP est-il ouvert, la configuration
porte-t-elle la marque de ce rôle.

---

## 1 bis. Établir ce que le déploiement va réellement modifier

Sur un serveur en service, la question n'est pas seulement « est-ce que je vais
détruire quelque chose », mais « est-ce que je vais interrompre quelque chose,
même une minute ». Ces vérifications se font avant, pas après.

**Quels services tournent, et lesquels le rôle touche-t-il ?**

```bash
ss -lntup
```

Le rôle n'installe que `net-snmp` et ne démarre que `snmpd`, sur le port 161.
Il ne redémarre aucun autre service. Si le port 161 est déjà pris, c'est qu'un
agent existe : reportez-vous au garde-fou plus haut.

**Le service d'horloge risque-t-il d'être remplacé ?**

```bash
systemctl is-active systemd-timesyncd chrony
```

Si `systemd-timesyncd` est actif, installer chrony le remplacerait et
interromprait la synchronisation. C'est la raison de `common_ntp_enabled: false`
sur un serveur qui n'appartient pas au laboratoire.

**Le pare-feu risque-t-il d'être activé ?**

```bash
sudo ufw status
sudo systemctl is-active firewalld
```

Le rôle n'agit que sur un pare-feu **déjà actif** : il ajoute une autorisation,
il n'en active jamais un qui ne l'était pas. Activer un pare-feu inactif
couperait les connexions établies, y compris la session qui déploie. Si votre
pare-feu est inactif et que vous voulez qu'il protège l'agent, activez-le
vous-même, hors de cette procédure et en connaissance de cause.

**Les paquets de base sont-ils déjà là ?**

```bash
dpkg -s curl ca-certificates python3-apt 2>/dev/null | grep -c "install ok installed"
```

S'ils le sont, aucune installation n'aura lieu. S'ils manquent, leur
installation ne reconfigure aucun service existant.

Au terme de ces quatre vérifications, vous savez exactement ce qui changera.
Sur un serveur déjà pourvu de ses paquets de base, sans agent SNMP et sans
pare-feu actif, le déploiement se réduit à l'ajout d'un service qui n'existait
pas, et rien de ce qui tourne n'est arrêté ni rechargé.

---

## 2. Déclarer le serveur dans l'inventaire

Ouvrez `inventories/<votre-inventaire>/hosts.yml` et ajoutez l'hôte dans le
groupe correspondant à sa famille de distribution, `monitored_debian_family`
pour Debian et Ubuntu, `monitored_rhel_family` pour Alma, Rocky et RHEL.

```yaml
            mon-serveur:
              ansible_host: 10.0.0.50
              centreon_host_alias: Serveur applicatif de production
              centreon_host_groups: [Linux-Servers]
```

Le nom à gauche est celui qui apparaîtra dans Centreon. Il ne doit contenir
aucun des caractères que le moteur refuse dans un nom d'objet,
`~!$%^&*"|'<>?,()=`, apostrophe comprise.

**Si le compte de connexion diffère** de celui du reste du parc, précisez-le
sur l'hôte, il l'emporte sur la valeur globale :

```yaml
              ansible_user: joel
```

**Si le serveur n'appartient pas au laboratoire**, neutralisez ce qui ne relève
pas de la supervision. Sans ces trois lignes, le déploiement remplacerait son
service d'horloge par chrony, poserait le fuseau horaire du parc et réécrirait
sa résolution de noms :

```yaml
              common_manage_timezone: false
              common_ntp_enabled: false
              common_manage_hosts_file: false
```

Restent installés `curl`, `ca-certificates` et, sur Debian et Ubuntu,
`python3-apt`, ce dernier étant nécessaire à Ansible lui-même.

**Si le serveur doit être interrogé en SNMP v2c** parce qu'un central existant
l'impose, ajoutez-le au groupe `snmp_v2c` plutôt qu'à `snmp_v3`, et renseignez
sa communauté dans le coffre. La v2c transporte cette communauté en clair : la
seule protection réelle est alors la restriction par adresse source, que le
rôle applique.

Vérifiez que l'inventaire reste lisible :

```bash
ansible-inventory -i inventories/<votre-inventaire>/hosts.yml --host mon-serveur
```

---

## 3. Déposer l'agent SNMP

Ne déployez d'abord que sur ce serveur, jamais sur tout le parc :

```bash
make agents LIMIT=mon-serveur
```

Le rôle installe `net-snmp`, crée l'utilisateur SNMP v3, restreint sa vue aux
sept branches que consomment les plugins Linux, ouvre le port 161 pour la
seule adresse du serveur central, et démarre le service. Il prouve ensuite que
l'agent répond, par une requête réelle et non par la lecture d'un fichier.

**Si le déploiement s'arrête** en disant que `/etc/snmp/snmpd.conf` a été
modifié et n'a pas été écrit par ce rôle, c'est le garde-fou. Ne le contournez
pas sans avoir regardé ce qu'il protège, avec `make diag-agent`. Une fois
certain que la configuration en place ne sert plus :

```bash
make agents LIMIT=mon-serveur OPTS="-e snmp_agent_replace_foreign_config=true"
```

Une sauvegarde horodatée du fichier remplacé est conservée à côté de
l'original, dans tous les cas.

---

## 4. Déclarer le serveur dans Centreon

```bash
make declare
```

Cette commande crée l'hôte, lui applique le modèle et ses six services, pose
les macros SNMP, puis génère et recharge la configuration du collecteur.

Elle traite tous les hôtes de l'inventaire, ce qui est sans danger : elle ne
recrée pas ce qui existe déjà.

---

## 5. Prouver que la collecte fonctionne

```bash
make verify
```

Cette vérification interroge les agents **depuis le serveur central**, seul
point de vue qui prouve quelque chose : le contrôleur Ansible peut être
autorisé là où le central ne l'est pas, et vérifier depuis le contrôleur donne
un faux sentiment de succès.

Les services mettront un cycle de contrôle à passer de `Pending` à leur état
réel, quelques minutes. Un service n'est pas sain parce qu'il vient de
démarrer.

---

## 6. Quand la collecte ne part pas

Le symptôme le plus courant est un `SNMP GET Request: Timeout` sur tous les
services du nouvel hôte. Trois causes, dans l'ordre où il faut les écarter.

**L'agent ne tourne pas.** Sur le serveur : `systemctl is-active snmpd`.

**Le pare-feu du serveur ne laisse pas passer le central.** Le rôle ouvre le
port pour les adresses déclarées dans `snmp_agent_allowed_managers`, qui
pointe par défaut sur l'adresse du central. Si le central a changé d'adresse,
cette variable désigne encore l'ancienne, et les paquets sont filtrés sans
qu'aucun journal ne le dise.

**Les identifiants SNMP diffèrent** entre l'agent et ce que Centreon envoie.
Les macros posées sur l'hôte doivent correspondre à l'utilisateur créé sur
l'agent.

Une sonde utile, depuis le serveur central, avec un utilisateur volontairement
inexistant :

```bash
snmpget -v3 -u utilisateur-inexistant -l noAuthNoPriv -t 3 -r 0 <adresse> 1.3.6.1.2.1.1.5.0
```

Une réponse « Unknown user name » prouve que le paquet atteint l'agent, donc
que le réseau et le pare-feu sont hors de cause. Un dépassement de délai ne
prouve rien à lui seul : un agent configuré en `authPriv` strict peut ne rien
renvoyer du tout à une requête non authentifiée. Cette sonde écarte une cause,
elle n'en désigne aucune.

---

## 7 bis. Cas d'un central existant qui interroge en SNMP v2c

C'est le cas le plus fréquent en entreprise : la supervision existe déjà, elle
appartient à une autre équipe, et elle interroge en v2c avec une communauté en
service depuis des années. Vous n'avez la main que sur les serveurs à
raccorder.

**Ce que vous ne devez surtout pas faire :** lancer `make deploy` ou
`site.yml`. Ces commandes installeraient un serveur central, alors qu'il en
existe déjà un. Le seul point d'entrée valable ici est celui qui ne touche
qu'aux agents.

### Ce qu'il faut obtenir de l'équipe du central

Trois informations, et aucune ne se devine.

L'**adresse du serveur central**, celle depuis laquelle il interrogera vos
serveurs. C'est elle, et elle seule, que le pare-feu autorisera.

La **communauté** en vigueur. Elle doit être identique à celle que le central
émet, sans quoi vos agents refuseront ses requêtes sans rien journaliser
d'exploitable.

La **confirmation qu'ils déclareront vos hôtes** de leur côté. Ce dépôt pose
les agents ; la déclaration dans leur Centreon leur revient, sauf s'ils vous
donnent un compte d'accès à leur interface de programmation.

### Déclarer ces serveurs

Dans `inventories/production/group_vars/all/main.yml` :

```yaml
# Adresse du central existant, seule autorisée à interroger les agents.
centreon_central_address: 10.20.0.5

# La v2c transporte la communauté en clair sur le réseau. La restriction par
# adresse source est donc la seule protection réelle, et non un supplément.
snmp_agent_allowed_managers:
  - "{{ centreon_central_address }}"
```

Dans le coffre, jamais en clair :

```yaml
vault_snmp_agent_v2c_community: "<COMMUNAUTE_FOURNIE_PAR_L_EQUIPE_CENTRALE>"
```

Puis les serveurs eux-mêmes, dans `hosts.yml`, avec les précautions de la
section 2 : compte de connexion s'il diffère, et neutralisation de ce qui ne
relève pas de la supervision.

### Poser les agents

```bash
make snmp-v2c LIMIT=mon-serveur
```

Ce point d'entrée bascule le rôle en v2c, désactive la v3, et ne touche à
aucun serveur central. Il enchaîne sur une vérification depuis le contrôleur
Ansible.

**Si le déploiement refuse la communauté**, c'est le garde-fou : le rôle
n'accepte pas une communauté de moins de huit caractères. Les communautés
héritées valent souvent `public` ou `private`, qui sont les valeurs par défaut
de tous les agents du monde. Si l'équipe du central ne peut pas la changer,
passez outre en connaissance de cause :

```bash
make snmp-v2c LIMIT=mon-serveur OPTS="-e snmp_agent_v2c_accept_weak_community=true"
```

Le rôle acceptera, en le disant. Ce n'est pas anodin : quiconque atteint le
réseau de ces serveurs peut alors lire l'intégralité de leur vue SNMP.

### Vérifier, sans accès au central

La vérification de référence interroge les agents depuis le serveur central,
ce que vous ne pouvez pas faire ici. Le playbook de repli fait jouer ce rôle
au contrôleur Ansible :

```bash
make verify-agents LIMIT=mon-serveur
```

Attention à ce qu'il prouve exactement : que l'agent répond **au contrôleur**.
Si le contrôleur est autorisé et que le central ne l'est pas, la vérification
réussit et la collecte échouera quand même. Demandez à l'équipe du central de
confirmer de son côté, ou faites-vous ouvrir un accès pour tester depuis leur
machine. C'est la seule preuve qui vaille.

### Passer plus tard de la v2c à la v3

Le dépôt sait faire cohabiter les deux versions sur un même parc : le
scénario C du guide d'utilisation décrit la migration, agent par agent, sans
interruption de la collecte.

---

## 7. Ce que cette procédure laisse à votre charge

La supervision détecte, elle n'avertit pas. Aucun contact n'est déclaré dans
Centreon par ces rôles : un service peut passer en critique sans que personne
en soit informé. La seule alerte du dispositif est la surveillance extérieure
du central, et elle-même n'écrit que dans un journal tant que
`supervision_watchdog_alert_command` n'est pas renseignée avec ce qui atteint
réellement l'astreinte.
