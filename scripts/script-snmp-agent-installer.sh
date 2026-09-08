#!/usr/bin/env bash

###############################################################################
# CENTREON SNMP AGENT INSTALLER
# Version 5.1.0
#
# Installation/configuration d'un agent SNMP pour Centreon.
#
# OS supportés :
#   - Rocky Linux
#   - RHEL
#   - AlmaLinux
#   - CentOS
#   - Fedora
#   - Ubuntu
#   - Debian
#
# Protocoles :
#   - SNMPv2c
#   - SNMPv3 authPriv
#
# Firewall :
#   - firewalld
#   - UFW
#
# PRINCIPES DE SECURITE :
#   - --dry-run = aucune modification
#   - Backup avant modification
#   - Conservation de la configuration existante
#   - Bloc Centreon isolé et idempotent
#   - Rollback automatique en cas d'échec
#   - Seul le service snmpd peut être manipulé
#   - Aucun service tiers arrêté
#   - Aucun mot de passe écrit dans les logs
###############################################################################

set -Eeuo pipefail

VERSION="5.1.0"

###############################################################################
# CONFIGURATION GLOBALE
###############################################################################

SNMP_CONF="/etc/snmp/snmpd.conf"
SNMP_SERVICE="snmpd"

MANAGED_BEGIN="# BEGIN CENTREON MANAGED BLOCK"
MANAGED_END="# END CENTREON MANAGED BLOCK"

BACKUP_ROOT="/var/backups/centreon-snmp-installer"
LOCK_FILE="/run/centreon-snmp-installer.lock"

DRY_RUN=false

###############################################################################
# SYSTEME
###############################################################################

OS_ID=""
OS_NAME=""
OS_VERSION=""
PKG_MANAGER=""

###############################################################################
# CONFIGURATION CENTREON
###############################################################################

POLLER_IP=""
SNMP_VERSION=""

COMMUNITY=""

SNMP_USER=""
SNMP_AUTH_PROTO=""
SNMP_AUTH_PASS=""
SNMP_PRIV_PROTO=""
SNMP_PRIV_PASS=""

###############################################################################
# FIREWALL
###############################################################################

FIREWALL="none"
FIREWALL_CHANGED=false

###############################################################################
# ETAT INITIAL
###############################################################################

SNMP_INITIAL_ACTIVE=false
SNMP_INITIAL_ENABLED=false

###############################################################################
# BACKUPS
###############################################################################

CONFIG_BACKUP=""
PERSISTENT_BACKUP=""
PERSISTENT_CONF=""

###############################################################################
# ETAT TRANSACTION
###############################################################################

CONFIG_CHANGED=false
SNMPV3_CHANGED=false

###############################################################################
# OUTPUT
###############################################################################

info() {
    printf '[INFO] %s\n' "$*"
}

ok() {
    printf '[ OK ] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

error() {
    printf '[ERROR] %s\n' "$*" >&2
}

fatal() {
    error "$*"
    exit 1
}

section() {

    echo
    printf '%s\n' "============================================================"
    printf ' %s\n' "$*"
    printf '%s\n' "============================================================"

}

###############################################################################
# CLEANUP
###############################################################################

cleanup() {

    rm -f "$LOCK_FILE" 2>/dev/null || true

    unset COMMUNITY
    unset SNMP_AUTH_PASS
    unset SNMP_PRIV_PASS

}

trap cleanup EXIT

###############################################################################
# ARGUMENTS
###############################################################################

usage() {

    cat <<EOF

Centreon SNMP Agent Installer V$VERSION

Usage:

    sudo $0
    sudo $0 --dry-run

Options:

    --dry-run
        Analyse le système et affiche le plan.
        Aucune modification n'est effectuée.

    --help
        Affiche cette aide.

Le mode --dry-run ne fait AUCUNE des opérations suivantes :

    - installation de paquet
    - création de fichier
    - modification de fichier
    - création d'utilisateur SNMPv3
    - modification firewall
    - arrêt de service
    - démarrage de service
    - redémarrage de service
    - enable/disable systemd

EOF

}

parse_args() {

    while [[ $# -gt 0 ]]; do

        case "$1" in

            --dry-run)

                DRY_RUN=true
                shift

                ;;

            --help|-h)

                usage
                exit 0

                ;;

            *)

                fatal "Option inconnue : $1"

                ;;

        esac

    done

}

###############################################################################
# ROOT
###############################################################################

check_root() {

    if [[ "$EUID" -ne 0 ]]; then

        fatal "Ce script doit être exécuté avec sudo/root."

    fi

}

###############################################################################
# LOCK
###############################################################################

acquire_lock() {

    #
    # Le dry-run doit rester strictement read-only.
    #
    if [[ "$DRY_RUN" == true ]]; then
        return 0
    fi

    if [[ -e "$LOCK_FILE" ]]; then

        fatal "Une autre instance du script est déjà active."

    fi

    (
        umask 077
        printf '%s\n' "$$" > "$LOCK_FILE"
    )

}

###############################################################################
# DETECTION OS
###############################################################################

detect_os() {

    [[ -r /etc/os-release ]] ||
        fatal "/etc/os-release est introuvable."

    # shellcheck disable=SC1091
    source /etc/os-release

    OS_ID="${ID:-unknown}"
    OS_NAME="${NAME:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"

    case "$OS_ID" in

        rocky|rhel|almalinux|centos|fedora)

            if command -v dnf >/dev/null 2>&1; then
                PKG_MANAGER="dnf"
            elif command -v yum >/dev/null 2>&1; then
                PKG_MANAGER="yum"
            else
                fatal "dnf/yum introuvable."
            fi

            ;;

        ubuntu|debian)

            PKG_MANAGER="apt"

            ;;

        *)

            fatal "Distribution non supportée : $OS_ID"

            ;;

    esac

    info "OS : $OS_NAME $OS_VERSION"
    info "Gestionnaire de paquets : $PKG_MANAGER"

}

###############################################################################
# ETAT SERVICE
###############################################################################

read_service_state() {

    command -v systemctl >/dev/null 2>&1 ||
        fatal "systemctl est requis."

    if systemctl is-active --quiet "$SNMP_SERVICE"; then
        SNMP_INITIAL_ACTIVE=true
    fi

    if systemctl is-enabled --quiet "$SNMP_SERVICE" 2>/dev/null; then
        SNMP_INITIAL_ENABLED=true
    fi

    if [[ "$SNMP_INITIAL_ACTIVE" == true ]]; then
        info "Service snmpd : actif"
    else
        info "Service snmpd : arrêté"
    fi

    if [[ "$SNMP_INITIAL_ENABLED" == true ]]; then
        info "Démarrage automatique : activé"
    else
        info "Démarrage automatique : désactivé"
    fi

}

###############################################################################
# NET-SNMP
###############################################################################

check_net_snmp() {

    if command -v snmpd >/dev/null 2>&1 &&
       command -v snmpget >/dev/null 2>&1; then

        ok "Net-SNMP est installé."

        return 0

    fi

    if [[ "$DRY_RUN" == true ]]; then

        warn "Net-SNMP n'est pas complètement installé."

        echo
        echo "[DRY-RUN] Installation prévue :"

        if [[ "$PKG_MANAGER" == "apt" ]]; then

            echo "  apt-get install -y snmp snmpd"

        else

            echo "  $PKG_MANAGER install -y net-snmp net-snmp-utils"

        fi

        return 0

    fi

    fatal "snmpd/snmpget sont nécessaires."

}

###############################################################################
# CONFIGURATION PERSISTANTE SNMPv3
###############################################################################

detect_persistent_config() {

    local candidates=(
        "/var/lib/net-snmp/snmpd.conf"
        "/var/lib/snmp/snmpd.conf"
        "/var/net-snmp/snmpd.conf"
    )

    for file in "${candidates[@]}"; do

        if [[ -f "$file" ]]; then

            PERSISTENT_CONF="$file"

            info "Fichier persistant SNMP : $PERSISTENT_CONF"

            return 0

        fi

    done

    case "$OS_ID" in

        rocky|rhel|almalinux|centos|fedora)

            PERSISTENT_CONF="/var/lib/net-snmp/snmpd.conf"

            ;;

        ubuntu|debian)

            PERSISTENT_CONF="/var/lib/snmp/snmpd.conf"

            ;;

    esac

    info "Fichier persistant SNMP prévu : $PERSISTENT_CONF"

}

###############################################################################
# FIREWALL
###############################################################################

detect_firewall() {

    FIREWALL="none"

    #
    # firewalld
    #
    if command -v firewall-cmd >/dev/null 2>&1 &&
       firewall-cmd --state >/dev/null 2>&1; then

        FIREWALL="firewalld"

    #
    # UFW
    #
    elif command -v ufw >/dev/null 2>&1 &&
         ufw status 2>/dev/null | grep -q '^Status: active'; then

        FIREWALL="ufw"

    fi

    case "$FIREWALL" in

        firewalld)

            info "Firewall actif : firewalld"

            ;;

        ufw)

            info "Firewall actif : UFW"

            ;;

        none)

            warn "Aucun firewall local actif."

            ;;

    esac

}

###############################################################################
# VALIDATION IPV4
###############################################################################

validate_ipv4() {

    local ip="$1"

    local a
    local b
    local c
    local d

    IFS=. read -r a b c d <<< "$ip"

    [[ "$a" =~ ^[0-9]+$ ]] &&
    [[ "$b" =~ ^[0-9]+$ ]] &&
    [[ "$c" =~ ^[0-9]+$ ]] &&
    [[ "$d" =~ ^[0-9]+$ ]] &&
    (( a <= 255 )) &&
    (( b <= 255 )) &&
    (( c <= 255 )) &&
    (( d <= 255 ))

}

###############################################################################
# SAISIE POLLER
###############################################################################

ask_poller() {

    while true; do

        read -r -p "IP du Poller Centreon : " POLLER_IP

        if validate_ipv4 "$POLLER_IP"; then

            break

        fi

        warn "Adresse IPv4 invalide."

    done

}

###############################################################################
# SAISIE SNMPv2c
###############################################################################

ask_v2c() {

    while true; do

        #
        # Community volontairement visible.
        #
        read -r -p "Community SNMPv2c : " COMMUNITY

        if [[ -n "$COMMUNITY" ]]; then

            break

        fi

        warn "La community ne peut pas être vide."

    done

}

###############################################################################
# SAISIE SNMPv3
###############################################################################

ask_v3() {

    read -r -p "Utilisateur SNMPv3 : " SNMP_USER

    [[ -n "$SNMP_USER" ]] ||
        fatal "Utilisateur SNMPv3 vide."

    [[ "$SNMP_USER" =~ ^[A-Za-z0-9_.-]+$ ]] ||
        fatal "Nom utilisateur SNMPv3 invalide."

    echo
    echo "Algorithme d'authentification :"
    echo "  1) SHA"
    echo "  2) SHA-256"
    echo "  3) SHA-512"

    read -r -p "Choix [1-3] : " choice

    case "$choice" in

        1)
            SNMP_AUTH_PROTO="SHA"
            ;;

        2)
            SNMP_AUTH_PROTO="SHA-256"
            ;;

        3)
            SNMP_AUTH_PROTO="SHA-512"
            ;;

        *)
            fatal "Choix invalide."
            ;;

    esac

    read -r -s -p "Mot de passe auth : " SNMP_AUTH_PASS
    echo

    (( ${#SNMP_AUTH_PASS} >= 8 )) ||
        fatal "Mot de passe auth trop court."

    echo
    echo "Algorithme de confidentialité :"
    echo "  1) AES"

    read -r -p "Choix [1] : " choice

    [[ "$choice" == "1" ]] ||
        fatal "Choix invalide."

    SNMP_PRIV_PROTO="AES"

    read -r -s -p "Mot de passe priv : " SNMP_PRIV_PASS
    echo

    (( ${#SNMP_PRIV_PASS} >= 8 )) ||
        fatal "Mot de passe priv trop court."

}

###############################################################################
# MENU SNMP
###############################################################################

ask_configuration() {

    section "CONFIGURATION CENTREON"

    ask_poller

    echo
    echo "Version SNMP :"
    echo "  1) SNMPv2c"
    echo "  2) SNMPv3"

    read -r -p "Choix [1-2] : " choice

    case "$choice" in

        1)

            SNMP_VERSION="2c"

            ask_v2c

            ;;

        2)

            SNMP_VERSION="3"

            ask_v3

            ;;

        *)

            fatal "Choix invalide."

            ;;

    esac

}

###############################################################################
# BLOC SNMPv2c
###############################################################################

build_v2c_block() {

    cat <<EOF
$MANAGED_BEGIN
#
# Managed by Centreon SNMP Installer V$VERSION
# Poller Centreon : $POLLER_IP
#

rocommunity $COMMUNITY $POLLER_IP

$MANAGED_END
EOF

}

###############################################################################
# BLOC SNMPv3
###############################################################################

build_v3_block() {

    cat <<EOF
$MANAGED_BEGIN
#
# Managed by Centreon SNMP Installer V$VERSION
# Poller Centreon : $POLLER_IP
#

rouser $SNMP_USER authPriv

$MANAGED_END
EOF

}

###############################################################################
# SUPPRESSION UNIQUEMENT DE NOTRE BLOC
###############################################################################

strip_managed_block() {

    awk \
        -v begin="$MANAGED_BEGIN" \
        -v end="$MANAGED_END" '

        $0 == begin {
            inside=1
            next
        }

        $0 == end {
            inside=0
            next
        }

        !inside {
            print
        }

    ' "$SNMP_CONF"

}

###############################################################################
# GENERATION CONFIG CANDIDATE
###############################################################################

generate_candidate() {

    local block

    if [[ "$SNMP_VERSION" == "2c" ]]; then

        block="$(build_v2c_block)"

    else

        block="$(build_v3_block)"

    fi

    {
        strip_managed_block
        printf '\n%s\n' "$block"
    }

}

###############################################################################
# DRY RUN
###############################################################################

dry_run_plan() {

    section "DRY-RUN"

    echo "[DRY-RUN] MODE LECTURE SEULE."
    echo "[DRY-RUN] AUCUNE MODIFICATION NE SERA EFFECTUÉE."

    echo
    echo "État actuel :"

    echo "  OS              : $OS_NAME $OS_VERSION"

    if [[ "$SNMP_INITIAL_ACTIVE" == true ]]; then
        echo "  snmpd           : actif"
    else
        echo "  snmpd           : arrêté"
    fi

    if [[ "$SNMP_INITIAL_ENABLED" == true ]]; then
        echo "  boot            : activé"
    else
        echo "  boot            : désactivé"
    fi

    echo "  firewall        : $FIREWALL"
    echo "  configuration   : $SNMP_CONF"

    echo
    echo "Configuration demandée :"

    echo "  SNMP            : $SNMP_VERSION"
    echo "  Poller          : $POLLER_IP"

    if [[ "$SNMP_VERSION" == "2c" ]]; then

        echo "  Community       : $COMMUNITY"

    else

        echo "  User            : $SNMP_USER"
        echo "  Auth            : $SNMP_AUTH_PROTO"
        echo "  Privacy         : $SNMP_PRIV_PROTO"
        echo "  Passwords       : ********"

    fi

    echo
    echo "Actions prévues :"

    echo "  [PLAN] Backup de $SNMP_CONF"

    if [[ "$SNMP_VERSION" == "3" ]]; then

        echo "  [PLAN] Backup de $PERSISTENT_CONF"
        echo "  [PLAN] Création/validation de l'utilisateur SNMPv3"

    fi

    echo "  [PLAN] Conservation de la configuration existante"
    echo "  [PLAN] Remplacement du bloc Centreon uniquement"
    echo "  [PLAN] Validation de la configuration"
    echo "  [PLAN] Configuration firewall UDP/161 depuis $POLLER_IP"

    if [[ "$SNMP_INITIAL_ACTIVE" == true ]]; then

        echo "  [PLAN] Redémarrage contrôlé de snmpd"

    else

        echo "  [PLAN] Démarrage contrôlé de snmpd"

    fi

    echo
    section "DIFF PROPOSÉ"

    if [[ -f "$SNMP_CONF" ]]; then

        diff -u \
            "$SNMP_CONF" \
            <(generate_candidate) || true

    else

        echo "[PLAN] $SNMP_CONF sera créé."

    fi

    echo
    section "FIN DRY-RUN"

    echo "AUCUNE MODIFICATION EFFECTUÉE."

}

###############################################################################
# BACKUP
###############################################################################

create_backups() {

    mkdir -p "$BACKUP_ROOT"

    local timestamp

    timestamp="$(date '+%Y%m%d_%H%M%S')"

    CONFIG_BACKUP="$BACKUP_ROOT/snmpd.conf.$timestamp"

    if [[ -f "$SNMP_CONF" ]]; then

        cp -a "$SNMP_CONF" "$CONFIG_BACKUP"

        ok "Backup snmpd.conf : $CONFIG_BACKUP"

    fi

    if [[ "$SNMP_VERSION" == "3" &&
          -f "$PERSISTENT_CONF" ]]; then

        PERSISTENT_BACKUP="$BACKUP_ROOT/snmpd-persistent.$timestamp"

        cp -a "$PERSISTENT_CONF" "$PERSISTENT_BACKUP"

        ok "Backup persistant SNMPv3 : $PERSISTENT_BACKUP"

    fi

}

###############################################################################
# VALIDATION CANDIDATE
###############################################################################

validate_candidate() {

    info "Validation de la configuration candidate..."

    local candidate

    candidate="$(mktemp)"

    chmod 600 "$candidate"

    generate_candidate > "$candidate"

    #
    # Vérification directives d'accès incomplètes.
    #
    if grep -nE \
        '^[[:space:]]*(rocommunity|rwcommunity|rouser|rwuser)[[:space:]]*$' \
        "$candidate" >/dev/null 2>&1; then

        rm -f "$candidate"

        fatal "Directive SNMP incomplète détectée."

    fi

    #
    # Vérification minimale de la disponibilité de snmpd.
    #
    command -v snmpd >/dev/null 2>&1 ||
        fatal "snmpd introuvable."

    #
    # Nettoyage.
    #
    rm -f "$candidate"

    ok "Configuration candidate validée."

}

###############################################################################
# APPLICATION CONFIG
###############################################################################

apply_main_config() {

    local temporary

    temporary="$(mktemp "${SNMP_CONF}.XXXXXX")"

    chmod 600 "$temporary"

    generate_candidate > "$temporary"

    #
    # Conservation owner/group.
    #
    if [[ -f "$SNMP_CONF" ]]; then

        chown \
            --reference="$SNMP_CONF" \
            "$temporary" \
            2>/dev/null || true

    fi

    mv "$temporary" "$SNMP_CONF"

    CONFIG_CHANGED=true

    ok "Bloc Centreon appliqué."

}

###############################################################################
# CREATION SNMPv3
###############################################################################

create_v3_user() {

    [[ "$SNMP_VERSION" == "3" ]] || return 0

    command -v net-snmp-create-v3-user >/dev/null 2>&1 ||
        fatal "net-snmp-create-v3-user introuvable."

    #
    # Vérification utilisateur existant.
    #
    if [[ -f "$PERSISTENT_CONF" ]] &&
       grep -Eq \
       "(^|[[:space:]])${SNMP_USER}([[:space:]]|$)" \
       "$PERSISTENT_CONF"; then

        warn "L'utilisateur SNMPv3 '$SNMP_USER' semble déjà exister."

        return 0

    fi

    #
    # Le binaire Net-SNMP peut nécessiter que snmpd soit arrêté.
    #
    if systemctl is-active --quiet "$SNMP_SERVICE"; then

        info "Arrêt temporaire de snmpd pour créer l'utilisateur SNMPv3."

        systemctl stop "$SNMP_SERVICE"

    fi

    #
    # Seul snmpd est arrêté.
    #
    net-snmp-create-v3-user \
        -ro \
        -a "$SNMP_AUTH_PROTO" \
        -x "$SNMP_PRIV_PROTO" \
        -A "$SNMP_AUTH_PASS" \
        -X "$SNMP_PRIV_PASS" \
        "$SNMP_USER"

    SNMPV3_CHANGED=true

    unset SNMP_AUTH_PASS
    unset SNMP_PRIV_PASS

    ok "Utilisateur SNMPv3 créé."

}

###############################################################################
# FIREWALL - VERIFICATION
###############################################################################

firewall_rule_exists() {

    case "$FIREWALL" in

        ufw)

            ufw status 2>/dev/null |
                grep -Eq \
                "161/udp.*${POLLER_IP}"

            ;;

        firewalld)

            firewall-cmd \
                --list-rich-rules \
                2>/dev/null |
                grep -Fq \
                "source address=\"$POLLER_IP\" port port=\"161\" protocol=\"udp\""

            ;;

        *)

            return 1

            ;;

    esac

}

###############################################################################
# FIREWALL - APPLICATION
###############################################################################

apply_firewall() {

    case "$FIREWALL" in

        ufw)

            if firewall_rule_exists; then

                ok "Règle UFW UDP/161 déjà présente."

                return 0

            fi

            info "Ajout règle UFW UDP/161 depuis $POLLER_IP."

            ufw allow \
                from "$POLLER_IP" \
                to any \
                port 161 \
                proto udp

            FIREWALL_CHANGED=true

            ok "Règle UFW ajoutée."

            ;;

        firewalld)

            if firewall_rule_exists; then

                ok "Règle firewalld UDP/161 déjà présente."

                return 0

            fi

            info "Ajout règle firewalld UDP/161 depuis $POLLER_IP."

            firewall-cmd \
                --permanent \
                --add-rich-rule="rule family=\"ipv4\" source address=\"$POLLER_IP\" port port=\"161\" protocol=\"udp\" accept"

            firewall-cmd --reload

            FIREWALL_CHANGED=true

            ok "Règle firewalld ajoutée."

            ;;

        none)

            warn "Aucun firewall local actif."

            ;;

    esac

}

###############################################################################
# SERVICE
###############################################################################

start_or_restart_snmpd() {

    section "SERVICE SNMPD"

    #
    # IMPORTANT :
    # uniquement snmpd.
    #
    if [[ "$SNMP_INITIAL_ACTIVE" == true ]]; then

        info "Redémarrage contrôlé de snmpd."

        systemctl restart "$SNMP_SERVICE"

    else

        info "Démarrage contrôlé de snmpd."

        systemctl start "$SNMP_SERVICE"

    fi

    sleep 2

    if ! systemctl is-active --quiet "$SNMP_SERVICE"; then

        error "snmpd n'est pas actif."

        journalctl \
            -u "$SNMP_SERVICE" \
            -n 50 \
            --no-pager \
            >&2 || true

        return 1

    fi

    ok "snmpd actif."

}

###############################################################################
# VALIDATION SOCKET UDP/161
###############################################################################

validate_snmp_socket() {

    info "Vérification de l'écoute UDP/161..."

    if command -v ss >/dev/null 2>&1; then

        if ss -lun | grep -Eq '(^|[[:space:]])[^ ]*:161([[:space:]]|$)'; then

            ok "snmpd écoute sur UDP/161."

            return 0

        fi

    elif command -v netstat >/dev/null 2>&1; then

        if netstat -lun | grep -Eq '(^|[[:space:]])[^ ]*:161([[:space:]]|$)'; then

            ok "snmpd écoute sur UDP/161."

            return 0

        fi

    else

        warn "ss/netstat absent : socket UDP/161 non vérifié."

        return 0

    fi

    error "Aucun processus n'écoute sur UDP/161."

    return 1

}

###############################################################################
# ETAT SERVICE AU BOOT
###############################################################################

ask_enable_service() {

    #
    # Si déjà activé, rien à faire.
    #
    if [[ "$SNMP_INITIAL_ENABLED" == true ]]; then

        return 0

    fi

    echo
    warn "snmpd était désactivé au démarrage avant l'installation."

    read -r -p \
        "Activer snmpd au démarrage du système ? [y/N] : " answer

    case "${answer,,}" in

        y|yes)

            systemctl enable "$SNMP_SERVICE"

            ok "snmpd activé au démarrage."

            ;;

        *)

            info "snmpd reste désactivé au démarrage."

            ;;

    esac

}

###############################################################################
# ROLLBACK FIREWALL
###############################################################################

rollback_firewall() {

    if [[ "$FIREWALL_CHANGED" != true ]]; then
        return 0
    fi

    info "Annulation de la modification firewall."

    case "$FIREWALL" in

        ufw)

            ufw delete allow \
                from "$POLLER_IP" \
                to any \
                port 161 \
                proto udp \
                >/dev/null 2>&1 || true

            ;;

        firewalld)

            firewall-cmd \
                --permanent \
                --remove-rich-rule="rule family=\"ipv4\" source address=\"$POLLER_IP\" port port=\"161\" protocol=\"udp\" accept" \
                >/dev/null 2>&1 || true

            firewall-cmd \
                --reload \
                >/dev/null 2>&1 || true

            ;;

    esac

    FIREWALL_CHANGED=false

    ok "Modification firewall annulée."

}

###############################################################################
# ROLLBACK COMPLET
###############################################################################

rollback() {

    section "ROLLBACK AUTOMATIQUE"

    #
    # Le rollback doit continuer même si une commande échoue.
    #
    set +e

    ###########################################################################
    # STOP UNIQUEMENT SNMPD
    ###########################################################################

    info "Arrêt de snmpd."

    systemctl stop "$SNMP_SERVICE" \
        >/dev/null 2>&1

    ###########################################################################
    # RESTAURATION CONFIGURATION PRINCIPALE
    ###########################################################################

    if [[ -n "$CONFIG_BACKUP" &&
          -f "$CONFIG_BACKUP" ]]; then

        info "Restauration de $SNMP_CONF."

        cp -a \
            "$CONFIG_BACKUP" \
            "$SNMP_CONF"

        if [[ $? -eq 0 ]]; then

            ok "Configuration snmpd restaurée."

        else

            error "Échec de restauration de $SNMP_CONF."

        fi

    fi

    ###########################################################################
    # RESTAURATION SNMPv3
    ###########################################################################

    if [[ "$SNMP_VERSION" == "3" &&
          -n "$PERSISTENT_BACKUP" &&
          -f "$PERSISTENT_BACKUP" ]]; then

        info "Restauration de $PERSISTENT_CONF."

        cp -a \
            "$PERSISTENT_BACKUP" \
            "$PERSISTENT_CONF"

        if [[ $? -eq 0 ]]; then

            ok "Configuration persistante SNMPv3 restaurée."

        else

            error "Échec de restauration SNMPv3."

        fi

    fi

    ###########################################################################
    # FIREWALL
    ###########################################################################

    rollback_firewall

    ###########################################################################
    # RESTAURATION ETAT ACTIF
    ###########################################################################

    info "Restauration de l'état actif initial de snmpd."

    if [[ "$SNMP_INITIAL_ACTIVE" == true ]]; then

        systemctl start "$SNMP_SERVICE" \
            >/dev/null 2>&1

        if systemctl is-active --quiet "$SNMP_SERVICE"; then

            ok "snmpd était actif avant l'opération : état restauré."

        else

            error "Impossible de restaurer snmpd à l'état actif."

        fi

    else

        systemctl stop "$SNMP_SERVICE" \
            >/dev/null 2>&1

        if ! systemctl is-active --quiet "$SNMP_SERVICE"; then

            ok "snmpd était arrêté avant l'opération : état restauré."

        else

            error "snmpd est toujours actif."

        fi

    fi

    ###########################################################################
    # RESTAURATION ETAT ENABLE
    ###########################################################################

    info "Restauration de l'état enable initial."

    if [[ "$SNMP_INITIAL_ENABLED" == true ]]; then

        systemctl enable "$SNMP_SERVICE" \
            >/dev/null 2>&1

        if systemctl is-enabled --quiet "$SNMP_SERVICE"; then

            ok "snmpd enable restauré : activé."

        else

            error "Impossible de restaurer l'état enable."

        fi

    else

        systemctl disable "$SNMP_SERVICE" \
            >/dev/null 2>&1

        if ! systemctl is-enabled --quiet "$SNMP_SERVICE" 2>/dev/null; then

            ok "snmpd enable restauré : désactivé."

        else

            error "snmpd est toujours enabled."

        fi

    fi

    set -e

    echo
    separator

}

###############################################################################
# VALIDATION SNMPv3 PERSISTANCE
###############################################################################

validate_v3_persistence() {

    [[ "$SNMP_VERSION" == "3" ]] || return 0

    info "Vérification de la configuration persistante SNMPv3."

    if [[ ! -f "$PERSISTENT_CONF" ]]; then

        fatal \
            "Fichier persistant SNMPv3 introuvable : $PERSISTENT_CONF"

    fi

    #
    # Après démarrage de snmpd, createUser ne doit pas rester
    # comme directive plaintext normale dans le fichier persistant.
    #
    if grep -Eq \
        '^[[:space:]]*createUser[[:space:]]+' \
        "$PERSISTENT_CONF"; then

        fatal \
            "Une directive createUser en clair reste dans le fichier persistant."

    fi

    ok "Persistance SNMPv3 vérifiée."

}

###############################################################################
# INSTALLATION
###############################################################################

apply_installation() {

    section "APPLICATION"

    ###########################################################################
    # 1 - BACKUP
    ###########################################################################

    create_backups

    ###########################################################################
    # 2 - SNMPv3 USER
    ###########################################################################

    if [[ "$SNMP_VERSION" == "3" ]]; then

        create_v3_user

    fi

    ###########################################################################
    # 3 - VALIDATION CANDIDATE
    ###########################################################################

    validate_candidate

    ###########################################################################
    # 4 - CONFIGURATION
    ###########################################################################

    apply_main_config

    ###########################################################################
    # 5 - FIREWALL
    ###########################################################################

    apply_firewall

    ###########################################################################
    # 6 - SERVICE
    ###########################################################################

    if ! start_or_restart_snmpd; then

        rollback

        fatal "Impossible de démarrer snmpd."

    fi

    ###########################################################################
    # 7 - SOCKET
    ###########################################################################

    if ! validate_snmp_socket; then

        rollback

        fatal "snmpd est actif mais UDP/161 n'est pas disponible."

    fi

    ###########################################################################
    # 8 - ENABLE
    ###########################################################################

    ask_enable_service

    ###########################################################################
    # 9 - SNMPv3 PERSISTENCE
    ###########################################################################

    if [[ "$SNMP_VERSION" == "3" ]]; then

        validate_v3_persistence

        unset SNMP_AUTH_PASS
        unset SNMP_PRIV_PASS

    fi

    ###########################################################################
    # 10 - SUCCESS
    ###########################################################################

    section "INSTALLATION TERMINÉE"

    ok "Agent SNMP configuré."

    echo
    echo "Résumé :"
    echo
    echo "  OS              : $OS_NAME $OS_VERSION"
    echo "  SNMP            : $SNMP_VERSION"
    echo "  Poller Centreon : $POLLER_IP"
    echo "  Service         : $SNMP_SERVICE"
    echo "  Configuration   : $SNMP_CONF"
    echo "  Firewall        : $FIREWALL"

    echo

    if [[ "$SNMP_VERSION" == "2c" ]]; then

        echo "Test à effectuer depuis le Poller Centreon :"
        echo
        echo "  snmpget -v2c -c '<COMMUNITY>' \\"
        echo "    <IP_SERVEUR> \\"
        echo "    1.3.6.1.2.1.1.3.0"

    else

        echo "Test SNMPv3 à effectuer depuis le Poller Centreon."

    fi

    echo

}

###############################################################################
# MAIN
###############################################################################

main() {

    parse_args

    section "CENTREON SNMP INSTALLER V$VERSION"

    if [[ "$DRY_RUN" == true ]]; then

        echo
        echo "[DRY-RUN] MODE LECTURE SEULE."
        echo "[DRY-RUN] Aucune modification du système ne sera effectuée."
        echo

    fi

    check_root

    acquire_lock

    detect_os

    read_service_state

    check_net_snmp

    detect_persistent_config

    detect_firewall

    ask_configuration

    ###########################################################################
    # HARD DRY-RUN BOUNDARY
    ###########################################################################

    if [[ "$DRY_RUN" == true ]]; then

        dry_run_plan

        exit 0

    fi

    ###########################################################################
    # REAL INSTALLATION
    ###########################################################################

    apply_installation

}

main "$@"
