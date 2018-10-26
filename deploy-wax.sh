#!/usr/bin/env bash

#
# WAX deployer script for (wax-testnet, wax-connect-api, wax-rng-oracle, wax-rng)
#
# The following variable can be set before running this script in
# order to automate de execution:
#
#   - WAX_WORK_DIR:
#       Directory where wax-testnet, wax-connect-api, wax-rng-oracle
#       and wax-rng project are located. If this variable is empty
#       a temporary directory will be used.
#       Default: temporary one in /tmp
#
#   - WAX_ENV:
#       Deployment environment (qa, staging, production)
#
#   - WAX_ENV_POSTFIX:
#       Custom postfix for environment name.
#       Default: $USER
#
#   - WAX_KEYS_FILE_PATH:
#       CVS Keys file path and name
#
#   - WAX_VERSION_FILE:
#       Name and path where version are specified. 
#       Default: ./version-list.txt       
#
#
#   TODO Add a silent mode installation
#   TODO EOS Docker image version is still not used with eos 1.0.x, but the
#        code is prepared for that.
#

SCRIPT_VERSION="2.0.0"

. ./modules/wax_helpers.sh
. ./modules/aws_helpers.sh


# Gets the deployment environment (it will set WAX_ENV, WAX_ENV_POSTFIX and
# WAX_ENV_POSTFIX_FULL (a combination of the former two) variables with user
# input if they weren't set before)
function get_environment() {
    # If wasn't set before running this script?
    if [ -z $WAX_ENV ]; then
        # Be careful, if you add another environment, update the index in "if" part
        local ENV_OPTIONS=("qa" "staging" "production" "other (future usage)")
        wax_print_menu "Environment to deploy:" ENV_OPTIONS

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
        if [ -z $USER ]; then # When running inside a docker $USER is not defined :-O
            USER=$RANDOM
        fi
    
        read -e -i $USER -p "Environment postfix (modify or delete it): " WAX_ENV_POSTFIX
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


# Gets the keys file from user, storing the value on WAX_KEYS_FILE_PATH
#
# Arg $1: (optional) Default keys file
function get_keys_file_path()
{   
    if [ -z $WAX_KEYS_FILE_PATH ]; then
        read -e -i "$1" -p "Path and name of the CSV keys file (for wax-testnet only: an empty value will create a new file): " WAX_KEYS_FILE_PATH
    else
        echo "CSV keys file already set to: $WAX_KEYS_FILE_PATH"
    fi
}


function check_requirements() {
    echo "Checking requirements..."

    # TODO Add this "path" validation inside "wax_check_command" function
    # Validate node installation
    which node | grep "/usr/bin" > /dev/null
    if [ $? == 0 ]; then
        echo "WARNING:"
        echo "Your node.js installation ($(which node)) is not recommended"
        echo "Please use https://github.com/creationix/nvm#install-script to install it"
        #exit 10   # < just for now a simple warning
    fi

    wax_check_command npm
    wax_check_command node "8.9"
    wax_check_command terraform "v0.11"
    wax_check_command ansible
    wax_check_command python3
    wax_check_command cleos
    wax_check_command make
    wax_check_command jq
    wax_check_command aws
    wax_check_command awk
    wax_check_command git
    wax_check_command dig
    wax_check_command tee
    wax_check_command sed
    wax_check_command printf

    # TODO Add other requirements

    echo "Ok"
}


# Sets general stuff
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
    wax_ask_yesno "Do you want to remove the working directory ($WAX_WORK_DIR)?"

    if [ "$RESULT" == "y" ];  then
        rm -rf $WAX_WORK_DIR
    fi

    popd > /dev/null
    echo -e "\nDone"
}


function deploy_testnet() {
    echo -e "\nDeploying Testnet..."
    wax_download_component "wax-testnet"
    cd $WAX_WORK_DIR/wax-testnet

    if [ -z $WAX_KEYS_FILE_PATH ]; then
        # The user didn't provide a keys file, for the rest of the deployment process 
        # the keys file will the one created by this deployment (testnet)
        WAX_KEYS_FILE_PATH=$(pwd)/ansible/roles/eos-node/templates/keys.csv
    else
        # Use the provided keys file
        cp -i $WAX_KEYS_FILE_PATH $(pwd)/ansible/roles/eos-node/templates/keys.csv
    fi

    # "production" is a special case
    if [ "$WAX_ENV" == "production" ]; then
        local PUB_KEY
        local PRI_KEY

        read -p "Root public key for production (eosio account): " PUB_KEY
        read -p "Root private key for production (eosio account): " PRI_KEY

        PRODUCTION_OPTIONS="ROOT_PUB_KEY=$PUB_KEY ROOT_PRI_KEY=$PRI_KEY"
    fi
    
    wax_get_docker_version "eos-docker-image"
    local DOCKER_VERSION=$RESULT

    wax_abort_if_fail "make all ENVIRONMENT=$WAX_ENV EOS_DOCKER_IMAGE_TAG=$DOCKER_VERSION ENV_POSTFIX=$WAX_ENV_POSTFIX $PRODUCTION_OPTIONS"
}


function deploy_tracker() {
    echo -e "\nDeploying Tracker..."
    wax_download_component "wax-tracker"
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

    echo "Result: '$RESULT'"

    if [ -z "$RESULT" ]; then
        echo "Cannot find '$NODE_NAME' instance on AWS."
        echo "You must deploy the testnet before trying to deploy the block explorer"
        exit 11
    fi

    wax_abort_if_fail "npm install"
    wax_abort_if_fail "make deploy environment=$WAX_ENV env_postfix=$WAX_ENV_POSTFIX eos_peer_ip=$RESULT"
}


function deploy_connect_api() {
    echo -e "\nDeploying Connect API..."
    wax_download_component "wax-connect-api"
    cd $WAX_WORK_DIR/wax-connect-api

    local METRICS_HOST
    read -e -i "localhost" -p "Metrics host (ENTER to accept the suggested): " METRICS_HOST

    local METRICS_PORT
    read -e -i "8125" -p "Metrics port (ENTER to accept the suggested): " METRICS_PORT

    local INFLUX_DB
    read -e -i "telegraf" -p "Influx database (ENTER to accept the suggested): " INFLUX_DB

    local INFLUX_HOST
    read -e -i "localhost" -p "Influx database host (ENTER to accept the suggested): " INFLUX_HOST

    local PRODUCTION_OPTIONS

    # "production" is a special case
    if [ "$WAX_ENV" == "production" ]; then

        local PRODUCTION_CHAIN_ID="2bfabaf12493e3196867e5afe2cf9c20372a24329f13495eee8c9d957638ba40"
        local CHAIN_ID

        read -e -i $PRODUCTION_CHAIN_ID -p "Production EOS Chain Id (ENTER to accept the suggested): " CHAIN_ID

        PRODUCTION_OPTIONS="chain_id=$CHAIN_ID"
    fi
    
    wax_get_docker_version "eos-docker-image"
    local DOCKER_VERSION=$RESULT

    # TODO Get IPs from all nodes, wax-connect-api now support a list of IP in "eos_peer_ip"
    local NODE_NAME="eos-node-0-$WAX_ENV_POSTFIX_FULL"
    aws_get_instance_attribute $NODE_NAME  "PrivateIpAddress"

    if [ -z $RESULT ]; then
        echo "Cannot find '$NODE_NAME' instance on AWS."
        echo "You must deploy the testnet before trying to deploy the wax-connect-api"
        exit 12
    else
        local EOS_PEER_IP=$RESULT
    fi

    wax_get_private_key "wax.connect" $WAX_KEYS_FILE_PATH
    wax_abort_if_fail \
        "make deploy env_postfix=$WAX_ENV_POSTFIX key_provider=$RESULT eos_peer_ip=$EOS_PEER_IP metrics_host=$METRICS_HOST metrics_port=$METRICS_PORT influxdb_database=$INFLUX_DB influxdb_host=$INFLUX_HOST eos_docker_image_tag=$DOCKER_VERSION $PRODUCTION_OPTIONS"
}


function deploy_oracle() {
    echo -e "\nDeploying Oracle..."
    wax_download_component "wax-rng-oracle"
    cd $WAX_WORK_DIR/wax-rng-oracle

    local METRICS_HOST
    read -e -i "localhost" -p "Metrics host (ENTER to accept the suggested): " METRICS_HOST

    local METRICS_PORT
    read -e -i "8125" -p "Metrics port (ENTER to accept the suggested): " METRICS_PORT

    local INFLUX_DB
    read -e -i "telegraf" -p "Influx database (ENTER to accept the suggested): " INFLUX_DB

    local INFLUX_HOST
    read -e -i "localhost" -p "Influx hostname (ENTER to accept the suggested): " INFLUX_HOST

    aws_get_load_balancer_attribute "wax-connect-api-lb-$WAX_ENV_POSTFIX_FULL" "DNSName"
    local CONNECT_API_LB=$RESULT

    wax_abort_if_fail \
        "make deploy env_postfix=$WAX_ENV_POSTFIX wax_api_url=http://$CONNECT_API_LB metrics_host=$METRICS_HOST metrics_port=$METRICS_PORT influxdb_database=$INFLUX_DB influxdb_host=$INFLUX_HOST"
}


function deploy_rng_contract() {
    echo -e "\nDeploying RNG contract..."
    wax_download_component "wax-rng"
    cd $WAX_WORK_DIR/wax-rng

    cleos wallet stop > /dev/null

    # Backup current wallet
    local BACKUP_WALLET
    if [ -d ~/eosio-wallet ] ; then
        BACKUP_WALLET=~/eosio-wallet_$RANDOM
        mv ~/eosio-wallet $BACKUP_WALLET
    fi

    # Create a temporary wallet
    wax_abort_if_fail "cleos wallet create > /dev/null"

    wax_get_private_key "wax.rng" $WAX_KEYS_FILE_PATH
    wax_abort_if_fail "cleos wallet import $RESULT > /dev/null"

    # Open temporarily the port 8888 for my IP in order to deploy the contract
    aws_open_port "wax-connect-api-sg-$WAX_ENV_POSTFIX_FULL" "8888"

    aws_get_instance_attribute "wax-connect-api-node-0-$WAX_ENV_POSTFIX_FULL" "PublicIpAddress"
    export NODEOS_URL=http://$RESULT:8888

    # TODO Use (and test) the new task 'dockerized-deploy'
    # TODO Add docker to the script requirements when dockerized-deploy will be used
    wax_abort_if_fail "make deploy"

    # Cleanup
    aws_close_port "wax-connect-api-sg-$WAX_ENV_POSTFIX_FULL" "8888"

    # Restore user wallet
    if [ -d $BACKUP_WALLET ] ; then
        cleos wallet stop
        rm -R ~/eosio-wallet
        mv $BACKUP_WALLET ~/eosio-wallet
    fi

# FUTURE Implementation for dockerized deploy
#     wax_get_private_key "wax.rng" $WAX_KEYS_FILE_PATH
#     local RNG_PRIV_KEY=$RESULT
#
#     # Open temporarily the port 8888 for my IP in order to deploy the contract
#     aws_open_port "wax-connect-api-sg-$WAX_ENV_POSTFIX_FULL" "8888"
#
#     aws_get_instance_attribute "wax-connect-api-node-0-$WAX_ENV_POSTFIX_FULL" "PublicIpAddress"
#     export NODEOS_URL=http://$RESULT:8888
#
#     wax_abort_if_fail "make dockerized-deploy RNG_PRIV_KEY=$RNG_PRIV_KEY NODEOS_URL=$NODEOS_URL"

}


function deploy_explorer()
{
    echo -e "\nDeploying Explorer..."
    wax_download_component "wax-explorer"
    cd $WAX_WORK_DIR/wax-explorer

    local TRADE_API_URL
    read  -p "Trade API URL: " TRADE_API_URL

    local NODE_NAME="wax-connect-api-node-0-$WAX_ENV_POSTFIX_FULL"
    aws_get_instance_attribute $NODE_NAME "PrivateIpAddress"

    if [ -z $RESULT ]; then
        echo "Cannot find '$NODE_NAME' instance on AWS."
        echo "You must deploy connect-api before trying to deploy the explorer"
        exit 10
    else
        local CONNECT_IP=$RESULT
    fi

    wax_abort_if_fail "make deploy env_postfix=$WAX_ENV_POSTFIX trade_api_url=$TRADE_API_URL wax_connect_api_url=http://$CONNECT_IP"
}


function deploy_cases()
{
    echo -e "\nDeploying Cases..."
    wax_download_component "case-tools"
    cd $WAX_WORK_DIR/case-tools/cases

    wax_abort_if_fail "npm install"

    # Open temporarily the port 80 for my IP in order to deploy the cases
    aws_open_port "wax-connect-api-sg-$WAX_ENV_POSTFIX_FULL" "80"

    aws_get_instance_attribute "wax-connect-api-node-0-$WAX_ENV_POSTFIX_FULL" "PublicIpAddress"
    local CONNECT_PUBLIC_IP=$RESULT

    # TODO Check why the full path is necessary (it wasn't at rng project)
    for CASE_FILE in $WAX_WORK_DIR/case-tools/cases/definitions/*.csv; do
        wax_abort_if_fail "npm run deploy -- -c '$CASE_FILE' -w http://$CONNECT_PUBLIC_IP -l 0"
    done

    aws_close_port "wax-connect-api-sg-$WAX_ENV_POSTFIX_FULL" "80"
}


function show_versions()
{
    if [ -e $WAX_VERSION_FILE ]; then
        echo "---------------"
        cat $WAX_VERSION_FILE
        echo "---------------"
    
    else
        echo "Cannot find version file"
    fi
    
    echo "" 
    read -p "Press any key to return to main menu" 
    echo ""
}


################################################################################
function main() {
    startup

    local DEFAULT_KEYS_FILE=$WAX_WORK_DIR/wax-testnet/ansible/roles/eos-node/templates/keys.csv
    
    local OPTIONS=(       \
        "All"             \
        "Testnet"         \
        "Tracker"         \
        "Connect API"     \
        "Explorer"        \
        "Oracle"          \
        "RNG contract"    \
        "Cases"           \
        "<Version info>"  \
        "<Quit>")

    while : ; do
        wax_print_menu "What do you want to deploy?" OPTIONS

        case "$RESULT" in
            0)
                get_environment
                get_keys_file_path  # No default keys file here
                deploy_testnet
                deploy_tracker
                deploy_connect_api
                deploy_explorer
                deploy_oracle
                deploy_rng_contract
                deploy_cases
                ;;
            1)
                get_environment
                get_keys_file_path $DEFAULT_KEYS_FILE
                deploy_testnet
                ;;
            2)
                get_environment
                deploy_tracker
                ;;
            3)
                get_environment
                get_keys_file_path $DEFAULT_KEYS_FILE
                deploy_connect_api
                ;;
            4)
                get_environment
                deploy_explorer
                ;;
            5)
                get_environment
                deploy_oracle
                ;;
            6)
                get_environment
                get_keys_file_path $DEFAULT_KEYS_FILE
                deploy_rng_contract
                ;;
            7)
                get_environment
                deploy_cases
                ;;
            8)
                show_versions
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
    # This script must be executed from the same directory where it resides
    # TODO Add checking for that

    # Relaunch this instance, but logging everything to an installation file
    $0 --internal-start 2>&1 | tee -a ./deploy-wax-installation.log
fi

