# WAX-Deployer

## Description 
This is an interactive automation script to deploy not only wax-testnet, but
wax-connect-api, wax-rng-oracle and wax-rng modules.

    - To start the deployment process just execute the script from a terminal.

    - A log filed called "deploy-wax-installation.log" will be created in the
      directory from which the script is executed. It will contain all the
      screen output from the installation process.

Note:

In order to track the changes, if you modify the script, please, before
every commit:

    - Update the value of variable SCRIPT_VERSION.
    - Update the change-log.txt file

## How to run 
 
### Prerequisites 

- terraform version "0.10.7"
- ansible
- npm
- python3
- cleos
- make
- jq
- aws
- awk
- git
- dig
- tee

### Command 

```bash
./deploy-wax.sh
```
