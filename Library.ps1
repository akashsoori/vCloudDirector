Import-Module -Name VMware.VimAutomation.Core
Import-Module -Name VMware.VimAutomation.Cloud

$ErrorActionPreference = "Stop"

Function Login
{
	Write-Host "`nLogging onto $ENV:Cloud PL Cloud..."
	Connect-CIServer -Server $ENV:Cloud -User $ENV:UserName -Password $ENV:Password -Org $ENV:Organization
	Write-Host ""
}

Function CloneVApp
{
	$CatalogName = Get-Catalog $ENV:Catalog
	$VAppTemplateName = $CatalogName | Get-CIVAppTemplate $ENV:TemplateName

	Write-Host "`nCreating $ENV:VAppName VApp from $ENV:TemplateName VAppTemplate in $ENV:Organization Organization of $ENV:Cloud PL Cloud..."
	New-CIVApp -Name $ENV:VAppName -VAppTemplate $VAppTemplateName -OrgVdc $ENV:OrgVDC -RuntimeLease $null -Server $ENV:Cloud -StorageLease $null
	Write-Host ""
    
	CheckVAppTasks
}

Function StopVApp
{
	$MyVApp = Get-CIVApp -Name $ENV:VAppName
	$MyVM = Get-CIVApp $MyVApp | Get-CIVM

	if ($MyVM.Status -ne "PoweredOff")
	{
		Stop-CIVApp -VApp $MyVApp -Confirm:$False
			
		CheckVAppTasks
	}
}

Function ShareVApp
{
	$MyVApp = Get-CIVApp -Name $ENV:VAppName

	New-CIAccessControlRule -Entity $MyVApp -EveryoneInOrg -AccessLevel "Full" -Confirm:$False
	Write-Host ""
}

Function UpdateCPUandRAM
{
	$MyVApp = Get-CIVApp -Name $ENV:VAppName
	$MyVM = Get-CIVApp $MyVApp | Get-CIVM

	Write-Host "Updating CPU and RAM values as per user's input... `n"
	$Memory = 1024*$ENV:RAM

	$ExtensionDataLength = $MyVM.ExtensionData.Section[0].Item.Length
	for ($i=0; $i -lt $ExtensionDataLength; $i++)
	{
		if ($MyVM.ExtensionData.Section[0].Item[$i].Description[0].'Value' -eq 'Memory Size')
		{
			$MyVM.ExtensionData.Section[0].Item[$i].VirtualQuantity.Value = $Memory
		}

		if ($MyVM.ExtensionData.Section[0].Item[$i].Description[0].'Value' -eq 'Number of Virtual CPUs')
		{
			$MyVM.ExtensionData.Section[0].Item[$i].Any[0].'#text' = "1"
			$MyVM.ExtensionData.Section[0].Item[$i].VirtualQuantity.Value = $ENV:CPU
		}
	}
    
	$count = 0
	$completed = $false
	while (-not $completed)
	{
		try
		{
			$MyVM.ExtensionData.Section[0].UpdateServerData()
			$completed = $true
			return $retValue
		}
		catch
		{
			if($count -lt 3)
			{
				$count++
				Write-Host "Update server data opertion failed... Retrying in 120 seconds..."
				Start-Sleep 120
			}
			else
			{
				Write-Host "Maximum retries reached..."
				exit 1
			}
		}
	}
	
	CheckVAppTasks
}

Function UpdateVMName
{
    $MyVApp = Get-CIVApp -Name $ENV:VAppName

    Write-host "Updating Virtual Machine Names to be unique..."
    $VirtualMachines = Get-CIVApp $MyVApp | Get-CIVM
    
	foreach ($VirtualMachine in $VirtualMachines)
    {
        Write-host "Processing Virtual Machine: " $VirtualMachine
        Write-Host ""
        $MyVM = Get-CIVApp $MyVApp | Get-CIVM -Name $VirtualMachine
        $MyVMComputerName = $MyVM.ExtensionData.Section[3].ComputerName
        Write-host "Virtual Machine Computer Name: "  $MyVMComputerName
        Write-Host ""
        $MyVM.ExtensionData.Name = "$ENV:VAppName" + "_" + $MyVMComputerName
    
	    $count = 0
        $completed = $false
        while (-not $completed)
        {
            try
            {
                $MyVM.ExtensionData.UpdateServerData()
                $completed = $true
            }
            catch
            {
            	write-host $_.Exception.Message ", at line" $_.InvocationInfo.ScriptLineNumber 
                if($count -lt 3)
                {
                    $count++
                    Write-Host "Update server data opertion failed... Retrying in 120 seconds..."
                    Start-Sleep 120
                }
                else
                {
                    Write-Host "Maximum retries reached..." 
                    exit 1
                }
            }
        }

        Write-Host "New VM Name(s) are..."
        (Get-CIVApp $MyVApp | Get-CIVM).Name
        Write-Host ""
    }
}

Function StartVApp
{
    Write-Host "Powering On $ENV:VAppName VM... `n"
    Start-CIVApp -VApp $ENV:VAppName
	
	CheckVAppTasks
}

Function FetchExternalIP
{
    Write-Host "Fetching External IP Address of the VM... `n" 
    $MyVM = Get-CIVM -VApp $ENV:VAppName
    $NetworkType = Get-CIVApp $ENV:VAppName | Get-CIVAppNetwork | Select-Object ConnectionType

    $NetworkAddress = Get-CINetworkAdapter -VM $MyVM

    if ($NetworkType -Match "=Direct")
    {
        $NewNode = $NetworkAddress.IPAddress.IPAddressToString
    }
    else
    {
        $NewNode = $NetworkAddress[0].ExternalIPAddress.IPAddressToString
    }

    Write-Host "External IP Address of the VM is $NewNode`n"

    $MyVApp = Get-CIVApp -Name $ENV:VAppName

	Write-Host "Creating property for VApp Id at job level... `n"
	$MyVAppId=$MyVApp.Id
	Write-Host ""

	Write-Host "Creating property for VApp Created Date at job level... `n"
	$MyVAppCreatedDate=Get-Date $MyVApp.ExtensionData.DateCreated.ToUniversalTime() -Format "yyyy-MM-dd HH:mm:ss"        
	Write-Host ""

	Write-Host "Creating property for VApp Owner at job level... `n"
	$MyVAppOwner=$MyVApp.Owner.Name
	Write-Host ""
}

Function RetainExternalIP
{
    Write-Host "Retain External IP Address of the VM is $NewNode by setting it to true`n"
    
	$MyVApp = Get-CIVApp -Name $ENV:VAppName

	$networkconfigsection = $MyVApp.ExtensionData.GetNetworkConfigSection()
	$vappnetwork = $networkconfigsection.networkconfig
	$vappnetwork.configuration.RetainNetInfoAcrossDeployments = $true
    $networkconfigsection.UpdateServerData() 
    
    CheckVAppTasks
}

Function GetVMHostData
{
    $MyVApp = Get-CIVApp -Name $ENV:VAppName
    $MyVM = Get-CIVApp $MyVApp | Get-CIVM

	Write-Host "Connecting to $ENV:VIHost... `n"
	Connect-VIServer -Server $ENV:VIHost -Protocol https -User $ENV:UserName -Password $ENV:Password

	$CloudVMID=$MyVM.GetConnectionParameters().VMId
	$VCVMID="VirtualMachine-"+$CloudVMID
	Write-Host "`nVM ID - $VCVMID"

	$VM_Host = (get-vm -Id $VCVMID).vmhost.name
	Write-Host "VM Host - $VM_Host"
    Write-Host ""

	Write-Host "Logging out of $ENV:VIHost VI Server...`n"
	Disconnect-VIServer $ENV:VIHost -Force -Confirm:$False
}


Function Logout
{
	Write-Host "Logging out of $ENV:SelectedCloud PL Cloud..."
	Disconnect-CIServer $ENV:Cloud -Force -Confirm:$False
}

Function DeleteVApp
{
    $MyVApp = Get-CIVApp -Name $ENV:VAppName

    Write-Host "Deleting $ENV:VAppName VM... `n"
	Remove-CIVApp -VApp $MyVApp -Confirm:`$False
}

Function CheckTemplateExists
{
    Write-Host "`nChecking existing template $ENV:TemplateName in Catalog. `n"
    $error.Clear()
    
	$MyVapptemplate=Get-Catalog "$ENV:Catalog" | Get-CIVAppTemplate -Name "$ENV:TemplateName" -ErrorAction Ignore
    
	if($MyVapptemplate)
    {
	    Write-Host "$ENV:TemplateName already exists in catalog $ENV:Catalog in $ENV:Organization"
	    $VappTemplateOrgVDC=Get-OrgVdc -Name $myVapptemplate.OrgVdc.Name
	    $VappTemplateOrg=$VappTemplateOrgVDC.Org.Name

	    if ("$VappTemplateOrg" -eq "$ENV:Organization")
	    {
            $TemplateName = "$ENV:TemplateName" + "_"  + "$ENV:myjobId"
            Write-Host "Renaming $ENV:TemplateName to $TemplateName"
            $ENV:TemplateName = $TemplateName
	    }
    }
    else
    {
	    write-host $Error
	    Write-Host "$ENV:TemplateName not found in Catalog $ENV:Catalog in $ENV:Organization"
    }
}

Function CaptureAsTemplate
{
    Write-Host "Capturing VM as template in catalog $ENV:Catalog in Cloud $ENV:Cloud. `n"
    Get-CIVApp $ENV:VAppName | New-CIVAppTemplate -Name $ENV:TemplateName -OrgVdc "$ENV:OrgVDC" -Catalog "$ENV:Catalog" -Description "$ENV:VAppName"
    
	CheckVAppTasks
}

Function RenameVApp
{
    $MyVApp = Get-CIVApp -Name $ENV:VAppName

    Write-Host "Changing name of the Vapp from _wip to _fail..."
    $FailVappName = "$ENV:VAppName" -replace "_wip","_fail"
    $MyVApp | Set-CIVApp -Name $FailVappName
}

Function RebootVApp
{
	$MyVApp = Get-CIVApp -Name $ENV:VAppName
	$MyVM = Get-CIVApp $MyVApp | Get-CIVM

	$VMStatus = $MyVM.Status
	if ( $VMStatus -eq "PoweredOn" )
	{
		Write-Host -NoNewline "`nStopping VApp $ENV:VAppName..."
		Stop-CIVApp -VApp $ENV:VAppName -Confirm:$False
	}

	CheckVAppTasks

	Write-Host "Starting VApp $ENV:VAppName..."
	Start-CIVApp -VApp $ENV:VAppName

	CheckVAppTasks
}
