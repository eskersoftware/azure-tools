Param
(
    [Parameter(Mandatory = $true)] [string] $ResourceGroupName,
    [Parameter(Mandatory = $true)] [string] $VMName,
    [Parameter(Mandatory = $true)] [string] $SnapshotTag,
    [Parameter(Mandatory = $false)] [int] $ExcludeDiskLUN,
    [Parameter(Mandatory = $false)] [switch] $ForceOverwrite,
    [Parameter(Mandatory = $false)] [hashtable] $AzureTags
)

if ((Get-AzureRmContext) -eq $null) {
    Write-Error "No Azure context found, you need to login with Connect-AzureRmAccount before launching this script !"
    Exit -1
}

Write-Verbose "Finding VM named $VMName in the resource group $ResourceGroupName ..."
$VM = Get-AzureRmVM -ResourceGroupName $ResourceGroupName -Name $VMName
if ($VM -eq $null) {
    Write-Error "Could not find a vm named : $VMName in resource group : $ResourceGroupName"
    Exit -2
}

function CheckSnapOverwriting($SnapshotName) {
    $snapshot = Get-AzureRmSnapshot -ResourceGroupName $ResourceGroupName -SnapshotName $SnapshotName -ErrorAction SilentlyContinue
    if ($snapshot -ne $null) {
        Write-Warning "There is already an existing snapshot named $SnapshotName"
        Write-Warning "Time created: $($snapshot.TimeCreated)"
        if ($ForceOverwrite) {
            Write-Verbose "Removing previous snapshot..."
            $null = Remove-AzureRmSnapshot -ResourceGroupName $ResourceGroupName -SnapshotName $SnapshotName -Force
            Write-Verbose "Removed"
        }
		else {
			Write-Error "There is already an existing snapshot named $SnapshotName and ForceOverwrite switch was not set"
            Exit -3
        }
    }
}

function SnapshotDisk($DiskName, $DiskId, $SnapshotName, $Location) {
	CheckSnapOverwriting $SnapshotName
	Write-Verbose "Create $DiskName snapshot: $SnapshotName"

	$snapshotConfig = New-AzureRmSnapshotConfig -SourceUri $DiskId -Location $Location -CreateOption Copy
	$snapshot = New-AzureRmSnapshot -Snapshot $snapshotConfig -SnapshotName $SnapshotName -ResourceGroupName $ResourceGroupName

	if($Script:PSBoundParameters.ContainsKey("AzureTags")) {
		$null = Set-AzureRmResource -ResourceId $snapshot.Id -Tag $AzureTags -Force
	}
}

$SnapshotNamePrefix = "$($VM.Name)-Snap-$SnapshotTag"
Write-Verbose "Snapshotting $VMName disks with prefix $SnapshotNamePrefix"

Write-Verbose "OSDisk:"
$OSDiskSnapshotName = "$SnapshotNamePrefix-OSDisk"
$OSDisk = $VM.StorageProfile.OsDisk
SnapshotDisk -DiskName $OSDisk.Name -DiskId $OSDisk.ManagedDisk.Id -SnapshotName $OSDiskSnapshotName -Location $VM.Location

Write-Verbose "Data Disks:"
$dataDisksToSnapshot = $VM.StorageProfile.DataDisks
if($PSBoundParameters.ContainsKey("ExcludeDiskLUN")) {
	Write-Verbose "Removing disk with LUN: $ExcludeDiskLUN from list of disks to snapshot"
	$dataDisksToSnapshot = $dataDisksToSnapshot | Where-Object { $_.Lun -ne $ExcludeDiskLUN }
}

$dataDisksToSnapshot | ForEach-Object {
    $diskId = $_.Lun
    $DataDiskSnapshotName = "$SnapshotNamePrefix-DataDisk-$diskId"
	SnapshotDisk -DiskName $_.Name -DiskId $_.ManagedDisk.Id -SnapshotName $DataDiskSnapshotName -Location $VM.Location
}

Write-Verbose "End of script"

return 0