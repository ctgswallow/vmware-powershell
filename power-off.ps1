# Columns in the CSV file are:
# vCenter, Cluster, Template, Name, Disksize, Network,
# CPUs, MemGB, IPAddress, Netmask, Gateway, FirstDNS, SecondDNS,
# DomainName, Folder, ResourcePool, Description, LeadDeveloper

$csvfile = $args[0]
if (Get-Item $csvfile) {
  $vms = Import-Csv $csvfile
} else {
  throw "$csvfile does not exist!"
}
 
# Set some global variables to be used across all jobs
$password = Read-Host -AsSecureString -Prompt "Please supply your vCenter password"
$tempCredential = New-Object System.Management.Automation.PsCredential "None",$password
$password = $tempCredential.GetNetworkCredential().Password


$username = $Env:USERNAME
$mydomain = "exacttarget.com"

$me = $Env:USERDOMAIN + "\" + $Env:USERNAME
$email = $Env:USERNAME + "@" + $mydomain
$datetime = Get-Date
$mmddyyyy = $datetime.ToShortDateString()

# Set this if you're going to lunch or don't want to be bothered with prompts.
#$confirm = $false
$confirm = $true
  
foreach ($vm in $vms) {
  if ($vm.vCenter -ne $connectedserver) {
    Write-Host Disconnecting from $connectedserver
	Disconnect-VIServer -Server $connectedserver -Confirm:$confirm
  }
	
  Write-Host Connecting to $vm.vCenter or reusing connection.
  if ($server = Connect-VIServer -Server $vm.vCenter -Protocol https -User $username -Password $password) {
	$connectedserver = $server.Name
	
    $cluster = Get-Cluster -Name $vm.Cluster
    $datacenter = Get-Datacenter -Cluster $cluster
    
	$rvm = Get-VM -Name $vm.Name -Location $datacenter
	$rvmview = Get-View $rvm.Id
	
	Write-Host Powering off $rvm.Name.
	$rvmview.PowerOffVM()		
        
	# Move the VM to the right folder.
    $vfolder = Get-Folder -Location $datacenter -NoRecursion | Where-Object { $_.Name -eq "vm" }
    if ($folder = Get-Folder -Location $vfolder | Where-Object { $_.Name -eq "Disabled Auth Servers" }) {
	    $fview = Get-View $folder.Id
	    Write-Host Moving $rvm.Name to $folder folder
	    $fview.MoveIntoFolder($rvmview.MoRef)
    } else {
        if ($folder = New-Folder -Location $vfolder -Name "Disabled Auth Servers" -Confirm:$confirm) {
		  Write-Host Created $folder folder.  Moving $rvm.Name to folder.
		  $fview = Get-View $folder.Id
		  $fview.MoveIntoFolder($rvmview.MoRef)
		} else {
  	  	  Write-Host "Could not create Disabled Auth Servers folder"
  	    }
    }
    
	# Rename the VM
	$rvmview.Rename("zzz" + $rvm.Name)
  }
}

Write-Host Disconnecting from $connectedserver.
Disconnect-VIServer -Server $connectedserver -Confirm:$confirm

