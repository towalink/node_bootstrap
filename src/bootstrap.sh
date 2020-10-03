#!/bin/bash

#################################
### Bootstrap a Towalink node ###
#################################

# Written for Raspbian (based on Debian Buster) and Alpine Linux
#
# The Towalink Project
# Author: Dirk Henrici
# Creation: Sept. 2019
# Last update: September 2020
# License: GPL3

# This program is free software: you can redistribute it and/or modify  
# it under the terms of the GNU General Public License as published by  
# the Free Software Foundation, version 3.
# 
# This program is distributed in the hope that it will be useful, but 
# WITHOUT ANY WARRANTY; without even the implied warranty of 
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU 
# General Public License for more details.
# 
# You should have received a copy of the GNU General Public License 
# along with this program. If not, see <http://www.gnu.org/licenses/>.


########################
# Function definitions #
########################

# Prints the current time or the relative time since the script started depending on the time_start variable
function doOutputTime
{
  if [ -z "$time_start" ]; then
    echo -n "[$(date '+%F %T')] "
  else
    time_current=$(date +%s)
    printf "[+%03d] " "$(($time_current-$time_start))"
  fi
}

# Prints a string in case verbose output is requested
function doOutputVerbose #(output)
{
  if [[ $verbose -ne 0 ]]; then
    doOutputTime
    echo "$1"
  fi
}

# Prints a string
function doOutput #(output, error)
{
  doOutputTime
  if [[ ${2:-0} -eq 1 ]]; then
    echo "$1" 2>&1
  else
    echo "$1"
  fi
  [[ $syslog -eq 0 ]] || logger "homebox: $1"
}

# Prints an error message and exits the script
function exitWithError #(output)
{
  local erroutput="${1:-}"
  doOutput "$erroutput" 1
  exit 1
}

# Prints an error message and exits the script
function exitWithTrapError #(lineno, output)
{
  local erroutput="${2:-}"
  if [ "$erroutput" == "" ]; then
    erroutput="Trapped shell error on line $1. See log file for error message. Aborting."
  fi
  exitWithError "$erroutput"
}

# Checks whether a command is available on the system and exits the script if not
function checkCommandAvailability #(command)
{
  command -v "$1" >/dev/null 2>&1 || exitWithError "The command '$1' cannot be found. Exiting."
}

# Prints information in the script usage (i.e. available command line parameters)
function printUsage
{
  echo -e "Usage: ${0##*/} [-v|--verbose]\n"
  echo -e "  -h, --help        Prints usage info"
  echo -e "  -c, --controller  URL of the controller to connect to"
  echo -e "  -v, --verbose     Verbose output"
  echo
  echo -e "Example:"
  echo -e "  ${0##*/} --verbose"
}

# Prints/returns the name of the primary interface (identified by default route leading to it)
function getPrimaryInterface # : interface_name
{
  local counter=0
  local interface=
  while [ -z "${interface}" ] && [ $counter -lt 60 ];
  do
    # "grep -v wg" to ignore WireGuard interfaces
    interface=$(route -n | grep '^0.0.0.0' | grep -v wg | grep -o '[^ ]*$')
    #echo $(ip route get 8.8.8.8 | awk -- '{printf $5}') # alternative way to get primary interface
    if [ ! -z "${interface}" ]; then
      # Wait for network to be configured (relevant while still starting up) and then try again
      sleep 1
    fi
    counter=$((${counter}+1))
  done
  # If still no interface detected, default to eth0
  if [ -z "${interface}" ]; then
    interface=eth0
  fi
  echo $interface
}

# Prints/returns the MAC address of the specified interface
function getMacAddressByInterface #(interface_name) : MAC address
{
  cat "/sys/class/net/$1/address"
}

# Prints/returns the MAC address of the primary interface
function getPrimaryMacAddress # : MAC address
{
  echo $(getMacAddressByInterface $(getPrimaryInterface))
}

# Resets the counter in the given file
function resetCounterFile #(filename)
{
  local filename=$1
  echo 0 > "${filename}"
}

# Gets the counter in the given file
function getCounterFile #(filename) : counter
{
  local filename=$1
  local counter
  if [ -e "${filename}" ]; then
    counter=$(cat "${filename}")
  else
    counter=0
  fi
  echo $counter
}

# Increases the counter in the given file
function increaseCounterFile #(filename)
{
  local filename=$1
  if [ ! -e "${filename}" ]; then
    resetCounterFile "${filename}"
  else
    local counter=$(getCounterFile "${filename}")
    echo $((${counter}+1)) > "${filename}"
  fi
}

# Resolves DNS CNAMEs to final host
function getEffectiveHost #(hostname_in) : hostname_out
{
  local hostname=$1
  local result=$hostname
  local retcode=0
  while [[ $result != "record" ]] && [ $retcode -eq 0 ]
  do
    hostname=$result
    result=$(host -t cname $result)
    retcode=$?
    if [[ $result != "record" ]]; then
      result=$(echo $result | awk '{print $NF}') # last column contains host
      result=${result%.} # remove trailing dot
    fi
  done
  echo $hostname
}

############################
# Prepare script execution #
############################

# Do not continue on error
# set -o errexit  # is the same as 'set -e'
# We do not use this as we evaluate results on our own

# Fail on "true | false"
set -o pipefail

# Exit if unset variable is used
set -o nounset  # is the same as 'set -u'

# Call function on error
trap 'exitWithTrapError $LINENO' ERR

### Set initial/default values of variables ###
verbose=0
debug=0
syslog=0
restart_required=0
controller=
configfile='bootstrap.conf'
configpath='/etc/towalink'
configpath_bootstrap=${configpath}'/bootstrap'
logfile='/var/log/towalink_bootstrap.log'
scriptpath='/opt/towalink'
scriptfile=${scriptpath}'/bootstrap.sh'
scriptversion=0.1
wg_interface='tlwg_mgmt'
wg_listenport=51820
wg_configfile='/etc/wireguard/'${wg_interface}'.conf'
filename_cacert="${configpath_bootstrap}/cacert.pem"
filename_config="${configpath_bootstrap}/${configfile}"
filename_controller=${configpath_bootstrap}'/controller'
filename_config_key=${configpath_bootstrap}'/config_key'
filename_recovery_key=${configpath_bootstrap}'/recovery_key'
filename_wg_private=${configpath_bootstrap}'/wg_private'
filename_wg_public=${configpath_bootstrap}'/wg_public'
filename_wg_shared=${configpath_bootstrap}'/wg_shared'
filename_bootstrapconfig='/tmp/tl_bootstrapconfig'
filename_counter_invocations=${configpath_bootstrap}'/counter_invocations'
filename_counter_noconnect=${configpath_bootstrap}'/counter_noconnect'
curl_opts_bootstrap=()

### Initial actions ###
time_start=$(date +%s)

# Write output also to log file
if [ ! -z "${logfile}" ]; then
  exec > >(tee ${logfile}) 2>&1
fi

# Check for root privileges
# Note: previous way of checking:  if [ $(id -u) -gt 0 ]; then 
if [[ "$EUID" -ne 0 ]]; then
  exitWithError "You need to run this script with root privileges"
fi

# Process config file
if [ -e "${filename_config}" ]; then
  doOutputVerbose "Reading config file [${filename_config}]"
  IFS="="
  while read -r name value
  do
    # Skip empty lines
    [[ -z "$name" ]]  && continue
    # Skip comments
    [[ "$name" =~ ^#.*$ ]] && continue
    #echo "Variable $name is set to ${value//\"/}"
    declare "$name=${value//\"/}"
  done < "${filename_config}"
fi

# Consider script parameters
while [ "${1:-}" != "" ]; # ${var:-unset} evaluates as unset if var is not set
do
    case $1 in
      -v  | --verbose )     verbose=1
                ;;
      -c  | --controller )  shift; controller="${1:-}"
                ;;
      -h  | --help )        printUsage
                            exit
                ;;
      *)                    printUsage
                            echo
                            exitWithError "The parameter $1 is not allowed"
                ;;
    esac
    shift
done

# Switch on script debugging if requested
if [[ $debug -ne 0 ]]; then
  set -x
fi

# Make sure needed directories exist
tmp1=$(mkdir -p ${configpath_bootstrap})
tmp1=$(mkdir -p ${scriptpath})

# Create config file with script parameters
# Note: "controller" is handled differently so that always the latest provided one is used
if [ ! -e "${filename_config}" ]; then
  tmp1="verbose=${verbose}"
  echo "$tmp1" > "${filename_config}"
fi

# Make sure Towalink config is only readable by root
chmod 700 ${configpath} -R

# Make variables from /etc/os-release available in this script
source <(cat /etc/os-release)
# $ID -> alpine, debian, raspian 
# $VERSION_CODENAME -> buster (on Debian)

# Increase counters
increaseCounterFile "${filename_counter_invocations}"
increaseCounterFile "${filename_counter_noconnect}"

# Remember controller command line argument
if [ -z "${controller}" ]; then
  if [ -e "${filename_controller}" ]; then
    controller=$(cat "${filename_controller}")
  fi
else
  doOutputVerbose "Remembering controller [${controller}] for further script invocations"
  echo $controller > "${filename_controller}"
fi
if [ ! -z "${controller}" ]; then
  doOutput "Using custom controller [${controller}]"
fi

#############################################
# Make sure this script is run at boot time #
#############################################

### Make sure this script is available at the needed location ###
if [[ ! "$(realpath $0)" == "$scriptfile" ]]; then # don't overwrite a running script
  doOutputVerbose "Currently not running bootstrap script from ["$scriptfile"]. Installing at that location"
  # Download official current version
  retcode=$(wget https://install.towalink.net/node/ -O "/tmp/tl_bootstrap.sh" -T 10 -q && echo 0 || echo $?)
  if [ $retcode -eq 0 ]; then  
    install -m 700 "/tmp/tl_bootstrap.sh" "$scriptfile"
    doOutputVerbose "Bootstrap script downloaded and installed"
  else
    doOutputVerbose "Bootstrap script download failed. wget returned error code ${retcode}. Working around..."
    install -m 700 "$(realpath $0)" "$scriptfile"
  fi
fi

### Start bootstrap script on boot using a init script ###
doOutputVerbose "Making sure that bootstrap script gets started on boot"
name=towalink_bootstrap
if [ -e "/etc/alpine-release" ]; then # Alpine
  init_script="#!/sbin/openrc-run

depend() {
	need net
}
 
name="$name"
command="$scriptfile"
command_args="$@"
pidfile="/run/\$RC_SVCNAME.pid"
command_background="yes"
stopsig="SIGTERM"
"
  echo "$init_script" > /etc/init.d/$name
  chmod u+x /etc/init.d/$name
  rc-update -q add $name default
else # non-Alpine ==> systemd
  init_script="
[Unit]
Description=Towalink bootstrap service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/root
ExecStart=/bin/bash "$scriptfile"
#RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
"
  echo "$init_script" > /etc/systemd/system/$name.service
  chmod 644 /etc/systemd/system/$name.service
  systemctl enable $name.service
fi

###############################
# Get and run recovery script #
###############################

### Make sure needed packages are installed ###
if [ -e "/sbin/apk" ]; then # Alpine (apk-based)
  if [ ! -e "/usr/bin/host" ]; then
    # Host command and dig command
    doOutputVerbose "Installing bind-tools"
    apk add bind-tools 
  fi
else # non-Alpine
  # "host" command
  if [ ! -e "/usr/bin/host" ]; then
    doOutputVerbose "Installing bind9-host"
    apt-get install bind9-host
  fi
fi

### Get and run recovery script ###
recovery='/tmp/tl_recovery.sh'
tmp1=$(getPrimaryMacAddress)
tmp1=${tmp1//:} # delete colons from MAC address
tmp1=$tmp1.recovery.towalink.net
tmp1=$(getEffectiveHost "$tmp1") # resolve CNAMEs to avoid certificate errors (needed if no wildcard certificate is used)
doOutputVerbose "Attempting to download and process recovery from [$tmp1]..."
retcode=$(wget https://$tmp1/recovery/ -O "$recovery" -T 5 -q && echo 0 || echo $?)
if [ $retcode -eq 0 ]; then  
  doOutputVerbose "Recovery script has downloaded without error"
  tmp2=$(tail -n 1 "$recovery")
  if [ "$tmp2" == "# EOF" ]; then  
    doOutputVerbose "Recovery script is completely downloaded"
    # If recovery key exists it needs to be contained in the recovery file
    if [ -e "$filename_recovery_key" ]; then
      tmp3=$(cat "$filename_recovery_key")
      if ! grep -q "$tmp3" "${recovery}"; then
        tmp1=$(getCounterFile "${filename_counter_noconnect}")
        if [ $tmp1 -lt 5 ]; then # require five machine restarts to disable security check
          doOutput "Recovery script failed validation. Not running it"        
          recovery=
        else
          doOutput "Recovery script failed validation. Running anyway since management connection seems to have failed permanently"
        fi
      else
        doOutputVerbose "Recovery script validated based on recovery key"
      fi
    fi
    if [ ! -z "${recovery}" ]; then
      chmod u+x "$recovery"
      doOutput "Running recovery script..."
      source "$recovery"
    fi
  fi
else
  doOutputVerbose "Recovery script download not possible; recovery is probably disabled. wget returned error code ${retcode}. Ignoring and continuing"
fi

###############################
# Establish remote management #
###############################

### Make sure needed packages are installed ###
if [ -e "/sbin/apk" ]; then # Alpine (apk-based)
  # WireGuard kernel
  if [[ $(apk info | grep linux-virt | wc -l) -ne 0 ]]; then # virt kernel installed?
    if ! apk info -q --installed wireguard-virt ; then
      doOutput "Installing WireGuard virt kernel..."
      apk add wireguard-virt
      restart_required=1
    fi
  else # no virt kernel installed
    if ! apk info -q --installed wireguard-virt ; then
      doOutput "Installing WireGuard kernel..."
      apk add wireguard-vanilla
      restart_required=1
    fi
  fi
  if ! apk info -q --installed wireguard-tools wireguard-tools-wg wireguard-tools-wg-quick bind-tools curl ; then
    doOutputVerbose "Making sure that required tool packages are installed"
    # WireGuard tools  
    apk add wireguard-tools wireguard-tools-wg wireguard-tools-wg-quick
    # "host" command and "dig" command
    apk add bind-tools
    # "curl" command
    apk add curl
    # python (for remote management using Ansible)
    apk add python3
  fi
else # non-Alpine
  if [ ! -e "/usr/bin/wg" ]; then
    if [[ "$VERSION_CODENAME" == "buster" ]]; then
      doOutput "Installing WireGuard..."
      echo "deb http://httpredir.debian.org/debian buster-backports main contrib non-free" > /etc/apt/sources.list.d/debian-backports.list
      # apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 04EE7237B7D453EC 648ACFD622F3D138
      wget -O - https://ftp-master.debian.org/keys/archive-key-$(lsb_release -sr).asc | apt-key add -
      apt-get update
      if [[ "$ID" == "raspbian" ]]; then
        apt-get install raspberrypi-kernel-headers
      fi    
      apt-get -y install wireguard
      restart_required=1
    else
      exitWithError "The operating system version [$VERSION_CODENAME] is not yet supported"
    fi
  fi
  # "host" command
  if [ ! -e "/usr/bin/host" ]; then
    doOutputVerbose "Installing bind9-host package"  
    apt-get install bind9-host
  fi
fi

### Based on the changes done (new kernel...), trigger a reboot ###
if [[ $restart_required -ne 0 ]]; then
  read -t 15 -p "Restart required. Rebooting machine in fifteen seconds (unless you interrupt this script now)..." || :
  doOutput "Triggering reboot..."
  reboot
  exit
fi

### Create/get key material ###
if [ ! -e "${filename_config_key}" ] && [ ! -e "${filename_config_key}.tmp" ]; then
  doOutputVerbose "Generating config key"
  install -m 700 /dev/null "${filename_config_key}.tmp"
  wg genpsk > "${filename_config_key}.tmp"
fi
if [ ! -e "${filename_config_key}" ]; then
  config_key=$(cat "${filename_config_key}.tmp")
else
  config_key=$(cat "${filename_config_key}")
fi
if [ ! -e "${filename_recovery_key}" ] && [ ! -e "${filename_recovery_key}.tmp" ]; then
  doOutputVerbose "Generating recovery key"
  install -m 700 /dev/null "${filename_recovery_key}.tmp"
  wg genpsk > "${filename_recovery_key}.tmp"
fi  
if [ ! -e "${filename_recovery_key}" ]; then
  recovery_key=$(cat "${filename_recovery_key}.tmp")
else
  recovery_key=$(cat "${filename_recovery_key}")
fi
if [ ! -e "${filename_wg_private}" ]; then
  install -m 700 /dev/null "${filename_wg_private}"
  wg genkey > "${filename_wg_private}"  
fi
wg_private=$(cat "${filename_wg_private}")  
wg_public=$(echo "$wg_private" | wg pubkey)

### Download and run bootstrap config script until management connection is up and working ###
mac_addr=$(getPrimaryMacAddress)
if [ -z "${controller}" ]; then
  controller=$mac_addr
  controller=${controller//:} # delete colons from MAC address
  controller="${controller}.bootstrap.towalink.net"
  controller=$(getEffectiveHost "$controller") # resolve CNAMEs to avoid certificate errors
fi
if [ -e "$filename_cacert" ]; then
  curl_opts_bootstrap+=(--cacert ${filename_cacert})
else
  doOutput "Warning: File ${filename_cacert} for CA certificate is not present. Self-signed Controller certificates will be rejected"
fi
success=0
counter=0
while [ $success -ne 1 ]
do
  # Try to download bootstrap config if this machine is still unconfigured or after one hour without connection
  filename_bootstrapconfig='/tmp/tl_bootstrapconfig.sh' # must be in while loop
  if [ ! -e "${wg_configfile}" ] || [ $counter -gt 240 ]; then
    doOutputVerbose "Attempting to download and process bootstrap config from [$controller]..."
    # --get would encode data in query string instead of posting the data
    http_response=$(curl --max-time 5 --silent "${curl_opts_bootstrap[@]}" --write-out %{http_code} --data-urlencode "scriptversion=$scriptversion"  --data-urlencode "mac=$mac_addr" --data-urlencode "hostname=$(hostname -f)" --data-urlencode "recovery-key=$recovery_key" --data-urlencode "config-key=$config_key" --data-urlencode "wg_public=$wg_public" "https://$controller/bootstrap/" --output "$filename_bootstrapconfig" && echo 0 || echo $?)
    retcode=$?
    if [ $retcode -eq 0 ]; then  
      if [ $http_response -eq 2000 ]; then  # a zero is appended to the usual http response code
        doOutputVerbose "Bootstrap config has downloaded without error"
        tmp2=$(tail -n 1 "$filename_bootstrapconfig")
        if [ "$tmp2" == "# EOF" ]; then  
          doOutputVerbose "Bootstrap config is completely downloaded"
          # If config key exists it needs to be contained in the downloaded bootstrap config file
          if [ -e "$filename_config_key" ]; then
            tmp3=$(cat "$filename_config_key")
            if ! grep -q "$tmp3" "${filename_bootstrapconfig}"; then
              doOutput "Bootstrap config failed validation. Not running it"
              filename_bootstrapconfig=
            else
              doOutputVerbose "Bootstrap config validated based on config key"
            fi
          fi
          if [ ! -z "${filename_bootstrapconfig}" ]; then        
            chmod u+x "${filename_bootstrapconfig}"
            doOutput "Running downloaded bootstrap config script..."
            source "${filename_bootstrapconfig}"
            counter=0            
            # Successfully transmitted config key and recovery key, thus using them now
            if [ ! -e "${filename_recovery_key}.tmp" ]; then
              mv "${filename_recovery_key}.tmp" "${filename_recovery_key}"
            fi
            if [ ! -e "${filename_config_key}.tmp" ]; then
              mv "${filename_config_key}.tmp" "${filename_config_key}"
            fi
          fi
        fi
      elif [ $http_response -eq "00052" ]; then  # http response 204
        doOutputVerbose "Bootstrap config download failed. Controller reached but config not yet available. Ignoring and continuing"      
      else
        doOutputVerbose "Bootstrap config download failed with http response ${http_response}. Ignoring and continuing"
      fi
    else
      doOutputVerbose "Bootstrap config download failed. curl returned error code ${retcode}. Ignoring and continuing"
    fi  
  fi
  if [ -e "${wg_configfile}" ]; then
    # Enable management interface
    retcode=$(wg-quick down "$wg_interface" 2>&1 > /dev/null && echo 0 || echo $?) # for the case that interface is up
    retcode=$(wg-quick up "$wg_interface" && echo 0 || echo $?)
    if [ $retcode -eq 0 ]; then  
      doOutputVerbose "Interface [$wg_interface] is up"
    else
      doOutput "Error setting up interface [$wg_interface]"
    fi
    # Check for successful connection to controller
    retcode=$(ping -c 1 -W 3 -w 3 -q fe80::1%${wg_interface} > /dev/null; echo $?)
    if [ $retcode -eq 0 ]; then
      doOutput "Management connection established and working"
      success=1
      resetCounterFile "${filename_counter_noconnect}"
    fi
  else
    # Provide non-verbose info at the first failure only
    if [ $counter -eq 0 ]; then
      doOutput "Bootstrap config download was not yet possible; attempting retry every 15 seconds..."
    fi
  fi
  if [ $success -ne 1 ]; then
    # Wait some seconds until next check
    doOutputVerbose "Management connection not yet working; attempting retry after sleeping for 15 seconds..."
    sleep 15
  fi
  counter=$((counter+1))
done
doOutput "Bootstrapping finished successfully"

############
# Clean-up #
############

trap - ERR
