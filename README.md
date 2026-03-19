# Cortex Cloud Workload Sizing Scripts

This repository contains cloud provider-specific sizing scripts for Cortex Cloud. These scripts help determine the scale and scope of cloud resources that need to be secured, enabling accurate licensing and resource planning. Calculations used to determine workload counts are incorporated into the scripts.

## Supported Cloud Providers

- AWS
- Azure
- GCP (In Progress)
- OCI (Outstanding)
- Alibaba Cloud (Outstanding)

## Calculated Workloads
- VMs
- VMs running containers
- CaaS
- Serverless functions
- Container Images in Registries
- Cloud Buckets
- Managed Cloud Databases

## Limitations
*NOT* Calculated Workloads as no direct way to calculate from CLI (maybe solvable with entry of API key)
- DBaaS TB stored
- SaaS Users
- Cloud ASM assets
- Code repository active developers. The [RedShirts](https://github.com/bridgecrewio/redshirts) repository should be used for this calculation.

CSP Cloud Shells Timeouts (could impact very large accounts):  
- [AWS](https://docs.aws.amazon.com/cloudshell/latest/userguide/limits.html#:~:text=Inactive%20sessions%3A%20AWS%20CloudShell%20is,minutes%2C%20your%20shell%20session%20ends.) 30min  
- [Azure](https://learn.microsoft.com/en-us/azure/cloud-shell/faq-troubleshooting) 20min  
- [GCP](https://cloud.google.com/shell/docs/quotas-limits#non-interactive_usage) 40min   



## Prerequisites

- Cloud provider CLI tools must be installed and configured:
  - AWS CLI for AWS
  - Azure CLI for Azure
  - Google Cloud CLI for GCP
- Required Unix utilities:
  - jq (JSON processing)
  - grep, cut, wc, sed (text processing)
  - ps (process monitoring)
- Appropriate cloud provider permissions/roles for:
  - Organization-wide scanning
  - Cross-account access
  - Resource inspection
  - Service enablement checks

## Credential Setup

### AWS
1. AWS CloudShell Usage:
   - Navigate to AWS CloudShell in AWS Console
   - Upload script: Use CloudShell's "Actions" menu → "Upload file"
   - Make executable: `chmod +x pcs_aws_sizing.sh`
   - Run script (all prerequisites are pre-installed)
     
2. Required Permissions:
   - For standalone account:
     * ReadOnlyAccess
     * AWSSystemsManagerReadOnlyAccess (if using -c flag)
   - For organization scanning:
     * OrganizationAccountAccessRole
     * ReadOnlyAccess in member accounts
     * AWSSystemsManagerReadOnlyAccess in member accounts (if using -c flag)

### Azure
1. Azure Cloud Shell Usage:
   - Open Azure Cloud Shell in Azure Portal
   - Select Bash environment
   - Upload script: Use Cloud Shell's upload button or drag-and-drop
   - Make executable: `chmod +x pcs_azure_sizing.sh`
   - Run script (all prerequisites are pre-installed)
     
2. Required Permissions:
   - For standalone subscription:
     * Reader role
     * VM Reader role (if using -c flag)
   - For organization scanning:
     * Reader role on Management Group level
     * VM Reader role on Management Group level (if using -c flag)

### GCP
1. Google Cloud Shell Usage:
   - Open Cloud Shell in Google Cloud Console
   - Upload script: Use Cloud Shell's "Upload file" button
   - Make executable: `chmod +x pcs_gcp_sizing.sh`
   - Run script (all prerequisites are pre-installed)
     
2. Required Permissions:
   - For standalone project:
     * Viewer role
     * Compute Viewer role
     * Security Reviewer role
   - For organization scanning:
     * Organization Viewer role
     * Folder Viewer role
     * Project Viewer role
     * Compute Viewer role
     * Security Reviewer role

## Common Features

All scripts provide the following capabilities:
- Organization/tenant-wide resource scanning
- Compute resource counting (VMs, containers, etc.)
- Data resource detection (databases, storage)
- Region-specific filtering (where applicable)


## Command Line Options

All scripts support a standardized set of options:

| Option | Description |
|--------|-------------|
| -h | Display help information |
| -n | Region filter (AWS/Azure) |
| -o | Organization mode for tenant-wide scanning |
| -r | Role specification for cross-account access |

## Provider-Specific Usage

### AWS
```bash
./cc_aws_sizing.sh [-h] [-n region] [-o] [-r role]

# Examples:
# Scan entire organization
./cc_aws_sizing.sh -o

# Cross-account scan with role
./cc_aws_sizing.sh -o -r CustomerOrgCloudRole
```

### Azure
```bash
./cc_azure_sizing.sh [-h] [-n region] [-o] [-r role]

# Examples:
# Tenant-wide scan
./cc_azure_sizing.sh -o

# Region-specific scan
./cc_azure_sizing.sh -n eastus
```

### GCP
```bash
./cc_gcp_sizing.sh [-h] [-n region] [-o] [-r role]

# Examples:
# Organization scan
./cc_gcp_sizing.sh -o

# Cross-project scan with role
./cc_gcp_sizing.sh -o -r CustomerOrgCloudRole
```

## License
These scripts are proprietary to Cortex Cloud and should be used in accordance with your licensing agreement.
