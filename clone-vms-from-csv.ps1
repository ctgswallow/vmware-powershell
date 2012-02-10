#****************************************************
#Script to Deploy Multiple VMs from Template
#v1.
#Downloaded from: Jason Langone
#Many thanks to: Blog.Halfbyte.com and NTPRO.NL
#*****************************************************
Add-PSSnapIn VMware.VimAutomation.Core

# Columns in the CSV file are:
# vCenter, Cluster, Template, Name, Disksize, Network,
# CPU, MemGB, Folder, ResourcePool

$csvfile = $args[0]
if (Get-Item $csvfile) {
  $vms = Import-Csv $csvfile
  } else {
  throw "$csvfile does not exist!"
  }
  
$password = Read-Host -AsSecureString -Prompt "Please supply your vCenter password"
$tempCredential = New-Object System.Management.Automation.PsCredential "None",$password
$password = $tempCredential.GetNetworkCredential().Password
$username = $Env:USERNAME
$mydomain = "exacttarget.com"

$me = $Env:USERDOMAIN + "\" + $Env:USERNAME
$email = $Env:USERNAME + "@" + $mydomain
$datetime = Get-Date
$mmddyyyy = $datetime.ToShortDateString()

# Set this if you're going to lunch:
$confirm = $false
#$confirm = $true

foreach ($vm in $vms) {
 
  $server = Connect-VIServer -Server $vm.vCenter -Protocol https -User $username -Password $password
  $seconddisk = $vm.Disksize + "GB"
  #$totalmb = ($seconddisk / 1MB + 12GB / 1MB)
  $secondkb = ($seconddisk / 1KB)
  
  $cluster = Get-Cluster -Name $vm.Cluster
  $datacenter = Get-Datacenter -Cluster $cluster
  $network = Get-VirtualPortGroup -Name $vm.Network
  
  # Assign new VMs randomly to hosts in the cluster.
  $hosts = Get-VMHost -Location $cluster
  $hrand = Get-Random -Maximum $hosts.Count -Minimum 1

  # Assign new VMs randomly to datacenters available to the cluster, where there is enough space to handle the whole VM.
  if ($template = Get-Template -Location $datacenter -Name $vm.Template) {
    $firstdisk = Get-HardDisk -Template $template | where { $_.Name -eq "Hard disk 1" }
	$totalmb = ($firstdisk.CapacityKB / 1KB) + ($seconddisk / 1MB)
    $datastores = Get-Datastore -VMHost $hosts[$hrand] | Where-Object {$_.FreeSpaceMB -gt $totalmb} | sort -Descending -Property FreeSpaceMB
    $drand = Get-Random -Maximum $datastores.Count -Minimum 1
  
  # Create the VM from template.
    Write-Host $vm.Name will be cloned from $vm.Template on $hosts[$hrand], datastore $datastores[$drand] in network $vm.Network
    $newvm = New-VM -Name $vm.Name -Template $template -DiskStorageFormat Thin -Host $hosts[$hrand] -Datastore $datastores[$drand] -Confirm:$confirm

    # Move the VM to its network.
    if ($adapter = Get-NetworkAdapter -VM $vm.Name | where { $_.Name -eq "Network Adapter 1" }) {
      Set-NetworkAdapter -NetworkAdapter $adapter -NetworkName $vm.Network -StartConnected $true -Confirm:$confirm
    } else {
      $adapter = New-NetworkAdapter -VM $vm.Name -NetworkName $vm.Network -Type Vmxnet3 -StartConnected:$true -Confirm:$confirm
    }
  
    # Resize the second hard disk to the specified size (40GB is default)
    if ($disk = Get-HardDisk -VM $vm.Name | where { $_.Name -eq "Hard disk 2" }) {
      if ($disk.CapacityKB -lt $secondkb) {
        Set-HardDisk -HardDisk $disk -Capacity $secondkb -Confirm:$confirm
      } else {
	    Remove-HardDisk -HardDisk $disk -DeletePermanently:$true -Confirm:$confirm
  	    New-HardDisk -VM $vm.Name -CapacityKB $secondkb -DiskType Flat -StorageFormat Thin -Confirm:$confirm
	  }
    }
  
    # Move the VM to the right folder.
    $vfolder = Get-Folder -Location $datacenter -NoRecursion | Where-Object { $_.Name -eq "vm" }
    if ($folder = Get-Folder -Location $vfolder | Where-Object { $_.Name -eq $vm.Folder }) {
      Move-VM -Destination $folder -VM $vm.Name -Confirm:$confirm
    } else {
      $folder = New-Folder -Location $vfolder -Name $vm.Folder -Confirm:$confirm
	  Move-VM -Destination $folder -VM $vm.Name -Confirm:$confirm
    }
  
    # Move the VM to the right resource pool.  You can leave the resource pool blank in the CSV file.
    if ($rp = Get-ResourcePool -Location $datacenter | Where-Object { $_ -eq $vm.ResourcePool }) {
      Move-VM -Destination $rp -VM $vm.Name -Confirm:$confirm
    } # Will refrain from adding new resource pools if they don't exist.
  
    # Set Comments
    $description = "Cloned from " + $vm.Template + " at " + $mmddyyyy
    Set-CustomField -Entity $newvm -Name "Creator" -Value $me -Confirm:$confirm
    Set-CustomField -Entity $newvm -Name "Email" -Value $email -Confirm:$confirm
    Set-VM -VM $newvm -Description $description -Confirm:$confirm
  
    # Set number of CPUs / memory (in gigabytes)
	$mem = $vm.MemGB + "GB"
	$mem = $mem / 1MB
	Set-Vm -VM $vm.Name -NumCpu $vm.CPUs -MemoryMB $mem -Confirm:$confirm
	
    # Power on the VM.
    Start-VM -VM $vm.Name -Confirm:$confirm
  }
}