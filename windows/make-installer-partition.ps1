<#
.SYNOPSIS
  Builds a bootable Ubuntu Server autoinstaller on a spare FAT32 partition, so no USB stick is needed.

.DESCRIPTION
  Run from Windows, as Administrator, on the machine you are about to turn into a GPU node.
  1. Shrinks -ShrinkDrive by -SizeGB and creates a FAT32 partition labelled UBUNTUINST on that disk
     (or reuses it if it already exists).
  2. Unpacks the Ubuntu ISO onto it.
  3. Copies autoinstall/ + firstboot/ into \nocloud, with __TARGET_DISK_SERIAL__ replaced.
  4. Adds an "AUTOINSTALL GPU node" entry at the top of the boot menu.
  Then reboot, press the firmware boot-menu key (F8 on ASUS), pick "UEFI: <installer disk>, Partition N".

  The installer partition must live on a disk you are NOT installing to (the target disk is wiped).

.EXAMPLE
  # list disks and serials first
  Get-PhysicalDisk | Select-Object DeviceId, FriendlyName, MediaType, SerialNumber
  .\make-installer-partition.ps1 -Iso D:\ubuntu-24.04.5-live-server-amd64.iso `
      -ShrinkDrive D -InstallerDiskSerial WD-WMAYUP101743 -TargetDiskSerial S2RANX0H710744R
#>
param(
    [Parameter(Mandatory)] [string]$Iso,
    [Parameter(Mandatory)] [char]$ShrinkDrive,           # NTFS volume to take space from (on the installer disk)
    [Parameter(Mandatory)] [string]$InstallerDiskSerial, # disk that holds $ShrinkDrive; safety check
    [Parameter(Mandatory)] [string]$TargetDiskSerial,    # SSD that Ubuntu will be installed to (gets wiped)
    [int]$SizeGB = 6,
    [string]$Log = "$env:PUBLIC\make-installer-partition.log"
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Start-Transcript -Path $Log -Force | Out-Null
try {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw 'Run this from an elevated (Administrator) PowerShell.' }

    $srcPart = Get-Partition -DriveLetter $ShrinkDrive
    $disk = Get-Disk -Number $srcPart.DiskNumber
    if ($disk.SerialNumber.Trim() -ne $InstallerDiskSerial) { throw "Drive ${ShrinkDrive}: is on disk serial '$($disk.SerialNumber.Trim())', expected '$InstallerDiskSerial'. Aborting." }
    if ($InstallerDiskSerial -eq $TargetDiskSerial) { throw 'Installer disk and target disk must be different (the target gets wiped).' }
    if (-not (Get-PhysicalDisk | Where-Object { $_.SerialNumber.Trim() -eq $TargetDiskSerial })) { throw "No disk with serial '$TargetDiskSerial' found." }

    $part = Get-Partition -DiskNumber $disk.Number | Where-Object { ($_ | Get-Volume -ErrorAction SilentlyContinue).FileSystemLabel -eq 'UBUNTUINST' }
    if ($part) {
        "reusing existing UBUNTUINST partition #$($part.PartitionNumber)"
    } else {
        $sup = Get-PartitionSupportedSize -DriveLetter $ShrinkDrive
        $newSize = $srcPart.Size - ([int64]$SizeGB * 1GB)
        if ($newSize -lt $sup.SizeMin) { throw "Cannot shrink ${ShrinkDrive}: by $SizeGB GB (minimum size $([int]($sup.SizeMin/1GB)) GB)." }
        "shrinking ${ShrinkDrive}: to $([math]::Round($newSize/1GB,1)) GB"
        Resize-Partition -DriveLetter $ShrinkDrive -Size $newSize
        $mbr = $disk.PartitionStyle -eq 'MBR'
        $part = if ($mbr) { New-Partition -DiskNumber $disk.Number -UseMaximumSize -MbrType FAT32 -AssignDriveLetter }
                else      { New-Partition -DiskNumber $disk.Number -UseMaximumSize -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' -AssignDriveLetter }
        Start-Sleep -Seconds 3
        Format-Volume -Partition $part -FileSystem FAT32 -NewFileSystemLabel 'UBUNTUINST' -Confirm:$false | Out-Null
    }
    $part = Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber
    if (-not $part.DriveLetter -or $part.DriveLetter -eq [char]0) {
        $part | Add-PartitionAccessPath -AssignDriveLetter
        $part = Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber
    }
    $T = "$($part.DriveLetter):"
    "installer partition: $T (disk $($disk.Number) partition $($part.PartitionNumber), $([math]::Round($part.Size/1GB,1)) GB)"

    $img = Mount-DiskImage -ImagePath $Iso -PassThru
    try {
        $src = ($img | Get-Volume).DriveLetter + ':'
        "copying ISO from $src ..."
        robocopy "$src\" "$T\" /E /R:1 /W:1 /NP /NFL /NDL | Select-Object -Last 8
    } finally { Dismount-DiskImage -ImagePath $Iso | Out-Null }
    attrib -R "$T\*" /S /D

    # nocloud seed: autoinstall config + first-boot files, with the target serial filled in
    $nc = "$T\nocloud"
    New-Item -ItemType Directory -Force -Path $nc | Out-Null
    $ud = (Get-Content "$repo\autoinstall\user-data" -Raw).Replace('__TARGET_DISK_SERIAL__', $TargetDiskSerial)
    $lf = { param($p, $s) [IO.File]::WriteAllText($p, $s.Replace("`r`n", "`n")) }
    & $lf "$nc\user-data" $ud
    & $lf "$nc\meta-data" (Get-Content "$repo\autoinstall\meta-data" -Raw)
    & $lf "$nc\gpu-node-setup.sh" (Get-Content "$repo\firstboot\gpu-node-setup.sh" -Raw)
    & $lf "$nc\gpu-node-setup.service" (Get-Content "$repo\firstboot\gpu-node-setup.service" -Raw)

    $cfgPath = "$T\boot\grub\grub.cfg"
    $cfg = Get-Content $cfgPath -Raw
    if ($cfg -notmatch 'AUTOINSTALL GPU node') {
        # nomodeset: stock nouveau predates RTX 50 and blanks the screen ("out of range"); stay on the firmware framebuffer
        $entry = "menuentry `"AUTOINSTALL GPU node (erases disk $TargetDiskSerial only, asks to confirm)`" {`n`tset gfxpayload=keep`n`tlinux`t/casper/vmlinuz nomodeset ds=nocloud\;s=/cdrom/nocloud/ ---`n`tinitrd`t/casper/initrd`n}`n" +
                 "menuentry `"AUTOINSTALL GPU node - fallback: HWE kernel`" {`n`tset gfxpayload=keep`n`tlinux`t/casper/hwe-vmlinuz nomodeset ds=nocloud\;s=/cdrom/nocloud/ ---`n`tinitrd`t/casper/hwe-initrd`n}`n"
        $i = $cfg.IndexOf('menuentry')
        & $lf $cfgPath ($cfg.Substring(0, $i) + $entry + $cfg.Substring($i))
    }
    if (-not (Test-Path "$T\EFI\boot\bootx64.efi")) { throw 'EFI loader missing after copy.' }
    'RESULT=OK  Reboot, open the firmware boot menu, and pick the UEFI entry for this partition.'
} catch {
    "RESULT=FAIL $_"
    exit 1
} finally { Stop-Transcript | Out-Null }
