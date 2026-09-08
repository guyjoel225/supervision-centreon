#!/bin/bash
# ===================================================================
# Installe un agent SNMP en lecture seule pour la supervision Centreon.
#
# Autonome : ni Ansible, ni inventaire, ni accès au serveur central. Conçu
# pour être confié à l'équipe qui exploite un serveur, et exécuté par elle.
#
# Deux versions du protocole au choix. La v3 authentifie et chiffre. La v2c
# transporte sa communauté en clair : elle n'existe ici que pour les centraux
# qui ne savent pas faire autrement, et la restriction par adresse source y
# est alors la seule protection réelle.
#
# Sur un serveur en production, le script s'interdit :
#   - de toucher à autre chose qu'à l'agent SNMP ;
#   - de redémarrer un service qui n'est pas snmpd ;
#   - d'activer un pare-feu qui ne l'était pas, ce qui couperait les
#     connexions établies, y compris la session qui l'exécute ;
#   - d'écraser une configuration SNMP existante sans y avoir été autorisé.
#
# Il ne modifie rien tant que --appliquer n'est pas passé : sans cette
# option, il établit et affiche ce qu'il ferait.
# ===================================================================

set -euo pipefail

# ------------------------------------------------------------------
# Valeurs par défaut
# ------------------------------------------------------------------

VERSION_SNMP=""
CENTRAL=""
UTILISATEUR="centreon_ro"
PROTO_AUTH="SHA"
PROTO_CHIFFREMENT="AES"
PORT=161
APPLIQUER=0
FORCER=0
FICHIER_SECRETS=""
LOCALISATION="$(hostname)"
CONTACT="supervision"

CONF="/etc/snmp/snmpd.conf"
MARQUE="Agent SNMP pour la supervision Centreon, pose par installer-agent-snmp.sh"

# Branches exposées, et rien d'autre. Une vue restreinte n'est pas une
# précaution symbolique : tout ce qui y figure est lisible par quiconque
# détient les identifiants SNMP.
VUES=(
    ".1.3.6.1.2.1.1     system : nom, description, temps de fonctionnement"
    ".1.3.6.1.2.1.2     interfaces : compteurs reseau"
    ".1.3.6.1.2.1.4     ip : table des adresses"
    ".1.3.6.1.2.1.25    host-resources : stockage, processus, memoire"
    ".1.3.6.1.2.1.31    ifMIB : compteurs 64 bits"
    ".1.3.6.1.4.1.2021  UCD-SNMP : charge, memoire, pagination, disques"
    ".1.3.6.1.4.1.8072  net-snmp : statistiques de l agent"
)

rouge()  { printf '\033[0;31m%s\033[0m\n' "$*"; }
vert()   { printf '\033[0;32m%s\033[0m\n' "$*"; }
jaune()  { printf '\033[0;33m%s\033[0m\n' "$*"; }
titre()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
info()   { printf '  %s\n' "$*"; }

mourir() { rouge "ERREUR : $*"; exit 1; }

aide() {
    cat <<'FIN'
Usage : installer-agent-snmp.sh --version v3|v2c --central <adresse> [options]

Obligatoire
  --version v3|v2c        Version du protocole que le central emploie
  --central <adresse>     Adresse du serveur central, seule autorisee a
                          interroger cet agent

Options
  --appliquer             Applique reellement. Sans cette option, le script
                          etablit et affiche ce qu'il ferait, sans rien changer
  --utilisateur <nom>     Nom de l'utilisateur SNMP v3 (defaut : centreon_ro)
  --secrets <fichier>     Fichier contenant les secrets, une ligne par valeur :
                            AUTH=<phrase d authentification>
                            PRIV=<phrase de chiffrement>
                            COMMUNAUTE=<communaute v2c>
                          A defaut, ils sont demandes sans etre affiches.
                          Les passer en argument les exposerait dans la table
                          des processus.
  --auth-protocole <p>    SHA (defaut) ou SHA-512
  --priv-protocole <p>    AES (defaut) ou AES-256
  --port <n>              Port d'ecoute (defaut : 161)
  --localisation <texte>  Valeur de sysLocation
  --contact <texte>       Valeur de sysContact
  --forcer                Remplace une configuration SNMP existante que ce
                          script n'a pas ecrite. Une sauvegarde horodatee est
                          conservee dans tous les cas
  --aide                  Affiche ce message

Exemples
  # Constat : ne modifie rien
  ./installer-agent-snmp.sh --version v3 --central 10.0.0.5

  # Application reelle
  ./installer-agent-snmp.sh --version v3 --central 10.0.0.5 --appliquer

  # Central qui interroge en v2c
  ./installer-agent-snmp.sh --version v2c --central 10.0.0.5 --appliquer
FIN
}

# ------------------------------------------------------------------
# Arguments
# ------------------------------------------------------------------

while [ $# -gt 0 ]; do
    case "$1" in
        --version)         VERSION_SNMP="${2:-}"; shift 2 ;;
        --central)         CENTRAL="${2:-}"; shift 2 ;;
        --utilisateur)     UTILISATEUR="${2:-}"; shift 2 ;;
        --secrets)         FICHIER_SECRETS="${2:-}"; shift 2 ;;
        --auth-protocole)  PROTO_AUTH="${2:-}"; shift 2 ;;
        --priv-protocole)  PROTO_CHIFFREMENT="${2:-}"; shift 2 ;;
        --port)            PORT="${2:-}"; shift 2 ;;
        --localisation)    LOCALISATION="${2:-}"; shift 2 ;;
        --contact)         CONTACT="${2:-}"; shift 2 ;;
        --appliquer)       APPLIQUER=1; shift ;;
        --forcer)          FORCER=1; shift ;;
        --aide|-h)         aide; exit 0 ;;
        *)                 mourir "option inconnue : $1 (voir --aide)" ;;
    esac
done

# Les arguments sont validés avant d'exiger root : corriger une faute de
# frappe ne doit pas obliger à relancer sous sudo pour la découvrir.
[ -n "$VERSION_SNMP" ] || { aide; mourir "--version est obligatoire."; }
[ -n "$CENTRAL" ]      || { aide; mourir "--central est obligatoire."; }

case "$VERSION_SNMP" in
    v3|v2c) ;;
    *) mourir "--version accepte v3 ou v2c, pas « $VERSION_SNMP »." ;;
esac

echo "$CENTRAL" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' \
    || mourir "--central attend une adresse IPv4, pas « $CENTRAL »."

[ "$(id -u)" -eq 0 ] || mourir "ce script doit etre execute par root."

# ------------------------------------------------------------------
# Distribution
# ------------------------------------------------------------------

titre "1. Systeme"

if   command -v apt-get >/dev/null 2>&1; then
    FAMILLE="debian"; PAQUETS="snmp snmpd"; SERVICE="snmpd"
    PERSISTANT="/var/lib/snmp/snmpd.conf"; UTILISATEUR_SERVICE="Debian-snmp"
elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    FAMILLE="rhel"; PAQUETS="net-snmp net-snmp-utils"; SERVICE="snmpd"
    PERSISTANT="/var/lib/net-snmp/snmpd.conf"; UTILISATEUR_SERVICE="root"
else
    mourir "ni apt ni dnf : distribution non prise en charge."
fi

. /etc/os-release 2>/dev/null || true
info "distribution : ${PRETTY_NAME:-inconnue} (famille ${FAMILLE})"
info "central autorise : ${CENTRAL}"
info "protocole : ${VERSION_SNMP}"

# ------------------------------------------------------------------
# Ce que le script va trouver, avant de toucher à quoi que ce soit
# ------------------------------------------------------------------

titre "2. Etat actuel de la machine"

AGENT_PRESENT=0
command -v snmpd >/dev/null 2>&1 && AGENT_PRESENT=1
info "agent deja installe : $([ $AGENT_PRESENT -eq 1 ] && echo oui || echo non)"

PORT_OCCUPE=0
if ss -lnu 2>/dev/null | grep -qE ":${PORT}\b"; then
    PORT_OCCUPE=1
fi
info "port ${PORT} deja en ecoute : $([ $PORT_OCCUPE -eq 1 ] && echo oui || echo non)"

CONF_ETRANGERE=0
if [ -f "$CONF" ] && ! grep -qF "$MARQUE" "$CONF" 2>/dev/null; then
    # Un fichier livré par le paquet et jamais modifié n'est pas une
    # configuration à protéger. Seul un fichier retouché signale un usage.
    if [ "$FAMILLE" = "debian" ]; then
        dpkg --verify snmpd 2>/dev/null | grep -q "$CONF" && CONF_ETRANGERE=1 || true
    else
        rpm --verify net-snmp 2>/dev/null | grep -q "$CONF" && CONF_ETRANGERE=1 || true
    fi
fi
info "configuration SNMP etrangere : $([ $CONF_ETRANGERE -eq 1 ] && echo OUI || echo non)"

PARE_FEU="aucun"
if systemctl is-active --quiet firewalld 2>/dev/null; then
    PARE_FEU="firewalld"
elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    PARE_FEU="ufw"
fi
info "pare-feu actif : ${PARE_FEU}"

# ------------------------------------------------------------------
# Ce qui empêche de continuer
# ------------------------------------------------------------------

if [ $CONF_ETRANGERE -eq 1 ] && [ $FORCER -eq 0 ]; then
    titre "Arret volontaire"
    rouge "${CONF} a ete modifie et n'a pas ete ecrit par ce script."
    cat <<FIN

  Cette machine est probablement deja supervisee par un autre outil.
  L'ecraser ferait tomber cette supervision en aveugle, sans alerte.

  Regardez ce que contient ce fichier avant de decider :

      grep -vE '^\\s*#|^\\s*\$' ${CONF}

  Verifiez en particulier trois choses : une destination de traps, qui
  signifie que la machine envoie ses alertes ailleurs ; un acces en ecriture
  (rwcommunity, rwuser), qui permet a un tiers de la modifier ; et la
  communaute ou l'utilisateur declares, dont un autre central se sert
  peut-etre.

  Si cette configuration ne sert plus, relancez avec --forcer. Une sauvegarde
  horodatee sera conservee a cote du fichier.

FIN
    exit 2
fi

if [ $PORT_OCCUPE -eq 1 ] && [ $AGENT_PRESENT -eq 0 ]; then
    mourir "le port ${PORT} est occupe par autre chose qu'un agent SNMP. Verifiez avec : ss -lnup | grep ${PORT}"
fi

# ------------------------------------------------------------------
# Secrets, jamais en argument ni affichés
# ------------------------------------------------------------------

AUTH=""; PRIV=""; COMMUNAUTE=""

lire_secrets() {
    if [ -n "$FICHIER_SECRETS" ]; then
        [ -f "$FICHIER_SECRETS" ] || mourir "fichier de secrets introuvable : ${FICHIER_SECRETS}"
        # shellcheck disable=SC1090
        AUTH=$(sed -n 's/^AUTH=//p' "$FICHIER_SECRETS" | head -1)
        PRIV=$(sed -n 's/^PRIV=//p' "$FICHIER_SECRETS" | head -1)
        COMMUNAUTE=$(sed -n 's/^COMMUNAUTE=//p' "$FICHIER_SECRETS" | head -1)
        return
    fi
    if [ "$VERSION_SNMP" = "v3" ]; then
        printf '  phrase d authentification (invisible) : ' >&2
        read -rs AUTH; echo >&2
        printf '  phrase de chiffrement (invisible)     : ' >&2
        read -rs PRIV; echo >&2
    else
        printf '  communaute v2c (invisible)            : ' >&2
        read -rs COMMUNAUTE; echo >&2
    fi
}

controler_secrets() {
    if [ "$VERSION_SNMP" = "v3" ]; then
        [ ${#AUTH} -ge 8 ] || mourir "la phrase d authentification doit faire au moins 8 caracteres."
        [ ${#PRIV} -ge 8 ] || mourir "la phrase de chiffrement doit faire au moins 8 caracteres."
        [ "$AUTH" != "$PRIV" ] || mourir "les deux phrases doivent differer : une seule compromise livrerait tout."
    else
        [ ${#COMMUNAUTE} -ge 8 ] || jaune "  La communaute fait moins de 8 caracteres. En v2c elle circule en clair : c'est un secret faible sur un canal ouvert."
        case "$COMMUNAUTE" in
            public|private) jaune "  « ${COMMUNAUTE} » est la valeur par defaut de tous les agents du monde." ;;
        esac
    fi
}

# ------------------------------------------------------------------
# Résumé, et arrêt si l'on n'applique pas
# ------------------------------------------------------------------

titre "3. Ce qui sera fait"

info "installer les paquets : ${PAQUETS}$([ $AGENT_PRESENT -eq 1 ] && echo ' (deja presents)')"
info "ecrire ${CONF}$([ -f "$CONF" ] && echo ' (sauvegarde horodatee de l existant)')"
[ "$VERSION_SNMP" = "v3" ] && info "creer l utilisateur SNMP v3 « ${UTILISATEUR} » en ${PROTO_AUTH}/${PROTO_CHIFFREMENT}"
[ "$VERSION_SNMP" = "v2c" ] && info "declarer la communaute v2c, restreinte a ${CENTRAL}"
case "$PARE_FEU" in
    aucun) info "pare-feu : aucun actif, aucune regle ajoutee, et aucun ne sera active" ;;
    *)     info "pare-feu : ouvrir ${PORT}/udp depuis ${CENTRAL} seulement (${PARE_FEU})" ;;
esac
info "poser un fragment systemd : attendre le reseau, retenter en cas d echec"
info "demarrer et activer ${SERVICE}"
info "verifier que l agent repond, par une requete reelle"
echo
info "ne sera PAS touche : horloge, resolution de noms, fuseau horaire,"
info "                    autres services, autres regles de pare-feu"

if [ $APPLIQUER -eq 0 ]; then
    titre "Constat termine"
    jaune "Rien n'a ete modifie. Relancez avec --appliquer pour agir."
    exit 0
fi

titre "4. Secrets"
lire_secrets
controler_secrets

# ------------------------------------------------------------------
# Application
# ------------------------------------------------------------------

titre "5. Installation"

if [ $AGENT_PRESENT -eq 0 ]; then
    info "installation des paquets"
    if [ "$FAMILLE" = "debian" ]; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        # shellcheck disable=SC2086
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $PAQUETS >/dev/null
    else
        # shellcheck disable=SC2086
        { command -v dnf >/dev/null && dnf install -y -q $PAQUETS >/dev/null; } \
            || yum install -y -q $PAQUETS >/dev/null
    fi
    vert "  paquets installes"
else
    info "paquets deja presents, rien a installer"
fi

if [ -f "$CONF" ]; then
    SAUVEGARDE="${CONF}.$(date +%Y%m%d-%H%M%S).avant-centreon"
    cp -a "$CONF" "$SAUVEGARDE"
    vert "  configuration precedente sauvegardee : ${SAUVEGARDE}"
fi

info "ecriture de ${CONF}"
umask 077
{
    echo "# ${MARQUE}"
    echo "# Ecrit le $(date '+%Y-%m-%d %H:%M:%S%z'). Toute modification manuelle"
    echo "# sera perdue au prochain passage du script."
    echo
    echo "agentaddress udp:127.0.0.1:${PORT},udp:0.0.0.0:${PORT}"
    echo
    echo "# Vue restreinte : seules ces branches sont lisibles."
    for v in "${VUES[@]}"; do
        oid="${v%% *}"; commentaire="${v#* }"
        echo "view centreonview included ${oid}   # ${commentaire# }"
    done
    echo
    if [ "$VERSION_SNMP" = "v3" ]; then
        echo "# Lecture seule, authentifiee et chiffree."
        echo "rouser ${UTILISATEUR} priv -V centreonview"
    else
        echo "# La communaute circule en clair : la restriction par adresse"
        echo "# source est la seule protection reelle de ce canal."
        echo "com2sec centreonsec ${CENTRAL} ${COMMUNAUTE}"
        echo "group   centreongrp v2c centreonsec"
        echo "access  centreongrp \"\" any noauth exact centreonview none none"
    fi
    echo
    echo "sysLocation ${LOCALISATION}"
    echo "sysContact  ${CONTACT}"
    echo "sysServices 72"
    echo "dontLogTCPWrappersConnects yes"
} > "$CONF"
chmod 600 "$CONF"
umask 022
vert "  configuration ecrite"

# ------------------------------------------------------------------
# Utilisateur v3
# ------------------------------------------------------------------

if [ "$VERSION_SNMP" = "v3" ]; then
    titre "6. Utilisateur SNMP v3"
    # net-snmp ne consomme « createUser » qu'au demarrage, et ne reecrit son
    # fichier persistant qu'a l'arret. L'agent doit donc etre arrete pendant
    # cette manipulation, sans quoi elle serait perdue.
    systemctl stop "$SERVICE" 2>/dev/null || true
    touch "$PERSISTANT"; chmod 600 "$PERSISTANT"
    chown "$UTILISATEUR_SERVICE" "$PERSISTANT" 2>/dev/null || true
    sed -i "/^usmUser .*${UTILISATEUR}/d;/^createUser ${UTILISATEUR} /d" "$PERSISTANT"
    printf 'createUser %s %s "%s" %s "%s"\n' \
        "$UTILISATEUR" "$PROTO_AUTH" "$AUTH" "$PROTO_CHIFFREMENT" "$PRIV" >> "$PERSISTANT"
    vert "  utilisateur declare, il sera cree au demarrage de l agent"
fi

# ------------------------------------------------------------------
# Pare-feu : jamais activé, seulement complété s'il tourne déjà
# ------------------------------------------------------------------

titre "7. Pare-feu"
case "$PARE_FEU" in
    firewalld)
        firewall-cmd --quiet --permanent \
            --add-rich-rule="rule family=\"ipv4\" source address=\"${CENTRAL}\" port port=\"${PORT}\" protocol=\"udp\" accept" >/dev/null
        firewall-cmd --quiet --reload >/dev/null
        vert "  ${PORT}/udp ouvert depuis ${CENTRAL} seulement"
        ;;
    ufw)
        ufw --force allow from "$CENTRAL" to any port "$PORT" proto udp >/dev/null
        vert "  ${PORT}/udp ouvert depuis ${CENTRAL} seulement"
        ;;
    aucun)
        jaune "  Aucun pare-feu actif : aucune regle posee, et aucun n'est active."
        jaune "  L'agent est donc joignable depuis tout le reseau, et non du seul"
        jaune "  central. Activer un pare-feu couperait les connexions etablies :"
        jaune "  cela vous revient, hors de ce script."
        ;;
esac

# ------------------------------------------------------------------
# Démarrage
# ------------------------------------------------------------------

titre "8. Demarrage"

# L'agent lie son ecoute a une adresse precise. Si cette adresse appartient a
# une interface montee tardivement, reseau virtuel ou liaison agregee, il
# echoue au demarrage de la machine et ne reessaie jamais. Le fragment
# ci-dessous le fait attendre le reseau et retenter.
mkdir -p /etc/systemd/system/snmpd.service.d
cat > /etc/systemd/system/snmpd.service.d/10-attendre-le-reseau.conf <<'FRAGMENT'
# Pose par installer-agent-snmp.sh
[Unit]
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Restart=on-failure
RestartSec=10
FRAGMENT
chmod 644 /etc/systemd/system/snmpd.service.d/10-attendre-le-reseau.conf
systemctl daemon-reload
info "fragment de demarrage pose : l agent attendra le reseau et retentera"

systemctl enable "$SERVICE" >/dev/null 2>&1 || true
systemctl restart "$SERVICE"
sleep 3
systemctl is-active --quiet "$SERVICE" \
    || mourir "${SERVICE} n'a pas demarre. Voir : journalctl -u ${SERVICE} -n 40"
vert "  ${SERVICE} actif et active au demarrage"

# ------------------------------------------------------------------
# Preuve
# ------------------------------------------------------------------

titre "9. Verification"

# Les phrases secrètes ne passent pas par la ligne de commande, où ps les
# rendrait lisibles par tout utilisateur de la machine.
REPERTOIRE_TEST=$(mktemp -d)
trap 'rm -rf "$REPERTOIRE_TEST"' EXIT
if [ "$VERSION_SNMP" = "v3" ]; then
    {
        echo "defVersion 3"
        echo "defSecurityLevel authPriv"
        echo "defSecurityName ${UTILISATEUR}"
        echo "defAuthType ${PROTO_AUTH}"
        echo "defAuthPassphrase ${AUTH}"
        echo "defPrivType ${PROTO_CHIFFREMENT}"
        echo "defPrivPassphrase ${PRIV}"
    } > "${REPERTOIRE_TEST}/snmp.conf"
    chmod 600 "${REPERTOIRE_TEST}/snmp.conf"
    REPONSE=$(SNMPCONFPATH="$REPERTOIRE_TEST" snmpget -Oqv "127.0.0.1:${PORT}" .1.3.6.1.2.1.1.5.0 2>&1) || true
else
    {
        echo "defVersion 2c"
        echo "defCommunity ${COMMUNAUTE}"
    } > "${REPERTOIRE_TEST}/snmp.conf"
    chmod 600 "${REPERTOIRE_TEST}/snmp.conf"
    REPONSE=$(SNMPCONFPATH="$REPERTOIRE_TEST" snmpget -Oqv "127.0.0.1:${PORT}" .1.3.6.1.2.1.1.5.0 2>&1) || true
fi

if [ -n "$REPONSE" ] && ! echo "$REPONSE" | grep -qiE "timeout|error|unknown"; then
    vert "  l agent repond : « ${REPONSE} »"
else
    rouge "  l agent ne repond pas correctement : ${REPONSE}"
    cat <<FIN

  Ce qui reste a verifier, dans cet ordre :
    journalctl -u ${SERVICE} -n 40
    ss -lnup | grep ${PORT}

FIN
    exit 3
fi

# ------------------------------------------------------------------
# Ce qui reste à faire
# ------------------------------------------------------------------

titre "Termine"
cat <<FIN
  L'agent repond en local. Cela ne prouve pas encore que le central peut
  l'interroger : c'est un autre chemin reseau, souvent d'autres regles de
  pare-feu.

  Faites lancer ceci depuis le serveur central, c'est la seule preuve qui
  vaille :

$(if [ "$VERSION_SNMP" = "v3" ]; then
    echo "      snmpget -v3 -u ${UTILISATEUR} -l authPriv \\"
    echo "        -a ${PROTO_AUTH} -A '<phrase auth>' \\"
    echo "        -x ${PROTO_CHIFFREMENT} -X '<phrase chiffrement>' \\"
    echo "        $(hostname -I | awk '{print $1}') 1.3.6.1.2.1.1.5.0"
else
    echo "      snmpget -v2c -c '<communaute>' $(hostname -I | awk '{print $1}') 1.3.6.1.2.1.1.5.0"
fi)

  Puis declarez cet hote dans Centreon, avec les memes identifiants.

  Pour revenir en arriere :
      systemctl stop ${SERVICE} && systemctl disable ${SERVICE}
      cp -a ${CONF}.<horodatage>.avant-centreon ${CONF}   # si une sauvegarde existe
FIN
