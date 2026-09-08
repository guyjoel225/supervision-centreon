#!/usr/bin/env bash

###############################################################################
# Centreon SNMP Agent Installer V4
#
# Supports:
#   - Debian / Ubuntu
#   - RHEL / Rocky / AlmaLinux / CentOS / Fedora
#   - SNMPv2c
#   - SNMPv3 authPriv SHA/AES
#   - UFW
#   - firewalld
#
# Safety:
#   - Real dry-run
#   - Backup before modification
#   - Automatic rollback
#   - Idempotent Centreon block
#   - Only snmpd may be stopped/restarted
#   - Existing configuration preserved
###############################################################################

set -Eeuo pipefail

VERSION="4.0.0"

MANAGED_BEGIN="# BEGIN CENTREON MANAGED BLOCK"
MANAGED_END="# END CENTREON MANAGED BLOCK"

LOCK_FILE="/run/centreon-snmp-installer.lock"
BACKUP_DIR="/var/backups/centreon-snmp-installer"

DRY_RUN=false
ROLLBACK_REQUIRED=false

OS=""
PKG_MANAGER=""
SNMP_CONF="/etc/snmp/snmpd.conf"
SNMP_SERVICE="snmpd"

FIREWALL=""
POLLER_IP=""
SNMP_VERSION=""

COMMUNITY=""
SNMP_USER=""
SNMP_AUTH_PROTO=""
SNMP_AUTH_PASS=""
SNMP_PRIV_PROTO=""
SNMP_PRIV_PASS=""

PERSISTENT_CONF=""

SNMP_WAS_ACTIVE=false
SNMP_WAS_ENABLED=false

BACKUP_CONF=""
BACKUP_PERSISTENT=""
FIREWALL_RULE_ADDED=false

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

die() {
    error "$*"
    exit 1
}

separator() {
    printf '%s\n' "============================================================"
}

###############################################################################
# CLEANUP
###############################################################################

cleanup() {
    rm -f "$LOCK_FILE" 2>/dev/null || true

    unset SNMP_AUTH_PASS
    unset SNMP_PRIV_PASS
}

trap cleanup EXIT

###############################################################################
# ROLLBACK
###############################################################################

rollback() {
    local rc=$?

    if [[ "$ROLLBACK_REQUIRED" != true ]]; then
        return "$rc"
    fi

    separator
    warn "ROLLBACK AUTOMATIQUE"

    #
    # Restore snmpd.conf
    #
    if [[ -n "${BACKUP_CONF:-}" && -f "$BACKUP_CONF" ]]; then
        info "Restauration de $SNMP_CONF"

        cp -a "$BACKUP_CONF" "$SNMP_CONF" || \
            error "Impossible de restaurer $SNMP_CONF"
    fi

    #
    # Restore persistent SNMPv3 configuration
    #
    if [[ -n "${BACKUP_PERSISTENT:-}" &&
          -f "$BACKUP_PERSISTENT" &&
          -n "${PERSISTENT_CONF:-}" ]]; then

        info "Restauration de $PERSISTENT_CONF"

        cp -a "$BACKUP_PERSISTENT" "$PERSISTENT_CONF" || \
            error "Impossible de restaurer $PERSISTENT_CONF"
    fi

    #
    # Remove firewall rule only if THIS execution added it
    #
    if [[ "$FIREWALL_RULE_ADDED" == true ]]; then
        remove_firewall_rule || \
            warn "La règle firewall devra être retirée manuellement."
    fi

    #
    # Restart ONLY snmpd.
    #
    if command -v systemctl >/dev/null 2>&1; then

        if [[ "$SNMP_WAS_ACTIVE" == true ]]; then
            info "Restauration de l'état actif de snmpd"
            systemctl start "$SNMP_SERVICE" || \
                error "Impossible de redémarrer snmpd après rollback."
        else
            info "snmpd était arrêté avant l'opération."
            systemctl stop "$SNMP_SERVICE" 2>/dev/null || true
        fi
    fi

    separator

    return "$rc"
}

trap 'rollback' ERR

###############################################################################
# ARGUMENTS
###############################################################################

usage() {
    cat <<EOF

Centreon SNMP Installer V$VERSION

Usage:
    sudo $0 [options]

Options:
    --dry-run       Analyse et affiche le plan sans modifier le système
    --help          Affiche cette aide

Exemples:

    sudo $0

    sudo $0 --dry-run

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
                die "Option inconnue : $1"
                ;;

        esac

    done
}

###############################################################################
# ROOT
###############################################################################

check_root() {

    if [[ "$EUID" -ne 0 ]]; then
        die "Le script doit être exécuté avec sudo/root."
    fi

}

###############################################################################
# LOCK
###############################################################################

acquire_lock() {

    if [[ "$DRY_RUN" == true ]]; then
        return
    fi

    if [[ -e "$LOCK_FILE" ]]; then
        die "Une autre installation Centreon SNMP semble être en cours."
    fi

    (
        umask 077
        touch "$LOCK_FILE"
    )

}

###############################################################################
# OS DETECTION
###############################################################################

detect_os() {

    [[ -f /etc/os-release ]] || die "/etc/os-release introuvable."

    # shellcheck disable=SC1091
    source /etc/os-release

    case "${ID:-}" in

        ubuntu|debian)
            OS="${ID^} ${VERSION_ID:-unknown}"
            PKG_MANAGER="apt"
            ;;

        rhel|rocky|almalinux|centos|fedora)
            OS="${NAME:-RHEL} ${VERSION_ID:-unknown}"

            if command -v dnf >/dev/null 2>&1; then
                PKG_MANAGER="dnf"
            else
                PKG_MANAGER="yum"
            fi
            ;;

        *)
            die "Distribution non supportée : ${ID:-unknown}"
            ;;

    esac

    info "OS détecté : $OS"
    info "Gestionnaire de paquets : $PKG_MANAGER"

}

###############################################################################
# PACKAGE CHECK
###############################################################################

is_package_installed() {

    case "$PKG_MANAGER" in

        apt)
            dpkg-query -W -f='${Status}' "$1" 2>/dev/null |
                grep -q "install ok installed"
            ;;

        dnf|yum)
            rpm -q "$1" >/dev/null 2>&1
            ;;

    esac

}

install_snmp_packages() {

    if command -v snmpd >/dev/null 2>&1 &&
       command -v snmpget >/dev/null 2>&1; then

        ok "Net-SNMP est déjà installé."
        return
    fi

    if [[ "$DRY_RUN" == true ]]; then

        warn "Net-SNMP n'est pas complètement installé."
        info "[DRY-RUN] Installation qui serait effectuée :"

        if [[ "$PKG_MANAGER" == "apt" ]]; then
            printf '  apt-get install -y snmp snmpd\n'
        else
            printf '  %s install -y net-snmp net-snmp-utils\n' "$PKG_MANAGER"
        fi

        return
    fi

    info "Installation de Net-SNMP..."

    case "$PKG_MANAGER" in

        apt)
            DEBIAN_FRONTEND=noninteractive \
                apt-get update
            DEBIAN_FRONTEND=noninteractive \
                apt-get install -y snmp snmpd
            ;;

        dnf|yum)
            "$PKG_MANAGER" install -y net-snmp net-snmp-utils
            ;;

    esac

    command -v snmpd >/dev/null 2>&1 ||
        die "snmpd n'est pas disponible après installation."

    command -v snmpget >/dev/null 2>&1 ||
        die "snmpget n'est pas disponible après installation."

    ok "Net-SNMP installé."

}

###############################################################################
# SERVICE STATE
###############################################################################

detect_service_state() {

    if ! command -v systemctl >/dev/null 2>&1; then
        die "systemd est requis."
    fi

    if systemctl is-active --quiet "$SNMP_SERVICE"; then
        SNMP_WAS_ACTIVE=true
    else
        SNMP_WAS_ACTIVE=false
    fi

    if systemctl is-enabled --quiet "$SNMP_SERVICE" 2>/dev/null; then
        SNMP_WAS_ENABLED=true
    else
        SNMP_WAS_ENABLED=false
    fi

    if [[ "$SNMP_WAS_ACTIVE" == true ]]; then
        info "Service snmpd : actif"
    else
        info "Service snmpd : arrêté"
    fi

}

###############################################################################
# PERSISTENT SNMPV3 CONFIG
###############################################################################

detect_persistent_config() {

    local candidates=(
        "/var/lib/snmp/snmpd.conf"
        "/var/lib/net-snmp/snmpd.conf"
        "/var/net-snmp/snmpd.conf"
    )

    for file in "${candidates[@]}"; do
        if [[ -f "$file" ]]; then
            PERSISTENT_CONF="$file"
            info "Configuration persistante SNMP : $PERSISTENT_CONF"
            return
        fi
    done

    #
    # If none exists, choose the distro-standard location.
    #
    case "$PKG_MANAGER" in
        apt)
            PERSISTENT_CONF="/var/lib/snmp/snmpd.conf"
            ;;
        dnf|yum)
            PERSISTENT_CONF="/var/lib/net-snmp/snmpd.conf"
            ;;
    esac

    info "Fichier persistant SNMP prévu : $PERSISTENT_CONF"

}

###############################################################################
# FIREWALL DETECTION
###############################################################################

detect_firewall() {

    FIREWALL="none"

    if command -v ufw >/dev/null 2>&1 &&
       ufw status 2>/dev/null | grep -q "^Status: active"; then

        FIREWALL="ufw"

    elif command -v firewall-cmd >/dev/null 2>&1 &&
         firewall-cmd --state 2>/dev/null | grep -q "^running"; then

        FIREWALL="firewalld"

    fi

    case "$FIREWALL" in

        ufw)
            info "Firewall détecté : UFW"
            ;;

        firewalld)
            info "Firewall détecté : firewalld"
            ;;

        none)
            warn "Aucun firewall actif détecté."
            ;;

    esac

}

###############################################################################
# INPUT
###############################################################################

ask_configuration() {

    separator
    printf 'CONFIGURATION CENTREON\n'
    separator

    while true; do

        read -r -p "IP du Poller Centreon : " POLLER_IP

        if [[ "$POLLER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            break
        fi

        warn "Adresse IPv4 invalide."

    done

    echo
    echo "Version SNMP :"
    echo "  1) SNMPv2c"
    echo "  2) SNMPv3"

    while true; do

        read -r -p "Choix [1-2] : " choice

        case "$choice" in

            1)
                SNMP_VERSION="2c"
                break
                ;;

            2)
                SNMP_VERSION="3"
                break
                ;;

            *)
                warn "Choix invalide."
                ;;

        esac

    done

    if [[ "$SNMP_VERSION" == "2c" ]]; then

        while true; do

            read -r -s -p "Community SNMPv2c : " COMMUNITY
            echo

            if [[ -n "$COMMUNITY" ]]; then
                break
            fi

            warn "La community ne peut pas être vide."

        done

    else

        read -r -p "Utilisateur SNMPv3 : " SNMP_USER

        [[ -n "$SNMP_USER" ]] ||
            die "Utilisateur SNMPv3 vide."

        echo
        echo "Algorithme d'authentification :"
        echo "  1) SHA"
        echo "  2) SHA-256"
        echo "  3) SHA-512"

        while true; do

            read -r -p "Choix [1-3] : " choice

            case "$choice" in

                1)
                    SNMP_AUTH_PROTO="SHA"
                    break
                    ;;

                2)
                    SNMP_AUTH_PROTO="SHA-256"
                    break
                    ;;

                3)
                    SNMP_AUTH_PROTO="SHA-512"
                    break
                    ;;

                *)
                    warn "Choix invalide."
                    ;;

            esac

        done

        read -r -s -p "Mot de passe authentification : " SNMP_AUTH_PASS
        echo

        [[ ${#SNMP_AUTH_PASS} -ge 8 ]] ||
            die "Le mot de passe d'authentification doit contenir au moins 8 caractères."

        echo
        echo "Algorithme de chiffrement :"
        echo "  1) AES"

        read -r -p "Choix [1] : " choice

        [[ "$choice" == "1" ]] ||
            die "Choix invalide."

        SNMP_PRIV_PROTO="AES"

        read -r -s -p "Mot de passe confidentialité : " SNMP_PRIV_PASS
        echo

        [[ ${#SNMP_PRIV_PASS} -ge 8 ]] ||
            die "Le mot de passe de confidentialité doit contenir au moins 8 caractères."

    fi

}

###############################################################################
# CONFIG BLOCK
###############################################################################

generate_v2c_block() {

    cat <<EOF
$MANAGED_BEGIN
#
# Centreon SNMPv2c
# Poller autorisé : $POLLER_IP
#

rocommunity $COMMUNITY $POLLER_IP

$MANAGED_END
EOF

}

generate_v3_block() {

    cat <<EOF
$MANAGED_BEGIN
#
# Centreon SNMPv3
# Poller autorisé par firewall : $POLLER_IP
#

rouser $SNMP_USER authPriv

$MANAGED_END
EOF

}

###############################################################################
# CONFIG MANIPULATION
###############################################################################

remove_managed_block() {

    awk -v begin="$MANAGED_BEGIN" \
        -v end="$MANAGED_END" '
        $0 == begin { inside=1; next }
        $0 == end   { inside=0; next }
        !inside     { print }
    ' "$SNMP_CONF"

}

build_proposed_config() {

    local block

    if [[ "$SNMP_VERSION" == "2c" ]]; then
        block="$(generate_v2c_block)"
    else
        block="$(generate_v3_block)"
    fi

    {
        remove_managed_block
        printf '\n%s\n' "$block"
    }

}

###############################################################################
# DRY RUN
###############################################################################

show_dry_run_plan() {

    separator
    echo "PLAN DRY-RUN"
    separator

    printf '[DRY-RUN] OS                    : %s\n' "$OS"
    printf '[DRY-RUN] SNMP                  : %s\n' "$SNMP_VERSION"
    printf '[DRY-RUN] Poller Centreon       : %s\n' "$POLLER_IP"
    printf '[DRY-RUN] Configuration         : %s\n' "$SNMP_CONF"
    printf '[DRY-RUN] Firewall              : %s\n' "$FIREWALL"
    printf '[DRY-RUN] Service               : %s\n' "$SNMP_SERVICE"

    echo

    if [[ "$SNMP_VERSION" == "2c" ]]; then
        echo "[DRY-RUN] La community sera configurée en lecture seule."
    else
        echo "[DRY-RUN] Un utilisateur SNMPv3 authPriv sera configuré."
        echo "[DRY-RUN] Le mot de passe ne sera PAS affiché."
    fi

    echo
    echo "[DRY-RUN] Actions qui seraient effectuées :"
    echo
    echo "  1. Sauvegarde de $SNMP_CONF"
    echo "  2. Conservation de la configuration existante"
    echo "  3. Remplacement du bloc Centreon uniquement"
    echo "  4. Validation de la configuration snmpd"
    echo "  5. Configuration du firewall UDP/161 depuis $POLLER_IP"
    echo "  6. Configuration/démarrage de snmpd"
    echo "  7. Test SNMP"
    echo

    if [[ "$SNMP_VERSION" == "3" ]]; then
        echo "  8. Création/validation de l'utilisateur SNMPv3"
        echo "  9. Vérification de la configuration persistante"
    fi

    echo

    separator
    echo "DIFF PROPOSÉ"
    separator

    #
    # No temporary file is created.
    #
    diff -u \
        <(cat "$SNMP_CONF") \
        <(build_proposed_config) || true

    echo

    separator
    echo "DRY-RUN TERMINÉ"
    echo "AUCUNE MODIFICATION EFFECTUÉE"
    separator

}

###############################################################################
# BACKUP
###############################################################################

create_backup() {

    mkdir -p "$BACKUP_DIR"

    local timestamp
    timestamp="$(date '+%Y%m%d_%H%M%S')"

    BACKUP_CONF="$BACKUP_DIR/snmpd.conf.$timestamp"

    cp -a "$SNMP_CONF" "$BACKUP_CONF"

    ok "Backup : $BACKUP_CONF"

}

###############################################################################
# PERSISTENT BACKUP
###############################################################################

backup_persistent_config() {

    if [[ "$SNMP_VERSION" != "3" ]]; then
        return
    fi

    if [[ -f "$PERSISTENT_CONF" ]]; then

        BACKUP_PERSISTENT="$BACKUP_DIR/snmpd-persistent.$(date '+%Y%m%d_%H%M%S')"

        cp -a "$PERSISTENT_CONF" "$BACKUP_PERSISTENT"

        ok "Backup SNMPv3 persistant : $BACKUP_PERSISTENT"

    fi

}

###############################################################################
# WRITE CONFIG
###############################################################################

apply_main_config() {

    local tmp

    tmp="$(mktemp "${SNMP_CONF}.XXXXXX")"

    chmod 600 "$tmp"

    build_proposed_config > "$tmp"

    #
    # Preserve owner/group.
    #
    chown --reference="$SNMP_CONF" "$tmp" 2>/dev/null || true

    mv "$tmp" "$SNMP_CONF"

    ok "Configuration snmpd mise à jour."

}

###############################################################################
# SNMPV3 USER
###############################################################################

create_snmpv3_user() {

    [[ "$SNMP_VERSION" == "3" ]] || return

    #
    # Find native Net-SNMP utility.
    #
    local tool=""

    if command -v net-snmp-create-v3-user >/dev/null 2>&1; then
        tool="net-snmp-create-v3-user"
    elif command -v net-snmp-config >/dev/null 2>&1; then
        tool="net-snmp-config"
    else
        die "Aucun outil de création SNMPv3 Net-SNMP disponible."
    fi

    #
    # Check whether the user already exists.
    #
    if [[ -f "$PERSISTENT_CONF" ]] &&
       grep -Eq "(^|[[:space:]])${SNMP_USER}([[:space:]]|$)" "$PERSISTENT_CONF"; then

        warn "L'utilisateur SNMPv3 '$SNMP_USER' semble déjà exister."

        return
    fi

    info "Création de l'utilisateur SNMPv3..."

    #
    # Net-SNMP requires the agent to be stopped for the native
    # user creation utility on many distributions.
    #
    if systemctl is-active --quiet "$SNMP_SERVICE"; then

        info "Arrêt temporaire de snmpd uniquement."

        systemctl stop "$SNMP_SERVICE"

    fi

    if [[ "$tool" == "net-snmp-create-v3-user" ]]; then

        #
        # The utility handles the persistent SNMPv3 storage.
        #
        net-snmp-create-v3-user \
            -ro \
            -a "$SNMP_AUTH_PROTO" \
            -x "$SNMP_PRIV_PROTO" \
            -A "$SNMP_AUTH_PASS" \
            -X "$SNMP_PRIV_PASS" \
            "$SNMP_USER"

    else

        net-snmp-config \
            --create-snmpv3-user \
            -ro \
            -a "$SNMP_AUTH_PROTO" \
            -x "$SNMP_PRIV_PROTO" \
            -A "$SNMP_AUTH_PASS" \
            -X "$SNMP_PRIV_PASS" \
            "$SNMP_USER"

    fi

    unset SNMP_AUTH_PASS
    unset SNMP_PRIV_PASS

    ok "Utilisateur SNMPv3 créé."

}

###############################################################################
# CONFIG VALIDATION
###############################################################################

validate_config() {

    info "Validation de la configuration snmpd..."

    #
    # Basic structural checks.
    #
    [[ -f "$SNMP_CONF" ]] ||
        die "snmpd.conf absent."

    #
    # Detect obvious syntax problems before touching the firewall/service.
    #
    if grep -nE '^[[:space:]]*(rocommunity|rwcommunity|rouser|rwuser)[[:space:]]*$' \
        "$SNMP_CONF" >/dev/null 2>&1; then

        die "Une directive SNMP incomplète a été détectée."

    fi

    #
    # If snmpd supports -H, use it as a configuration sanity check.
    #
    if snmpd -H >/dev/null 2>&1; then
        ok "snmpd accepte les options de configuration."
    else
        warn "Impossible d'obtenir la liste des directives snmpd."
    fi

    ok "Validation de base réussie."

}

###############################################################################
# FIREWALL
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
                "rule family=\"ipv4\" source address=\"$POLLER_IP\" port port=\"161\" protocol=\"udp\" accept"

            ;;

        none)
            return 1
            ;;

    esac

}

add_firewall_rule() {

    case "$FIREWALL" in

        ufw)

            if firewall_rule_exists; then
                ok "Règle UFW déjà présente."
                return
            fi

            info "Ajout UFW : UDP/161 depuis $POLLER_IP"

            ufw allow from "$POLLER_IP" to any port 161 proto udp

            FIREWALL_RULE_ADDED=true

            ;;

        firewalld)

            if firewall_rule_exists; then
                ok "Règle firewalld déjà présente."
                return
            fi

            info "Ajout firewalld : UDP/161 depuis $POLLER_IP"

            firewall-cmd \
                --permanent \
                --add-rich-rule="rule family=\"ipv4\" source address=\"$POLLER_IP\" port port=\"161\" protocol=\"udp\" accept"

            firewall-cmd --reload

            FIREWALL_RULE_ADDED=true

            ;;

        none)

            warn "Aucun firewall actif : aucune règle ajoutée."
            ;;

    esac

}

remove_firewall_rule() {

    case "$FIREWALL" in

        ufw)

            ufw delete allow \
                from "$POLLER_IP" \
                to any port 161 proto udp \
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
# SERVICE VALIDATION
###############################################################################

validate_with_snmpd() {

    info "Validation réelle de snmpd avant remise en service..."

    #
    # snmpd must be stopped for this isolated foreground validation,
    # otherwise UDP/161 would already be occupied.
    #
    if systemctl is-active --quiet "$SNMP_SERVICE"; then

        info "Arrêt temporaire de snmpd pour validation."

        systemctl stop "$SNMP_SERVICE"

    fi

    local validation_log
    validation_log="$(mktemp)"

    chmod 600 "$validation_log"

    #
    # Start snmpd in foreground only for syntax/runtime validation.
    # It is automatically terminated after 3 seconds.
    #
    set +e

    timeout 3 \
        snmpd \
        -f \
        -Lo \
        -C \
        -c "$SNMP_CONF" \
        >"$validation_log" 2>&1

    local rc=$?

    set -e

    #
    # timeout=124 is expected if snmpd successfully stayed alive.
    #
    if [[ "$rc" -ne 0 && "$rc" -ne 124 ]]; then

        error "Validation snmpd échouée."

        sed \
            -E \
            's/(authPass|privPass|password|community)[^[:space:]]*/\1=REDACTED/Ig' \
            "$validation_log" >&2

        rm -f "$validation_log"

        return 1

    fi

    rm -f "$validation_log"

    ok "Configuration snmpd validée."

}

###############################################################################
# SERVICE START
###############################################################################

start_snmpd() {

    info "Démarrage de snmpd..."

    systemctl start "$SNMP_SERVICE"

    sleep 2

    systemctl is-active --quiet "$SNMP_SERVICE" ||
        die "snmpd ne démarre pas."

    ok "snmpd actif."

}

###############################################################################
# ENABLE SERVICE
###############################################################################

enable_snmpd() {

    #
    # If snmpd was already enabled, nothing changes.
    #
    if [[ "$SNMP_WAS_ENABLED" == true ]]; then
        return
    fi

    #
    # If the package was just installed, enabling it is expected.
    #
    if [[ "$SNMP_WAS_ACTIVE" == false ]]; then

        info "Activation de snmpd au démarrage."

        systemctl enable "$SNMP_SERVICE"

        ok "snmpd activé."

    fi

}

###############################################################################
# LOCAL TEST
###############################################################################

test_snmp_v2c() {

    info "Test SNMPv2c local..."

    local output

    output="$(
        snmpget \
            -v2c \
            -c "$COMMUNITY" \
            -Oqv \
            -t 2 \
            -r 1 \
            127.0.0.1 \
            1.3.6.1.2.1.1.3.0 \
            2>/dev/null
    )" || {
        error "Test SNMPv2c échoué."
        return 1
    }

    [[ -n "$output" ]] ||
        die "SNMPv2c ne retourne aucune valeur."

    ok "SNMPv2c fonctionnel."

}

test_snmp_v3() {

    info "Test SNMPv3..."

    #
    # Credentials are passed only to snmpget.
    # They are never printed.
    #
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
            -Oqv \
            -t 2 \
            -r 1 \
            127.0.0.1 \
            1.3.6.1.2.1.1.3.0 \
            2>/dev/null
    )" || {
        error "Test SNMPv3 échoué."
        return 1
    }

    [[ -n "$output" ]] ||
        die "SNMPv3 ne retourne aucune valeur."

    ok "SNMPv3 fonctionnel."

}

###############################################################################
# V3 PERSISTENT STORAGE CHECK
###############################################################################

validate_v3_persistent_storage() {

    [[ "$SNMP_VERSION" == "3" ]] || return

    info "Vérification du stockage persistant SNMPv3..."

    if [[ ! -f "$PERSISTENT_CONF" ]]; then
        die "Le fichier persistant SNMPv3 est introuvable : $PERSISTENT_CONF"
    fi

    #
    # After snmpd has started, plaintext createUser should no longer
    # remain as a normal configuration directive.
    #
    if grep -Eq '^[[:space:]]*createUser[[:space:]]+' "$PERSISTENT_CONF"; then

        die "Une directive createUser en clair reste dans le fichier persistant."

    fi

    #
    # Confirm that the persistent file contains Net-SNMP USM data.
    #
    if grep -Eq 'usmUser|engineBoots|oldEngineID' "$PERSISTENT_CONF"; then
        ok "Configuration SNMPv3 persistante détectée."
    else
        warn "Le contenu persistant ne permet pas de confirmer automatiquement USM."
    fi

}

###############################################################################
# MAIN APPLY
###############################################################################

apply_configuration() {

    ROLLBACK_REQUIRED=true

    create_backup
    backup_persistent_config

    #
    # For SNMPv3, user creation must happen while snmpd is stopped
    # on installations where the native utility requires it.
    #
    if [[ "$SNMP_VERSION" == "3" ]]; then
        create_snmpv3_user
    fi

    apply_main_config

    validate_config

    #
    # Validate the complete effective agent before firewall/service.
    #
    validate_with_snmpd

    #
    # Only after validation do we modify firewall.
    #
    add_firewall_rule

    start_snmpd

    enable_snmpd

    #
    # Credentials may still be available here for testing.
    #
    if [[ "$SNMP_VERSION" == "2c" ]]; then
        test_snmp_v2c
    else
        test_snmp_v3
        validate_v3_persistent_storage

        unset SNMP_AUTH_PASS
        unset SNMP_PRIV_PASS
    fi

    ROLLBACK_REQUIRED=false

    separator
    ok "INSTALLATION CENTREON SNMP TERMINÉE"
    separator

    echo
    echo "Résumé :"
    echo "  OS             : $OS"
    echo "  SNMP           : $SNMP_VERSION"
    echo "  Poller         : $POLLER_IP"
    echo "  Configuration  : $SNMP_CONF"
    echo "  Firewall       : $FIREWALL"
    echo "  Service        : $SNMP_SERVICE"
    echo

}

###############################################################################
# MAIN
###############################################################################

main() {

    parse_args

    separator
    echo " CENTREON SNMP INSTALLER V$VERSION"
    separator

    if [[ "$DRY_RUN" == true ]]; then
        echo
        echo "[DRY-RUN] AUCUNE MODIFICATION NE SERA EFFECTUÉE."
        echo
    fi

    check_root
    acquire_lock

    detect_os
    detect_service_state

    #
    # Package installation is skipped in dry-run.
    #
    install_snmp_packages

    #
    # Only after Net-SNMP detection.
    #
    detect_persistent_config
    detect_firewall

    ask_configuration

    if [[ "$DRY_RUN" == true ]]; then

        show_dry_run_plan
        exit 0

    fi

    apply_configuration

}

main "$@"
