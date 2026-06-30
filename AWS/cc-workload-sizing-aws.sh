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

function printHelp {
    echo ""
    echo "NOTES:"
    echo "* Requires AWS CLI v2 to execute"
    echo "* Requires JQ utility to be installed (TODO: Install JQ from script; exists in AWS)"
    echo "* Validated to run successfully from within CSP console CLIs"
    echo ""
    echo "Available flags:"
    echo " -h          Display the help info"
    echo " -n <region> Single region to scan"
    echo " -R <regions> Comma-separated region list to scan; skips AWS region discovery"
    echo " -o          Organization mode"
    echo "             This option will use your cached AWS SSO login to fetch every account"
    echo "             assigned to you, then directly request credentials for the default"
    echo "             (or specified) SSO role/permission set in each account."
    echo " -p <profile> Optional source AWS SSO profile/session used to locate the cached login"
    echo "             token. This is one SSO login profile, not one profile per account."
    echo " -r <role>   Specify a non-default SSO role/permission set in organization mode"
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
while getopts ":cdhn:oR:p:r:s" opt; do
  case ${opt} in
    c) SSM_MODE=true ;;
    h) printHelp ;;
    n) REGION="$OPTARG" ;;
    o) ORG_MODE=true ;;
    R) REGION_LIST="$OPTARG" ;;
    p) SSO_PROFILE="$OPTARG" ;;
    r) ROLE="$OPTARG" ;;
    s) STATE="running,stopped" ;;
    *) echo "Invalid option: -${OPTARG}" && printHelp exit ;;
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
  check_error $? "AWS CLI not configured or credentials invalid. Please run 'aws configure' or 'aws sso login'."
fi

# Initialize counters
total_ec2_instances=0
total_eks_nodes=0
total_s3_buckets=0
total_functions=0
total_efs=0
total_aurora=0
total_rds=0
total_dynamodb=0
total_redshift=0
total_ec2_db=0
ec2_db_count=0
paas_workloads=0
total_paas_workloads=0
caas_workloads=0
total_caas_workloads=0
container_image_workloads=0
total_container_image_workloads=0
serverless_workloads=0
total_serverless_workloads=0
eks_workloads=0
total_eks_workloads=0
s3_workloads=0
total_s3_workloads=0

function get_sso_profile_setting {
    local profile=$1
    local key=$2

    if [ -z "$profile" ]; then
        return 1
    fi

    aws configure get "$key" --profile "$profile" 2>/dev/null
}

function get_sso_session_setting {
    local session_name=$1
    local key=$2
    local config_file="${AWS_CONFIG_FILE:-$HOME/.aws/config}"

    if [ -z "$session_name" ] || [ ! -f "$config_file" ]; then
        return 1
    fi

    awk -v section="sso-session $session_name" -v key="$key" '
        function trim(value) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            return value
        }

        /^[[:space:]]*\[/ {
            current = $0
            sub(/^[[:space:]]*\[/, "", current)
            sub(/\][[:space:]]*$/, "", current)
            in_section = (current == section)
            next
        }

        in_section && $0 !~ /^[[:space:]]*(#|;|$)/ {
            separator = index($0, "=")
            if (separator == 0) {
                next
            }

            name = trim(substr($0, 1, separator - 1))
            value = trim(substr($0, separator + 1))

            if (name == key) {
                print value
                exit
            }
        }
    ' "$config_file"
}

function find_cached_sso_session {
    local profile=$1
    local expected_start_url=""
    local expected_region=""
    local sso_session_name=""
    local cache_files
    local session_info

    if [ -n "$profile" ]; then
        sso_session_name=$(get_sso_profile_setting "$profile" "sso_session")
        expected_start_url=$(get_sso_profile_setting "$profile" "sso_start_url")
        expected_region=$(get_sso_profile_setting "$profile" "sso_region")

        if [ -n "$sso_session_name" ]; then
            if [ -z "$expected_start_url" ]; then
                expected_start_url=$(get_sso_session_setting "$sso_session_name" "sso_start_url")
            fi
            if [ -z "$expected_region" ]; then
                expected_region=$(get_sso_session_setting "$sso_session_name" "sso_region")
            fi
        fi
    fi

    cache_files=("$HOME"/.aws/sso/cache/*.json)
    if [ ! -e "${cache_files[0]}" ]; then
        return 1
    fi

    session_info=$(jq -r -s --arg start "$expected_start_url" --arg region "$expected_region" '
        def clean_date: sub("\\.[0-9]+Z$"; "Z") | sub("UTC$"; "Z");
        [
            .[]?
            | select(.accessToken? and .expiresAt? and .region?)
            | select(($start == "" or (.startUrl // "") == $start) and ($region == "" or (.region // "") == $region))
            | . + {expiresEpoch: (try (.expiresAt | clean_date | fromdateiso8601) catch 0)}
            | select(.expiresEpoch > now)
        ]
        | sort_by(.expiresEpoch)
        | reverse
        | .[0] // empty
        | [.accessToken, .region, (.startUrl // "")]
        | @tsv
    ' "${cache_files[@]}" 2>/dev/null)

    if [ -z "$session_info" ]; then
        return 1
    fi

    echo "$session_info"
}

function print_sso_login_hint {
    if [ -n "$SSO_PROFILE" ]; then
        echo "Run: aws sso login --profile \"$SSO_PROFILE\""
    else
        echo "Run: aws sso login --profile <your-sso-profile>"
        echo "You can pass that source profile to this script with -p <profile>."
    fi
}

function clear_org_credentials {
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
}

# Function to count resources in a single account
count_resources() {
    local account_id=$1
    local activeRegions
    local caller_account
    local creds

    if [ "$ORG_MODE" == true ]; then
        # Fetch direct AWS Identity Center role credentials for this account.
        clear_org_credentials
        creds=$(aws sso get-role-credentials --account-id "$account_id" --role-name "$ROLE" \
            --access-token "$SSO_ACCESS_TOKEN" --region "$SSO_REGION" \
            --query "roleCredentials" --output json 2> /dev/null)
        local get_role_exit_code=$?

        if [ $get_role_exit_code -ne 0 ]; then
            echo "  Warning: Unable to get SSO role '$ROLE' credentials for account $account_id (Exit Code: $get_role_exit_code). Skipping account..."
            return
        fi

        if [ -z "$creds" ]; then
             echo "  Warning: SSO returned empty credentials for account $account_id. Skipping account..."
             return
        fi

        export AWS_ACCESS_KEY_ID=$(echo "$creds" | jq -r ".accessKeyId")
        export AWS_SECRET_ACCESS_KEY=$(echo "$creds" | jq -r ".secretAccessKey")
        export AWS_SESSION_TOKEN=$(echo "$creds" | jq -r ".sessionToken")

        caller_account=$(aws sts get-caller-identity --query "Account" --output text 2>/dev/null)
        if [ "$caller_account" != "$account_id" ]; then
            echo "  Warning: SSO credentials resolved to account $caller_account, expected $account_id. Skipping account..."
            clear_org_credentials
            return
        fi
    fi

    echo ""
    echo "Counting Cloud Security resources in account: $account_id"

    if [ -n "$MANUAL_REGIONS" ]; then
        activeRegions="$MANUAL_REGIONS"
        echo "Using provided regions for account $account_id: $activeRegions"
    else
        # Get enabled regions for the current account context.
        echo "Fetching enabled regions for account $account_id..."
        activeRegions=$(aws account list-regions --region-opt-status-contains ENABLED ENABLED_BY_DEFAULT --query "Regions[].RegionName" --output text)
        local list_regions_exit_code=$?

        if [ $list_regions_exit_code -ne 0 ]; then
            if [ "$ORG_MODE" == true ]; then
                echo "  Warning: Failed to list enabled AWS regions for account $account_id. Ensure 'account:ListRegions' permission is granted."
                echo "           To skip AWS region discovery, rerun with -R <region1,region2,...>."
                echo "           Skipping account..."
                clear_org_credentials
                return
            fi
            check_error $list_regions_exit_code "Failed to list enabled AWS regions. Ensure 'account:ListRegions' permission is granted. To skip AWS region discovery, rerun with -R <region1,region2,...>."
        fi

        if [ -z "$activeRegions" ]; then
            if [ "$ORG_MODE" == true ]; then
                echo "  Warning: Could not retrieve list of enabled regions for account $account_id."
                echo "           To skip AWS region discovery, rerun with -R <region1,region2,...>."
                echo "           Skipping account..."
                clear_org_credentials
                return
            fi
            echo "Error: Could not retrieve list of enabled regions."
            echo "To skip AWS region discovery, rerun with -R <region1,region2,...>."
            exit 1
        fi
        echo "Enabled regions found: $activeRegions"

        # Validate region flag against the current account context.
        if [[ "${REGION}" ]]; then
            # Use grep -w for whole word match to avoid partial matches (e.g., "us-east" matching "us-east-1")
            if echo "$activeRegions" | grep -qw "$REGION";
                then echo "Requested region is valid";
            else
                if [ "$ORG_MODE" == true ]; then
                    echo "  Warning: Requested region $REGION is not enabled for account $account_id. Skipping account..."
                    clear_org_credentials
                    return
                fi
                echo "Invalid region requested: $REGION";
                exit 1
            fi
        fi
    fi
       
    # Count EC2 instances
    if [[ "${REGION}" ]]; then
        ec2_count=$(aws ec2 describe-instances --region $REGION --filters "Name=instance-state-name,Values=$STATE" --query "Reservations[*].Instances[*]" --output json | jq 'length')
        check_error $? "Failed to describe EC2 instances in region $REGION for account $account_id."
    else
        echo "  Counting EC2 instances across all accessible regions..."
        ec2_count=0
        # Use the activeRegions variable fetched earlier
        for r in $activeRegions; do
            # Capture stderr to avoid cluttering output for regions where API might not be enabled/accessible
            count_in_region=$(aws ec2 describe-instances --region "$r" --filters "Name=instance-state-name,Values=$STATE" --query "Reservations[*].Instances[*]" --output json 2>/dev/null | jq 'length')
            if [ $? -eq 0 ] && [[ "$count_in_region" =~ ^[0-9]+$ ]]; then
                # Only print if count > 0 to reduce noise
                if [ "$count_in_region" -gt 0 ]; then
                    echo "    Region $r: $count_in_region instances"
                fi
                ec2_count=$((ec2_count + count_in_region))
            fi
        done
    fi
    echo "  $(tput bold)$(tput setaf 2)VM Workloads: $ec2_count$(tput sgr0)"
    total_ec2_instances=$((total_ec2_instances + ec2_count))
    total_ec2_workloads=$total_ec2_instances

    # Count EKS nodes
    if [[ "${REGION}" ]]; then
        clusters=$(aws eks list-clusters --region $REGION --query "clusters" --output text)
        check_error $? "Failed to list EKS clusters in region $REGION for account $account_id."
    else
        clusters=$(aws eks list-clusters --query "clusters" --output text)
        check_error $? "Failed to list EKS clusters (all regions) for account $account_id."
    fi        
    for cluster in $clusters; do
        node_groups=$(aws eks list-nodegroups --cluster-name "$cluster" --query 'nodegroups' --output text)
        # If listing nodegroups fails, log warning and skip this cluster
        if [ $? -ne 0 ]; then
            echo "    Warning: Failed to list nodegroups for EKS cluster '$cluster' in account $account_id. Skipping cluster."
            continue
        fi
        total_nodes=0
        for node_group in $node_groups; do
            node_count=$(aws eks describe-nodegroup --cluster-name "$cluster" --nodegroup-name "$node_group" --query "nodegroup.scalingConfig.desiredSize" --output text)
            # If describing nodegroup fails, log warning and skip this nodegroup
            if [ $? -ne 0 ]; then
                echo "    Warning: Failed to describe nodegroup '$node_group' for cluster '$cluster' in account $account_id. Skipping nodegroup."
                continue
            fi
            total_nodes=$((total_nodes + node_count))
            echo "  EKS cluster '$cluster' nodegroup $node_group nodes: $node_count"
            total_eks_nodes=$((total_eks_nodes + node_count))
            eks_workloads=$total_nodes
            total_eks_workloads=$((total_eks_nodes + eks_workloads))
            echo "  $(tput bold)$(tput setaf 2)VM (Container) Workloads: $eks_workloads$(tput sgr0)"
        done
    done

    # Count Serverless Functions
    echo ""
    echo "  Counting active and inactive serverless functions in AWS..."

    # Initialize counters
    active_functions=0
    inactive_functions=0

    # Get a list of all Lambda function ARNs
    # The --query argument filters the output to only the FunctionArn and flattens the list.
    # The --output text argument formats the output as plain text, one ARN per line.
    function_arns=$(aws lambda list-functions --query 'Functions[].FunctionArn' --output text)

    # Check if any functions were found
    if [ -z "$function_arns" ]; then
    echo "    No serverless functions found in your AWS account."
    else
    
        # Loop through each function ARN to get its state
        for arn in $function_arns; do
        # Extract the function name from the ARN for easier reading in output
        function_name=$(echo "$arn" | awk -F':' '{print $NF}')

        # Get the function configuration, specifically the State and LastUpdateStatus
        # We use jq to parse the JSON output and extract the relevant fields.
        # .Configuration.State will be "Active", "Inactive", "Pending" etc.
        # .Configuration.LastUpdateStatus will be "Successful", "Failed" etc.
        function_state_info=$(aws lambda get-function-configuration --function-name "$arn" --query '{State: State, LastUpdateStatus: LastUpdateStatus}' --output json)

        # Parse the state and last update status using jq
        state=$(echo "$function_state_info" | jq -r '.State')
        last_update_status=$(echo "$function_state_info" | jq -r '.LastUpdateStatus')

        #echo "Function: $function_name, State: $state, LastUpdateStatus: $last_update_status"

        # Determine if the function is active or inactive based on its state and last update status
        if [[ "$state" == "Active" && "$last_update_status" == "Successful" ]]; then
            active_functions=$((active_functions + 1))
        else
            inactive_functions=$((inactive_functions + 1))
        fi
        done
        total_functions=$((active_functions + inactive_functions))
        echo "    Total Serverless Functions: $total_functions"
    fi

    serverless_workloads=$(( (total_functions +25-1)/25 ))
    if (( $total_functions == 0 )); then 
        serverless_workloads=0
    fi
    total_serverless_workloads=$((total_serverless_workloads + serverless_workloads))
    echo "  $(tput bold)$(tput setaf 2)Serverless Workloads: $serverless_workloads$(tput sgr0)"

    # Count CaaS
    echo ""
    echo "  Counting managed container resources in AWS..."

    # Initialize counters
    ecs_fargate_services=0
    apprunner_services=0
    total_managed_containers=0

    # List all ECS clusters
    # We'll then iterate through each cluster to find Fargate services.
    ecs_clusters=$(aws ecs list-clusters --query 'clusterArns[]' --output text)

    if [ -z "$ecs_clusters" ]; then
        echo "    No ECS clusters found."
        else
            for cluster_arn in $ecs_clusters; do
                cluster_name=$(echo "$cluster_arn" | awk -F'/' '{print $NF}')
                echo "    Checking cluster: $cluster_name"

                # List services within the cluster
                # We need to describe each service to check its launch type (Fargate vs. EC2)
                service_arns=$(aws ecs list-services --cluster "$cluster_arn" --query 'serviceArns[]' --output text)

                if [ -z "$service_arns" ]; then
                    echo "      No services found in this cluster."
                else
                for service_arn in $service_arns; do
                    # Get service details to check launch type
                    service_details=$(aws ecs describe-services --cluster "$cluster_arn" --services "$service_arn" --query 'services[0].launchType' --output text)

                    if [ "$service_details" == "Fargate" ]; then
                     ecs_fargate_services=$((ecs_fargate_services + 1))
                      service_name=$(echo "$service_arn" | awk -F'/' '{print $NF}')
                     echo "    Found Fargate Service: $service_name"
                    fi
                done
                fi
            done
        fi

        # List all App Runner services
        apprunner_service_arns=$(aws apprunner list-services --query 'ServiceSummaryList[].ServiceArn' --output text)

        if [ -z "$apprunner_service_arns" ]; then
        echo "    No AWS App Runner services found."
        else
        for service_arn in $apprunner_service_arns; do
            apprunner_services=$((apprunner_services + 1))
            service_name=$(echo "$service_arn" | awk -F'/' '{print $NF}')
            echo "    Found App Runner Service: $service_name"
        done
        fi

        total_managed_containers=$((ecs_fargate_services + apprunner_services))
        caas_workloads=$[(total_managed_containers+10-1)/10]
        if (( total_managed_containers=0 )); then 
            caas_workloads=0
        fi
        total_caas_workloads=$((total_caas_workloads + caas_workloads))
        echo "  $(tput bold)$(tput setaf 2)CaaS Workloads: $caas_workloads$(tput sgr0)"
        echo ""

        # Count Container Images in Registries
        echo "  Counting container images in all registries..."

        # Initialize a counter for the total number of images across all repositories
        total_images_across_all_registries=0

        # List all ECR repositories
        # The --query 'repositories[].repositoryName' extracts only the names of the repositories
        # The --output text formats the output as plain text, one name per line
        repository_names=$(aws ecr describe-repositories --query 'repositories[].repositoryName' --output text)

        # Check if any repositories were found
        if [ -z "$repository_names" ]; then
        echo "    No ECR repositories found in your AWS account."
        else

            # Loop through each repository name
            for repo_name in $repository_names; do
            #echo "Repository: $repo_name"

            # Count images in the current repository
            # We use describe-images to get a list of image digests (unique identifiers for images).
            # We then use wc -l to count the number of lines, which corresponds to the number of images.
            # The || true part prevents the script from exiting if a repository has no images and describe-images returns an empty list.
            image_count=$(aws ecr describe-images --repository-name "$repo_name" --query 'imageDetails[].imageDigest' --output text | wc -l)

            # Add the current repository's image count to the total
            total_images_across_all_registries=$((total_images_across_all_registries + image_count))
            container_image_workload=$[(image_count-((ec2_count+total_eks_nodes)*10))]
            container_image_workload=$(( variable < 0 ? 0 : variable ))
            total_container_image_workload=$((total_container_image_workload + container_image_workload))
                done

            echo "  Total ECR Repositories Found: $(echo "$repository_names" | wc -l)"
            echo "  Total Images Across All Registries: $total_images_across_all_registries"
        fi
        echo "  $(tput bold)$(tput setaf 2)Container Image Workloads: $total_container_image_workload$(tput sgr0)"
        echo ""

        # Count S3 buckets
        echo "  Counting up bucket workloads..."
        if [[ "${REGION}" ]]; then
            s3_count=$(aws s3api list-buckets --region $REGION --query "Buckets[*].Name" --output text | wc -w)
            check_error $? "Failed to list S3 buckets in region $REGION for account $account_id."
        else
            s3_count=$(aws s3api list-buckets --query "Buckets[*].Name" --output text | wc -w)
            check_error $? "Failed to list S3 buckets (all regions) for account $account_id."
        fi   
        echo "    S3 buckets: $s3_count"
        total_s3_buckets=$((total_s3_buckets + s3_count))
        s3_workloads=$[(total_s3_buckets+10-1)/10]
        if (( total_s3_buckets=0 )); then
            s3_workloads=0
        fi
        total_s3_workloads=$((total_s3_workloads + s3_workloads))
        echo "  $(tput bold)$(tput setaf 2)S3 workloads: $s3_workloads$(tput sgr0)"
        echo ""

        echo "  Counting up PaaS workloads..."
        # Count EFS file systems
        if [[ "${REGION}" ]]; then
            efs_count=$(aws efs describe-file-systems --region $REGION --query "FileSystems[*].FileSystemId" --output text | wc -w)
            check_error $? "Failed to describe EFS file systems in region $REGION for account $account_id."
        else
            efs_count=$(aws efs describe-file-systems --query "FileSystems[*].FileSystemId" --output text | wc -w)
            check_error $? "Failed to describe EFS file systems (all regions) for account $account_id."
        fi  
        echo "    EFS file systems: $efs_count"
        total_efs=$((total_efs + efs_count))

        # Count Aurora clusters
        if [[ "${REGION}" ]]; then
            aurora_count=$(aws rds describe-db-clusters --region $REGION --query "DBClusters[?Engine=='aurora'].DBClusterIdentifier" --output text | wc -w)
            check_error $? "Failed to describe Aurora clusters in region $REGION for account $account_id."
        else
            aurora_count=$(aws rds describe-db-clusters --query "DBClusters[?Engine=='aurora'].DBClusterIdentifier" --output text | wc -w)
            check_error $? "Failed to describe Aurora clusters (all regions) for account $account_id."
        fi         
        echo "    Aurora clusters: $aurora_count"
        total_aurora=$((total_aurora + aurora_count))

        # Count RDS instances
        if [[ "${REGION}" ]]; then
            rds_count=$(aws rds describe-db-instances --region $REGION --query "DBInstances[?Engine=='mysql' || Engine=='mariadb' || Engine=='postgres'].DBInstanceIdentifier" --output text | wc -w)
            check_error $? "Failed to describe RDS instances in region $REGION for account $account_id."
        else
            rds_count=$(aws rds describe-db-instances --query "DBInstances[?Engine=='mysql' || Engine=='mariadb' || Engine=='postgres'].DBInstanceIdentifier" --output text | wc -w)
            check_error $? "Failed to describe RDS instances (all regions) for account $account_id."
        fi   
        echo "    RDS instances (MySQL, MariaDB, PostgreSQL): $rds_count"
        total_rds=$((total_rds + rds_count))

        # Count DynamoDB tables
        if [[ "${REGION}" ]]; then
            dynamodb_count=$(aws dynamodb list-tables --region $REGION --query "TableNames" --output text | wc -w)
            check_error $? "Failed to list DynamoDB tables in region $REGION for account $account_id."
        else
            dynamodb_count=$(aws dynamodb list-tables --query "TableNames" --output text | wc -w)
            check_error $? "Failed to list DynamoDB tables (all regions) for account $account_id."
        fi 
        echo "    DynamoDB tables: $dynamodb_count"
        total_dynamodb=$((total_dynamodb + dynamodb_count))

        # Count Redshift clusters
        if [[ "${REGION}" ]]; then
            redshift_count=$(aws redshift describe-clusters --region $REGION --query "Clusters[*].ClusterIdentifier" --output text | wc -w)
            check_error $? "Failed to describe Redshift clusters in region $REGION for account $account_id."
        else
            redshift_count=$(aws redshift describe-clusters --query "Clusters[*].ClusterIdentifier" --output text | wc -w)
            check_error $? "Failed to describe Redshift clusters (all regions) for account $account_id."
        fi 
        echo "    Redshift clusters: $redshift_count"
        total_redshift=$((total_redshift + redshift_count))

        paas_workloads=$[((total_rds + total_aurora + total_dynamodb + total_redshift)+2-1)/2]
        total_paas_workloads=$((total_paas_workloads + paas_workloads))
        if [[ $total_rds+$total_aurora+$total_dynamodb+$total_redshift=0 ]]; then
            paas_workloads=0
        fi
        echo "  $(tput bold)$(tput setaf 2)PaaS Workloads: $paas_workloads$(tput sgr0)"

    if [ "$ORG_MODE" == true ]; then
        clear_org_credentials
    fi
}

# Main logic
if [ "$ORG_MODE" == true ]; then
    sso_session_info=$(find_cached_sso_session "$SSO_PROFILE")
    if [ $? -ne 0 ] || [ -z "$sso_session_info" ]; then
        echo "Error: No valid cached AWS SSO login token found."
        print_sso_login_hint
        exit 1
    fi

    IFS=$'\t' read -r SSO_ACCESS_TOKEN SSO_REGION SSO_START_URL <<< "$sso_session_info"

    if [ -z "$SSO_ACCESS_TOKEN" ] || [ -z "$SSO_REGION" ]; then
        echo "Error: Cached AWS SSO login token is missing an access token or SSO region."
        print_sso_login_hint
        exit 1
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
    echo "  -- AWS WORKLOAD COUNTS --"
    echo "     VM workloads: $total_ec2_instances"
    echo "     VM (container) workloads: $total_eks_workloads"
    echo "     Serverless workloads: $total_serverless_workloads"
    echo "     S3 workloads: $total_s3_workloads"
    echo "     CaaS workloads: $total_caas_workloads"
    echo "     Container Image workloads: $total_container_image_workloads"
    echo "     PaaS workloads: $total_paas_workloads"  
    echo ""
    echo "$(tput bold)$(tput setaf 2)** SUM TOTAL AWS WORKLOADS: $((total_ec2_instances+total_eks_workloads+total_serverless_workloads+total_s3_workloads+total_caas_workloads+total_container_image_workloads+total_paas_workloads)) **$(tput sgr0)"
