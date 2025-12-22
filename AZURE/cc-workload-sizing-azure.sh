#!/bin/bash

# Check for jq dependency
if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed. Please install jq to run this script."
    echo "(e.g., 'sudo apt-get install jq' or 'sudo yum install jq' or 'brew install jq')"
    exit 1
fi

# Function to handle errors
function check_error {
    local exit_code=$1
    local message=$2
    if [ $exit_code -ne 0 ]; then
        echo "Error: $message (Exit Code: $exit_code)"
        exit $exit_code
    fi
}

function printHelp {
    echo ""
    echo "NOTES:"
    echo "* Requires Azure CLI to execute"
    echo "* Requires JQ utility to be installed"

    echo "Available flags:"
    echo " -h          Display the help info"
    echo " -n <region> Single Azure region (location) to scan"
    echo " -s          Include stopped compute instances in addition to running"
    exit 1
}

echo "$(tput bold)$(tput setaf 2)";
echo "   ___           _                ___ _                 _ ";
echo "  / __\___  _ __| |_ _____  __   / __\ | ___  _   _  __| |";
echo " / /  / _ \| '__| __/ _ \ \/ /  / /  | |/ _ \| | | |/ _\` |";
echo "/ /__| (_) | |  | ||  __/>  <  / /___| | (_) | |_| | (_| |";
echo "\____/\___/|_|   \__\___/_/\_\ \____/|_|\___/ \__,_|\__,_|";
echo "                                                          ";
echo "                                                          ";
echo "$(tput sgr0)";

# Ensure Azure CLI is logged in
az account show > /dev/null 2>&1
check_error $? "Azure CLI not logged in or credentials invalid. Please run 'az login'."

# Initialize options
LOCATION=""
#STATE="running" # Azure VMs are either 'running' or 'deallocated' for stopped
STATE="running,deallocated" #oveerriding option flag to default to count running & stopped

# Get options
while getopts ":hn:s" opt; do
  case ${opt} in
    h) printHelp ;;
    n) LOCATION="$OPTARG" ;;
    s) STATE="running,deallocated" ;; # In Azure, 'stopped' instances are 'deallocated'
    *) echo "Invalid option: -${OPTARG}" && printHelp exit ;;
 esac
done
shift $((OPTIND-1))

# Get a list of all subscriptions
subscriptions=$(az account list --query '[].{id:id, name:name}' -o json)
if [ -z "$subscriptions" ] || [ "$subscriptions" == "[]" ]; then
    echo "No Azure subscriptions found or accessible. Please check your Azure login and permissions."
    exit 0
fi

sum_total_azure_workloads=0

# Loop through each subscription using process substitution to avoid subshell
# This ensures sum_total_azure_workloads is updated in the current shell
while read -r subscription; do
    sub_id=$(echo "$subscription" | jq -r '.id')
    sub_name=$(echo "$subscription" | jq -r '.name')
     echo "Processing Subscription: $sub_name (ID: $sub_id)"

    # Set the current subscription
    # We redirect stderr to /dev/null to suppress "Setting active subscription..." messages
    az account set --subscription "$sub_id" &> /dev/null

    if [ $? -ne 0 ]; then
        echo "  WARNING: Could not set subscription '$sub_name'. Skipping this subscription."
        continue
    fi

    echo "  Fetching enabled Azure locations for the account..."
    echo ""
    activeLocations=$(az account list-locations --query "[].name" --output tsv)
    check_error $? "  Failed to list enabled Azure locations. Ensure proper permissions."

    if [ -z "$activeLocations" ]; then
        echo "  Error: Could not retrieve list of enabled locations."
        exit 1
    fi
    #echo "Enabled locations found: $activeLocations"

    # Validate region flag (Azure uses 'location')
    if [[ "${LOCATION}" ]]; then
        if echo "$activeLocations" | grep -qi "\b$LOCATION\b"; then
            echo "  Requested location is valid";
        else
            echo "  Invalid location requested: $LOCATION";
            exit 1
        fi
    fi

    echo "$(tput bold)$(tput setaf 6)Counting Workloads$(tput sgr0)"

    # Initialize counters (these are re-initialized for each subscription within the loop)
    total_vm_instances=0
    total_aks_nodes=0
    total_storage_accounts=0
    total_azure_files=0
    total_azure_sql_servers=0
    total_cosmosdb_accounts=0
    total_sql_managed_instances=0
    paas_workloads=0
    total_paas_workloads_sub=0 # Use _sub suffix to differentiate from global sum
    caas_workloads=0
    total_caas_workloads_sub=0
    container_image_workloads=0
    total_container_image_workloads_sub=0
    serverless_workloads=0
    total_serverless_workloads_sub=0
    aks_workloads=0
    total_aks_workloads_sub=0
    storage_workloads=0
    total_storage_workloads_sub=0

    # Function to count resources in Azure
    # This function should probably pass values back via return codes or echoed values
    # if it were meant to be used outside of the main loop.
    # For now, it updates the local variables for the current subscription.
    count_resources() {
        local subscription_id=$1

        # Count Azure Virtual Machines
        echo "  Counting VM instances..."
        local vm_count=0
        local vm_list_query="[?powerState=='VM running' || powerState=='VM deallocated'].id"
        if [[ "$STATE" == "running,deallocated" ]]; then
            vm_list_query="[].id" # Get all VMs regardless of state
        fi

        if [[ "${LOCATION}" ]]; then
            vm_ids=$(az vm list --query "$vm_list_query" --output tsv --location "$LOCATION")
            check_error $? "Failed to describe VMs in location $LOCATION."
        else
            vm_ids=$(az resource list --resource-type "Microsoft.Compute/virtualMachines" --output tsv)
            check_error $? "Failed to describe VMs across all locations."
        fi
        vm_count=$(echo "$vm_ids" | wc -l)
        echo "  $(tput bold)$(tput setaf 6)VM Workloads: $vm_count$(tput sgr0)"
        echo ""
        total_vm_instances=$((total_vm_instances + vm_count))

        # Count Azure Kubernetes Service (AKS) nodes
        echo "  Counting AKS nodes..."
        local aks_node_count=0
        local aks_clusters=""
        if [[ "${LOCATION}" ]]; then
            aks_clusters=$(az aks list --query "[?location=='$LOCATION'].name" --output tsv)
            check_error $? "    Failed to list AKS clusters in location $LOCATION."
        else
            aks_clusters=$(az aks list --query "[].name" --output tsv)
            check_error $? "    Failed to list AKS clusters across all locations."
        fi

        for cluster_name in $aks_clusters; do
            echo "  Checking AKS cluster: $cluster_name"
            # Get the resource group of the cluster to query node pools
            # This part needs a rework to correctly identify the resource group for the AKS cluster.
            # A more robust way is to query az aks show for the 'nodeResourceGroup'
            local cluster_rg=$(az aks show --name "$cluster_name" --query "resourceGroup" -o tsv 2>/dev/null)
            if [ -z "$cluster_rg" ]; then
                echo "    Warning: Could not determine resource group for AKS cluster '$cluster_name'. Skipping node pool count."
                continue
            fi

            local node_pools=$(az aks nodepool list --cluster-name "$cluster_name" --resource-group "$cluster_rg" --query "[].name" --output tsv 2>/dev/null)
            if [ -z "$node_pools" ]; then
                echo "    No node pools found for cluster '$cluster_name' in resource group '$cluster_rg'."
                continue
            fi

            for pool_name in $node_pools; do
                local desired_node_count=$(az aks nodepool show --cluster-name "$cluster_name" --resource-group "$cluster_rg" --name "$pool_name" --query "count" --output tsv 2>/dev/null)
                if [ -n "$desired_node_count" ]; then
                    aks_node_count=$((aks_node_count + desired_node_count))
                    echo "    Node pool '$pool_name' in cluster '$cluster_name': $desired_node_count nodes"
                fi
            done
        done
        total_aks_nodes=$((total_aks_nodes + aks_node_count))
        aks_workloads=$total_aks_nodes
        total_aks_workloads_sub=$((total_aks_workloads_sub + aks_workloads))
        echo "  $(tput bold)$(tput setaf 6)VM (Container) Workloads: $aks_workloads$(tput sgr0)"
        echo ""

        # Count Azure Functions (Serverless)
        echo "  Counting Azure Functions (Serverless)..."
        local functions_count=0
        if [[ "${LOCATION}" ]]; then
            functions_count=$(az functionapp list --query "[?location=='$LOCATION'].id" --output tsv 2>/dev/null | wc -l)
            check_error $? "    Failed to list Azure Functions in location $LOCATION."
        else
            functions_count=$(az functionapp list --query "[].id" --output tsv 2>/dev/null | wc -l)
            check_error $? "    Failed to list Azure Functions across all locations."
        fi
        serverless_workloads=$(( (functions_count+25-1)/25 )) # Assuming a ratio of 25 functions per workload unit
        if (( functions_count == 0 )); then
            serverless_workloads=0
        fi
        total_serverless_workloads_sub=$((total_serverless_workloads_sub + serverless_workloads))
        echo "  $(tput bold)$(tput setaf 6)Serverless Workloads: $serverless_workloads$(tput sgr0)"
        echo ""

        # Count Azure Container Instances and Azure Container Apps (CaaS)
        echo "  Counting Azure Container Instances and Container Apps (CaaS)..."
        local aci_count=0
        local aca_count=0
        if [[ "${LOCATION}" ]]; then
            aci_count=$(az container list --query "[?location=='$LOCATION'].id" --output tsv 2>/dev/null | wc -l)
            check_error $? "    Failed to list Azure Container Instances in location $LOCATION."
            aca_count=$(az containerapp list --query "[?location=='$LOCATION'].id" --output tsv 2>/dev/null | wc -l)
            check_error $? "    Failed to list Azure Container Apps in location $LOCATION."
        else
            aci_count=$(az container list --query "[].id" --output tsv 2>/dev/null | wc -l)
            check_error $? "    Failed to list Azure Container Instances across all locations."
            aca_count=$(az containerapp list --query "[].id" --output tsv 2>/dev/null | wc -l)
            check_error $? "    Failed to list Azure Container Apps across all locations."
        fi
        local total_containers=$((aci_count + aca_count))
        caas_workloads=$(( (total_containers+10-1)/10 )) # Assuming a ratio of 10 containers per workload unit
        if (( total_containers == 0 )); then
            caas_workloads=0
        fi
        total_caas_workloads_sub=$((total_caas_workloads_sub + caas_workloads))
        echo "  $(tput bold)$(tput setaf 6)CaaS Workloads: $caas_workloads$(tput sgr0)"
        echo ""

        # Count Container Images in Azure Container Registry (ACR)
        echo "  Counting container images in Azure Container Registry (ACR)..."
        local total_images_acr=0
        local acr_registries=""
        if [[ "${LOCATION}" ]]; then
            acr_registries=$(az acr list --query "[?location=='$LOCATION'].name" --output tsv 2>/dev/null)
            check_error $? "    Failed to list ACR registries in location $LOCATION."
        else
            acr_registries=$(az acr list --query "[].name" --output tsv 2>/dev/null)
            check_error $? "    Failed to list ACR registries across all locations."
        fi

        for registry_name in $acr_registries; do
            echo "  Checking ACR registry: $registry_name"
            # List repositories in the registry
            local repositories=$(az acr repository list --name "$registry_name" --output tsv 2>/dev/null)
            if [ -z "$repositories" ]; then
                echo "      No repositories found in registry '$registry_name'."
                continue
            fi
            for repo_name in $repositories; do
                # Count images (tags) in each repository
                local image_count=$(az acr repository show-tags --name "$registry_name" --repository "$repo_name" --output tsv 2>/dev/null | wc -l)
                echo "      Repository '$repo_name': $image_count images"
                total_images_acr=$((total_images_acr + image_count))
            done
        done
        container_image_workloads=$total_images_acr # Each image counted as a workload unit
        total_container_image_workloads_sub=$((total_container_image_workloads_sub + container_image_workloads))
        echo "  $(tput bold)$(tput setaf 6)Container Image Workloads: $container_image_workloads$(tput sgr0)"
        echo ""

        # Count Azure Storage Accounts (S3 equivalent)
        echo "  Counting Azure Storage Accounts..."
        local storage_account_count=0
        if [[ "${LOCATION}" ]]; then
            storage_account_count=$(az storage account list --query "[?location=='$LOCATION'].id" --output tsv 2>/dev/null | wc -l)
            check_error $? "    Failed to list Storage Accounts in location $LOCATION."
        else
            storage_account_count=$(az storage account list --query "[].id" --output tsv 2>/dev/null | wc -l)
            check_error $? "    Failed to list Storage Accounts across all locations."
        fi
        storage_workloads=$(( (storage_account_count+10-1)/10 )) # Assuming 10 storage accounts per workload unit
        if (( storage_account_count == 0 )); then
            storage_workloads=0
        fi
        total_storage_workloads_sub=$((total_storage_workloads_sub + storage_workloads))
        echo "  $(tput bold)$(tput setaf 6)Storage Workloads: $storage_workloads$(tput sgr0)"
        echo ""

        # Count Azure Database services (PaaS)
        echo "  Counting PaaS workloads (Azure SQL, Cosmos DB, Azure Database for PostgreSQL/MySQL/MariaDB)..."
        local azure_sql_db_count=0
        local cosmosdb_count=0
        local postgres_count=0
        local mysql_count=0
        local mariadb_count=0
        local sql_managed_instance_count=0
        local postgresflex_count=0
        local mysqlflex_count=0


        # Azure SQL Databases (logical servers, databases within them)
        if [[ "${LOCATION}" ]]; then
            azure_sql_db_count=$(az sql server list --query "[?location=='$LOCATION'].id" --output tsv --only-show-errors 2>/dev/null | wc -l)
            check_error $? "    Failed to list Azure SQL Servers in location $LOCATION."
        else
            azure_sql_db_count=$(az sql server list --query "[].id" --output tsv --only-show-errors 2>/dev/null | wc -l)
            check_error $? "    Failed to list Azure SQL Servers across all locations."
        fi
        echo "  Azure SQL Servers: $azure_sql_db_count"
        total_azure_sql_servers=$((total_azure_sql_servers + azure_sql_db_count))

        # Azure SQL Managed Instances
        if [[ "${LOCATION}" ]]; then
            sql_managed_instance_count=$(az sql mi list --query "[?location=='$LOCATION'].id" --output tsv --only-show-errors 2>/dev/null | wc -l)
            check_error $? "    Failed to list Azure SQL Managed Instances in location $LOCATION."
        else
            sql_managed_instance_count=$(az sql mi list --query "[].id" --output tsv --only-show-errors 2>/dev/null | wc -l)
            check_error $? "    Failed to list Azure SQL Managed Instances across all locations."
        fi
        echo "  Azure SQL Managed Instances: $sql_managed_instance_count"
        total_sql_managed_instances=$((total_sql_managed_instances + sql_managed_instance_count))

        # Cosmos DB Accounts
        if [[ "${LOCATION}" ]]; then
            cosmosdb_count=$(az cosmosdb list --query "[?location=='$LOCATION'].id" --output tsv --only-show-errors 2>/dev/null | wc -l)
            check_error $? "    Failed to list Cosmos DB accounts in location $LOCATION."
        else
            cosmosdb_count=$(az cosmosdb list --query "[].id" --output tsv --only-show-errors 2>/dev/null | wc -l)
            check_error $? "    Failed to list Cosmos DB accounts across all locations."
        fi
        echo "  Cosmos DB accounts: $cosmosdb_count"
        total_cosmosdb_accounts=$((total_cosmosdb_accounts + cosmosdb_count))

        # Azure Database for PostgreSQL servers
        if [[ "${LOCATION}" ]]; then
            postgres_count=$(az postgres server list --query "[?location=='$LOCATION'].id" --output tsv  --only-show-errors 2>/dev/null | wc -l)
            check_error $? "    Failed to list Azure Database for PostgreSQL servers in location $LOCATION."
        else
            postgres_count=$(az postgres server list --query "[].id" --output tsv --only-show-errors 2>/dev/null | wc -l)
            check_error $? "    Failed to list Azure Database for PostgreSQL servers across all locations."
        fi
        echo "  Azure Database for PostgreSQL servers: $postgres_count"

        # Azure Database for PostgreSQL flexible server
        if [[ "${LOCATION}" ]]; then
            postgresflex_count=$(az postgres flexible-server list --query "[?location=='$LOCATION'].id" --output tsv --only-show-errors 2>/dev/null | wc -l)
            check_error $? "    Failed to list Azure Database for PostgreSQL servers in location $LOCATION."
        else
            postgresflex_count=$(az postgres flexible-server list --query "[].id" --output tsv --only-show-errors 2>/dev/null | wc -l)
            check_error $? "    Failed to list Azure Database for PostgreSQL servers across all locations."
        fi
        echo "  Azure Database for PostgreSQL flexible servers: $postgresflex_count"
        
        # Azure Database for MySQL servers
        if [[ "${LOCATION}" ]]; then
            mysql_count=$(az mysql server list --query "[?location=='$LOCATION'].id" --output tsv --only-show-errors 2>/dev/null | wc -l)
            check_error $? "    Failed to list Azure Database for MySQL servers in location $LOCATION."
        else
            mysql_count=$(az mysql server list --query "[].id" --output tsv --only-show-errors 2>/dev/null | wc -l)
            check_error $? "    Failed to list Azure Database for MySQL servers across all locations."
        fi
        echo "  Azure Database for MySQL servers: $mysql_count"

        # Azure Database for MySQL flexible server
        if [[ "${LOCATION}" ]]; then
            mysqlflex_count=$(az mysql flexible-server list --query "[?location=='$LOCATION'].id" --output tsv --only-show-errors 2>/dev/null | wc -l)
            check_error $? "    Failed to list Azure Database for MySQL servers in location $LOCATION."
        else
            mysqlflex_count=$(az mysql flexible-server list --query "[].id" --output tsv --only-show-errors 2>/dev/null | wc -l)
            check_error $? "    Failed to list Azure Database for MySQL servers across all locations."
        fi
        echo "  Azure Database for MySQL flexible servers: $mysqlflex_count"

        # Azure Database for MariaDB servers
        if [[ "${LOCATION}" ]]; then
            mariadb_count=$(az mariadb server list --query "[?location=='$LOCATION'].id" --output tsv --only-show-errors 2>/dev/null | wc -l)
            check_error $? "    Failed to list Azure Database for MariaDB servers in location $LOCATION."
        else
            mariadb_count=$(az mariadb server list --query "[].id" --output tsv --only-show-errors 2>/dev/null | wc -l)
            check_error $? "    Failed to list Azure Database for MariaDB servers across all locations."
        fi
        echo "  Azure Database for MariaDB servers: $mariadb_count"


        local total_paas_databases=$((azure_sql_db_count + cosmosdb_count + postgres_count + postgresflex_count + mysql_count + mysqlflex_count + mariadb_count + sql_managed_instance_count))
        paas_workloads=$(( (total_paas_databases + 2 - 1) / 2 )) # Assuming 2 PaaS database instances per workload unit
        if (( total_paas_databases == 0 )); then
            paas_workloads=0
        fi
        total_paas_workloads_sub=$((total_paas_workloads_sub + paas_workloads))
        echo "  $(tput bold)$(tput setaf 6)PaaS Workloads: $paas_workloads$(tput sgr0)"
        echo ""
    }

    # Main logic for Azure
    # In Azure, we typically work within a single subscription at a time unless explicitly managing multiple.
    # The script will count resources in the currently active Azure subscription.
    current_subscription=$(az account show --query "id" --output tsv)
    check_error $? "Failed to get current Azure subscription ID. Please ensure you are logged in."
    count_resources "$current_subscription"

    echo "    SUMMARY WORKLOAD COUNTS FOR: $sub_name (ID: $sub_id)"
    echo "     VM workloads: $total_vm_instances"
    echo "     VM (container) workloads: $total_aks_workloads_sub"
    echo "     Serverless workloads: $total_serverless_workloads_sub"
    echo "     Storage workloads: $total_storage_workloads_sub"
    echo "     CaaS workloads: $total_caas_workloads_sub"
    echo "     Container Image workloads: $total_container_image_workloads_sub"
    echo "     PaaS workloads: $total_paas_workloads_sub"
    current_sub_total=$((total_vm_instances + total_aks_workloads_sub + total_serverless_workloads_sub + total_storage_workloads_sub + total_caas_workloads_sub + total_container_image_workloads_sub + total_paas_workloads_sub))
    echo "$(tput bold)$(tput setaf 6)    SUMMARY WORKLOADS: $current_sub_total$(tput sgr0)"
    echo ""
    sum_total_azure_workloads=$((sum_total_azure_workloads + current_sub_total))
    # echo "sum_total_azure_workloads: $sum_total_azure_workloads"
# Use process substitution here to keep the while loop in the current shell
done < <(echo "$subscriptions" | jq -c '.[]')

echo "$(tput bold)$(tput setaf 6)** SUM TOTAL AZURE WORKLOADS: $sum_total_azure_workloads **$(tput sgr0)"
