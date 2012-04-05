#****************************************************
#Script to Deploy Multiple VMs from Template
#v1.
#Downloaded from: Jason Langone
#Many thanks to: Blog.Halfbyte.com and NTPRO.NL
#*****************************************************

# Seriously
set-item wsman:localhost\Shell\MaxMemoryPerShellMB 512

# Support four concurrent jobs to speed things up.
$jobs = New-Object System.Collections.ArrayList
$jobs.Add("j1")
$jobs.Add("j2")
$jobs.Add("j3")
$jobs.Add("j4")

$queues = @()

# Columns in the CSV file are:
# vCenter, Cluster, Template, Name, Disksize, Network,
# CPU, MemGB, Folder, ResourcePool, Description
$csvfile = $args[0]
if (Get-Item $csvfile) {
  $vms = Import-Csv $csvfile
  
  # Each job gets a work queue, which is the next row in the CSV.
  
  $i=0
  foreach ($vm in $vms) {
  	if ($queues.Count -le $i) {
      $queues += ,@($vm)
      } else {
      $queues[$i] += $vm
      }
 
    $i++
    if ($i -eq $jobs.Count) {
      $i = 0
      }
    }
  } else {
  throw "$csvfile does not exist!"
  }
 
# Set some global variables to be used across all jobs
$password = Read-Host -AsSecureString -Prompt "Please supply your vCenter password"
$tempCredential = New-Object System.Management.Automation.PsCredential "None",$password
$password = $tempCredential.GetNetworkCredential().Password

# The majority of this script is executed as a block.
$sb = {
  param([array]$queue,$password)
  
  Add-PSSnapIn VMware.VimAutomation.Core
  
  $username = $Env:USERNAME
  $mydomain = "exacttarget.com"

  $me = $Env:USERDOMAIN + "\" + $Env:USERNAME
  $email = $Env:USERNAME + "@" + $mydomain
  $datetime = Get-Date
  $mmddyyyy = $datetime.ToShortDateString()

  # Set this if you're going to lunch or don't want to be bothered with prompts.
  $confirm = $false
  #$confirm = $true
  
  foreach ($vm in $queue) {
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
      $newvm = New-VM -Name $vm.Name -Template $template -DiskStorageFormat Thin -Host $hosts[$hrand] -Datastore $datastores[$drand] -Confirm:$confirm | Out-Null
  
      # Move the VM to its network.
      if ($adapter = Get-NetworkAdapter -VM $vm.Name | where { $_.Name -eq "Network Adapter 1" }) {
        Set-NetworkAdapter -NetworkAdapter $adapter -NetworkName $vm.Network -StartConnected $true -Confirm:$confirm | Out-Null
      } else {
        $adapter = New-NetworkAdapter -VM $vm.Name -NetworkName $vm.Network -Type Vmxnet3 -StartConnected:$true -Confirm:$confirm | Out-Null
      }
  
      # Resize the second hard disk to the specified size (40GB is default)
      if ($disk = Get-HardDisk -VM $vm.Name | where { $_.Name -eq "Hard disk 2" }) {
        if ($disk.CapacityKB -lt $secondkb) {
          Set-HardDisk -HardDisk $disk -Capacity $secondkb -Confirm:$confirm | Out-Null
        } else {
	      Remove-HardDisk -HardDisk $disk -DeletePermanently:$true -Confirm:$confirm
  	      New-HardDisk -VM $vm.Name -CapacityKB $secondkb -DiskType Flat -StorageFormat Thin -Confirm:$confirm | Out-Null
	    }
      }
  
      # Move the VM to the right folder.
      $vfolder = Get-Folder -Location $datacenter -NoRecursion | Where-Object { $_.Name -eq $vm.Folder }
      if ($folder = Get-Folder -Location $vfolder | Where-Object { $_.Name -eq $vm.Folder }) {
        Move-VM -Destination $folder -VM $vm.Name -Confirm:$confirm | Out-Null
      } else {
        $folder = New-Folder -Location $vfolder -Name $vm.Folder -Confirm:$confirm
	    Move-VM -Destination $folder -VM $vm.Name -Confirm:$confirm | Out-Null
      }
    
      # Move the VM to the right resource pool.  You can leave the resource pool blank in the CSV file.
      if ($rp = Get-ResourcePool -Location $datacenter | Where-Object { $_ -eq $vm.ResourcePool }) {
        Move-VM -Destination $rp -VM $vm.Name -Confirm:$confirm | Out-Null
      } # Will refrain from adding new resource pools if they don't exist.
  
      # Set Comments
      $description = $vm.description + " cloned from " + $vm.Template + " at " + $mmddyyyy
      Set-CustomField -Entity $newvm -Name "Creator" -Value $me -Confirm:$confirm
      Set-CustomField -Entity $newvm -Name "Email" -Value $email -Confirm:$confirm
      Set-VM -VM $newvm -Description $description -Confirm:$confirm
    
      # Set number of CPUs / memory (in gigabytes)
	  $mem = $vm.MemGB + "GB"
	  $mem = $mem / 1MB
	  Set-Vm -VM $vm.Name -NumCpu $vm.CPUs -MemoryMB $mem -Confirm:$confirm
	
      # Power on the VM.
      Start-VM -VM $vm.Name -Confirm:$confirm | Out-Null
    }
  }
}

# Junk, for testing
$sb2 = {
  param([array]$queue,$password,$sn)
  foreach ($vm in $queue) {
    $wait = Get-Random -Maximum 15 -Minimum 5
    Write-Host $sn $vm.Cluster $vm.Name $password
	Sleep $wait
	}
  }

# Start four background jobs and pass work queues to each job
$i = 0
foreach ($job in $jobs) {
  Start-Job -ScriptBlock $sb -Name $job -ArgumentList ($queues[$i],$password)
  $i++
}

# Reap jobs and send results of job to report file.
$running = $jobs.Count
$jobsToDelete = New-Object System.Collections.ArrayList

while ($running -gt 0) {
  sleep 1

  foreach ($job in $jobs) {
    $j = Get-Job -Name $job
	if ($j.State -eq "Completed") {
	  Receive-Job -Id $j.Id |Out-File -Append -FilePath $Env:TEMP\clone-report.txt
	  Remove-Job -Id $j.Id
	  $jobsToDelete.Add("$job")
	}
  }
  Write-Host JobsToDelete $jobsToDelete
  
  foreach ($job in $jobsToDelete) {
    $jobs.Remove("$job")
  }
  $jobsToDelete.Clear()
  
  $running = $jobs.Count
  Write-Host Jobs $jobs
}