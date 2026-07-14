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
        # Avoid leaving temporary credentials in effect before exiting.
        if [ "$ORG_MODE" == true ]; then
            unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
        fi
        exit $exit_code
    fi
}

# Function to print hint for SSO login
function print_sso_login_hint {
    echo ""
    echo "HINT: To use -o (Organization mode) with AWS SSO, you must first log in."
    if [ -n "$SSO_PROFILE" ]; then
        echo "Try running: aws sso login --profile $SSO_PROFILE"
    else
        echo "Try running: aws sso login --profile <your_sso_profile>"
    fi
    echo ""
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
  echo "  -n <region> Single region to scan"
  echo "  -R <regions> Comma-separated region list to scan; skips AWS region discovery"
  echo "  -o Organization mode"
  echo "     This option will use your cached AWS SSO login to fetch every account"
  echo "     assigned to you, then directly request credentials for the default"
  echo "     (or specified) SSO role/permission set in each account."
  echo "  -p <profile> Optional source AWS SSO profile/session used to locate the cached login"
  echo "     token. This is one SSO login profile, not one profile per account."
  echo "  -r <role> Specify a non-default SSO role/permission set in organization mode"
  echo ""
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

# Initialize options
ORG_MODE=false
ROLE="AWSReadOnlyAccess"
REGION=""
REGION_LIST=""
MANUAL_REGIONS=""
STATE="running,stopped"
SSO_PROFILE=""
SSO_ACCESS_TOKEN=""
SSO_REGION=""
SSO_START_URL=""

# Get options
while getopts ":dhn:oR:p:r:s" opt; do
  case ${opt} in
    h) printHelp ;;
    n) REGION="$OPTARG" ;;
    o) ORG_MODE=true ;;
    R) REGION_LIST="$OPTARG" ;;
    p) SSO_PROFILE="$OPTARG" ;;
    r) ROLE="$OPTARG" ;;
    s) STATE="running,stopped" ;;
    \*) echo "Invalid option: -$OPTARG" && printHelp exit ;;
  esac
done
shift $((OPTIND-1))

if [ -n "$REGION" ] && [ -n "$REGION_LIST" ]; then
    echo "Error: -n <region> and -R <regions> cannot be used together."
    exit 1
fi

if [ -n "$REGION_LIST" ]; then
    MANUAL_REGIONS=$(echo "$REGION_LIST" | tr ',' ' ' | xargs)
    if [ -z "$MANUAL_REGIONS" ]; then
        echo "Error: -R requires at least one region."
        exit 1
    fi
fi

if [ "$ORG_MODE" == true ]; then
  echo "Organization mode active"
  echo "SSO role/permission set to use: $ROLE"
else
  # Ensure AWS CLI is configured for standalone mode.
  aws sts get-caller-identity > /dev/null 2>&1
  check_error $? "AWS CLI not configured or credentials invalid. Please run 'aws configure'."
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
        # Use SSO access token to fetch credentials for the account/role combo.
        creds_json=$(aws sso get-role-credentials \
            --access-token "$SSO_ACCESS_TOKEN" \
            --region "$SSO_REGION" \
            --account-id "$account_id" \
            --role-name "$ROLE" \
            --output json 2>/dev/null)
        local exit_code=$?

        if [ $exit_code -ne 0 ] || [ -z "$creds_json" ]; then
            echo "  Warning: Unable to get credentials for role '$ROLE' in account $account_id. Skipping account..."
            return
        fi

        export AWS_ACCESS_KEY_ID=$(echo "$creds_json" | jq -r ".roleCredentials.accessKeyId")
        export AWS_SECRET_ACCESS_KEY=$(echo "$creds_json" | jq -r ".roleCredentials.secretAccessKey")
        export AWS_SESSION_TOKEN=$(echo "$creds_json" | jq -r ".roleCredentials.sessionToken")
    fi

    echo ""
    echo "Counting Cloud Security resources in account: $account_id"

    # Only fetch active regions for the first account or if not using manual regions.
    if [ -z "$MANUAL_REGIONS" ]; then
        if [ -z "$activeRegions" ]; then
            echo "Fetching enabled regions for the account..."
            activeRegions=$(aws account list-regions --region-opt-status-contains ENABLED ENABLED_BY_DEFAULT --query "Regions[].RegionName" --output text 2>/dev/null)
            if [ $? -ne 0 ] || [ -z "$activeRegions" ]; then
                 echo "Warning: Could not fetch active regions for account $account_id. Will fallback to basic region list."
                 activeRegions="us-east-1 us-east-2 us-west-1 us-west-2"
            fi
        fi
        
        # Validate -n region if provided
        if [ -n "$REGION" ]; then
            if ! echo "$activeRegions" | grep -qw "$REGION"; then
                echo "Warning: Requested region $REGION does not appear to be enabled for account $account_id. Proceeding anyway."
            fi
        fi
    fi

    # Determine which regions to scan
    if [[ -n "${MANUAL_REGIONS}" ]]; then
        SCAN_REGIONS="$MANUAL_REGIONS"
    elif [[ -n "${REGION}" ]]; then
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
    if [ "$ORG_MODE" == true ]; then
        unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
    fi
}

# Main logic
if [ "$ORG_MODE" == true ]; then
    sso_session_info=$(python3 -c "
import os, json, glob, datetime

def find_sso_session():
    sso_cache_dir = os.path.expanduser('~/.aws/sso/cache')
    if not os.path.isdir(sso_cache_dir):
        return None

    # Sort files by modification time, newest first
    json_files = sorted(glob.glob(os.path.join(sso_cache_dir, '*.json')), key=os.path.getmtime, reverse=True)
    
    for file_path in json_files:
        try:
            with open(file_path, 'r') as f:
                data = json.load(f)
                
            # Check for a valid, non-expired accessToken
            if 'accessToken' in data and 'expiresAt' in data:
                # AWS CLI cache uses UTC (e.g., '2025-02-27T17:03:00UTC')
                # A simple string comparison often works if we format current time similarly,
                # but a robust check handles the 'UTC' or 'Z' suffix.
                exp_str = data['expiresAt'].replace('UTC', '').replace('Z', '')
                try:
                    exp_time = datetime.datetime.strptime(exp_str, '%Y-%m-%dT%H:%M:%S')
                except ValueError:
                    continue # Skip if date format is unexpected

                if exp_time > datetime.datetime.utcnow():
                    # We found a valid token. Now we need the corresponding region.
                    # This script relies on SSO_REGION being available, which is sometimes in the cache
                    # or needs to be derived. The original script used a Python snippet that
                    # expected region in the cache or provided as fallback.
                    region = data.get('region', '')
                    start_url = data.get('startUrl', '')
                    return f\"{data['accessToken']}\\t{region}\\t{start_url}\"
        except Exception:
            continue
    return None

result = find_sso_session()
if result:
    print(result)
" 2>/dev/null)

    if [ $? -ne 0 ] || [ -z "$sso_session_info" ]; then
        echo "Error: No valid cached AWS SSO login token found."
        print_sso_login_hint
        exit 1
    fi

    IFS=$'\t' read -r SSO_ACCESS_TOKEN SSO_REGION SSO_START_URL <<< "$sso_session_info"

    if [ -z "$SSO_ACCESS_TOKEN" ] || [ -z "$SSO_REGION" ]; then
        echo "Error: Cached AWS SSO login token is missing an access token or SSO region."
        # If the region was missing in the cache JSON, we can try to fallback to AWS_REGION if set
        if [ -n "$AWS_REGION" ] && [ -n "$SSO_ACCESS_TOKEN" ]; then
            SSO_REGION="$AWS_REGION"
            echo "Falling back to SSO Region from environment: $SSO_REGION"
        elif [ -n "$AWS_DEFAULT_REGION" ] && [ -n "$SSO_ACCESS_TOKEN" ]; then
            SSO_REGION="$AWS_DEFAULT_REGION"
            echo "Falling back to SSO Region from environment: $SSO_REGION"
        else
            print_sso_login_hint
            exit 1
        fi
    fi

    if [ -n "$SSO_START_URL" ]; then
        echo "Using cached AWS SSO session for $SSO_START_URL in $SSO_REGION"
    else
        echo "Using cached AWS SSO session in $SSO_REGION"
    fi

    # Get the list of accounts assigned to the cached SSO login.
    accounts=$(aws sso list-accounts --access-token "$SSO_ACCESS_TOKEN" --region "$SSO_REGION" --query "accountList[].accountId" --output text 2>/dev/null)
    if [ $? -ne 0 ]; then
        echo "Error: Failed to list accounts from AWS SSO."
        print_sso_login_hint
        exit 1
    fi

    if [ -z "$accounts" ]; then
        echo "No accounts found for the cached AWS SSO login."
        exit 0
    fi

    # Loop through each SSO-assigned account.
    for account_id in $accounts; do
        count_resources "$account_id"
    done
else
    # Run for the standalone account
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
