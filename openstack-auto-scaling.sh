#!/bin/bash

SCRIPT_NAME="$(basename "$0")"
OPTION=""
RETVAL=""
CONFIG=""
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
  Usage: $SCRIPT_NAME -c <config_file_location> [-t] [-u <UCUPN>] [-l]" 1>&2
  Options: -c <config_file_location> - Location of config file which is sourced by this script to provide following values
                                       UNDERCLOUDRC     - openstack rc file location for admin access to undercloud
                                                          (default: $UNDERCLOUDRC)
                                       OVERCLOUDRC      - openstack rc file location for admin access to overcloud
                                                          (default: $OVERCLOUDRC)
                                       LOCKFILE         - location of readable lock file
                                                          if file exist script won't take action on cloud hypervisors
                                                          (default: $LOCKFILE)
                                       UCUPN            - Unused Computes Up Percentage Number
                                                          value must be between 1 and 100
                                                          (no default value but mandatory)
                                       AGG_GROUPS       - coma separated aggregation groups on which this script will be auto-scaling hypervisors
                                                          script expects that no hypervisor is configured in more than one aggregation group from AGG_GROUPS list
                                                          (no default value but mandatory)
                                       SHUTDOWN_TIMEOUT - maximum number of seconds as waiting timeout for hypervisor shutdown
                                                          (default: $SHUTDOWN_TIMEOUT)
                                       STARTUP_TIMEOUT  - maximum number of seconds as waiting timeout for hypervisor startup
                                                          (default: $STARTUP_TIMEOUT)
                                       PIDFILE          - location of writable pid file
                                                          prior any script run check for already running script is done using this file
                                                          (default: $PIDFILE)
           -u <UCUPN> - UCUPN override 
                        value must be between 1 and 100
                        value will be used instead of config value for all nodes startup purposes prior upgrades or changes to overcloud
           -t - test mode, no action will be taken on hypervisors
           -l - LOCKFILE override 
                in case of this argument lockfile will be ignored for all nodes startup purposes prior upgrades or changes to overcloud
  Example: $SCRIPT_NAME -c /home/stack/openstack-auto-scaling/openstack-auto-scalingrc
  Cron entry example: */10 * * * * $SCRIPT_NAME -c /home/stack/openstack-auto-scaling/openstack-auto-scalingrc >/dev/null
  Script to run prior overcloud upgrade/change example: touch $LOCKFILE
                                                        $SCRIPT_NAME -c /home/stack/openstack-auto-scaling/openstack-auto-scalingrc -u 100 -l
                                                        <overcloud upgrade/change command> && \\
                                                        rm -f $LOCKFILE
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

while getopts ":tc:u:l" options; do
  case "${options}" in
    c)
      OPTION=${OPTARG}
      if test -r "$OPTION" -a -f "$OPTION" ; then
        CONFIG="$OPTION"
      else
        log "1" "Unable to read config file $OPTION"
      fi
      ;;
    t)
      TESTMODE="true"
      ;;
    u)
      OPTION=${OPTARG}
      UCUPN_OVERRIDE="$OPTION"
      ;;
    l)
      LOCKFILE_OVERRIDE="true"
      ;;
    \?)
      log "1" "Unknown option: -$OPTARG" 1>&2 && exit_abnormal
      ;;
    :)
      log "1" "Missing option argument for -$OPTARG" 1>&2 && exit_abnormal
      ;;
    *)
      log "1" "Unimplemented option: -$OPTARG" 1>&2 && exit_abnormal
      ;;
  esac
done

[ "$CONFIG" == "" ] && log "1" "Missing mandatory -c argument." 1>&2 && exit_abnormal
source "$CONFIG" &>/dev/null

touch $PIDFILE &>/dev/null
[ ! -w "$PIDFILE" ] && log "1" "Unable to write to $PIDFILE." 1>&2 && exit_abnormal
SECONDS="clear";
PID="$(cat $PIDFILE)" && ps -p "$PID" &>/dev/null && grep "$SCRIPT_NAME" </proc/"$PID"/cmdline &>/dev/null && \
  while [ "$SECONDS" -lt "$PID_TIMEOUT" ]; do
    log "2" "$SCRIPT_NAME process with PID $(cat $PIDFILE) exist. Waiting 10 seconds with timeout $PID_TIMEOUT seconds."
    sleep 10
    PID="$(cat $PIDFILE)" && ps -p "$PID" &>/dev/null && grep "$SCRIPT_NAME" </proc/"$PID"/cmdline &>/dev/null
    RETVAL="$?"
    if [ "$RETVAL" -ne 0 ]; then
      break
    fi
  done
PID="$(cat $PIDFILE)" && ps -p "$PID" &>/dev/null && grep "$SCRIPT_NAME" </proc/"$PID"/cmdline &>/dev/null && \
        log "1" "$SCRIPT_NAME process with PID $(cat $PIDFILE) exist. Exiting.." && exit 1
echo $$ > $PIDFILE

[ "$LOCKFILE_OVERRIDE" != "" ] && LOCKFILE="$LOCKFILE_OVERRIDE"
[ "$UCUPN_OVERRIDE" != "" ] && UCUPN="$UCUPN_OVERRIDE"

[ "$UNDERCLOUDRC" == "" ] && log "1" "Variable UNDERCLOUDRC is unset." 1>&2 && exit_abnormal
[ "$OVERCLOUDRC" == "" ] && log "1" "Variable OVERCLOUDRC is unset." 1>&2 && exit_abnormal 
[ "$LOCKFILE" == "" ] && log "1" "Variable LOCKFILE is unset." 1>&2 && exit_abnormal
[ "$UCUPN" == "" ] && log "1" "Variable UCUPN is unset." 1>&2 && exit_abnormal
[ "$AGG_GROUPS" == "" ] && log "1" "Variable AGG_GROUPS is unset." 1>&2 && exit_abnormal
[ "$SHUTDOWN_TIMEOUT" == "" ] && log "1" "Variable SHUTDOWN_TIMEOUT is unset." 1>&2 && exit_abnormal
[ "$STARTUP_TIMEOUT" == "" ] && log "1" "Variable STARTUP_TIMEOUT is unset." 1>&2 && exit_abnormal

if  [[ ( "$SHUTDOWN_TIMEOUT" -ge 0 ) ]]; then
  echo &>/dev/null
else
  log "1" "Incrorrect SHUTDOWN_TIMEOUT value in $CONFIG."
  exit 1
fi
if  [[ ( "$STARTUP_TIMEOUT" -ge 0 ) ]]; then
  echo &>/dev/null
else
  log "1" "Incrorrect STARTUP_TIMEOUT value in $CONFIG."
  exit 1
fi
if  [[ ( "$UCUPN" -gt 0 ) && ( "$UCUPN" -le 100 ) ]]; then 
  echo &>/dev/null
else
  log "1" "Incrorrect UCUPN value."
  exit 1
fi
if [ "$LOCKFILE_OVERRIDE" == "false" ]; then
  if test -r "$LOCKFILE" -a -f "$LOCKFILE" ; then 
    log "2" "Lock file $LOCKFILE exist. Script is not going to take any action."
    exit 0
  fi
else
  log "2" "Lock file override enabled."
fi
test -r "$UNDERCLOUDRC" -a -f "$UNDERCLOUDRC" && openstack_undercloud catalog list &>/dev/null
RETVAL=$?
[ "$RETVAL" -ne 0 ] && log "1" "Unable to access undercloud catalog using $UNDERCLOUDRC as a rc file." && exit 1
test -r "$OVERCLOUDRC" -a -f "$OVERCLOUDRC" && openstack_overcloud catalog list &>/dev/null
RETVAL=$?
[ "$RETVAL" -ne 0 ] && log "1" "Unable to access overcloud catalog using $OVERCLOUDRC as a rc file." && exit 1

for agg_group in $(echo "$AGG_GROUPS"|tr ',' ' ')
do
  openstack_overcloud aggregate show "$agg_group" &>/dev/null
  RETVAL=$?
  if [ "$RETVAL" -ne 0 ]; then
    log "1" "Unable to find aggregation group $agg_group"
  else 
    agg_group_hypervisor_list="$(openstack_overcloud aggregate show "$agg_group" -f json -c hosts |jq --raw-output '.hosts[]')"
    agg_group_hypervisor_filter="$(echo "$agg_group_hypervisor_list"|tr '\n' '|'|sed 's/|$//g')"

    hyp_list="$(openstack_overcloud hypervisor list --long -f value -c "Hypervisor Hostname" -c "vCPUs Used" -c "State"|grep -E "$agggroup_hypervisor_filter"|sort)"
    computes_number="$(echo "$hyp_list"|wc -l)"
    computes_number_up_with_vm="$(echo "$hyp_list"|grep " up "|grep -vc " 0$")"
    computes_number_down_with_vm="$(echo "$hyp_list"|grep " down "|grep -vc " 0$")"
    computes_number_up_before_logic="$(echo "$hyp_list"|grep -c " up ")"
    computes_number_up_after_logic="$((computes_number_up_with_vm + computes_number * UCUPN / 100))"
    [ "$computes_number_up_after_logic" -gt "$computes_number" ] && computes_number_up_after_logic="$computes_number"
    computes_number_difference="$((computes_number_up_before_logic - computes_number_up_after_logic))"
    computes_hostnames_up="$(echo "$hyp_list"|grep " up "|awk '{print $1}')"
    computes_hostnames_up_available_for_shutdown="$(echo "$hyp_list"|grep " up "|grep " 0$"|awk '{print $1}')"
    computes_hostnames_down_with_no_vm="$(echo "$hyp_list"|grep " down "|grep " 0$"|awk '{print $1}')"
    computes_hostnames_down_with_vm="$(echo "$hyp_list"|grep " down "|grep -v " 0$"|awk '{print $1}')"

    #NO ACTION
    if [ "$computes_number_difference" -eq 0 ]; then
      log "0" "Percentage of empty computes configured: $UCUPN%"
      log "0" "Number of hypervisors in aggregation group $agg_group: $computes_number"
      log "0" "Number of hypervisors in aggregation group $agg_group up: $computes_number_up_before_logic"
      log "0" "Expected number of hypervisors in aggregation group $agg_group up: $computes_number_up_after_logic"
      log "0" "Hypervisors in aggregation group $agg_group up: $(echo $computes_hostnames_up)"
      log "0" "Hypervisors in aggregation group $agg_group down: $(echo $computes_hostnames_down_with_no_vm)"
      log "0" "No action needed." 
      [ "$computes_number_down_with_vm" -ne 0 ] && log "2" "IMPORTANT: hypervisors in aggregation group $agg_group down with VMs: $(echo $computes_hostnames_down_with_vm)"
    fi
    #COMPUTES SHUTDOWN
    if [ "$computes_number_difference" -gt 0 ]; then
      computes_hostnames_to_disable="$(echo "$computes_hostnames_up_available_for_shutdown"|tail -"$computes_number_difference")"
      computes_hostnames_to_shutdown="$(echo "$computes_hostnames_up_available_for_shutdown"|tail -"$computes_number_difference"|awk -F\. '{print $1}')"
      log "0" "Percentage of empty computes configured: $UCUPN%"
      log "0" "Number of hypervisors in aggregation group $agg_group: $computes_number"
      log "0" "Number of hypervisors in aggregation group $agg_group up: $computes_number_up_before_logic"
      log "0" "Expected number of hypervisors in aggregation group $agg_group up: $computes_number_up_after_logic"
      log "0" "Hypervisors in aggregation group $agg_group up: $(echo $computes_hostnames_up)"
      log "0" "Hypervisors in aggregation group $agg_group down: $(echo $computes_hostnames_down_with_no_vm)"
      if [ "$TESTMODE" == "false" ]; then
        log "0" "Disabling nova-compute service for hypervisors: $(echo $computes_hostnames_to_disable) now.."
        echo "$computes_hostnames_to_disable"| while read -r host; do openstack_overcloud compute service set --disable --disable-reason "$SCRIPT_NAME" "$host" nova-compute; done
        log "0" "Shutting down hypervisors: $(echo $computes_hostnames_to_disable) now.."
        echo "$computes_hostnames_to_shutdown"| while read -r host; do openstack_undercloud server stop "$host"; done
        log "0" "Waiting for hypervisors to be down with timeout $SHUTDOWN_TIMEOUT seconds"
        SECONDS="clear"; 
        filter="$(echo "$computes_hostnames_to_disable"|tr '\n' '|'|sed 's/|$//g')"
        while [ "$SECONDS" -lt "$SHUTDOWN_TIMEOUT" ]; do 
          openstack_overcloud hypervisor list --long -f value -c "Hypervisor Hostname" -c "State"|grep -E "$filter"|grep " up$" &>/dev/null || break
          sleep 10
        done
        openstack_overcloud hypervisor list --long -f value -c "Hypervisor Hostname" -c "State"|grep -E "$filter"|grep " up$" &>/dev/null
        RETVAL=$?
        if [ "$RETVAL" -eq 0 ]; then
          compute_hostnames_to_disable_still_up="$(openstack_overcloud hypervisor list --long -f value -c "Hypervisor Hostname" -c "State"|grep -E "$filter"|grep " up$"|awk '{print $1}'|sort)"
          log "1" "Computes still up after timeout: $( echo $compute_hostnames_to_disable_still_up)." 
        fi
        log "0" "Enabling nova-compute service for hypervisors: $(echo $computes_hostnames_to_disable) now.."
        echo "$computes_hostnames_to_disable"| while read -r host; do openstack_overcloud compute service set --enable "$host" nova-compute; done
      else
        log "2" "Script in TEST MODE. No action is taken on hypervisors."
        log "0" "Hypervisors for shutdown: $(echo $computes_hostnames_to_disable)"
      fi
      [ "$computes_number_down_with_vm" -ne 0 ] && log "2" "IMPORTANT: hypervisors in aggregation group $agg_group down with VMs: $(echo $computes_hostnames_down_with_vm)"
    fi
    #COMPUTES STARTUP
    if [ "$computes_number_difference" -lt 0 ]; then
      computes_number_to_startup="${computes_number_difference/-/}"
      computes_hostnames_to_enable="$(echo "$computes_hostnames_down_with_no_vm"|head -"$computes_number_to_startup")"
      computes_hostnames_to_startup="$(echo "$computes_hostnames_down_with_no_vm"|head -"$computes_number_to_startup"|awk -F\. '{print $1}')"
      log "0" "Percentage of empty computes configured: $UCUPN%"
      log "0" "Number of hypervisors in aggregation group $agg_group: $computes_number"
      log "0" "Number of hypervisors in aggregation group $agg_group up: $computes_number_up_before_logic"
      log "0" "Expected number of hypervisors in aggregation group $agg_group up: $computes_number_up_after_logic"
      log "0" "Hypervisors in aggregation group $agg_group up: $(echo $computes_hostnames_up)"
      log "0" "Hypervisors in aggregation group $agg_group down: $(echo $computes_hostnames_down_with_no_vm)"
      if [ "$TESTMODE" == "false" ]; then
        log "0" "Starting up hypervisors: $(echo $computes_hostnames_to_enable) now.."
        echo "$computes_hostnames_to_startup"| while read -r host; do openstack_undercloud server start "$host"; done
        log "0" "Waiting for hypervisors to startup with timeout $STARTUP_TIMEOUT seconds"
        SECONDS="clear";
        filter="$(echo "$computes_hostnames_to_enable"|tr '\n' '|'|sed 's/|$//g')"
        while [ "$SECONDS" -lt "$STARTUP_TIMEOUT" ]; do
          openstack_overcloud hypervisor list --long -f value -c "Hypervisor Hostname" -c "State"|grep -E "$filter"|grep " down$" &>/dev/null || break
          sleep 10
        done
        openstack_overcloud hypervisor list --long -f value -c "Hypervisor Hostname" -c "State"|grep -E "$filter"|grep " down$" &>/dev/null
        RETVAL=$?
        if [ "$RETVAL" -eq 0 ]; then
          compute_hostnames_to_startup_still_down="$(openstack_overcloud hypervisor list --long -f value -c "Hypervisor Hostname" -c "State"|grep -E "$filter"|grep " down$"|awk '{print $1}'|sort)"
          log "1" "Computes still down after timeout: $(echo $compute_hostnames_to_startup_still_down)."
        fi
        log "0" "Enabling nova-compute service for hypervisors: $(echo $computes_hostnames_to_enable) now.."
        echo "$computes_hostnames_to_enable"| while read -r host; do openstack_overcloud compute service set --enable "$host" nova-compute; done
      else
        log "2" "Script in TEST MODE. No action is taken on hypervisors."
        log "0" "Hypervisors for startup: $(echo $computes_hostnames_to_enable)"
      fi
      [ "$computes_number_down_with_vm" -ne 0 ] && log "2" "IMPORTANT: hypervisors in aggregation group $agg_group down with VMs: $(echo $computes_hostnames_down_with_vm)"
    fi
  fi
done
