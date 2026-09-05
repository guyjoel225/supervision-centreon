# Supervision Centreon

Déploiement automatisé d'une plateforme de supervision Centreon sur un parc
mixte Ubuntu et Rocky Linux, entièrement pilotée par Ansible.

Le projet couvre l'installation du serveur central, la configuration des agents
SNMP v3 sur les hôtes supervisés, la déclaration de ces hôtes dans Centreon, et
la vérification de la chaîne de bout en bout.

---

## Une contrainte à connaître avant de commencer

**Centreon ne s'installe pas sur Ubuntu.** Les seules plateformes supportées
pour un serveur central ou un collecteur sont Alma, RHEL et Oracle Linux 8 et 9,
ainsi que Debian 12, en x86_64. Il n'existe pas de dépôt Centreon pour Ubuntu.

Le rôle `centreon_central` refuse donc explicitement de s'exécuter ailleurs que
sur une distribution Enterprise Linux, plutôt que d'échouer à mi-parcours sur
une erreur de dépôt introuvable.

Cette contrainte n'affecte que le serveur central. Les hôtes supervisés ne
reçoivent aucun paquet Centreon : ils exposent simplement un agent SNMP, ce qui
fonctionne identiquement sous Ubuntu et sous Rocky.

---

## Topologie

Exemple de topologie, à adapter au parc réel.

| Inventaire | Adresse | Système | Ressources | Rôle |
|---|---|---|---|---|
| `ctrl-ansible` | 10.0.0.10 | Ubuntu 24.04 | 2 Go, 2 vCPU | Contrôleur Ansible, supervisé |
| `srv-central-01` | 10.0.0.25 | Rocky | 4 Go, 2 vCPU | Serveur central Centreon, supervisé |
| `srv-ubuntu-02` | 10.0.0.32 | Ubuntu 24.04 | 1,5 Go, 2 vCPU | Supervisé |
| `srv-rocky-01` | 10.0.0.41 | Rocky | 1,7 Go, 2 vCPU | Supervisé |
| `srv-ubuntu-01` | 10.0.0.31 | Ubuntu 24.04 | 1,5 Go, 2 vCPU | Supervisé |

Le contrôleur Ansible et le serveur central sont deux machines distinctes. Cette
séparation est imposée par la contrainte ci-dessus : le contrôleur Ansible est
une machine Ubuntu, sur laquelle Centreon ne peut pas s'installer.

Centreon demande 4 vCPU et 4 Go de mémoire pour une plateforme allant jusqu'à
500 hôtes. La machine qui porte le central doit donc être dimensionnée en
conséquence, et lui être dédiée.

Les flux :

```
  ctrl-ansible  ──SSH──▶  toutes les machines        configuration
  srv-central-01     ──SNMPv3 (udp/161)──▶  hôtes         collecte
  navigateur         ──HTTP (tcp/80)──▶  srv-central-01   consultation
```

---

## Démarrage rapide

Pour savoir quoi lancer selon votre situation, lisez
[docs/guide-utilisation.md](docs/guide-utilisation.md).

```bash
git clone <ce-dépôt> && cd supervision-centreon
make deps
```

Renseigner l'inventaire :

```bash
$EDITOR inventories/lab/hosts.yml
$EDITOR inventories/lab/group_vars/all/main.yml
```

Créer le coffre à secrets :

```bash
cp inventories/lab/group_vars/all/vault.yml.example inventories/lab/group_vars/all/vault.yml
$EDITOR inventories/lab/group_vars/all/vault.yml
ansible-vault encrypt inventories/lab/group_vars/all/vault.yml
```

Contrôler, puis déployer :

```bash
make lint
make check
make deploy
make verify
```

---

## Structure

```
.
├── ansible.cfg                  Configuration Ansible du projet
├── requirements.yml             Collections nécessaires
├── Makefile                     Raccourcis d'exploitation
│
├── inventories/
│   ├── lab/                     Inventaire du laboratoire
│   │   ├── hosts.yml            Machines et appartenance aux groupes
│   │   ├── group_vars/
│   │   │   ├── all/             Variables partagées, coffre à secrets
│   │   │   ├── centreon_central.yml
│   │   │   └── monitored.yml
│   │   └── host_vars/           Surcharges par machine
│   └── production/              Même structure, à remplir
│
├── playbooks/
│   ├── site.yml                 Déploiement complet, dans l'ordre
│   ├── 10-common.yml            Prérequis système
│   ├── 20-central.yml           Serveur central Centreon
│   ├── 30-snmp-agents.yml       Agents SNMP v3
│   ├── 40-centreon-hosts.yml    Déclaration des hôtes dans Centreon
│   ├── snmp-v3.yml              Agents en SNMP v3, authentifié et chiffré
│   ├── snmp-v2c.yml             Agents en SNMP v2c, communauté en clair
│   ├── snmp-only.yml            Agents selon l'inventaire, permet la cohabitation
│   ├── 98-verify-snmp-agents.yml  Vérifie les agents sans central
│   └── 99-verify.yml            Vérification complète, ne modifie rien
│
├── roles/
│   ├── common/                  Horloge, résolution de noms, paquets de base
│   ├── snmp_agent/              Agent SNMP v3 en lecture seule
│   ├── centreon_central/        Installation complète du central
│   └── centreon_hosts/          Déclaration des hôtes via l'API Centreon
│
└── docs/
    ├── guide-utilisation.md     Quoi lancer, quand, et ce qui se passe
    ├── architecture.md          Choix de conception et leurs raisons
    ├── exploitation.md          Coffre, exécution, rotation, dépannage
    └── variables.md             Catalogue des variables par rôle
```

---

## Ce que fait le déploiement

L'ordre des étapes n'est pas arbitraire : chacune produit ce dont la suivante a
besoin.

1. **Prérequis système** sur toutes les machines. L'horloge est synchronisée en
   premier : un décalage fausse les graphiques et les fenêtres de notification.
2. **Serveur central**. Dépôts, PHP, MariaDB, paquets Centreon, base durcie,
   puis l'assistant d'installation web déroulé automatiquement en HTTP.
3. **Agents SNMP**, y compris sur le central lui-même. Ce passage vient après
   l'installation du central, dont les paquets tirent net-snmp : le rôle doit
   avoir le dernier mot sur `/etc/snmp/snmpd.conf`.
4. **Déclaration des hôtes** dans Centreon, avec leurs groupes et leurs macros
   SNMP v3, puis export de la configuration vers le collecteur.
5. **Vérification**, qui interroge réellement chaque hôte en SNMP v3 depuis le
   central et exécute le plugin de supervision.

---

## Superviser depuis un central Centreon déjà en service

Si le central existe déjà, rien n'est à installer sur lui et le rôle
`centreon_central` ne doit jamais être joué.

```bash
make snmp-v3     # si le central sait interroger en v3
make snmp-v2c    # si le central n'accepte que la v2c
```

Ces deux points d'entrée ne jouent que le rôle `snmp_agent` puis vérifient la
collecte. Ils ne changent ni le fuseau horaire, ni la synchronisation de
l'heure, ni `/etc/hosts` : ce sont les seuls conçus pour tourner sur des
serveurs en production.

Un troisième, `make snmp-only`, suit ce que déclare l'inventaire au lieu de
forcer une version. C'est le seul qui permet d'activer les deux à la fois, ce
qui est nécessaire pour migrer de la v2c vers la v3 sans trou de supervision :
le central continue d'interroger en v2c pendant que la v3 est éprouvée, et
l'ancien accès n'est fermé qu'une fois la bascule faite.

La v2c fait circuler la communauté en clair, sans authentification ni
chiffrement. Seules la restriction aux adresses déclarées et le pare-feu la
protègent.

Deux réglages conditionnent son résultat. `centreon_central_address` doit porter
l'adresse réelle du central, c'est elle qui autorise l'interrogation et ouvre le
pare-feu. Et les passphrases SNMP v3 du coffre doivent être celles que le
central utilise déjà : ce sont ses macros qui font foi.

---

## Déployer sans serveur central

Le central Centreon exige un système que l'on n'a pas toujours sous la main. Rien
n'oblige pour autant à attendre : les agents SNMP ne dépendent pas de lui.

```bash
make deploy LIMIT=monitored     # prérequis système et agents SNMP
make verify-agents              # le contrôleur interroge les agents à la place du central
```

`98-verify-snmp-agents.yml` fait jouer au contrôleur Ansible le rôle
d'interrogateur. Il prouve que l'utilisateur SNMP v3 est créé, que l'agent
répond en authentifié et chiffré, et que sa vue couvre bien les compteurs que
consommeront les plugins Linux de Centreon. Il ne remplace pas `99-verify.yml`,
qui reste la vérification de référence une fois le central en service.

---

## Passer en production

Ce dépôt sait faire des choses qui n'ont pas leur place sur un serveur en
service. Trois garde-fous encadrent ce risque.

**L'inventaire `production` neutralise ce qui ne relève pas de la
supervision.** Fuseau horaire, synchronisation de l'heure et `/etc/hosts` y
sont désactivés explicitement, avec la raison écrite à côté de chaque
interrupteur. Un lancement de `site.yml` par inadvertance reste ainsi sans
effet destructeur.

**Une configuration SNMP appartenant à un tiers n'est jamais écrasée.** Avant
de déposer son fichier, le rôle demande au gestionnaire de paquets si
`/etc/snmp/snmpd.conf` a divergé de la version livrée. Si oui, et qu'il ne
porte pas notre marqueur, le déploiement s'arrête : la machine est
probablement déjà supervisée, et l'écraser ferait tomber cette supervision en
aveugle. Forcer le passage demande `snmp_agent_replace_foreign_config=true`,
en connaissance de cause.

**Le déploiement se fait par vagues.** La première ne traite qu'une machine
témoin, les suivantes le parc par quarts, et toute défaillance arrête tout.
Une régression est ainsi constatée sur un hôte, pas sur cent.

**Les cinq points qui séparaient cette plateforme d'une véritable mise en
production sont désormais traités par le dépôt**, chacun avec sa réserve, qui
est écrite plutôt que passée sous silence.

L'interface est servie en HTTPS, le trafic en clair étant redirigé, ce qui est
vérifié sur la plateforme réelle. Le rôle reprend le corps de l'hôte virtuel
que Centreon déclare sur le port 80 plutôt que de le réécrire, faute de quoi
le canal chiffré répondrait par une erreur 404. Réserve : sans certificat
fourni par l'exploitant, celui produit est auto-signé, et chiffre le transport
sans authentifier le serveur. Fournir le certificat de l'entreprise lève cette
réserve et active la validation à tous les appels : la procédure est dans
[docs/exploitation.md](docs/exploitation.md).

SELinux passe en `enforcing` une fois la plateforme en marche, politiques
Centreon installées et booléens posés. Vérifié sur la plateforme réelle :
aucun accès refusé pendant les soixante secondes d'observation. Réserve : si des accès sont refusés ou
si l'interface cesse de répondre, le rôle revient en `permissive` et le dit.
Une supervision aveugle est un incident plus grave qu'une politique non
appliquée.

La base et les fichiers de configuration sont sauvegardés chaque nuit, avec
vérification des empreintes, rétention et exécution immédiate lors du
déploiement. Réserve : les archives restent sur la machine. Elles protègent
d'une erreur logique ou d'une migration ratée, pas de la perte du serveur.

La plateforme se supervise elle-même, et une surveillance extérieure posée sur
le contrôleur Ansible détecte son arrêt, ce qu'elle seule peut faire. Réserve :
tant que `supervision_watchdog_alert_command` n'est pas renseignée, l'alerte
s'écrit dans un journal, ce qui ne réveille personne.

Une procédure de montée de version est écrite et outillée, sauvegarde
préalable obligatoire et retour arrière documenté, dans
`docs/montee-de-version.md`. Réserve : l'assistant de migration de la base
reste manuel, délibérément.

---

## Diagnostiquer

Cinq playbooks relèvent l'état de la plateforme sans rien modifier. Ils
existent parce que Centreon désigne rarement la vraie cause d'une panne :
la même « erreur de cohérence dans les fichiers exportés » répond aussi bien
quand aucun fichier n'a été produit que lorsqu'un nom de service est refusé,
et le message est parfois vide.

```bash
make diag-base          # comptes, tables et accès de la base
make diag-installeur    # étape et état de l'assistant d'installation
make diag-connexion     # connexion à l'interface et à son API
make diag-generation    # fichiers produits, et ce que le moteur reproche
make diag-agent LIMIT=<hôte>   # configuration SNMP en place, secrets masqués
```

`make diag-agent` sert avant de forcer l'écrasement d'un `snmpd.conf`
existant : il montre les directives en place sans jamais afficher une
communauté ni une phrase secrète, et dit si la machine envoie ses alertes
ailleurs ou expose un accès en écriture.

## Retirer un serveur de la supervision

```bash
make retirer-agent LIMIT=<hôte> OPTS="-e snmp_agent_confirmer_retrait=true"
```

Arrête l'agent, restaure la configuration SNMP antérieure si le rôle en avait
sauvegardé une, retire l'utilisateur v3 et les autorisations de pare-feu
posées, puis vérifie que plus rien n'écoute. Une limite et une confirmation
explicite sont exigées : une désupervision se fait machine par machine, jamais
sur une faute de frappe.

Les paquets ne sont pas désinstallés par défaut, et l'hôte reste déclaré dans
Centreon : le supprimer effacerait son historique de métriques, ce qui ne se
décide pas depuis une ligne de commande.

## Documentation

| Document | Ce qu'il couvre |
|----------|-----------------|
| [docs/guide-utilisation.md](docs/guide-utilisation.md) | Quel playbook pour quel besoin, quatre scénarios complets |
| [docs/ajouter-un-serveur.md](docs/ajouter-un-serveur.md) | Raccorder un serveur en service, sans l'interrompre, y compris à un central existant en v2c |
| [docs/catalogue-supervision.md](docs/catalogue-supervision.md) | Tout ce que le plugin sait mesurer, la branche SNMP que chaque mode exige, et comment ajouter un contrôle |
| [docs/montee-de-version.md](docs/montee-de-version.md) | Monter le central de version, et revenir en arrière |
| [docs/exploitation.md](docs/exploitation.md) | Opérations courantes et dépannage |
| [docs/architecture.md](docs/architecture.md) | Ce que fait chaque rôle et pourquoi |
| [docs/variables.md](docs/variables.md) | Les variables et leur effet |

## Ce qui reste à votre charge

Trois réserves subsistent après le déploiement. Elles ne sont pas des oublis :
chacune demande une décision ou un accès qui n'appartient pas à ce dépôt. La
marche à suivre pour chacune est dans
[docs/exploitation.md](docs/exploitation.md), section « Lever les réserves qui
subsistent ».

**Faire en sorte que la surveillance alerte réellement.** Elle détecte l'arrêt
du central, mais écrit dans un journal tant que sa commande d'alerte n'est pas
renseignée. C'est la plus urgente des trois, et elle ne demande qu'une ligne.

**Recopier les sauvegardes hors du serveur.** Elles protègent d'une erreur
logique ou d'une migration ratée, pas de la perte de la machine. Et une
sauvegarde jamais restaurée n'est pas encore une sauvegarde.

**Déclarer un contact dans Centreon.** Aucun n'est créé par ces rôles : un
service peut passer en critique sans que personne en soit informé. Les
destinataires, les plages d'astreinte et les seuils d'escalade relèvent de
l'organisation qui exploite la plateforme.

## Nature de la validation

`ansible-lint` au profil `production` passe sans avertissement, le contrôle
syntaxique des playbooks passe, et un script vérifie qu'aucun playbook
n'emploie une variable d'un rôle qu'il ne charge pas.

Au-delà de ces contrôles, **le déploiement a été exécuté de bout en bout sur
six machines réelles**, quatre sous Ubuntu et deux sous Rocky Linux 9 et 10,
avec un serveur central installé depuis zéro par le rôle. Le résultat, relevé
dans l'interface de Centreon : six hôtes et **trente-six services au vert**,
alimentés par des mesures réelles en SNMP v3 authentifié et chiffré, chaque
machine remontant sa mémoire, son processeur, sa charge, ses systèmes de
fichiers, son espace de pagination et son temps de fonctionnement.

La sixième est un serveur de production extérieur au laboratoire, raccordé
sans que son fuseau horaire, sa synchronisation d'horloge, sa résolution de
noms ni son pare-feu ne soient touchés. L'ajout n'a interrompu aucun des
services déjà collectés.

Ce que cette exécution a coûté est resté dans le dépôt sous forme de
garde-fous et de diagnostics : un fichier de secrets que Centreon ne remplit
pas lors d'une installation neuve, une apostrophe dans un nom de service qui
rendait toute la configuration ingénérable, et une vérification qui cherchait
une ligne dans un fichier là où seule une requête aboutie prouve qu'un agent
répond.
