<# 
.SYNOPSIS
    This script calculates WVD cost savings for a hostpool from using Bistech Automation 

.DESCRIPTION
    This script will gather billing information for the VM's within a hostpool (resource group) and calculate the customer cost savings achieved by using Bistech's
    Automation product. It will also compare using automation to reserved instances so you can track if moving to reserved instances would be more cost effective based
    on the customers usage hours.

.NOTES
    Author  : Dave Pierson
    Version : 1.0.9

    # THIS SOFTWARE IS PROVIDED "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, 
    # INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY 
    # AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL 
    # THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, 
    # INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT 
    # NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, 
    # DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY 
    # THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT 
    # (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE 
    # OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#>

param(
    [Parameter(mandatory = $false)]
    [object]$webHookData
)
# If the runbook was called from a Webhook, the WebhookData will not be null.
if ($webHookData) {

    # Collect properties of WebhookData
    $webHookName = $webHookData.WebhookName
    $webHookHeaders = $webHookData.RequestHeader
    $webHookBody = $webHookData.RequestBody

    # Collect individual headers. Input converted from JSON.
    $from = $webHookHeaders.From
    $input = (ConvertFrom-Json -InputObject $webHookBody)
}
else {
    Write-Error -Message "Runbook was not started from it's Webhook so the script was terminated" -ErrorAction Stop
}

# Set variables from WebHook body objects
$aadTenantId = $Input.AADTenantId
$subscriptionID = $Input.SubscriptionID
$resourceGroupName = $Input.ResourceGroupName
$logAnalyticsWorkspaceId = $Input.LogAnalyticsWorkspaceId
$logAnalyticsPrimaryKey = $Input.LogAnalyticsPrimaryKey
$connectionAssetName = $Input.ConnectionAssetName
$hostpoolName = $Input.HostPoolName

Set-ExecutionPolicy -ExecutionPolicy Undefined -Scope Process -Force -Confirm:$false
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope LocalMachine -Force -Confirm:$false

# Set ErrorActionPreference to stop script execution when error occurs
$ErrorActionPreference = "Stop"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Function to add logs to Log Analytics Workspace
function Add-LogEntry {
    param(
        [Object]$logMessageObj,
        [string]$logAnalyticsWorkspaceId,
        [string]$logAnalyticsPrimaryKey,
        [string]$logType
    )
  
    foreach ($key in $logMessage.Keys) {
        switch ($key.substring($key.Length - 2)) {
            '_s' { $sep = '"'; $trim = $key.Length - 2 }
            '_t' { $sep = '"'; $trim = $key.Length - 2 }
            '_b' { $sep = ''; $trim = $key.Length - 2 }
            '_d' { $sep = ''; $trim = $key.Length - 2 }
            '_g' { $sep = '"'; $trim = $key.Length - 2 }
            default { $sep = '"'; $trim = $key.Length }
        }
        $logData = $logData + '"' + $key.substring(0, $trim) + '":' + $sep + $logMessageObj.Item($key) + $sep + ','
    }
  
    $json = "{$($logData)}"
    $postResult = Send-OMSAPIIngestionFile -CustomerId $logAnalyticsWorkspaceId -SharedKey $logAnalyticsPrimaryKey -Body "$json" -LogType $logType
      
    if ($postResult -ne "Accepted") {
        Write-Error "Error when posting data to Log Analytics - $postResult"
    }
}
  
# Retrieve the RunAs account credentials from the Azure Automation Account Assets
$connection = Get-AutomationConnection -Name $ConnectionAssetName
  
# Authenticate to Azure 
Clear-AzContext -Force
$azAuthentication = Connect-AzAccount -ApplicationId $connection.ApplicationId -TenantId $aadTenantId -CertificateThumbprint $connection.CertificateThumbprint -ServicePrincipal
if ($azAuthentication -eq $null) {
    Write-Error "Failed to authenticate to Azure using the Automation Account $($_.exception.message)"
} 
else {
    Write-Output "Successfully authenticated to Azure using the Automation Account"
}
  
# Set the Azure context with Subscription
$azContext = Set-AzContext -SubscriptionId $subscriptionID
if ($azContext -eq $null) {
    Write-Error "Subscription ID '$subscriptionID' does not exist. Ensure that you have entered the correct values in the automation settings file"
} 
else {
    Write-Output "Set the Azure Context to the subscription named '$($azContext.Subscription.Name)' with Id '$($azContext.Subscription.Id)'"
}

# Get the appropriate VM size from querying the VMs in the resource group
$vms = Get-AzVM -ResourceGroupName $resourceGroupName
$vmSize = $vms | Select-Object -First 1
$vmLocation = $vmSize.Location
$vmSize = $vmSize.HardwareProfile.VmSize
$skuName = $vmSize -replace 'Standard_'
$skuName = $skuName -replace '_', ' '

# Get Azure price list for all reserved VM instance SKUs matching VM size
Write-Output "Retrieving Reserved Instance prices for machine type '$vmSize'..."
try {
    $reservedAzurePriceSkus = Invoke-WebRequest -Uri "https://prices.azure.com/api/retail/prices?`$filter=armSkuName eq '$vmSize' and armRegionName eq '$vmLocation' and priceType eq 'Reservation' and skuName eq '$skuName'" -UseBasicParsing
    $reservedAzurePriceSkus = $reservedAzurePriceSkus | ConvertFrom-Json
}
catch {
    Write-Error "An error was received from the endpoint whilst querying the Azure Retail Prices API so the script was terminated"
}

if (!$reservedAzurePriceSkus.Items) {
    Write-Error "Azure Retail Prices API has not returned any data for VM size '$vmSize' in location '$vmLocation' with price type of 'Reservation' and SKU name '$skuName' so the script was terminated"
}

# Calculate hourly costs for reserved VM instances
$reservedVMCostUSD1YearTerm = $reservedAzurePriceSkus.Items | Where-Object { $_.reservationTerm -eq '1 Year' } | Select-Object -ExpandProperty retailPrice
$hourlyReservedCostUSD1YearTerm = $reservedVMCostUSD1YearTerm / 8760
$reservedVMCostUSD3YearTerm = $reservedAzurePriceSkus.Items | Where-Object { $_.reservationTerm -eq '3 Years' } | Select-Object -ExpandProperty retailPrice
$hourlyReservedCostUSD3YearTerm = $reservedVMCostUSD3YearTerm / 26280

# Get Azure price list for PAYG VM instances matching VM size
Write-Output "Retrieving PAYG prices for machine type '$vmSize'..."
try {
    $azurePrices = Invoke-WebRequest -Uri "https://prices.azure.com/api/retail/prices?`$filter=armSkuName eq '$vmSize' and armRegionName eq '$vmLocation' and priceType eq 'Consumption' and skuName eq '$skuName'" -UseBasicParsing
    $azurePrices = $azurePrices | ConvertFrom-Json
}
catch {
    Write-Error "An error was received from the endpoint whilst querying the Azure Retail Prices API so the script was terminated"
}

if (!$azurePrices.Items) {
    Write-Error "Azure Retail Prices API has not returned any data for VM size '$vmSize' in location '$vmLocation' with price type of 'Consumption' and SKU name '$skuName' so the script was terminated"
}

# Get meter id associated (using Linux pricing due to WVD)
$meterId = $azurePrices.Items | Where-Object { $_.productName -NotLike '*Windows' -and $_.serviceFamily -eq 'Compute' } | Select-Object -ExpandProperty meterId

# Check for any reserved instances of the machine type contained in resource group
Write-Output "Checking for any reserved instances of VM size '$vmSize'..."
$reservedInstances1YearTerm = 0
$reservedInstances3YearTerm = 0
$reservationOrders = Get-AzReservationOrderId -ErrorAction SilentlyContinue

if ($reservationOrders.Id) {
    $reservations = $reservationOrders.AppliedReservationOrderId
    $reservations = $reservations -replace "/providers/Microsoft.Capacity/reservationorders/"

    $reservedMachineTypes = foreach ($reservation in $reservations) { 

        Get-AzReservation -ReservationOrderId $reservation | Where-Object { $_.Sku -eq $vmSize }
    }

    foreach ($reservedMachineType in $reservedMachineTypes) {
        
        $reservedInstancesTerm = $reservedMachineType.DisplayName
        $reservedInstancesTerm = $reservedInstancesTerm -replace "Reserved_VM_Instance_"
        $reservedInstancesTerm = $reservedInstancesTerm -replace "$vmSize"
        $reservedInstancesTerm = $reservedInstancesTerm -replace "[^0-9]"

        if ($reservedInstancesTerm -eq 1) { 
            $reservedInstances1YearTerm += $reservedMachineType.Quantity
        }
        else { 
            $reservedInstances3YearTerm += $reservedMachineType.Quantity
        }
    }   

    if ($reservedInstances1YearTerm) {
        Write-Output "Found x$reservedInstances1YearTerm 1-Year reserved instances for VM size '$vmSize'"
    }

    if ($reservedInstances3YearTerm) {
        Write-Output "Found x$reservedInstances3YearTerm 3-Year reserved instances for VM size '$vmSize'"
    }
}

if (!$reservedInstances1YearTerm -and !$reservedInstances3YearTerm) {
    Write-Output "No reserved instances found for VM size '$vmSize'"
}

# Set billing day to yesterday
$yesterday = (Get-Date).AddDays(-1)
$billingDay = Get-Date $yesterday -Format yyyy-MM-dd

# Get token for API call
$azContext = Get-AzContext
$subscriptionId = $azContext.Subscription.Id
$azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
$profileClient = New-Object -TypeName Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient -ArgumentList ($azProfile)
$token = $profileClient.AcquireAccessToken($azContext.Subscription.TenantId)
$authHeader = @{
    'Content-Type'  = 'application/json'
    'Authorization' = 'Bearer ' + $token.AccessToken
}

# Invoke the REST API and pull in billing data for previous day
Write-Output "Retrieving billing data for billing day $billingDay..."
$billingUri = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Consumption/usageDetails?`startDate=$billingDay&endDate=$billingDay&api-version=2019-10-01"
try {
    $billingInfo = Invoke-WebRequest -Uri $billingUri -Method Get -Headers $authHeader -UseBasicParsing
    $billingInfo = $billingInfo | ConvertFrom-Json
}
catch {
    Write-Error "An error was received from the endpoint whilst querying the Microsoft Consumption API so the script was terminated"
}

$vmCosts = @()
$vmCosts += $billingInfo.value.properties | Where-Object { $_.meterId -Like $meterId -and $_.resourceGroup -eq $resourceGroupName } | Select-Object date, instanceName, resourceGroupName, meterId, meterName, unitPrice, quantity, paygCostInUSD, paygCostInBillingCurrency, exchangeRate

while ($billingInfo.nextLink) {
    $nextLink = $billingInfo.nextLink
    try {
        $billingInfo = Invoke-WebRequest -Uri $nextLink -Method Get -Headers $authHeader -UseBasicParsing
        $billingInfo = $billingInfo | ConvertFrom-Json
    }
    catch {
        Write-Error "An error was received from the endpoint whilst querying the Microsoft Consumption API for the next page so the script was terminated"
    }
    $vmCosts += $billingInfo.value.properties | Where-Object { $_.meterId -Like $meterId -and $_.resourceGroup -eq $resourceGroupName } | Select-Object date, instanceName, resourceGroupName, meterId, meterName, unitPrice, quantity, paygCostInUSD, paygCostInBillingCurrency, exchangeRate
}

# Filter billing data for compute type and retrieve costs
Write-Output "Successfully retrieved billing data for date $billingDay, calculating costs..."
$conversionRate = $vmCosts.exchangeRate | Select-Object -First 1
$hourlyVMCostUSD = $vmCosts.unitPrice | Select-Object -First 1
$hourlyVMCostBillingCurrency = $hourlyVMCostUSD * $conversionRate
$hourlyReservedCostBillingCurrency1YearTerm = $hourlyReservedCostUSD1YearTerm * $conversionRate
$hourlyReservedCostBillingCurrency3YearTerm = $hourlyReservedCostUSD3YearTerm * $conversionRate
$usageHours = $vmCosts.quantity | Measure-Object -Sum | Select-Object -ExpandProperty Sum
$billingDaySpendUSD = $vmCosts.quantity | Measure-Object -Sum | Select-Object -ExpandProperty Sum
$billingDaySpendUSD = $billingDaySpendUSD * $hourlyVMCostUSD
$billingDaySpend = $billingDaySpendUSD * $conversionRate

# Get VM count from hostpool and calculate hours runtime if all machines were powered on 24/7 - we have to use the Hostpool to enumerate vms
# rather than billing as powered off hosts will not show on the billing data due to no compute charge
$allVms = Get-AzWvdSessionHost -ResourceGroupName $resourceGroupName -HostPoolName $hostpoolName
$fullDailyRunHours = $allVms.Count * 24

# Calculate costs for PAYG 24/7 running
$fullPAYGDailyRunHoursPriceUSD = $fullDailyRunHours * $hourlyVMCostUSD
$fullPAYGDailyRunHoursPriceBillingCurrency = $fullDailyRunHours * $hourlyVMCostBillingCurrency

# Calculate costs for all VMs running as Reserved Instances
$fullDailyReservedHoursPriceUSD1YearTerm = $fullDailyRunHours * $hourlyReservedCostUSD1YearTerm
$fullDailyReservedHoursPriceUSD3YearTerm = $fullDailyRunHours * $hourlyReservedCostUSD3YearTerm
$fullDailyReservedHoursPriceBillingCurrency1YearTerm = $fullDailyRunHours * $hourlyReservedCostBillingCurrency1YearTerm
$fullDailyReservedHoursPriceBillingCurrency3YearTerm = $fullDailyRunHours * $hourlyReservedCostBillingCurrency3YearTerm

# Calculate costs for owned Reserved Instances and add to Billing Spend
$billingCost1YearTermUSD = $reservedInstances1YearTerm * $hourlyReservedCostUSD1YearTerm * 24
$billingCost3YearTermUSD = $reservedInstances3YearTerm * $hourlyReservedCostUSD3YearTerm * 24
$billingCost1YearTermBillingCurrency = $reservedInstances1YearTerm * $hourlyReservedCostBillingCurrency1YearTerm * 24
$billingCost3YearTermBillingCurrency = $reservedInstances3YearTerm * $hourlyReservedCostBillingCurrency3YearTerm * 24
$billingDaySpend = $billingDaySpend + $billingCost1YearTermBillingCurrency + $billingCost3YearTermBillingCurrency
$billingDaySpendUSD = $billingDaySpendUSD + $billingCost1YearTermUSD + $billingCost3YearTermUSD 

# Calculate savings from owned Reserved Instances
$reservationSavings1YearTermUSD = (($hourlyVMCostUSD * 24) * $reservedInstances1YearTerm) - $billingCost1YearTermUSD
$reservationSavings3YearTermUSD = (($hourlyVMCostUSD * 24) * $reservedInstances3YearTerm) - $billingCost3YearTermUSD
$reservationSavings1YearTermBillingCurrency = (($hourlyVMCostBillingCurrency * 24) * $reservedInstances1YearTerm) - $billingCost1YearTermBillingCurrency
$reservationSavings3YearTermBillingCurrency = (($hourlyVMCostBillingCurrency * 24) * $reservedInstances3YearTerm) - $billingCost3YearTermBillingCurrency

# Convert final figures to 2 decimal places
$fullPAYGDailyRunHoursPriceUSD = [math]::Round($fullPAYGDailyRunHoursPriceUSD, 2)
$fullPAYGDailyRunHoursPriceBillingCurrency = [math]::Round($fullPAYGDailyRunHoursPriceBillingCurrency, 2)
$fullDailyReservedHoursPriceUSD1YearTerm = [math]::Round($fullDailyReservedHoursPriceUSD1YearTerm, 2)
$fullDailyReservedHoursPriceUSD3YearTerm = [math]::Round($fullDailyReservedHoursPriceUSD3YearTerm, 2)
$fullDailyReservedHoursPriceBillingCurrency1YearTerm = [math]::Round($fullDailyReservedHoursPriceBillingCurrency1YearTerm, 2)
$fullDailyReservedHoursPriceBillingCurrency3YearTerm = [math]::Round($fullDailyReservedHoursPriceBillingCurrency3YearTerm, 2)
$billingCost1YearTermUSD = [math]::Round($billingCost1YearTermUSD, 2)
$billingCost3YearTermUSD = [math]::Round($billingCost3YearTermUSD, 2)
$billingCost1YearTermBillingCurrency = [math]::Round($billingCost1YearTermBillingCurrency, 2)
$billingCost3YearTermBillingCurrency = [math]::Round($billingCost3YearTermBillingCurrency, 2)
$billingDaySpend = [math]::Round($billingDaySpend, 2)
$billingDaySpendUSD = [math]::Round($billingDaySpendUSD, 2)
$reservationSavings1YearTermUSD = [math]::Round($reservationSavings1YearTermUSD, 2)
$reservationSavings3YearTermUSD = [math]::Round($reservationSavings3YearTermUSD, 2)
$reservationSavings1YearTermBillingCurrency = [math]::Round($reservationSavings1YearTermBillingCurrency, 2)
$reservationSavings3YearTermBillingCurrency = [math]::Round($reservationSavings3YearTermBillingCurrency, 2)

# Calculate total savings from Autoscaling + Reserved Instances
$automationHoursSaved = $fullDailyRunHours - $usageHours
$automationHoursSaved = [math]::Round($automationHoursSaved, 2)
$totalSavingsReservedInstancesUSD = $reservationSavings1YearTermUSD + $reservationSavings3YearTermUSD
$totalSavingsReservedInstancesBillingCurrency = $reservationSavings1YearTermBillingCurrency + $reservationSavings3YearTermBillingCurrency
$totalSavingsReservedInstancesBillingCurrency = [math]::Round($totalSavingsReservedInstancesBillingCurrency, 2)
$totalSavingsUSD = $fullPAYGDailyRunHoursPriceUSD - $billingDaySpendUSD
$totalSavingsBillingCurrency = $fullPAYGDailyRunHoursPriceBillingCurrency - $billingDaySpend

# Compare daily cost vs all VMs running as Reserved Instances
$allReservedSavings1YearTermUSD = $fullDailyReservedHoursPriceUSD1YearTerm - $billingDaySpendUSD
$allReservedSavings3YearTermUSD = $fullDailyReservedHoursPriceUSD3YearTerm - $billingDaySpendUSD
$allReservedSavings1YearTermBillingCurrency = $fullDailyReservedHoursPriceBillingCurrency1YearTerm - $billingDaySpend
$allReservedSavings3YearTermBillingCurrency = $fullDailyReservedHoursPriceBillingCurrency3YearTerm - $billingDaySpend

# Post data to Log Analytics
$logMessage = @{ 
    billingDay_s                                       = $billingDay;
    resourceGroupName_s                                = $resourceGroupName;
    billingDaySpendUSD_d                               = $billingDaySpendUSD;
    billingDaySpend_d                                  = $billingDaySpend;
    hoursSaved_d                                       = $automationHoursSaved; 
    savingsFromOwnedReservedInstancesUSD_d             = $totalSavingsReservedInstancesUSD;
    savingsFromOwnedReservedInstancesBillingCurrency_d = $totalSavingsReservedInstancesBillingCurrency;
    totalSavingsUSD_d                                  = $totalSavingsUSD;
    totalSavingsBillingCurrency_d                      = $totalSavingsBillingCurrency;
    ifAllReservedSavings1YearTermUSD_d                 = $allReservedSavings1YearTermUSD;
    ifAllReservedSavings3YearTermUSD_d                 = $allReservedSavings3YearTermUSD;
    ifAllReservedSavings1YearTermBillingCurrency_d     = $allReservedSavings1YearTermBillingCurrency;
    ifAllReservedSavings3YearTermBillingCurrency_d     = $allReservedSavings3YearTermBillingCurrency;
    usageHours_d                                       = $usageHours;
    hostPoolName_s                                     = $hostpoolName
}

Add-LogEntry -LogMessageObj $logMessage -LogAnalyticsWorkspaceId $logAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $logAnalyticsPrimaryKey -LogType "WVDBilling_CL"
Write-Output "Posted cost analysis data for date $billingDay to Log Analytics"

# Check to see if any WVDBilling logs are missing for the last 31 days
Write-Output "Checking for any missing cost analysis data in the last 31 days..."

# Query Log Analytics WVDBilling_CL log file for the last 31 days
$logAnalyticsQuery = Invoke-AzOperationalInsightsQuery -WorkspaceId $logAnalyticsWorkspaceId -Query "WVDBilling_CL | where TimeGenerated > ago(31d)" -ErrorAction SilentlyContinue

if (!$logAnalyticsQuery) {
    Write-Warning "An error was received from the endpoint whilst querying Log Analytics. Checks for any missing cost analysis data in the last 31 days will not be performed"
    Write-Warning "Error message: $($error[0].Exception.Message)"
}

if ($logAnalyticsQuery) {
    $loggedDays = $logAnalyticsQuery.Results.billingDay_s | foreach { Get-Date -Date $_ -Format yyyy-MM-dd }
    $startDate = -31
    $daysToCheck = $startDate..-1 | ForEach-Object { (Get-Date).AddDays($_).ToString('yyyy-MM-dd') }
    $missingDays = @()

    # Check for any missing days in Log Analytics WVDBilling_CL log file within the last 31 days
    foreach ($dayToCheck in $daysToCheck) {
        if ($loggedDays -notcontains $dayToCheck) {
            $missingDays += $dayToCheck
        }
    }

    # If there are any missing days then retrieve billing data for the missing days and post data to Log Analytics
    if ($missingDays) {
        foreach ($missingDay in $missingDays) {

            Write-Warning "Found no cost analysis data for date $missingDay. Retrieving billing data..."

            # Get token for API call
            $azContext = Get-AzContext
            $subscriptionId = $azContext.Subscription.Id
            $azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
            $profileClient = New-Object -TypeName Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient -ArgumentList ($azProfile)
            $token = $profileClient.AcquireAccessToken($azContext.Subscription.TenantId)
            $authHeader = @{
                'Content-Type'  = 'application/json'
                'Authorization' = 'Bearer ' + $token.AccessToken
            }
            # Invoke the REST API and pull in billing data for missing day
            $billingUri = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Consumption/usageDetails?`startDate=$missingDay&endDate=$missingDay&api-version=2019-10-01"
            try {
                $billingInfo = Invoke-WebRequest -Uri $billingUri -Method Get -Headers $authHeader -UseBasicParsing
                $billingInfo = $billingInfo | ConvertFrom-Json
            }
            catch {
                Write-Error "An error was received from the endpoint whilst querying the Microsoft Consumption API so the script was terminated"
            }

            $vmCosts = @()
            $vmCosts += $billingInfo.value.properties | Where-Object { $_.meterId -Like $meterId -and $_.resourceGroup -eq $resourceGroupName } | Select-Object date, instanceName, resourceGroupName, meterId, meterName, unitPrice, quantity, paygCostInUSD, paygCostInBillingCurrency, exchangeRate
            
            while ($billingInfo.nextLink) {
                $nextLink = $billingInfo.nextLink
                try {
                    $billingInfo = Invoke-WebRequest -Uri $nextLink -Method Get -Headers $authHeader -UseBasicParsing
                    $billingInfo = $billingInfo | ConvertFrom-Json
                }
                catch {
                    Write-Error "An error was received from the endpoint whilst querying the Microsoft Consumption API for the next page so the script was terminated"
                }
                $vmCosts += $billingInfo.value.properties | Where-Object { $_.meterId -Like $meterId -and $_.resourceGroup -eq $resourceGroupName } | Select-Object date, instanceName, resourceGroupName, meterId, meterName, unitPrice, quantity, paygCostInUSD, paygCostInBillingCurrency, exchangeRate
            }

            # Filter billing data for compute type and retrieve costs
            Write-Output "Successfully retrieved billing data for date $missingDay, calculating costs..."
            $usageHours = $vmCosts.quantity | Measure-Object -Sum | Select-Object -ExpandProperty Sum
            $billingDaySpendUSD = $vmCosts.quantity | Measure-Object -Sum | Select-Object -ExpandProperty Sum
            $billingDaySpendUSD = $billingDaySpendUSD * $hourlyVMCostUSD
            $billingDaySpend = $billingDaySpendUSD * $conversionRate

            # Calculate costs for owned Reserved Instances and add to Billing Spend
            $billingDaySpend = $billingDaySpend + $billingCost1YearTermBillingCurrency + $billingCost3YearTermBillingCurrency
            $billingDaySpendUSD = $billingDaySpendUSD + $billingCost1YearTermUSD + $billingCost3YearTermUSD 
            
            # Convert final figures to 2 decimal places
            $billingDaySpend = [math]::Round($billingDaySpend, 2)
            $billingDaySpendUSD = [math]::Round($billingDaySpendUSD, 2)

            # Calculate total savings from Autoscaling + Reserved Instances
            $automationHoursSaved = $fullDailyRunHours - $usageHours
            $automationHoursSaved = [math]::Round($automationHoursSaved, 2)
            $totalSavingsUSD = $fullPAYGDailyRunHoursPriceUSD - $billingDaySpendUSD
            $totalSavingsBillingCurrency = $fullPAYGDailyRunHoursPriceBillingCurrency - $billingDaySpend

            # Compare daily cost vs all VMs running as Reserved Instances
            $allReservedSavings1YearTermUSD = $fullDailyReservedHoursPriceUSD1YearTerm - $billingDaySpendUSD
            $allReservedSavings3YearTermUSD = $fullDailyReservedHoursPriceUSD3YearTerm - $billingDaySpendUSD
            $allReservedSavings1YearTermBillingCurrency = $fullDailyReservedHoursPriceBillingCurrency1YearTerm - $billingDaySpend
            $allReservedSavings3YearTermBillingCurrency = $fullDailyReservedHoursPriceBillingCurrency3YearTerm - $billingDaySpend

            # Post data to Log Analytics
            $logMessage = @{ 
                billingDay_s                                       = $missingDay;
                resourceGroupName_s                                = $resourceGroupName;
                billingDaySpendUSD_d                               = $billingDaySpendUSD;
                billingDaySpend_d                                  = $billingDaySpend;
                hoursSaved_d                                       = $automationHoursSaved; 
                savingsFromOwnedReservedInstancesUSD_d             = $totalSavingsReservedInstancesUSD;
                savingsFromOwnedReservedInstancesBillingCurrency_d = $totalSavingsReservedInstancesBillingCurrency;
                totalSavingsUSD_d                                  = $totalSavingsUSD;
                totalSavingsBillingCurrency_d                      = $totalSavingsBillingCurrency;
                ifAllReservedSavings1YearTermUSD_d                 = $allReservedSavings1YearTermUSD;
                ifAllReservedSavings3YearTermUSD_d                 = $allReservedSavings3YearTermUSD;
                ifAllReservedSavings1YearTermBillingCurrency_d     = $allReservedSavings1YearTermBillingCurrency;
                ifAllReservedSavings3YearTermBillingCurrency_d     = $allReservedSavings3YearTermBillingCurrency;
                usageHours_d                                       = $usageHours;
                hostPoolName_s                                     = $hostpoolName
            }
            Add-LogEntry -LogMessageObj $logMessage -LogAnalyticsWorkspaceId $logAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $logAnalyticsPrimaryKey -LogType "WVDBilling_CL"
            Write-Output "Posted cost analysis data for date $missingDay to Log Analytics"
        }
    }
    Write-Output "All WVD cost analysis data successfully posted to Log Analytics"
}
