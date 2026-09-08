#!/usr/bin/env bash

###############################################################################
# CENTREON SNMP AGENT INSTALLER
# Version 5.0.1
#
# Supports:
#   - Rocky / RHEL / AlmaLinux / CentOS / Fedora
#   - Ubuntu / Debian
#   - SNMPv2c
#   - SNMPv3 authPriv
#   - UFW / firewalld
#
# Safety:
#   - Real dry-run
#   - Read-only precheck
#   - Backup before modification
#   - Explicit rollback
#   - Existing configuration preserved
#   - Only snmpd may be stopped/restarted
#   - No third-party service manipulation
###############################################################################

set -Eeuo pipefail

VERSION="5.0.1"

SNMP_CONF="/etc/snmp/snmpd.conf"
SNMP_SERVICE="snmpd"

MANAGED_BEGIN="# BEGIN CENTREON MANAGED BLOCK"
MANAGED_END="# END CENTREON MANAGED BLOCK"

BACKUP_ROOT="/var/backups/centreon-snmp-installer"
LOCK_FILE="/run/centreon-snmp-installer.lock"

DRY_RUN=false

OS_ID=""
OS_NAME=""
OS_VERSION=""
PKG_MANAGER=""

POLLER_IP=""
SNMP_VERSION=""

COMMUNITY=""
SNMP_USER=""
SNMP_AUTH_PROTO=""
SNMP_AUTH_PASS=""
SNMP_PRIV_PROTO=""
SNMP_PRIV_PASS=""

FIREWALL="none"

SNMP_INITIAL_ACTIVE=false
SNMP_INITIAL_ENABLED=false

CONFIG_BACKUP=""
PERSISTENT_BACKUP=""
PERSISTENT_CONF=""

FIREWALL_CHANGED=false
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

  --dry-run    Read-only analysis + proposed plan
  --help       Show help

IMPORTANT:

  --dry-run performs NO:
    - package installation
    - file creation
    - configuration modification
    - firewall modification
    - service stop/start/restart
    - service enable/disable
    - SNMPv3 user creation

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
        fatal "Exécuter avec sudo/root."
    fi

}

###############################################################################
# LOCK
###############################################################################

acquire_lock() {

    #
    # IMPORTANT:
    # dry-run does not create the lock because it must remain
    # completely read-only.
    #
    if [[ "$DRY_RUN" == true ]]; then
        return
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
# OS DETECTION
###############################################################################

detect_os() {

    [[ -r /etc/os-release ]] ||
        fatal "/etc/os-release introuvable."

    # shellcheck disable=SC1091
    source /etc/os-release

    OS_ID="${ID:-unknown}"
    OS_NAME="${NAME:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"

    case "$OS_ID" in

        rocky|rhel|almalinux|centos|fedora)

            if command -v dnf >/dev/null 2>&1; then
                PKG_MANAGER="dnf"
            else
                PKG_MANAGER="yum"
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
# SERVICE STATE
###############################################################################

read_service_state() {

    command -v systemctl >/dev/null 2>&1 ||
        fatal "systemd est requis."

    if systemctl is-active --quiet "$SNMP_SERVICE"; then
        SNMP_INITIAL_ACTIVE=true
    fi

    if systemctl is-enabled --quiet "$SNMP_SERVICE" 2>/dev/null; then
        SNMP_INITIAL_ENABLED=true
    fi

    if [[ "$SNMP_INITIAL_ACTIVE" == true ]]; then
        info "snmpd : actif"
    else
        info "snmpd : arrêté"
    fi

    if [[ "$SNMP_INITIAL_ENABLED" == true ]]; then
        info "snmpd au démarrage : activé"
    else
        info "snmpd au démarrage : désactivé"
    fi

}

###############################################################################
# NET-SNMP
###############################################################################

check_net_snmp() {

    if command -v snmpd >/dev/null 2>&1 &&
       command -v snmpget >/dev/null 2>&1; then

        ok "Net-SNMP installé."
        return 0

    fi

    if [[ "$DRY_RUN" == true ]]; then

        warn "Net-SNMP incomplet."

        if [[ "$PKG_MANAGER" == "apt" ]]; then

            info "[DRY-RUN] Installation prévue :"
            echo "  apt-get install -y snmp snmpd"

        else

            info "[DRY-RUN] Installation prévue :"
            echo "  $PKG_MANAGER install -y net-snmp net-snmp-utils"

        fi

        return 0

    fi

    fatal "Net-SNMP doit être installé avant cette étape."

}

###############################################################################
# PERSISTENT SNMP CONFIG
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

            return

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
# FIREWALL DETECTION
###############################################################################

detect_firewall() {

    FIREWALL="none"

    if command -v firewall-cmd >/dev/null 2>&1 &&
       firewall-cmd --state >/dev/null 2>&1; then

        FIREWALL="firewalld"

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
# IPv4 VALIDATION
###############################################################################

validate_ipv4() {

    local ip="$1"
    local IFS=.

    read -r a b c d <<< "$ip"

    [[ "$a" =~ ^[0-9]+$ ]] &&
    [[ "$b" =~ ^[0-9]+$ ]] &&
    [[ "$c" =~ ^[0-9]+$ ]] &&
    [[ "$d" =~ ^[0-9]+$ ]] &&
    (( a <= 255 && b <= 255 && c <= 255 && d <= 255 ))

}

###############################################################################
# POLLER
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
# SNMPv2c
###############################################################################

ask_v2c() {

    while true; do

        #
        # Community intentionally visible.
        #
        read -r -p "Community SNMPv2c : " COMMUNITY

        if [[ -n "$COMMUNITY" ]]; then
            break
        fi

        warn "Community vide interdite."

    done

}

###############################################################################
# SNMPv3
###############################################################################

ask_v3() {

    read -r -p "Utilisateur SNMPv3 : " SNMP_USER

    [[ "$SNMP_USER" =~ ^[A-Za-z0-9_.-]+$ ]] ||
        fatal "Nom utilisateur SNMPv3 invalide."

    echo
    echo "Authentification :"
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
    echo "Confidentialité :"
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
# CONFIGURATION MENU
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
# MANAGED BLOCK
###############################################################################

build_v2c_block() {

    cat <<EOF
$MANAGED_BEGIN
#
# Managed by Centreon SNMP Installer V$VERSION
# Poller Centreon: $POLLER_IP
#

rocommunity $COMMUNITY $POLLER_IP

$MANAGED_END
EOF

}

build_v3_block() {

    cat <<EOF
$MANAGED_BEGIN
#
# Managed by Centreon SNMP Installer V$VERSION
# Poller Centreon: $POLLER_IP
#

rouser $SNMP_USER authPriv

$MANAGED_END
EOF

}

###############################################################################
# REMOVE ONLY OUR BLOCK
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
# CANDIDATE CONFIG
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
# TRUE DRY-RUN
###############################################################################

dry_run_plan() {

    section "DRY-RUN"

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
        echo "  démarrage boot  : activé"
    else
        echo "  démarrage boot  : désactivé"
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
        echo "  Authentication  : $SNMP_AUTH_PROTO"
        echo "  Privacy         : $SNMP_PRIV_PROTO"
        echo "  Passwords       : ********"

    fi

    echo
    echo "Actions prévues :"

    echo "  [PLAN] Backup de $SNMP_CONF"

    if [[ "$SNMP_VERSION" == "3" ]]; then

        echo "  [PLAN] Backup du fichier persistant SNMPv3"
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

    cp -a "$SNMP_CONF" "$CONFIG_BACKUP"

    ok "Backup : $CONFIG_BACKUP"

    if [[ "$SNMP_VERSION" == "3" &&
          -f "$PERSISTENT_CONF" ]]; then

        PERSISTENT_BACKUP="$BACKUP_ROOT/snmpd-persistent.$timestamp"

        cp -a "$PERSISTENT_CONF" "$PERSISTENT_BACKUP"

        ok "Backup persistant : $PERSISTENT_BACKUP"

    fi

}

###############################################################################
# CONFIG VALIDATION
###############################################################################

validate_candidate_syntax() {

    local candidate

    candidate="$(mktemp)"

    chmod 600 "$candidate"

    generate_candidate > "$candidate"

    #
    # Detect incomplete access directives.
    #
    if grep -nE \
        '^[[:space:]]*(rocommunity|rwcommunity|rouser|rwuser)[[:space:]]*$' \
        "$candidate" >/dev/null 2>&1; then

        rm -f "$candidate"

        fatal "Directive SNMP incomplète."

    fi

    #
    # Verify snmpd command is available.
    #
    command -v snmpd >/dev/null 2>&1 ||
        fatal "snmpd introuvable."

    #
    # -H verifies that snmpd can load its directive database.
    #
    if ! snmpd -H >/dev/null 2>&1; then

        rm -f "$candidate"

        fatal "snmpd ne peut pas charger ses directives."

    fi

    rm -f "$candidate"

    ok "Validation structurelle réussie."

}

###############################################################################
# APPLY MAIN CONFIG
###############################################################################

apply_main_config() {

    local tmp

    tmp="$(mktemp "${SNMP_CONF}.XXXXXX")"

    chmod 600 "$tmp"

    generate_candidate > "$tmp"

    #
    # Preserve owner and group.
    #
    chown --reference="$SNMP_CONF" "$tmp" 2>/dev/null || true

    mv "$tmp" "$SNMP_CONF"

    CONFIG_CHANGED=true

    ok "Bloc Centreon appliqué."

}

###############################################################################
# SNMPv3 USER
###############################################################################

create_v3_user() {

    [[ "$SNMP_VERSION" == "3" ]] || return

    command -v net-snmp-create-v3-user >/dev/null 2>&1 ||
        fatal "net-snmp-create-v3-user introuvable."

    #
    # Existing user detection.
    #
    if [[ -f "$PERSISTENT_CONF" ]] &&
       grep -Eq "(^|[[:space:]])${SNMP_USER}([[:space:]]|$)" \
       "$PERSISTENT_CONF"; then

        warn "L'utilisateur SNMPv3 '$SNMP_USER' semble déjà exister."

        return

    fi

    #
    # The Net-SNMP utility requires the agent to be stopped.
    #
    if systemctl is-active --quiet "$SNMP_SERVICE"; then

        info "Arrêt temporaire de snmpd pour créer l'utilisateur SNMPv3."

        systemctl stop "$SNMP_SERVICE"

    fi

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
# FIREWALL CHECK
###############################################################################

firewall_rule_exists() {

    case "$FIREWALL" in

        ufw)

            ufw status 2>/dev/null |
                grep -Eq "161/udp.*${POLLER_IP}"

            ;;

        firewalld)

            firewall-cmd --list-rich-rules 2>/dev/null |
                grep -Fq \
                "source address=\"$POLLER_IP\" port port=\"161\" protocol=\"udp\""

            ;;

        *)

            return 1

            ;;

    esac

}

###############################################################################
# FIREWALL APPLY
###############################################################################

apply_firewall() {

    case "$FIREWALL" in

        ufw)

            if firewall_rule_exists; then

                ok "Règle UFW déjà présente."

                return

            fi

            info "Autorisation UDP/161 depuis $POLLER_IP."

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

                ok "Règle firewalld déjà présente."

                return

            fi

            info "Autorisation UDP/161 depuis $POLLER_IP."

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
    # ONLY snmpd is touched here.
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
            -n 40 \
            --no-pager >&2 || true

        return 1

    fi

    ok "snmpd actif."

}

###############################################################################
# SERVICE ENABLE
###############################################################################

enable_snmpd_if_required() {

    #
    # IMPORTANT:
    # Do not silently change a pre-existing disabled state.
    #
    if [[ "$SNMP_INITIAL_ENABLED" == true ]]; then

        return

    fi

    warn "snmpd était désactivé au démarrage."

    echo
    read -r -p \
        "Activer snmpd au démarrage du système ? [y/N] : " answer

    case "${answer,,}" in

        y|yes)

            systemctl enable "$SNMP_SERVICE"

            ok "snmpd activé au démarrage."

            ;;

        *)

            info "État de démarrage conservé : désactivé."

            ;;

    esac

}

###############################################################################
# LOCAL SNMPv2c TEST
###############################################################################

test_v2c_local() {

    info "Test local SNMPv2c..."

    local output

    output="$(
        snmpget \
            -v2c \
            -c "$COMMUNITY" \
            -t 2 \
            -r 1 \
            127.0.0.1 \
            1.3.6.1.2.1.1.3.0 \
            2>/dev/null
    )" || {

        warn "Le test local SNMPv2c a échoué."

        return 1

    }

    [[ -n "$output" ]] || return 1

    ok "Agent SNMPv2c répond localement."

}

###############################################################################
# LOCAL SNMPv3 TEST
###############################################################################

test_v3_local() {

    info "Test local SNMPv3..."

    local output

    output="$(
        snmpget \
            -v3 \
            -l authPriv \
            -u "$SNMP_USER" \
            -a "$SNMP_AUTH_PROTO" \
            -A "$SNMP_AUTH_PASS" \
            -x "$SNMP_PRIV_PROTO" \
            -X "$SNMP_PRIV_PASS" \
            -t 2 \
            -r 1 \
            127.0.0.1 \
            1.3.6.1.2.1.1.3.0 \
            2>/dev/null
    )" || {

        warn "Le test local SNMPv3 a échoué."

        return 1

    }

    [[ -n "$output" ]] || return 1

    ok "Agent SNMPv3 répond localement."

}

###############################################################################
# PERSISTENT V3 CHECK
###############################################################################

validate_v3_persistence() {

    [[ "$SNMP_VERSION" == "3" ]] || return

    info "Vérification de la persistance SNMPv3..."

    if [[ ! -f "$PERSISTENT_CONF" ]]; then

        fatal "Fichier persistant SNMPv3 introuvable : $PERSISTENT_CONF"

    fi

    #
    # createUser in plaintext should not remain after snmpd startup.
    #
    if grep -Eq \
        '^[[:space:]]*createUser[[:space:]]+' \
        "$PERSISTENT_CONF"; then

        fatal "Une directive createUser en clair reste dans le fichier persistant."

    fi

    ok "Persistance SNMPv3 vérifiée."

}

###############################################################################
# ROLLBACK FIREWALL
###############################################################################

rollback_firewall() {

    [[ "$FIREWALL_CHANGED" == true ]] || return

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

            firewall-cmd --reload >/dev/null 2>&1 || true

            ;;

    esac

}

###############################################################################
# ROLLBACK
###############################################################################

rollback() {

    section "ROLLBACK AUTOMATIQUE"

    #
    # ONLY snmpd.
    #
    systemctl stop "$SNMP_SERVICE" 2>/dev/null || true

    #
    # Restore main configuration.
    #
    if [[ -n "$CONFIG_BACKUP" &&
          -f "$CONFIG_BACKUP" ]]; then

        cp -a "$CONFIG_BACKUP" "$SNMP_CONF"

        ok "Configuration snmpd restaurée."

    fi

    #
    # Restore persistent V3 configuration.
    #
    if [[ "$SNMP_VERSION" == "3" &&
          -n "$PERSISTENT_BACKUP" &&
          -f "$PERSISTENT_BACKUP" ]]; then

        cp -a "$PERSISTENT_BACKUP" "$PERSISTENT_CONF"

        ok "Configuration persistante SNMPv3 restaurée."

    fi

    rollback_firewall

    #
    # Restore original service state.
    #
    if [[ "$SNMP_INITIAL_ACTIVE" == true ]]; then

        systemctl start "$SNMP_SERVICE" 2>/dev/null || true

    else

        systemctl stop "$SNMP_SERVICE" 2>/dev/null || true

    fi

    if [[ "$SNMP_INITIAL_ENABLED" == true ]]; then

        systemctl enable "$SNMP_SERVICE" \
            >/dev/null 2>&1 || true

    else

        systemctl disable "$SNMP_SERVICE" \
            >/dev/null 2>&1 || true

    fi

    ok "État initial de snmpd restauré."

}

###############################################################################
# REAL INSTALLATION
###############################################################################

apply() {

    section "APPLICATION"

    create_backups

    #
    # SNMPv3 user creation happens before main config modification.
    #
    if [[ "$SNMP_VERSION" == "3" ]]; then

        create_v3_user

    fi

    #
    # Validate candidate before changing main config.
    #
    validate_candidate_syntax

    #
    # Apply only managed block.
    #
    apply_main_config

    #
    # Firewall after configuration preparation.
    #
    apply_firewall

    #
    # Start/restart only snmpd.
    #
    if ! start_or_restart_snmpd; then

        rollback

        fatal "Échec du démarrage de snmpd."

    fi

    #
    # Optional persistent enable.
    #
    enable_snmpd_if_required

    #
    # Functional test.
    #
    if [[ "$SNMP_VERSION" == "2c" ]]; then

        if ! test_v2c_local; then

            rollback

            fatal "Échec du test SNMPv2c."

        fi

    else

        if ! test_v3_local; then

            rollback

            fatal "Échec du test SNMPv3."

        fi

        validate_v3_persistence

        unset SNMP_AUTH_PASS
        unset SNMP_PRIV_PASS

    fi

    section "INSTALLATION TERMINÉE"

    ok "Agent SNMP configuré."

    echo
    echo "Résumé :"
    echo "  Version SNMP : $SNMP_VERSION"
    echo "  Poller       : $POLLER_IP"
    echo "  Service      : $SNMP_SERVICE"
    echo "  Configuration: $SNMP_CONF"
    echo "  Firewall     : $FIREWALL"

    echo

    if [[ "$SNMP_VERSION" == "2c" ]]; then

        echo "Test depuis le Poller Centreon :"
        echo
        echo "  snmpget -v2c -c '<COMMUNITY>' \\"
        echo "    <IP_SERVEUR> 1.3.6.1.2.1.1.3.0"

    else

        echo "Test SNMPv3 depuis le Poller avec les identifiants configurés."

    fi

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

    #
    # HARD DRY-RUN BOUNDARY.
    #
    if [[ "$DRY_RUN" == true ]]; then

        dry_run_plan

        exit 0

    fi

    apply

}

main "$@"
