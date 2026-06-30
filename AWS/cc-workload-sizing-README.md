
## Usage
For best results, log in with AWS CLI v2 using AWS IAM Identity Center (SSO) and an SSO assignment that can access the target accounts with the `AWSReadOnlyAccess` permission set. If an organization account is not in use, log in to each standalone account with admin/owner credentials.
   
### Prerequisites (if not using AWS CloudShell)  
* Install and configure the AWS CLI v2  
* Install `jq` 
* For organization mode, run `aws sso login --profile <your-sso-profile>` before executing the script
    
### Execution  
1. Launch the AWS CloudShell from the top menu bar.  
3. Upload the sizing script to your CloudShell instance.  
4. `chmod +x ./cc-workload-sizing-aws.sh` to update permissions on the sizing script.  
5. Execute the script `./cc-workload-sizing-aws.sh [-o|-p|-r|-R]`
   * The script by default will sum up Cloud Security resources that are counted for licensing/credit counts.  
   * Optional flags are available:  
      * `-h` display help info  
      * `-n <region>` specify single region to scan  
      * `-R <regions>` specify a comma-separated region list to scan and skip AWS region discovery
      * `-o` enable organization mode and loop through each SSO-assigned account and sum up totals
      * `-p <profile>` specify the source AWS SSO profile/session used to locate the cached login token
      * `-r <role>` specify a non-default SSO role/permission set in Organization mode
6. Provide the output/screenshot of the script to your Palo Alto Prisma Cloud team members.  

### What It Does
1. In Organization mode, the script uses your cached AWS SSO login token to call `aws sso list-accounts` and retrieve the accounts assigned to you.
1. Requests direct AWS Identity Center credentials for each account using the `AWSReadOnlyAccess` role/permission set by default. Should your AWS environment use a different permission set name, specify it via the `-r` flag (see help).
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
