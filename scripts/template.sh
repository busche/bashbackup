#!/bin/bash
# Simple backup with rsync
# local-mode, tossh-mode, fromssh-mode

MOUNTPOINT=/path/to/mount/locally
REMOTE_ADDRESS=foreign.server.com:/path/to/backups

if  mount | grep "on ${MOUNTPOINT} type"  >/dev/null
then
echo "Mountpoint found"
else
mount -t nfs -o nfsvers=3 ${REMOTE_ADDRESS} ${MOUNTPOINT}
fi

# array of source folders to make a backup from
SOURCES=(/root /etc /boot )

# target directory to make a backup to
TARGET=${MOUNTPOINT}"/dailyBackups"

# edit or comment with "#"
#LISTPACKAGES=listdebianpackages        # local-mode and tossh-mode
MONTHROTATE=monthrotate                 # use DD instead of YYMMDD

RSYNCCONF=(-AHS --delete --exclude=/backupscripts/*.log --exclude=/home/postgres-datenbanken --exclude=/home/ismll-backups) # --dry-run)
# yet unused.
MOUNTPOINT="/backup"               # check local mountpoint
# to whom to send a mail
MAILREC="me@host.com"

#SSHUSER="user"
#FROMSSH="fromssh-server"
#TOSSH="some.server.com"
#SSHPORT=22

### do not edit ###

MOUNT="/bin/mount"; FGREP="/bin/fgrep"; SSH="/usr/bin/ssh"
LN="/bin/ln"; ECHO="/bin/echo"; DATE="/bin/date"; RM="/bin/rm"
DPKG="/usr/bin/dpkg"; AWK="/usr/bin/awk"; MAIL="/bin/mail"
CUT="/usr/bin/cut"; TR="/usr/bin/tr"; RSYNC="/usr/bin/rsync"
LAST="last"; INC="--link-dest=../$LAST"

LOG=$0.log
MAILLOG=$0.log.short
$DATE > $LOG
$DATE > $MAILLOG


if [ "${TARGET:${#TARGET}-1:1}" != "/" ]; then
  TARGET=$TARGET/
fi

if [ "$LISTPACKAGES" ] && [ -z "$FROMSSH" ]; then
  $ECHO "$DPKG --get-selections | $AWK '!/deinstall|purge|hold/'|$CUT -f1 | $TR '\n' ' '" >> $LOG
  $DPKG --get-selections | $AWK '!/deinstall|purge|hold/'|$CUT -f1 |$TR '\n' ' '  >> $LOG  2>&1 
fi

if [ "$MOUNTPOINT" ]; then
  MOUNTED=$($MOUNT | $FGREP "$MOUNTPOINT");
fi

if [ -z "$MOUNTPOINT" ] || [ "$MOUNTED" ]; then
  if [ -z "$MONTHROTATE" ]; then
    TODAY=$($DATE +%y%m%d)
  else
    TODAY=$($DATE +%m%d)
  fi

  if [ "$SSHUSER" ] && [ "$SSHPORT" ]; then
    S="$SSH -p $SSHPORT -l $SSHUSER";
  fi

  for SOURCE in "${SOURCES[@]}"
    do
      echo ${SOURCE} >> $MAILLOG

      if [ "$S" ] && [ "$FROMSSH" ] && [ -z "$TOSSH" ]; then
        $ECHO "$RSYNC -e \"$S\" -axvR \"$FROMSSH:$SOURCE\" ${RSYNCCONF[@]} $TARGET$TODAY $INC"  >> $LOG 
#        $RSYNC -e "$S" -axvR "$FROMSSH:\"$SOURCE\"" "${RSYNCCONF[@]}" "$TARGET"$TODAY $INC >> $LOG 2>&1 
        if [ $? -ne 0 ]; then
          ERROR=1
        fi 
      fi 
      if [ "$S" ]  && [ "$TOSSH" ] && [ -z "$FROMSSH" ]; then
        $ECHO "$RSYNC -e \"$S\" -axvR \"$SOURCE\" ${RSYNCCONF[@]} \"$TOSSH:$TARGET$TODAY\" $INC " >> $LOG
#        $RSYNC -e "$S" -axvR "$SOURCE" "${RSYNCCONF[@]}" "$TOSSH:\"$TARGET\"$TODAY" $INC >> $LOG 2>&1 
        if [ $? -ne 0 ]; then
          ERROR=1
        fi 
      fi
      if [ -z "$S" ]; then
	# copy locally
        $ECHO "$RSYNC -axvR \"$SOURCE\" ${RSYNCCONF[@]} $TARGET$TODAY $INC"  >> $LOG 
        $RSYNC -axvR "$SOURCE" "${RSYNCCONF[@]}" "$TARGET"$TODAY $INC  >> $LOG 2>&1 
	status=$?
#echo "blub"
	echo `du "$TARGET"$TODAY` >> $MAILLOG 2>&1
        if [ $status -ne 0 ]; then
	  echo $status >> $MAILLOG
          ERROR=1
        fi 
      fi
    $DATE >> $MAILLOG
  done

  if [ "$S" ] && [ "$TOSSH" ] && [ -z "$FROMSSH" ]; then
    $ECHO "$SSH -p $SSHPORT -l $SSHUSER $TOSSH $LN -nsf $TARGET$TODAY $TARGET$LAST" >> $LOG  
    $SSH -p $SSHPORT -l $SSHUSER $TOSSH "$LN -nsf \"$TARGET\"$TODAY \"$TARGET\"$LAST" >> $LOG 2>&1
    if [ $? -ne 0 ]; then
      ERROR=1
    fi 
  fi 
  if ( [ "$S" ] && [ "$FROMSSH" ] && [ -z "$TOSSH" ] ) || ( [ -z "$S" ] );  then
    $ECHO "$LN -nsf $TARGET$TODAY $TARGET$LAST" >> $LOG
    $LN -nsf "$TARGET"$TODAY "$TARGET"$LAST  >> $LOG 2>&1 
    if [ $? -ne 0 ]; then
      ERROR=1
    fi 
  fi
else
  $ECHO "$MOUNTPOINT not mounted" >> $LOG
  ERROR=1
fi
#$DATE >> $LOG

if [ -n "$MAILREC" ]; then
#  echo "should send email"
  if [ $ERROR ];then
    
    $MAIL -s "Error Backup $LOG" $MAILREC < $LOG
  else
    echo "Backup complete" >> $LOG
    echo "Backup complete" >> $MAILLOG
    $MAIL -s "Backup `hostname` $LOG" $MAILREC < $MAILLOG
  fi
fi

#umount ${MOUNTPOINT}
