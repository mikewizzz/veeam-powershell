[CmdletBinding()]
param(
  [switch]$AutoInstallModules,
  [string]$OutputPath = "./out/veeam_compute_network_$(Get-Date -Format yyyy-MM-dd_HHmmss).csv",
  [string[]]$Subscriptions
)

$ErrorActionPreference = 'Stop'

# --- Ensure required Az modules are available ---
$Needed = @('Az.Accounts','Az.Resources','Az.Compute','Az.Network','Az.ResourceGraph')
foreach($m in $Needed){
  if(-not (Get-Module -ListAvailable -Name $m)){
    if($AutoInstallModules){
      try{
        $pg = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
        if(-not $pg -or $pg.InstallationPolicy -ne 'Trusted'){
          Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
        }
        Install-Module $m -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
      } catch { Write-Warning "Failed to install module $m: $($_.Exception.Message)" }
    } else { Write-Warning "Module $m missing. Re-run with -AutoInstallModules to auto-install." }
  }
  Import-Module $m -ErrorAction SilentlyContinue | Out-Null
}

if(-not (Get-AzContext)) { Connect-AzAccount | Out-Null }

# --- Resolve subscriptions ---
if(-not $Subscriptions -or $Subscriptions.Count -eq 0){
  $subs = Get-AzSubscription | Sort-Object -Property Name
} else {
  $subs = foreach($s in $Subscriptions){ Get-AzSubscription -SubscriptionId $s -ErrorAction SilentlyContinue } | Where-Object { $_ }
}

# --- Discover tag keys once using Resource Graph across all selected subs ---
$subIds = @($subs.Id)
$TagKeys = @()
try{
  $q = @"
resources
| where isnotempty(tags)
| mv-expand tagKey = bag_keys(tags)
| summarize by tostring(tagKey)
"@
  $rg = Search-AzGraph -Query $q -First 50000 -Subscription $subIds
  $TagKeys = @($rg.tagKey | Sort-Object -Unique | Where-Object { $_ })
} catch { Write-Verbose 'Tag discovery via Resource Graph failed; will fall back per-resource.' }

function Add-TagColumns {
  param([hashtable]$h,[hashtable]$tags,[string[]]$keys)
  $use = if($keys -and $keys.Count){ $keys } elseif($tags){ @($tags.Keys) } else { @() }
  foreach($k in $use){ $h["Tag: $k"] = ( $tags -and $tags.ContainsKey($k) ) ? ($tags[$k]) : '-' }
}

# --- Collect rows ---
$Rows = @()
foreach($sub in $subs){
  Set-AzContext -SubscriptionId $sub.Id | Out-Null
  Write-Host "Processing subscription: $($sub.Name) ($($sub.Id))" -ForegroundColor Cyan

  $vms = Get-AzVM -Status -ErrorAction Continue
  foreach($vm in $vms){
    # Resolve VM-level tags with fallback to generic resource lookup if needed
    $vmTags = $vm.Tags
    if(-not $vmTags -or $vmTags.Count -eq 0){
      try{ $res = Get-AzResource -ResourceId $vm.Id -ErrorAction Stop; $vmTags = $res.Tags } catch { }
    }

    # NICs (collect all + identify primary from the VM NIC references)
    $nicRefs = @($vm.NetworkProfile.NetworkInterfaces)
    $primaryNicRef = $nicRefs | Where-Object { $_.Primary } | Select-Object -First 1
    if(-not $primaryNicRef){ $primaryNicRef = $nicRefs | Select-Object -First 1 }

    $nicObjs = @()
    foreach($ref in $nicRefs){
      try{ $nicObjs += Get-AzNetworkInterface -ResourceId $ref.Id } catch { }
    }

    $primaryNic = $null
    if($primaryNicRef){
      $primaryNic = $nicObjs | Where-Object { $_.Id -eq $primaryNicRef.Id } | Select-Object -First 1
      if(-not $primaryNic){ $primaryNic = $nicObjs | Select-Object -First 1 }
    }

    # Primary IP config details
    $primaryCfg = $null
    if($primaryNic){ $primaryCfg = @($primaryNic.IpConfigurations) | Where-Object { $_.Primary } | Select-Object -First 1 }
    if(-not $primaryCfg -and $primaryNic){ $primaryCfg = @($primaryNic.IpConfigurations) | Select-Object -First 1 }

    $privateIP = $primaryCfg.PrivateIpAddress
    $subnetId  = $primaryCfg.Subnet.Id

    # Derive VNet/Subnet/Nsg
    $vnetName=$null; $subnetName=$null; $subnetPrefix=$null; $subnetNsg=$null; $rgName=$vm.ResourceGroupName
    if($subnetId){
      $parts = $subnetId -split '/'
      $rgName   = $parts[$parts.IndexOf('resourceGroups')+1]
      $vnetName = $parts[$parts.IndexOf('virtualNetworks')+1]
      $subnetName = $parts[$parts.IndexOf('subnets')+1]
      try{
        $vnet = Get-AzVirtualNetwork -ResourceGroupName $rgName -Name $vnetName -ErrorAction Stop
        $sub  = Get-AzVirtualNetworkSubnetConfig -Name $subnetName -VirtualNetwork $vnet
        $subnetPrefix = ($sub.AddressPrefix | Select-Object -First 1)
        if($sub.NetworkSecurityGroup){ $subnetNsg = $sub.NetworkSecurityGroup.Id.Split('/')[-1] }
      } catch { }
    }

    # Public IP info
    $hasPip = 'No'; $publicIP = $null; $publicIPName=$null; $pipDns=$null
    if($primaryCfg -and $primaryCfg.PublicIpAddress -and $primaryCfg.PublicIpAddress.Id){
      try{
        $pip = Get-AzPublicIpAddress -ResourceId $primaryCfg.PublicIpAddress.Id
        if($pip){ $hasPip='Yes'; $publicIP=$pip.IpAddress; $publicIPName=$pip.Name; $pipDns=$pip.DnsSettings.Fqdn }
      } catch { }
    }

    # Summarize ALL NICs (nicName: vnet/subnet [pip?])
    $nicSummary = @()
    foreach($n in $nicObjs){
      foreach($cfg in $n.IpConfigurations){
        $snId = $cfg.Subnet.Id; $vn=$null; $sn=$null; if($snId){ $p=$snId -split '/'; $vn=$p[$p.IndexOf('virtualNetworks')+1]; $sn=$p[$p.IndexOf('subnets')+1] }
        $pipFlag = if($cfg.PublicIpAddress -and $cfg.PublicIpAddress.Id){ 'pip' } else { 'no-pip' }
        $nicSummary += ("$($n.Name): $vn/$sn [$pipFlag]")
      }
    }
    $nicList = ($nicSummary -join '; ')

    # Disk info
    $osDisk   = $vm.StorageProfile.OsDisk
    $dataDisks= @($vm.StorageProfile.DataDisks)
    $dataSkus = ($dataDisks | ForEach-Object { if($_.ManagedDisk){ $_.ManagedDisk.StorageAccountType } else { 'Unmanaged' } } | Sort-Object -Unique) -join '; ' 
    $diskGiB  = ([int]$osDisk.DiskSizeGB + (($dataDisks | Measure-Object -Property DiskSizeGB -Sum).Sum))

    $h = [ordered]@{
      Subscription   = $sub.Name
      SubscriptionId = $sub.Id
      ResourceGroup  = $vm.ResourceGroupName
      Region         = $vm.Location
      VM             = $vm.Name
      VMSize         = $vm.HardwareProfile.VmSize
      PowerState     = ($vm.Statuses | Where-Object { $_.Code -like 'PowerState*' }).DisplayStatus
      OSDiskSku      = if($osDisk.ManagedDisk){ $osDisk.ManagedDisk.StorageAccountType } else { 'Unmanaged' }
      DataDiskSkus   = $dataSkus
      DiskCount      = (1 + $dataDisks.Count)
      DiskGiB        = $diskGiB
      PrimaryNIC     = if($primaryNic){ $primaryNic.Name } else { $null }
      PrimaryNICNSG  = if($primaryNic.NetworkSecurityGroup){ $primaryNic.NetworkSecurityGroup.Id.Split('/')[-1] } else { $null }
      PrimaryVNet    = $vnetName
      PrimarySubnet  = $subnetName
      PrimarySubnetPrefix = $subnetPrefix
      PrimaryPrivateIP    = $privateIP
      PrimaryHasPublicIP  = $hasPip
      PrimaryPublicIPName = $publicIPName
      PrimaryPublicIP     = $publicIP
      PrimaryPublicFQDN   = $pipDns
      PrimarySubnetNSG    = $subnetNsg
      NICs           = $nicList
    }

    Add-TagColumns -h $h -tags $vmTags -keys $TagKeys
    $Rows += [pscustomobject]$h
  }
}

# Normalize headers across rows (Export-Csv uses first object otherwise)
$Headers = @()
foreach($r in $Rows){ foreach($n in $r.PSObject.Properties.Name){ if(-not ($Headers -contains $n)){ $Headers += $n } } }
$Normalized = foreach($r in $Rows){ $o=[ordered]@{}; foreach($h in $Headers){ $o[$h] = $r.$h }; [pscustomobject]$o }

$dir = Split-Path $OutputPath -Parent
if(-not (Test-Path $dir)){ New-Item -ItemType Directory -Path $dir | Out-Null }
$Normalized | Export-Csv -Path $OutputPath -NoTypeInformation
Write-Host "Wrote $($Rows.Count) VMs to $OutputPath" -ForegroundColor Green

<#
USAGE EXAMPLES
-------------
# Auto-install Az modules (sets PSGallery trusted), all subscriptions
./Get-AzureSizingInfo-Veeam.ps1 -AutoInstallModules

# Specific subscriptions and custom output path
./Get-AzureSizingInfo-Veeam.ps1 -Subscriptions '00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111' -OutputPath './out/azure_sizing.csv'

OUTPUT COLUMNS (partial)
------------------------
Subscription, SubscriptionId, ResourceGroup, Region, VM, VMSize, PowerState,
OSDiskSku, DataDiskSkus, DiskCount, DiskGiB,
PrimaryNIC, PrimaryNICNSG, PrimaryVNet, PrimarySubnet, PrimarySubnetPrefix,
PrimaryPrivateIP, PrimaryHasPublicIP, PrimaryPublicIPName, PrimaryPublicIP, PrimaryPublicFQDN, PrimarySubnetNSG,
NICs, Tag: <key1>, Tag: <key2>, ...
#>
