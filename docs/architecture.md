# Architecture et choix de conception

Ce document explique pourquoi la plateforme est construite ainsi, et pas
autrement. Il complète le README, qui décrit ce que le projet fait.

---

## Pourquoi le central n'est pas sur le contrôleur Ansible

L'intention initiale était de faire du contrôleur Ansible le serveur central
Centreon, sur une même machine Ubuntu. Ce n'est pas réalisable : Centreon ne
publie de paquets que pour Alma, RHEL et Oracle Linux 8 et 9, et pour Debian 12.
Aucun dépôt Ubuntu n'existe.

Quatre issues étaient envisageables :

| Option | Ce qu'elle coûte |
|--------|------------------|
| Réinstaller le contrôleur sous Alma ou Rocky 9 | Refaire une machine, mais tout reste supporté |
| Faire tourner le central en conteneurs sur Ubuntu | Sort du chemin supporté, met à jour et sauvegarde à votre charge |
| **Séparer les deux rôles** | Abandonne la fusion, occupe une machine Rocky |
| Forcer les paquets Debian sur Ubuntu | Conflits PHP et MariaDB, aucun support, casse à la mise à jour |

C'est la troisième qui a été retenue. Le contrôleur Ansible reste sous Ubuntu,
le central Centreon occupe une machine Rocky. Les deux machines sont supervisées
comme les autres.

Le rôle `centreon_central` matérialise cette contrainte par une assertion en
tête de son exécution : sur une machine qui n'est pas de la famille Enterprise
Linux, il s'arrête immédiatement avec un message explicite, plutôt que de courir
jusqu'à une erreur de dépôt introuvable trente tâches plus loin.

---

## Pourquoi SNMP v3 et rien d'autre

Le protocole de collecte a été choisi parmi quatre candidats.

**SNMP v3** est retenu. Il est universel, ne demande aucun paquet Centreon sur
les hôtes supervisés, et ne pose donc aucun problème de compatibilité entre
Ubuntu et Rocky. Sa version 3 apporte l'authentification et le chiffrement, ce
que ni la v1 ni la v2c ne font : celles-ci transportent la communauté en clair.

Trois conséquences dans la configuration :

- Aucune directive `rocommunity` n'est écrite. Les versions 1 et 2c ne sont
  simplement pas configurées.
- L'utilisateur ne dispose que d'une vue restreinte aux branches consommées par
  les plugins Linux de Centreon, et non de l'arbre entier. C'est le principe du
  moindre privilège appliqué à la supervision.
- L'agent n'écoute que sur son adresse de service et sur la boucle locale, et le
  pare-feu ne laisse passer que le serveur central.

Les alternatives écartées : le Centreon Monitoring Agent, plus riche mais qui
imposerait un paquet Centreon sur chaque hôte ; NRPE, techniquement en fin de
cycle ; et l'exécution des plugins par SSH depuis le central, coûteuse en
ressources et lourde en gestion de clés.

---

## Pourquoi l'assistant d'installation est automatisé

Une installation de Centreon par paquets se termine normalement par un assistant
web en neuf écrans, qu'un opérateur parcourt à la souris. Cette étape manuelle
interdit tout redéploiement reproductible, et rend impossible la reconstruction
à l'identique de la plateforme.

Le rôle `centreon_central` rejoue donc cet assistant en HTTP, dans l'ordre
imposé par l'assistant lui-même. Les scripts appelés sont ceux de Centreon :

| Étape | Script | Ce qu'elle règle |
|-------|--------|------------------|
| 3 | `process_step3.php` | Chemins du moteur de supervision |
| 4 | `process_step4.php` | Chemins du broker |
| 5 | `process_step5.php` | Compte administrateur |
| 6 | `process_step6.php` | Connexion à la base de données |
| 7 | sept scripts successifs | Création et remplissage de la base |
| 8 | `process_step8.php` | Modules et widgets |
| 9 | `process_step9.php` | Clôture |

L'assistant tient par ailleurs un compteur d'étape dans `tmp/step.json`, et
chaque écran se charge par `steps/step.php`. Poster les scripts `process_stepN`
sans faire avancer ce compteur ne suffit pas : c'est le premier écran qui écrit
`tmp/configuration.json`, d'où `configFileSetup.php` tire les chemins
d'installation. Sans lui, ce script reçoit des valeurs nulles et tente d'écrire
à la racine du système. Le rôle suit donc le cheminement réel de l'assistant,
écran par écran, et non seulement ses scripts de traitement.

Chaque script répond un JSON dont le champ `result` vaut `0` en cas de succès,
et dont le champ `msg` porte l'erreur sinon. C'est ce contrat qui sert de
critère d'échec, plutôt qu'un simple code HTTP 200 qui ne prouverait rien.

Le répertoire de l'assistant est supprimé une fois l'installation confirmée :
laissé en place, il permet de réinitialiser la plateforme depuis un navigateur.

---

## Pourquoi une base de données retouchée avant l'assistant

L'assistant se connecte à MariaDB en tant que `root` avec un mot de passe. Or,
à l'installation, MariaDB authentifie `root` par socket Unix et refuse toute
authentification par mot de passe, ce qui fait échouer l'étape 6 avec une erreur
d'accès refusé.

Le rôle bascule donc `root` sur `mysql_native_password` avant de lancer
l'assistant. Il applique ensuite l'équivalent de `mariadb-secure-installation`
sous forme de tâches idempotentes : comptes anonymes retirés, connexion de
`root` depuis le réseau interdite, base de démonstration supprimée. La commande
interactive d'origine n'aurait pas été rejouable.

---

## Pourquoi la vérification est un playbook à part

Un playbook qui se termine sans erreur ne prouve pas que la supervision
fonctionne. Il prouve que les tâches se sont exécutées.

`playbooks/99-verify.yml` ne configure rien. Il produit une preuve pour chaque
maillon de la chaîne :

1. `snmpd` tourne et est activé au démarrage sur chaque hôte supervisé ;
2. l'agent écoute réellement sur l'adresse attendue ;
3. l'utilisateur SNMP v3 est enregistré dans le fichier persistant de net-snmp ;
4. le central obtient une réponse SNMP v3 de chaque hôte ;
5. le plugin Linux de Centreon collecte effectivement des métriques ;
6. les services de la plateforme tournent ;
7. tous les hôtes de l'inventaire sont déclarés dans Centreon.

Les points 4 et 5 sont les seuls qui prouvent la chaîne complète : ils
franchissent le réseau, l'authentification, le chiffrement, la vue SNMP et le
plugin. Les autres sont des vérifications de maillon.

Les passphrases n'y transitent jamais par une ligne de commande, où `ps` les
rendrait lisibles par tout utilisateur de la machine : elles passent par un
fichier de configuration temporaire en lecture root seule, effacé ensuite.

---

## Idempotence : les points délicats

Trois endroits ne sont pas idempotents par nature et ont demandé un traitement.

**L'utilisateur SNMP v3.** Sa création passe par une directive `createUser`
écrite pendant que l'agent est arrêté ; l'agent la consomme au démarrage et la
remplace par une ligne `usmUser`. C'est la présence de cette ligne `usmUser` qui
sert de preuve d'existence, et qui évite de recréer l'utilisateur à chaque
passage. La variable `snmp_agent_v3_force_recreate_user` permet de forcer la
recréation lors d'une rotation des passphrases.

**Les macros de mot de passe dans Centreon.** Centreon les renvoie masquées : il
est impossible de savoir si celle qui est posée correspond à celle qu'on veut
poser. Elles ne sont donc écrites qu'à la création de l'hôte, ou sur demande
explicite via `centreon_hosts_force_update_snmp_macros`. Les macros non
sensibles, elles, sont relues et comparées avant d'être écrites.

**Les commandes `dnf module`.** Elles sont déclaratives et sans effet si l'état
demandé est déjà atteint. Elles sont marquées comme non modifiantes, ce qui
évite un faux positif à chaque exécution.
