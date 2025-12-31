#!/bin/bash
# Simple backup with rsync
# local-mode, tossh-mode, fromssh-mode

#
# return values
#   0 all fine
#   1 current backup ongoing
#   2 SSH configuration error
#   3 An error ocurred during rsync
#   4 An error ocurred during ln of the new backup folder
#   5 If rsync was not found.
#   6 If ssh was not found.
#   7 RSYNCOPTS or RSYNCCONF not configured as Bash arrays (new check)

# Important configuration notes:
# - RSYNCCONF and RSYNCOPTS must be defined as Bash arrays, e.g.:
#     RSYNCCONF=( -HS -a )
#     RSYNCOPTS=( --dry-run )
#   The script will exit with code 7 if either variable is not an array. This
#   ensures safe, correct quoting when building the rsync argument array.

# actual backup directory
TARGET="/some/path/to/dailyBackups"

# array of source folders to make a backup from
SOURCES=(/root /etc /boot )

# edit or comment with "#"
DATEPATTERN=+%Y%m%d_%H%M%S
DATEPATTERN=+%d  # gets overridden by config file.
if [ 'x'$OSTYPE = 'xcygwin' ]; then
        echo "$0: I am running in a cygwin environment!"
        RSYNCCONF=(-HS -rltD --delete)
else
        echo "$0: Running in a Linux environment."
        RSYNCCONF=(-HS -a )
fi
# dummy initialization
#RSYNCOPTS=( --dry-run )
RSYNCOPTS=(  )

# to whom to send a mail
MAILREC="me@host.com"
# both need to be defined jointly
USE_SSH="no"
# The test is
# if ()(SSHUSER && SSHPORT) || SSHKEY_COPIED)
SSHUSER=`whoami`
SSHPORT="22"

# one of those need to be defined!
#FROMSSH="source.server.com"
#TOSSH="target.server.com"
FROMSSH=""
TOSSH=""

### do not edit ###
# init variables
ERROR=0
LOGDATEPATTERN=+%Y%m%d%H%M%S

# number of trials per source to try to rsync
TRIALS=0


#
# called on script end.
function cleanup() {
        log_detail "" "$0: Cleaning temporary files..."
        if [ -n "${LOCKFILE}" ] && [ -f "${LOCKFILE}" ]; then
                rm -f "${LOCKFILE}" || true
                rc=$?
                log_detail "$rc" "$0: removed lockfile ${LOCKFILE}"
        fi
        if [ -n "${DETAILLOG}" ] && [ -f "${DETAILLOG}" ]; then
                rm -f "${DETAILLOG}" || true
                rc=$?
                log_detail "$rc" "$0: removed detail log ${DETAILLOG}"
        fi
        if [ -n "${SUMMARYLOG}" ] && [ -f "${SUMMARYLOG}" ]; then
                rm -f "${SUMMARYLOG}" || true
                rc=$?
                log_detail "$rc" "$0: removed summary log ${SUMMARYLOG}"
        fi
        log_detail "" "$0: cleanup done"
}

# errorous end of the script. shows an error message and returns a value != 0,  passed as first argument.
function mexit() {
        echo "$0: Error. Some error occurred while performing the backup."
        if [ ! 'x'${MAIL} = 'x' ]; then
                $MAIL -s "Error Backup $0 $1" $MAILREC < $SUMMARYLOG
        fi
        cleanup

        exit $1
}

# Logging helpers: write timestamped messages to SUMMARYLOG and DETAILLOG.
# Usage:
#   last_rc=$?; log_summary "$last_rc" "message"
#   log_summary_trunc "$last_rc" "message"    # overwrite file
# If last_rc is empty, rc is omitted.
function log_summary() {
        local rc="$1"
        shift || true
        if [ -z "${SUMMARYLOG+set}" ]; then
                return
        fi
        if [ -n "$rc" ]; then
                printf '%s %s (rc=%s)\n' "$($DATE '+%Y-%m-%d %H:%M:%S')" "$*" "$rc" >> "$SUMMARYLOG"
        else
                printf '%s %s\n' "$($DATE '+%Y-%m-%d %H:%M:%S')" "$*" >> "$SUMMARYLOG"
        fi
}

function log_summary_trunc() {
        local rc="$1"
        shift || true
        if [ -n "$rc" ]; then
                printf '%s %s (rc=%s)\n' "$($DATE '+%Y-%m-%d %H:%M:%S')" "$*" "$rc" > "$SUMMARYLOG"
        else
                printf '%s %s\n' "$($DATE '+%Y-%m-%d %H:%M:%S')" "$*" > "$SUMMARYLOG"
        fi
}

function log_detail() {
        local rc="$1"
        shift || true
        if [ -z "${DETAILLOG+set}" ]; then
                return
        fi
        if [ -n "$rc" ]; then
                printf '%s %s (rc=%s)\n' "$($DATE '+%Y-%m-%d %H:%M:%S')" "$*" "$rc" >> "$DETAILLOG"
        else
                printf '%s %s\n' "$($DATE '+%Y-%m-%d %H:%M:%S')" "$*" >> "$DETAILLOG"
        fi
}

function log_detail_trunc() {
        local rc="$1"
        shift || true
        if [ -n "$rc" ]; then
                printf '%s %s (rc=%s)\n' "$($DATE '+%Y-%m-%d %H:%M:%S')" "$*" "$rc" > "$DETAILLOG"
        else
                printf '%s %s\n' "$($DATE '+%Y-%m-%d %H:%M:%S')" "$*" > "$DETAILLOG"
        fi
}

# Rsync error code descriptions for better logging and debugging
# Based on rsync documentation: see 'man rsync' section EXIT VALUES
function rsync_error_description() {
        local rc="$1"
        case "$rc" in
                0)   echo "Success" ;;
                1)   echo "Syntax or usage error" ;;
                2)   echo "Protocol incompatibility" ;;
                3)   echo "Errors selecting input/output files, dirs" ;;
                4)   echo "Requested action not supported: an attempt was made to manipulate 64-bit files on a platform that cannot support them; or an option was specified that is not supported on this build of rsync" ;;
                5)   echo "Error starting client-server protocol" ;;
                6)   echo "Daemon unable to append to log-file" ;;
                10)  echo "Error in socket I/O" ;;
                11)  echo "Error in file I/O" ;;
                12)  echo "Error in rsync protocol data stream" ;;
                13)  echo "Errors with program diagnostics" ;;
                14)  echo "Error in IPC code" ;;
                20)  echo "Received SIGUSR1 or SIGINT" ;;
                21)  echo "Some error returned by waitpid()" ;;
                22)  echo "Error allocating core memory buffers" ;;
                23)  echo "Partial transfer due to error" ;;
                24)  echo "Partial transfer due to vanished source files" ;;
                25)  echo "The --max-delete limit stopped deletions" ;;
                30)  echo "Timeout in data send/receive" ;;
                35)  echo "Timeout waiting for daemon connection" ;;
                *)   echo "Unknown error code: $rc" ;;
        esac
}

if [ $# -gt 0 ]; then
        # include the parameters from the first argument (pointing to a file) if given
        log_summary "" "$0: Including definitions from $1 ..."
        . $1
fi

MOUNT="/bin/mount"; FGREP="/bin/fgrep"
SSH=`which ssh`
if [ 'x' = 'x'${SSH} ]; then
        echo "$0: fatal: no ssh found."
        exit 6
fi

LN="/bin/ln"; ECHO="/bin/echo"; DATE="/bin/date"; RM="/bin/rm"
AWK="/usr/bin/awk";
MAIL=`which mail`
if [ 'x'${MAIL} = 'x' ]; then
        # no mail program found!
        echo "$0: no mail program found. Not sending any mail!"
        MAILREC=""
fi
#"/usr/bin/mail"
MKTEMP=`which mktemp`
if [ 'x' = 'x'${MKTEMP} ]; then
        echo "$0: no mktemp command found. Using fake log files (in place!)"
        DETAILLOG=$0.detail.log
        SUMMARYLOG=$0.summary.log
else
        DETAILLOG=`mktemp /tmp/detail_XXXXXXXX`
        SUMMARYLOG=`mktemp /tmp/summary_XXXXXXXX`

fi
RSYNC=`which rsync`
if [ 'x'${RSYNC} = 'x' ]; then
        echo "$0: fatal: no rsync found."
        exit 5
fi

# Initialize logs EARLY - before any log_detail() calls
# This ensures all log_detail() and log_summary() calls have valid file paths
log_detail_trunc "" "$0: Log initialized"
log_summary_trunc "" "$0: Log initialized"

# Log environment & configuration summary for debugging (one variable per line)
log_detail "" "$0: startup.pid=$$"
log_detail "" "$0: startup.user=$(whoami)"
log_detail "" "$0: startup.cwd=$(pwd)"
log_detail "" "$0: startup.args=$*"

# Tools / patterns
log_detail "" "$0: RSYNC=$RSYNC"
log_detail "" "$0: SSH=$SSH"
log_detail "" "$0: DATEPATTERN=$DATEPATTERN"
log_detail "" "$0: LOGDATEPATTERN=$LOGDATEPATTERN"

# Configuration values
log_detail "" "$0: TARGET=$TARGET"
idx=0
for s in "${SOURCES[@]}"; do
        log_detail "" "$0: SOURCE[$idx]=$s"
        idx=$((idx+1))
done
log_detail "" "$0: USE_SSH=$USE_SSH"
log_detail "" "$0: FROMSSH=$FROMSSH"
log_detail "" "$0: TOSSH=$TOSSH"
log_detail "" "$0: SSHUSER=$SSHUSER"
log_detail "" "$0: SSHPORT=$SSHPORT"
log_detail "" "$0: TRIALS=$TRIALS"

LAST="last"; INC="--link-dest=../$LAST"

DRY_RUN=0
for OPT in "${RSYNCCONF[@]}" "${RSYNCOPTS[@]}" ; do
#for OPT in "${RSYNCCONF[@]}" "${RSYNCOPTS[@]}"]} ; do
        if [ $OPT = '--dry-run' ]; then
                echo "$0: --dry-run detected."
                DRY_RUN=1
        fi
        if [ $OPT = '-n' ]; then
                echo "$0: --dry-run detected."
                DRY_RUN=1
        fi
done

if [ ${#RSYNCOPTS[@]} = 0 ]; then
        # keep RSYNCOPTS as an empty array (not a string) so later code can
        # safely use "${RSYNCOPTS[@]}" without type errors
        RSYNCOPTS=()
fi

# Ensure RSYNCOPTS and RSYNCCONF are arrays. If not, fail early.
# Use ${VAR[@]} syntax test: if this works without error, VAR is an array.
# This is more robust than 'declare -p' across different Bash versions.
if ! ( : "${RSYNCOPTS[@]}" ) 2>/dev/null; then
	echo "$0: fatal: RSYNCOPTS is not an array. Please define RSYNCOPTS as a Bash array." >&2
	mexit 7
fi

if ! ( : "${RSYNCCONF[@]}" ) 2>/dev/null; then
	echo "$0: fatal: RSYNCCONF is not an array. Please define RSYNCCONF as a Bash array." >&2
	mexit 7
fi

set -u # Abort when unbound variables are used
# Do NOT use 'set -e' globally - we need custom error handling in the rsync loop
# set -e #immediate exit if something fails, e.g., network connection terminated.

LOCKFILE=$1.lock

# Log that backup process is starting
log_detail "" "$0: Backup starts at `$DATE ${LOGDATEPATTERN}`"
log_summary "" "$0: Backup starts at `$DATE ${LOGDATEPATTERN}`"

# check temp temp file. I won't start the backup if this file exists.
#
if [ -f ${LOCKFILE} ]; then
        echo "$0: It appears as if a backup is already running (File ${LOCKFILE} esists). Stopping here. Maybe delete the lock file if you know what you are doing..."
        mexit 1
fi
touch ${LOCKFILE}
log_detail "" "$0: Created lockfile ${LOCKFILE} (pid=$$)"

if [ ${USE_SSH} = "yes" ]; then
        echo "$0: checking ssh configuration ..."
        if [ -z $FROMSSH ] && [ -z $TOSSH ]; then
                echo "$0: Error: Both \$FROMSSH and \$TOSSH are empty. One of them needs to be set!"
                mexit 2
        fi
        if [ $FROMSSH ] && [ $TOSSH ]; then
                echo "$0: Error: Both \$FROMSSH and \$TOSSH are set to some values. One of them needs to be set, the other needs to be an empty string!"
                mexit 2
        fi
fi

#
# check mountpoint / target location
#
#if  $MOUNT | grep "on ${MOUNTPOINT} type"  >/dev/null
#then
#       echo "$0: Mountpoint ${MOUNTPOINT} found"
#else
#       mount -t nfs -o nfsvers=3 ${REMOTE_ADDRESS} ${MOUNTPOINT}
#fi

if [ "${TARGET:${#TARGET}-1:1}" != "/" ]; then
  TARGET=$TARGET/
fi
log_detail "" "$0: Target is $TARGET"

TODAY=$($DATE ${DATEPATTERN})
YESTERDAY=$($DATE -d "yesterday" ${DATEPATTERN})
S=""
if [ ${USE_SSH} = "yes" ]; then
        echo -n "$0: Configuring SSH ... "
  if [ "$SSHUSER" ] && [ "$SSHPORT" ]; then
          S="$SSH -p $SSHPORT -l $SSHUSER";
  fi
  echo $S
#               if [ -z ${S} ] && ${SSHKEY_COPIED} ; then
                        # simply define the variable
#                       S=""
#               fi
fi # of ${SSH} = yes
for SOURCE in "${SOURCES[@]}"
  do
	echo "SOURCE=${SOURCE}"
                trial=0
                backup_status=0
                log_summary "" "$0: Currently (`$DATE ${LOGDATEPATTERN}`) working on ${SOURCE}"
     if [ "$S" ] && [ "$FROMSSH" ] && [ "${#TOSSH}" = 0 ]; then
                        # SSH connection from a host, to local
                        # Build rsync arguments as an array (safe quoting)
                        rsync_args=("$RSYNC" "-e" "$S")
                        # RSYNCOPTS and RSYNCCONF are guaranteed to be arrays (checked earlier)
                        rsync_args+=("${RSYNCOPTS[@]}")
                        rsync_args+=("-xvR" "$FROMSSH:$SOURCE")
                        rsync_args+=("${RSYNCCONF[@]}" "$TARGET$TODAY" "$INC")

                        ducommand="du -sh \"$TARGET\"$TODAY\"/${SOURCE}\""
#      $ECHO "$0: $RSYNC -e \"$S\" ${RSYNCOPTS[@]} } -xvR \"$FROMSSH:$SOURCE\" ${RSYNCCONF[@]} $TARGET$TODAY $INC" >> $SUMMARYLOG
#                       $RSYNC -e "$S" ${RSYNCOPTS[@]} -xvR "$FROMSSH:$SOURCE" ${RSYNCCONF[@]} $TARGET$TODAY $INC  >> $DETAILLOG
#                       backup_status=$?
    fi
    if [ "$S" ]  && [ "$TOSSH" ] && [  "${#FROMSSH}" = 0 ]; then
                        # ssh connection to a server, from local
                        echo "pounk"
                        rsync_args=("$RSYNC" "-e" "$S")
                        # RSYNCOPTS and RSYNCCONF are guaranteed to be arrays (checked earlier)
                        rsync_args+=("${RSYNCOPTS[@]}")
                        rsync_args+=("-xvR" "$SOURCE")
                        rsync_args+=("${RSYNCCONF[@]}" "$TOSSH:$TARGET$TODAY" "$INC")

                        ducommand="${S} du -sh \"$TARGET\"$TODAY/${SOURCE}"
#      $ECHO "$0: $RSYNC -e \"$S\" ${RSYNCOPTS[@]} -xvR \"$SOURCE\" ${RSYNCCONF[@]} \"$TOSSH:$TARGET$TODAY\" $INC " >> $SUMMARYLOG
#      $RSYNC -e "$S"  ${RSYNCOPTS[@]} -xvR "$SOURCE" "${RSYNCCONF[@]}" $TOSSH:"\"$TARGET\"$TODAY" $INC >> $DETAILLOG 2>&1
#                       backup_status=$?
    fi
    if [ -z "$S" ]; then
                        # no ssh connection; backup locally
                        mkdir -p ${TARGET}
                        rsync_args=("$RSYNC")
                        # RSYNCOPTS and RSYNCCONF are guaranteed to be arrays (checked earlier)
                        rsync_args+=("${RSYNCOPTS[@]}")
                        rsync_args+=("-xvR" "${RSYNCCONF[@]}" "$SOURCE" "$TARGET$TODAY" "$INC")
                        ducommand="du -sh \"$TARGET\"$TODAY\"/${SOURCE}\""
                #       $ECHO "$0: $command" >> $DETAILLOG
                #       eval $command  >> $SUMMARYLOG
                #       backup_status=$?
                #       echo "$0: Backup size of ${SOURCE} is "`du -sh "$TARGET"$TODAY"/${SOURCE}"` >> $SUMMARYLOG 2>&1
    fi
                # perform rsync
                # Log the actually executed rsync command using the argument array
                log_summary "" "$0: ${rsync_args[*]}"
                log_detail "" "$0: ${rsync_args[*]}"
                log_detail "" "$0: Starting rsync for ${SOURCE} (attempt ${trial})"

                # Execute rsync using the array. Respect TRIALS (0 means single try).
                # Disable 'set -e' for this section so we can handle rsync errors gracefully
                set +e
                backup_status=1
                while : ; do
                        # Run rsync and append stdout/stderr to DETAILLOG
                        "${rsync_args[@]}" >> ${DETAILLOG} 2>&1
                        backup_status=$?

                        # Log the return code of the rsync command with description
                        local rsync_msg="$0: rsync finished for source ${SOURCE} (attempt ${trial})"
                        local rsync_desc="$(rsync_error_description $backup_status)"
                        log_detail "$backup_status" "$rsync_msg - reason: $rsync_desc"

                        if [ "$backup_status" = 0 ] || [ ${trial} -ge ${TRIALS} ]; then
                                if [ "$backup_status" = 0 ]; then
                                        ERROR=0
                                        log_summary "" "$0: Successful backup for ${SOURCE}"
                                else
                                        ERROR=3
                                        local rsync_desc_summary="$(rsync_error_description $backup_status)"
                                        log_summary "$backup_status" "$0: Failed backup for ${SOURCE} after ${trial} / ${TRIALS} attempts - rsync error: $rsync_desc_summary"
                                fi
                                break
                        else
                                local rsync_desc_retry="$(rsync_error_description $backup_status)"
                                log_summary "$backup_status" "$0: Failed attempt ${trial} / ${TRIALS} for ${SOURCE} - rsync error: $rsync_desc_retry (retrying...)"
                                trial=$((trial + 1))
                        fi
                done
                set -e

                # perform backup size calculation
                #if [ ! $DRY_RUN = 0 ] && [ $ERROR = 0 ]; then
                #        backup_size=`eval $ducommand | cut -d" " -f1`
                #        echo -n "$0: Backup size of ${SOURCE} is "  >> $SUMMARYLOG 2>&1
                #        echo $backup_size | cut -d" " -f1 >> $SUMMARYLOG 2>&1
                #        echo -n "$0: Backup size of ${SOURCE} is "  >> $DETAILLOG 2>&1
                #        echo $backup_size | cut -d" " -f1 >> $DETAILLOG 2>&1
                #fi
                echo "Sleeping for 5 seconds"
                sleep 5
done

log_summary "" "$0: Finished the backup on `$DATE ${LOGDATEPATTERN}`"
log_detail "" "$0: Finished the backup on `$DATE ${LOGDATEPATTERN}`"

log_summary "${ERROR}" "$0: Finished with ERROR = ${ERROR}"

if [ ! ${ERROR} = 0 ]; then
        mexit ${ERROR}
fi

if [ ${DRY_RUN} = 1 ]; then
        log_summary "" "$0: --dry-run detected. Not running the following ln command ..."
fi
# do not create new links if an error occurred ...
if [ "$S" ] && [ "$TOSSH" ] && [ -z "$FROMSSH" ]; then
        log_summary "" "$0: $SSH -p $SSHPORT -l $SSHUSER $TOSSH $LN -nsf $TARGET$TODAY $TARGET$LAST"
        if [ ${DRY_RUN} = 0 ]; then
                                $LN -nsf $TODAY $LAST
                                rc=$?
                                log_detail "$rc" "$0: ln -nsf $TODAY $LAST (on local, before sending)"

                                $RSYNC -e "$S"  ${RSYNCOPTS[@]} -xvR "$LAST" "${RSYNCCONF[@]}" $TOSSH:$TARGET # no INC
                                rc=$?
                                log_detail "$rc" "$0: rsync of LAST to remote returned"

                                rm $LAST
                                rc=$?
                                if [ $rc -ne 0 ]; then
                                        ERROR=4
                                        log_summary "$rc" "$0: rm $LAST failed"
                                fi

#       $SSH -p $SSHPORT -l $SSHUSER $TOSSH "$LN -nsf \"$TARGET\"$TODAY \"$TARGET\"$LAST" >> $DETAILLOG 2>&1
#               if [ $? -ne 0 ]; then
#         ERROR=4
#               fi
        fi
fi

if ( [ "$S" ] && [ "$FROMSSH" ] && [ -z "$TOSSH" ] ) || ( [ -z "$S" ] );  then
        log_summary "" "$0: $LN -nsf $TARGET$TODAY $TARGET$LAST"
        if [ ${DRY_RUN} = 0 ]; then
echo      $LN -nsf "$TARGET"$TODAY "$TARGET"$LAST # >> $DETAILLOG 2>&1
                $LN -nsf "$TARGET"$TODAY "$TARGET"$LAST # >> $DETAILLOG 2>&1
                rc=$?
                log_detail "$rc" "$0: ln -nsf set last -> $TARGET$TODAY"
#               if [ $? -ne 0 ]; then
#       ERROR=4
#               fi
        fi
fi

set +e #do not exit if something fails, e.g., network connection terminated.

if [ ! ${ERROR} = 0 ]; then
  mexit ${ERROR}
fi

log_detail "" "$0: Trying to obtain the backup size ... I am assuming a remote git-shell and ~/git-shell-commands/du to be available ."
log_detail "" "$0: stat.total_backup_size"
log_detail "" "$SSH -p $SSHPORT ${SSHUSER}@${TOSSH} du $TODAY $YESTERDAY"
$SSH -p $SSHPORT ${SSHUSER}@${TOSSH} du $TODAY $YESTERDAY >> $DETAILLOG 2>&1
rc=$?
log_detail "$rc" "$0: remote du finished (today,yesterday)"

log_detail "" "$SSH -p $SSHPORT ${SSHUSER}@${TOSSH} du \"$TARGET\"$TODAY/ \"$TARGET\"$YESTERDAY"
$SSH -p $SSHPORT ${SSHUSER}@${TOSSH} du "$TARGET"$TODAY/ "$TARGET"$YESTERDAY >> $DETAILLOG 2>&1
rc=$?
log_detail "$rc" "$0: remote du finished (target paths)"

# copy log file.
log_detail "" "DRY_RUN is ${DRY_RUN}"
log_detail "" "Copying current detail.log logfile to backup target"
if [ "$S" ]  && [ "$TOSSH" ] && [  "${#FROMSSH}" = 0 ]; then
    # ssh connection to a server,  from local
    chmod 0777 ${DETAILLOG}
                if [ ${DRY_RUN} = 0 ]; then
                        $RSYNC ${RSYNCOPTS[@]} -xv ${DETAILLOG} ${RSYNCCONF[@]} ${SSHUSER}@${TOSSH}:${TARGET}/${TODAY}/detail.log
                        rc=$?
                        log_detail "$rc" "$0: rsync of detail.log to remote returned"
                fi
fi
log_detail "" "Copying current summary.log logfile to backup target"
if [ "$S" ]  && [ "$TOSSH" ] && [  "${#FROMSSH}" = 0 ]; then
    # ssh connection to a server,  from local
    chmod 0777 ${DETAILLOG}
                if [ ${DRY_RUN} = 0 ]; then
                        $RSYNC ${RSYNCOPTS[@]} -xv ${SUMMARYLOG} ${RSYNCCONF[@]} ${SSHUSER}@${TOSSH}:${TARGET}/${TODAY}/summary.log
                        rc=$?
                        log_detail "$rc" "$0: rsync of summary.log to remote returned"
                fi
fi

if [ -z "$S" ] && [ -d ${TARGET}/${TODAY} ]; then
        cp ${DETAILLOG} ${TARGET}/${TODAY}/"detail.log"
        rc=$?
        chmod a+r  ${TARGET}/${TODAY}/"detail.log"
        log_detail "$rc" "$0: Copied detail.log to ${TARGET}/${TODAY}/detail.log"
        cp ${SUMMARYLOG} ${TARGET}/${TODAY}/"summary.log"
        rc=$?
        chmod a+r  ${TARGET}/${TODAY}/"summary.log"
        log_summary "$rc" "$0: Copied summary.log to ${TARGET}/${TODAY}/summary.log"
fi


if [ ! 'x'${MAIL} = 'x' ] && [ ! 'x'$MAILREC = 'x' ]; then
        echo "$0: Sending mail to $MAILREC ..."
        log_summary "" "$0: Backup complete"
        $MAIL -s "Backup `hostname` $0 $1" $MAILREC < $SUMMARYLOG
        rc=$?
        log_summary "$rc" "$0: mail send returned"
fi

#echo "$0: Now dumping the summary file..."
#cat $SUMMARYLOG

cleanup

exit 0

