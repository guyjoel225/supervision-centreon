# Catalogue des contrôles disponibles

Ce que le plugin Linux SNMP sait mesurer, ce que chaque mesure exige de
l'agent, et comment ajouter un contrôle sans se heurter à une branche non
exposée.

La liste des modes ci-dessous a été relevée sur la plateforme, avec
`centreon_linux_snmp.pl --plugin=os::linux::snmp::plugin --list-mode`, et non
reconstituée de mémoire. Relancez cette commande après une montée de version
du plugin : elle fait autorité, ce document non.

---

## Le principe, en une phrase

Un mode interroge une branche de l'arbre SNMP. L'agent n'expose que les
branches déclarées dans `snmp_agent_view_oids`. **Un mode qui interroge une
branche non exposée échoue**, avec un message qui parle d'expiration de délai
et ne nomme jamais la branche manquante.

Ajouter un contrôle demande donc deux vérifications : le mode existe-t-il, et
sa branche est-elle exposée.

---

## Ce que la vue expose par défaut

| Branche | Contenu | Ce qu'elle rend possible |
|---|---|---|
| `.1.3.6.1.2.1.1` | system | Nom, description, temps de fonctionnement |
| `.1.3.6.1.2.1.2` | interfaces | Compteurs réseau 32 bits |
| `.1.3.6.1.2.1.4` | ip | Table des adresses |
| `.1.3.6.1.2.1.25` | host-resources | Stockage, processus, mémoire |
| `.1.3.6.1.2.1.31` | ifMIB | Compteurs 64 bits, noms d'interfaces |
| `.1.3.6.1.4.1.2021` | UCD-SNMP | Charge, mémoire, pagination, disques |
| `.1.3.6.1.4.1.8072` | net-snmp | Statistiques de l'agent, extensions |

Sept branches, choisies pour couvrir les mesures d'un serveur Linux sans
exposer l'arbre entier. Une vue restreinte n'est pas une précaution
symbolique : tout ce qui y figure est lisible par quiconque possède les
identifiants SNMP.

---

## Les modes, et ce qu'ils exigent

### Déjà utilisés par le rôle

| Mode | Service | Branche requise | État |
|---|---|---|---|
| `cpu` | Charge processeur | UCD-SNMP | exposée |
| `memory` | Mémoire utilisée | UCD-SNMP | exposée |
| `swap` | Espace de pagination | UCD-SNMP | exposée |
| `load` | Charge système | UCD-SNMP | exposée |
| `storage` | Occupation des systèmes de fichiers | host-resources | exposée |
| `uptime` | Temps depuis le démarrage | system | exposée |
| `processcount` | Démons du central | host-resources | exposée |

### Utilisables sans toucher aux agents

Leur branche figure déjà dans la vue : il suffit d'ajouter une ligne au
catalogue.

| Mode | Ce qu'il mesure | Branche |
|---|---|---|
| `cpu-detailed` | Détail par type d'usage : système, utilisateur, attente d'entrées-sorties | UCD-SNMP |
| `interfaces` | Trafic, erreurs et état des interfaces réseau | interfaces, ifMIB |
| `disk-usage` | Occupation par point de montage | host-resources |
| `inodes` | Occupation en inodes, souvent saturée avant l'espace disque | host-resources |
| `diskio` | Entrées-sorties disque | UCD-SNMP |
| `time` | Dérive de l'horloge par rapport au collecteur | system |
| `arp` | Table ARP | ip |
| `list-interfaces` | Énumère les interfaces, pour découvrir quoi superviser | interfaces |
| `list-storages` | Énumère les systèmes de fichiers | host-resources |
| `list-processes` | Énumère les processus | host-resources |
| `list-diskio` | Énumère les disques | UCD-SNMP |
| `list-diskspath` | Énumère les chemins de disques | host-resources |

Les modes `list-*` ne produisent pas de service utile : ils servent à
découvrir ce qui existe sur une machine avant d'écrire le filtre d'un contrôle.
Lancez-les à la main depuis le central.

### Demandant d'élargir la vue

| Mode | Ce qu'il mesure | Branche à ajouter |
|---|---|---|
| `tcpcon` | Connexions TCP par état | `.1.3.6.1.2.1.6` |
| `udpcon` | Connexions UDP | `.1.3.6.1.2.1.7` |

C'est la seule limite connue du dépôt sur ce plugin. Elle est délibérée : la
branche TCP expose la liste des connexions établies, donc avec qui la machine
communique, ce qui ne se donne pas sans raison.

Le mode `multi` permet enfin de regrouper plusieurs contrôles en un appel. Il
n'est pas employé ici : un service par mesure donne un historique et un seuil
propres à chacune.

---

## Ajouter un contrôle

### Cas simple : la branche est déjà exposée

Une ligne dans `centreon_hosts_services`, puis `make declare`.

```yaml
  - {nom: Interfaces, mode: interfaces, description: "Trafic des interfaces reseau"}
```

Deux règles pour la description. Elle ne doit contenir aucun caractère refusé
par le moteur, `~!$%^&*"|'<>?,()=`, apostrophe et parenthèses comprises : la
garde du rôle vous arrêtera en nommant le service. Et si vous renommez un
service existant, notez son ancienne description dans `anciennes_descriptions`,
faute de quoi les services déjà créés garderont l'ancien nom pendant que le
modèle en engendrera de nouveaux sous le nouveau.

Certains modes demandent des options, passées par la macro
`EXTRAOPTIONS` comme le fait le catalogue du central. Un filtre d'interface,
par exemple, évite de surveiller les interfaces virtuelles.

### Cas où la branche manque

Ajoutez-la à `snmp_agent_view_oids`, puis **rejouez les agents avant de
déclarer le service**, sinon le contrôle échouera sur une expiration de délai
sans dire pourquoi.

```yaml
snmp_agent_view_oids:
  - {oid: ".1.3.6.1.2.1.6", comment: "tcp : connexions par etat"}
```

```bash
make agents LIMIT=<hôtes concernés>
make declare
```

Élargir la vue sur un parc en service ne coupe rien : le rôle réécrit la
configuration de l'agent et le recharge, sans toucher aux autres services de
la machine.

---

## Vérifier qu'un mode fonctionne avant de le déclarer

Plus rapide que de créer un service et d'attendre le prochain cycle : appelez
le plugin à la main, depuis le serveur central, avec les mêmes paramètres que
Centreon utilisera.

```bash
/usr/lib/centreon/plugins/centreon_linux_snmp.pl \
  --plugin=os::linux::snmp::plugin \
  --mode=interfaces \
  --hostname=<adresse> \
  --snmp-version=3 \
  --snmp-username=<utilisateur> \
  --authprotocol=SHA --authpassphrase=<phrase> \
  --privprotocol=AES --privpassphrase=<phrase>
```

Une réponse `OK` prouve que le mode et la vue s'accordent. Une expiration de
délai signale presque toujours une branche non exposée, et non un problème de
réseau : la même commande avec `--mode=uptime` répondra, elle.

Ces paramètres contiennent des phrases secrètes : lancez cette commande depuis
un interpréteur qui n'historise pas, ou faites-la précéder d'une espace.
