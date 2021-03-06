#****************************************************
#Script to Deploy Multiple VMs from Template
#v2.14.
#Downloaded from: Jason Langone
#Many thanks to: Blog.Halfbyte.com and NTPRO.NL
#*****************************************************

# Support concurrent jobs to speed things up.
$jobs = New-Object System.Collections.ArrayList
$jobs_byid = New-Object System.Collections.ArrayList
$jobs.Add("j1")
$jobs.Add("j2")
$jobs.Add("j3")
$jobs.Add("j4")
$jobs.Add("j5")
$jobs.Add("j6")
$jobs.Add("j7")
$jobs.Add("j8")

$queues = @()

# Columns in the CSV file are:
# vCenter, Cluster, Template, Name, Disksize, Network,
# CPUs, MemGB, IPAddress, Netmask, Gateway, FirstDNS, SecondDNS,
# DomainName, Folder, ResourcePool, Description, LeadDeveloper,
# DNS
#
# Some of the columns in the .xltx contain formulas to make life
# easier for ETers.

$csvfile = $args[0]
if (Get-Item $csvfile) {
  $vms = Import-Csv $csvfile
  
  # Cycle through the rows in the CSV and add VMs
	# to work queues, round-robin.
  
  $i=0
  foreach ($vm in $vms) {
  	if ($queues.Count -le $i) {
     	$queues += ,@($vm)
    } else {
      $queues[$i] += $vm
    }
    Write-Host Adding $vm.Name to Queue $i 
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

  # Set this to false if you're going to lunch or don't want to be bothered with prompts.
  $confirm = $false
  #$confirm = $true
  
  foreach ($vm in $queue) {
    if ($vm.vCenter -ne $connectedserver -and $connectedserver.get_IsConnected) {
	    Write-Host Disconnecting from $connectedserver
	    Disconnect-VIServer -Server $connectedserver -Confirm:$confirm
    }
	
	  if ($connectedserver.Get_IsConnected) {
			Write-Host Reusing connection to $vm.vCenter.
		} 
		elseif ( $server = Connect-VIServer -Server $vm.vCenter -Protocol https -User $username -Password $password) {
			$connectedserver = $server.Name
		}
		else {
		  Write-Host Cannot connect to $vm.vCenter!
			continue
	  }
	  
		$seconddisk = $vm.Disksize + "GB"
    $secondkb = ($seconddisk / 1KB)
  
	  # Sanity check
    if ($cluster = Get-Cluster -Name $vm.Cluster) {
      $datacenter = Get-Datacenter -Cluster $cluster
		} else {
		  Write-Host $("You tried to create " + $vm.Name + " in a cluster that doesn't exist: " + $vm.Cluster)
      continue
	  }
		
    # Assign new VMs randomly to hosts in the cluster.
    $hosts = Get-VMHost -Location $cluster
    $hrand = Get-Random -Maximum $hosts.Count -Minimum 1
	  $curhost = $hosts[$hrand]
	  $chview = Get-View $curhost.Id

    # Assign new VMs randomly to VMFS datastores available to the cluster (not NFS)
		# where there is enough space to handle the whole VM.
    if ($template = Get-Template -Location $datacenter -Name $vm.Template) {
      $firstdisk = Get-HardDisk -Template $template | where { $_.Name -eq "Hard disk 1" }
	    $totalmb = ($firstdisk.CapacityKB / 1KB) + ($seconddisk / 1MB)
      $datastores = Get-Datastore -VMHost $curhost | Where-Object {$_.FreeSpaceMB -gt $totalmb -and ($_ | Get-View).Summary.Type -eq "VMFS"} | sort -Descending -Property FreeSpaceMB
      $drand = Get-Random -Maximum $datastores.Count -Minimum 1
		
		  # Create a temporary OSCustomizationSpec to use to set IP addresses.
		  $dnsServers = @($vm.FirstDNS, $vm.SecondDNS)
		  if ($spec = New-OSCustomizationSpec -Type NonPersistent -Name $vm.Name -NamingScheme VM -DnsServer $dnsServers -DnsSuffix $vm.DomainName -OSType Linux -Domain $vm.DomainName) {
		    $nicmap = Get-OSCustomizationNicMapping -OSCustomizationSpec $spec.Name
		    Set-OSCustomizationNicMapping -OSCustomizationNicMapping $nicmap -IpMode UseStaticIP -IpAddress $vm.IPAddress -SubnetMask $vm.Netmask -DefaultGateway $vm.Gateway
		
		    # Create the VM from template.  Make sure the resource pool exists and create the folder if necessary.  
        Write-Host $vm.Name will be cloned from $vm.Template in $vm.Folder on $curhost, datastore $datastores[$drand] in network $vm.Network
		    $newvm = New-VM -Name $vm.Name -Template $template -OSCustomizationSpec $spec.Name -DiskStorageFormat Thin -Host $curhost -Datastore $datastores[$drand] -Confirm:$confirm
		    $nvview = Get-View $newvm.Id
		  } else {
			
				# Or fail and move on.
				Write-Host Could not create a OSCustomizationSpec called $vm.Name
				Write-Host $vm.Name will be cloned from $vm.Template in $vm.Folder on $curhost, datastore $datastores[$drand] in network $vm.Network
		    $newvm = New-VM -Name $vm.Name -Template $template -DiskStorageFormat Thin -Host $curhost -Datastore $datastores[$drand] -Confirm:$confirm
		    $nvview = Get-View $newvm.Id
			}
			
		  # Move the VM to its network.
      if ($pg = Get-VirtualPortGroup -VMHost $curhost | Where-Object { $_.Name -eq $vm.Network }) {
				if ($adapter = Get-NetworkAdapter -VM $newvm | where { $_.Name -eq "Network Adapter 1" }) {
		      Write-Host Moving network adapter to $vm.Network network.
          Set-NetworkAdapter -NetworkAdapter $adapter -NetworkName $vm.Network -StartConnected $true -Confirm:$confirm
        } else {
		      Write-Host Adding network adapter in $vm.Network network.
          $adapter = New-NetworkAdapter -VM $newvm -NetworkName $vm.Network -Type Vmxnet3 -StartConnected:$true -Confirm:$confirm
        }
      } else {
				Write-Host $("Could not add " + $vm.Name + " to " + $vm.Network)
			}

			# Resize the second hard disk to the specified size (40GB is default)
      if ($disk = Get-HardDisk -VM $newvm | Where-Object { $_.Name -eq "Hard disk 2" }) {
        if ($disk.CapacityKB -lt $secondkb) {
		      Write-Host Setting Hard-disk $disk.Name to $secondkb KB capacity.
          Set-HardDisk -HardDisk $disk -CapacityKB $secondkb -Confirm:$confirm
        } else {
		      Write-Host Replacing $disk.Name with $secondkb KB capacity disk.
	        Remove-HardDisk -HardDisk $disk -DeletePermanently:$true -Confirm:$confirm
  	      New-HardDisk -VM $newvm -CapacityKB $secondkb -DiskType Flat -StorageFormat Thin -Confirm:$confirm
	      }
      }
        
		  # Move the VM to the right folder.
      $vfolder = Get-Folder -Location $datacenter -NoRecursion | Where-Object { $_.Name -eq "vm" }
      if ($folder = Get-Folder -Location $vfolder | Where-Object { $_.Name -eq $vm.Folder }) {
		    $fview = Get-View $folder.Id
		    Write-Host Moving $vm.Name to $folder folder
		    $fview.MoveIntoFolder($nvview.MoRef)
      } else {
        if ($folder = New-Folder -Location $vfolder -Name $vm.Folder -Confirm:$confirm) {
		      Write-Host Created $folder folder.  Moving $vm.Name to folder.
			    $fview = Get-View $folder.Id
			    $fview.MoveIntoFolder($nvview.MoRef)
	      } else {
  	      Write-Host Could not create $vm.Folder folder.
  	   	}
      }
    
      # Move the VM to the right resource pool.  You can leave the resource pool blank in the CSV file.
      if ($rp = Get-ResourcePool -Location $datacenter | Where-Object { $_.name -eq $vm.ResourcePool }) {
		    Write-Host Moving $vm.Name to $rp.Name resource pool.
		    $rpview = Get-View $rp.Id
		    $rpview.MoveIntoResourcePool($nvview.MoRef)
      } # Will refrain from adding new resource pools if they don't exist. 
        
		  # Set Comments
		  Write-Host Setting comments on $newvm.Name.
	    if ($ca = Get-CustomAttribute -Name Creator) {
		    $nvview.setCustomValue($ca.Name,$me)
		  } else {
		    $ca = New-CustomAttribute -Name Creator -TargetType $null -Confirm:$confirm
		    $nvview.setCustomValue($ca.Name,$me)
		  }
		 
		  if ($ca = Get-CustomAttribute -Name Email) {
		    $nvview.setCustomValue($ca.Name,$email)
		  } else {
		    $ca = New-CustomAttribute -Name Email -TargetType $null -Confirm:$confirm
        $nvview.setCustomValue($ca.Name,$email)
		  }
		
		  if ($ca = Get-CustomAttribute -Name LeadDeveloper) {
		    $nvview.setCustomValue($ca.Name,$vm.LeadDeveloper)
		  } else {
		    $ca = New-CustomAttribute -Name LeadDeveloper -TargetType $null -Confirm:$confirm
		    $nvview.setCustomValue($ca.Name,$vm.LeadDeveloper)
		  }

			if ($ca = Get-CustomAttribute -Name FQDN) {
		    $nvview.setCustomValue($ca.Name,$($vm.Name + "." + $vm.DomainName))
		  } else {
		    $ca = New-CustomAttribute -Name FQDN -TargetType $null -Confirm:$confirm
		    $nvview.setCustomValue($ca.Name,$($vm.Name + "." + $vm.DomainName))
		  }
		
		  # Set memory / CPU / notes via methods on VM View object.  You can't use
		  # set-vm in a background job.
      $notes = $vm.Description + " cloned from " + $vm.Template + " at " + $mmddyyyy
		  $memgb = $vm.MemGB + "GB"
	    $memmb = $memgb / 1MB
		
		  Write-Host Setting CPU and memory for $vm.Name to $memmb MB and $vm.CPUs CPUs.
		  $vmConfigSpec = New-Object VMware.Vim.VirtualMachineConfigSpec
		  $vmConfigSpec.NumCPUs = $vm.CPUs
		  $vmConfigSpec.MemoryMB = $memmb
		  $vmConfigSpec.Annotation = $notes
		  $nvview.ReconfigVM($vmConfigSpec)

	    
      # Power on the VM. Start-VM blocks, too.  Blocked tasks will hang jobs and never return.
		  Write-Host Powering on $vm.Name.
		  $nvview.PowerOnVM($chview.MoRef)
	  } 
  } 
  Write-Host Disconnecting from $connectedserver.
  Disconnect-VIServer -Server $connectedserver -Confirm:$confirm
} 

# Start background jobs and pass work queues to each job
$i = 0

foreach ($jobname in $jobs) {
  if ($queues[$i].length -gt 0) {
    $job = Start-Job -Name $jobname -ScriptBlock $sb -ArgumentList ($queues[$i],$password) -RunAs32
    $jobs_byid.Add($job.Id)
	}
  $i++
}

# Reap jobs and send results of job to report file.
$running = $jobs_byid.Count
$jobsToDelete = New-Object System.Collections.ArrayList

while ($running -gt 0) {
  sleep 1

  foreach ($id in $jobs_byid) {
    $j = Get-Job -Id $id
	  if ($j.State -eq "Completed") {
	    Receive-Job -Id $j.Id | Out-File -Append -FilePath $Env:TEMP\clone-report.txt
	    Remove-Job -Id $j.Id
	    $jobsToDelete.Add($j.Id)
	  }
  }
  
  foreach ($id in $jobsToDelete) {
    $jobs_byid.Remove($id)
  }
  
	$jobsToDelete.Clear()
  $running = $jobs_byid.Count
}
