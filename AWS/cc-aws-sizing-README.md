
## Usage
For best results, log in to the AWS Console for the master organization account with the admin/owner credentials. If an organization account is not in use, log in to each standalone account with admin/owner credentials.
   
### Prerequisites (if not using AWS CloudShell)  
* Install and configure the AWS CLI v2  
* Install `jq` 
    
### Execution  
1. Launch the AWS CloudShell from the top menu bar.  
3. Upload the sizing script to your CloudShell instance.  
4. `chmod +x ./pcs_aws_sizing.sh` to update permissions on the sizing script.  
5. Execute the script `./pcs_aws_sizing.sh [-o|-r]  
   * The script by default will sum up Cloud Security resources that are counted for licensing/credit counts.  
   * Optional flags are available:  
      * `-h` display help info  
      * `-n <region>` specify single region to scan  
      * `-o` enable organization mode and loop through each organization sub-account and sum up totals  
      * `-r <role>` specify a non-default role to assume in Organization mode  
6. Provide the output/screenshot of the script to your Palo Alto Prisma Cloud team members.  

### What It Does
1. In Organization mode, the script uses `aws organizations list-accounts` to retrieve all accounts in the organization.  
1. Assumes a cross-account role (e.g., OrganizationAccountAccessRole) to access each sub-account. This role is [created automatically](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_accounts_create-cross-account-role.html) for sub-accounts created within an organization.  Should your AWS environment not be configured in this manner, you can optionally specify an alternate role name that contains the same permissions via the `-r` flag (see help).
Alternatively, you can create the OrganizationAccountAccessRole and add the role to each subaccount, as indicated in [AWS documentation](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_accounts_create-cross-account-role.html).
1. With no flags selected (Cloud Security mode), counts:
    * VM workloads
    * VM (container) workloads
    * Serverless workloads
    * S3 workloads
    * CaaS workloads
    * Container Image workloads
    * PaaS workloads
      
### Troubleshooting
* The error `Cannot execute: required file not found` may result when using a Windows computer to upload the shell script to AWS console, due to the manner in which Windows converts CR/LF. The below two VIM commands can be used to convert CR/LF within the AWS CLI, or alternatively, utilities such as `dos2linux` can be utilized.
   * `:e ++ff=unix`
   * `:%s/\r\(\n\)/\1/g`

