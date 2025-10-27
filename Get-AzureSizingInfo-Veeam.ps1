#requires -Version 7.0
#requires -Modules Az.Accounts, Az.Aks, Az.Compute, Az.Network, Az.Storage, Az.Sql, Az.SqlVirtualMachine, Az.ResourceGraph, Az.Monitor, Az.Resources, Az.RecoveryServices, Az.CosmosDB, Az.CostManagement
<#
.SYNOPSIS
  Azure inventory & metrics tailored for Veeam sizing (VBA, VBR NAS/Agents, Kasten K10).

.DESCRIPTION
  Collects VM & disk footprints (+ NIC/vNET/subnet & public IPs), Storage Accounts (Blob/File metrics),
  optional per-container stats, AKS & node pools, Azure Files shares, optional Azure SQL (DB/MI) and Cosmos DB
  outlines/metrics, and Azure Backup vaults, policies & protected items. Optional monthly cost insights.
  Outputs CSVs plus a summary, planners, and a manifest—zipped.

  v1.3.6 defaults to showing **ALL tag keys** encountered (global discovery ∪ per-object tags), so Tag:* columns
  appear in CSVs even when tags vary by object.

.PARAMETER Source
  All | Current | Subscriptions | SubscriptionIds | ManagementGroups

.PARAMETER Subscriptions
  One or more subscription display names (when -Source Subscriptions)

.PARAMETER SubscriptionIds
  One or more subscription IDs (when -Source SubscriptionIds)

.PARAMETER ManagementGroups
  One or more Azure Management Group names (when -Source ManagementGroups)

.PARAMETER Scope
  Compute, Storage, Databases, Kubernetes, Backup, Cosmos, Identity  (default: all)

.PARAMETER DeepContainers
  Traverse each blob container to compute hot/cool/archive/unknown bytes & counts.

.PARAMETER DeepBackup
  Enumerate Azure Backup policies and protected items per vault & workload type.

.PARAMETER DeepCosmos
  Pull Cosmos DB account-level metrics (DocumentCount, DataUsage, PhysicalPartitionSizeInfo, PhysicalPartitionCount, IndexUsage).

.PARAMETER CostInsights
  Include monthly cost insights for -CostServices over -CostMonths (max 12).

.PARAMETER CostMonths
  Cost lookback window in months (max 12, default 12).

.PARAMETER CostServices
  ServiceName filters for cost (default: "Backup"). Provide one or more service names.

.PARAMETER Parallel
  Degree of parallelism for per-subscription processing (default: 6)

.PARAMETER Anonymize
  Anonymize identifiers (resource names, ids, RGs, subscription names, tenant, etc.) using salted SHA256.

.PARAMETER AnonymizeSalt
  Salt for anonymization. If omitted, a random in-memory salt is used (non-repeatable across runs).

.PARAMETER ChangeRatePercent
  Estimated daily change rate (%) for repo sizing heuristic (default: 3)

.PARAMETER RetentionDays
  Daily restore points retained (default: 30)

.PARAMETER CompressionRatio
  Effective compression+dedupe ratio for repo sizing heuristic (default: 0.6)

.PARAMETER PlannerTag
  Tag key to generate a tag-grouped planner (e.g., Environment, App, BU). Default: 'Environment'

.NOTES
  Author: Michael Wisniewski
  Version: 1.3.6 (2025-10-27)
  – Fixes subscription/subnet variable collision
  – Shows ALL tag keys by default (global ∪ per-object)
  – Keeps subnet + public IP details for VMs
#>

[CmdletBinding()]
param(
  [ValidateSet('All','Current','Subscriptions','SubscriptionIds','ManagementGroups')]
  [string]$Source = 'All',

  [string[]]$Subscriptions,
  [string[]]$SubscriptionIds,
  [string[]]$ManagementGroups,

  [ValidateSet('Compute','Storage','Databases','Kubernetes','Backup','Cosmos','Identity')]
  [string[]]$Scope = @('Compute','Storage','Databases','Kubernetes','Backup','Cosmos','Identity'),

  [switch]$DeepContainers,
  [switch]$DeepBackup,
  [switch]$DeepCosmos,

  [switch]$CostInsights,
  [ValidateRange(1,12)][int]$CostMonths = 12,
  [string[]]$CostServices = @('Backup'),

  [int]$Parallel = 6,

  [switch]$Anonymize,
  [string]$AnonymizeSalt,

  [double]$ChangeRatePercent = 3,
  [int]$RetentionDays = 30,
  [double]$CompressionRatio = 0.6,

  [string]$PlannerTag = 'Environment'
)

# ---------------- init & helpers ----------------
$ErrorActionPreference = 'Stop'
$start    = Get-Date
$runStamp = $start.ToString('yyyy-MM-dd_HHmmss')
$outDir   = Join-Path -Path "." -ChildPath "out"
if (!(Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

$logFile  = Join-Path $outDir "veeam_run_$runStamp.log.jsonl"
function Write-Log {
  param([string]$Level='INFO',[string]$Message,[hashtable]$Data)
  $obj = [ordered]@{
    ts     = (Get-Date).ToString('o')
    level  = $Level
    msg    = $Message
    data   = $Data
  } | ConvertTo-Json -Depth 6
  Add-Content -Path $logFile -Value $obj
  if($Level -in 'WARN','ERROR'){ Write-Host "[$Level] $Message" -ForegroundColor Yellow } else { Write-Host $Message }
}

# CSV helper (normalizes columns across rows)
function Save-Csv {
  param([Parameter(Mandatory)][array]$Data,[Parameter(Mandatory)][string]$Path,[switch]$NoTypeInfo)
  if($Data -and $Data.Count -gt 0){
    $headers = New-Object System.Collections.Generic.HashSet[string]
    foreach($r in $Data){ foreach($n in $r.PSObject.Properties.Name){ [void]$headers.Add($n) } }
    $norm = foreach($r in $Data){ $o=[ordered]@{}; foreach($h in $headers){ $o[$h]=$r.$h }; [pscustomobject]$o }
    if($NoTypeInfo){ $norm | Export-Csv -Path $Path -NoTypeInformation } else { $norm | Export-Csv -Path $Path }
    Write-Log -Message "Wrote $($Data.Count) rows -> $Path"
    return $true
  } else { Write-Log -Level 'WARN' -Message "No rows to write for $Path"; return $false }
}

# culture guard for numeric formatting
$origCulture = [System.Globalization.CultureInfo]::CurrentCulture
[Threading.Thread]::CurrentThread.CurrentCulture  = 'en-US'
[Threading.Thread]::CurrentThread.CurrentUICulture= 'en-US'

# anonymization (salted SHA256 -> 10 chars)
$script:Anonymize = [bool]$Anonymize
$anonSalt = if($Anonymize){ if($AnonymizeSalt){ $AnonymizeSalt } else { [guid]::NewGuid().Guid } } else { '' }
$sha256   = [System.Security.Cryptography.SHA256]::Create()
function Anon {
  param([object]$Value)
  if(-not $script:Anonymize){ return $Value }
  if($null -eq $Value){ return $null }
  $s = "$($Value.ToString())|$($anonSalt)"
  $bytes = [Text.Encoding]::UTF8.GetBytes($s)
  $hash  = $sha256.ComputeHash($bytes)
  $hex   = -join ($hash | ForEach-Object { $_.ToString("x2") })
  return "anon-$($hex.Substring(0,10))"
}

# ---------------- subscription resolution ----------------
try { $ctx = Get-AzContext } catch { }
if(-not $ctx){ Connect-AzAccount | Out-Null; $ctx = Get-AzContext }

function Resolve-Subscriptions {
  switch($Source){
    'Current'           { return ,(Get-AzSubscription -SubscriptionId $ctx.Subscription.Id) }
    'Subscriptions'     { return $Subscriptions     | ForEach-Object { Get-AzSubscription -SubscriptionName $_ } }
    'SubscriptionIds'   { return $SubscriptionIds   | ForEach-Object { Get-AzSubscription -SubscriptionId  $_ } }
    'ManagementGroups'  {
      $all = @()
      foreach($mg in $ManagementGroups){
        $names = (Search-AzGraph -Query "resourcecontainers | where type =~ 'microsoft.resources/subscriptions'" -ManagementGroup $mg).name
        $all  += $names | ForEach-Object { Get-AzSubscription -SubscriptionName $_ }
      }
      return $all
    }
    Default             { return Get-AzSubscription }
  }
}
$subs = @(Resolve-Subscriptions)
if(-not $subs){ throw "No subscriptions resolved with -Source $Source" }
Write-Log -Message "Resolved subscriptions" -Data @{ count = $subs.Count; source = $Source }

$scopes = $Scope

# ---------------- per-subscription work (parallel) ----------------
$allRows = $subs | ForEach-Object -Parallel {
  param($using:scopes,$using:DeepContainers,$using:DeepBackup,$using:DeepCosmos,
        $using:CostInsights,$using:CostMonths,$using:CostServices,
        $using:ChangeRatePercent,$using:RetentionDays,$using:CompressionRatio,
        $using:Anonymize,$using:anonSalt,$using:PlannerTag)

  # local helpers in runspace
  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  function Anon {
    param([object]$Value)
    if(-not $using:Anonymize){ return $Value }
    if($null -eq $Value){ return $null }
    $s = "$($Value.ToString())|$($using:anonSalt)"
    $bytes = [Text.Encoding]::UTF8.GetBytes($s)
    $hash  = $sha256.ComputeHash($bytes)
    $hex   = -join ($hash | ForEach-Object { $_.ToString("x2") })
    return "anon-$($hex.Substring(0,10))"
  }

  $metricDefCache = @{}
  function Get-MetricLastMax {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ResourceId,[Parameter(Mandatory)][string]$MetricName)
    try {
      if (-not $metricDefCache.ContainsKey($ResourceId)) {
        try { $defs = Get-AzMetricDefinition -ResourceId $ResourceId -ErrorAction Stop }
        catch { return 0 }
        $metricDefCache[$ResourceId] = $defs
      } else {
        $defs = $metricDefCache[$ResourceId]
      }
      if (-not $defs){ return 0 }
      $def = $defs | Where-Object { $_.Name.Value -eq $MetricName -or $_.Name.Value -ieq $MetricName } | Select-Object -First 1
      if (-not $def) { $def = $defs | Where-Object { $_.Name.Value -like "*$MetricName*" } | Select-Object -First 1 }
      if (-not $def) { return 0 }
      $ns = $def.MetricNamespaceName; if(-not $ns){ $ns = $def.Namespace }
      $args = @{ ResourceId=$ResourceId; MetricName=$def.Name.Value; AggregationType='Maximum'; StartTime=(Get-Date).AddDays(-1); ErrorAction='Stop'; WarningAction='SilentlyContinue' }
      if ($ns) { $args.MetricNamespace = $ns }
      $m = Get-AzMetric @args
      if (-not $m -or -not $m.Data -or -not $m.Data.Maximum) { return 0 }
      [double](($m.Data.Maximum | Select-Object -Last 1) ?? 0)
    } catch { 0 }
  }

  function Merge-Tags { param([hashtable[]]$TagSets) $m=@{}; foreach($t in $TagSets){ if($t){ foreach($k in $t.Keys){ $m[$k]=$t[$k] } } } $m }

  function Add-TagColumns {
    param(
      [hashtable]$h,
      [hashtable]$tags,
      [string[]]$globalKeys,
      [string]$Prefix = 'Tag: '
    )
    # Always include ALL keys = (global discovery ∪ object keys)
    $objKeys = @(); if($tags){ $objKeys = @($tags.Keys | Where-Object { $_ }) }
    $useKeys = @($globalKeys + $objKeys | Sort-Object -Unique)
    foreach($k in $useKeys){ $h["$Prefix$k"] = ( $tags -and $tags.ContainsKey($k) ) ? $tags[$k] : '-' }
    # Good to keep a raw JSON too for validation/debugging:
    if($tags){ $h["TagsJson"] = ($tags | ConvertTo-Json -Depth 4 -Compress) } else { $h["TagsJson"] = $null }
  }

  $out = @()

  # lock subscription identity BEFORE any other lookups
  $azSubObj       = $_
  Set-AzContext -SubscriptionId $azSubObj.SubscriptionId | Out-Null
  $azSubName      = $azSubObj.Name
  $azSubId        = $azSubObj.SubscriptionId
  $azTenantName   = (Get-AzTenant -TenantId $azSubObj.TenantId).DisplayName

  # -------- tag key discovery (global) --------
  $globalTagKeys = @()
  try{
    $q = @"
resources
| where isnotempty(tags)
| mv-expand k = bag_keys(tags)
| summarize by tostring(k)
"@
    $rg = Search-AzGraph -Query $q -First 100000 -Subscription $azSubId
    $globalTagKeys = @($rg.k | Sort-Object -Unique | Where-Object { $_ })
  } catch { $globalTagKeys = @() }

  # ==================== Compute (VMs + NIC/VNET/SUBNET/PIP) ====================
  if('Compute' -in $using:scopes){
    try{
      $vms = Get-AzVM -Status -ErrorAction SilentlyContinue
      $sqlVms = @(); try{ $sqlVms = Get-AzSqlVM -ErrorAction SilentlyContinue } catch {}
      $sqlNames = @($sqlVms | ForEach-Object Name)

      foreach($vm in $vms){
        $rgName = $vm.ResourceGroupName
        $rgObj  = $null; try{ $rgObj = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue } catch {}
        $rgTags = ($rgObj?.Tags)

        $vmTags = $vm.Tags
        if(-not $vmTags -or $vmTags.Count -eq 0){
          try{ $res = Get-AzResource -ResourceId $vm.Id -ErrorAction Stop; $vmTags = $res.Tags } catch {}
        }

        # NICs
        $nicRefs = @($vm.NetworkProfile.NetworkInterfaces)
        $primaryNicRef = $nicRefs | Where-Object { $_.Primary } | Select-Object -First 1
        if(-not $primaryNicRef){ $primaryNicRef = $nicRefs | Select-Object -First 1 }

        $nicObjs = @()
        foreach($ref in $nicRefs){ try{ $nicObjs += Get-AzNetworkInterface -ResourceId $ref.Id } catch { } }
        $primaryNic = $null
        if($primaryNicRef){
          $primaryNic = $nicObjs | Where-Object { $_.Id -eq $primaryNicRef.Id } | Select-Object -First 1
          if(-not $primaryNic){ $primaryNic = $nicObjs | Select-Object -First 1 }
        }
        $nicTags = $primaryNic?.Tags

        # Primary IP config & subnet/vnet
        $primaryCfg = $null
        if($primaryNic){ $primaryCfg = @($primaryNic.IpConfigurations) | Where-Object { $_.Primary } | Select-Object -First 1 }
        if(-not $primaryCfg -and $primaryNic){ $primaryCfg = @($primaryNic.IpConfigurations) | Select-Object -First 1 }

        $privateIP = $primaryCfg.PrivateIpAddress
        $subnetId  = $primaryCfg.Subnet.Id

        $vnetName=$null; $subnetName=$null; $subnetPrefix=$null; $subnetNsg=$null; $vnetTags=$null; $subnetTags=$null
        if($subnetId){
          $parts = $subnetId -split '/'
          $vnetRg     = $parts[$parts.IndexOf('resourceGroups')+1]
          $vnetName   = $parts[$parts.IndexOf('virtualNetworks')+1]
          $subnetName = $parts[$parts.IndexOf('subnets')+1]
          try{
            $vnet = Get-AzVirtualNetwork -ResourceGroupName $vnetRg -Name $vnetName -ErrorAction Stop
            $vnetTags = $vnet.Tags
            $snCfg  = Get-AzVirtualNetworkSubnetConfig -Name $subnetName -VirtualNetwork $vnet
            $subnetPrefix = ($snCfg.AddressPrefix | Select-Object -First 1)
            if($snCfg.NetworkSecurityGroup){ $subnetNsg = $snCfg.NetworkSecurityGroup.Id.Split('/')[-1] }
            try{ if($snCfg.Tags){ $subnetTags = $snCfg.Tags } } catch {}
          } catch { }
        }

        # Public IP
        $hasPip = 'No'; $publicIP = $null; $publicIPName=$null; $pipDns=$null
        if($primaryCfg -and $primaryCfg.PublicIpAddress -and $primaryCfg.PublicIpAddress.Id){
          try{
            $pip = Get-AzPublicIpAddress -ResourceId $primaryCfg.PublicIpAddress.Id
            if($pip){ $hasPip='Yes'; $publicIP=$pip.IpAddress; $publicIPName=$pip.Name; $pipDns=$pip.DnsSettings.Fqdn }
          } catch { }
        }

        # NIC summary
        $nicSummary = @()
        foreach($n in $nicObjs){
          foreach($cfg in $n.IpConfigurations){
            $snId = $cfg.Subnet.Id; $vn=$null; $sn=$null
            if($snId){ $p=$snId -split '/'; $vn=$p[$p.IndexOf('virtualNetworks')+1]; $sn=$p[$p.IndexOf('subnets')+1] }
            $pipFlag = if($cfg.PublicIpAddress -and $cfg.PublicIpAddress.Id){ 'pip' } else { 'no-pip' }
            $nicSummary += ("$($n.Name): $vn/$sn [$pipFlag]")
          }
        }
        $nicList = ($nicSummary -join '; ')

        # Disk details
        $diskCount = 0; $diskGiB = 0
        $osDisk = $vm.StorageProfile.OsDisk
        if($osDisk){ $diskCount++; if($osDisk.DiskSizeGB){ $diskGiB += [int]$osDisk.DiskSizeGB } }
        $osSku = if($osDisk -and $osDisk.ManagedDisk){ $osDisk.ManagedDisk.StorageAccountType } else { 'Unmanaged' }
        $ephemeral = $false
        try{ if($osDisk -and $osDisk.DiffDiskSettings -and $osDisk.DiffDiskSettings.Option -eq 'Local'){ $ephemeral = $true } } catch { }
        $dataSkus = @()
        foreach($d in @($vm.StorageProfile.DataDisks)){
          if($d){ $diskCount++; if($d.DiskSizeGB){ $diskGiB += [int]$d.DiskSizeGB }; $dataSkus += ( if($d.ManagedDisk){ $d.ManagedDisk.StorageAccountType } else { 'Unmanaged' } ) }
        }
        $dataSkuList = ($dataSkus | Where-Object { $_ } | Sort-Object -Unique) -join '; '

        # Merge tags (VM + RG + NIC + VNet + Subnet)
        $mergedTags = Merge-Tags @($vmTags,$rgTags,$nicTags,$vnetTags,$subnetTags)

        $h = [ordered]@{
          _kind         = 'compute'
          Scope         = 'VBA or VBR Agent'
          Subscription  = Anon $azSubName
          SubscriptionId= Anon $azSubId
          Tenant        = Anon $azTenantName
          Region        = $vm.Location
          ResourceGroup = Anon $vm.ResourceGroupName
          VM            = Anon $vm.Name
          VMId          = Anon $vm.VmId
          Size          = $vm.HardwareProfile.VmSize
          PowerState    = ($vm.Statuses | Where-Object { $_.Code -like 'PowerState*' }).DisplayStatus
          DiskCount     = $diskCount
          DiskGiB       = $diskGiB
          DiskTiB       = [math]::Round($diskGiB/1024,4)
          OSDiskSku     = $osSku
          DataDiskSkus  = $dataSkuList
          EphemeralOS   = if($ephemeral){ 'Yes' } else { 'No' }
          HasSqlInVM    = ($sqlNames -contains $vm.Name) ? 'Yes' : 'No'
          OS            = $vm.StorageProfile.OsDisk.OsType
          PrimaryNIC    = if($primaryNic){ $primaryNic.Name } else { $null }
          PrimaryNICNSG = if($primaryNic -and $primaryNic.NetworkSecurityGroup){ $primaryNic.NetworkSecurityGroup.Id.Split('/')[-1] } else { $null }
          PrimaryVNet   = $vnetName
          PrimarySubnet = $subnetName
          PrimarySubnetPrefix = $subnetPrefix
          PrimarySubnetNSG    = $subnetNsg
          PrimaryPrivateIP    = $privateIP
          PrimaryHasPublicIP  = $hasPip
          PrimaryPublicIPName = $publicIPName
          PrimaryPublicIP     = $publicIP
          PrimaryPublicFQDN   = $pipDns
          NICs          = $nicList
        }
        Add-TagColumns -h $h -tags $mergedTags -globalKeys $globalTagKeys
        $out += [pscustomobject]$h
      }
    } catch { }
  }

  # ==================== Storage Accounts / Blobs / Files ====================
  if('Storage' -in $using:scopes){
    try{
      $sas = Get-AzStorageAccount -ErrorAction SilentlyContinue
      foreach($sa in $sas){
        $rid     = "/subscriptions/$($azSubId)/resourceGroups/$($sa.ResourceGroupName)/providers/Microsoft.Storage/storageAccounts/$($sa.StorageAccountName)"
        $blobSvc = "$rid/blobServices/default"
        $fileSvc = "$rid/fileServices/default"

        $UsedCapacityBytes          = [int64](Get-MetricLastMax -ResourceId $rid     -MetricName 'UsedCapacity')
        $UsedBlobCapacityBytes      = [int64](Get-MetricLastMax -ResourceId $blobSvc -MetricName 'BlobCapacity')
        $BlobContainerCount         = [int64](Get-MetricLastMax -ResourceId $blobSvc -MetricName 'ContainerCount')
        $BlobCount                  = [int64](Get-MetricLastMax -ResourceId $blobSvc -MetricName 'BlobCount')
        $UsedFileShareCapacityBytes = [int64](Get-MetricLastMax -ResourceId $fileSvc -MetricName 'FileCapacity')
        $FileShareCount             = [int64](Get-MetricLastMax -ResourceId $fileSvc -MetricName 'FileShareCount')
        $FileCount                  = [int64](Get-MetricLastMax -ResourceId $fileSvc -MetricName 'FileCount')

        $row = [ordered]@{
          _kind           = 'storage'
          Scope           = 'VBA Repository Candidate'
          Subscription    = Anon $azSubName
          SubscriptionId  = Anon $azSubId
          Tenant          = Anon $azTenantName
          StorageAccount  = Anon $sa.StorageAccountName
          Kind            = $sa.Kind
          HNS_ADLSGen2    = [bool]$sa.EnableHierarchicalNamespace
          Sku             = $sa.Sku.Name
          AccessTier      = $sa.AccessTier
          Region          = $sa.PrimaryLocation
          ResourceGroup   = Anon $sa.ResourceGroupName
          BlobBytes       = $UsedBlobCapacityBytes
          BlobContainers  = $BlobContainerCount
          BlobCount       = $BlobCount
          FileBytes       = $UsedFileShareCapacityBytes
          FileShareCount  = $FileShareCount
          FileCount       = $FileCount
          AccountBytes    = $UsedCapacityBytes
        }
        Add-TagColumns -h $row -tags $sa.Tags -globalKeys $globalTagKeys
        $out += [pscustomobject]$row

        if($using:DeepContainers){
          try{
            $ctx = (Get-AzStorageAccount -Name $sa.StorageAccountName -ResourceGroupName $sa.ResourceGroupName).Context
            $containers = Get-AzStorageContainer -Context $ctx
            foreach($c in $containers){
              $hot=$cool=$arch=$unk=$all=0; $hotC=$coolC=$archC=$totC=0
              $blobs = Get-AzStorageBlob -Container $c.Name -Context $ctx -ErrorAction SilentlyContinue
              foreach($b in $blobs){
                if($b.SnapshotTime){ continue }
                $totC++; $all += $b.Length
                switch($b.AccessTier){
                  'Hot'     { $hotC++;  $hot  += $b.Length }
                  'Cool'    { $coolC++; $cool += $b.Length }
                  'Archive' { $archC++; $arch += $b.Length }
                  default   { $unk += $b.Length }
                }
              }
              $hc = [ordered]@{
                _kind          = 'containers'
                Scope          = 'VBA Repo (per-container)'
                Subscription   = Anon $azSubName
                SubscriptionId = Anon $azSubId
                Tenant         = Anon $azTenantName
                StorageAccount = Anon $sa.StorageAccountName
                Container      = Anon $c.Name
                Region         = $sa.PrimaryLocation
                Bytes_Hot      = $hot
                Bytes_Cool     = $cool
                Bytes_Archive  = $arch
                Bytes_Unknown  = $unk
                Bytes_Total    = $all
                Count_Hot      = $hotC
                Count_Cool     = $coolC
                Count_Archive  = $archC
                Count_Total    = $totC
              }
              Add-TagColumns -h $hc -tags $sa.Tags -globalKeys $globalTagKeys
              $out += [pscustomobject]$hc
            }
          } catch { }
        }

        # Azure Files shares (mgmt plane)
        try{
          $shares = Get-AzRmStorageShare -ResourceGroupName $sa.ResourceGroupName -StorageAccountName $sa.StorageAccountName -ErrorAction SilentlyContinue
          foreach($sh in $shares){
            $shUsage = Get-AzRmStorageShare -ResourceGroupName $sa.ResourceGroupName -StorageAccountName $sa.StorageAccountName -Name $sh.Name -GetShareUsage -ErrorAction SilentlyContinue
            $fr = [ordered]@{
              _kind          = 'files'
              Scope          = 'VBR NAS (Azure Files)'
              Subscription   = Anon $azSubName
              SubscriptionId = Anon $azSubId
              Tenant         = Anon $azTenantName
              StorageAccount = Anon $sa.StorageAccountName
              Share          = Anon $sh.Name
              Region         = $sa.PrimaryLocation
              QuotaGiB       = $shUsage.QuotaGiB
              UsedBytes      = [int64]($shUsage.ShareUsageBytes ?? 0)
            }
            Add-TagColumns -h $fr -tags $sa.Tags -globalKeys $globalTagKeys
            $out += [pscustomobject]$fr
          }
        } catch { }
      }
    } catch { }
  }

  # ==================== Databases (Azure SQL DB + MI) ====================
  if('Databases' -in $using:scopes){
    try{
      $servers = Get-AzSqlServer -ErrorAction SilentlyContinue
      foreach($sv in $servers){
        $dbs = @(); try{ $dbs = Get-AzSqlDatabase -ServerName $sv.ServerName -ResourceGroupName $sv.ResourceGroupName } catch {}
        foreach($db in $dbs){
          if($db.SkuName -eq 'System'){ continue }
          $allocated = Get-AzMetric -ResourceId $db.ResourceId -MetricName "allocated_data_storage" -AggregationType Maximum -StartTime (Get-Date).AddDays(-1) -WarningAction SilentlyContinue
          $used      = Get-AzMetric -ResourceId $db.ResourceId -MetricName "storage"                -AggregationType Maximum -StartTime (Get-Date).AddDays(-1) -WarningAction SilentlyContinue
          $allocLast = ($allocated.Data.Maximum | Select-Object -Last 1)
          $usedLast  = ($used.Data.Maximum      | Select-Object -Last 1)

          $row = [ordered]@{
            _kind         = 'sql'
            Scope         = 'Azure-native'
            Kind          = 'AzureSQLDatabase'
            Subscription  = Anon $azSubName
            SubscriptionId= Anon $azSubId
            Tenant        = Anon $azTenantName
            Server        = Anon $db.ServerName
            Database      = Anon $db.DatabaseName
            Region        = $db.Location
            MaxSizeBytes  = [long]$db.MaxSizeBytes
            Allocated_Bytes= [int64]($allocLast ?? 0)
            Utilized_Bytes = [int64]($usedLast  ?? 0)
          }
          Add-TagColumns -h $row -tags $db.Tags -globalKeys $globalTagKeys
          $out += [pscustomobject]$row
        }
      }

      $mis = Get-AzSqlInstance -ErrorAction SilentlyContinue
      foreach($mi in $mis){
        $miUsed = Get-AzMetric -ResourceId $mi.Id -MetricName "storage_space_used_mb" -AggregationType Maximum -StartTime (Get-Date).AddDays(-1) -WarningAction SilentlyContinue
        $miUsedLast = [double](($miUsed.Data.Maximum | Select-Object -Last 1) ?? 0)

        $row = [ordered]@{
          _kind         = 'sql'
          Scope         = 'Azure-native'
          Kind          = 'ManagedInstance'
          Subscription  = Anon $azSubName
          SubscriptionId= Anon $azSubId
          Tenant        = Anon $azTenantName
          Server        = Anon $mi.ManagedInstanceName
          Database      = ''
          Region        = $mi.Location
          MaxSizeBytes  = [long]$mi.StorageSizeInGB * 1GB
          storage_space_used_mb = $miUsedLast
        }
        Add-TagColumns -h $row -tags $mi.Tags -globalKeys $globalTagKeys
        $out += [pscustomobject]$row
      }
    } catch { }
  }

  # ==================== AKS (Kasten K10 scope) ====================
  if('Kubernetes' -in $using:scopes){
    try{
      $clusters = Get-AzAksCluster -ErrorAction SilentlyContinue
      foreach($c in $clusters){
        $pools = @(); try{ $pools = Get-AzAksNodePool -ResourceGroupName $c.ResourceGroupName -ClusterName $c.Name } catch {}
        $row = [ordered]@{
          _kind         = 'aks'
          Scope         = 'Kasten K10'
          Subscription  = Anon $azSubName
          SubscriptionId= Anon $azSubId
          Tenant        = Anon $azTenantName
          Cluster       = Anon $c.Name
          ResourceGroup = Anon $c.ResourceGroupName
          Location      = $c.Location
          Kubernetes    = $c.KubernetesVersion
          NodePools     = ($pools | ForEach-Object Name) -join '; '
          NodeSizes     = ($pools | ForEach-Object VmSize) -join '; '
          NodeCount     = ($pools | Measure-Object -Property Count -Sum).Sum
        }
        Add-TagColumns -h $row -tags $c.Tags -globalKeys $globalTagKeys
        $out += [pscustomobject]$row
      }
    } catch { }
  }

  # ==================== Cosmos DB ====================
  if('Cosmos' -in $using:scopes){
    try{
      $rgs = Get-AzResourceGroup -ErrorAction SilentlyContinue
      foreach($rg in $rgs){
        $accts = Get-AzCosmosDBAccount -ResourceGroupName $rg.ResourceGroupName -ErrorAction SilentlyContinue
        foreach($a in $accts){
          $row = [ordered]@{
            _kind         = 'cosmos'
            Scope         = 'Azure-native / K10'
            Subscription  = Anon $azSubName
            SubscriptionId= Anon $azSubId
            Tenant        = Anon $azTenantName
            Account       = Anon $a.Name
            Region        = $a.Location
            Kind          = $a.Kind
            BackupType    = $a.BackupPolicy.BackupType
            BackupTier    = $a.BackupPolicy.Tier
          }
          Add-TagColumns -h $row -tags $a.Tags -globalKeys $globalTagKeys
          $out += [pscustomobject]$row

          if($using:DeepCosmos){
            $names = @('DocumentCount','DataUsage','PhysicalPartitionSizeInfo','PhysicalPartitionCount','IndexUsage')
            $vals = @{}
            foreach($n in $names){
              try{ $vals[$n] = [double](Get-MetricLastMax -ResourceId $a.Id -MetricName $n) } catch { $vals[$n] = 0 }
            }
            $mrow = [ordered]@{
              _kind         = 'cosmosMetrics'
              Subscription  = Anon $azSubName
              SubscriptionId= Anon $azSubId
              Tenant        = Anon $azTenantName
              Account       = Anon $a.Name
              Region        = $a.Location
              DocumentCount = $vals['DocumentCount']
              DataUsageBytes= $vals['DataUsage']
              PhysicalPartitionSizeInfoBytes = $vals['PhysicalPartitionSizeInfo']
              PhysicalPartitionCount         = $vals['PhysicalPartitionCount']
              IndexUsageBytes                = $vals['IndexUsage']
            }
            Add-TagColumns -h $mrow -tags $a.Tags -globalKeys $globalTagKeys
            $out += [pscustomobject]$mrow
          }
        }
      }
    } catch { }
  }

  # ==================== Recovery Services Vaults & Backup ====================
  if('Backup' -in $using:scopes){
    try{
      $vaults = Get-AzRecoveryServicesVault -ErrorAction SilentlyContinue
      foreach($v in $vaults){
        $row = [ordered]@{
          _kind         = 'rsv'
          Scope         = 'Azure Backup (mapping)'
          Subscription  = Anon $azSubName
          SubscriptionId= Anon $azSubId
          Tenant        = Anon $azTenantName
          Vault         = Anon $v.Name
          Region        = $v.Location
          ResourceGroup = Anon $v.ResourceGroupName
        }
        Add-TagColumns -h $row -tags $v.Tags -globalKeys $globalTagKeys
        $out += [pscustomobject]$row

        if($using:DeepBackup){
          try{
            Set-AzRecoveryServicesVaultContext -Vault $v | Out-Null
            $workloads = @('AzureVM','MSSQL','AzureSQLDatabase','AzureFiles')
            foreach($wl in $workloads){
              $pols = @(); try{ $pols = Get-AzRecoveryServicesBackupProtectionPolicy -WorkloadType $wl -ErrorAction SilentlyContinue } catch {}
              foreach($p in $pols){
                $pr = [ordered]@{
                  _kind         = 'backupPolicy'
                  Subscription  = Anon $azSubName
                  SubscriptionId= Anon $azSubId
                  Tenant        = Anon $azTenantName
                  Vault         = Anon $v.Name
                  Region        = $v.Location
                  WorkloadType  = $wl
                  PolicyName    = $p.Name
                  ScheduleType  = $p.SchedulePolicy.ScheduleRunFrequency
                  RetentionInfo = ($p.RetentionPolicy | ConvertTo-Json -Depth 4)
                }
                $out += [pscustomobject]$pr

                $items = @(); try{ $items = Get-AzRecoveryServicesBackupItem -Policy $p -ErrorAction SilentlyContinue } catch {}
                foreach($it in $items){
                  $ir = [ordered]@{
                    _kind               = 'backupItem'
                    Subscription        = Anon $azSubName
                    SubscriptionId      = Anon $azSubId
                    Tenant              = Anon $azTenantName
                    Vault               = Anon $v.Name
                    Region              = $v.Location
                    WorkloadType        = $wl
                    PolicyName          = $p.Name
                    ProtectedItemType   = $it.WorkloadType
                    BackupManagementType= $it.BackupManagementType
                    ContainerName       = Anon $it.ContainerName
                    SourceResourceId    = Anon $it.SourceResourceId
                    FriendlyName        = Anon $it.FriendlyName
                  }
                  $out += [pscustomobject]$ir
                }
              }
            }
          } catch { }
        }
      }
    } catch { }
  }

  # ==================== Cost Insights ====================
  if($using:CostInsights){
    try{
      $dims   = New-AzCostManagementQueryComparisonExpressionObject -Name 'ServiceName' -Value ($using:CostServices -join ',')
      $filter = New-AzCostManagementQueryFilterObject -Dimensions $dims
      $aggregation = @{
        totalCostUSD = @{ name = "CostUSD";        function = "Sum" }
        preTaxCost   = @{ name = "PreTaxCostUSD";  function = "Sum" }
      }
      $from = (Get-Date).AddMonths(-1 * ($using:CostMonths - 1))
      $to   = Get-Date

      $raw = Invoke-AzCostManagementQuery -Type Usage `
                                          -Scope "subscriptions/$($azSubId)" `
                                          -DatasetGranularity 'Monthly' `
                                          -DatasetFilter $filter `
                                          -Timeframe Custom `
                                          -TimePeriodFrom $from `
                                          -TimePeriodTo   $to `
                                          -DatasetAggregation $aggregation 6> $null
      $parsed = $raw | ConvertTo-Json -Depth 10 | ConvertFrom-Json

      $colIndex = @{}
      for($i=0; $i -lt $parsed.Columns.Count; $i++){ $colIndex[$parsed.Columns[$i].Name] = $i }
      foreach($row in $parsed.Row){
        $dateCol = @('UsageDate','BillingMonth','Date') | Where-Object { $colIndex.ContainsKey($_) } | Select-Object -First 1
        $cr = [pscustomobject]@{
          _kind         = 'cost'
          SubscriptionId= Anon $azSubId
          Subscription  = Anon $azSubName
          Tenant        = Anon $azTenantName
          BillingMonth  = [datetime]$row[$colIndex[$dateCol]]
          PreTaxCostUSD = [math]::Round([double]$row[$colIndex['PreTaxCostUSD']],2)
          CostUSD       = [math]::Round([double]$row[$colIndex['CostUSD']],2)
          ServicesFilter= ($using:CostServices -join ';')
        }
        $out += $cr
      }
    } catch { }
  }

  # emit
  $out
} -ThrottleLimit $Parallel

# ---------------- split by kind ----------------
$computeRows         = @($allRows | Where-Object { $_._kind -eq 'compute' })
$storageRows         = @($allRows | Where-Object { $_._kind -eq 'storage' })
$containerRows       = @($allRows | Where-Object { $_._kind -eq 'containers' })
$filesRows           = @($allRows | Where-Object { $_._kind -eq 'files' })
$sqlRows             = @($allRows | Where-Object { $_._kind -eq 'sql' })
$aksRows             = @($allRows | Where-Object { $_._kind -eq 'aks' })
$cosmosRows          = @($allRows | Where-Object { $_._kind -eq 'cosmos' })
$cosmosMetricRows    = @($allRows | Where-Object { $_._kind -eq 'cosmosMetrics' })
$rsvRows             = @($allRows | Where-Object { $_._kind -eq 'rsv' })
$backupPolicyRows    = @($allRows | Where-Object { $_._kind -eq 'backupPolicy' })
$backupItemRows      = @($allRows | Where-Object { $_._kind -eq 'backupItem' })
$costRows            = @($allRows | Where-Object { $_._kind -eq 'cost' })

# ---------------- exports ----------------
$files = @()

$F_Compute       = Join-Path $outDir "veeam_compute_$runStamp.csv"
$F_Storage       = Join-Path $outDir "veeam_storage_accounts_$runStamp.csv"
$F_Containers    = Join-Path $outDir "veeam_blob_containers_$runStamp.csv"
$F_Files         = Join-Path $outDir "veeam_azure_files_$runStamp.csv"
$F_SQL           = Join-Path $outDir "veeam_sql_outline_$runStamp.csv"
$F_AKS           = Join-Path $outDir "veeam_aks_$runStamp.csv"
$F_Cosmos        = Join-Path $outDir "veeam_cosmos_$runStamp.csv"
$F_CosmosMetrics = Join-Path $outDir "veeam_cosmos_metrics_$runStamp.csv"
$F_RSV           = Join-Path $outDir "veeam_rsv_$runStamp.csv"
$F_BkpPolicies   = Join-Path $outDir "veeam_backup_policies_$runStamp.csv"
$F_BkpItems      = Join-Path $outDir "veeam_backup_items_$runStamp.csv"
$F_Costs         = Join-Path $outDir "veeam_costs_$runStamp.csv"
$F_Summary       = Join-Path $outDir "veeam_summary_$runStamp.csv"
$F_Plan          = Join-Path $outDir "veeam_planner_$runStamp.csv"
$F_PlanByTag     = Join-Path $outDir "veeam_planner_by_tag_$runStamp.csv"
$F_Manifest      = Join-Path $outDir "manifest_$runStamp.json"

if($computeRows.Count)         { if(Save-Csv -Data $computeRows         -Path $F_Compute       -NoTypeInfo){ $files += $F_Compute } }
if($storageRows.Count)         { if(Save-Csv -Data $storageRows         -Path $F_Storage       -NoTypeInfo){ $files += $F_Storage } }
if($containerRows.Count)       { if(Save-Csv -Data $containerRows       -Path $F_Containers    -NoTypeInfo){ $files += $F_Containers } }
if($filesRows.Count)           { if(Save-Csv -Data $filesRows           -Path $F_Files         -NoTypeInfo){ $files += $F_Files } }
if($sqlRows.Count)             { if(Save-Csv -Data $sqlRows             -Path $F_SQL           -NoTypeInfo){ $files += $F_SQL } }
if($aksRows.Count)             { if(Save-Csv -Data $aksRows             -Path $F_AKS           -NoTypeInfo){ $files += $F_AKS } }
if($cosmosRows.Count)          { if(Save-Csv -Data $cosmosRows          -Path $F_Cosmos        -NoTypeInfo){ $files += $F_Cosmos } }
if($cosmosMetricRows.Count)    { if(Save-Csv -Data $cosmosMetricRows    -Path $F_CosmosMetrics -NoTypeInfo){ $files += $F_CosmosMetrics } }
if($rsvRows.Count)             { if(Save-Csv -Data $rsvRows             -Path $F_RSV           -NoTypeInfo){ $files += $F_RSV } }
if($backupPolicyRows.Count)    { if(Save-Csv -Data $backupPolicyRows    -Path $F_BkpPolicies   -NoTypeInfo){ $files += $F_BkpPolicies } }
if($backupItemRows.Count)      { if(Save-Csv -Data $backupItemRows      -Path $F_BkpItems      -NoTypeInfo){ $files += $F_BkpItems } }
if($costRows.Count)            { if(Save-Csv -Data $costRows            -Path $F_Costs         -NoTypeInfo){ $files += $F_Costs } }

# ---------------- summary ----------------
$summary = @()
if($computeRows.Count){
  $tiB = (@($computeRows | ForEach-Object { [double]$_.DiskTiB }) | Measure-Object -Sum).Sum
  $summary += [pscustomobject]@{ Resource='IaaS VMs'; Count=$computeRows.Count; TotalTiB=[math]::Round($tiB,3) }
}
if($storageRows.Count){
  $blobTiB = ((@($storageRows | ForEach-Object BlobBytes) | Measure-Object -Sum).Sum) / 1TB
  $fileTiB = ((@($storageRows | ForEach-Object FileBytes) | Measure-Object -Sum).Sum) / 1TB
  $summary += [pscustomobject]@{ Resource='Storage Accounts (Blob)'; Count=$storageRows.Count; TotalTiB=[math]::Round($blobTiB,3) }
  $summary += [pscustomobject]@{ Resource='Storage Accounts (File)'; Count=$storageRows.Count; TotalTiB=[math]::Round($fileTiB,3) }
}
if($filesRows.Count){
  $nasTiB = ((@($filesRows | ForEach-Object UsedBytes) | Measure-Object -Sum).Sum) / 1TB
  $summary += [pscustomobject]@{ Resource='Azure Files Shares'; Count=$filesRows.Count; TotalTiB=[math]::Round($nasTiB,3) }
}
if($aksRows.Count)    { $summary += [pscustomobject]@{ Resource='AKS Clusters'; Count=$aksRows.Count; TotalTiB=$null } }
if($sqlRows.Count)    { $summary += [pscustomobject]@{ Resource='Azure SQL (DB/MI)'; Count=$sqlRows.Count; TotalTiB=[math]::Round(((@($sqlRows | ForEach-Object MaxSizeBytes) | Measure-Object -Sum).Sum)/1TB,3) } }
if($cosmosRows.Count) { $summary += [pscustomobject]@{ Resource='Cosmos DB Accounts'; Count=$cosmosRows.Count; TotalTiB=$null } }
if($rsvRows.Count)    { $summary += [pscustomobject]@{ Resource='Recovery Services Vaults'; Count=$rsvRows.Count; TotalTiB=$null } }
if($backupItemRows.Count){ $summary += [pscustomobject]@{ Resource='Azure Backup Items'; Count=$backupItemRows.Count; TotalTiB=$null } }
if($costRows.Count){ $summary += [pscustomobject]@{ Resource="Costs (months=$CostMonths, services=$($CostServices -join ';'))"; Count=$costRows.Count; TotalTiB=$null } }

if($summary.Count){ if(Save-Csv -Data $summary -Path $F_Summary -NoTypeInfo){ $files += $F_Summary } }

# ---------------- simple sizing planner (region-level) ----------------
$planner = @()
if($computeRows.Count){
  $byRegion = $computeRows | Group-Object Region
  foreach($g in $byRegion){
    $sizeGiB = (@($g.Group | ForEach-Object DiskGiB) | Measure-Object -Sum).Sum
    $fullGiB = $sizeGiB * $CompressionRatio
    $incGiB  = $sizeGiB * ($ChangeRatePercent/100.0) * $RetentionDays * $CompressionRatio
    $planner += [pscustomobject]@{
      Area            = 'VBA (VM backup)'
      Region          = $g.Name
      ProtectedGiB    = [math]::Round($sizeGiB,0)
      EstimatedRepoGiB= [math]::Round($fullGiB + $incGiB,0)
      Assumptions     = "Change=$ChangeRatePercent%, Retention=$RetentionDays d, Ratio=$CompressionRatio"
    }
  }
}
if($filesRows.Count){
  $byRegion = $filesRows | Group-Object Region
  foreach($g in $byRegion){
    $usedGiB = ((@($g.Group | ForEach-Object UsedBytes) | Measure-Object -Sum).Sum) / 1GB
    $fullGiB = $usedGiB * $CompressionRatio
    $incGiB  = $usedGiB * ($ChangeRatePercent/100.0) * $RetentionDays * $CompressionRatio
    $planner += [pscustomobject]@{
      Area            = 'VBR NAS (Azure Files)'
      Region          = $g.Name
      ProtectedGiB    = [math]::Round($usedGiB,0)
      EstimatedRepoGiB= [math]::Round($fullGiB + $incGiB,0)
      Assumptions     = "Change=$ChangeRatePercent%, Retention=$RetentionDays d, Ratio=$CompressionRatio"
    }
  }
}
if($planner.Count){ if(Save-Csv -Data $planner -Path $F_Plan -NoTypeInfo){ $files += $F_Plan } }

# ---------------- tag-grouped planner (by $PlannerTag) ----------------
$plannerByTag = @()
if($PlannerTag){
  if($computeRows.Count){
    $computeByTagRegion = $computeRows | ForEach-Object {
      $tagVal = $_."Tag: $PlannerTag"; if(-not $tagVal){ $tagVal = '-' }
      [pscustomobject]@{ Tag=$tagVal; Region=$_.Region; DiskGiB=[double]$_.DiskGiB }
    } | Group-Object Tag,Region

    foreach($g in $computeByTagRegion){
      $parts = $g.Name -split ','
      $tagName = ($parts[0] -replace '^Tag=','').Trim()
      $region  = ($parts[1] -replace '^Region=','').Trim()
      $sizeGiB = ($g.Group | Measure-Object DiskGiB -Sum).Sum
      $fullGiB = $sizeGiB * $CompressionRatio
      $incGiB  = $sizeGiB * ($ChangeRatePercent/100.0) * $RetentionDays * $CompressionRatio
      $plannerByTag += [pscustomobject]@{
        Area            = 'VBA (VM backup)'
        Tag             = $tagName
        Region          = $region
        ProtectedGiB    = [math]::Round($sizeGiB,0)
        EstimatedRepoGiB= [math]::Round($fullGiB + $incGiB,0)
        Assumptions     = "Change=$ChangeRatePercent%, Retention=$RetentionDays d, Ratio=$CompressionRatio"
      }
    }
  }
  if($filesRows.Count){
    $filesByTagRegion = $filesRows | ForEach-Object {
      $tagVal = $_."Tag: $PlannerTag"; if(-not $tagVal){ $tagVal = '-' }
      [pscustomobject]@{ Tag=$tagVal; Region=$_.Region; UsedGiB=([double]$_.UsedBytes/1GB) }
    } | Group-Object Tag,Region

    foreach($g in $filesByTagRegion){
      $parts = $g.Name -split ','
      $tagName = ($parts[0] -replace '^Tag=','').Trim()
      $region  = ($parts[1] -replace '^Region=','').Trim()
      $usedGiB = ($g.Group | Measure-Object UsedGiB -Sum).Sum
      $fullGiB = $usedGiB * $CompressionRatio
      $incGiB  = $usedGiB * ($ChangeRatePercent/100.0) * $RetentionDays * $CompressionRatio
      $plannerByTag += [pscustomobject]@{
        Area            = 'VBR NAS (Azure Files)'
        Tag             = $tagName
        Region          = $region
        ProtectedGiB    = [math]::Round($usedGiB,0)
        EstimatedRepoGiB= [math]::Round($fullGiB + $incGiB,0)
        Assumptions     = "Change=$ChangeRatePercent%, Retention=$RetentionDays d, Ratio=$CompressionRatio"
      }
    }
  }
}
if($plannerByTag.Count){ if(Save-Csv -Data $plannerByTag -Path $F_PlanByTag -NoTypeInfo){ $files += $F_PlanByTag } }

# ---------------- manifest & archive ----------------
$manifest = [ordered]@{
  generatedAt = (Get-Date).ToString('o')
  version     = '1.3.6'
  source      = $Source
  scopes      = $Scope
  deep        = @{ containers = [bool]$DeepContainers; backup = [bool]$DeepBackup; cosmos = [bool]$DeepCosmos }
  cost        = @{ enabled = [bool]$CostInsights; months = $CostMonths; services = $CostServices }
  planner     = @{ byTagKey = $PlannerTag }
  files       = $files
  log         = (Split-Path $logFile -Leaf)
}
$manifest | ConvertTo-Json -Depth 6 | Out-File -FilePath $F_Manifest -Encoding utf8
$files += $F_Manifest

$zipPath = Join-Path $outDir ("veeam_azure_inventory_" + $runStamp + ".zip")
$existing = $files | Where-Object { Test-Path $_ }
if($existing){ Compress-Archive -Path $existing -DestinationPath $zipPath -Force }

Write-Log -Message "Artifacts ready" -Data @{ zip = (Split-Path $zipPath -Leaf); count = $files.Count }

# restore culture
[Threading.Thread]::CurrentThread.CurrentCulture   = $origCulture
[Threading.Thread]::CurrentThread.CurrentUICulture = $origCulture

Write-Host
Write-Host "Results packaged at: $zipPath" -ForegroundColor Green
Write-Host "Please send the archive to your Veeam representative." -ForegroundColor Cyan
