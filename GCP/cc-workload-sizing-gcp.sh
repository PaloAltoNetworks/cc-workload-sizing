#!/bin/bash

# Script to fetch GCP inventory for Prisma Cloud sizing.
# This script is adapted from an Azure script to work with Google Cloud Platform.

# Check for jq dependency
if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed. Please install jq to run this script."
    echo "(e.g., 'sudo apt-get install jq' or 'sudo yum install jq' or 'brew install jq')"
    exit 1
fi

# Check for gcloud dependency
if ! command -v gcloud &> /dev/null; then
    echo "Error: gcloud CLI is not installed. Please install Google Cloud SDK."
    echo "(See: https://cloud.google.com/sdk/docs/install)"
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
    echo "* Requires gcloud CLI to execute"
    echo "* Requires JQ utility to be installed"
    echo "* Requires Cloud Asset Inventory API enabled for the organization or projects."
    echo "  (Enable with: gcloud services enable cloudasset.googleapis.com)"
    echo "* Requires appropriate permissions (e.g., roles/cloudasset.viewer at organization level,"
    echo "  or viewer roles for specific resource types at project level)."
    echo ""
    echo "Usage: $0 [-h] [-o <organization-id>] [-l <location>]"
    echo ""
    echo "Available flags:"
    echo " -h       Display this help info"
    echo " -o <id>  Optional: Specify a single Organization ID to scan. If not provided,"
    echo "          the script will attempt to list and scan all organizations you have access to."
    echo " -l <loc> Optional: Filter resources by a specific GCP location (e.g., us-central1)."
    echo "          Note: Not all resource types support location filtering in asset searches."
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

# Ensure gcloud CLI is authenticated
gcloud auth list --filter=status:ACTIVE --format="value(account)" > /dev/null 2>&1
check_error $? "gcloud CLI not authenticated. Please run 'gcloud auth login'."

# Initialize options
SPECIFIC_ORG_ID=""
LOCATION=""

# Get options
while getopts ":ho:l:" opt; do
  case ${opt} in
    h) printHelp ;;
    o) SPECIFIC_ORG_ID="$OPTARG" ;;
    l) LOCATION="$OPTARG" ;;
    *) echo "Invalid option: -${OPTARG}" && printHelp exit ;;
  esac
done
shift $((OPTIND-1))

# Global sum for all workloads across all organizations and projects
sum_total_gcp_workloads=0

# --- Function to count resources within a single GCP Project ---
# This function takes the project ID as an argument.
# It accumulates workload counts for the current project and adds to global total.
function count_gcp_resources_in_project {
    local project_id=$1
    local location_filter=""

    if [[ -n "$LOCATION" ]]; then
        location_filter="location==\"$LOCATION\""
        echo "  Applying location filter: $LOCATION"
    fi

    echo "  $(tput bold)$(tput setaf 6)Counting Workloads for Project: $project_id$(tput sgr0)"

    # Initialize counters for the current project
    local total_vm_instances_proj=0
    local total_gke_nodes_proj=0
    local total_serverless_workloads_proj=0
    local total_caas_workloads_proj=0
    local total_container_image_workloads_proj=0
    local total_storage_workloads_proj=0
    local total_paas_workloads_proj=0

    # Temporarily set gcloud project context for project-specific commands
    # This is crucial for commands that don't support --project flag or work better in context
    local original_project=$(gcloud config get-value project 2>/dev/null)
    gcloud config set project "$project_id" --quiet > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "    WARNING: Could not set gcloud project to '$project_id'. Skipping project-specific resource counts."
        # Restore original project context
        if [[ -n "$original_project" ]]; then
            gcloud config set project "$original_project" --quiet > /dev/null 2>&1
        fi
        return 1
    fi

    # 1. Count Compute Engine instances
    echo "    Counting Compute Engine instances..."
    local instance_list=""
    if [[ -n "$LOCATION" ]]; then
        instance_list=$(gcloud compute instances list --filter="zone ~ ^$LOCATION.*" --project "$project_id" --format='value(name)' --quiet 2>/dev/null)
    else
        instance_list=$(gcloud compute instances list --project "$project_id" --format='value(name)' --quiet 2>/dev/null)
    fi

    if [ -n "$instance_list" ]; then
        total_vm_instances_proj=$(echo "$instance_list" | wc -l)
    else
        total_vm_instances_proj=0
    fi
    echo "    $(tput bold)$(tput setaf 2)VM Workloads (Compute Engine instances): $total_vm_instances_proj$(tput sgr0)"

    # 2. Count GKE nodes
    echo "    Counting GKE nodes..."
    local gke_node_count=0
    local cluster_list=""
    if [[ -n "$LOCATION" ]]; then
        cluster_list=$(gcloud container clusters list --project "$project_id" --filter="location ~ ^$LOCATION" --format='value(name,location)' --quiet 2>/dev/null)
    else
        cluster_list=$(gcloud container clusters list --project "$project_id" --format='value(name,location)' --quiet 2>/dev/null)
    fi

    if [ -z "$cluster_list" ]; then
        echo "      No GKE clusters found in project $project_id."
    else
        # Use process substitution for this inner loop as well
        while IFS=$'\t' read -r cluster_name cluster_location; do
            echo "      Describing cluster '$cluster_name' in location '$cluster_location'..."
            # Attempt to get node count, default to 0 on error
            local node_count=$(gcloud container clusters describe "$cluster_name" --location "$cluster_location" --format="value(currentNodeCount)" --quiet --project "$project_id" 2>/dev/null)
            if [ $? -ne 0 ] || ! [[ "$node_count" =~ ^[0-9]+$ ]]; then
                echo "        Warning: Failed to get node count for cluster '$cluster_name'. Assuming 0 nodes."
                node_count=0
            fi
            echo "        Cluster '$cluster_name' has $node_count nodes."
            gke_node_count=$((gke_node_count + node_count))
        done < <(echo "$cluster_list") # Fix: Process substitution
    fi
    total_gke_nodes_proj=$gke_node_count
    echo "    $(tput bold)$(tput setaf 2)VM (Container) Workloads (GKE nodes): $total_gke_nodes_proj$(tput sgr0)"

    # 3. Count Serverless workloads (Cloud Functions, Cloud Run, App Engine)
    echo "    Counting Serverless workloads (Cloud Functions, Cloud Run, App Engine)..."
    local functions_count=0
    local cloud_run_count=0
    local app_engine_services_count=0

    if [[ -n "$LOCATION" ]]; then
        functions_count=$(gcloud functions list --project "$project_id" --filter="region ~ ^$LOCATION.*" --format='value(name)' --quiet 2>/dev/null | wc -l)
        cloud_run_count=$(gcloud run services list --project "$project_id" --region "$LOCATION" --format='value(metadata.name)' --quiet 2>/dev/null | wc -l)
        # App Engine location filtering is complex, doing general list for now
        app_engine_services_count=$(gcloud app services list --project "$project_id" --format='value(id)' --quiet 2>/dev/null | wc -l)
    else
        functions_count=$(gcloud functions list --project "$project_id" --format='value(name)' --quiet 2>/dev/null | wc -l)
        cloud_run_count=$(gcloud run services list --project "$project_id" --format='value(metadata.name)' --quiet 2>/dev/null | wc -l)
        app_engine_services_count=$(gcloud app services list --project "$project_id" --format='value(id)' --quiet 2>/dev/null | wc -l)
    fi

    local total_serverless_raw=$((functions_count + cloud_run_count + app_engine_services_count))
    serverless_workloads=$(( (total_serverless_raw + 25 - 1) / 25 )) # Ratio: 25 items per workload unit
    if (( total_serverless_raw == 0 )); then
        serverless_workloads=0
    fi
    total_serverless_workloads_proj=$serverless_workloads
    echo "    $(tput bold)$(tput setaf 2)Serverless Workloads (Functions: $functions_count, Cloud Run: $cloud_run_count, App Engine: $app_engine_services_count): $total_serverless_workloads_proj$(tput sgr0)"

    # 4. Count CaaS workloads (Cloud Run already covered, if other specific CaaS, add here)
    # Cloud Run is already counted under serverless, so for CaaS we can just re-use that number
    # or add other specific CaaS types if defined in future.
    total_caas_workloads_proj=$total_serverless_workloads_proj # As Cloud Run is our primary CaaS metric here.
    echo "    $(tput bold)$(tput setaf 2)CaaS Workloads (re-using Serverless count for Cloud Run): $total_caas_workloads_proj$(tput sgr0)"


    # 5. Count Container Images (Artifact Registry & Container Registry)
    echo "    Counting Container Images (Artifact Registry & Container Registry)..."
    local total_images_acr=0

    # Artifact Registry
    local ar_repos=""
    if [[ -n "$LOCATION" ]]; then
        ar_repos=$(gcloud artifacts repositories list --project "$project_id" --filter="location ~ ^$LOCATION.*" --format='value(name,location)' --quiet 2>/dev/null)
    else
        ar_repos=$(gcloud artifacts repositories list --project "$project_id" --format='value(name,location)' --quiet 2>/dev/null)
    fi

    if [ -n "$ar_repos" ]; then
        # Use process substitution for this inner loop as well
        while IFS=$'\t' read -r repo_name repo_location; do
            echo "      Checking Artifact Registry: $repo_name (location: $repo_location)"
            local image_count=$(gcloud artifacts docker images list "$repo_location-docker.pkg.dev/$project_id/$repo_name" --include-tags --format='value(DIGEST)' --quiet 2>/dev/null | wc -l)
            # Fallback for other formats if docker images list doesn't work or for generic files
            if [[ "$image_count" -eq 0 ]]; then
                image_count=$(gcloud artifacts files list --repository="$repo_name" --project "$project_id" --location="$repo_location" --format='value(size)' --quiet 2>/dev/null | wc -l)
            fi

            if [[ "$image_count" -gt 0 ]]; then
                total_images_acr=$((total_images_acr + image_count))
                echo "        Found $image_count images/files in $repo_name."
            fi
        done < <(echo "$ar_repos") # Fix: Process substitution
    fi

    # Container Registry (legacy) - only if Artifact Registry didn't cover it or explicitly needed
    # Note: Container Registry is deprecated in favor of Artifact Registry.
    local cr_images=$(gcloud container images list --project "$project_id" --format='value(name)' --quiet 2>/dev/null)
    if [ -n "$cr_images" ]; then
        # Use process substitution for this inner loop as well
        while IFS= read -r image_name; do
            local tags_count=$(gcloud container images list-tags "$image_name" --format='value(digest)' --quiet 2>/dev/null | wc -l)
            total_images_acr=$((total_images_acr + tags_count))
            echo "        Found $tags_count tags for $image_name in Container Registry."
        done < <(echo "$cr_images") # Fix: Process substitution
    fi

    total_container_image_workloads_proj=$total_images_acr # Each image/tag counted as a workload unit
    echo "    $(tput bold)$(tput setaf 2)Container Image Workloads: $total_container_image_workloads_proj$(tput sgr0)"

    # 6. Count Storage Workloads (Cloud Storage buckets)
    echo "    Counting Storage Workloads (Cloud Storage buckets)..."
    local bucket_count=0
    # Using asset search for organization scope is better, but here limiting to project
    bucket_count=$(gcloud storage ls --project "$project_id" --recursive --format='value(NAME)' 2>/dev/null | grep -c 'gs://')
    # A more robust way for project: gcloud asset search-all-resources --project "$project_id" --asset-types='storage.googleapis.com/Bucket'
    # The 'gs://' grep might be slow for many files. wc -l is for top-level buckets
    if [[ -n "$LOCATION" ]]; then
      # Need to filter buckets by location, which `gcloud storage ls` doesn't do directly by flag.
      # Requires parsing `gcloud storage buckets describe` output for each bucket.
      # For simplicity, if location is given, we might need to skip strict bucket location filtering here or note its limitation.
      # For now, we'll assume `gcloud storage ls` is sufficient to get a project-level count,
      # but acknowledge that direct location filtering is not trivial without iterating/describing each bucket.
      echo "      Note: Direct bucket location filtering for count is complex with 'gcloud storage ls'."
      echo "      Counting all buckets in project, location filter might not be fully applied for buckets."
    fi
    
    local storage_workloads_raw=$bucket_count
    total_storage_workloads_proj=$(( (storage_workloads_raw + 10 - 1) / 10 )) # Ratio: 10 buckets per workload unit
    if (( storage_workloads_raw == 0 )); then
        total_storage_workloads_proj=0
    fi
    echo "    $(tput bold)$(tput setaf 2)Storage Workloads (Buckets: $storage_workloads_raw): $total_storage_workloads_proj$(tput sgr0)"

    # 7. Count PaaS Workloads (Cloud SQL, Cloud Spanner, Firestore, Memorystore, BigQuery, Pub/Sub)
    echo "    Counting PaaS workloads (Cloud SQL, Spanner, Firestore, Memorystore, BigQuery, Pub/Sub)..."
    local sql_instance_count=0
    local spanner_instance_count=0
    local firestore_database_count=0
    local redis_instance_count=0
    local memcache_instance_count=0
    local bigquery_dataset_count=0
    local pubsub_topic_count=0
    local pubsub_subscription_count=0

    if [[ -n "$LOCATION" ]]; then
        sql_instance_count=$(gcloud sql instances list --project "$project_id" --filter="region ~ ^$LOCATION.*" --format='value(name)' --quiet 2>/dev/null | wc -l)
        spanner_instance_count=$(gcloud spanner instances list --project "$project_id" --filter="config.name ~ ^projects/.*/instanceConfigs/$LOCATION.*" --format='value(name)' --quiet 2>/dev/null | wc -l)
        # Firestore is global for default, other locations might be hard to filter. Count projects with firestore.
        # This will be more accurate with asset inventory if location is critical.
        # For simplicity, assume list counts existing for given project.
        firestore_database_count=$(gcloud firestore databases list --project "$project_id" --format='value(name)' --quiet 2>/dev/null | wc -l)
        redis_instance_count=$(gcloud redis instances list --project "$project_id" --filter="location ~ ^$LOCATION.*" --format='value(name)' --quiet 2>/dev/null | wc -l)
        memcache_instance_count=$(gcloud memcache instances list --project "$project_id" --filter="zones ~ ^$LOCATION.*" --format='value(name)' --quiet 2>/dev/null | wc -l)
        # BigQuery datasets are per-project, then location filter might be needed.
        bigquery_dataset_count=$(bq --project_id "$project_id" ls --datasets --format=json 2>/dev/null | jq ".[] | select(.location | ascii_downcase | contains(\"$LOCATION\"))" | wc -l)
        pubsub_topic_count=$(gcloud pubsub topics list --project "$project_id" --filter="name ~ ^projects/.*/topics/.*/locations/$LOCATION.*" --format='value(name)' --quiet 2>/dev/null | wc -l)
        pubsub_subscription_count=$(gcloud pubsub subscriptions list --project "$project_id" --filter="name ~ ^projects/.*/subscriptions/.*/locations/$LOCATION.*" --format='value(name)' --quiet 2>/dev/null | wc -l)

    else
        sql_instance_count=$(gcloud sql instances list --project "$project_id" --format='value(name)' --quiet 2>/dev/null | wc -l)
        spanner_instance_count=$(gcloud spanner instances list --project "$project_id" --format='value(name)' --quiet 2>/dev/null | wc -l)
        firestore_database_count=$(gcloud firestore databases list --project "$project_id" --format='value(name)' --quiet 2>/dev/null | wc -l)
        redis_instance_count=$(gcloud redis instances list --project "$project_id" --format='value(name)' --quiet 2>/dev/null | wc -l)
        memcache_instance_count=$(gcloud memcache instances list --project "$project_id" --format='value(name)' --quiet 2>/dev/null | wc -l)
        bigquery_dataset_count=$(bq --project_id "$project_id" ls --datasets --format=json 2>/dev/null | jq '.[].id' | wc -l)
        pubsub_topic_count=$(gcloud pubsub topics list --project "$project_id" --format='value(name)' --quiet 2>/dev/null | wc -l)
        pubsub_subscription_count=$(gcloud pubsub subscriptions list --project "$project_id" --format='value(name)' --quiet 2>/dev/null | wc -l)
    fi

    echo "      Cloud SQL Instances: $sql_instance_count"
    echo "      Cloud Spanner Instances: $spanner_instance_count"
    echo "      Firestore Databases: $firestore_database_count"
    echo "      Memorystore (Redis): $redis_instance_count"
    echo "      Memorystore (Memcached): $memcache_instance_count"
    echo "      BigQuery Datasets: $bigquery_dataset_count"
    echo "      Pub/Sub Topics: $pubsub_topic_count"
    echo "      Pub/Sub Subscriptions: $pubsub_subscription_count"

    local total_paas_raw=$((sql_instance_count + spanner_instance_count + firestore_database_count + redis_instance_count + memcache_instance_count + bigquery_dataset_count + pubsub_topic_count + pubsub_subscription_count))
    paas_workloads=$(( (total_paas_raw + 2 - 1) / 2 )) # Ratio: 2 instances per workload unit
    if (( total_paas_raw == 0 )); then
        paas_workloads=0
    fi
    total_paas_workloads_proj=$paas_workloads
    echo "    $(tput bold)$(tput setaf 2)PaaS Workloads: $total_paas_workloads_proj$(tput sgr0)"
    echo ""

    # Accumulate project totals for this project
    local current_proj_total=$((total_vm_instances_proj + total_gke_nodes_proj + total_serverless_workloads_proj + total_storage_workloads_proj + total_caas_workloads_proj + total_container_image_workloads_proj + total_paas_workloads_proj))
    echo "    $(tput bold)$(tput setaf 6)SUMMARY WORKLOADS FOR PROJECT: $project_id: $current_proj_total$(tput sgr0)"
    echo "----------------------------------------------------------------------"

    # Add to global sum
    sum_total_gcp_workloads=$((sum_total_gcp_workloads + current_proj_total))

    # Restore original project context
    if [[ -n "$original_project" ]]; then
        gcloud config set project "$original_project" --quiet > /dev/null 2>&1
    fi
    return 0 # Indicate success for this project
}

# --- Main Logic for Organizations and Projects ---
organizations=""
if [[ -n "$SPECIFIC_ORG_ID" ]]; then
    # If a specific organization ID is provided, use it directly
    # Validate the provided ID first
    local org_name=$(gcloud organizations describe "$SPECIFIC_ORG_ID" --format="value(displayName)" 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$org_name" ]; then
        echo "Error: Organization ID '$SPECIFIC_ORG_ID' is invalid or not accessible. Please check the ID and your permissions."
        exit 1
    fi
    organizations=$(jq -n --arg id "$SPECIFIC_ORG_ID" --arg name "$org_name" '[{"id": $id, "name": $name}]')
else
    # Attempt to list all organizations the user has access to
    echo "Attempting to list all accessible organizations..."
    organizations=$(gcloud organizations list --format="json" 2>/dev/null)
    check_error $? "Failed to list organizations. Ensure you have 'resourcemanager.organizations.list' permission."

    if [ -z "$organizations" ] || [ "$organizations" == "[]" ]; then
        echo "No accessible GCP organizations found. Please ensure your account has the necessary permissions."
        exit 0
    fi
fi

# Loop through each organization using process substitution
while read -r org_data; do # Fix: Outer loop now uses process substitution
    org_id=$(echo "$org_data" | jq -r '.id')
    org_name=$(echo "$org_data" | jq -r '.name')

    echo "$(tput bold)$(tput setaf 3)--- Processing Organization: $org_name (ID: $org_id) ---$(tput sgr0)"

    # List projects under the current organization
    echo "  Listing projects under organization $org_id..."
    # Reverting this line to correctly filter projects by organization ID
    projects=$(gcloud projects list --organization "$org_id" --format="json" --quiet 2>/dev/null)
    projects=$(gcloud projects list --format="json" --quiet 2>/dev/null)
    check_error $? "    Failed to list projects for organization '$org_id'. Ensure 'resourcemanager.projects.list' permission."

    if [ -z "$projects" ] || [ "$projects" == "[]" ]; then
        echo "    No projects found in organization '$org_id' or no access. Skipping."
        echo "$(tput bold)$(tput setaf 3)--- Finished Organization: $org_name (ID: $org_id) ---$(tput sgr0)"
        echo ""
        continue
    fi

    # Loop through each project in the current organization (using process substitution)
    while read -r project_data; do
        project_id=$(echo "$project_data" | jq -r '.projectId')
        project_name=$(echo "$project_data" | jq -r '.name')
        
        echo "$(tput bold)$(tput setaf 5)--- Entering Project: $project_name (ID: $project_id) ---$(tput sgr0)"
        count_gcp_resources_in_project "$project_id"
        echo "$(tput bold)$(tput setaf 5)--- Exiting Project: $project_name (ID: $project_id) ---$(tput sgr0)"
        echo ""
    done < <(echo "$projects" | jq -c '.[]') # Fix: Process substitution for inner loop

    echo "$(tput bold)$(tput setaf 3)--- Finished Organization: $org_name (ID: $org_id) ---$(tput sgr0)"
    echo ""
done < <(echo "$organizations" | jq -c '.[]') # Fix: Process substitution for outer loop

echo "##########################################"
echo "$(tput bold)$(tput setaf 6)** GCP INVENTORY COLLECTION COMPLETE **$(tput sgr0)"
echo "$(tput bold)$(tput setaf 6)Total Workloads across all accessible Organizations and Projects: $sum_total_gcp_workloads$(tput sgr0)"
echo "##########################################"
