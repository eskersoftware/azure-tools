Param
(
    [Parameter(Mandatory = $true)] [string] $ResourceGroupName,
    [Parameter(Mandatory = $true)] [string] $VMName,
    [Parameter(Mandatory = $true)] [string] $SnapshotTag,
    [Parameter(Mandatory = $false)] [int] $ExcludeDiskLUN,
    [Parameter(Mandatory = $false)] [string] $DefaultStorageType = "Standard_LRS"
)

if ((Get-AzureRMContext) -eq $null) {
    Write-Error "No Azure context found, you need to login with Connect-AzureRmAccount before launching this script !"
    Exit -1
}

Write-Verbose "Check status of VM named $VMName in the resource group $ResourceGroupName ..."
$VM = Get-AzureRmVm -ResourceGroupName $ResourceGroupName -Name $VMName -Status
if ($VM -eq $null) {
    Write-Error "Could not find a vm named : $VMName in resource group : $ResourceGroupName"
    Exit -2
}

function CreateDiskFromSnapshot($SnapshotName, $DiskName) {
    $snapshot = Get-AzureRmSnapshot -ResourceGroupName $ResourceGroupName -SnapshotName $SnapshotName
    if ($snapshot -eq $null) {
        Write-Verbose "$SnapshotName was not found, stopping"
        Exit -4
    }

    $diskConfig = New-AzureRmDiskConfig -Location $snapshot.Location `
        -SourceResourceId $snapshot.Id -CreateOption Copy
    return New-AzureRmDisk -Disk $diskConfig -ResourceGroupName $ResourceGroupName -DiskName $DiskName
}

if (!($VM.Statuses.code.Contains("PowerState/stopped") `
            -or $VM.Statuses.code.Contains("PowerState/deallocated"))) {
    Write-Error "VM should be either stopped or deallocated but is neither"
    Exit -3
}

Write-Verbose "Finding VM named $VMName in the resource group $ResourceGroupName ..."
# Object returned by Get-AzureRmVm -Status is not the same as the one returned
# by Get-AzureRMVM so retrieve the VM once again
$VM = Get-AzureRmVm -ResourceGroupName $ResourceGroupName -Name $VMName

Write-Verbose "Restoring snapshot tagged $SnapshotTag on VM $($VM.Name)"

$SnapshotNamePrefix = "$($VM.Name)-Snap-$SnapshotTag"
$OSDiskName = "$($VM.Name)-$SnapshotTag-OSDisk"
$OSDisk = Get-AzureRmDisk -ResourceGroupName $ResourceGroupName -DiskName $OSDiskName -ErrorAction SilentlyContinue
if ($OSDisk -eq $null) {
    Write-Verbose "Creating OSDisk $OSDiskName from snapshot"
    $SnapshotName = "$SnapshotNamePrefix-OSDisk"
    $OSDisk = CreateDiskFromSnapshot -SnapshotName $SnapshotName -DiskName $OSDiskName
}
else {
    Write-Verbose "Found already existing OSDisk named $OSDiskName"
}

Write-Verbose "Switching OSDisk (not applied yet)"
$VM = Set-AzureRmVMOSDisk -VM $VM -ManagedDiskId $OSDisk.Id -Name $OSDisk.Name

$dataDisksToRestore = $VM.StorageProfile.DataDisks
if ($PSBoundParameters.ContainsKey("ExcludeDiskLUN")) {
    Write-Verbose "Removing disk with LUN: $ExcludeDiskLUN from list of disks to snapshot"
    $dataDisksToRestore = $dataDisksToRestore | Where-Object { $_.Lun -ne $ExcludeDiskLUN }
}

foreach ($dataDisk in $dataDisksToRestore) {
    $dataDiskLun = $dataDisk.Lun
    $newStorageType = $dataDisk.ManagedDisk.StorageAccountType
    if (($newStorageType -eq $null) -or ($newStorageType -eq "")) {
        # StorageAccountType isn't available when machine is deallocated :(
        Write-Warning "Unable to determine previous storage type, fallbacking to $DefaultStorageType"
        $newStorageType = $DefaultStorageType
    }

    $newDataDiskName = "$($VM.Name)-$SnapshotTag-DataDisk-$dataDiskLun"
    $newDataDisk = Get-AzureRmDisk -ResourceGroupName $ResourceGroupName `
        -DiskName $newDataDiskName -ErrorAction SilentlyContinue
    if ($newDataDisk -eq $null) {
        Write-Verbose "Creating data disk $newDataDiskName from snapshot"
        $SnapshotName = "$SnapshotNamePrefix-DataDisk-$dataDiskLun"
        $newDataDisk = CreateDiskFromSnapshot -SnapshotName $SnapshotName -DiskName $newDataDiskName
    }
    else {
        Write-Verbose "Found already existing data disk named $newDataDiskName"
    }

    Write-Verbose "Detach data disk $($dataDisk.Name) from VM"
    $VM = Remove-AzureRmVMDataDisk -VM $VM -DataDiskNames $dataDisk.Name

    Write-Verbose "Update VM to take into account data disk removal (also updates pending changes)"
    $null = Update-AzureRmVM -ResourceGroupName $ResourceGroupName -VM $VM

    Write-Verbose "Adding new data disk $($newDataDisk.Name) (not applied yet)"
    $VM = Add-AzureRmVMDataDisk -VM $VM -Lun $dataDiskLun -Name $newDataDisk.Name `
        -CreateOption Attach -StorageAccountType $newStorageType -ManagedDiskId $newDataDisk.Id  
}

Write-Verbose "Updating VM"
$null = Update-AzureRmVM -ResourceGroupName $ResourceGroupName -VM $VM
Write-Verbose "VM updated"

return 0