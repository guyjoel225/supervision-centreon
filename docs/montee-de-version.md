# Monter le serveur central de version

Ce document existe pour que la marche à suivre ne soit pas découverte le jour
où une faille impose de l'appliquer vite. Il couvre la montée de version et,
surtout, le retour en arrière : c'est la partie qu'on regrette de ne pas avoir
écrite.

---

## Ce qui est automatisé, et ce qui ne l'est pas

`make upgrade` prend une sauvegarde, la vérifie, relève les versions, met à
jour les paquets et confirme que l'interface répond.

Il ne déroule pas l'assistant de migration de la base. Ce n'est pas un oubli.
Cet assistant transforme des données irremplaçables, son déroulement change
d'une version à l'autre, et le faire jouer à l'aveugle par un automate est
précisément le genre de raccourci qui coûte une plateforme. Le playbook
prépare tout, vérifie tout, et dit où reprendre à la main.

---

## Avant de commencer

Vérifiez que la version visée accepte votre système. Centreon ne publie que
pour Alma, RHEL et Oracle Linux 8 et 9, plus Debian 12. Une version majeure
peut retirer une plateforme de cette liste : le constat ci-dessous vous dira
ce qui est disponible, pas ce qui est supporté.

```bash
make upgrade
```

Sans autre option, cette commande **ne modifie rien**. Elle relève la version
installée et celle disponible, prend une sauvegarde et en vérifie les
empreintes. Lisez sa sortie avant d'aller plus loin.

---

## Dérouler la mise à jour

```bash
make upgrade OPTS="-e centreon_upgrade_apply=true"
```

Cette commande arrête la collecte, met à jour les paquets, redémarre
l'interface et vérifie qu'elle répond. Elle laisse volontairement le moteur de
supervision arrêté : sa configuration doit d'abord être régénérée par la
plateforme mise à jour, et le relancer avant produirait des contrôles sur une
configuration périmée, ce qui est pire qu'une collecte interrompue et visible.

Trois étapes restent à votre main, dans cet ordre.

Ouvrez l'interface et déroulez l'assistant de migration qu'elle propose. C'est
lui qui transforme la base.

Allez dans Configuration puis Pollers, exportez la configuration et relancez le
moteur.

Enfin, prouvez que la collecte a repris :

```bash
make verify
```

Tant que cette dernière commande n'est pas passée, la mise à jour n'est pas
terminée, quelle que soit l'apparence de l'interface.

---

## Revenir en arrière

La sauvegarde prise juste avant la mise à jour est le point de retour. Son
emplacement est rappelé dans la sortie de `make upgrade`, et dans
`/var/lib/centreon-backup.state`.

La restauration n'est pas automatisée, et ce choix est délibéré : une
restauration écrase l'état courant, y compris ce qui a pu être collecté depuis
la sauvegarde. Une commande qui ferait cela sans que quelqu'un ait relu ce
qu'elle écrase serait plus dangereuse qu'utile.

Sur le serveur central, en tant que `root` :

```bash
systemctl stop centengine gorgoned cbd httpd php-fpm
```

Vérifiez d'abord que l'archive est intacte. Une archive tronquée se lit sans
erreur jusqu'à sa troncature ; seule cette vérification la détecte.

```bash
cd /var/backups/centreon/<horodatage> && sha256sum --check SHA256SUMS
```

Restaurez les deux bases. `centreon` porte la configuration du parc,
`centreon_storage` les métriques et l'historique : restaurer l'une sans
l'autre laisse une plateforme qui fonctionne mais qui a tout oublié de ce
qu'elle a mesuré.

```bash
zcat centreon.sql.gz | mysql --defaults-extra-file=/root/.centreon-backup.cnf centreon
```

```bash
zcat centreon_storage.sql.gz | mysql --defaults-extra-file=/root/.centreon-backup.cnf centreon_storage
```

Restaurez ensuite les fichiers de configuration. Ils comptent autant que la
base : `engine-context.json` porte les clés de chiffrement partagées entre
l'interface et le moteur, et une base restaurée sans elles ne produirait plus
aucune configuration, avec un message d'erreur qui ne nommerait pas la cause.

```bash
tar --extract --gzip --file configuration.tar.gz --directory /
```

Si les paquets ont été mis à jour, redescendez-les à la version d'origine
avant de redémarrer, sinon le code attendra un schéma de base que vous venez
de remplacer par l'ancien.

```bash
systemctl start php-fpm httpd cbd gorgoned
```

Régénérez la configuration depuis l'interface, puis relancez le moteur et
lancez `make verify`.

---

## Ce que cette procédure suppose

Elle suppose une sauvegarde exploitable, donc que `make deploy` a bien posé le
mécanisme de sauvegarde et qu'il tourne. Vérifiez-le sans attendre le jour de
la mise à jour :

```bash
systemctl list-timers centreon-backup.timer
```

Elle suppose aussi que la sauvegarde existe **ailleurs** que sur la machine.
Telle qu'elle est posée, elle protège d'une migration ratée, d'une erreur
logique ou d'une suppression, mais pas de la perte du serveur lui-même. Recopier
ces archives hors de cette machine reste à faire, et c'est le seul cas qu'elles
ne couvrent pas.
