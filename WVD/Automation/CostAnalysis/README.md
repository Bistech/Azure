
# Windows Virtual Desktop Cost Analysis


### Latest Release - v1.6.4

#### v1.6.4
##### New Features
###### * Bandwidth Costs - Costs will now be calculated for the VMs egress bandwidth
##### Other
###### * Increased number of metrics being written to Log Analytics
---
#### v1.5.0
##### New Features
###### * Missing Days - If any billing data is missing in Log Analytics for the last 30 days, cost analysis will be performed and missing data retrieved
---
#### v1.4.0
##### New Features
###### * Disk Costs - Costs will now be calculated for the VM managed disks. This works alongside AutoScaling where disk performance is changed on startup/shutdown of hosts in order to save costs on storage 
----
#### v1.3.3
##### New Features
###### * Reserved Instance Recommendations Cost Comparison - Added cost comparison alongside the reserved instance recommendations
##### Fixes
###### * Fixed total compute spend calculations where sometimes they wouldn't total correctly
###### * Fixed compute MeterId where it sometimes returned CLoud Services rather than Compute
##### Other
###### * Tidied logging so output is consistent
---
#### v1.2.0
##### New Features
###### * Reserved Instance Recommendations - Compute hours will be compared with reserved instances, outputting a recommended number of reserved instances to apply to enable maximum cost reduction for compute
---
#### v1.1.0
##### Fixes
###### * Fixed reserved instance cost calculations
##### Other
###### * Added fallback options for VMN cost and exchange rate
###### * Added additional error checking
---
#### v1.0.9
##### Fixes
###### * Changed Log Analytics query to warning on fail rather than error. This is expected to error on first run due to time for Log Analytics log file initial creation
---
#### v1.0.7
##### Fixes
###### * Added full error checking
---
#### v1.0.3
##### Fixes
###### * Fixed REST requests when used by Automation Account
##### Other
###### * Added additonal output
###### * Usage hours added to logging
---
#### v1.0.0
##### New Features
###### * Costs from compute 
###### * Comparison to running all hosts as reserved instances