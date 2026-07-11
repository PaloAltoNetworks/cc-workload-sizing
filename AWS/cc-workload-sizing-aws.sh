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
        # Optionally unset credentials if in org mode before exiting
        if [ "$ORG_MODE" == true ] && [ -n "$AWS_SESSION_TOKEN" ]; then
            unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
        fi
        exit $exit_code
    fi
}

function printHelp {
  echo ""
  echo "NOTES:"
  echo "* Requires AWS CLI v2 to execute"
  echo "* Requires JQ utility to be installed"
  echo "* Validated to run successfully from within CSP console CLIs"
  echo ""
  echo "Available flags:"
  echo "  -h Display the help info"
  echo "  -n <region> Single region to scan (e.g. us-east-1)"
  echo "  -o Organization mode"
  echo "     This option will fetch all sub-accounts associated with an organization"
  echo "     and assume the default cross account role in order to iterate through and"
  echo "     scan resources in each sub-account."
  echo "  -r <role> Specify a non default role to assume in combination with organization mode"
  echo ""
  exit 1
}

echo "$(tput bold)$(tput setaf 2)";echo "   ___  _                 _   ___                     _ _         ";echo "  / __\___ _ __| |_   _____ __   / __\ | ___  _   _  __| |";echo " / /  / _ \| '__| __/ _ \ \/ /  / /  | |/ _ \| | | |/ _\` |";echo "/ /__| (_) | |  | ||  __/>  <  / /___| | (_) | |_| | (_| |";echo "\____/\___/|_|   \__\___\/_/\_\ \____/|_|\___/ \__,_|\__,_|";echo "                                                           ";echo "                                                          ";echo "$(tput sgr0)";

# Ensure AWS CLI is configured
aws sts get-caller-identity > /dev/null 2>&1
check_error $? "AWS CLI not configured or credentials invalid. Please run 'aws configure'."

# Initialize options
ORG_MODE=false
ROLE="OrganizationAccountAccessRole"
REGION=""
STATE="running,stopped"

# Get options
while getopts ":cdhn:or:s" opt; do
  case ${opt} in
    c) SSM_MODE=true ;;
    h) printHelp ;;
    n) REGION="$OPTARG" ;;
    o) ORG_MODE=true ;;
    r) ROLE="$OPTARG" ;;
    s) STATE="running,stopped" ;;
    \*) echo "Invalid option: -$OPTARG" && printHelp exit ;;
  esac
done
shift $((OPTIND-1))

# Get enabled regions for the current account context
echo "Fetching enabled regions for the account..."
activeRegions=$(aws account list-regions --region-opt-status-contains ENABLED ENABLED_BY_DEFAULT --query "Regions[].RegionName" --output text)
check_error $? "Failed to list enabled AWS regions. Ensure 'account:ListRegions' permission is granted."

if [ -z "$activeRegions" ]; then
    echo "Error: Could not retrieve list of enabled regions."
    exit 1
fi

# Validate region flag
if [[ "${REGION}" ]]; then
    if echo "$activeRegions" | grep -qw "$REGION"; then
        echo "Requested region ($REGION) is valid."
    else
        echo "Invalid region requested: $REGION";
        exit 1
    fi
else
    echo "Enabled regions found: $activeRegions"
fi

if [ "$ORG_MODE" == true ]; then
  echo "Organization mode active"
  echo "Role to assume: $ROLE"
fi

# Global Counters
total_ec2_instances=0
total_eks_nodes=0
total_s3_buckets=0
total_functions=0
total_efs=0
total_aurora=0
total_rds=0
total_dynamodb=0
total_redshift=0
total_paas_workloads=0
total_caas_workloads=0
total_container_image_workloads=0
total_serverless_workloads=0
total_eks_workloads=0
total_s3_workloads=0

# Function to count resources in a single account
count_resources() {
    local account_id=$1

    if [ "$ORG_MODE" == true ]; then
        creds=$(aws sts assume-role --role-arn "arn:aws:iam::$account_id:role/$ROLE" --role-session-name "OrgSession" --query "Credentials" --output json 2> /dev/null)
        local assume_role_exit_code=$?

        if [ $assume_role_exit_code -ne 0 ] || [ -z "$creds" ]; then
            echo "  Warning: Unable to assume role in account $account_id. Skipping account..."
            return
        fi

        export AWS_ACCESS_KEY_ID=$(echo $creds | jq -r ".AccessKeyId")
        export AWS_SECRET_ACCESS_KEY=$(echo $creds | jq -r ".SecretAccessKey")
        export AWS_SESSION_TOKEN=$(echo $creds | jq -r ".SessionToken")
    fi

    echo ""
    echo "Counting Cloud Security resources in account: $account_id"

    # Define regions to scan for this execution
    if [[ -n "${REGION}" ]]; then
        SCAN_REGIONS="$REGION"
    else
        SCAN_REGIONS="$activeRegions"
    fi

    # 1. Count EC2 instances (Excluding EKS Nodes)
    echo "   Counting EC2 instances..."
    ec2_count=0
    for r in $SCAN_REGIONS; do
        count_in_region=$(aws ec2 describe-instances --region "$r" --filters "Name=instance-state-name,Values=$STATE" --query "Reservations[*].Instances[*]" --output json 2>/dev/null | jq '[flatten[] | select(.Tags == null or (.Tags | map(.Key | startswith("eks:") or startswith("kubernetes.io/cluster/")) | any | not))] | length')
        if [ $? -eq 0 ] && [[ "$count_in_region" =~ ^[0-9]+$ ]] && [ "$count_in_region" -gt 0 ]; then
            echo "     Region $r: $count_in_region standalone instances"
            ec2_count=$((ec2_count + count_in_region))
        fi
    done
    echo "   $(tput bold)$(tput setaf 2)Standalone VM Workloads: $ec2_count$(tput sgr0)"
    total_ec2_instances=$((total_ec2_instances + ec2_count))

    # 2. Count EKS nodes
    echo "   Counting EKS nodes..."
    for r in $SCAN_REGIONS; do
        clusters=$(aws eks list-clusters --region "$r" --query "clusters" --output text 2>/dev/null)
        for cluster in $clusters; do
            node_groups=$(aws eks list-nodegroups --region "$r" --cluster-name "$cluster" --query 'nodegroups' --output text 2>/dev/null)
            total_nodes=0
            for node_group in $node_groups; do
                node_count=$(aws eks describe-nodegroup --region "$r" --cluster-name "$cluster" --nodegroup-name "$node_group" --query "nodegroup.scalingConfig.desiredSize" --output text 2>/dev/null)
                if [[ "$node_count" =~ ^[0-9]+$ ]]; then
                    total_nodes=$((total_nodes + node_count))
                    total_eks_nodes=$((total_eks_nodes + node_count))
                fi
            done
            if [ "$total_nodes" -gt 0 ]; then
                echo "     Region $r - EKS cluster '$cluster': $total_nodes nodes"
            fi
        done
    done
    total_eks_workloads=$total_eks_nodes
    echo "   $(tput bold)$(tput setaf 2)VM (Container) Workloads: $total_eks_workloads$(tput sgr0)"

    # 3. Count Serverless Functions
    echo ""
    echo "   Counting active and inactive serverless functions in AWS..."
    active_functions=0
    inactive_functions=0
    for r in $SCAN_REGIONS; do
        function_arns=$(aws lambda list-functions --region "$r" --query 'Functions[].FunctionArn' --output text 2>/dev/null)
        if [ -n "$function_arns" ]; then
            for arn in $function_arns; do
                function_state_info=$(aws lambda get-function-configuration --region "$r" --function-name "$arn" --query '{State: State, LastUpdateStatus: LastUpdateStatus}' --output json 2>/dev/null)
                state=$(echo "$function_state_info" | jq -r '.State')
                last_update_status=$(echo "$function_state_info" | jq -r '.LastUpdateStatus')

                if [[ "$state" == "Active" && "$last_update_status" == "Successful" ]]; then
                    active_functions=$((active_functions + 1))
                else
                    inactive_functions=$((inactive_functions + 1))
                fi
            done
        fi
    done
    account_total_functions=$((active_functions + inactive_functions))
    total_functions=$((total_functions + account_total_functions))
    
    serverless_workloads=$(( (account_total_functions + 25 - 1) / 25 ))
    if (( account_total_functions == 0 )); then serverless_workloads=0; fi
    total_serverless_workloads=$((total_serverless_workloads + serverless_workloads))
    
    echo "   Total Serverless Functions: $account_total_functions"
    echo "   $(tput bold)$(tput setaf 2)Serverless Workloads: $serverless_workloads$(tput sgr0)"

    # 4. Count CaaS
    echo ""
    echo "   Counting managed container resources (CaaS)..."
    ecs_fargate_services=0
    apprunner_services=0
    
    for r in $SCAN_REGIONS; do
        # ECS Clusters
        ecs_clusters=$(aws ecs list-clusters --region "$r" --query 'clusterArns[]' --output text 2>/dev/null)
        for cluster_arn in $ecs_clusters; do
            service_arns=$(aws ecs list-services --region "$r" --cluster "$cluster_arn" --query 'serviceArns[]' --output text 2>/dev/null)
            for service_arn in $service_arns; do
                service_details=$(aws ecs describe-services --region "$r" --cluster "$cluster_arn" --services "$service_arn" --query 'services[0].launchType' --output text 2>/dev/null)
                if [ "$service_details" == "Fargate" ]; then
                    ecs_fargate_services=$((ecs_fargate_services + 1))
                fi
            done
        done
        # App Runner
        apprunner_service_arns=$(aws apprunner list-services --region "$r" --query 'ServiceSummaryList[].ServiceArn' --output text 2>/dev/null)
        for arn in $apprunner_service_arns; do
            apprunner_services=$((apprunner_services + 1))
        done
    done

    total_managed_containers=$((ecs_fargate_services + apprunner_services))
    echo "   Total Managed Containers (CaaS): $total_managed_containers"
    caas_workloads=$((total_managed_containers / 10))
    total_caas_workloads=$((total_caas_workloads + caas_workloads))
    echo "   $(tput bold)$(tput setaf 2)CaaS Workloads: $caas_workloads$(tput sgr0)"

    # 5. Count Container Images 
    echo ""
    echo "   Counting ECR container images..."
    total_images_in_account=0
    for r in $SCAN_REGIONS; do
        repository_names=$(aws ecr describe-repositories --region "$r" --query 'repositories[].repositoryName' --output text 2>/dev/null | tr '\t' '\n')
        for repo_name in $repository_names; do
            if [ -n "$repo_name" ]; then
                image_count=$(aws ecr describe-images --region "$r" --repository-name "$repo_name" --query 'imageDetails[].imageDigest' --output text 2>/dev/null | wc -l)
                total_images_in_account=$((total_images_in_account + image_count))
                
                # Formula matching original script per repo
                container_image_workload=$(( image_count - ((ec2_count + total_eks_nodes) * 10) ))
                if (( container_image_workload < 0 )); then container_image_workload=0; fi
                total_container_image_workloads=$((total_container_image_workloads + container_image_workload))
            fi
        done
    done
    echo "   Total Images Across All Registries in Account: $total_images_in_account"
    echo "   $(tput bold)$(tput setaf 2)Container Image Workloads: $total_container_image_workloads$(tput sgr0)"
    echo ""

    # 6. Count S3 buckets (Global Resource - only evaluate once)
    echo "   Counting up bucket workloads..."
    # Grab the first region from SCAN_REGIONS to satisfy the AWS CLI region requirement
    s3_target_region=$(echo "$SCAN_REGIONS" | awk '{print $1}')
    s3_count=$(aws s3api list-buckets --region "$s3_target_region" --query "Buckets[*].Name" --output text 2>/dev/null | wc -w)
    
    echo "   S3 buckets: $s3_count"
    total_s3_buckets=$((total_s3_buckets + s3_count))
    s3_workloads=$(( (total_s3_buckets + 10 - 1) / 10 ))
    if (( total_s3_buckets == 0 )); then s3_workloads=0; fi
    total_s3_workloads=$((total_s3_workloads + s3_workloads))
    echo "   $(tput bold)$(tput setaf 2)S3 workloads: $s3_workloads$(tput sgr0)"
    echo ""

    # 7. Count PaaS workloads
    echo "   Counting up PaaS workloads..."
    account_efs=0
    account_aurora=0
    account_rds=0
    account_dynamodb=0
    account_redshift=0

    for r in $SCAN_REGIONS; do
        e=$(aws efs describe-file-systems --region "$r" --query "FileSystems[*].FileSystemId" --output text 2>/dev/null | wc -w)
        account_efs=$((account_efs + e))
        
        a=$(aws rds describe-db-clusters --region "$r" --query "DBClusters[?Engine=='aurora'].DBClusterIdentifier" --output text 2>/dev/null | wc -w)
        account_aurora=$((account_aurora + a))
        
        rd=$(aws rds describe-db-instances --region "$r" --query "DBInstances[?Engine=='mysql' || Engine=='mariadb' || Engine=='postgres'].DBInstanceIdentifier" --output text 2>/dev/null | wc -w)
        account_rds=$((account_rds + rd))
        
        d=$(aws dynamodb list-tables --region "$r" --query "TableNames" --output text 2>/dev/null | wc -w)
        account_dynamodb=$((account_dynamodb + d))
        
        rs=$(aws redshift describe-clusters --region "$r" --query "Clusters[*].ClusterIdentifier" --output text 2>/dev/null | wc -w)
        account_redshift=$((account_redshift + rs))
    done

    echo "   EFS file systems: $account_efs"
    echo "   Aurora clusters: $account_aurora"
    echo "   RDS instances: $account_rds"
    echo "   DynamoDB tables: $account_dynamodb"
    echo "   Redshift clusters: $account_redshift"

    total_rds=$((total_rds + account_rds))
    total_aurora=$((total_aurora + account_aurora))
    total_dynamodb=$((total_dynamodb + account_dynamodb))
    total_redshift=$((total_redshift + account_redshift))

    paas_workloads=$(( (account_rds + account_aurora + account_dynamodb + account_redshift + 2 - 1) / 2 ))
    if (( (account_rds + account_aurora + account_dynamodb + account_redshift) == 0 )); then
        paas_workloads=0
    fi
    total_paas_workloads=$((total_paas_workloads + paas_workloads))
    echo "   $(tput bold)$(tput setaf 2)PaaS Workloads: $paas_workloads$(tput sgr0)"

    # Unset temporary credentials
    if [ "$ORG_MODE" == true ] && [ -n "$AWS_SESSION_TOKEN" ]; then
        unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    fi
}

# Main logic
if [ "$ORG_MODE" == true ]; then
    accounts=$(aws organizations list-accounts --query "Accounts[?Status=='ACTIVE'].Id" --output text)
    check_error $? "Failed to list accounts in the organization. Ensure you have 'organizations:ListAccounts' permission."

    if [ -z "$accounts" ]; then
        echo "No accounts found in the organization."
        exit 0
    fi

    for account_id in $accounts; do
        count_resources "$account_id"
    done
else
    current_account=$(aws sts get-caller-identity --query "Account" --output text)
    check_error $? "Failed to get caller identity for the current account."
    count_resources "$current_account"
fi

echo ""
echo " -- AWS WORKLOAD COUNTS --"
echo " VM workloads: $total_ec2_instances"
echo " VM (container) workloads: $total_eks_workloads"
echo " Serverless workloads: $total_serverless_workloads"
echo " S3 workloads: $total_s3_workloads"
echo " CaaS workloads: $total_caas_workloads"
echo " Container Image workloads: $total_container_image_workloads"
echo " PaaS workloads: $total_paas_workloads" 
echo ""
echo "$(tput bold)$(tput setaf 2)** SUM TOTAL AWS WORKLOADS: $((total_ec2_instances+total_eks_workloads+total_serverless_workloads+total_s3_workloads+total_caas_workloads+total_container_image_workloads+total_paas_workloads)) **$(tput sgr0)"
