# =============================
# Logging & Progress
# =============================

function Write-Log {
  param(
    [Parameter(Mandatory = $true)][string]$Message,
    [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS", "TEST-PASS", "TEST-FAIL")]
    [string]$Level = "INFO"
  )

  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $entry = [PSCustomObject]@{
    Timestamp = $timestamp
    Level     = $Level
    Message   = $Message
  }
  $script:LogEntries.Add($entry)

  $color = switch ($Level) {
    "ERROR"     { "Red" }
    "WARNING"   { "Yellow" }
    "SUCCESS"   { "Green" }
    "TEST-PASS" { "Cyan" }
    "TEST-FAIL" { "Magenta" }
    default     { "White" }
  }

  Write-Host "[$timestamp] ${Level}: $Message" -ForegroundColor $color
}

function Write-ProgressStep {
  param(
    [Parameter(Mandatory = $true)][string]$Activity,
    [string]$Status = "Processing..."
  )

  $script:CurrentStep++
  $percentComplete = [math]::Round(($script:CurrentStep / $script:TotalSteps) * 100)
  Write-Progress -Activity "Veeam AHV SureBackup" -Status "$Activity - $Status" -PercentComplete $percentComplete
  Write-Log "STEP $($script:CurrentStep)/$($script:TotalSteps): $Activity" -Level "INFO"
}

function Write-Banner {
  $banner = @"

  ╔══════════════════════════════════════════════════════════════════╗
  ║          Veeam SureBackup for Nutanix AHV  v1.1.0              ║
  ║          Automated Backup Verification & Recovery Testing       ║
  ╚══════════════════════════════════════════════════════════════════╝

"@
  Write-Host $banner -ForegroundColor Green

  if ($DryRun) {
    Write-Host "  >>> DRY RUN MODE - No VMs will be recovered <<<" -ForegroundColor Yellow
    Write-Host ""
  }
}
