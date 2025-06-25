
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
      * `-c` Connect via SSM to EC2 instances running DBs in combination with DSPM mode  
      * ~~`-d` enable DSPM mode and count up resources for DSPM licensing/credit counts. This option can be used alone or in combination with `-o`~~  
      * `-h` display help info  
      * `-n <region>` specify single region to scan  
      * `-o` enable organization mode and loop through each organization sub-account and sum up totals  
      * `-r <role>` specify a non-default role to assume in Organization mode  
      * `-s` include stopped instances in addition to running instances  
6. Provide the output/screenshot of the script to your Palo Alto Prisma Cloud team members.  

### What It Does
1. In Organization mode, the script uses `aws organizations list-accounts` to retrieve all accounts in the organization.  
1. Assumes a cross-account role (e.g., OrganizationAccountAccessRole) to access each sub-account. This role is [created automatically](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_accounts_create-cross-account-role.html) for sub-accounts created within an organization.  Should your AWS environment not be configured in this manner, you can optionally specify an alternate role name that contains the same permissions via the `-r` flag (see help).
Alternatively, you can create the OrganizationAccountAccessRole and add the role to each subaccount, as indicated in [AWS documentation](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_accounts_create-cross-account-role.html).
1. With no flags selected (Cloud Security mode), counts:
    * VM workloads instances using `aws ec2 describe-instances`.
    * VM (Container) workloads / EKS nodes by listing clusters and their node groups with `aws eks describe-nodegroup`.  
    * Serverless workloads (active and inactive)  
    * Container workloads  
    * Container Image workloads in registries  
    * S3 instances using `aws s3api list-buckets`
    * EFS instances using `aws efs describe-file-systems`
    * PaaS Workloads
      * Aurura clusters using `aws rds describe-db-clusters` and filtering on aurura engine
      * RDS instances using `aws rds describe-db-instances` and filtering on mysql, mariadb, and postgres engines
      * DynamoDB tables using `aws dynamodb list-tables`
      * Redshift clusters using `aws redshift describe-clusters`
      
### Troubleshooting
* The error `Cannot execute: required file not found` may result when using a Windows computer to upload the shell script to AWS console, due to the manner in which Windows converts CR/LF. The below two VIM commands can be used to convert CR/LF within the AWS CLI, or alternatively, utilities such as `dos2linux` can be utilized.
   * `:e ++ff=unix`
   * `:%s/\r\(\n\)/\1/g`
 
## TO DO
*  Validate filter to only count compute instances that are active/running
*  Find method to examine EC2 DB size allocation if unable to connect via SSM
   *  Add method to count/display DB size allocation if able to connect via SSM
*  Add additional DSPM services (DBaaS, xxx, xxx)
