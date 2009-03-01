#!/usr/bin/env bash
#*
#* PPSS, the Parallel Processing Shell Script
#* 
#* Copyright (c) 2009, Louwrentius
#* All rights reserved.
#*
#* Redistribution and use in source and binary forms, with or without
#* modification, are permitted provided that the following conditions are met:
#*     * Redistributions of source code must retain the above copyright
#*       notice, this list of conditions and the following disclaimer.
#*     * Redistributions in binary form must reproduce the above copyright
#*       notice, this list of conditions and the following disclaimer in the
#*       documentation and/or other materials provided with the distribution.
#*     * Neither the name of the <organization> nor the
#*       names of its contributors may be used to endorse or promote products
#*       derived from this software without specific prior written permission.
#*
#* THIS SOFTWARE IS PROVIDED BY Louwrentius ''AS IS'' AND ANY
#* EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
#* WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
#* DISCLAIMED. IN NO EVENT SHALL Louwrentius BE LIABLE FOR ANY
#* DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
#* (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
#* LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
#* ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
#* (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
#* SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


#------------------------------------------------------
# It should not be necessary to edit antyhing.
# Ofcource you can if it is necesary for your needs.
# Send a patch if your changes may benefit others.
#------------------------------------------------------

# Handling control-c for a clean shutdown.
trap 'kill_process; ' INT

# Setting some vars. Do not change. 
SCRIPT_NAME="Distributed Parallel Processing Shell Script"
SCRIPT_VERSION="1.99"

MODE="$1"
shift
ARGS=$@
CONFIG="config.cfg"
DAEMON=0
HOSTNAME=`hostname`
ARCH=`uname`
RUNNING_SIGNAL="$0_is_running"          # Prevents running mutiple instances of PPSS.. 
GLOBAL_LOCK="PPSS-GLOBAL-LOCK"          # Global lock file used by local PPSS instance.
PAUSE_SIGNAL="pause_signal"                # Not implemented yet (pause processing).
PAUSE_DELAY=300
STOP_SIGNAL="stop_signal"
ARRAY_POINTER_FILE="ppss-array-pointer" # 
JOB_LOG_DIR="JOB_LOG"                   # Directory containing log files of processed items.
LOGFILE="ppss-log.txt"                  # General PPSS log file. Contains lots of info.
STOP=9                                  # STOP job.
MAX_DELAY=2
PERCENT="0"
PID="$$"
LISTENER_PID=""
IFS_BACKUP="$IFS"
INTERVAL="10"                           # Polling interval to check if there are running jobs.

SSH_SERVER=""                           # Remote server or 'master'.
SSH_KEY=""                              # SSH key for ssh account.
SSH_SOCKET="/tmp/PPSS-ssh-socket"       # Multiplex multiple SSH connections over 1 master.
SSH_OPTS="-o BatchMode=yes -o ControlPath=$SSH_SOCKET -o GlobalKnownHostsFile=./known_hosts -o ControlMaster=auto -o ConnectTimeout=5"
SSH_MASTER_PID=""

PPSS_HOME_DIR="ppss"
ITEM_LOCK_DIR="PPSS_ITEM_LOCK_DIR"      # Remote directory on master used for item locking.
PPSS_LOCAL_TMPDIR="PPSS_LOCAL_TMPDIR" # Local directory on slave for local processing.
PPSS_LOCAL_OUTPUT="PPSS_LOCAL_OUTPUT" # Local directory on slave for local output.
TRANSFER_TO_SLAVE="0"                   # Transfer item to slave via (s)cp.
SECURE_COPY="1"                         # If set, use SCP, Otherwise, use cp.
REMOTE_OUTPUT_DIR=""                    # Remote directory to which output must be uploaded.
SCRIPT=""                               # Custom user script that is executed by ppss.


showusage () {
    
    echo 
    echo "$SCRIPT_NAME"
    echo "Version: $SCRIPT_VERSION"
    echo 
    echo "Description: this script processess files or other items in parallel. It is designed to make"
    echo "use of the multi-core CPUs. It will detect the number of available CPUs and start a thread "
    echo "for each CPU core. It will also use hyperthreading if available." It has also support for
    echo "distributed usage, using a Master server in conjunction with (multiple) slaves."
    echo 
    echo "Usage: $0 [ options ]"
    echo 
    echo "Options are:"
    echo 
    echo -e "\t- c \tCommand to execute. Can be a custom script or just a plain command."
    echo -e "\t- d \tDirectory containing items to be processed."
    echo -e "\t- f \tFile containing items to be processed. (Alternative to -d)" 
    echo -e "\t- l \tSpecifies name and location of the logfile."
    echo -e "\t- p \tSpecifies number of simultaneous processes manually. (optional)"
    echo -e "\t- j \tEnable or disable hyperthreading. Enabled by default. (optional)"
    echo
    echo "Options for distributed usage:"
    echo 
    echo -e "\t- s \tUsername@server domain name or IP-address of 'PPSS master server'."
    echo -e "\t- k \tSSH key file used for connection with 'PPSS master server'."
    echo -e "\t- t \tTransfer remote item to slave for local processing."
    echo -e "\t- o \tUpload output back to server into this directory."
    echo -e "\t- b \tDo *not* use scp for item transfer but use cp. "
    echo 
    echo -e "Example: encoding some wav files to mp3 using lame:"
    echo 
    echo -e "$0 -c 'lame ' -d /path/to/wavfiles -l logfile -j (wach out for the space in -c)" 
    echo    
}

kill_process () {

    kill $LISTENER_PID >> /dev/null 2>&1
    while true
    do
        JOBS=`ps ax | grep -v grep | grep -v -i screen | grep ppss.sh | grep -i bash | wc -l`
        if [ "$JOBS" -gt "2" ]
        then
            for x in `ps ax | grep -v grep | grep -v -i screen | grep ppss.sh | grep -i bash | awk '{ print $1 }'`
            do
                if [ ! "$x" == "$PID" ] && [ ! "$x" == "$$" ]
                then
                    kill -9 $x >> /dev/null 2>&1
                fi
            done
            sleep 5
        else
            cleanup 
            echo -en "\033[1B"
            # The master SSH connection should be killed.
            if [ ! -z "$SSH_MASTER_PID" ]
            then
                kill -9 "$SSH_MASTER_PID"
            fi
            echo ""
            exit 0
        fi
    done
    
}

exec_cmd () { 

    CMD="$1"

    if [ ! -z "$SSH_SERVER" ]
    then
        ssh $SSH_OPTS $SSH_KEY $USER@$SSH_SERVER $CMD
    else
        eval "$CMD"
    fi
}

# this function makes remote or local checking of existence of items transparent.
does_file_exist () {

    FILE="$1"
    `exec_cmd "ls -1 $FILE" >> /dev/null 2>&1`
    if [ "$?" == "0" ]
    then
        return 0
    else 
        return 1
    fi
}

check_for_interrupt () {

    does_file_exist "$STOP_SIGNAL"
    if [ "$?" == "0" ]
    then
        log INFO "STOPPING job. Stop signal found."
        STOP="1"
    fi

    does_file_exist "$PAUSE_SIGNAL"
    if [ "$?" == "0" ]
    then
        log INFO "PAUSE: sleeping for $PAUSE_DELAY seconds."
        sleep $PAUSE_DELAY
        check_for_interrupt
    fi
}

cleanup () {

    #log DEBUG "$FUNCNAME - Cleaning up all temp files and processes."
    
    if [ -e "$FIFO" ]
    then 
        rm $FIFO 
    fi

    if [ -e "$ARRAY_POINTER_FILE" ] 
    then
        rm $ARRAY_POINTER_FILE
    fi

    if [ -e "$GLOBAL_LOCK" ] 
    then
        rm -rf $GLOBAL_LOCK
    fi

    if [ -e "$RUNNING_SIGNAL" ]
    then
        rm "$RUNNING_SIGNAL"
    fi

    if [ -e "$SSH_SOCKET" ]
    then
        rm -rf "$SSH_SOCKET"
    fi

}

# check if ppss is already running.
is_running () {

    if [ -e "$RUNNING_SIGNAL" ]
    then
        echo 
        log INFO "$0 is already running (lock file exists)."
        echo
        exit 1
    fi
}


add_var_to_config () {
    
    if [ "$MODE" == "config" ]
    then

        VAR="$1"
        VALUE="$2"

        echo -e "$VAR=$VALUE" >> $CONFIG
    fi
}

# Process any command-line options that are specified."
while [ $# -gt 0 ]
do
    case $1 in
        -config )
            CONFIG="$2"

            if [ "$MODE" == "config" ]
            then
                if [ -e "$CONFIG" ]
                then
                    echo "Do want to overwrite existing config file?"
                    read yn
                    if [ "$yn" == "y" ]
                    then
                        rm "$CONFIG"
                    else
                        echo "Aborting..."
                        cleanup
                        exit
                    fi 
                fi
            fi

            if [ ! "$MODE" == "config" ]
            then
                source $CONFIG
            fi

            if [ ! -z "$SSH_KEY" ]
            then
                SSH_KEY="-i $SSH_KEY"
            fi

            shift 2
            ;;
        -n ) 
            NODES_FILE="$2"
            shift 2
            ;;

        -f )
            INPUT_FILE="$2"
            add_var_to_config INPUT_FILE "$INPUT_FILE"
            shift 2
            ;;
        -d ) 
            SRC_DIR="$2"
            add_var_to_config SRC_DIR "$SRC_DIR"
            shift 2
            ;; 
        -D )
            DAEMON=1
            add_var_to_config DAEMON "$DAEMON"
            shift 2
            ;;
        -c ) 
            COMMAND=$2
            if [ "$MODE" == "config" ]
            then
                COMMAND=\'$COMMAND\'
                add_var_to_config COMMAND "$COMMAND"
            fi
            shift 2
            ;;

        -h )
            showusage
            exit 1;;
        -j )
            HYPERTHREADING=yes
            add_var_to_config HYPERTHREADING "yes"
            shift 1
            ;;
        -l )
            LOGFILE="$2"
            add_var_to_config LOGFILE "$LOGFILE"
            shift 2
            ;;
        -k )
            SSH_KEY="$2"
            add_var_to_config SSH_KEY "$SSH_KEY"
            if [ ! -z "$SSH_KEY" ]
            then
                SSH_KEY="-i $SSH_KEY"
            fi
            shift 2
            ;;
        -b )
            SECURE_COPY=0
            add_var_to_config SECURE_COPY "$SECURE_COPY"
            shift 1
            ;;
        -o )
            REMOTE_OUTPUT_DIR="$2"
            add_var_to_config REMOTE_OUTPUT_DIR "$REMOTE_OUTPUT_DIR"
            shift 2
            ;;
        -p )
            TMP="$2"
            if [ ! -z "$TMP" ]
            then
                MAX_NO_OF_RUNNING_JOBS="$TMP"
                add_var_to_config MAX_NO_OF_RUNNING_JOBS "$MAX_NO_OF_RUNNING_JOBS" 
                shift 2
            fi
            ;;
        -s ) 
            SSH_SERVER="$2"
            add_var_to_config SSH_SERVER "$SSH_SERVER"
            shift 2
            ;;
        -S )
            SCRIPT="$2"
            add_var_to_config SCRIPT "$SCRIPT"
            shift 2
            ;;
        -t )
            TRANSFER_TO_SLAVE="1"    
            add_var_to_config TRANSFER_TO_SLAVE "$TRANSFER_TO_SLAVE"
            shift 1
            ;;
        -u )
            USER="$2"
            add_var_to_config USER "$USER"
            shift 2
            ;;

        -v )
            echo ""
            echo "$SCRIPT_NAME version $SCRIPT_VERSION"
            echo ""
            exit 0
            ;;
        * )
            showusage
            exit 1;;
    esac
done

# Init all vars
init_vars () {

    if [ -e "$LOGFILE" ]
    then
        rm $LOGFILE
    fi

    if [ -z "$COMMAND" ]
    then
        echo
        echo "ERROR - no command specified."
        echo
        showusage
        cleanup
        exit 1
    fi

    echo 0 > $ARRAY_POINTER_FILE

    FIFO=$(pwd)/fifo-$RANDOM-$RANDOM

    if [ ! -e "$FIFO" ]
    then    
        mkfifo -m 600 $FIFO
    fi

    exec 42<> $FIFO

    touch $RUNNING_SIGNAL

    if [ -z "$MAX_NO_OF_RUNNING_JOBS" ]
    then 
        MAX_NO_OF_RUNNING_JOBS=`get_no_of_cpus $HYPERTHREADING`
    fi

    does_file_exist "$JOB_LOG_DIR"
    if [ ! "$?" == "0" ]
    then
        log INFO "Job log directory $JOB_lOG_DIR does not exist. Creating."
        exec_cmd "mkdir $JOB_LOG_DIR"
    else
        log INFO "Job log directory $JOB_LOG_DIR exists, if it contains logs for items, these items will be skipped."
    fi

    does_file_exist "$ITEM_LOCK_DIR"
    if [ ! "$?" == "0" ] && [ ! -z "$SSH_SERVER" ]
    then
        log DEBUG "Creating remote item lock dir."
        exec_cmd "mkdir $ITEM_LOCK_DIR"
    fi

    if [ ! -e "$JOB_LOG_DIR" ]
    then
        mkdir "$JOB_LOG_DIR"
    fi

    does_file_exist "$REMOTE_OUTPUT_DIR"
    if [ ! "$?" == "0" ]
    then
        echo "ERROR: remote output dir $REMOTE_OUTPUT_DIR does not exist."
        cleanup
        exit
    fi

    if [ ! -e "$PPSS_LOCAL_TMPDIR" ] && [ ! -z "$SSH_SERVER" ]
    then
        mkdir "$PPSS_LOCAL_TMPDIR"
    fi

    if [ ! -e "$PPSS_LOCAL_OUTPUT" ] && [ ! -z "$SSH_SERVER" ]
    then
        mkdir "$PPSS_LOCAL_OUTPUT"
    fi
}

expand_str () {

    STR=$1
    LENGTH=$TYPE_LENGTH
    SPACE=" "

    while [ "${#STR}" -lt "$LENGTH" ]
    do
        STR=$STR$SPACE
    done

    echo "$STR"
}

log () {

    TYPE="$1"
    MESG="$2"
    TMP_LOG=""
    TYPE_LENGTH=6 

    TYPE_EXP=`expand_str "$TYPE"`

    DATE=`date +%b\ %d\ %H:%M:%S`
    PREFIX="$DATE: ${TYPE_EXP:0:$TYPE_LENGTH} -"

    LOG_MSG="$PREFIX $MESG"

    echo -e "$LOG_MSG" >> "$LOGFILE"

    if [ "$TYPE" == "INFO" ] && [ "$DAEMON" == "0" ]
    then
        echo -e "$LOG_MSG"
    fi

}

log INFO "$0 $@"

check_status () {

    ERROR="$1"
    FUNCTION="$2"
    MESSAGE="$3"

    if [ ! "$ERROR" == "0" ]
    then
        log INFO "$FUNCTION - $MESSAGE"
        cleanup
        exit 1
    fi

}

erase_ppss () {

    echo "Are you realy sure you want to erase PPSS from all nades!?"
    read YN

    if [ "$YN" == "y" ]
    then
        for NODE in `cat $NODES_FILE`
        do
            log INFO "Erasing PPSS homedir $PPSS_HOME_DIR from node $NODE."
            ssh $USER@$NODE "rm -rf $PPSS_HOME_DIR"
        done
    fi
}

deploy_ppss () {

    ERROR=0

    set_error () {

        if [ ! "$1" == "0" ]
        then
            ERROR=$1 
        fi
    }
    
    KEY=`echo $SSH_KEY | cut -d " " -f 2` 
    if [ -z "$KEY" ] || [ ! -e "$KEY" ]
    then
        log INFO "ERROR - nodes require a key file."
        cleanup
        exit 1
    fi

    if [ ! -e "$SCRIPT" ]
    then
        log INFO "ERROR - script $SCRIPT not found."
        cleanup
        exit 1
    fi

    if [ ! -e "$NODES_FILE" ]
    then
        log INFO "ERROR file $NODES with list of nodes does not exist."
        cleanup
        exit 1
    else
        for NODE in `cat $NODES_FILE` 
        do
            ssh -q $USER@$NODE "mkdir $PPSS_HOME_DIR >> /dev/null 2>&1" 
            scp -q $SSH_OPTS $0 $USER@$NODE:~/$PPSS_HOME_DIR
            set_error $?
            scp -q $KEY $USER@$NODE:~/$PPSS_HOME_DIR
            set_error $?
            scp -q $CONFIG $USER@$NODE:~/$PPSS_HOME_DIR
            set_error $?
            scp -q known_hosts $USER@$NODE:~/$PPSS_HOME_DIR
            set_error $?
            scp -q $SCRIPT $USER@$NODE:~/$PPSS_HOME_DIR
            set_error $?
            if [ ! -z "$INPUT_FILE" ]
            then
                scp -q $INPUT_FILE $USER@$NODE:~/$PPSS_HOME_DIR
                set_error $?
            fi

            if [ "$ERROR" == "0" ]
            then
                log INFO "PPSS installed on node $NODE."
            else
                log INFO "PPSS failed to install on $NODE."
            fi
        done
    fi
}

start_ppss_on_node () {

    NODE="$1"

    log INFO "Starting PPSS on node $NODE."
    ssh $USER@$NODE "cd $PPSS_HOME_DIR ; screen -d -m -S PPSS ./ppss.sh node -config $CONFIG" 
}


test_server () {

    # Testing if the remote server works as expected.
    if [ ! -z "$SSH_SERVER" ] 
    then
        exec_cmd "date >> /dev/null"
        check_status "$?" "$FUNCNAME" "Server $SSH_SERVER could not be reached"

        ssh -N -M $SSH_OPTS $SSH_KEY $USER@$SSH_SERVER &
        SSH_MASTER_PID="$!"
    else
        log DEBUG "No remote server specified, assuming stand-alone mode."
    fi
}

get_no_of_cpus () {

    # Use hyperthreading or not?
    HPT=$1
    NUMBER=""

    if [ -z "$HPT" ]
    then
        HPT=no
    fi

    got_cpu_info () {

    ERROR="$1"
    check_status "$ERROR" "$FUNCNAME" "cannot determine number of cpu cores. Specify with -p." 

    }

    if [ "$HPT" == "yes" ]
    then
        if [ "$ARCH" == "Linux" ]
        then
            NUMBER=`cat /proc/cpuinfo | grep processor | wc -l`
            got_cpu_info "$?"
            
        elif [ "$ARCH" == "Darwin" ]
        then
            NUMBER=`sysctl -a hw | grep -w logicalcpu | awk '{ print $2 }'`
            got_cpu_info "$?"
        elif [ "$ARCH" == "FreeBSD" ]
        then
            NUMBER=`sysctl hw.ncpu | awk '{ print $2 }'`
            got_cpu_info "$?"
        else
            NUMBER=`cat /proc/cpuinfo | grep processor | wc -l`
            got_cpu_info "$?"
        fi
    elif [ "$HPT" == "no" ]
    then
        if [ "$ARCH" == "Linux" ]
        then
            RES=`cat /proc/cpuinfo | grep "cpu cores"`
            if [ "$?" == "0" ]
            then
                NUMBER=`cat /proc/cpuinfo | grep "cpu cores" | cut -d ":" -f 2 | uniq | sed -e s/\ //g`
                got_cpu_info "$?"
            else
                NUMBER=`cat /proc/cpuinfo | grep processor | wc -l`
                got_cpu_info "$?"
            fi
        elif [ "$ARCH" == "Darwin" ]
        then
            NUMBER=`sysctl -a hw | grep -w physicalcpu | awk '{ print $2 }'`
            got_cpu_info "$?"
        elif [ "$ARCH" == "FreeBSD" ]
        then
            NUMBER=`sysctl hw.ncpu | awk '{ print $2 }'`
            got_cpu_info "$?"
        else
            NUMBER=`cat /proc/cpuinfo | grep "cpu cores" | cut -d ":" -f 2 | uniq | sed -e s/\ //g`
            got_cpu_info "$?"
        fi

    fi

    if [ ! -z "$NUMBER" ]
    then
        echo "$NUMBER"
    else
        log INFO "$FUNCNAME ERROR - number of CPUs not obtained."
        exit 1
    fi
}


random_delay () {

    ARGS="$1"

    if [ -z "$ARGS" ]
    then
        log ERROR "$FUNCNAME Function random delay, no argument specified."
        exit 1
    fi

    NUMBER=$RANDOM
    let "NUMBER %= $ARGS"
    sleep "$NUMBER"
}


global_lock () {

    mkdir $GLOBAL_LOCK > /dev/null 2>&1
    ERROR="$?"

    if [ ! "$ERROR" == "0" ]
    then
        return 1
    else
        return 0
    fi
}

get_global_lock () {

    while true
    do
        global_lock
        ERROR="$?"
        if [ ! "$ERROR" == "0" ]
        then
            random_delay $MAX_DELAY
            continue
        else
            break
        fi
    done
}

release_global_lock () {

    rm -rf "$GLOBAL_LOCK"
}

are_jobs_running () {
   
    NUMBER_OF_PROCS=`jobs | wc -l`
    if [ "$NUMBER_OF_PROCS" -gt "1" ]
    then
        return 0
    else
        return 1
    fi
}

download_item () {

    ITEM="$1"
    ITEM_WITH_PATH="$SRC_DIR/$ITEM"

    if [ "$TRANSFER_TO_SLAVE" == "1" ]
    then
        log DEBUG "Transfering item $ITEM to local disk."
        if [ "$SECURE_COPY" == "1" ]
        then
            scp -q $SSH_OPTS $SSH_KEY $USER@$SSH_SERVER:"$ITEM_WITH_PATH" $PPSS_LOCAL_TMPDIR
            log DEBUG "Exit code of transfer is $?"
        else
            cp "$ITEM_WITH_PATH" $PPSS_LOCAL_TMPDIR 
            log DEBUG "Exit code of transfer is $?"
        fi
    fi
}

upload_item () {

    ITEM="$1"

    log DEBUG "Uploading item $ITEM."
    if [ "$SECURE_COPY" == "1" ]
    then
        #scp -q $SSH_OPTS $SSH_KEY $PPSS_LOCAL_OUTPUT/"$ITEM"/* $USER@$SSH_SERVER:$REMOTE_OUTPUT_DIR
        scp -q $SSH_OPTS $SSH_KEY $ITEM $USER@$SSH_SERVER:$REMOTE_OUTPUT_DIR
        ERROR="$?"
        if [ ! "$ERROR" == "0" ]
        then
            log DEBUG "ERROR - uploading of $ITEM failed."
        else
            log DEBUG "Upload of item $ITEM success" 
            rm $ITEM
        fi
    else    
        cp "$PPSS_LOCAL_OUTPUT/$ITEM" $REMOTE_OUTPUT_DIR
        ERROR="$?"
        if [ ! "$ERROR" == "0" ]
        then
            log DEBUG "ERROR - uploading of $ITEM failed."
        fi
    fi
}

lock_item () {
    
    if [ ! -z "$SSH_SERVER" ]
    then
        ITEM="$1"
        LOCK_FILE_NAME=`echo $ITEM | sed s/^\\\.//g |sed s/^\\\.\\\.//g | sed s/\\\///g`
        ITEM_LOCK_FILE="$ITEM_LOCK_DIR/$LOCK_FILE_NAME"
        log DEBUG "Trying to lock item $ITEM."
        exec_cmd "mkdir $ITEM_LOCK_FILE >> /dev/null 2>&1"
        ERROR="$?"
        return "$ERROR"
    fi
}

release_item () {

    ITEM="$1"
   
    LOCK_FILE_NAME=`echo $ITEM` # | sed s/^\\.//g | sed s/^\\.\\.//g | sed s/\\\///g`
    ITEM_LOCK_FILE="$ITEM_LOCK_DIR/$LOCK_FILE_NAME"

    exec_cmd "rm -rf ./$ITEM_LOCK_FILE"
}

get_all_items () {

    count=0

    if [ -z "$INPUT_FILE" ]
    then
        if [ ! -z "$SSH_SERVER" ] # Are we running stand-alone or as a slave?"
        then
            ITEMS=`exec_cmd "ls -1 $SRC_DIR"`
            check_status "$?" "$FUNCNAME" "Could not list files within remote source directory."
        else 
            ITEMS=`ls -1 $SRC_DIR`
        fi
        IFS="
"
        for x in $ITEMS
        do
            ARRAY[$count]="$x"
            ((count++))
        done
        IFS=$IFS_BACKUP
    else
        if [ ! -z "$SSH_SERVER" ] # Are we running stand-alone or as a slave?"
        then
            log DEBUG "Running as slave, input file has been pushed (hopefully)."
            if [ ! -e "$INPUT_FILE" ]
            then
                log INFO "ERROR - input file $INPUT_FILE does not exist."
            fi
            #scp -q $SSH_OPTS $SSH_KEY $USER@$SSH_SERVER:~/"$INPUT_FILE" >> /dev/null 2>&1
            #check_status "$?" "$FUNCNAME" "Could not copy input file $INPUT_FILE."
        fi
    
        exec 10<$INPUT_FILE

        while read LINE <&10
        do
            ARRAY[$count]=$LINE
            ((count++))
        done
  
    fi
    exec 10>&-

    SIZE_OF_ARRAY="${#ARRAY[@]}"
    if [ "$SIZE_OF_ARRAY" -le "0" ]
    then
        echo "ERROR: source file/dir seems to be empty."
        cleanup
        exit 1
    fi
}

get_item () {

    check_for_interrupt

    if [ "$STOP" == "1" ]
    then
        return 1
    fi

    get_global_lock

    SIZE_OF_ARRAY="${#ARRAY[@]}"

    # Return error if the array is empty.
    if [ "$SIZE_OF_ARRAY" -le "0" ]
    then
        release_global_lock
        return 1
    fi

    # This variable is used to walk thtough all array items.
    ARRAY_POINTER=`cat $ARRAY_POINTER_FILE`

    # Gives a status update on the current progress..
    PERCENT=$((100 * $ARRAY_POINTER / $SIZE_OF_ARRAY ))
    log INFO "Currently $PERCENT percent complete. Processed $ARRAY_POINTER of $SIZE_OF_ARRAY items." 
    echo -en "\033[1A"

    # Check if all items have been processed.
    if [ "$ARRAY_POINTER" -ge "$SIZE_OF_ARRAY" ]
    then
        release_global_lock
        return 2
    fi

    # Select an item. 
    ITEM="${ARRAY[$ARRAY_POINTER]}" 
    if [ -z "$ITEM" ]
    then
        ((ARRAY_POINTER++))
        echo $ARRAY_POINTER > $ARRAY_POINTER_FILE
        release_global_lock
        get_item
    else
        ((ARRAY_POINTER++))
        echo $ARRAY_POINTER > $ARRAY_POINTER_FILE
        lock_item "$ITEM"
        if [ ! "$?" == "0" ]
        then
            log DEBUG "Item $ITEM is locked."
            release_global_lock
            get_item
        else
            log DEBUG "Got lock on $ITEM, processing."
            release_global_lock
            download_item "$ITEM"
            return 0
        fi
    fi
}

start_single_worker () {

    get_item
    ERROR=$?
    if [ ! "$ERROR" == "0" ]
    then
        log DEBUG "Item empty, we are probably almost finished."
        return 1
    else
        get_global_lock
        echo "$ITEM" > $FIFO
        release_global_lock
        return 0
    fi
}

commando () {

    ITEM="$1"
    ITEM_NO_PATH="$1"

    log DEBUG "Processing item $ITEM"

    if [ -z "$INPUT_FILE" ] && [ "$TRANSFER_TO_SLAVE" == "0" ]
    then
        ITEM="$SRC_DIR/$ITEM"
    else
        ITEM="$PPSS_LOCAL_TMPDIR/$ITEM"
    fi

    LOG_FILE_NAME=`echo "$ITEM" | sed s/^\\\.//g | sed s/^\\\.\\\.//g | sed s/\\\///g`
    ITEM_LOG_FILE="$JOB_LOG_DIR/$LOG_FILE_NAME"

    mkdir $PPSS_LOCAL_OUTPUT/"$ITEM_NO_PATH"

    does_file_exist "$ITEM_LOG_FILE"
    if [ "$?" == "0" ]
    then
        log DEBUG "Skipping item $ITEM - already processed." 
    else
        
        ERROR=""

        # Some formatting of item log files. 
        DATE=`date +%b\ %d\ %H:%M:%S`
        echo "=== PPSS Item Log File ===" > "$ITEM_LOG_FILE"
        echo -e "Host:\t$HOSTNAME" >> "$ITEM_LOG_FILE"
        echo -e "Date:\t$DATE" >> "$ITEM_LOG_FILE"
        echo -e "Item:\t$ITEM" >> "$ITEM_LOG_FILE"

        # The actual execution of the command.
        TMP=`echo $COMMAND | grep -i '$ITEM'`
        if [ "$?" == "0"  ]
        then 
            eval "$COMMAND" >> "$ITEM_LOG_FILE" 2>&1
            ERROR="$?"
        else
            EXECME='$COMMAND"$ITEM" >> "$ITEM_LOG_FILE" 2>&1'
            eval "$EXECME"
            ERROR="$?"
        fi

        # Some error logging. Success or fail.
        if [ ! "$ERROR" == "0" ] 
        then
           echo -e "Status:\tError - something went wrong." >> "$ITEM_LOG_FILE"
        else
           echo -e "Status:\tSucces - item has been processed." >> "$ITEM_LOG_FILE"
        fi

        if [ "$TRANSFER_TO_SLAVE" == "1" ]      
        then
            if [ -e "$ITEM" ]
            then
                rm $ITEM
            else        
                log DEBUG "ERROR Something went wrong removing item $ITEM from local work dir."
            fi

        fi

        if [ ! -z "$REMOTE_OUTPUT_DIR" ]
        then
            upload_item "$PPSS_LOCAL_OUTPUT/$ITEM_NO_PATH/*"
        fi

        if [ ! -z "$SSH_SERVER" ]
        then
            log DEBUG "Uploading item log file $ITEM_LOG_FILE to master."
            scp -q $SSH_OPTS $SSH_KEY $ITEM_LOG_FILE $USER@$SSH_SERVER:~/$JOB_LOG_DIR 
        fi
    fi

    start_single_worker
    return $?
}

# This is the listener service. It listens on the pipe for events.
# A job is executed for every event received.
listen_for_job () {

    log INFO "Listener started."
    while read event <& 42
    do
        commando "$event" &
    done
}

# This starts an number of parallel workers based on the # of parallel jobs allowed.
start_all_workers () {

    if [ "$MAX_NO_OF_RUNNING_JOBS" == "1" ]
    then
        log INFO "Starting $MAX_NO_OF_RUNNING_JOBS worker."
    else
        log INFO "Starting $MAX_NO_OF_RUNNING_JOBS workers."
    fi

    i=0
    while [ "$i" -lt "$MAX_NO_OF_RUNNING_JOBS" ]
    do
        start_single_worker
        ((i++))
    done
}

show_status () {

    source $CONFIG
    if [ ! -z "$SSH_KEY" ]
    then
        SSH_KEY="-i $SSH_KEY"
    fi

    if [ -z "$INPUT_FILE" ]
    then
        ITEMS=`exec_cmd "ls -1 $SRC_DIR | wc -l"`
    else
        ITEMS=`exec_cmd "cat $INPUT_FILE | wc -l"` 
    fi
    
    PROCESSED=`exec_cmd "ls -1 $ITEM_LOCK_DIR | wc -l"`
    STATUS=$((100 * $PROCESSED / $ITEMS))

    log INFO "$STATUS percent complete."

}


# If this is called, the whole framework will execute.
main () {
    
    is_running    
    log DEBUG "---------------- START ---------------------"
    log INFO "$SCRIPT_NAME version $SCRIPT_VERSION"
    log INFO `hostname`

    case $MODE in
        node ) 
                    init_vars
                    test_server
                    get_all_items
                    listen_for_job "$MAX_NO_OF_RUNNING_JOBS" &
                    LISTENER_PID=$!
                    start_all_workers
                    ;;
        server )
                    # This option only starts all nodes.
                    init_vars
                
                    if [ ! -e "$NODES_FILE" ]
                    then
                        log INFO "ERROR file $NODES with list of nodes does not exist."
                        cleanup
                        exit 1
                    else
                        for NODE in `cat $NODES_FILE`
                        do
                            start_ppss_on_node "$NODE"
                        done
                    fi
                    cleanup
                    exit 0
                    ;;
        config )

                    log INFO "Generating configuration file $CONFIG"
                    add_var_to_config PPSS_LOCAL_TMPDIR "$PPSS_LOCAL_TMPDIR"
                    add_var_to_config PPSS_LOCAL_OUTPUT "$PPSS_LOCAL_OUTPUT"
                    cleanup
                    exit 0
                    ;;

        stop )
                    #some stop
                    ;;
        deploy )
                    deploy_ppss
                    cleanup
                    exit 0
                    ;;
        status )
                    show_status
                    cleanup
                    exit 0
                    # some show command
                    ;;
        erase )
                    erase_ppss
                    cleanup
                    exit 0
                    ;;
        * )
                    showusage
                    exit 1
                    ;;
    esac

}
# This command starts the that sets the whole framework in motion.
main

# Either start new jobs or exit, sleep in the meantime.
while true
do
    sleep 5
    JOBS=`ps ax | grep -v grep | grep -v -i screen | grep ppss.sh | wc -l`
    log INFO "JOBS is jobs: $JOBS"
    
    MIN_JOBS=3

    if [ "$ARCH" == "Darwin" ]
    then
        MIN_JOBS=4
    elif [ "$ARCH" == "Linux" ]
    then
        MIN_JOBS=3
    fi

    if [ "$JOBS" -gt "$MIN_JOBS" ] 
    then
        log INFO "Sleeping $INTERVAL..." 
        sleep $INTERVAL
    else
            echo -en "\033[1B"
            log INFO "There are no more running jobs, so we must be finished."
            echo -en "\033[1B"
            log INFO "Killing listener and remainig processes."
            log INFO "Dying processes may display an error message."
            kill_process
    fi
done

# Exit after all processes have finished.
wait
