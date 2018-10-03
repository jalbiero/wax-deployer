#!/usr/bin/env bash

#
#
# Generic helper functions
#
#

# Global variables
WAX_SCRIPT_DIR=$(dirname $(realpath $0))

if [ -z "$WAX_VERSION_FILE" ]; then
    WAX_VERSION_FILE=$WAX_SCRIPT_DIR/version-list.txt
fi



# Arg $1: Menu title
# Arg $2: String array with menu options
# Return: Option index starting from 0 in RESULT variable
function wax_print_menu() {
    local -n OPTS=$2

    echo $1
    while : ; do
        for ((i=0; i<${#OPTS[@]}; i++)); do
            echo " $i) ${OPTS[i]}"
        done

        read -p " Enter your option: " OPT
        echo

        # Check for emptiness, numeric type and option range
        if [ -n "$OPT" ] && [ "$OPT" == $OPT ] &&  [ "$OPT" -lt "${#OPTS[@]}" ] ; then
           RESULT=$OPT
           return
        else
           echo -e "\nInvalid option\n"
        fi
    done
}


# Arg $1: Prompt
# Return: y/n in RESULT variable
function wax_ask_yesno() {
    local ANS
    while : ; do
        read -N 1 -p "$1 (y/n): " ANS

        if [ "$ANS" == "y" ] || [ "$ANS" == "n" ]; then
            RESULT=$ANS
            echo ""
            return
        else
            echo ""
        fi
    done
}


# Checks if the specified command exist in the system. Optionally checks for
# the required version. If some condition fails the script is aborted
#
# Arg $1: Command name to check
# Arg $2: Version to validate (optional)
function wax_check_command() {
    which $1 > /dev/null

    if [ $? == 1 ] ; then
        echo "'$1' is required, aborting"
        exit 100
    fi

    if [ ! -z $2 ] ; then
        local REQ_VER=$($1 --version)
        echo $REQ_VER | grep $2 > /dev/null

        if [ ! $? == 0 ] ; then
            echo "Wrong version for '$1' (required $2, got '$REQ_VER'), aborting"
            exit 101
        fi
    fi
}


# Reads the specified Module/Project version from version file
#
# Arg $1: Module/Project name. A special name "branch" can be used to get the working branch
# Arg $2: (Optional) default value when component is not found in the version file
# Return: the required version in $RESULT variable
function wax_get_component_version()
{
    if [ -f $WAX_VERSION_FILE ]; then
        # Remove the comment lines and then try to search the component name
        local LINE=$(grep -v '^ *#' $WAX_VERSION_FILE | grep $1)
        
        # TODO Refactor, repeated pieces of code, maybe a simple RESULT=$2 is ok
        if [ -z "$LINE" ]; then
            # Component not found
            if [ -z "$2" ]; then
                RESULT="" 
            else
                RESULT=$2
            fi
        else
            local VERSION=$(echo "$LINE" | awk '{ print $2} ') 
            
            if [ -z "$VERSION" ]; then
                if [ -z "$2" ]; then
                    RESULT="" 
                else
                    RESULT=$2
                fi
            else
                RESULT=$VERSION
            fi
        fi
    else
        # Component not found
        if [ -z "$2" ]; then
            RESULT="" 
        else
            RESULT=$2
        fi
    fi
}


# Gets the specified working branch from version file. If the version is not
# found the "master"  is returned
#
# Return: the working branch in $RESULT variable
function wax_get_working_branch()
{
    wax_get_component_version "branch" "master" 
}


# Gets the specified docker version from version file. If the version is not
# found the "latest" version is returned
#
# Arg $1: docker name
# Return: the docker version in $RESULT variable
function wax_get_docker_version()
{
    wax_get_component_version $1 "latest" 
}


# Downloads the specified component from WAX gitlab repository
#
# Arg $1: Component to donwnload in the current directory. If the component
#         already exists it won't be donwnloaded
function wax_download_component() {
    # Do not download the component (directory) if already exist
    if [ ! -d "$1" ]; then
        cd  $WAX_WORK_DIR
        wax_abort_if_fail "git clone ssh://git@monica.mcmxi.services:2259/wax/$1.git"
        
        wax_get_component_version $1
        
        if [ -z $RESULT ]; then
            # Version was not specfied, try with branch
            wax_get_working_branch
        fi    
        
        pushd . > /dev/null
        cd "$1"
        wax_abort_if_fail "git checkout $RESULT"
        popd > /dev/null
        
    else
        echo "Component '$1' already exists, download skipped"
    fi

    echo ""
}


# Gets the private key of the specified account. It will abort if it cannot find
# the specified keys file
#
# Arg $1: Account name
# Arg $2: keys file 
# Return: The private key in RESULT variable
function wax_get_private_key() {
    if [ ! -e $2 ]; then
        echo "Cannot find the keys file ('$2'), aborting"
        exit 103
    fi

    RESULT=$(grep $1 $2 | awk -F "," '{print $3}')
}


# Executes a command and abort if it fails
#
# Arg $1: The command to execute
# Arg $2: Optional custom message to display in case of failure
function wax_abort_if_fail() {
    #echo "$1"   # << uncomment to debug
    eval $1

    if [ ! $? == 0 ]; then
        if [ -z "$2" ]; then
            echo "'$1' has failed, aborting"
        else
            echo "$2"
        fi

        exit 104
    fi
}


