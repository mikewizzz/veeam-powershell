param(
  [switch]$AutoInstallModules,
  [string]$OutputPath = "./out/veeam_compute_network_$(Get-Date -Format yyyy-MM-dd_HHmmss).csv"
)

$ErrorActionPreference = 'Stop'

$needed = @('Az.Accounts','Az.Resources','Az.Compute','Az.Network','Az.ResourceGraph')
foreach($m in $needed){
  if(-not (Get-Module -ListAvailable -Name $m)){
    if($AutoInstallModules){
      try{
        if((Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue).InstallationPolicy -ne 'Trusted'){
          Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
        }
        Install-Module $m -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
      } catch { Write-Warning "Failed to install module $m: $($_.Exception.Message)" }
    } else { Write-Warning "Module $m missing. Re-run with -AutoInstallModules to auto-install." }
  }
  Import-Module $m -ErrorAction SilentlyContinue | Out-Null
}

if(-not (Get-AzContext)) { Connect-AzAccount | Out-Null }

# Discover tag keys across scope to keep CSV headers consistent
$tagKeys = @()
try{
  $q = @"
resources
| where isnotempty(tags)
| mv-expand k = bag_keys(tags)
| summarize by tostring(k)
"@
  $rg = Search-AzGraph -Query $q -First 50000
  $tagKeys = @($rg.k | Sort-Object -Unique | Where-Object { $_ })
} catch { }

# Helper to add tag columns consistently
function Add-TagColumns {
  param([hashtable]$h,[hashtable]$tags,[string[]]$keys)
  $use = if($keys -and $keys.Count){ $keys } elseif($tags){ @($tags.Keys) } else { @() }
  foreach($k in $use){ $h["Tag: $k"] = ( $tags -and $tags.ContainsKey($k) ) ? $tags[$k] : '-' }
}

$rows = @()
$vms = Get-AzVM -Status
foreach($vm in $vms){
  # Primary NIC
  $nicIds = @($vm.NetworkProfile.NetworkInterfaces | ForEach-Object { $_.Id })
  $nicObjs = @(); foreach($id in $nicIds){ try{ $nicObjs += Get-AzNetworkInterface -ResourceId $id } catch {} }
  $primaryNic = $nicObjs | Where-Object { $_.Primary } | Select-Object -First 1
  if(-not $primaryNic){ $primaryNic = $nicObjs | Select-Object -First 1 }

  $ipcfgs = @(); if($primaryNic){ $ipcfgs = @($primaryNic.IpConfigurations) }
  $primaryCfg = $ipcfgs | Where-Object { $_.Primary } | Select-Object -First 1
  if(-not $primaryCfg){ $primaryCfg = $ipcfgs | Select-Object -First 1 }

  $privateIP = $primaryCfg.PrivateIpAddress
  $subnetId  = $primaryCfg.Subnet.Id
  $vnetName = $null; $subnetName=$null; $subnetPrefix=$null; $subnetNsg=$null
  if($subnetId){
    $parts = $subnetId -split '/'
    $vnetName   = $parts[$parts.IndexOf('virtualNetworks')+1]
    $subnetName = $parts[$parts.IndexOf('subnets')+1]
    try{
      $rgName = $parts[$parts.IndexOf('resourceGroups')+1]
      $sub = Get-AzVirtualNetworkSubnetConfig -Name $subnetName -VirtualNetwork (Get-AzVirtualNetwork -ResourceGroupName $rgName -Name $vnetName)
      $subnetPrefix = ($sub.AddressPrefix | Select-Object -First 1)
      if($sub.NetworkSecurityGroup){ $subnetNsg = $sub.NetworkSecurityGroup.Id.Split('/')[-1] }
    } catch {}
  }

  $hasPip = 'No'; $publicIP = $null; $publicIPName=$null; $pipDns=$null
  if($primaryCfg -and $primaryCfg.PublicIpAddress -and $primaryCfg.PublicIpAddress.Id){
    try{
      $pip = Get-AzPublicIpAddress -ResourceId $primaryCfg.PublicIpAddress.Id
      if($pip){ $hasPip='Yes'; $publicIP=$pip.IpAddress; $publicIPName=$pip.Name; $pipDns=$pip.DnsSettings.Fqdn }
    } catch {}
  }

  $osDisk = $vm.StorageProfile.OsDisk
  $dataDisks = @($vm.StorageProfile.DataDisks)
  $dataSkus = ($dataDisks | ForEach-Object { if($_.ManagedDisk){ $_.ManagedDisk.StorageAccountType } else { 'Unmanaged' } } | Sort-Object -Unique) -join '; ' 

  $h = [ordered]@{
    Subscription   = (Get-AzContext).Subscription.Name
    SubscriptionId = (Get-AzContext).Subscription.Id
    ResourceGroup  = $vm.ResourceGroupName
    Region         = $vm.Location
    VM             = $vm.Name
    VMSize         = $vm.HardwareProfile.VmSize
    PowerState     = ($vm.Statuses | Where-Object { $_.Code -like 'PowerState*' }).DisplayStatus
    OSDiskSku      = if($osDisk.ManagedDisk){ $osDisk.ManagedDisk.StorageAccountType } else { 'Unmanaged' }
    DataDiskSkus   = $dataSkus
    DiskCount      = (1 + $dataDisks.Count)
    DiskGiB        = ([int]$osDisk.DiskSizeGB + (($dataDisks | Measure-Object -Property DiskSizeGB -Sum).Sum))
    PrivateIP      = $privateIP
    VNet           = $vnetName
    Subnet         = $subnetName
    SubnetPrefix   = $subnetPrefix
    NIC            = if($primaryNic){ $primaryNic.Name } else { $null }
    NICNSG         = if($primaryNic.NetworkSecurityGroup){ $primaryNic.NetworkSecurityGroup.Id.Split('/')[-1] } else { $null }
    SubnetNSG      = $subnetNsg
    HasPublicIP    = $hasPip
    PublicIPName   = $publicIPName
    PublicIP       = $publicIP
    PublicIPFQDN   = $pipDns
  }
  Add-TagColumns -h $h -tags $vm.Tags -keys $tagKeys
  $rows += [pscustomobject]$h
}

# Normalize headers so all tag columns appear even if first row lacks them
$headers = @()
foreach($r in $rows){ foreach($n in $r.PSObject.Properties.Name){ if(-not ($headers -contains $n)){ $headers += $n } } }
$norm = foreach($r in $rows){
  $o = [ordered]@{}; foreach($h in $headers){ $o[$h] = $r.$h }; [pscustomobject]$o
}

$dir = Split-Path $OutputPath -Parent
if(-not (Test-Path $dir)){ New-Item -ItemType Directory -Path $dir | Out-Null }
$norm | Export-Csv -Path $OutputPath -NoTypeInformation
Write-Host "Wrote $($rows.Count) VMs to $OutputPath" -ForegroundColor Green
