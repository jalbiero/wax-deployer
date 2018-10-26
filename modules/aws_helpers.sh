#!/usr/bin/env bash

#
# 
# AWS helper functions
#
#


# Gets an AWS instance attribute
#
# Arg $1: Instance name
# Arg $2: Attribute
# Return: Attribute value in $RESULT variable
function aws_get_instance_attribute() {
    RESULT=$(wax_abort_if_fail \
        "aws ec2 describe-instances --filters 'Name=tag:Name,Values=$1' | jq -r '.Reservations[].Instances[].$2'")

    if [ "$RESULT" == "null" ]; then
        echo "Cannot get attribute '$2' for instance '$1', aborting"
        exit 200
    else
        # TODO Remove this fix when figure out why sometimes RESULT contains an extra line with the 'null' word
        RESULT=$(printf $RESULT) # gets only the 1st line
    fi
}


# Gets an AWS load balancer attribute
#
# Arg $1: Load balancer name
# Arg $2: Attribute
# Return: Attribute value in $RESULT variable
function aws_get_load_balancer_attribute() {
    RESULT=$(wax_abort_if_fail \
        "aws elb describe-load-balancers --load-balancer-name $1 | jq -r '.LoadBalancerDescriptions[].$2'")

    if [ "$RESULT" == "null" ]; then
        echo "Cannot get attribute '$2' for load balancer '$1', aborting"
        exit 201
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
            exit 203
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


