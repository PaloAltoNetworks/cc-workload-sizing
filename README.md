# Prisma Cloud Sizing Scripts

This repository contains cloud provider-specific sizing scripts for Prisma Cloud. These scripts help determine the scale and scope of cloud resources that need to be secured, enabling accurate licensing and resource planning.

## Supported Cloud Providers

- AWS
- Azure
- GCP
- OCI (Outstanding)
- Alibaba Cloud (Outstanding)

## Prerequisites

- Cloud provider CLI tools must be installed and configured:
  - AWS CLI for AWS
  - Azure CLI for Azure
  - Google Cloud CLI for GCP
- Required Unix utilities:
  - jq (JSON processing)
  - grep, cut, wc, sed (text processing)
  - ps (process monitoring)
  - date (performance timing)
  - timeout (operation limits)
  - mktemp (secure temporary files)
- Appropriate cloud provider permissions/roles for:
  - Organization-wide scanning
  - Cross-account access
  - Resource inspection
  - Service enablement checks

## Credential Setup

### AWS
1. Console Setup:
   ```bash
   aws configure
   # Enter your AWS Access Key ID
   # Enter your AWS Secret Access Key
   # Enter your default region
   # Enter your preferred output format (json recommended)
   ```

2. Required Permissions:
   - For standalone account:
     * ReadOnlyAccess
     * AWSSystemsManagerReadOnlyAccess (if using -c flag)
   - For organization scanning:
     * OrganizationAccountAccessRole
     * ReadOnlyAccess in member accounts
     * AWSSystemsManagerReadOnlyAccess in member accounts (if using -c flag)

3. AWS CloudShell Usage:
   - Navigate to AWS CloudShell in AWS Console
   - Upload script: Use CloudShell's "Actions" menu → "Upload file"
   - Make executable: `chmod +x pcs_aws_sizing.sh`
   - Run script (all prerequisites are pre-installed)

### Azure
1. Console Setup:
   ```bash
   az login
   # Follow the browser prompt to authenticate
   
   # For organization scanning:
   az account list
   az account set --subscription "Subscription Name"
   ```

2. Required Permissions:
   - For standalone subscription:
     * Reader role
     * VM Reader role (if using -c flag)
   - For organization scanning:
     * Reader role on Management Group level
     * VM Reader role on Management Group level (if using -c flag)

3. Azure Cloud Shell Usage:
   - Open Azure Cloud Shell in Azure Portal
   - Select Bash environment
   - Upload script: Use Cloud Shell's upload button or drag-and-drop
   - Make executable: `chmod +x pcs_azure_sizing.sh`
   - Run script (all prerequisites are pre-installed)

### GCP
1. Console Setup:
   ```bash
   gcloud auth login
   # Follow the browser prompt to authenticate
   
   # For organization scanning:
   gcloud organizations list
   gcloud config set organization <org-id>
   ```

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

3. Google Cloud Shell Usage:
   - Open Cloud Shell in Google Cloud Console
   - Upload script: Use Cloud Shell's "Upload file" button
   - Make executable: `chmod +x pcs_gcp_sizing.sh`
   - Run script (all prerequisites are pre-installed)

## Common Features

All scripts provide the following capabilities:
- Organization/tenant-wide resource scanning
- Compute resource counting (VMs, containers, etc.)
- Data resource detection (databases, storage)
- Region-specific filtering (where applicable)
- Direct instance/VM inspection
- Service availability verification
- Performance monitoring and metrics

## Command Line Options

All scripts support a standardized set of options:

| Option | Description |
|--------|-------------|
| -c | Connect mode for direct database inspection |
| ~~-d~~ | ~~DSPM (Data Security Posture Management) mode~~ |
| -h | Display help information |
| -n | Region filter (AWS/Azure) |
| -o | Organization mode for tenant-wide scanning |
| -r | Role specification for cross-account access |
| -s | Include stopped/terminated instances |

## Provider-Specific Usage

### AWS
```bash
./pcs_aws_sizing.sh [-c] [-d] [-h] [-n region] [-o] [-r role] [-s]

# Examples:
# Scan entire organization
./pcs_aws_sizing.sh -o

# Scan specific region with DSPM
./pcs_aws_sizing.sh -n us-east-1 -d

# Cross-account scan with role
./pcs_aws_sizing.sh -o -r PrismaCloudRole
```

### Azure
```bash
./pcs_azure_sizing.sh [-c] [-d] [-h] [-n region] [-o] [-r role] [-s]

# Examples:
# Tenant-wide scan
./pcs_azure_sizing.sh -o

# Region-specific DSPM scan
./pcs_azure_sizing.sh -n eastus -d

# Include stopped VMs
./pcs_azure_sizing.sh -o -s
```

### GCP
```bash
./pcs_gcp_sizing.sh [-c] [-d] [-h] [-o] [-r role] [-s]

# Examples:
# Organization scan
./pcs_gcp_sizing.sh -o

# DSPM mode with stopped instances
./pcs_gcp_sizing.sh -d -s

# Cross-project scan with role
./pcs_gcp_sizing.sh -o -r PrismaCloudRole
```

## Resource Detection

The scripts perform comprehensive resource detection including:

- Compute Resources:
  - Virtual Machines/Instances
  - Container Instances
  - Serverless Functions
  - Managed Services

- Data Resources:
  - Databases (including port scanning)
  - Storage Services
  - Data Warehouses
  - Caching Services

## Performance Considerations

The scripts include built-in performance monitoring:
- Execution time tracking
- Memory usage monitoring
- API call counting
- Resource usage statistics
- Rate limit tracking

For large environments:
- Use region filtering when possible
- Consider running in segments
- Monitor API rate limits
- Be aware of memory usage with large resource sets
- Observe concurrent operation limits

## Output Format

Scripts provide standardized output including:
- Resource counts by type
- Database detection results
- Service availability status
- Performance metrics
- Error reporting and status messages
- Rate limit statistics

## Error Handling

Scripts include comprehensive error handling for:
- API failures with retries
- Permission issues
- Resource access problems
- Rate limiting
- Service availability
- Timeout management
- Resource cleanup
- Session management

## Support

For issues or questions, please refer to:
- Provider-specific README files in each directory
- Testing documentation for validation procedures
- Performance monitoring documentation for optimization
- Error handling documentation for troubleshooting

## License

These scripts are proprietary to Prisma Cloud and should be used in accordance with your licensing agreement.
