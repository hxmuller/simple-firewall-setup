#!/bin/sh
# firewall.sh install | remove [4 | 6]
#
# firewall.sh installs or removes either or both iptables and ip6tables
# rules onto a Debian based distribution with systemd installed.
#
# The first parameter is required, and is one of: install, remove. The
# second parameter is optional. If omitted, both IPv4 and IPv6 are
# assumed. When used, 4 selects only iptables, while 6 selects only
# ip6tables.
#
# The script does not assume /etc/iptables was created, therefore it
# will not remove the drectory with the 'remove' parameter.

# Trap TERM signal from abort function, so we can exit the main script
# from subprocesses.
trap 'exit 1' TERM
export TOP_PID=$$

# abort () function for error handling, prints all text after the
# function name.
abort () {
    echo 1>&2 firewall.sh: $@
    kill -s TERM $TOP_PID
}

# usage () function - No parameters, prints usage to stdout
usage () {
    abort "Usage: $0 install | remove [4 | 6]"
}

# Test for missing first parameter, if true, exit.
case $1 in
""|4|6)
    echo "missing required first parameter"
    usage
    ;;
install|remove)
    break
    ;;
*)
    echo "bad first parameter supplied"
    usage
    ;;
esac

# Test for correct optional second parameter. Exit if bad
# parameter supplied.
case $2 in
4|6|"")
    break
    ;;
*)
    echo "bad second parameter supplied"
    usage
    ;;
esac

# Error function for missing executable, takes one parameter,
# the name of the executable
err_missing () {
    abort "err_missing: Missing $1 executable"
}

# Script constants
#
# ETC_IPTABLES_DIR
#   This constant maintains the original status of the /etc/iptables
#   directory on the host when the script is first run. The script
#   uses this to determine if the directory should be removed if
#   script given the 'remove' parameter. There are three possible
#   values for the constant. "") State when the script has not been
#   run, "present") The directory is present when the script is first
#   run, "absent") The directory is absent from the machine when the
#   script is first run.
ETC_IPTABLES_DIR="absent"
WHICH=$(which which) || err_missing which
ID=$($WHICH id) || err_missing id
BASENAME=$($WHICH basename) || err_missing basename
SED=$($WHICH sed) || err_missing sed
IPTABLES=$($WHICH iptables) || err_missing iptables
IP6TABLES=$($WHICH ip6tables) || err_missing ip6tables
MKDIR=$($WHICH mkdir) || err_missing mkdir
CAT=$($WHICH cat) || err_missing cat
SH=$($WHICH sh) || err_missing sh
SYSTEMCTL=$($WHICH systemctl) || err_missing systemctl
RM=$($WHICH rm) || err_missing rm

# Test for root user, if not, exit script
if [ $($ID -u) -ne 0 ]
then
    echo "$($BASENAME $0) must be run as root"
    exit
fi

# Test for presence of /etc/iptables when script first run.
# Store state in ETC_IPTABLES_DIR constant.
if [ "$ETC_IPTABLES_DIR" = "" ]; then
    if [ -d /etc/iptables ]; then
        $SED -i '/^ETC_IPTABLES_DIR/s/=.*/="present"/' $0
    else
        $SED -i '/^ETC_IPTABLES_DIR/s/=.*/="absent"/' $0
    fi
fi

# func_argtest () function tests for correct parameter
# supplied to script functions. It then returns the correct iptables
# executable with full path name. func_argtest takes two parameter:
#   $1 - 4 | 6, for either iptables or ip6tables
#   $2 - nocommand, or any other text. This is optional and causes
#        the function to only test for correct parameter.
func_argtest () {
    if [ "$1" = "" ]; then
        abort "func_argtest called without parameters"
    elif [ "$1" != "4" -a "$1" != "6" ]; then
        abort "func_argtest called with bad first parameter"
    fi
    if [ "$2" = "" ]; then
        if [ "$1" = "4" ]; then
            echo $IPTABLES
        elif [ "$1" = "6" ]; then
            echo $IP6TABLES
        else
            abort "func_argtest called with bad first parameter"
        fi
   fi
}

# func_flush () function takes one argument, one of either:
#   4 - for iptables
#   6 - for ip6tables
func_flush () {
    local COMMAND=$(func_argtest $1)
    if [ -f /etc/iptables/empty.v$1 ]; then
        ${COMMAND}-restore > /etc/iptables/empty.v$1 || abort \
            "func_flush: could not restore /etc/iptables/empty.v$1"
    else
        $COMMAND -F
        $COMMAND -Z
        $COMMAND -P INPUT ACCEPT
        $COMMAND -P OUTPUT ACCEPT
        $COMMAND -P FORWARD ACCEPT
    fi
}

# func_rules () function takes one argument, one of either:
#   4 - for iptables
#   6 - for ip6tables
func_rules () {
    local COMMAND=$(func_argtest $1)
    $COMMAND -P INPUT DROP
    $COMMAND -P FORWARD DROP
    $COMMAND -P OUTPUT ACCEPT
    if [ "$1" = "6" ]; then
        $COMMAND -A INPUT -p icmpv6 -j ACCEPT
    fi
    $COMMAND -A INPUT -m state --state INVALID,UNTRACKED -j DROP
    $COMMAND -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
    $COMMAND -A INPUT -i lo -m state --state NEW -j ACCEPT
}

func_service_file () {
    func_argtest $1 nocommand
    if [ "$1" = "4" ]; then
        local FILENAME=iptables.service
    elif [ "$1" = "6" ]; then
        local FILENAME=ip6tables.service
    fi
    echo $FILENAME
}

func_present () {
    func_argtest $1 nocommand
    local FILENAME=$(func_service_file $1)
    [ -f /etc/systemd/system/$FILENAME ] && abort "$FILENAME present"
    [ -f /etc/iptables/empty.v$1 ] && abort "empty.v$1 present"
    [ -f /etc/iptables/rules.v$1 ] && abort "rules.v$1 present"
}

func_not_present () {
    func_argtest $1 nocommand
    local FILENAME=$(func_service_file $1)
    [ -f /etc/systemd/system/$FILENAME ] || abort "$FILENAME not present"
    [ -f /etc/iptables/empty.v$1 ] || abort "empty.v$1 not present"
    [ -f /etc/iptables/rules.v$1 ] || abort "rules.v$1 not present"
}

func_setup () {
    local COMMAND=$(func_argtest $1)
    local FILENAME=$(func_service_file $1)
    func_flush $1 
    ${COMMAND}-save > /etc/iptables/empty.v$1 || \
        abort "could not save /etc/iptables/empty.v$1"
    func_rules $1
    ${COMMAND}-save > /etc/iptables/rules.v$1 || \
        abort "could not save /etc/iptables/rules.v$1"
    $CAT << END > /etc/systemd/system/$FILENAME
[Unit]
Description=IPv$1 Packet Filtering
DefaultDependencies=no
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=$SH -c "${COMMAND}-restore < /etc/iptables/rules.v$1"
ExecReload=$SH -c "${COMMAND}-restore < /etc/iptables/rules.v$1"
ExecStop=$SH -c "${COMMAND}-restore < /etc/iptables/empty.v$1"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
END
    $SYSTEMCTL daemon-reload
    $SYSTEMCTL enable $FILENAME
    $SYSTEMCTL start $FILENAME
}

func_destroy () {
    local COMMAND=$(func_argtest $1)
    local FILENAME=$(func_service_file $1)
    $SYSTEMCTL stop $FILENAME
    $SYSTEMCTL disable $FILENAME
    $RM /etc/systemd/system/$FILENAME
    $RM /etc/iptables/empty.v$1
    $RM /etc/iptables/rules.v$1
}

# Main script execution.
case $1 in
install)
    [ -d /etc/iptables ] || $MKDIR -p /etc/iptables
    case $2 in
    4) func_present 4
       func_setup 4
       ;;
    6) func_present 6
       func_setup 6
       ;;
    "") func_present 4
        func_present 6
        func_setup 4
        func_setup 6
        ;;
    esac
    ;;
remove)
    case $2 in
    4) func_not_present 4
       func_destroy 4
       ;;
    6) func_not_present 6
       func_destroy 6
       ;;
    "") func_not_present 4
        func_not_present 6
        func_destroy 4
        func_destroy 6
        ;;
    esac
    if [ -d /etc/iptables -a "$ETC_IPTABLES_DIR" = "absent" ]; then
        $RM -rf /etc/iptables
    fi
    ;;
esac

echo "firewall.sh: Script terminated normally"
exit 0
