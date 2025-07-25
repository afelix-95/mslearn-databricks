param(
    [string]$suffix
)
Clear-Host
write-host "Starting script at $(Get-Date)"

# If no suffix provided, generate a 7-character alphanumeric one
if (-not $suffix) {
    $suffix = -join ((48..57) + (97..122) | Get-Random -Count 7 | ForEach-Object {[char]$_})
}

$resourceGroupName = "msl-$suffix"

Write-Output "Using resource group name: $resourceGroupName"

# Handle cases where the user has multiple subscriptions
$subs = Get-AzSubscription | Select-Object
if($subs.GetType().IsArray -and $subs.length -gt 1){
    Write-Host "You have multiple Azure subscriptions - please select the one you want to use:"
    for($i = 0; $i -lt $subs.length; $i++)
    {
            Write-Host "[$($i)]: $($subs[$i].Name) (ID = $($subs[$i].Id))"
    }
    $selectedIndex = -1
    $selectedValidIndex = 0
    while ($selectedValidIndex -ne 1)
    {
            $enteredValue = Read-Host("Enter 0 to $($subs.Length - 1)")
            if (-not ([string]::IsNullOrEmpty($enteredValue)))
            {
                if ([int]$enteredValue -in (0..$($subs.Length - 1)))
                {
                    $selectedIndex = [int]$enteredValue
                    $selectedValidIndex = 1
                }
                else
                {
                    Write-Output "Please enter a valid subscription number."
                }
            }
            else
            {
                Write-Output "Please enter a valid subscription number."
            }
    }
    $selectedSub = $subs[$selectedIndex].Id
    Select-AzSubscription -SubscriptionId $selectedSub
    az account set --subscription $selectedSub
}


# Register resource providers
Write-Host "Registering resource providers...";
$provider_list = "Microsoft.Storage", "Microsoft.Compute", "Microsoft.Databricks"
foreach ($provider in $provider_list){
    $result = Register-AzResourceProvider -ProviderNamespace $provider
    $status = $result.RegistrationState
    Write-Host "$provider : $status"
}


# Choose a region
Write-Host "Preparing to deploy. This may take several minutes...";
$delay = 0, 30, 60, 90, 120 | Get-Random
Start-Sleep -Seconds $delay # random delay to stagger requests from multi-student classes

# Get a list of locations for Azure Databricks
$supported_regions = "centralus","eastus","eastus2","northcentralus","northeurope","westeurope","westus", "uksouth"
$locations = Get-AzLocation | Where-Object {
    $_.Providers -contains "Microsoft.Databricks" -and
    $_.Providers -contains "Microsoft.Compute" -and
    $_.Location -in $supported_regions
}
$max_index = $locations.Count - 1
$rand = (0..$max_index) | Get-Random

# Start with preferred region if specified, otherwise choose one at random
if ($args.count -gt 0 -And $args[0] -in $locations.Location)
{
    $Region = $args[0]
}
else {
    $Region = $locations.Get($rand).Location
}

# Try to create an Azure Databricks workspace in a region that has capacity
$stop = 0
$tried_regions = New-Object Collections.Generic.List[string]
while ($stop -ne 1){
    write-host "Trying $Region..."
    # Check that the required SKU is available
    $skuOK = 1
    $skus = Get-AzComputeResourceSku $Region | Where-Object {$_.ResourceType -eq "VirtualMachines" -and $_.Name -eq "Standard_D4ds_v5"}
    if ($skus.length -gt 0)
    {
        $r = $skus.Restrictions
        if ($r -ne $null)
        {
            $skuOK = 0
            Write-Host $r[0].ReasonCode
        }
    }
    # Get the available quota
    $available_quota = 0
    if ($skuOK -eq 1)
        {
            $quota = @(Get-AzVMUsage -Location $Region).where{$_.name.LocalizedValue -match 'Standard DDSv5 Family vCPUs'}
            $cores =  $quota.currentvalue
            $maxcores = $quota.limit
            write-host "$cores of $maxcores cores in use."
            $available_quota = $quota.limit - $quota.currentvalue
        }
    if (($available_quota -lt 8) -or ($skuOK -eq 0))
    {
        Write-Host "$Region has insufficient capacity."
        $tried_regions.Add($Region)
        $locations = $locations | Where-Object {$_.Location -notin $tried_regions}
        if ($locations.Count -ne 1){
            $rand = (0..$($locations.Count - 1)) | Get-Random
            $Region = $locations.Get($rand).Location
            $stop = 0
        }
        else {
            Write-Host "Could not create a Databricks workspace."
            Write-Host "Try using the Azure portal to add one to the $resourceGroupName resource group."
            $stop = 1
        }
    }
    else {
        Write-Host "Creating $resourceGroupName resource group ..."
        New-AzResourceGroup -Name $resourceGroupName -Location $Region | Out-Null
        $dbworkspace = "databricks-$suffix"
        Write-Host "Creating $dbworkspace Azure Databricks workspace in $resourceGroupName resource group..."
        New-AzDatabricksWorkspace -Name $dbworkspace -ResourceGroupName $resourceGroupName -Location $Region -Sku premium | Out-Null
        $stop = 1
    }
}


write-host "Script completed at $(Get-Date)"
