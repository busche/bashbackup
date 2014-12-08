#!/bin/bash
# Simple backup with rsync
# local-mode, tossh-mode, fromssh-mode

#
# return values
#   1 current backup ongoing

# target directory where to make backups.
# this is a root path; the actual target (sub-)directory is defined in the next variable)
#
#MOUNTPOINT=/path/to/mount/locally
# simply uncomment this (undefine the variable) if you don't want to make backups if the target is not mounted.
MOUNT_IF_UNMOUNTED=1
# if MOUNT_IF_UNMOUNTED=1 and a manual mount happened, unmount the mountpoint afterwards.
UNMOUNT_IF_AUTOMATICALLY_MOUNTED=1
# actual backup directory
TARGET=${MOUNTPOINT}"/dailyBackups"

# remote adress, where to make backups to
REMOTE_ADDRESS=foreign.server.com:/path/to/backups
# array of source folders to make a backup from
SOURCES=(/root /etc /boot )

# edit or comment with "#"
#LISTPACKAGES=listdebianpackages        # local-mode and tossh-mode
#MONTHROTATE=monthrotate                 # use DD instead of YYMMDD
DATEPATTERN=+%y%m%d
RSYNCCONF=(-AHS --delete --exclude=/backupscripts/*.log --exclude=/home/postgres-datenbanken --exclude=/home/ismll-backups) # --dry-run)
# yet unused.
# to whom to send a mail
MAILREC="me@host.com"
# both need to be defined jointly
# The test is 
# if ()(SSHUSER && SSHPORT) || SSHKEY_COPIED)
#SSHUSER="me"
#SSHPORT="22"
#SSHKEY_COPIED=1

#FROMSSH="source.server.com"
#TOSSH="target.server.com"

### do not edit ###

if [ $# -gt 0 ]; then
	# include the parameters from the first argument (pointing to a file) if give if given
	echo "$0: Including definitions from $1 ..."
	. $1
fi

MOUNT="/bin/mount"; FGREP="/bin/fgrep"; SSH="/usr/bin/ssh"
LN="/bin/ln"; ECHO="/bin/echo"; DATE="/bin/date"; RM="/bin/rm"
AWK="/usr/bin/awk"; MAIL="/bin/mail"
RSYNC="/usr/bin/rsync"
LAST="last"; INC="--link-dest=../$LAST"

set -e # Abort on error
set -u # Abort when unbound variables are used

P_MOUNT_IF_UNMOUNTED=1

LOCKFILE=/tmp/$0.lock
DETAILLOG=`tempfile`
SUMMARYLOG=`tempfile`
$DATE > $DETAILLOG
$DATE > $SUMMARYLOG

# check temp temp file. I won't start the backup if this file exists.
# 
if [ -f ${LOCKFILE} ]; then
	echo "$0: It appears as if a backup is already running (File ${LOCKFILE} esists). Stopping here. Maybe delete the lock file if you know what you are doing..."
	exit 1
fi
touch ${LOCKFILE}

#
# check mountpoint / target location
#
#if  $MOUNT | grep "on ${MOUNTPOINT} type"  >/dev/null
#then
#	echo "$0: Mountpoint ${MOUNTPOINT} found"
#else
#	mount -t nfs -o nfsvers=3 ${REMOTE_ADDRESS} ${MOUNTPOINT}
#fi



if [ "${TARGET:${#TARGET}-1:1}" != "/" ]; then
  TARGET=$TARGET/
fi
echo "$0: Target is $TARGET"

if [ "$MOUNTPOINT" ]; then # variable MOUNTPOINT if define, thus ...
	# check whether it is actually mounted
  MOUNTED=$($MOUNT | $FGREP "$MOUNTPOINT");
	if [ -z ${MOUNTED} ]; then # if it is not mounted, then ...
		# try to mount it:
		mount "$MOUNTPOINT"
		if [ ! $? = 0 ]; then # if the mount fails ...
			ERROR=1
			# tell the user  
			echo "$0: failed to mount $MOUNTPOINT. Does it exist in /etc/fstab?"
		else
			P_MOUNT_IF_UNMOUNTED=1
		fi
	fi
else
	echo "$0: No mountpoint given. Assuming local backup"
fi

if [ -z "$MOUNTPOINT" ] || [ "$MOUNTED" ]; then
  TODAY=$($DATE ${DATEPATTERN})
  if [ "$SSHUSER" ] && [ "$SSHPORT" ]; then
    S="--rsh='$SSH -p $SSHPORT -l $SSHUSER'";
  fi
	if [ -z ${S} ] && ${SSHKEY_COPIED} ; then
		# simply define the variable
		S=""
	fi
  for SOURCE in "${SOURCES[@]}"
    do
      echo ${SOURCE} >> $SUMMARYLOG
      if [ "$S" ] && [ "$FROMSSH" ] && [ -z "$TOSSH" ]; then
				# SSH connection from a host,  to local
        $ECHO "$RSYNC \"$S\" -axvR \"$FROMSSH:$SOURCE\" ${RSYNCCONF[@]} $TARGET$TODAY $INC"  >> $DETAILLOG
#        $RSYNC -e "$S" -axvR "$FROMSSH:\"$SOURCE\"" "${RSYNCCONF[@]}" "$TARGET"$TODAY $INC >> $LOG 2>&1
        if [ $? -ne 0 ]; then
          ERROR=1
        fi
      fi
      if [ "$S" ]  && [ "$TOSSH" ] && [ -z "$FROMSSH" ]; then
				# ssh connection to a server,  from local
        $ECHO "$RSYNC \"$S\" -axvR \"$SOURCE\" ${RSYNCCONF[@]} \"$TOSSH:$TARGET$TODAY\" $INC " >> $DETAILLOG
#        $RSYNC -e "$S" -axvR "$SOURCE" "${RSYNCCONF[@]}" "$TOSSH:\"$TARGET\"$TODAY" $INC >> $LOG 2>&1 
        if [ $? -ne 0 ]; then
          ERROR=1
        fi
      fi
      if [ -z "$S" ]; then
				# no ssh connection; backup locally
        $ECHO "$RSYNC -axvR \"$SOURCE\" ${RSYNCCONF[@]} $TARGET$TODAY $INC"  >> $SUMMARYLOG 
        $RSYNC -axvR "$SOURCE" "${RSYNCCONF[@]}" "$TARGET"$TODAY $INC  >> $DETAILLOG 2>&1 
				status=$?
				echo `du "$TARGET"$TODAY` >> $SUMMARYLOG 2>&1
        if [ $status -ne 0 ]; then
				  echo $status >> $SUMMARYLOG
          ERROR=1
        fi
      fi
    $DATE >> $MAILLOG
  done

  if [ "$S" ] && [ "$TOSSH" ] && [ -z "$FROMSSH" ]; then
    $ECHO "$SSH -p $SSHPORT -l $SSHUSER $TOSSH $LN -nsf $TARGET$TODAY $TARGET$LAST" >> $SUMMARYLOG  
    $SSH -p $SSHPORT -l $SSHUSER $TOSSH "$LN -nsf \"$TARGET\"$TODAY \"$TARGET\"$LAST" >> $DETAILLOG 2>&1
    if [ $? -ne 0 ]; then
      ERROR=1
    fi
  fi
  if ( [ "$S" ] && [ "$FROMSSH" ] && [ -z "$TOSSH" ] ) || ( [ -z "$S" ] );  then
    $ECHO "$LN -nsf $TARGET$TODAY $TARGET$LAST" >> $SUMMARYLOG
    $LN -nsf "$TARGET"$TODAY "$TARGET"$LAST  >> $DETAILLOG 2>&1
    if [ $? -ne 0 ]; then
      ERROR=1
    fi
  fi
else
  $ECHO "$0: $MOUNTPOINT not mounted" >> $SUMMARYLOG
  ERROR=1
fi

if [ -n "$MAILREC" ]; then
#  echo "should send email"
  if [ $ERROR ];then
    
    $MAIL -s "Error Backup $LOG" $MAILREC < $SUMMARYLOG
  else
    echo "Backup complete" >> $SUMMARYLOG
    echo "Backup complete" >> $DETAILLOG
    $MAIL -s "Backup `hostname` $LOG" $MAILREC < $SUMMARYLOG
  fi
fi
rm -f /tmp/$0.tmp
rm -f ${DETAILLOG}
rm -r ${SUMMARYLOG}

if [ ${UNMOUNT_IF_AUTOMATICALLY_MOUNTED} ] && [ ${MOUNT_IF_UNMOUNTED} ]; then
	umount ${MOUNTPOINT}
fi
