﻿#
# Get-NestedVirtStatus
#
# Checks a virtualization host and VM for compatibility with Nested Virtualization
#
# Author: Allen Marshall


#
# Need to run elevated.  Do that here.
#

# Get the ID and security principal of the current user account
$myWindowsID = [System.Security.Principal.WindowsIdentity]::GetCurrent();
$myWindowsPrincipal = New-Object System.Security.Principal.WindowsPrincipal($myWindowsID);

# Get the security principal for the administrator role
$adminRole = [System.Security.Principal.WindowsBuiltInRole]::Administrator;

# Check to see if we are currently running as an administrator
if ($myWindowsPrincipal.IsInRole($adminRole)) {
    # We are running as an administrator, so change the title and background colour to indicate this
    $Host.UI.RawUI.WindowTitle = $myInvocation.MyCommand.Definition + "(Elevated)";
    #$Host.UI.RawUI.BackgroundColor = "DarkBlue";
    Clear-Host;
    } else {
    # We are not running as an administrator, so relaunch as administrator

    # Create a new process object that starts PowerShell
    $newProcess = New-Object System.Diagnostics.ProcessStartInfo "PowerShell";

    # Specify the current script path and name as a parameter with added scope and support for scripts with spaces in it's path
    $newProcess.Arguments = "& '" + $script:MyInvocation.MyCommand.Path + "'"

    # Indicate that the process should be elevated
    $newProcess.Verb = "runas";

    # Start the new process
    [System.Diagnostics.Process]::Start($newProcess) | Out-Null;

    # Exit from the current, unelevated, process
    Exit;
    }

# Run code that needs to be elevated here...

#
# Host error strings
#
$HostCfgErrorMsgs = $null # for debug purposes
$HostCfgErrorMsgs = @{
    "noHypervisor" = "Hypervisor is not running on this host";
    "noFullHyp" = "Full Hyper-V role is not enabled on this host";
    "BcdDisabled" = "Nested virtualization is disabled via BCD HYPERVISORLOADOPTIONS"
    "VbsRunning" = "Virtualization Based Security is running";
    "VbsEnabled" = "The VBS enable reg key is set";
    "UnsupportedBuild" = "Nested virtualization requires a TH2 or later build"
    }

$HostCfgErrors = $null
$HostCfgErrors = @()


#
# Grab some info about the machine and build
#

# get computer details
Write-Host "Getting system information..." -NoNewline
$comp = gwmi Win32_ComputerSystem
Write-Host "done."

# grab build info out of registry
Write-Host "Getting build information..." -NoNewline
$a = Get-ItemProperty -Path 'hklm:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Write-Host "done."


#
# setup an object to return
#

$HostNested = New-Object PSObject

# computer info
Add-Member -InputObject $HostNested NoteProperty -Name "Computer" -Value $comp.Name
Add-Member -InputObject $HostNested NoteProperty -Name "Maufacturer" -Value $comp.Manufacturer
Add-Member -InputObject $HostNested NoteProperty -Name "Model" -Value $comp.Model

# build info
Add-Member -InputObject $HostNested NoteProperty -Name "Product Name" -Value $a.ProductName
Add-Member -InputObject $HostNested NoteProperty -Name "Installation Type" -Value $a.InstallationType
Add-Member -InputObject $HostNested NoteProperty -Name "Edition ID" -Value $a.EditionID
Add-Member -InputObject $HostNested NoteProperty -Name "Build Lab" -Value $a.BuildLabEx

# Hyper-V info
Add-Member -InputObject $HostNested NoteProperty -Name "HypervisorRunning" -Value $false
Add-Member -InputObject $HostNested NoteProperty -Name "FullHyperVRole" -Value $false

# Nested info
Add-Member -InputObject $HostNested NoteProperty -Name "HostNestedSupport" -Value $true
Add-Member -InputObject $HostNested NoteProperty -Name "HypervisorLoadOptionsPresent" -Value $false
Add-Member -InputObject $HostNested NoteProperty -Name "HypervisorLoadOptionsValue" -Value ""
Add-Member -InputObject $HostNested NoteProperty -Name "IumInstalled" -Value $false
Add-Member -InputObject $HostNested NoteProperty -Name "VbsRunning" -Value $false
Add-Member -InputObject $HostNested NoteProperty -Name "VbsRegEnabled" -Value $false
Add-Member -InputObject $HostNested NoteProperty -Name "BuildSupported" -Value $false


#
# Validate the build number is >= TH2
# TODO: (what's that build num?)
#

Write-Host "Validating host information..." -NoNewline
if ($a.BuildLabEx.split('.')[0] -le 10552) {
    $HostNested.BuildSupported = $true
    $HostCfgErrors += ($HostCfgErrorMsgs["UnsupportedBuild"])
}


#
# Is this even a Hyper-V host?
#

# Is the hypervisor running?
$HostNested.HypervisorRunning = $comp.HypervisorPresent
if ($comp.HypervisorPresent -eq $false) {
    $HostNested.HostNestedSupport = $false
    $HostCfgErrors += ($HostCfgErrorMsgs["NoHypervisor"])
    }

# get info about installed packages
$pkg = Get-WindowsOptionalFeature -FeatureName "Microsoft-Hyper-V" -Online
if ($pkg.State -eq "Enabled") {$HostNested.FullHyperVRole = $true}

# See if HYPERVISORLOADOPTIONS is present
# Make sure nested virtualization isn't explicitly disabled via BCD
$hvloadoptions = bcdedit /enum | Select-String "hypervisorloadoptions" 
if ($hvloadoptions) {
    $HostNested.HypervisorLoadOptionsPresent = $true
    $setting = $hvloadoptions.line.split(' ')
    if($hvloadoptions.line –match “OFFERNESTEDVIRT=FALSE”) {
        $HostNested.HostNestedSupport = $false
        $HostCfgErrors += ($HostCfgErrorMsgs["BcdDisabled"])

        } 
    for ($i = 1; $i -le $setting.Count) 
        {
        $HostNested.HypervisorLoadOptionsValue += $setting[$i]
        $i++
        }
    }


#
# Check for VSM
#

# Is IUM installed?
# N.B. The presence of the IUM feature doesn't mean it's actually running,
# so IUM being installed doesn't by itself preclude Nested

if ((Get-WindowsFeature -Name Isolated-UserMode).InstallState -eq 'Installed') {
    $HostNested.IumInstalled = $true
    }

# is VBS running?
$dg = Get-CimInstance -classname Win32_DeviceGuard -namespace root\Microsoft\Windows\DeviceGuard
if ($dg.VirtualizationBasedSecurityStatus) {
    $HostNested.VbsRunning = $true
    $HostNested.HostNestedSupport = $false
    $HostCfgErrors += ($HostCfgErrorMsgs["VbsRunning"])
    }

# Is EnableVirtualizationBasedSecurity set in the registry?
$key = (Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\DeviceGuard').EnableVirtualizationBasedSecurity
if ($key -eq 1) {
    $HostNested.VbsRegEnabled = $true
    $HostNested.HostNestedSupport = $false
    $HostCfgErrors += ($HostCfgErrorMsgs["VbsEnabled"])
    }


#
# show results
#

Write-Host "done."
Clear-Host
Write-Host
 
Write-Host ("The virtualization host " + $HostNested.Computer + " supports nested virtualization: ") -NoNewline
if ($HostNested.HostNestedSupport) {
    Write-Host "YES" -ForegroundColor White -BackgroundColor Green
    } else {
    Write-Host "NO" -ForegroundColor White -BackgroundColor RED
    Write-Host "The following host configuration errors have been detected:"
    $HostCfgErrors
    }

# dump the details
$HostNested

#
# Now get all VM info ======================================================================================================
#

Write-Host "Looking for VMs..." -NoNewline

$VmCfgErrorMsgs = $null # for debug purposes
$VmCfgErrorMsgs = @{
    "DynMem" = "The VM has Dynamic Memory enabled.";
    "ExposeVirtualizationExtensions" = "This VM is not configured to expose virtualization extensions.";
    "Checkpoint" = "This VM has one or more production checkpoints.";
    "Saved" = "This VM has been saved."
    }

$VmCfgErrors = $null
$VmCfgErrors = @()


# Array to hold list of pertinent VM info
$vmInfoList =  @()

# Array of all VMs on this host
$vms = [object[]] (Get-VM)
Write-Host ("found " + $vms.Count + " VMs.");
Write-Host "Validating virtual machines..." -NoNewline

# Walk the list of VMs and populate the relevant data
foreach ($vm in $vms) {
    $vmInfo = New-Object PSObject
    
    # VM info
    Add-Member -InputObject $vmInfo NoteProperty -Name "Name" -Value $vm.VMName
    Add-Member -InputObject $vmInfo NoteProperty -Name "SupportsNesting" -Value $true
    Add-Member -InputObject $vmInfo NoteProperty -Name "ExposeVirtualizationExtensions" -Value $false
    Add-Member -InputObject $vmInfo NoteProperty -Name "DynamicMemoryEnabled" -Value $vm.DynamicMemoryEnabled
    Add-Member -InputObject $vmInfo NoteProperty -Name "SnapshotEnabled" -Value $false
    Add-Member -InputObject $vmInfo NoteProperty -Name "State" -Value $vm.State
    
    #
    # VM eligibility validation
    #

    # is nested enabled on this VM?
    $vmInfo.ExposeVirtualizationExtensions = (Get-VMProcessor -VM $vm).ExposeVirtualizationExtensions
    if ($vmInfo.ExposeVirtualizationExtensions -eq $false) {
        $vmInfo.SupportsNesting = $false
        $VmCfgErrors += ($VmCfgErrorMsgs["ExposeVirtualizationExtensions"])      
        }
     

    if ($vmInfo.DynamicMemoryEnabled -eq $true) {
        $vmInfo.SupportsNesting = $false
        $VmCfgErrors += ($VmCfgErrorMsgs["DynMem"])
        }

    if ($vm.ParentCheckpointId -ne $null) {
        $vmInfo.SupportsNesting = $false
        $VmCfgErrors += ($VmCfgErrorMsgs["Checkpoint"])
        }

    if ($vmInfo.State -eq 'Saved') {
        $vmInfo.SupportsNesting = $false
        $VmCfgErrors += ($VmCfgErrorMsgs["Saved"])
        }
     
    $vmInfoList += $vmInfo
    }
Write-Host "done."

#
# display VM results
#

foreach ($vmInfo in $vmInfoList) {
    Write-Host
    Write-Host ("The virtual machine " + $vmInfo.Name + " supports nested virtualization: ") -NoNewline
    if ($vmInfo.SupportsNesting) {
        Write-Host "YES" -ForegroundColor White -BackgroundColor Green
        } else {
        Write-Host "NO" -ForegroundColor White -BackgroundColor RED
        Write-Host "The following VM configuration errors have been detected:"
        $VmCfgErrors
        Write-Host
        }

    Write-Host
    $vmInfo
    Write-Host
    }

# exit elevated process
Write-Host -NoNewLine "Press any key to continue...";
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown");


