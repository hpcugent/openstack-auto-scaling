#!/bin/bash

SCRIPT_NAME="$(basename "$0")"
RETVAL=""
CONFIG="/etc/openstack-auto-scaling/openstack-auto-scalingrc"
TESTMODE="false"
UNDERCLOUDRC="/home/stack/stackrc"
OVERCLOUDRC="/home/stack/templates/overcloudrc"
LOCKFILE="/home/stack/openstack-auto-scaling/openstack-auto-scaling.lock"
LOCKFILE_OVERRIDE="false"
UCUPN=""
UCUPN_OVERRIDE=""
AGG_GROUPS=""
SHUTDOWN_TIMEOUT="120"
STARTUP_TIMEOUT="900"
PIDFILE="/home/stack/openstack-auto-scaling/openstack-auto-scaling.pid"
PID_TIMEOUT="1200"

usage() {
  cat 1>&2 << EOF_USAGE
  Usage: $SCRIPT_NAME [-c <configrc_file>] [-t] [-u <UCUPN>] [-l] [-h]
  Options: 

  -c, --config <configrc_file>
      (default: $CONFIG)
      Location of configrc file which is sourced by this script to provide following values
      UNDERCLOUDRC - openstack rc file location for admin access to undercloud
                     (default: $UNDERCLOUDRC)
      OVERCLOUDRC - openstack rc file location for admin access to overcloud
                    (default: $OVERCLOUDRC)
      LOCKFILE - location of readable lock file
                 if file exist script won't take action on cloud hypervisors
                 (default: $LOCKFILE)
      UCUPN - Unused Computes Up Percentage Number
              value must be between 1 and 100
              (no default value but mandatory)
      AGG_GROUPS - coma separated aggregation groups on which this script will be auto-scaling hypervisors
                   script expects that no hypervisor is configured in more than one aggregation group from AGG_GROUPS list
                   (no default value but mandatory)
      SHUTDOWN_TIMEOUT - maximum number of seconds as waiting timeout for hypervisor shutdown
                         (default: $SHUTDOWN_TIMEOUT)
      STARTUP_TIMEOUT - maximum number of seconds as waiting timeout for hypervisor startup
                        (default: $STARTUP_TIMEOUT)
      PIDFILE - location of writable pid file
                prior any script run check for already running script is done using this file
                (default: $PIDFILE)

  -t, --testmode
      test mode, no action will be taken on hypervisors

  -u, --ucupn <UCUPN>
      UCUPN override 
      value must be between 1 and 100
      value will be used instead of config value for all nodes startup purposes prior upgrades or changes to overcloud

  -l, --lockfile-override
      LOCKFILE override 
      in case of this argument lockfile will be ignored for all nodes startup purposes prior upgrades or changes to overcloud

  -h
      help
EOF_USAGE
}

exit_abnormal() {
  usage
  exit 1
}

log() {
  if [ "$1" -eq 0 ]; then
    logger "$SCRIPT_NAME: INFO: $2" 
    echo "INFO: $2"
  elif [ "$1" -eq 1 ]; then
    logger "$SCRIPT_NAME: ERROR: $2"
    echo "ERROR: $2" 1>&2
  else
    logger "$SCRIPT_NAME: WARNING: $2"
    echo "WARNING: $2"
  fi
}

openstack_undercloud() {
  source "$UNDERCLOUDRC"
  openstack "$@"
}

openstack_overcloud() {
  source "$OVERCLOUDRC"
  openstack "$@"
}

openstack_api_access_check() {
  test -r "$UNDERCLOUDRC" -a -f "$UNDERCLOUDRC" && openstack_undercloud catalog list &>/dev/null
  local RETVAL
  RETVAL="$?"
  [ "$RETVAL" -ne 0 ] && log "1" "Unable to access undercloud catalog using $UNDERCLOUDRC as a rc file" && exit 1
  test -r "$OVERCLOUDRC" -a -f "$OVERCLOUDRC" && openstack_overcloud catalog list &>/dev/null
  RETVAL="$?"
  [ "$RETVAL" -ne 0 ] && log "1" "Unable to access overcloud catalog using $OVERCLOUDRC as a rc file" && exit 1
}

config_check() {
  [ "$1" == "" ] && log "1" "Script CONFIG variable is empty" && exit_abnormal
  if ! test -r "$1" -a -f "$1"; then
    log "1" "Unable to read configrc file $1"
    exit_abnormal
  fi
}
input_check() {
  [ "$UNDERCLOUDRC" == "" ] && log "1" "Variable UNDERCLOUDRC is unset" && exit_abnormal
  [ "$OVERCLOUDRC" == "" ] && log "1" "Variable OVERCLOUDRC is unset" && exit_abnormal
  [ "$LOCKFILE" == "" ] && log "1" "Variable LOCKFILE is unset" && exit_abnormal
  [ "$UCUPN" == "" ] && log "1" "Variable UCUPN is unset" && exit_abnormal
  [ "$AGG_GROUPS" == "" ] && log "1" "Variable AGG_GROUPS is unset" && exit_abnormal
  [ "$SHUTDOWN_TIMEOUT" == "" ] && log "1" "Variable SHUTDOWN_TIMEOUT is unset" && exit_abnormal
  [ "$STARTUP_TIMEOUT" == "" ] && log "1" "Variable STARTUP_TIMEOUT is unset" && exit_abnormal
  [ "$PIDFILE" == "" ] && log "1" "Variable PIDFILE is unset" && exit_abnormal
  if ! [[ ( "$SHUTDOWN_TIMEOUT" -ge 0 ) ]]; then
    log "1" "Incrorrect SHUTDOWN_TIMEOUT value in $CONFIG"
    exit 1
  fi
  if ! [[ ( "$STARTUP_TIMEOUT" -ge 0 ) ]]; then
    log "1" "Incrorrect STARTUP_TIMEOUT value in $CONFIG"
    exit 1
  fi
  if ! [[ ( "$UCUPN" -gt 0 ) && ( "$UCUPN" -le 100 ) ]]; then
    log "1" "Incrorrect UCUPN value"
    exit 1
  fi
}

lockfile_check() {
  if [ "$LOCKFILE_OVERRIDE" == "false" ]; then
    if test -r "$LOCKFILE" -a -f "$LOCKFILE" ; then 
      log "2" "Lock file $LOCKFILE exist, script is not going to take any action"
      exit 0
    fi
  else
    log "2" "Lock file override enabled"
  fi
}

get_agg_group_status() {
#usage: get_agg_group_status AGG_GROUP
  local agg_group
  agg_group="$1"
  openstack_overcloud aggregate show "$agg_group" &>/dev/null
  local RETVAL
  RETVAL="$?"
  if [ "$RETVAL" -ne 0 ]; then
    log "1" "Unable to find aggregation group $agg_group" && return 1
  else
    local agg_group_hypervisor_list agg_group_hypervisor_filter
    agg_group_hypervisor_list="$(openstack_overcloud aggregate show "$agg_group" -f json -c hosts |jq --raw-output '.hosts[]')"
    agg_group_hypervisor_filter="$(echo "$agg_group_hypervisor_list"|tr '\n' '|'|sed 's/|$//g')"

    #below variable necessary as global
    hyp_list="$(openstack_overcloud hypervisor list --long -f value -c "Hypervisor Hostname" -c "vCPUs Used" -c "State"| \
                  grep -E "$agg_group_hypervisor_filter"|sort)"

    local computes_number_up_with_vm
    computes_number="$(echo "$hyp_list"|wc -l)"
    computes_number_up_with_vm="$(echo "$hyp_list"|grep " up "|grep -vc " 0$")"
    computes_number_up_before_logic="$(echo "$hyp_list"|grep -c " up ")"
    computes_number_up_after_logic="$((computes_number_up_with_vm + computes_number * UCUPN / 100))"
    [ "$computes_number_up_after_logic" -gt "$computes_number" ] && \
      computes_number_up_after_logic="$computes_number"

    #below variables necessary as global
    computes_number_difference="$((computes_number_up_before_logic - computes_number_up_after_logic))"
    computes_hostnames_up="$(echo "$hyp_list"|grep " up "|awk '{print $1}'|xargs)"
    computes_hostnames_down_with_no_vm="$(echo "$hyp_list"|grep " down "|grep " 0$"|awk '{print $1}'|xargs)"

    local computes_number_down_with_vm computes_hostnames_down_with_vm
    computes_number_down_with_vm="$(echo "$hyp_list"|grep " down "|grep -vc " 0$")"
    computes_hostnames_down_with_vm="$(echo "$hyp_list"|grep " down "|grep -v " 0$"|awk '{print $1}'|xargs)"
    [ "$computes_number_down_with_vm" -ne 0 ] && \
      log "2" "IMPORTANT: hypervisors in aggregation group $agg_group down with VMs: $computes_hostnames_down_with_vm"
  fi
  return 0
}

print_agg_group_status() {
#function expects global variables
  log "0" "Percentage of empty computes configured: $UCUPN%"
  log "0" "Number of hypervisors in aggregation group $agg_group: $computes_number"
  log "0" "Number of hypervisors in aggregation group $agg_group up: $computes_number_up_before_logic"
  log "0" "Expected number of hypervisors in aggregation group $agg_group up: $computes_number_up_after_logic"
  log "0" "Hypervisors in aggregation group $agg_group up: $computes_hostnames_up"
  log "0" "Hypervisors in aggregation group $agg_group down: $computes_hostnames_down_with_no_vm"
}

computes_action() {
#function expects global variables
#usage: computes_action shutdown|startup hostnames_fqdn_list
  local action hostnames_fqdn_list_for_action hostnames_list_for_action filter
  action="$1"
  hostnames_fqdn_list_for_action="$2"
  hostnames_list_for_action="$(echo "$hostnames_fqdn_list_for_action"|xargs -n1 echo|awk -F\. '{print $1}'|xargs)"
  filter="$(echo "$hostnames_fqdn_list_for_action"|tr ' ' '|')"

  if [ "$action" == "shutdown" ]; then
    log "0" "Disabling nova-compute service for hypervisors: $hostnames_fqdn_list_for_action now.."
    for host_fqdn in $hostnames_fqdn_list_for_action; do
      openstack_overcloud compute service set --disable --disable-reason "$SCRIPT_NAME" "$host_fqdn" nova-compute
    done
    log "0" "Shutting down hypervisors: $hostnames_fqdn_list_for_action now.."
    for host in $hostnames_list_for_action; do
      openstack_undercloud server stop "$host"
    done
    log "0" "Waiting for hypervisors to be down with timeout $SHUTDOWN_TIMEOUT seconds"
    SECONDS="clear";
    while [ "$SECONDS" -lt "$SHUTDOWN_TIMEOUT" ]; do
      openstack_overcloud hypervisor list --long -f value -c "Hypervisor Hostname" -c "State"|grep -E "$filter"|grep " up$" &>/dev/null || break
      sleep 10
    done
    local RETVAL
    openstack_overcloud hypervisor list --long -f value -c "Hypervisor Hostname" -c "State"|grep -E "$filter"|grep " up$" &>/dev/null
    RETVAL="$?"
    if [ "$RETVAL" -eq 0 ]; then
      local hostnames_fqdn_list_still_up
      hostnames_fqdn_list_still_up="$(openstack_overcloud hypervisor list --long -f value -c "Hypervisor Hostname" -c "State"| \
                                                 grep -E "$filter"|grep " up$"|awk '{print $1}'|sort|xargs)"
      log "1" "Hypervisos still up after timeout: $hostnames_fqdn_list_still_up"
    fi
    log "0" "Enabling nova-compute service for hypervisors: $hostnames_fqdn_list_for_action now.."
    for host_fqdn in $hostnames_fqdn_list_for_action; do
      openstack_overcloud compute service set --enable "$host_fqdn" nova-compute
    done
    return 0
  fi
  if [ "$action" == "startup" ]; then
    log "0" "Starting up hypervisors: $hostnames_fqdn_list_for_action now.."
    for host in $hostnames_list_for_action; do
      openstack_undercloud server start "$host"
    done
    log "0" "Waiting for hypervisors to be up with timeout $STARTUP_TIMEOUT seconds"
    SECONDS="clear";
    while [ "$SECONDS" -lt "$STARTUP_TIMEOUT" ]; do
      openstack_overcloud hypervisor list --long -f value -c "Hypervisor Hostname" -c "State"|grep -E "$filter"|grep " down$" &>/dev/null || break
      sleep 10
    done
    local RETVAL
    openstack_overcloud hypervisor list --long -f value -c "Hypervisor Hostname" -c "State"|grep -E "$filter"|grep " down$" &>/dev/null
    RETVAL="$?"
    if [ "$RETVAL" -eq 0 ]; then
      local hostnames_fqdn_list_still_down
      hostnames_fqdn_list_still_down="$(openstack_overcloud hypervisor list --long -f value -c "Hypervisor Hostname" -c "State"| \
                                                 grep -E "$filter"|grep " down$"|awk '{print $1}'|sort|xargs)"
      log "1" "Hypervisos still down after timeout: $hostnames_fqdn_list_still_down"
    fi
    return 0
  fi
  return 1
}

run_on_agg_groups() {
#function expects global variables
  local hostnames_fqdn_list
  for agg_group in $(echo "$AGG_GROUPS"|tr ',' ' ')
  do
    computes_number_difference=""
    local RETVAL hostnames_fqdn_list_in_agg_group
    get_agg_group_status "$agg_group" && print_agg_group_status
    RETVAL="$?"
    hostnames_fqdn_list_in_agg_group="$hyp_list"
    if [ "$RETVAL" -eq 0 ]; then
      #NO ACTION
      if [ "$computes_number_difference" -eq 0 ]; then
        log "0" "No action needed."
      fi
      if [ "$TESTMODE" == "true" ]; then
          log "2" "Script in TEST MODE. No action is taken on hypervisors"
      else
        #COMPUTES SHUTDOWN
        if [ "$computes_number_difference" -gt 0 ]; then
          hostnames_fqdn_list="$(echo "$hostnames_fqdn_list_in_agg_group"| \
                                   grep " 0$"|grep " up "|awk '{print $1}'|tail -"$computes_number_difference"|xargs)"
          computes_action "shutdown" "$hostnames_fqdn_list"
        fi
        #COMPUTES STARTUP
        if [ "$computes_number_difference" -lt 0 ]; then
          computes_number_difference="${computes_number_difference/-/}"
          hostnames_fqdn_list="$(echo "$hostnames_fqdn_list_in_agg_group"| \
                                   grep " 0$"|grep " down "|awk '{print $1}'|head -"$computes_number_difference"|xargs)"
          computes_action "startup" "$hostnames_fqdn_list"
        fi
      fi
    else
      log "1" "Unable to get hypervisors status for aggregation group $agg_group"
    fi
  done
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -c|--config)
      shift
      [ "$1" == "" ] && log "1" "Expecting argument" && exit_abnormal
      CONFIG="$1"
      shift
      ;;
    -t|--testmode)
      TESTMODE="true"
      shift
      ;;
    -u|--ucupn)
      shift
      [ "$1" == "" ] && log "1" "Expecting argument" && exit_abnormal
      UCUPN_OVERRIDE="$1"
      shift
      ;;
    -l|--lockfile-override)
      LOCKFILE_OVERRIDE="true"
      shift
      ;;
    *)
      log "1" "Unimplemented option: $1" && exit_abnormal
      ;;
  esac
done

export CONFIG
config_check "$CONFIG"
source "$CONFIG" 2>/dev/null
export UNDERCLOUDRC OVERCLOUDRC LOCKFILE UCUPN AGG_GROUPS SHUTDOWN_TIMEOUT STARTUP_TIMEOUT PIDFILE
[ "$UCUPN_OVERRIDE" != "" ] && UCUPN="$UCUPN_OVERRIDE"
input_check

touch "$PIDFILE" &>/dev/null
RETVAL="$?"
if [ "$RETVAL" -ne 0 ]; then
 log "1" "Unable to write to $PIDFILE file"
 exit 1
fi

log "0" "Performing check if script $SCRIPT_NAME is already running, if so waiting with timeout $PID_TIMEOUT seconds"
exec 3>"$PIDFILE"
flock -w "$PID_TIMEOUT" 3
RETVAL="$?"
if [ "$RETVAL" -eq 0 ]; then
  echo $$ 1>&3
  lockfile_check
  openstack_api_access_check
  run_on_agg_groups
else
 log "1" "Timeout expired. exiting.." 
 exit 1
fi
