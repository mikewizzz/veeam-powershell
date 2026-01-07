# Minimal test
$ErrorActionPreference = "Stop"

Write-Host "Test 1: Basic if statement"
if ($true) { Write-Host "OK" }

Write-Host "Test 2: Importing modules"
$RequiredModules = @(
  'Microsoft.Graph.Authentication',
  'Microsoft.Graph.Reports',
  'Microsoft.Graph.Identity.DirectoryManagement'
)

foreach ($m in $RequiredModules) {
  if (-not (Get-Module -ListAvailable -Name $m)) {
    Write-Host "Module $m not installed, skipping"
    continue
  }
  Write-Host "Importing $m"
  Import-Module $m -ErrorAction Stop
}

Write-Host "Test 3: Connect to Graph"
try {
  Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
  Connect-MgGraph -Scopes "Reports.Read.All","Directory.Read.All","User.Read.All","Organization.Read.All" -NoWelcome
  Write-Host "Connected"
} catch {
  Write-Host "Connection error (expected if already connected or credentials missing)"
}

Write-Host "Test 4: Download a report"
try {
  $uri = "https://graph.microsoft.com/v1.0/reports/getMailboxUsageDetail(period='D90')"
  Write-Host "Downloading from $uri"
  $tmp = "/tmp/test-report.csv"
  Invoke-MgGraphRequest -Uri $uri -OutputFilePath $tmp | Out-Null
  Write-Host "Downloaded to $tmp"
  
  Write-Host "Test 5: Import CSV"
  $data = Import-Csv $tmp
  Write-Host "Imported: $($data.Count) rows"
  
  Write-Host "Test 6: Now test if statement"
  if ($data) { Write-Host "CSV imported successfully" }
  
} catch {
  Write-Host "Error: $($_.Exception.Message)"
}

Write-Host "All tests complete"
