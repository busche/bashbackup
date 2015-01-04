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

# actual backup directory
TARGET="/some/path/to/dailyBackups"

# array of source folders to make a backup from
SOURCES=(/root /etc /boot )

# edit or comment with "#"
DATEPATTERN=+%Y%m%d_%H%M%S
if [ 'x'$OSTYPE = 'xcygwin' ]; then
	echo "$0: I am running in a cygwin environment!"
	RSYNCCONF=(-HS -rltD --delete)
else
	echo "$0: Running in a Linux environment."
RSYNCCONF=(-AHS -a --delete --exclude=/backupscripts/*.log --exclude=/home/postgres-datenbanken --exclude=/home/ismll-backups) # --dry-run)
fi

# to whom to send a mail
MAILREC="me@host.com"
# both need to be defined jointly
USE_SSH="no"
# The test is 
# if ()(SSHUSER && SSHPORT) || SSHKEY_COPIED)
SSHUSER=`whoami`
SSHPORT="22"
#SSHKEY_COPIED=1

# one of those need to be defined!
#FROMSSH="source.server.com"
#TOSSH="target.server.com"
FROMSSH=""
TOSSH=""

### do not edit ###
# init variables
ERROR=0
LOGDATEPATTERN=+%Y%m%d%H%M%S

#
# called on script end.
function cleanup() {
	echo -n "$0: Cleaning temporary files... "
	rm -f ${LOCKFILE}
	rm -f ${DETAILLOG}
	rm -r ${SUMMARYLOG}
	echo "OK"
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

if [ $# -gt 0 ]; then
	# include the parameters from the first argument (pointing to a file) if give if given
	echo "$0: Including definitions from $1 ..."
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
	unset MAILREC	
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

LAST="last"; INC="--link-dest=../$LAST"

set -e # Abort on error
set -u # Abort when unbound variables are used

LOCKFILE=$0.lock
echo "$0: Backup starts at "`${DATE} ${LOGDATEPATTERN}` > $DETAILLOG
echo "$0: Backup starts at "`${DATE} ${LOGDATEPATTERN}` > $SUMMARYLOG

# check temp temp file. I won't start the backup if this file exists.
# 
if [ -f ${LOCKFILE} ]; then
	echo "$0: It appears as if a backup is already running (File ${LOCKFILE} esists). Stopping here. Maybe delete the lock file if you know what you are doing..."
	mexit 1
fi
touch ${LOCKFILE}

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
#	echo "$0: Mountpoint ${MOUNTPOINT} found"
#else
#	mount -t nfs -o nfsvers=3 ${REMOTE_ADDRESS} ${MOUNTPOINT}
#fi

if [ "${TARGET:${#TARGET}-1:1}" != "/" ]; then
  TARGET=$TARGET/
fi
echo "$0: Target is $TARGET"

TODAY=$($DATE ${DATEPATTERN})
S=""
if [ ${USE_SSH} = "yes" ]; then
	echo -n "$0: Configuring SSH ... "
  if [ "$SSHUSER" ] && [ "$SSHPORT" ]; then
 	  S="$SSH -p $SSHPORT -l $SSHUSER";
  fi
	echo $S
#		if [ -z ${S} ] && ${SSHKEY_COPIED} ; then
			# simply define the variable
#			S=""
#		fi
fi # of ${SSH} = yes
for SOURCE in "${SOURCES[@]}"
  do
  echo $SOURCE
		backup_status=0
		echo "$0: Currently (`$DATE ${LOGDATEPATTERN} `) working on ${SOURCE}" >> $SUMMARYLOG
     if [ "$S" ] && [ "$FROMSSH" ] && [ "${#TOSSH}" = 0 ]; then
			# SSH connection from a host,  to local
      $ECHO "$0: $RSYNC -e \"$S\" -xvR \"$FROMSSH:$SOURCE\" ${RSYNCCONF[@]} $TARGET$TODAY $INC" >> $SUMMARYLOG
			$RSYNC -e "$S" -xvR "$FROMSSH:$SOURCE" ${RSYNCCONF[@]} $TARGET$TODAY $INC  >> $DETAILLOG
			backup_status=$?
    fi
    if [ "$S" ]  && [ "$TOSSH" ] && [  "${#FROMSSH}" = 0 ]; then
			# ssh connection to a server,  from local
      $ECHO "$0: $RSYNC -e \"$S\" -xvR \"$SOURCE\" ${RSYNCCONF[@]} \"$TOSSH:$TARGET$TODAY\" $INC " >> $SUMMARYLOG
      $RSYNC -e "$S"  -xvR "$SOURCE" "${RSYNCCONF[@]}" $TOSSH:"\"$TARGET\"$TODAY" $INC >> $DETAILLOG 2>&1 
			backup_status=$?
    fi
    if [ -z "$S" ]; then
			# no ssh connection; backup locally
      $ECHO "$0: $RSYNC -xvR \"$SOURCE\" ${RSYNCCONF[@]} $TARGET$TODAY $INC" >> $SUMMARYLOG 
      $RSYNC -xvR "$SOURCE" "${RSYNCCONF[@]}" "$TARGET"$TODAY $INC  >> $DETAILLOG 2>&1 
			backup_status=$?
			echo "$0: Backup size of ${SOURCE} is "`du -sh "$TARGET"$TODAY"${SOURCE}"` >> $SUMMARYLOG 2>&1
    fi
		if [ ! ${backup_status} = 0 ]; then
			echo "$0: ERROR: Return status was ${backup_status}." >> ${SUMMARYLOG}
			ERROR=3
		fi
done

echo "$0: Finished the backup on `$DATE ${LOGDATEPATTERN} `" >> $SUMMARYLOG

if [ ! ${ERROR} = 0 ]; then
	mexit ${ERROR}
fi

# copy log file.
if [ "$S" ]  && [ "$TOSSH" ] && [  "${#FROMSSH}" = 0 ]; then
	# ssh connection to a server,  from local
	scp -P $SSHPORT ${DETAILLOG} ${SSHUSER}@${TOSSH}:${TARGET}/${TODAY}/"detail.log"
fi

if [ -z "$S" ]; then
	cp ${DETAILLOG} ${TARGET}/${TODAY}/"detail.log"
	chmod a+r  ${TARGET}/${TODAY}/"detail.log"
fi

# do not create new links if an error occurred ...
if [ "$S" ] && [ "$TOSSH" ] && [ -z "$FROMSSH" ]; then
 	$ECHO "$0: $SSH -p $SSHPORT -l $SSHUSER $TOSSH $LN -nsf $TARGET$TODAY $TARGET$LAST" >> $SUMMARYLOG  
  $SSH -p $SSHPORT -l $SSHUSER $TOSSH "$LN -nsf \"$TARGET\"$TODAY \"$TARGET\"$LAST" >> $DETAILLOG 2>&1
 	if [ $? -ne 0 ]; then
    ERROR=4
 	fi
fi
if ( [ "$S" ] && [ "$FROMSSH" ] && [ -z "$TOSSH" ] ) || ( [ -z "$S" ] );  then
 	$ECHO "$0: $LN -nsf $TARGET$TODAY $TARGET$LAST" >> $SUMMARYLOG
  $LN -nsf "$TARGET"$TODAY "$TARGET"$LAST  >> $DETAILLOG 2>&1
 	if [ $? -ne 0 ]; then
    ERROR=4
 	fi
fi

if [ ! ${ERROR} = 0 ]; then
  mexit ${ERROR}
fi

if [ ! 'x'${MAIL} = 'x' ]; then
	echo "$0: Sending mail to $MAILREC ..."
	echo "$0: Backup complete" >> $SUMMARYLOG
	$MAIL -s "Backup `hostname` $0 $1" $MAILREC < $SUMMARYLOG
fi

echo "$0: Now dumping the summary file..."
cat $SUMMARYLOG

cleanup

exit 0
