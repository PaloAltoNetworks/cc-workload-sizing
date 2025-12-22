
## Usage
For best results, log in to the Azure Console for the tenant account with the admin/owner credentials. If an tenant account is not in use, log in to each standalone subscription account with admin/owner credentials.
   
### Prerequisites (if not using Azure CloudShell)  
* Install and configure the AZ CLI  
* Install `jq` 
    
### Execution  
1. Launch the Azure CloudShell from the top menu bar.  
3. Upload the sizing script to your CloudShell instance.  
4. `chmod +x ./cc-workload-sizing-azure.sh` to update permissions on the sizing script.  
5. Execute the script `./cc-workload-sizing-azure.sh [-r]  
   * The script by default will sum up Cloud Security resources that are counted for licensing/credit counts.  
   * Optional flags are available:  
      * `-h` display help info  
      * `-n <region>` specify single region to scan  
6. Provide the output/screenshot of the script to your Palo Alto Prisma Cloud team members.  

### What It Does
1. With no flags selected (Cloud Security mode), counts:
    * VM workloads
    * VM (container) workloads
    * Serverless workloads
    * Storage workloads
    * CaaS workloads
    * Container Image workloads
    * PaaS workloads
      
### Troubleshooting
* The error `Cannot execute: required file not found` may result when using a Windows computer to upload the shell script to Azure console, due to the manner in which Windows converts CR/LF. The below two VIM commands can be used to convert CR/LF within the AWS CLI, or alternatively, utilities such as `dos2linux` can be utilized.
   * `:e ++ff=unix`
   * `:%s/\r\(\n\)/\1/g`


