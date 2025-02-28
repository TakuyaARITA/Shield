#!/bin/bash
############################################
#####   Ericom Shield Installer        #####
#######################################BH###
ES_SETUP_VER="Setup:19.05-2804"

function usage() {
    echo " Usage: $0 [-f|--force] [--autoupdate] [--Dev] [--Staging] [--quickeval] [-v|--version] <version-name> [--list-versions] [--registry] <registry-ip:port> [--no-dist-upgrade] [--help]"
}

#Check if we are root
if ((EUID != 0)); then
    #    sudo su
    usage
    echo " Please run it as Root"
    echo "sudo $0 $@"
    exit
fi
ES_PATH="/usr/local/ericomshield"
ES_BACKUP_PATH="/usr/local/ericomshield/backup"
LOGFILE="$ES_PATH/ericomshield.log"
STACK_NAME=shield
DOCKER_DEFAULT_VERSION="18.03.1"
DOCKER_VERSION=""
DOCKER_VERSION_STRING=""
UPDATE=false
UPDATE_NEED_RESTART=false
UPDATE_NEED_RESTART_TXT="#UNR#"
NOT_FOUND_STR="404: Not Found"
ES_AUTO_UPDATE_FILE="$ES_PATH/.autoupdate"
ES_REPO_FILE="$ES_PATH/ericomshield-repo.sh"
ES_PRE_CHECK_FILE="$ES_PATH/shield-pre-install-check.sh"
ES_YML_FILE="$ES_PATH/docker-compose.yml"
ES_YML_FILE_BAK="$ES_PATH/docker-compose_yml.bak"
ES_VER_FILE="$ES_PATH/shield-version.txt"
ES_VER_FILE_NEW="$ES_PATH/shield-version-new.txt"
ES_VER_FILE_BAK="$ES_PATH/shield-version.bak"
ES_uninstall_FILE="$ES_PATH/uninstall.sh"
EULA_ACCEPTED_FILE="$ES_PATH/.eula_accepted"
ES_MY_IP_FILE="$ES_PATH/.es_ip_address"
ES_BRANCH_FILE="$ES_PATH/.esbranch"
DEV_BRANCH="Dev"
STAGING_BRANCH="Staging"
ES_SHIELD_REGISTRY_FILE="$ES_PATH/.es_registry"
SUCCESS=false

#SHIELD_REGISTRY="127.0.0.1:5000"
SHIELD_REGISTRY=""
DOCKER_USER="ericomshield1"
DOCKER_SECRET="Ericom98765$"
ES_POCKET=false
ES_AUTO_UPDATE=false
ES_FORCE=false
ES_FORCE_SET_IP_ADDRESS=false
ES_RUN_DEPLOY=true
ES_DIST_UPGRADE=true
SWITCHED_TO_MULTINODE=false
NON_INTERACTIVE=false

MIN_RELEASE_MAJOR="16"
MIN_RELEASE_MINOR="04"
REC_RELEASE_MAJOR="16"
REC_RELEASE_MINOR="04"

function check_distrib() {
    if [ -f /etc/os-release ]; then
        # freedesktop.org and systemd
        . /etc/os-release
        OS=$NAME
        VER=$VERSION_ID
    elif type lsb_release >/dev/null 2>&1; then
        # linuxbase.org
        OS=$(lsb_release -si)
        VER=$(lsb_release -sr)
    elif [ -f /etc/lsb-release ]; then
        # For some versions of Debian/Ubuntu without lsb_release command
        . /etc/lsb-release
        OS=$DISTRIB_ID
        VER=$DISTRIB_RELEASE
    elif [ -f /etc/debian_version ]; then
        # Older Debian/Ubuntu/etc.
        OS=Debian
        VER=$(cat /etc/debian_version)
    else
        # Fall back to uname, e.g. "Linux <version>", also works for BSD, etc.
        OS=$(uname -s)
        VER=$(uname -r)
    fi

    case $(uname -m) in
    x86_64)
        BITS=64
        ;;
    i*86)
        BITS=32
        ;;
    *)
        BITS=?
        ;;
    esac

    echo "The OS is a ${BITS}-bit $OS version $VER"

    local MIN_RELEASE_MAJOR="$MIN_RELEASE_MAJOR"
    local MIN_RELEASE_MINOR="$MIN_RELEASE_MINOR"
    local REC_RELEASE_MAJOR="$REC_RELEASE_MAJOR"
    local REC_RELEASE_MINOR="$REC_RELEASE_MINOR"
    local VER_REGEX="([[:digit:]]{2})\.([[:digit:]]{2})"
    local DIST_REGEX='Ubuntu'
    local DIST_S="$OS"
    local VER_S="$VER"

    if ! [[ $DIST_S =~ $DIST_REGEX ]]; then
        DIST_ERROR="Your distribution is \"$DIST_S\" but \"$DIST_REGEX\" is required" >&2
        return 1
    fi

    if [[ $VER_S =~ $VER_REGEX ]]; then
        VER="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
        if ((VER < ${MIN_RELEASE_MAJOR}${MIN_RELEASE_MINOR})); then
            DIST_ERROR="Old $DIST_REGEX version $VER_S is not supported, please use $DIST_REGEX ${MIN_RELEASE_MAJOR}.${MIN_RELEASE_MINOR} or higher"
            return 1
        elif ((VER != ${REC_RELEASE_MAJOR}${REC_RELEASE_MINOR})); then
            # DIST_WARNING="Your $DIST_REGEX release version is $VER_S but version ${REC_RELEASE_MAJOR}.${REC_RELEASE_MINOR} is recommended"
            return 0
        fi
        return 0
    else
        DIST_ERROR="$VER_S doesn't match $VER_REGEX"
        return 1
    fi

    if ((BITS != 64)); then
        DIST_ERROR="A 64-bit OS is required"
    fi
}

function check_inet_connectivity() {
    echo "Checking Internet connectivity using APT..."
    if apt-get update 2>&1 >/dev/null | grep "Failed to fetch"; then
        echo "Some APT repositories cannot be reached"
        return 1
    fi

    echo "OK"

    return 0
}

# Create the Ericom empty dir if necessary
if [ ! -d $ES_PATH ]; then
    mkdir -p $ES_PATH
    chmod 0755 $ES_PATH
fi

if [ ! -d $ES_BACKUP_PATH ]; then
    mkdir -p $ES_BACKUP_PATH
    chmod 0755 $ES_BACKUP_PATH
fi

function log_message() {
    local PREV_RET_CODE=$?
    echo "$@"
    echo "$(LC_ALL=C date): $@" | LC_ALL=C perl -ne 's/\x1b[[()=][;?0-9]*[0-9A-Za-z]?//g;s/\r//g;s/\007//g;print' >>"$LOGFILE"
    if ((PREV_RET_CODE != 0)); then
        return 1
    fi
    return 0
}

function list_versions() {
    ES_repo_versions="https://raw.githubusercontent.com/EricomSoftwareLtd/Shield/master/Setup/Releases.txt"
    echo "Getting $ES_repo_versions"
    curl -s -S -o "Releases.txt" $ES_repo_versions

    if [ ! -f "Releases.txt" ] || [ $(grep -c "$NOT_FOUND_STR" Releases.txt) -ge 1 ]; then
        echo "Error: cannot download Release.txt, exiting"
        exit 1
    fi

    while true; do
        cat Releases.txt | cut -d':' -f1
        read -p "Please select the Release you want to install/update (1-4):" choice
        case "$choice" in
        "1" | "latest")
            echo 'latest'
            OPTION="1)"
            break
            ;;
        "2")
            echo "2."
            OPTION="2)"
            break
            ;;
        "3")
            echo "3."
            OPTION="3)"
            break
            ;;
        "4")
            echo "4."
            OPTION="4)"
            break
            ;;
        *)
            echo "Error: Not a valid option, exiting"
            ;;
        esac
    done
    grep "$OPTION" Releases.txt
    BRANCH=$(grep "$OPTION" Releases.txt | cut -d':' -f2)
    echo "$BRANCH"
}

cd "$ES_PATH" || exit

while [ $# -ne 0 ]; do
    arg="$1"
    case "$arg" in
    -v | -version | --version) # -arg option will be deprecated and replaced by --arg
        shift
        BRANCH="$1"
        ;;
    -dev | --Dev) # -arg option will be deprecated and replaced by --arg
        echo $DEV_BRANCH >"$ES_BRANCH_FILE"
        ES_AUTO_UPDATE=true # ES_AUTO_UPDATE=true for Dev Deployments
        ;;
    -staging | --Staging) # -arg option will be deprecated and replaced by --arg
        echo $STAGING_BRANCH >"$ES_BRANCH_FILE"
        ;;
    --autoupdate | -autoupdate) # -arg option will be deprecated and replaced by --arg
        ES_AUTO_UPDATE=true
        ;;
    -f | --force | -force) # -arg option will be deprecated and replaced by --arg
        ES_FORCE=true
        #echo " " >>$ES_VER_FILE
        if [ -f "$ES_VER_FILE" ]; then
            echo " " >$ES_VER_FILE
        fi
        ;;
    -force-ip-address-selection)
        ES_FORCE_SET_IP_ADDRESS=true
        ;;
    --quickeval | -quickeval) # -arg option will be deprecated and replaced by --arg
        ES_POCKET=true
        echo " Quick Evaluation "
        ;;
    --restart | -restart) # -arg option will be deprecated and replaced by --arg
        UPDATE_NEED_RESTART=true
        echo " Restart will be done during upgrade "
        ;;
    -approve-eula)
        log_message "EULA has been accepted from Command Line"
        date -Iminutes >"$EULA_ACCEPTED_FILE"
        NON_INTERACTIVE=true
        ;;
    --no-deploy | -no-deploy) # -arg option will be deprecated and replaced by --arg
        ES_RUN_DEPLOY=false
        echo "Install Only (No Deploy) "
        ;;
    --list-versions | -list-versions) # -arg option will be deprecated and replaced by --arg
        list_versions
        ;;
    --registry | -registry) # -arg option will be deprecated and replaced by --arg
        shift
        SHIELD_REGISTRY="$1"
        echo $SHIELD_REGISTRY >"$ES_SHIELD_REGISTRY_FILE"
        ;;
    --no-dist-upgrade)
        log_message "Disabling dist-upgrade"
        ES_DIST_UPGRADE=false
        ;;
    #        -help)
    *)
        usage
        exit
        ;;
    esac
    shift
done

if [ -z "$BRANCH" ]; then
    if [ -f "$ES_BRANCH_FILE" ]; then
        BRANCH=$(cat "$ES_BRANCH_FILE")
    else
        BRANCH="master"
    fi
fi

if [ -f "$ES_SHIELD_REGISTRY_FILE" ]; then
    SHIELD_REGISTRY=$(cat "$ES_SHIELD_REGISTRY_FILE")
fi

log_message "Installing version: $BRANCH"

if [ "$ES_AUTO_UPDATE" == true ]; then
    echo "ES_AUTO_UPDATE" >"$ES_AUTO_UPDATE_FILE"
fi

function uninstall_if_installed() {
    local PACKAGE="$1"
    if dpkg -s "$PACKAGE" >/dev/null 2>&1; then
        while read -p "$PACKAGE is installed on the system which conflicts with Shield. Do you want to remove it? " choice; do
            case "$choice" in
            y | Y | "yes" | "YES" | "Yes")
                echo "yes"
                echo "***************     Uninstalling $PACKAGE"
                apt-get purge "$PACKAGE"
                return 0
                ;;
            n | N | "no" | "NO" | "No")
                echo "no"
                echo "$PACKAGE conflicts with Shield, the installation cannot be continued. Exiting..."

                exit 10
                ;;
            *) ;;

            esac
        done

    fi
}

uninstall_if_installed "dnsmasq"
uninstall_if_installed "bind9"
uninstall_if_installed "unbound"

function install_if_not_installed() {
    if ! dpkg -s "$1" >/dev/null 2>&1; then
        echo "***************     Installing $1"
        apt-get --assume-yes -y install "$1"
    fi
}

install_if_not_installed "curl"
install_if_not_installed "uuid-runtime"

function save_my_ip() {
    echo "$MY_IP" >"$ES_MY_IP_FILE"
}

function restore_my_ip() {
    if [ -s "$ES_MY_IP_FILE" ]; then
        MY_IP="$(cat "$ES_MY_IP_FILE" | grep -oP '\d+\.\d+\.\d+\.\d+')"
        if [[ -z $MY_IP ]]; then
            return 1
        else
            return 0
        fi
    fi
    return 1
}

function choose_network_interface() {

    local INTERFACES=($(find /sys/class/net -type l -not -lname '*virtual*' -printf '%f\n'))
    local INTERFACE_ADDRESSES=()
    local OPTIONS=()

    if [ -f "/sys/class/net/bonding_masters" ]; then
        INTERFACES+=($(cat /sys/class/net/bonding_masters))
    fi

    for IFACE in "${INTERFACES[@]}"; do
        local IF_ADDR="$(/sbin/ip address show scope global dev $IFACE | grep -oP '(?<=inet )\d+\.\d+\.\d+\.\d+')"
        if [ ! -z "$IF_ADDR" ]; then
            OPTIONS+=("Name: \"$IFACE\", IP address: $IF_ADDR")
            INTERFACE_ADDRESSES+=("$IF_ADDR")
        fi
    done

    if ((${#OPTIONS[@]} == 0)); then
        log_message "No network interface cards detected. Aborting!"
        exit 1
    elif ((${#OPTIONS[@]} == 1)); then
        local REPLY=1
        log_message "Using ${INTERFACES[$((REPLY - 1))]} with address ${INTERFACE_ADDRESSES[$((REPLY - 1))]} as an interface for Shield"
        MY_IP="${INTERFACE_ADDRESSES[$((REPLY - 1))]}"
        return
    fi

    echo "Choose a network card to be used by Shield"
    PS3="Enter your choice: "
    select opt in "${OPTIONS[@]}" "Quit"; do

        case "$REPLY" in

        [1-$((${#OPTIONS[@]}))]*)
            log_message "Using ${INTERFACES[$((REPLY - 1))]} with address ${INTERFACE_ADDRESSES[$((REPLY - 1))]} as an interface for Shield"
            MY_IP="${INTERFACE_ADDRESSES[$((REPLY - 1))]}"
            return
            ;;
        $((${#OPTIONS[@]} + 1)))
            break
            ;;
        *)
            echo "Invalid option. Try another one."
            continue
            ;;
        esac
    done

    failed_to_install "Aborting installation!"
}

function failed_to_install() {
    log_message "An error occurred during the installation: $1, exiting"
    exit 1
}

function failed_to_install_cleaner() {
    log_message "An error occurred during the installation: $1, Exiting"
    if [ "$UPDATE" == true ]; then
        if [ -f "$ES_VER_FILE" ]; then
            mv "$ES_VER_FILE_BAK" "$ES_VER_FILE"
        fi
    else
        if [ -f "$ES_VER_FILE" ]; then
            rm -f "$ES_VER_FILE"
        fi
    fi
    exit 1
}

function accept_license() {
    export LESSSECURE=1
    while less -P"%pb\% Press h for help or q to quit" "$1" &&
        read -p "Do you accept the EULA (yes/no/anything else to display it again)? " choice; do
        case "$choice" in
        y | Y | n | N)
            echo 'Please, type "yes" or "no"'
            read -n1 -r -p "Press any key to continue..." key
            ;;
        "yes" | "YES" | "Yes")
            echo "yes"
            return 0
            ;;
        "no" | "NO" | "No")
            echo "no"
            break
            ;;
        *) ;;

        esac
    done

    return -1
}

function update_ubuntu() {
    local UBUNTU_VER_FILE="/etc/lsb-release"
    if [ -r "$UBUNTU_VER_FILE" ]; then
        source "$UBUNTU_VER_FILE"

        apt-get -qq update
        apt-get -y install software-properties-common || failed_to_install "Failed to install software-properties-common. Exiting"
        add-apt-repository universe
        apt-get -qq update
        DEBIAN_FRONTEND='noninteractive' apt-get -y -o 'Dpkg::Options::=--force-confdef' -o 'Dpkg::Options::=--force-confold' dist-upgrade || failed_to_install "Failed to perform dist-upgrade. Exiting"

        if [ $DISTRIB_CODENAME = "xenial" ]; then
            apt-get -y install --install-recommends linux-generic-hwe-16.04
        fi

        apt-get -y autoremove
    else
        failed_to_install "Failed to update Ubuntu: $UBUNTU_VER_FILE is not readable. Exiting"
    fi
}

function install_docker() {

    if [ -f "$ES_VER_FILE" ]; then
        DOCKER_VERSION="$(grep -r 'docker-version' "$ES_VER_FILE" | cut -d' ' -f2)"
        DOCKER_VERSION_STRING="$(grep -r 'docker-version' "$ES_VER_FILE" | cut -d' ' -f3)"
    fi
    if [ "$DOCKER_VERSION" = "" ]; then
        DOCKER_VERSION="$DOCKER_DEFAULT_VERSION"
        echo "Using default Docker version: $DOCKER_VERSION"
    fi

    if [ ! -x /usr/bin/docker ] || [ "$(docker version | grep -c $DOCKER_VERSION)" -le 1 ]; then
        log_message "***************     Installing docker-engine: $DOCKER_VERSION"
        apt-get -y install apt-transport-https software-properties-common

        #Docker Installation of a specific Version
        curl -fsSL https://download.docker.com/linux/debian/gpg | apt-key add -
        add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
        echo -n "apt-get -qq update ..."
        apt-get -qq update
        echo "done"
        #Stop shield (if running)
        if [ "$ES_RUN_DEPLOY" == true ] && [ -x "/usr/bin/docker" ]; then
            log_message "Stopping docker on local machine"
            systemctl stop docker
        fi

        apt-cache policy docker-ce
        echo "Installing Docker: docker-ce=$DOCKER_VERSION*"
        if [ "$DOCKER_VERSION_STRING" = "" ]; then
            apt-get -y --allow-change-held-packages --allow-downgrades install "docker-ce=$DOCKER_VERSION*" && apt-mark hold docker-ce
        else
            apt-get -y --allow-change-held-packages --allow-downgrades install "docker-ce=$DOCKER_VERSION_STRING" "docker-ce-cli=$DOCKER_VERSION_STRING" containerd.io && apt-mark hold docker-ce
        fi
        sleep 5
        systemctl restart docker
        sleep 5
    else
        echo " ******* docker-engine $DOCKER_VERSION is already installed"
    fi
    if [ ! -x /usr/bin/docker ]; then
        failed_to_install "Failed to Install/Update Docker, exiting"
    fi
    if [ "$(docker version | grep -c $DOCKER_VERSION)" -le 1 ]; then
        log_message "Warning, Failed to Update Docker Version to: $DOCKER_VERSION"
    fi
}

function docker_login() {
    if [ "$(docker info | grep -c Username)" -eq 0 ]; then
        if [ "$DOCKER_USER" == " " ]; then
            echo " Please enter your login credentials to docker-hub"
            docker login
        else
            #Login and enter the credentials you received separately when prompt
            echo "docker login" $DOCKER_USER $DOCKER_SECRET
            echo "$DOCKER_SECRET" | docker login --username=$DOCKER_USER --password-stdin
        fi

        if [ $? == 0 ]; then
            echo "Login Succeeded!"
        else
            failed_to_install_cleaner "Cannot Login to docker, exiting"
        fi
    fi
}

function update_sysctl() {
    #check if file was not updated
    curl -s -S -o "${ES_PATH}/sysctl_shield.conf" "${ES_repo_sysctl_shield_conf}"
    # append sysctl with our settings
    cat "${ES_PATH}/sysctl_shield.conf" >"/etc/sysctl.d/30-ericom-shield.conf"
    #to apply the changes:
    sysctl --load="/etc/sysctl.d/30-ericom-shield.conf" >/dev/null 2>&1
    echo "file /etc/sysctl.d/30-ericom-shield.conf Updated!"
}

function create_shield_service() {
    echo "**************  Creating the ericomshield updater service..."
    if [ ! -f "${ES_PATH}/ericomshield-updater.service" ]; then
        # Need to download the service file only if needed and reload only if changed
        curl -s -S -o "${ES_PATH}/ericomshield-updater.service" "${ES_repo_systemd_updater_service}"
        systemctl link ${ES_PATH}/ericomshield-updater.service
        systemctl --system enable ${ES_PATH}/ericomshield-updater.service
        systemctl daemon-reload
    fi
    echo "Done!"
}

function check_shield_service_exists() {
    SHIELD_SERVICE_STATUS=$(systemctl show -p LoadState ericomshield-updater.service | sed 's/LoadState=//g')
    if [[ $SHIELD_SERVICE_STATUS == "not-found" && -f "$ES_PATH/ericomshield-updater.service" ]]; then
        rm -f "$ES_PATH/ericomshield-updater.service"
    fi
}

function add_aliases() {
    if [ -f ~/.bashrc ] && [ $(grep -c 'shield_aliases' ~/.bashrc) -eq 0 ]; then
        echo 'Adding Aliases in .bashrc'
        echo "" >>~/.bashrc
        echo "# EricomShield aliases" >>~/.bashrc
        echo "if [ -f ~/.shield_aliases ]; then" >>~/.bashrc
        echo ". ~/.shield_aliases" >>~/.bashrc
        echo "fi" >>~/.bashrc
    fi
    . ~/.bashrc
}

function prepare_yml() {
    echo "Preparing yml file (Containers build number)"
    while read -r ver; do
        if [ "${ver:0:1}" == '#' ]; then
            echo "$ver"
        else
            pattern_ver=$(echo "$ver" | awk '{print $1}')
            comp_ver=$(echo "$ver" | awk '{print $2}')
            if [ ! -z "$pattern_ver" ]; then
                #echo "Changing ver: $comp_ver"
                sed -i'' "s/$pattern_ver/$comp_ver/g" $ES_YML_FILE
            fi
        fi
    done <"$ES_VER_FILE"
    if [ ! -z "$SHIELD_REGISTRY" ]; then
        sed -i'' "s/securebrowsing/$SHIELD_REGISTRY\/securebrowsing/g" $ES_YML_FILE
    fi

    local TZ="$( (test -r /etc/timezone && cat /etc/timezone) || echo UTC)"
    sed -i'' "s#TZ=UTC#TZ=${TZ}#g" $ES_YML_FILE
}

function switch_to_multi_node() {
    if [ $(grep -c '#[[:space:]]*mode: global[[:space:]]*#multi node' $ES_YML_FILE) -eq 1 ]; then
        echo "Switching to Multi-Node (consul-server -> global)"
        sed -i'' 's/\(mode: replicated[[:space:]]*#single node\)/#\1/g' $ES_YML_FILE
        sed -i'' 's/\(replicas: 5[[:space:]]*#single node\)/#\1/g' $ES_YML_FILE
        sed -i'' 's/#\([[:space:]]*mode: global[[:space:]]*#multi node\)/\1/g' $ES_YML_FILE
        SWITCHED_TO_MULTINODE=true
    fi
}

function get_precheck_files() {
    echo "Getting $ES_REPO_FILE"
    ES_repo_setup="https://raw.githubusercontent.com/EricomSoftwareLtd/Shield/$BRANCH/Setup/ericomshield-repo.sh"
    curl -s -S -o "shield_repo_tmp.sh" $ES_repo_setup
    if [ ! -f shield_repo_tmp.sh ] || [ $(grep -c "$NOT_FOUND_STR" shield_repo_tmp.sh) -ge 1 ]; then
        failed_to_install "Cannot Retrieve Installation files for version: $BRANCH"
    fi
    #Set Branch File, after validation:
    echo $BRANCH >"$ES_BRANCH_FILE"
    mv shield_repo_tmp.sh "$ES_REPO_FILE"

    #include file with files repository
    source $ES_REPO_FILE

    echo "Getting $ES_PRE_CHECK_FILE"
    curl -s -S -o "$ES_PRE_CHECK_FILE" "$ES_repo_pre_check"
    chmod +x "$ES_PRE_CHECK_FILE"
}

function get_shield_install_files() {
    echo "Getting shield install files"

    if [ ! -f "$ES_VER_FILE_NEW" ]; then
        echo "Getting $ES_repo_ver"
        curl -s -S -o "$ES_VER_FILE_NEW" "$ES_repo_ver"
    fi

    SHIELD_VERSION=$(grep -r 'SHIELD_VER' "$ES_VER_FILE_NEW" | cut -d' ' -f2)
    if [ -f "$ES_VER_FILE" ]; then
        if [ "$(diff "$ES_VER_FILE" "$ES_VER_FILE_NEW" | wc -l)" -eq 0 ]; then
            echo "Your EricomShield System is Up to date ($SHIELD_VERSION)"
            exit 0
        else
            SHIELD_CUR_VERSION=$(grep -r 'SHIELD_VER' "$ES_VER_FILE" | cut -d' ' -f2)
            echo "***************     Updating EricomShield ($SHIELD_CUR_VERSION) to ($SHIELD_VERSION)"
            echo "$(date): New version found:  Updating EricomShield ($SHIELD_CUR_VERSION) to ($SHIELD_VERSION)" >>"$LOGFILE"
            UPDATE=true
            mv "$ES_VER_FILE" "$ES_VER_FILE_BAK"
            if [ $(grep -c "$UPDATE_NEED_RESTART_TXT" "$ES_VER_FILE_NEW") -eq 1 ]; then
                UPDATE_NEED_RESTART=true
            fi
        fi
    else
        echo "***************     Installing EricomShield ($SHIELD_VERSION)..."
        echo "$(date): Installing EricomShield ($SHIELD_VERSION)" >>"$LOGFILE"
    fi
    mv "$ES_VER_FILE_NEW" "$ES_VER_FILE"

    echo "Getting $ES_YML_FILE"
    if [ -f "$ES_YML_FILE" ]; then
        mv "$ES_YML_FILE" "$ES_YML_FILE_BAK"
    fi
    curl -s -S -o "$ES_YML_FILE" "$ES_repo_yml"

    if [ $ES_POCKET == true ]; then
        echo "Getting $ES_repo_pocket_yml"
        curl -s -S -o "$ES_YML_FILE" "$ES_repo_pocket_yml"
    fi
    curl -s -S -o deploy-shield.sh "$ES_repo_swarm_sh"
    chmod +x deploy-shield.sh
}

function pull_images() {
    if [ -f "$ES_VER_FILE_BAK" ] && [ "$(diff "$ES_VER_FILE" "$ES_VER_FILE_BAK" | wc -l)" -eq 0 ]; then
        echo "No new version detected"
        return
    fi
    LINE=0
    while read -r line; do
        if [ "${line:0:1}" == '#' ]; then
            echo "$line"
        else
            arr=($line)
            if [ $LINE -ge 3 ]; then
                echo "################## Pulling images  ######################"
                echo "pulling image: ${arr[1]} ($SHIELD_REGISTRY)"
                if [ ! -z "$SHIELD_REGISTRY" ]; then
                    IMAGE_NAME="$SHIELD_REGISTRY/securebrowsing/${arr[1]}"
                else
                    docker pull "securebrowsing/${arr[1]}"
                fi
            fi
        fi
        LINE=$((LINE + 1))
    done <"$ES_VER_FILE"
}

#############     Getting all files from Github
function get_shield_files() {
    #Get ericomshield-setup only if not present in the ericomshield folder
    if [ ! -f "ericomshield-setup.sh" ]; then
        curl -s -S -o ericomshield-setup.sh $ES_repo_setup
        chmod +x ericomshield-setup.sh
    fi

    if [ ! $0 == "autoupdate.sh" ]; then
        curl -s -S -o autoupdate.sh "$ES_repo_autoupdate"
        chmod +x autoupdate.sh
    fi

    echo "Getting Shield Scripts"
    curl -s -S -o "$ES_uninstall_FILE" "$ES_repo_uninstall"
    chmod +x "$ES_uninstall_FILE"
    curl -s -S -o start.sh "$ES_repo_start"
    chmod +x start.sh
    curl -s -S -o showversion.sh "$ES_repo_version"
    chmod +x showversion.sh
    curl -s -S -o stop.sh "$ES_repo_stop"
    chmod +x stop.sh
    curl -s -S -o status.sh "$ES_repo_status"
    chmod +x status.sh
    curl -s -S -o restart.sh "$ES_repo_restart"
    chmod +x restart.sh
    curl -s -S -o ~/show-my-ip.sh "$ES_repo_ip"
    chmod +x ~/show-my-ip.sh
    cp ~/show-my-ip.sh "$ES_PATH/show-my-ip.sh"
    curl -s -S -o addnodes.sh "$ES_repo_addnodes"
    chmod +x addnodes.sh
    curl -s -S -o addnodes.py "$ES_repo_addnodespy"
    curl -s -S -o nodes.sh "$ES_repo_shield_nodes"
    chmod +x nodes.sh
    curl -s -S -o ~/.shield_aliases "$ES_repo_shield_aliases"
    curl -s -S -o restore.sh "$ES_repo_restore"
    chmod +x restore.sh
    curl -s -S -o update.sh "$ES_repo_update"
    chmod +x update.sh
    curl -s -S -o prepare-node.sh "$ES_repo_preparenode"
    chmod +x prepare-node.sh
    curl -s -S -o spellcheck.sh "$ES_repo_spellcheck"
    chmod +x spellcheck.sh
}

function count_running_docker_services() {
    services=($(docker service ls --format "{{.Replicas}}" | awk 'BEGIN {FS = "/"; sum=0}; {d=$2-$1; sum+=d>0?d:-d} END {print sum}'))

    if ! [[ $? ]]; then
        log_message "Could not list services. Is Docker running?"
        return 1
    fi
    return 0
}

function wait_for_docker_to_settle() {
    local wait_count=0
    count_running_docker_services
    while ((services != 0)) && ((wait_count < 12)); do
        if [ $wait_count == 0 ]; then
            log_message "Not all services have reached their target scale. Waiting for Docker to settle..."
        fi

        echo -n .
        sleep 10
        wait_count=$((wait_count + 1))
        count_running_docker_services
    done
}

function test_swarm_exists() {
    echo $(docker info | grep -i 'swarm: active')
}

function am_i_leader() {
    AM_I_LEADER=$(docker node inspect $(hostname) --format "{{ .ManagerStatus.Leader }}" | grep "true")
}

function check_registry() {
    if [ ! -z $SHIELD_REGISTRY ]; then
        log_message "Testing the registry..."
        if ! docker run --rm "$SHIELD_REGISTRY/library/alpine:latest" "/bin/true"; then
            log_message "Registry test failed"
            return 1
        else
            log_message "Registry test OK"
        fi
    fi

    return 0
}

function update_daemon_json() {
    if [ ! -z $SHIELD_REGISTRY ]; then
        if [ -f /etc/docker/daemon.json ] && [ $(grep -c 'regist' /etc/docker/daemon.json) -ge 1 ]; then
            echo '/etc/docker/daemon.json is ok'
        else
            echo "Setting: insecure-registries:[$SHIELD_REGISTRY] in /etc/docker/daemon.json"
            echo '{' >/etc/docker/daemon.json.shield
            echo -n '  "insecure-registries":["' >>/etc/docker/daemon.json.shield
            echo -n $SHIELD_REGISTRY >>/etc/docker/daemon.json.shield
            echo '"]' >>/etc/docker/daemon.json.shield
            echo '}' >>/etc/docker/daemon.json.shield
            systemctl stop docker
            sleep 10
            mv /etc/docker/daemon.json.shield /etc/docker/daemon.json
            systemctl start docker
        fi
    fi
}

##################      MAIN: EVERYTHING STARTS HERE: ##########################

log_message "***************     EricomShield Setup ($ES_SETUP_VER) $BRANCH ..."

if [ "$ES_FORCE" == false ]; then
    echo "***************     Running pre-install-check (1) ..."
    check_distrib
    if [ -n "$DIST_ERROR" ]; then
        failed_to_install "$DIST_ERROR"
        exit 1
    elif [ -n "$DIST_WARNING" ]; then
        echo "$DIST_WARNING"
    fi
    if [ ! check_inet_connectivity ]; then
        failed_to_install "Internet connectivity problem detected, exiting..."
        exit 1
    fi
fi

if [ "$ES_RUN_DEPLOY" == true ]; then
    if ! restore_my_ip || [[ $ES_FORCE_SET_IP_ADDRESS == true ]]; then
        choose_network_interface
    fi
    save_my_ip
fi

echo Docker Login: $DOCKER_USER
echo "autoupdate=$ES_AUTO_UPDATE"

#Get first shield install files (shield-version.txt) which is used also to install docker specific version
get_precheck_files

get_shield_install_files

if [ "$ES_DIST_UPGRADE" = true ]; then
    update_ubuntu
fi
install_docker

update_daemon_json

if systemctl start docker; then
    echo "Starting docker service ***************     Success!"
else
    failed_to_install "Failed to start docker service"
fi

docker_login

if ! check_registry; then
    log_message "Using Docker Hub instead of local registry at $SHIELD_REGISTRY"
    SHIELD_REGISTRY=""
    while read -p "Do you want to proceed (Yes/No)? " choice; do
        case "$choice" in
        y | Y | "yes" | "YES" | "Yes")
            echo "yes"
            break
            ;;
        n | N | "no" | "NO" | "No")
            echo "no"
            echo "Exiting..."
            exit 10
            ;;
        *) ;;

        esac
    done
fi

curl -s -S -o "$ES_PATH/Ericom-EULA.txt" "$ES_repo_EULA"
if [ "$UPDATE" == false ] && [ ! -f "$EULA_ACCEPTED_FILE" ] && [ "$ES_RUN_DEPLOY" == true ]; then
    echo 'You will now be presented with the End User License Agreement.'
    echo 'Use PgUp/PgDn/Arrow keys for navigation, q to exit.'
    echo 'Please, read the EULA carefully, then accept it to continue the installation process or reject to exit.'
    read -n1 -r -p "Press any key to continue..." key
    echo

    if accept_license "$ES_PATH/Ericom-EULA.txt"; then
        log_message "EULA has been accepted"
        date -Iminutes >"$EULA_ACCEPTED_FILE"
    else
        failed_to_install_cleaner "EULA has not been accepted, exiting..."
    fi
fi

if [ "$ES_FORCE" == false ]; then
    source $ES_PRE_CHECK_FILE
    echo "***************     Running pre-install-check ..."
    perform_env_test
    if [ "$?" -ne "0" ]; then
        failed_to_install_cleaner "Shield pre-install-check failed!"
    fi
fi

add_aliases

get_shield_files

update_sysctl

if [ "$NON_INTERACTIVE" == false ]; then
    ./prepare-node.sh
fi

prepare_yml

if [ "$UPDATE" == false ]; then
    AM_I_LEADER=true #if new installation, i am the leader
    # New Installation
    create_shield_service
    echo "pull images" #before starting the system
    pull_images

else # Update
    check_shield_service_exists
    if [ "$SHIELD_SERVICE_STATUS" = "not-found" ]; then
        create_shield_service
    fi

    STOP_SHIELD=false
    SWARM=$(test_swarm_exists)
    if [ ! -z "$SWARM" ]; then
        am_i_leader
        MNG_NODES_COUNT=$(docker node ls -f "role=manager" | grep -c Ready)
        CONSUL_GLOBAL=$(docker service ls | grep -c "consul-server    global")
        if [ "$MNG_NODES_COUNT" -gt 1 ]; then
            switch_to_multi_node
            if [ "$CONSUL_GLOBAL" -ne 1 ]; then
                if [ "$AM_I_LEADER" == true ]; then
                    STOP_SHIELD=true
                fi
            fi
        fi
    else
        AM_I_LEADER=true #if swarm doesnt exist i am the leader
    fi

    echo "pull images" #before restarting the system for upgrade
    pull_images

    if [ "$AM_I_LEADER" == "true" ]; then
        if [ "$ES_RUN_DEPLOY" == "true" ]; then
            if [ "$UPDATE_NEED_RESTART" == "true" ] || [ "$STOP_SHIELD" == "true" ]; then
                log_message "Stopping Ericom Shield for Update (Downtime)"
                ./stop.sh
            else
                if [ ! -z "$SWARM" ]; then
                    echo -n "stop shield_es-remote-browser-scaler"
                    docker service scale shield_es-remote-browser-scaler=0
                    wait_for_docker_to_settle
                fi
            fi
        fi
    fi
fi

if [ -n "$MY_IP" ]; then
    echo "Connect swarm to $MY_IP"
    export SHIELD_IP_ADDRESS="$MY_IP"
fi

if [ "$ES_RUN_DEPLOY" == true ] && [ "$AM_I_LEADER" == true ]; then
    echo "source deploy-shield.sh"
    source deploy-shield.sh

    # Check the result of the last command (start, status, deploy-shield)
    if [ $? == 0 ]; then
        echo "***************     Success!"

        #Check the status of the system wait 20*10 (~3 mins)
        wait=0
        while [ $wait -lt 10 ]; do
            if "$ES_PATH"/status.sh; then
                echo "Ericom Shield is Running!"
                SUCCESS=true
                break
            else
                echo -n .
                sleep 30
            fi
            wait=$((wait + 1))
        done
    else
        failed_to_install_cleaner "Deploy Failed"
    fi
else
    echo "Installation only (no deployment or not the leader)"
    SUCCESS=true
fi

systemctl start ericomshield-updater.service

Version=$(grep SHIELD_VER "$ES_YML_FILE")

if [ $SUCCESS == false ]; then
    echo "Something went wrong. Timeout was reached during installation. Please run ./status.sh and check the log file: $LOGFILE."
    echo "$(date): Timeout was reached during the installation" >>"$LOGFILE"
    exit 1
fi

if [ "$SWITCHED_TO_MULTINODE" == "true" ]; then
    echo "Run consul data restore according switching consul mode"
    ./restore.sh
fi

echo "***************     Success!"
echo "***************"
echo "***************     Ericom Shield Version: $Version is up and running"
echo "$(date): Ericom Shield Version: $Version is up and running" >>"$LOGFILE"
