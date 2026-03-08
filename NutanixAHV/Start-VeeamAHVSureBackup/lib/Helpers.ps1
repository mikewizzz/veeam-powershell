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
  $total = @($TestResults).Count
  $passed = @($TestResults | Where-Object { $_.Passed }).Count
  $failed = $total - $passed
  [PSCustomObject]@{
    TotalTests  = $total
    PassedTests = $passed
    FailedTests = $failed
    PassRate    = if ($total -gt 0) { [math]::Round([double](([double]$passed / $total) * 100), [int]1) } else { 0 }
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
  if ($PrismApiVersion -eq "v4") {
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
