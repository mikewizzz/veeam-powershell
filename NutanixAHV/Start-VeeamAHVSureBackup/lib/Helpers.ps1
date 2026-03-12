# SPDX-License-Identifier: MIT
# =============================
# DRY Helper Functions
# =============================

function _NewTestResult {
  <#
  .SYNOPSIS
    Factory for SureBackup test result objects (DRY helper)
  #>
  param(
    [string]$VMName,
    [string]$TestName,
    [bool]$Passed,
    [string]$Details,
    [datetime]$StartTime
  )
  [PSCustomObject]@{
    VMName    = $VMName
    TestName  = $TestName
    Passed    = $Passed
    Details   = $Details
    Duration  = ((Get-Date) - $StartTime).TotalSeconds
    Timestamp = Get-Date
  }
}

function _WriteTestLog {
  <#
  .SYNOPSIS
    Consistent test pass/fail log entry (DRY helper)
  #>
  param(
    [string]$VMName,
    [string]$TestName,
    [bool]$Passed,
    [string]$Details
  )
  $level = if ($Passed) { "TEST-PASS" } else { "TEST-FAIL" }
  Write-Log "  [$VMName] $TestName : $(if($Passed){'PASS'}else{'FAIL'}) - $Details" -Level $level
}

function _GetTestSummary {
  <#
  .SYNOPSIS
    Calculate test pass/fail/rate summary from results collection (DRY helper)
  #>
  param($TestResults)
  $items = @($TestResults | Where-Object { $null -ne $_ })
  $total = @($items).Count
  $passed = @($items | Where-Object { $_.Passed -eq $true }).Count
  $failed = $total - $passed
  [PSCustomObject]@{
    TotalTests  = $total
    PassedTests = $passed
    FailedTests = $failed
    PassRate    = if ($total -gt 0) { [math]::Round(([double]$passed / $total) * 100, 1) } else { 0 }
  }
}

function _NewRecoveryInfo {
  <#
  .SYNOPSIS
    Factory for recovery session tracking objects (DRY helper)
  #>
  param(
    [string]$OriginalVMName,
    [string]$RecoveryVMName,
    [string]$RecoveryVMUUID,
    [string]$Status,
    [string]$ErrorMessage,
    [string]$RestoreMethod = "FullRestore"
  )
  [PSCustomObject]@{
    OriginalVMName = $OriginalVMName
    RecoveryVMName = $RecoveryVMName
    RecoveryVMUUID = $RecoveryVMUUID
    StartTime      = Get-Date
    Status         = $Status
    Error          = $ErrorMessage
    RestoreMethod  = $RestoreMethod
  }
}

function _GetNGTStatus {
  <#
  .SYNOPSIS
    Extract Nutanix Guest Tools status from a VM object (v3/v4 abstraction)
  #>
  param($VMData)
  if ($script:PrismApiVersion -eq "v4") {
    $ngt = $VMData.guestTools
    if ($ngt) { return [PSCustomObject]@{ Installed = $true; Enabled = [bool]$ngt.isEnabled } }
  }
  else {
    $ngt = $VMData.status.resources.guest_tools
    if ($ngt) { return [PSCustomObject]@{ Installed = $true; Enabled = ($ngt.nutanix_guest_tools.state -eq "ENABLED") } }
  }
  return [PSCustomObject]@{ Installed = $false; Enabled = $false }
}

function _ExtractTaskId {
  <#
  .SYNOPSIS
    Extract async task ID from a v4 API mutating response (POST/PUT/DELETE).
    v4 returns { data: { extId: "taskExtId" } }; v3 returns task_uuid in status.
  #>
  param($Response)
  $raw = if ($Response.Body) { $Response.Body } else { $Response }
  $data = if ($raw.data) { $raw.data } else { $raw }
  if ($data.extId) { return $data.extId }
  # v3 fallback: task_uuid in status
  if ($raw.status.execution_context.task_uuid) { return $raw.status.execution_context.task_uuid }
  return $null
}

function _FormatTimeAgo {
  <#
  .SYNOPSIS
    Convert a datetime to a human-readable relative time string (e.g., "2 hours ago").
  #>
  param([datetime]$DateTime)
  $span = (Get-Date) - $DateTime
  if ($span.TotalMinutes -lt 1)     { return "just now" }
  if ($span.TotalMinutes -lt 60)    { $n = [math]::Floor($span.TotalMinutes); return "$n minute$(if($n -ne 1){'s'}) ago" }
  if ($span.TotalHours -lt 24)      { $n = [math]::Floor($span.TotalHours);   return "$n hour$(if($n -ne 1){'s'}) ago" }
  if ($span.TotalDays -lt 30)       { $n = [math]::Floor($span.TotalDays);    return "$n day$(if($n -ne 1){'s'}) ago" }
  if ($span.TotalDays -lt 365)      { $n = [math]::Floor($span.TotalDays / 30); return "$n month$(if($n -ne 1){'s'}) ago" }
  $n = [math]::Floor($span.TotalDays / 365); return "$n year$(if($n -ne 1){'s'}) ago"
}

function New-EphemeralSSHKey {
  <#
  .SYNOPSIS
    Generate an ephemeral RSA keypair for jump VM SSH access.
    Returns a hashtable with PublicKey and PrivatePath.
  #>
  param(
    [string]$OutputDir = $env:TEMP
  )

  if (-not $OutputDir) { $OutputDir = "/tmp" }
  $keyName = "surebackup_jumpvm_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
  $keyPath = Join-Path $OutputDir $keyName

  # Generate RSA keypair via ssh-keygen (ships with Windows 10+ and Linux/macOS)
  $sshKeygenArgs = @("-t", "rsa", "-b", "2048", "-f", $keyPath, "-N", "", "-q")
  & ssh-keygen @sshKeygenArgs 2>&1 | Out-Null

  if (-not (Test-Path $keyPath)) {
    throw "ssh-keygen failed to create keypair at $keyPath"
  }

  $publicKey = Get-Content "${keyPath}.pub" -Raw
  return @{
    PrivatePath = $keyPath
    PublicKey   = $publicKey.Trim()
  }
}

function Invoke-SSHCommand {
  <#
  .SYNOPSIS
    Execute a command on a remote host via SSH (OpenSSH client)
  .PARAMETER HostIP
    IP address of the remote host
  .PARAMETER KeyPath
    Path to the private key file
  .PARAMETER Command
    Command string to execute on the remote host
  .PARAMETER User
    SSH user (default: ubuntu)
  .PARAMETER TimeoutSec
    SSH connection timeout in seconds (default: 10)
  #>
  param(
    [Parameter(Mandatory = $true)][string]$HostIP,
    [Parameter(Mandatory = $true)][string]$KeyPath,
    [Parameter(Mandatory = $true)][string]$Command,
    [string]$User = "ubuntu",
    [int]$TimeoutSec = 10
  )

  $sshArgs = @(
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "ConnectTimeout=$TimeoutSec",
    "-o", "LogLevel=ERROR",
    "-i", $KeyPath,
    "$User@$HostIP",
    $Command
  )
  $result = & ssh @sshArgs 2>&1

  # Separate stdout strings from error records
  $outputLines = @($result | Where-Object { $_ -is [string] })
  return @{
    Output   = $outputLines -join "`n"
    ExitCode = $LASTEXITCODE
  }
}

function Remove-EphemeralSSHKey {
  <#
  .SYNOPSIS
    Delete ephemeral SSH keypair files from disk
  #>
  param([Parameter(Mandatory = $true)][string]$KeyPath)

  foreach ($f in @($KeyPath, "${KeyPath}.pub")) {
    if (Test-Path $f) {
      Remove-Item $f -Force -ErrorAction SilentlyContinue
    }
  }
}

# =============================
# Checkpoint / Resume Functions
# =============================

function Save-SureBackupCheckpoint {
  <#
  .SYNOPSIS
    Save SureBackup run state to a JSON checkpoint file for resume-from-failure
  .PARAMETER CheckpointPath
    File path for the checkpoint JSON
  .PARAMETER CurrentGroup
    The boot-order group being processed when checkpoint is saved
  .PARAMETER CurrentBatch
    The batch index within the current group (0-based completed count)
  .PARAMETER Status
    Checkpoint status: "in-progress", "interrupted", or "completed"
  .PARAMETER CompletedGroups
    List of group names that have fully completed
  #>
  param(
    [Parameter(Mandatory = $true)][string]$CheckpointPath,
    [string]$CurrentGroup,
    [int]$CurrentBatch,
    [string]$Status,
    [string[]]$CompletedGroups
  )

  $checkpoint = [PSCustomObject]@{
    Version          = "1.0"
    Timestamp        = (Get-Date).ToString("o")
    Status           = $Status
    CurrentGroup     = $CurrentGroup
    CurrentBatch     = $CurrentBatch
    CompletedGroups  = @($CompletedGroups)
    RecoverySessions = @($script:RecoverySessions | ForEach-Object {
      [PSCustomObject]@{
        OriginalVMName = $_.OriginalVMName
        RecoveryVMName = $_.RecoveryVMName
        RecoveryVMUUID = $_.RecoveryVMUUID
        Status         = $_.Status
        Error          = $_.Error
        RestoreMethod  = $_.RestoreMethod
        StartTime      = $_.StartTime.ToString("o")
      }
    })
    TestResults      = @($script:TestResults | ForEach-Object {
      [PSCustomObject]@{
        VMName    = $_.VMName
        TestName  = $_.TestName
        Passed    = $_.Passed
        Details   = $_.Details
        Duration  = $_.Duration
        Timestamp = $_.Timestamp.ToString("o")
      }
    })
  }
  $checkpoint | ConvertTo-Json -Depth 10 | Set-Content -Path $CheckpointPath -Encoding UTF8
}

function Import-SureBackupCheckpoint {
  <#
  .SYNOPSIS
    Load a SureBackup checkpoint file for resume-from-failure
  .PARAMETER CheckpointPath
    Path to the SureBackup_Checkpoint.json file from an interrupted run
  #>
  param(
    [Parameter(Mandatory = $true)][string]$CheckpointPath
  )

  if (-not (Test-Path $CheckpointPath)) {
    throw "Checkpoint file not found: $CheckpointPath"
  }
  $raw = Get-Content -Path $CheckpointPath -Raw | ConvertFrom-Json
  if ($raw.Version -ne "1.0") {
    throw "Unsupported checkpoint version: $($raw.Version)"
  }
  return $raw
}

# =============================
# SLA Scoring Functions
# =============================

function _GetSLASummary {
  <#
  .SYNOPSIS
    Calculate RPO/RTO SLA compliance summary from per-VM timing data
  .PARAMETER VMTimings
    List of per-VM timing objects with RTOMinutes and RPOHours
  .PARAMETER TargetRTOMinutes
    Target Recovery Time Objective in minutes
  .PARAMETER TargetRPOHours
    Target Recovery Point Objective in hours
  #>
  param(
    $VMTimings,
    [int]$TargetRTOMinutes,
    [int]$TargetRPOHours
  )

  $vmCount = @($VMTimings).Count
  $rtoMet = 0; $rpoMet = 0
  $worstRTO = 0; $worstRPO = 0
  $avgRTO = 0; $avgRPO = 0

  foreach ($t in $VMTimings) {
    if ($TargetRTOMinutes -and $t.RTOMinutes -le $TargetRTOMinutes) { $rtoMet++ }
    if ($TargetRPOHours -and $null -ne $t.RPOHours -and $t.RPOHours -le $TargetRPOHours) { $rpoMet++ }
    if ($t.RTOMinutes -gt $worstRTO) { $worstRTO = $t.RTOMinutes }
    if ($null -ne $t.RPOHours -and $t.RPOHours -gt $worstRPO) { $worstRPO = $t.RPOHours }
    $avgRTO += $t.RTOMinutes
    if ($null -ne $t.RPOHours) { $avgRPO += $t.RPOHours }
  }
  if ($vmCount -gt 0) {
    $avgRTO = [math]::Round($avgRTO / $vmCount, 1)
    $avgRPO = [math]::Round($avgRPO / $vmCount, 1)
  }

  [PSCustomObject]@{
    VMCount         = $vmCount
    RTOTarget       = $TargetRTOMinutes
    RPOTarget       = $TargetRPOHours
    RTOMet          = $rtoMet
    RTORate         = if ($vmCount -gt 0 -and $TargetRTOMinutes) { [math]::Round(($rtoMet / $vmCount) * 100, 1) } else { $null }
    RPOMet          = $rpoMet
    RPORate         = if ($vmCount -gt 0 -and $TargetRPOHours) { [math]::Round(($rpoMet / $vmCount) * 100, 1) } else { $null }
    AvgRTOMinutes   = $avgRTO
    AvgRPOHours     = $avgRPO
    WorstRTOMinutes = [math]::Round($worstRTO, 1)
    WorstRPOHours   = [math]::Round($worstRPO, 1)
    VMDetails       = $VMTimings
  }
}

function _TestIPInSubnet {
  <#
  .SYNOPSIS
    Check if an IP address falls within a given subnet (PS 5.1 compatible)
  .PARAMETER IPAddress
    The IP address to test (e.g. "192.168.1.50")
  .PARAMETER NetworkAddress
    The network address of the subnet (e.g. "192.168.1.0")
  .PARAMETER PrefixLength
    The CIDR prefix length (e.g. 24)
  #>
  param(
    [Parameter(Mandatory = $true)][string]$IPAddress,
    [Parameter(Mandatory = $true)][string]$NetworkAddress,
    [Parameter(Mandatory = $true)][int]$PrefixLength
  )

  # Convert dotted-quad IP string to UInt32 (network byte order)
  $ipBytes = ([System.Net.IPAddress]::Parse($IPAddress)).GetAddressBytes()
  $netBytes = ([System.Net.IPAddress]::Parse($NetworkAddress)).GetAddressBytes()

  # .NET returns bytes in network order (big-endian) — shift into a UInt32
  [uint32]$ipInt = ([uint32]$ipBytes[0] -shl 24) -bor ([uint32]$ipBytes[1] -shl 16) -bor ([uint32]$ipBytes[2] -shl 8) -bor [uint32]$ipBytes[3]
  [uint32]$netInt = ([uint32]$netBytes[0] -shl 24) -bor ([uint32]$netBytes[1] -shl 16) -bor ([uint32]$netBytes[2] -shl 8) -bor [uint32]$netBytes[3]

  # Build subnet mask from prefix length
  if ($PrefixLength -eq 0) { [uint32]$mask = 0 }
  else { [uint32]$mask = [uint32]::MaxValue -shl (32 - $PrefixLength) }

  return (($ipInt -band $mask) -eq ($netInt -band $mask))
}
