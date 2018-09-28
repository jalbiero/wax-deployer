#!/usr/bin/env bash

#
# WAX deployer script for (wax-testnet, wax-connect-api, wax-rng-oracle, wax-rng)
#
# All variable starting with WAX_ can be set before running this script in
# order to automate de execution:
#
#   - WAX_WORK_DIR:
#       Directory where wax-testnet, wax-connect-api, wax-rng-oracle
#       and wax-rng project are located. If this variable is empty
#       a temporary directory will be used.
#
#   - WAX_ENV:
#       Deployment environment (qa, staging, production)
#
#   - WAX_ENV_POSTFIX:
#       Custom postfix for environment name
#
#   - WAX_KEY_FILE_PATH:
#       Path where "keys.csv" file is located. If is not set it will be
#       asked
#
#   TODO Add a silent mode installation
#

SCRIPT_VERSION="1.0.7.2"


################################################################################
#
# Generic helper functions
#


# Arg $1: Menu title
# Arg $2: String array with menu options
# Return: Option index starting from 0 in RESULT variable
function print_menu() {
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
function ask_yesno() {
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
function check_command() {
    which $1 > /dev/null

    if [ $? == 1 ] ; then
        echo "'$1' is required, aborting"
        exit 1
    fi

    if [ ! -z $2 ] ; then
        local REQ_VER=$($1 --version)
        echo $REQ_VER | grep $2 > /dev/null

        if [ ! $? == 0 ] ; then
            echo "Wrong version for '$1' (required $2, got '$REQ_VER'), aborting"
            exit 2
        fi
    fi
}


# Downloads the specified component from WAX gitlab repository
#
# Arg $1: Component to donwnload in the current directory. If the component
#         already exists it won't be donwnloaded
function download_component() {
    # Do not download the component (directory) if already exist
    if [ ! -d "$1" ]; then
        cd  $WAX_WORK_DIR
        abort_if_fail "git clone ssh://git@monica.mcmxi.services:2259/wax/$1.git"
    else
        echo "Component '$1' already exists, download skipped"
    fi

    echo ""
}


# Gets the private key of the specified account. It will abort if cannot find
# the "keys.cvs" file
#
# Arg $1: Account name
# Return: The private key in RESULT variable
function get_private_key() {
    local KEYS_FILE=$WAX_WORK_DIR/wax-testnet/ansible/roles/eos-node/templates/keys.csv

    if [ ! -e $KEYS_FILE ]; then
        echo "Cannot find '$KEYS_FILE'. Testnet is not deployed in this machine, aborting"
        exit 3
    fi

    RESULT=$(grep $1 $KEYS_FILE | awk -F "," '{print $3}')
}


# Executes a command and abort if it fails
#
# Arg $1: The command to execute
# Arg $2: Optional custom message to display in case of failure
function abort_if_fail() {
    #echo "$1"
    eval $1

    if [ ! $? == 0 ]; then
        if [ -z "$2" ]; then
            echo "'$1' has failed, aborting"
        else
            echo "$2"
        fi

        exit 4
    fi
}


# Gets an AWS instance attribute
#
# Arg $1: Instance name
# Arg $2: Attribute
# Return: Attribute value in $RESULT variable
function aws_get_instance_attribute() {
    RESULT=$(abort_if_fail \
        "aws ec2 describe-instances --filters 'Name=tag:Name,Values=$1' | jq -r '.Reservations[].Instances[].$2'")

    if [ "$RESULT" == "null" ]; then
        echo "Cannot get attribute '$2' for instance '$1', aborting"
        exit 5
    fi
}


# Gets an AWS load balancer attribute
#
# Arg $1: Load balancer name
# Arg $2: Attribute
# Return: Attribute value in $RESULT variable
function aws_get_load_balancer_attribute() {
    RESULT=$(abort_if_fail \
        "aws elb describe-load-balancers --load-balancer-name $1 | jq -r '.LoadBalancerDescriptions[].$2'")

    if [ "$RESULT" == "null" ]; then
        echo "Cannot get attribute '$2' for load balancer '$1', aborting"
        exit 6
    fi
}


# Opens the specfified TCP port for the current IP where this script is running
#
# Arg $1: Security group
# Arg $2: Port to open
# TODO Generalize for other protocols
function aws_open_port() {
    local MY_PUBLIC_IP=$(dig +short myip.opendns.com @resolver1.opendns.com)
    local TMP_OUTPUT=$(mktemp)

    aws ec2 authorize-security-group-ingress --group-name $1 --protocol tcp --port $2 --cidr $MY_PUBLIC_IP/32 > $TMP_OUTPUT 2>&1

    if [ ! $? == 0 ]; then
        ALREADY_OPEN_ERROR=$(grep "InvalidPermission.Duplicate" $TMP_OUTPUT)
        if [ -z "$ALREADY_OPEN_ERROR" ]; then
            echo -e "Cannot open port $2 for SG $1, aborting\n$(cat $TMP_OUTPUT)"
        fi
    fi
}


# Closes the specified TCP port in the provided security group
#
# Arg $1: Security group
# Arg $2: Port to close
# TODO Generalize for other protocols
function aws_close_port() {
    local MY_PUBLIC_IP=$(dig +short myip.opendns.com @resolver1.opendns.com)

    # Close the specified port (it doesn't matter if the command fails)
    aws ec2 revoke-security-group-ingress --group-name $1 --protocol tcp --port $2 --cidr $MY_PUBLIC_IP/32
}



#
# End generic helper functions
#
################################################################################


# Gets the deployment environment (it will set WAX_ENV, WAX_ENV_POSTFIX and
# WAX_ENV_POSTFIX_FULL (a combination of the former two) variables with user
# input if they weren't set before)
function get_environment() {
    # If wasn't set before running this script?
    if [ -z $WAX_ENV ]; then
        # Be careful, if you add another environment, update the index in "if" part
        local ENV_OPTIONS=("qa" "staging" "production" "other (future usage)")
        print_menu "Environment to deploy:" ENV_OPTIONS

        if [ "$RESULT" -eq "3" ]; then
            read -p "Other environment (ENTER for default): " WAX_ENV
        else
            WAX_ENV=${ENV_OPTIONS[$RESULT]}
        fi
    else
        echo "Environment already set to: $WAX_ENV"
    fi

    # If wasn't set before running this script?
    if [ -z $WAX_ENV_POSTFIX ]; then
        read -e -i $USER -p "Environment postfix (your user is used for security, modify or delete it): " WAX_ENV_POSTFIX
    else
        echo "Environment postfix already set to: $WAX_ENV_POSTFIX"
    fi

    # Postfix must be lowercase (for wax-rng-oracle) (be aware that the  following
    # way to convert to lowercase is not compatible with sh, only with bash)
    WAX_ENV_POSTFIX=${WAX_ENV_POSTFIX,,}

    if [ -z "$WAX_ENV_POSTFIX" ]; then
        WAX_ENV_POSTFIX_FULL=$WAX_ENV
    else
        WAX_ENV_POSTFIX_FULL="$WAX_ENV-$WAX_ENV_POSTFIX"
    fi
}


function check_requirements() {
    echo "Checking requirements..."

    # TODO Add this "path" validation inside "check_command" function
    # Validate node installation
    which node | grep "/usr/bin" > /dev/null
    if [ $? == 0 ]; then
        echo "Your node.js installation is not recommended"
        echo "Please use https://github.com/creationix/nvm#install-script to install it"
        exit 8
    fi

    check_command npm
    check_command node "8.9"
    check_command terraform "0.10.7"
    check_command ansible
    check_command python3
    check_command cleos
    check_command make
    check_command jq
    check_command aws
    check_command awk
    check_command git
    check_command dig
    check_command tee
    check_command sed

    # TODO Add other requirements

    echo "Ok"
}


# Set general stuff
# Output WAX_WORK_DIR variable with temporary work directory
function startup() {
    clear
    pushd . > /dev/null

    # It was not set from command line?
    if [ -z $WAX_WORK_DIR ] ; then
        read -p "Specify the working directory (ENTER for a temporary one): " WAX_WORK_DIR

        if [ -z $WAX_WORK_DIR ] ; then
            WAX_WORK_DIR=$(mktemp -d --suffix=_wax_deployment)
        fi
    fi

    cd $WAX_WORK_DIR
    echo -e "\nWorking directory set to: $WAX_WORK_DIR\n"
}


function shutdown() {
    ask_yesno "Do you want to remove the working directory ($WAX_WORK_DIR)?"

    if [ "$RESULT" == "y" ];  then
        rm -rf $WAX_WORK_DIR
    fi

    popd > /dev/null
    echo -e "\nDone"
}


function deploy_testnet() {
    echo -e "\nDeploying Testnet..."
    download_component "wax-testnet"
    cd $WAX_WORK_DIR/wax-testnet

    if [ -z $WAX_KEY_FILE_PATH ]; then
        read -p "CSV key file path (an empty value will create a new key file): " WAX_KEY_FILE_PATH

        if [ ! -z $WAX_KEY_FILE_PATH ]; then
            cp -i $WAX_KEY_FILE_PATH/keys.csv $(pwd)/ansible/roles/eos-node/templates/
        fi
    else
        echo "Keys file path already set to: $WAX_KEY_FILE_PATH"
    fi

    # "production" is a special case
    if [ "$WAX_ENV" == "production" ]; then
        local PUB_KEY
        local PRI_KEY

        read -p "Root public key for production (eosio account): " PUB_KEY
        read -p "Root private key for production (eosio account): " PRI_KEY

        PRODUCTION_OPTIONS="ROOT_PUB_KEY=$PUB_KEY ROOT_PRI_KEY=$PRI_KEY"
    fi

    # TODO Remove this when upgrade to terraform version 0.11.x. It's a must to
    #      ask for continuation before applying the changes!
    make terraform_plan ENVIRONMENT=$WAX_ENV ENV_POSTFIX=$WAX_ENV_POSTFIX $PRODUCTION_OPTIONS
    ask_yesno "Read carefully the above terraform plan, are you sure to continue?"

    if [ "$RESULT" == "y" ]; then
        abort_if_fail "make all ENVIRONMENT=$WAX_ENV ENV_POSTFIX=$WAX_ENV_POSTFIX $PRODUCTION_OPTIONS"
    fi
}


function deploy_block_explorer() {
    echo -e "\nDeploying Block Explorer..."
    download_component "wax-tracker"
    cd $WAX_WORK_DIR/wax-tracker

    # "production" is a special case
    if [ "$WAX_ENV" == "production" ]; then

        local PRODUCTION_CHAIN_ID="cf057bbfb72640471fd910bcb67639c22df9f92470936cddc1ade0e2f2e7dc4f"
        local CHAIN_ID

        read -e -i $PRODUCTION_CHAIN_ID -p "Production EOS Chain Id (ENTER to accept the suggested): " CHAIN_ID

        PRODUCTION_OPTIONS="chain_id=$CHAIN_ID"
    fi

    local NODE_NAME="eos-node-0-$WAX_ENV_POSTFIX_FULL"
    aws_get_instance_attribute $NODE_NAME  "PrivateIpAddress"

    if [ -z $RESULT ]; then
        echo "Cannot find '$NODE_NAME' instance on AWS."
        echo "You must deploy the testnet before trying to deploy the block explorer"
        exit 7
    fi

    abort_if_fail "npm install"
    abort_if_fail "make deploy environment=$WAX_ENV env_postfix=$WAX_ENV_POSTFIX eos_peer_ip=$RESULT"
}


function deploy_connect_api() {
    echo -e "\nDeploying Connect API..."
    download_component "wax-connect-api"
    cd $WAX_WORK_DIR/wax-connect-api

    local METRICS_HOST
    read -e -i "localhost" -p "Metrics host (ENTER to accept the suggested): " METRICS_HOST

    local METRICS_PORT
    read -e -i "8125" -p "Metrics port (ENTER to accept the suggested): " METRICS_PORT

    local INFLUX_DB
    read -e -i "telegraf" -p "Influx database (ENTER to accept the suggested): " INFLUX_DB

    local INFLUX_HOST
    read -e -i "localhost" -p "Influx database (ENTER to accept the suggested): " INFLUX_HOST

    local PRODUCTION_OPTIONS

    # "production" is a special case
    if [ "$WAX_ENV" == "production" ]; then

        local PRODUCTION_CHAIN_ID="2bfabaf12493e3196867e5afe2cf9c20372a24329f13495eee8c9d957638ba40"
        local CHAIN_ID

        read -e -i $PRODUCTION_CHAIN_ID -p "Production EOS Chain Id (ENTER to accept the suggested): " CHAIN_ID

        PRODUCTION_OPTIONS="chain_id=$CHAIN_ID"
    fi

    # TODO Get IPs from all nodes, wax-connect-api now support a list of IP in "eos_peer_ip"
    local NODE_NAME="eos-node-0-$WAX_ENV_POSTFIX_FULL"
    aws_get_instance_attribute $NODE_NAME  "PrivateIpAddress"

    if [ -z $RESULT ]; then
        echo "Cannot find '$NODE_NAME' instance on AWS."
        echo "You must deploy the testnet before trying to deploy the wax-connect-api"
        exit 9
    else
        local EOS_PEER_IP=$RESULT
    fi

    get_private_key "wax.connect"
    abort_if_fail "make deploy env_postfix=$WAX_ENV_POSTFIX key_provider=$RESULT eos_peer_ip=$EOS_PEER_IP metrics_host=$METRICS_HOST metrics_port=$METRICS_PORT influxdb_database=$INFLUX_DB influxdb_host=$INFLUX_HOST $PRODUCTION_OPTIONS"
}


function deploy_oracle() {
    echo -e "\nDeploying Oracle..."
    download_component "wax-rng-oracle"
    cd $WAX_WORK_DIR/wax-rng-oracle

    local METRICS_HOST
    read -e -i "localhost" -p "Metrics host (ENTER to accept the suggested): " METRICS_HOST

    local METRICS_PORT
    read -e -i "8125" -p "Metrics port (ENTER to accept the suggested): " METRICS_PORT

    local CONNECT_API_LB
    aws_get_load_balancer_attribute "wax-connect-api-lb-$WAX_ENV_POSTFIX_FULL" "DNSName"
    read -e -i "$RESULT" -p "Connect API Load Balancer address (ENTER accept the suggested): " CONNECT_API_LB

    local INFLUX_DB
    read -e -i "telegraf" -p "Influx database (ENTER to accept the suggested): " INFLUX_DB

    local INFLUX_HOST
    read -e -i "localhost" -p "Influx database (ENTER to accept the suggested): " INFLUX_HOST

    abort_if_fail "make deploy env_postfix=$WAX_ENV_POSTFIX wax_api_url=http://$CONNECT_API_LB metrics_host=$METRICS_HOST metrics_port=$METRICS_PORT influxdb_database=$INFLUX_DB influxdb_host=$INFLUX_HOST"
}


function deploy_rng_contract() {
    echo -e "\nDeploying RNG contract..."
    download_component "wax-rng"
    cd $WAX_WORK_DIR/wax-rng

    cleos wallet stop > /dev/null

    # Backup current wallet
    local BACKUP_WALLET
    if [ -d ~/eosio-wallet ] ; then
        BACKUP_WALLET=~/eosio-wallet_$RANDOM
        mv ~/eosio-wallet $BACKUP_WALLET
    fi

    # Create a temporary wallet
    abort_if_fail "cleos wallet create > /dev/null"

    get_private_key "wax.rng"
    abort_if_fail "cleos wallet import $RESULT > /dev/null"

    local CONNECT_PUBLIC_IP
    aws_get_instance_attribute "wax-connect-api-node-0-$WAX_ENV_POSTFIX_FULL" "PublicIpAddress"
    read -e -i "$RESULT" -p "WAX Connect public IP (ENTER to accept the suggested): " CONNECT_PUBLIC_IP

    # Open temporarily the port 8888 and 80 for my IP in order to deploy the contract
    aws_open_port "wax-connect-api-sg-$WAX_ENV_POSTFIX_FULL" "8888"

    export NODEOS_URL=http://$CONNECT_PUBLIC_IP:8888
    abort_if_fail "make deploy"

    ################################
    # Deploy cases

    # Open temporarily the port 80 for my IP in order to deploy the cases
    aws_open_port "wax-connect-api-sg-$WAX_ENV_POSTFIX_FULL" "80"

    cd cases
    abort_if_fail "npm install"

    for CASE_FILE in ./*.csv; do
        abort_if_fail "npm run deploy -- '$CASE_FILE' http://$CONNECT_PUBLIC_IP 0"
    done

    # Cleanup

    aws_close_port "wax-connect-api-sg-$WAX_ENV_POSTFIX_FULL" "80"
    aws_close_port "wax-connect-api-sg-$WAX_ENV_POSTFIX_FULL" "8888"

    # Restore user wallet
    if [ -d $BACKUP_WALLET ] ; then
        cleos wallet stop
        rm -R ~/eosio-wallet
        mv $BACKUP_WALLET ~/eosio-wallet
    fi
}


################################################################################
function main() {
    startup

    local OPTIONS=("All" "Testnet" "Block Explorer" "Connect API" "Oracle" "RNG contract" "<Quit>")

    while : ; do
        print_menu "What do you want to deploy?" OPTIONS

        case "$RESULT" in
            0)
                get_environment
                deploy_testnet
                deploy_block_explorer
                deploy_connect_api
                deploy_oracle
                deploy_rng_contract
                ;;
            1)
                get_environment
                deploy_testnet
                ;;
            2)
                get_environment
                deploy_block_explorer
                ;;
            3)
                get_environment
                deploy_connect_api
                ;;
            4)
                get_environment
                deploy_oracle
                ;;
            5)
                get_environment
                deploy_rng_contract
                ;;

            *)
                echo "Exit asked"
                break
                ;;

        esac
    done

    shutdown
}


################################################################################
# Entry point

check_requirements

if [ "$1" == "--internal-start" ]; then
    # Starts the deployer
    echo -e "\nStarting $0 at '$(date --utc)' version $SCRIPT_VERSION\n"
    main
else
    # Relaunch this instance, but logging everything to an installation file
    $0 --internal-start 2>&1 | tee -a ./deploy-wax-installation.log
fi

