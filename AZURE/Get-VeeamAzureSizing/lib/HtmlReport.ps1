# =========================================================================
# HtmlReport.ps1 - Professional HTML report generation (Fluent Design)
# =========================================================================

<#
.SYNOPSIS
  Generates a professional HTML sizing report with Microsoft Fluent Design System styling.
.PARAMETER VmInventory
  VM inventory collection.
.PARAMETER SqlInventory
  SQL inventory hashtable (Databases, ManagedInstances).
.PARAMETER StorageInventory
  Storage inventory hashtable (Files, Blobs).
.PARAMETER AzureBackupInventory
  Backup inventory hashtable (Vaults, Policies).
.PARAMETER VeeamSizing
  Veeam sizing summary object.
.PARAMETER OutputPath
  Directory to write the HTML file.
.OUTPUTS
  Path to the generated HTML file.
#>
function Build-HtmlReport {
  param(
    [Parameter(Mandatory=$true)]$VmInventory,
    [Parameter(Mandatory=$true)]$SqlInventory,
    [Parameter(Mandatory=$true)]$StorageInventory,
    [Parameter(Mandatory=$true)]$AzureBackupInventory,
    [Parameter(Mandatory=$true)]$VeeamSizing,
    [Parameter(Mandatory=$true)][string]$OutputPath
  )

  Write-ProgressStep -Activity "Generating HTML Report" -Status "Creating professional report..."

  $reportDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $duration = (Get-Date) - $script:StartTime
  $durationStr = "$([math]::Floor($duration.TotalMinutes))m $($duration.Seconds)s"

  # Build subscription summary (HTML-encoded)
  $subList = ($script:Subs | ForEach-Object {
    $safeName = Escape-Html $_.Name
    $safeId = Escape-Html $_.Id
    "<li>$safeName [$safeId]</li>"
  }) -join "`n"

  # Build VM summary by location (HTML-encoded)
  $vmsByLocation = $VmInventory | Group-Object Location | Sort-Object Count -Descending
  $locationRows = ($vmsByLocation | ForEach-Object {
    $safeLoc = Escape-Html $_.Name
    $count = $_.Count
    $storageGB = [math]::Round(($_.Group | Measure-Object -Property TotalProvisionedGB -Sum).Sum, 0)
    "<tr><td>$safeLoc</td><td>$count</td><td>$storageGB GB</td></tr>"
  }) -join "`n"

  # Build recommendations
  $recommendationItems = ($VeeamSizing.Recommendations | ForEach-Object {
    "<li class='recommendation-item'>$(Escape-Html $_)</li>"
  }) -join "`n"

  # Sizing values (numeric — safe, but kept clean)
  $totalVMs = $VeeamSizing.TotalVMs
  $totalSQLDbs = $VeeamSizing.TotalSQLDatabases
  $totalSQLMIs = $VeeamSizing.TotalSQLManagedInstances
  $vmStorageGB = [math]::Round($VeeamSizing.TotalVMStorageGB, 0)
  $sqlStorageGB = [math]::Round($VeeamSizing.TotalSQLStorageGB, 0)
  $sourceTB = [math]::Round($VeeamSizing.TotalSourceStorageGB / 1024, 2)
  $repoTB = [math]::Round($VeeamSizing.TotalRepositoryGB / 1024, 2)
  $snapshotGB = [math]::Ceiling($VeeamSizing.TotalSnapshotStorageGB)
  $repoGB = [math]::Ceiling($VeeamSizing.TotalRepositoryGB)
  $snapshotTB = [math]::Round($VeeamSizing.TotalSnapshotStorageGB / 1024, 2)
  $repoStorageTB = [math]::Round($VeeamSizing.TotalRepositoryGB / 1024, 2)
  $overheadPct = [math]::Round(($RepositoryOverhead - 1) * 100, 0)
  $subCount = $script:Subs.Count
  $filesCount = @($StorageInventory.Files).Count
  $blobsCount = @($StorageInventory.Blobs).Count
  $vaultsCount = @($AzureBackupInventory.Vaults).Count
  $policiesCount = @($AzureBackupInventory.Policies).Count

  $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Veeam Backup for Azure - Sizing Assessment</title>
<style>
:root {
  --ms-blue: #0078D4;
  --ms-blue-dark: #106EBE;
  --veeam-green: #00B336;
  --ms-gray-10: #FAF9F8;
  --ms-gray-20: #F3F2F1;
  --ms-gray-30: #EDEBE9;
  --ms-gray-50: #D2D0CE;
  --ms-gray-90: #605E5C;
  --ms-gray-130: #323130;
  --ms-gray-160: #201F1E;
  --shadow-depth-4: 0 1.6px 3.6px 0 rgba(0,0,0,.132), 0 0.3px 0.9px 0 rgba(0,0,0,.108);
  --shadow-depth-8: 0 3.2px 7.2px 0 rgba(0,0,0,.132), 0 0.6px 1.8px 0 rgba(0,0,0,.108);
  --shadow-depth-16: 0 6.4px 14.4px 0 rgba(0,0,0,.132), 0 1.2px 3.6px 0 rgba(0,0,0,.108);
}

* {
  box-sizing: border-box;
  margin: 0;
  padding: 0;
}

body {
  font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, sans-serif;
  background: var(--ms-gray-10);
  color: var(--ms-gray-160);
  line-height: 1.6;
  font-size: 14px;
}

.container {
  max-width: 1440px;
  margin: 0 auto;
  padding: 40px 32px;
}

.header {
  background: white;
  border-left: 4px solid var(--veeam-green);
  padding: 32px;
  margin-bottom: 32px;
  border-radius: 2px;
  box-shadow: var(--shadow-depth-8);
}

.header-title {
  font-size: 32px;
  font-weight: 300;
  color: var(--ms-gray-160);
  margin-bottom: 8px;
}

.header-subtitle {
  font-size: 16px;
  color: var(--ms-gray-90);
  margin-bottom: 24px;
}

.header-meta {
  display: flex;
  gap: 32px;
  flex-wrap: wrap;
  font-size: 13px;
  color: var(--ms-gray-90);
}

.kpi-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
  gap: 24px;
  margin-bottom: 32px;
}

.kpi-card {
  background: white;
  padding: 24px;
  border-radius: 2px;
  box-shadow: var(--shadow-depth-4);
  border-top: 3px solid var(--veeam-green);
}

.kpi-label {
  font-size: 12px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: var(--ms-gray-90);
  margin-bottom: 8px;
}

.kpi-value {
  font-size: 36px;
  font-weight: 300;
  color: var(--ms-gray-160);
  margin-bottom: 4px;
}

.kpi-subtext {
  font-size: 13px;
  color: var(--ms-gray-90);
}

.section {
  background: white;
  padding: 32px;
  margin-bottom: 24px;
  border-radius: 2px;
  box-shadow: var(--shadow-depth-4);
}

.section-title {
  font-size: 20px;
  font-weight: 600;
  color: var(--ms-gray-160);
  margin-bottom: 20px;
  padding-bottom: 12px;
  border-bottom: 1px solid var(--ms-gray-30);
}

table {
  width: 100%;
  border-collapse: collapse;
  font-size: 14px;
  margin-top: 16px;
}

thead {
  background: var(--ms-gray-20);
}

th {
  padding: 12px 16px;
  text-align: left;
  font-weight: 600;
  color: var(--ms-gray-130);
  font-size: 12px;
  text-transform: uppercase;
  letter-spacing: 0.03em;
  border-bottom: 2px solid var(--ms-gray-50);
}

td {
  padding: 14px 16px;
  border-bottom: 1px solid var(--ms-gray-30);
  color: var(--ms-gray-160);
}

tbody tr:hover {
  background: var(--ms-gray-10);
}

.info-card {
  background: var(--ms-gray-10);
  border-left: 4px solid var(--ms-blue);
  padding: 20px 24px;
  margin: 16px 0;
  border-radius: 2px;
}

.info-card-title {
  font-weight: 600;
  color: var(--ms-gray-130);
  margin-bottom: 8px;
  font-size: 14px;
}

.info-card-text {
  color: var(--ms-gray-90);
  font-size: 14px;
  line-height: 1.6;
}

.recommendation-item {
  padding: 12px 0;
  border-bottom: 1px solid var(--ms-gray-30);
  color: var(--ms-gray-160);
}

.recommendation-item:last-child {
  border-bottom: none;
}

.highlight {
  color: var(--veeam-green);
  font-weight: 600;
}

.footer {
  text-align: center;
  padding: 32px;
  color: var(--ms-gray-90);
  font-size: 13px;
}

@media print {
  body { background: white; }
  .section { box-shadow: none; border: 1px solid var(--ms-gray-30); }
}
</style>
</head>
<body>
<div class="container">
  <div class="header">
    <div class="header-title">Veeam Backup for Azure</div>
    <div class="header-subtitle">Professional Sizing Assessment</div>
    <div class="header-meta">
      <span><strong>Generated:</strong> $reportDate</span>
      <span><strong>Duration:</strong> $durationStr</span>
      <span><strong>Subscriptions:</strong> $subCount</span>
    </div>
  </div>

  <div class="kpi-grid">
    <div class="kpi-card">
      <div class="kpi-label">Azure VMs</div>
      <div class="kpi-value">$totalVMs</div>
      <div class="kpi-subtext">$vmStorageGB GB provisioned</div>
    </div>
    <div class="kpi-card">
      <div class="kpi-label">SQL Databases</div>
      <div class="kpi-value">$totalSQLDbs</div>
      <div class="kpi-subtext">$sqlStorageGB GB total</div>
    </div>
    <div class="kpi-card">
      <div class="kpi-label">Total Source Data</div>
      <div class="kpi-value">$sourceTB TB</div>
      <div class="kpi-subtext">Across all workloads</div>
    </div>
    <div class="kpi-card">
      <div class="kpi-label">Veeam Repository</div>
      <div class="kpi-value">$repoTB TB</div>
      <div class="kpi-subtext">Recommended capacity</div>
    </div>
  </div>

  <div class="section">
    <h2 class="section-title">Executive Summary</h2>
    <div class="info-card">
      <div class="info-card-title">Assessment Scope</div>
      <div class="info-card-text">
        This assessment analyzed <strong>$subCount Azure subscription(s)</strong> and discovered:
        <ul style="margin: 12px 0 0 20px;">
          <li><strong>$totalVMs Azure VMs</strong> with $vmStorageGB GB provisioned storage</li>
          <li><strong>$totalSQLDbs SQL Databases</strong> and <strong>$totalSQLMIs Managed Instances</strong></li>
          <li><strong>$filesCount Azure File Shares</strong> and <strong>$blobsCount Blob containers</strong></li>
          <li><strong>$vaultsCount Recovery Services Vaults</strong> with $policiesCount backup policies</li>
        </ul>
      </div>
    </div>

    <div class="info-card">
      <div class="info-card-title">Veeam Sizing Recommendations</div>
      <div class="info-card-text">
        <ul style="margin: 12px 0 0 20px;">
          $recommendationItems
        </ul>
      </div>
    </div>
  </div>

  <div class="section">
    <h2 class="section-title">Virtual Machines by Region</h2>
    <table>
      <thead>
        <tr>
          <th>Region</th>
          <th>VM Count</th>
          <th>Total Storage</th>
        </tr>
      </thead>
      <tbody>
        $locationRows
      </tbody>
    </table>
  </div>

  <div class="section">
    <h2 class="section-title">Veeam Backup for Azure Sizing</h2>
    <table>
      <thead>
        <tr>
          <th>Component</th>
          <th>Value</th>
          <th>Notes</th>
        </tr>
      </thead>
      <tbody>
        <tr>
          <td><strong>Snapshot Storage</strong></td>
          <td class="highlight">$snapshotGB GB</td>
          <td>Based on $SnapshotRetentionDays days retention with 10% daily change</td>
        </tr>
        <tr>
          <td><strong>Repository Capacity</strong></td>
          <td class="highlight">$repoGB GB</td>
          <td>Includes $overheadPct% overhead for compression and retention</td>
        </tr>
        <tr>
          <td><strong>Snapshot Storage (TB)</strong></td>
          <td class="highlight">$snapshotTB TB</td>
          <td>Recommended Azure Managed Disk capacity</td>
        </tr>
        <tr>
          <td><strong>Repository Storage (TB)</strong></td>
          <td class="highlight">$repoStorageTB TB</td>
          <td>Recommended Azure Blob Storage capacity</td>
        </tr>
      </tbody>
    </table>
  </div>

  <div class="section">
    <h2 class="section-title">Subscriptions Analyzed</h2>
    <ul style="margin: 16px 0 0 20px; color: var(--ms-gray-160);">
      $subList
    </ul>
  </div>

  <div class="section">
    <h2 class="section-title">Methodology</h2>
    <div class="info-card">
      <div class="info-card-title">Data Collection</div>
      <div class="info-card-text">
        This assessment uses Azure Resource Manager APIs to inventory VMs, SQL databases, storage accounts, and existing Azure Backup configuration. All data is read-only and no changes are made to your environment.
      </div>
    </div>
    <div class="info-card">
      <div class="info-card-title">Veeam Sizing Calculations</div>
      <div class="info-card-text">
        <strong>Snapshot Storage:</strong> Calculated based on provisioned VM disk capacity x (retention days / 30) x 10% daily change rate.<br><br>
        <strong>Repository Capacity:</strong> Calculated as source data x $RepositoryOverhead overhead multiplier to account for compression efficiency and retention requirements.<br><br>
        <strong>Note:</strong> These are sizing recommendations for planning purposes. Actual storage consumption will vary based on your backup policies, data change rates, and compression ratios.
      </div>
    </div>
  </div>

  <div class="footer">
    <p>Veeam Backup for Azure - Sizing Assessment</p>
    <p>Generated by Get-VeeamAzureSizing — open-source community tool</p>
  </div>
</div>
</body>
</html>
"@

  $htmlPath = Join-Path $OutputPath "Veeam-Azure-Sizing-Report.html"
  $html | Out-File -FilePath $htmlPath -Encoding UTF8

  Write-Log "Generated HTML report: $htmlPath" -Level "SUCCESS"
  return $htmlPath
}
