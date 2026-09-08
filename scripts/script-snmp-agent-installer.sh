```bash
#!/usr/bin/env bash

###############################################################################
# CENTREON SNMP INSTALLER V3
#
# Installation sécurisée de l'agent SNMP pour Centreon.
#
# SUPPORT :
#   - Ubuntu / Debian
#   - RHEL / Rocky / AlmaLinux / CentOS / Fedora
#
# SNMP :
#   - SNMPv2c
#   - SNMPv3 authPriv
#
# CARACTERISTIQUES :
#   - Mode interactif
#   - --dry-run
#   - --yes
#   - Backup automatique
#   - Rollback automatique
#   - Configuration SNMP existante conservée
#   - Configuration Centreon idempotente
#   - Gestion correcte des utilisateurs SNMPv3
#   - UFW / firewalld
#   - Validation avant démarrage
#   - Test SNMP après installation
#   - Aucun service tiers manipulé
#   - Verrou contre exécutions concurrentes
#   - Logs
#
# IMPORTANT :
#   Le script peut arrêter/restart UNIQUEMENT snmpd lorsque nécessaire.
#   Aucun autre service système ou applicatif n'est ciblé.
#
###############################################################################

set -Eeuo pipefail

###############################################################################
# VARIABLES
###############################################################################

SCRIPT_NAME="$(basename "$0")"

SNMP_SERVICE="snmpd"
SNMP_CONF="/etc/snmp/snmpd.conf"

BASE_DIR="/var/lib/centreon-snmp-installer"
BACKUP_DIR="${BASE_DIR}/backups"
LOG_DIR="${BASE_DIR}/logs"

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"

LOG_FILE="${LOG_DIR}/installation_${TIMESTAMP}.log"
LOCK_FILE="/var/run/centreon-snmp-installer.lock"

DRY_RUN="false"
AUTO_APPROVE="false"

OS_ID=""
OS_FAMILY=""

POLLER_IP=""
SNMP_VERSION=""

SNMP_COMMUNITY=""
SNMP_USER=""
SNMP_AUTH_PASS=""
SNMP_PRIV_PASS=""

SNMP_AUTH_PROTO="SHA"
SNMP_PRIV_PROTO="AES"

BACKUP_CONF=""
BACKUP_PERSISTENT=""
PERSISTENT_FILE=""

SNMP_WAS_ACTIVE="false"
SNMP_WAS_ENABLED="false"

CONFIG_CHANGED="false"
FIREWALL_CHANGED="false"
V3_USER_CREATED="false"

TMP_CONFIG=""
TMP_PERSISTENT=""

###############################################################################
# COULEURS
###############################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

###############################################################################
# INITIALISATION
###############################################################################

mkdir -p "$LOG_DIR" "$BACKUP_DIR"

touch "$LOG_FILE"

###############################################################################
# LOG
###############################################################################

log() {
    echo -e "${GREEN}[INFO]${NC} $*" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE" >&2
}

section() {
    echo
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${BLUE}$*${NC}"
    echo -e "${BLUE}============================================================${NC}"
}

###############################################################################
# DRY RUN
###############################################################################

run() {

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] $*" | tee -a "$LOG_FILE"
        return 0
    fi

    "$@"
}

###############################################################################
# CLEANUP
###############################################################################

cleanup() {

    rm -f \
        "$TMP_CONFIG" \
        "$TMP_PERSISTENT" \
        /tmp/centreon-snmp-validation.* \
        /tmp/centreon-snmp-test.* \
        2>/dev/null || true

    rm -f "$LOCK_FILE" 2>/dev/null || true
}

trap cleanup EXIT

###############################################################################
# ROLLBACK
###############################################################################

rollback() {

    [[ "$DRY_RUN" == "true" ]] && return 0

    warn "ROLLBACK : restauration de l'état précédent."

    ###########################################################################
    # RESTAURATION SNMP.CONF
    ###########################################################################

    if [[ -n "${BACKUP_CONF:-}" && -f "$BACKUP_CONF" ]]; then

        log "Restauration de $SNMP_CONF"

        cp -a "$BACKUP_CONF" "$SNMP_CONF"

        chmod 600 "$SNMP_CONF" 2>/dev/null || true
    fi

    ###########################################################################
    # RESTAURATION FICHIER PERSISTANT SNMPV3
    ###########################################################################

    if [[ -n "${BACKUP_PERSISTENT:-}" &&
          -f "$BACKUP_PERSISTENT" &&
          -n "${PERSISTENT_FILE:-}" ]]; then

        log "Restauration du fichier persistant SNMP."

        cp -a "$BACKUP_PERSISTENT" "$PERSISTENT_FILE"

        chmod 600 "$PERSISTENT_FILE" 2>/dev/null || true

    elif [[ "${V3_USER_CREATED:-false}" == "true" &&
            -n "${PERSISTENT_FILE:-}" ]]; then

        warn "Suppression du fichier persistant nouvellement créé."

        rm -f "$PERSISTENT_FILE" 2>/dev/null || true
    fi

    ###########################################################################
    # FIREWALL
    ###########################################################################

    if [[ "$FIREWALL_CHANGED" == "true" ]]; then

        rollback_firewall
    fi

    ###########################################################################
    # SERVICE SNMP UNIQUEMENT
    ###########################################################################

    systemctl restart "$SNMP_SERVICE" \
        >/dev/null 2>&1 || true

    log "Rollback terminé."
}

###############################################################################
# ERREUR
###############################################################################

on_error() {

    local rc=$?

    error "Erreur détectée (code ${rc})."

    rollback

    exit "$rc"
}

trap on_error ERR

###############################################################################
# ARGUMENTS
###############################################################################

parse_arguments() {

    while [[ $# -gt 0 ]]; do

        case "$1" in

            --dry-run)
                DRY_RUN="true"
                ;;

            --yes)
                AUTO_APPROVE="true"
                ;;

            -h|--help)

                cat <<EOF

Centreon SNMP Installer V3

Usage :

  sudo $SCRIPT_NAME

      Installation interactive.

  sudo $SCRIPT_NAME --dry-run

      Simulation sans modification.

  sudo $SCRIPT_NAME --yes

      Installation sans confirmation finale.

  sudo $SCRIPT_NAME --dry-run --yes

      Simulation non interactive.

EOF

                exit 0
                ;;

            *)

                error "Option inconnue : $1"
                exit 2
                ;;

        esac

        shift
    done
}

###############################################################################
# ROOT
###############################################################################

check_root() {

    [[ "$EUID" -eq 0 ]] ||
        {
            error "Ce script doit être exécuté avec sudo/root."
            exit 1
        }
}

###############################################################################
# LOCK
###############################################################################

acquire_lock() {

    if [[ -e "$LOCK_FILE" ]]; then

        error "Une autre installation Centreon SNMP est déjà en cours."

        exit 1
    fi

    if [[ "$DRY_RUN" == "false" ]]; then
        touch "$LOCK_FILE"
    fi
}

###############################################################################
# DETECTION OS
###############################################################################

detect_os() {

    section "Détection du système"

    [[ -f /etc/os-release ]] ||
        {
            error "Impossible de détecter l'OS."
            exit 1
        }

    # shellcheck disable=SC1091
    source /etc/os-release

    OS_ID="${ID:-unknown}"

    case "$OS_ID" in

        ubuntu|debian)
            OS_FAMILY="debian"
            ;;

        rhel|rocky|almalinux|centos|fedora)
            OS_FAMILY="rhel"
            ;;

        *)
            error "OS non supporté : $OS_ID"
            exit 1
            ;;

    esac

    log "OS : $OS_ID"
}

###############################################################################
# INSTALLATION PAQUETS
###############################################################################

install_snmp() {

    section "Installation / vérification SNMP"

    if command -v snmpd >/dev/null 2>&1 &&
       command -v snmpget >/dev/null 2>&1; then

        log "Net-SNMP est déjà installé."

        return 0
    fi

    warn "Net-SNMP n'est pas complètement installé."

    if [[ "$OS_FAMILY" == "debian" ]]; then

        run apt-get update

        run apt-get install -y \
            snmp \
            snmpd

    else

        if command -v dnf >/dev/null 2>&1; then

            run dnf install -y \
                net-snmp \
                net-snmp-utils

        else

            run yum install -y \
                net-snmp \
                net-snmp-utils
        fi

    fi

    command -v snmpd >/dev/null 2>&1 ||
        {
            error "snmpd indisponible."
            exit 1
        }

    command -v snmpget >/dev/null 2>&1 ||
        {
            error "snmpget indisponible."
            exit 1
        }

    log "Net-SNMP disponible."
}

###############################################################################
# OUTIL CREATION V3
###############################################################################

detect_v3_tool() {

    V3_TOOL=""

    if command -v net-snmp-create-v3-user >/dev/null 2>&1; then

        V3_TOOL="$(command -v net-snmp-create-v3-user)"

    elif command -v net-snmp-config >/dev/null 2>&1; then

        if net-snmp-config --help 2>&1 |
            grep -q -- '--create-snmpv3-user'; then

            V3_TOOL="net-snmp-config"
        fi

    fi

    if [[ -z "$V3_TOOL" ]]; then

        warn "Aucun outil natif de création SNMPv3 trouvé."

        if [[ "$SNMP_VERSION" == "2" ]]; then

            error "Impossible de configurer SNMPv3 de manière sûre."
            error "L'outil Net-SNMP de création d'utilisateur est requis."

            exit 1
        fi
    fi

    if [[ -n "$V3_TOOL" ]]; then
        log "Outil SNMPv3 : $V3_TOOL"
    fi
}

###############################################################################
# SERVICE
###############################################################################

check_snmp_service() {

    section "Vérification service snmpd"

    systemctl list-unit-files 2>/dev/null |
        grep -q '^snmpd.service' ||
        {
            error "Le service snmpd est introuvable."
            exit 1
        }

    if systemctl is-active --quiet "$SNMP_SERVICE"; then
        SNMP_WAS_ACTIVE="true"
    fi

    if systemctl is-enabled --quiet "$SNMP_SERVICE" 2>/dev/null; then
        SNMP_WAS_ENABLED="true"
    fi

    log "snmpd détecté."
}

###############################################################################
# DETECTION FICHIER PERSISTANT
###############################################################################

detect_persistent_file() {

    section "Détection du stockage persistant Net-SNMP"

    ###########################################################################
    # Priorité aux fichiers existants
    ###########################################################################

    local candidates=(
        "/var/lib/net-snmp/snmpd.conf"
        "/var/net-snmp/snmpd.conf"
        "/var/lib/snmp/snmpd.conf"
    )

    for candidate in "${candidates[@]}"; do

        if [[ -f "$candidate" ]]; then

            PERSISTENT_FILE="$candidate"

            log "Fichier persistant détecté : $PERSISTENT_FILE"

            return 0
        fi
    done

    ###########################################################################
    # Détection du répertoire configuré
    ###########################################################################

    if [[ -f /etc/snmp/snmpd.conf ]]; then

        local configured_dir

        configured_dir="$(
            grep -E \
                '^[[:space:]]*persistentDir[[:space:]]+' \
                /etc/snmp/snmpd.conf |
            tail -1 |
            awk '{print $2}' || true
        )"

        if [[ -n "$configured_dir" ]]; then

            PERSISTENT_FILE="${configured_dir%/}/snmpd.conf"

            log "Répertoire persistant configuré : $configured_dir"

            return 0
        fi
    fi

    ###########################################################################
    # Défaut Net-SNMP courant
    ###########################################################################

    if [[ "$OS_FAMILY" == "debian" ]]; then

        PERSISTENT_FILE="/var/lib/snmp/snmpd.conf"

    else

        PERSISTENT_FILE="/var/lib/net-snmp/snmpd.conf"

    fi

    log "Fichier persistant estimé : $PERSISTENT_FILE"
}

###############################################################################
# PARAMETRES
###############################################################################

ask_configuration() {

    section "Configuration Centreon"

    while true; do

        read -rp \
            "Adresse IPv4 du Poller Centreon : " \
            POLLER_IP

        if [[ "$POLLER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            break
        fi

        warn "Adresse IPv4 invalide."

    done

    echo
    echo "Protocoles :"
    echo
    echo "  1) SNMPv2c"
    echo "  2) SNMPv3 authPriv"
    echo

    while true; do

        read -rp "Choix [1-2] : " SNMP_VERSION

        case "$SNMP_VERSION" in
            1|2)
                break
                ;;
            *)
                warn "Choix invalide."
                ;;
        esac

    done

    ###########################################################################
    # V2C
    ###########################################################################

    if [[ "$SNMP_VERSION" == "1" ]]; then

        read -rsp \
            "Community SNMPv2c [centreonRO] : " \
            SNMP_COMMUNITY

        echo

        [[ -n "$SNMP_COMMUNITY" ]] ||
            SNMP_COMMUNITY="centreonRO"

        [[ "$SNMP_COMMUNITY" != "public" ]] ||
            {
                error "La communauté 'public' est interdite."
                exit 1
            }

        return 0
    fi

    ###########################################################################
    # V3
    ###########################################################################

    read -rp \
        "Utilisateur SNMPv3 : " \
        SNMP_USER

    [[ "$SNMP_USER" =~ ^[A-Za-z0-9._-]+$ ]] ||
        {
            error "Nom utilisateur SNMPv3 invalide."
            error "Utilisez uniquement lettres, chiffres, '.', '_' ou '-'."
            exit 1
        }

    while true; do

        read -rsp \
            "Mot de passe authentification : " \
            SNMP_AUTH_PASS

        echo

        if [[ ${#SNMP_AUTH_PASS} -ge 8 ]]; then
            break
        fi

        warn "Minimum 8 caractères."

    done

    while true; do

        read -rsp \
            "Mot de passe chiffrement : " \
            SNMP_PRIV_PASS

        echo

        if [[ ${#SNMP_PRIV_PASS} -ge 8 ]]; then
            break
        fi

        warn "Minimum 8 caractères."

    done

    detect_v3_tool
}

###############################################################################
# BACKUP
###############################################################################

backup_configuration() {

    section "Sauvegarde"

    mkdir -p "$BACKUP_DIR"

    ###########################################################################
    # snmpd.conf
    ###########################################################################

    if [[ -f "$SNMP_CONF" ]]; then

        BACKUP_CONF="${BACKUP_DIR}/snmpd.conf.${TIMESTAMP}"

        if [[ "$DRY_RUN" == "true" ]]; then

            log "[DRY-RUN] Backup prévu : $BACKUP_CONF"

        else

            cp -a "$SNMP_CONF" "$BACKUP_CONF"

            chmod 600 "$BACKUP_CONF"

            log "Backup snmpd.conf : $BACKUP_CONF"
        fi

    fi

    ###########################################################################
    # Fichier persistant
    ###########################################################################

    if [[ "$SNMP_VERSION" == "2" &&
          -n "$PERSISTENT_FILE" &&
          -f "$PERSISTENT_FILE" ]]; then

        BACKUP_PERSISTENT="${BACKUP_DIR}/persistent-snmpd.${TIMESTAMP}"

        if [[ "$DRY_RUN" == "true" ]]; then

            log "[DRY-RUN] Backup persistant prévu : $BACKUP_PERSISTENT"

        else

            cp -a "$PERSISTENT_FILE" "$BACKUP_PERSISTENT"

            chmod 600 "$BACKUP_PERSISTENT"

            log "Backup persistant : $BACKUP_PERSISTENT"
        fi
    fi
}

###############################################################################
# CONFIGURATION EXISTANTE
###############################################################################

check_existing_configuration() {

    section "Analyse configuration existante"

    if [[ ! -f "$SNMP_CONF" ]]; then

        log "Aucune configuration SNMP existante."

        return 0
    fi

    log "snmpd.conf existant détecté."

    if grep -Eq \
        '^[[:space:]]*(rocommunity|rwcommunity|rouser|rwuser|com2sec|group|view|access)' \
        "$SNMP_CONF"; then

        warn "Des règles SNMP existantes ont été détectées."
        log "Elles seront conservées."
    fi
}

###############################################################################
# VALIDATION UTILISATEUR V3 EXISTANT
###############################################################################

check_v3_user() {

    [[ "$SNMP_VERSION" == "2" ]] || return 0

    section "Vérification utilisateur SNMPv3"

    ###########################################################################
    # Vérification dans la configuration principale
    ###########################################################################

    if grep -Eq \
        "^[[:space:]]*(rouser|rwuser)[[:space:]]+${SNMP_USER}([[:space:]]|$)" \
        "$SNMP_CONF" 2>/dev/null; then

        warn "L'utilisateur SNMPv3 '$SNMP_USER' possède déjà une autorisation."

        read -rp \
            "Utiliser cet utilisateur existant ? [oui/non] : " \
            answer

        case "$answer" in

            oui|Oui|OUI|o|O)

                SNMP_USER_EXISTS="true"
                return 0
                ;;

            *)

                error "Installation annulée pour éviter une modification inattendue."
                exit 1
                ;;

        esac
    fi

    SNMP_USER_EXISTS="false"
}

###############################################################################
# CONFIGURATION V2C
###############################################################################

build_v2c_configuration() {

    section "Préparation SNMPv2c"

    local current_config=""
    local marker_begin="# BEGIN CENTREON MANAGED BLOCK"
    local marker_end="# END CENTREON MANAGED BLOCK"

    if [[ -f "$SNMP_CONF" ]]; then
        current_config="$(cat "$SNMP_CONF")"
    fi

    current_config="$(
        printf '%s\n' "$current_config" |
        awk '
            /# BEGIN CENTREON MANAGED BLOCK/ {
                skip=1
                next
            }

            /# END CENTREON MANAGED BLOCK/ {
                skip=0
                next
            }

            skip != 1 {
                print
            }
        '
    )"

    NEW_CONFIG="${current_config}

${marker_begin}
# Configuration Centreon
# Générée le : $(date)

rocommunity ${SNMP_COMMUNITY} ${POLLER_IP}

${marker_end}
"

    TMP_CONFIG="/tmp/centreon-snmp-config.${TIMESTAMP}"

    printf '%s\n' "$NEW_CONFIG" > "$TMP_CONFIG"

    chmod 600 "$TMP_CONFIG"
}

###############################################################################
# CONFIGURATION V3 PRINCIPALE
###############################################################################

build_v3_configuration() {

    section "Préparation SNMPv3"

    local current_config=""
    local marker_begin="# BEGIN CENTREON MANAGED BLOCK"
    local marker_end="# END CENTREON MANAGED BLOCK"

    if [[ -f "$SNMP_CONF" ]]; then
        current_config="$(cat "$SNMP_CONF")"
    fi

    current_config="$(
        printf '%s\n' "$current_config" |
        awk '
            /# BEGIN CENTREON MANAGED BLOCK/ {
                skip=1
                next
            }

            /# END CENTREON MANAGED BLOCK/ {
                skip=0
                next
            }

            skip != 1 {
                print
            }
        '
    )"

    NEW_CONFIG="${current_config}

${marker_begin}
# Configuration Centreon SNMPv3
# Générée le : $(date)

rouser ${SNMP_USER} authPriv

${marker_end}
"

    TMP_CONFIG="/tmp/centreon-snmp-config.${TIMESTAMP}"

    printf '%s\n' "$NEW_CONFIG" > "$TMP_CONFIG"

    chmod 600 "$TMP_CONFIG"
}

###############################################################################
# VALIDATION CONFIG
###############################################################################

validate_configuration() {

    section "Validation configuration"

    [[ -s "$TMP_CONFIG" ]] ||
        {
            error "Configuration vide."
            exit 1
        }

    if [[ "$SNMP_VERSION" == "1" ]]; then

        grep -q \
            "^rocommunity ${SNMP_COMMUNITY} ${POLLER_IP}$" \
            "$TMP_CONFIG" ||
            {
                error "Directive SNMPv2c absente."
                exit 1
            }

    else

        grep -q \
            "^rouser ${SNMP_USER} authPriv$" \
            "$TMP_CONFIG" ||
            {
                error "Directive rouser absente."
                exit 1
            }

    fi

    log "Validation structurelle OK."
}

###############################################################################
# CONFIRMATION
###############################################################################

confirm_changes() {

    [[ "$DRY_RUN" == "true" ]] && return 0
    [[ "$AUTO_APPROVE" == "true" ]] && return 0

    section "Confirmation"

    echo
    echo "Le script va :"
    echo
    echo "  - Installer Net-SNMP si nécessaire"
    echo "  - Sauvegarder les configurations"
    echo "  - Conserver la configuration SNMP existante"
    echo "  - Ajouter la configuration Centreon"
    echo "  - Configurer le firewall si nécessaire"
    echo "  - Valider la configuration"
    echo "  - Redémarrer UNIQUEMENT snmpd"
    echo "  - Effectuer un test SNMP"
    echo
    echo "Aucun autre service ne sera arrêté ou redémarré."
    echo

    if [[ "$SNMP_VERSION" == "2" &&
          "${SNMP_USER_EXISTS:-false}" != "true" ]]; then

        echo "SNMPv3 : un nouvel utilisateur sera créé."
        echo "Sécurité : authPriv / SHA / AES"
        echo
    fi

    read -rp "Continuer ? [oui/non] : " answer

    case "$answer" in
        oui|Oui|OUI|o|O)
            ;;
        *)
            error "Installation annulée."
            exit 1
            ;;
    esac
}

###############################################################################
# APPLICATION CONFIG
###############################################################################

apply_configuration() {

    section "Application configuration"

    if [[ "$DRY_RUN" == "true" ]]; then

        echo
        echo "========== DRY-RUN =========="
        echo
        cat "$TMP_CONFIG"
        echo
        echo "=============================="
        echo

        return 0
    fi

    cp -a "$TMP_CONFIG" "$SNMP_CONF"

    chmod 600 "$SNMP_CONF"

    CONFIG_CHANGED="true"

    log "Configuration Centreon appliquée."
}

###############################################################################
# CREATION UTILISATEUR V3
###############################################################################

create_v3_user() {

    [[ "$SNMP_VERSION" == "2" ]] || return 0

    [[ "${SNMP_USER_EXISTS:-false}" == "true" ]] && {

        log "Utilisateur SNMPv3 existant conservé."

        return 0
    }

    section "Création utilisateur SNMPv3"

    if [[ "$DRY_RUN" == "true" ]]; then

        log "[DRY-RUN] Création de l'utilisateur '$SNMP_USER'."

        return 0
    fi

    ###########################################################################
    # L'agent doit être arrêté pour l'outil natif Net-SNMP.
    #
    # IMPORTANT :
    # UNIQUEMENT snmpd est ciblé.
    ###########################################################################

    if systemctl is-active --quiet "$SNMP_SERVICE"; then

        log "Arrêt temporaire de snmpd pour création de l'utilisateur."

        systemctl stop "$SNMP_SERVICE"
    fi

    ###########################################################################
    # OUTIL RHEL / distributions
    ###########################################################################

    if command -v net-snmp-create-v3-user >/dev/null 2>&1; then

        net-snmp-create-v3-user \
            -ro \
            -a "$SNMP_AUTH_PASS" \
            -x "$SNMP_PRIV_PASS" \
            -X AES \
            "$SNMP_USER"

    ###########################################################################
    # net-snmp-config
    ###########################################################################

    elif command -v net-snmp-config >/dev/null 2>&1 &&
         net-snmp-config --help 2>&1 |
         grep -q -- '--create-snmpv3-user'; then

        net-snmp-config \
            --create-snmpv3-user \
            -ro \
            -a "$SNMP_AUTH_PASS" \
            -x "$SNMP_PRIV_PASS" \
            "$SNMP_USER"

    else

        error "Aucun outil de création SNMPv3 disponible."

        exit 1
    fi

    V3_USER_CREATED="true"

    log "Utilisateur SNMPv3 créé."
}

###############################################################################
# VALIDATION V3 PERSISTANTE
###############################################################################

validate_v3_persistent() {

    [[ "$SNMP_VERSION" == "2" ]] || return 0

    section "Validation stockage SNMPv3"

    if [[ "$DRY_RUN" == "true" ]]; then

        log "[DRY-RUN] Vérification du stockage SNMPv3."

        return 0
    fi

    ###########################################################################
    # Le fichier doit exister après création.
    ###########################################################################

    if [[ ! -f "$PERSISTENT_FILE" ]]; then

        warn "Le fichier persistant attendu n'est pas encore présent :"
        warn "$PERSISTENT_FILE"

    else

        chmod 600 "$PERSISTENT_FILE"

        log "Fichier persistant présent."
    fi

    ###########################################################################
    # Vérifier rouser dans snmpd.conf
    ###########################################################################

    grep -Eq \
        "^[[:space:]]*rouser[[:space:]]+${SNMP_USER}[[:space:]]+authPriv" \
        "$SNMP_CONF" ||
        {
            error "L'utilisateur n'est pas autorisé par snmpd.conf."
            exit 1
        }

    log "Autorisation SNMPv3 validée."
}

###############################################################################
# VALIDATION SNMPD
###############################################################################

validate_snmpd() {

    section "Validation de snmpd"

    if [[ "$DRY_RUN" == "true" ]]; then

        log "[DRY-RUN] Validation snmpd prévue."

        return 0
    fi

    local validation_log

    validation_log="/tmp/centreon-snmp-validation.${TIMESTAMP}"

    timeout 5 \
        snmpd \
        -f \
        -Lo \
        -C \
        -c "$SNMP_CONF" \
        >"$validation_log" 2>&1 || true

    if grep -qiE \
        'error|failed|unknown|invalid|cannot' \
        "$validation_log"; then

        cat "$validation_log"

        error "La configuration snmpd est invalide."

        exit 1
    fi

    log "Validation snmpd réussie."
}

###############################################################################
# UFW
###############################################################################

configure_ufw() {

    command -v ufw >/dev/null 2>&1 || return 1

    ufw status 2>/dev/null |
        grep -q "Status: active" || return 0

    section "Firewall UFW"

    if ufw status numbered 2>/dev/null |
        grep -Fq "$POLLER_IP"; then

        log "Une règle existante correspond déjà au Poller."

        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then

        log "[DRY-RUN] UFW : autoriser ${POLLER_IP} -> UDP/161"

    else

        ufw allow \
            from "$POLLER_IP" \
            to any \
            port 161 \
            proto udp

        FIREWALL_CHANGED="true"

        log "Règle UFW ajoutée."
    fi
}

###############################################################################
# FIREWALLD
###############################################################################

configure_firewalld() {

    command -v firewall-cmd >/dev/null 2>&1 || return 1

    firewall-cmd --state >/dev/null 2>&1 || return 0

    section "Firewall firewalld"

    local rule

    rule="rule family='ipv4' source address='${POLLER_IP}' port protocol='udp' port='161' accept"

    if firewall-cmd \
        --permanent \
        --list-rich-rules |
        grep -Fq "$rule"; then

        log "Règle firewalld existante."

        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then

        log "[DRY-RUN] firewalld : autoriser ${POLLER_IP} -> UDP/161"

    else

        firewall-cmd \
            --permanent \
            --add-rich-rule="$rule"

        firewall-cmd --reload

        FIREWALL_CHANGED="true"

        log "Règle firewalld ajoutée."
    fi
}

###############################################################################
# FIREWALL
###############################################################################

configure_firewall() {

    section "Firewall"

    if configure_ufw; then
        return 0
    fi

    if configure_firewalld; then
        return 0
    fi

    warn "Aucun UFW/firewalld actif."

    warn "Vérifier le firewall réseau :"
    warn "Source      : $POLLER_IP"
    warn "Destination : serveur"
    warn "Protocol    : UDP"
    warn "Port        : 161"
}

###############################################################################
# ROLLBACK FIREWALL
###############################################################################

rollback_firewall() {

    warn "Rollback firewall."

    if command -v ufw >/dev/null 2>&1 &&
       ufw status 2>/dev/null |
       grep -q "Status: active"; then

        ufw delete allow \
            from "$POLLER_IP" \
            to any \
            port 161 \
            proto udp \
            >/dev/null 2>&1 || true

    elif command -v firewall-cmd >/dev/null 2>&1 &&
         firewall-cmd --state >/dev/null 2>&1; then

        firewall-cmd \
            --permanent \
            --remove-rich-rule="rule family='ipv4' source address='${POLLER_IP}' port protocol='udp' port='161' accept" \
            >/dev/null 2>&1 || true

        firewall-cmd --reload \
            >/dev/null 2>&1 || true
    fi
}

###############################################################################
# RESTART SNMP
###############################################################################

restart_snmp() {

    section "Démarrage / redémarrage snmpd"

    if [[ "$DRY_RUN" == "true" ]]; then

        log "[DRY-RUN] snmpd serait démarré/restarté."

        return 0
    fi

    ###########################################################################
    # SEUL snmpd EST CIBLE
    ###########################################################################

    systemctl start "$SNMP_SERVICE"

    sleep 2

    if ! systemctl is-active --quiet "$SNMP_SERVICE"; then

        systemctl status "$SNMP_SERVICE" \
            --no-pager || true

        error "snmpd n'est pas opérationnel."

        exit 1
    fi

    log "snmpd opérationnel."
}

###############################################################################
# TEST UDP 161
###############################################################################

verify_port() {

    section "Vérification UDP/161"

    if [[ "$DRY_RUN" == "true" ]]; then

        log "[DRY-RUN] Vérification UDP/161."

        return 0
    fi

    if command -v ss >/dev/null 2>&1; then

        if ss -lun |
            grep -qE '(^|:)161[[:space:]]'; then

            log "UDP/161 est en écoute."

        else

            error "UDP/161 n'est pas en écoute."

            exit 1
        fi
    fi
}

###############################################################################
# TEST SNMP
###############################################################################

test_snmp() {

    section "Test SNMP local"

    if [[ "$DRY_RUN" == "true" ]]; then

        log "[DRY-RUN] Test SNMP ignoré."

        return 0
    fi

    local output

    output="/tmp/centreon-snmp-test.${TIMESTAMP}"

    ###########################################################################
    # V2C
    ###########################################################################

    if [[ "$SNMP_VERSION" == "1" ]]; then

        if snmpget \
            -v2c \
            -c "$SNMP_COMMUNITY" \
            -t 2 \
            -r 1 \
            127.0.0.1 \
            1.3.6.1.2.1.1.1.0 \
            >"$output" 2>&1; then

            log "Test SNMPv2c réussi."

        else

            cat "$output"

            error "Test SNMPv2c échoué."

            exit 1
        fi

    ###########################################################################
    # V3
    ###########################################################################

    else

        if snmpget \
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
            1.3.6.1.2.1.1.1.0 \
            >"$output" 2>&1; then

            log "Test SNMPv3 authPriv réussi."

        else

            cat "$output"

            error "Test SNMPv3 échoué."

            exit 1
        fi
    fi
}

###############################################################################
# RESUME
###############################################################################

summary() {

    section "INSTALLATION TERMINÉE"

    echo
    echo "OS                 : $OS_ID"
    echo "Poller Centreon    : $POLLER_IP"
    echo "Version SNMP       : SNMPv${SNMP_VERSION}c"
    echo "Service            : $SNMP_SERVICE"
    echo "Configuration      : $SNMP_CONF"
    echo "Journal            : $LOG_FILE"

    if [[ -n "$BACKUP_CONF" ]]; then
        echo "Backup config      : $BACKUP_CONF"
    fi

    if [[ -n "$BACKUP_PERSISTENT" ]]; then
        echo "Backup persistant  : $BACKUP_PERSISTENT"
    fi

    echo

    if [[ "$SNMP_VERSION" == "1" ]]; then

        echo "Mode sécurité      : READ ONLY"
        echo "Source autorisée   : $POLLER_IP"

    else

        echo "Mode sécurité      : authPriv"
        echo "Authentification   : SHA"
        echo "Chiffrement        : AES"
        echo "Utilisateur        : $SNMP_USER"
        echo "Stockage persistant: $PERSISTENT_FILE"

    fi

    echo
    echo -e "${GREEN}Agent SNMP prêt pour Centreon.${NC}"
    echo
}

###############################################################################
# MAIN
###############################################################################

main() {

    parse_arguments "$@"

    check_root

    acquire_lock

    section "CENTREON SNMP INSTALLER V3"

    if [[ "$DRY_RUN" == "true" ]]; then

        echo
        echo -e "${YELLOW}MODE DRY-RUN — AUCUNE MODIFICATION${NC}"
        echo
    fi

    detect_os

    install_snmp

    check_snmp_service

    detect_persistent_file

    ask_configuration

    backup_configuration

    check_existing_configuration

    check_v3_user

    ###########################################################################
    # CONFIGURATION
    ###########################################################################

    if [[ "$SNMP_VERSION" == "1" ]]; then

        build_v2c_configuration

    else

        build_v3_configuration

    fi

    validate_configuration

    confirm_changes

    ###########################################################################
    # V3 : création utilisateur AVANT application finale
    ###########################################################################

    if [[ "$SNMP_VERSION" == "2" ]]; then

        create_v3_user

    fi

    ###########################################################################
    # Configuration principale
    ###########################################################################

    apply_configuration

    ###########################################################################
    # Validation V3
    ###########################################################################

    if [[ "$SNMP_VERSION" == "2" ]]; then

        validate_v3_persistent

    fi

    ###########################################################################
    # Validation avant démarrage
    ###########################################################################

    validate_snmpd

    ###########################################################################
    # Firewall
    ###########################################################################

    configure_firewall

    ###########################################################################
    # SNMP
    ###########################################################################

    restart_snmp

    verify_port

    test_snmp

    summary
}

###############################################################################
# EXECUTION
###############################################################################

main "$@"
```
