# =============================
# Retry Logic
# =============================

<#
.SYNOPSIS
  Executes a script block with exponential backoff retry.
.PARAMETER ScriptBlock
  The operation to execute.
.PARAMETER OperationName
  Friendly name for logging.
.PARAMETER MaxAttempts
  Maximum number of attempts.
.PARAMETER BaseDelay
  Base delay in seconds (doubles each retry).
#>
function Invoke-WithRetry {
  param(
    [Parameter(Mandatory)][scriptblock]$ScriptBlock,
    [string]$OperationName = "Operation",
    [int]$MaxAttempts = $MaxRetries,
    [int]$BaseDelay = $RetryBaseDelaySeconds
  )

  $attempt = 0
  while ($true) {
    $attempt++
    try {
      return & $ScriptBlock
    }
    catch {
      if ($attempt -ge $MaxAttempts) {
        Write-Log "$OperationName failed after $MaxAttempts attempts: $($_.Exception.Message)" -Level ERROR
        throw
      }
      $delay = $BaseDelay * [Math]::Pow(2, $attempt - 1)
      Write-Log "$OperationName attempt $attempt/$MaxAttempts failed: $($_.Exception.Message). Retrying in ${delay}s..." -Level WARNING
      Start-Sleep -Seconds $delay
    }
  }
}

# =============================
# SLA/RTO Compliance
# =============================

<#
.SYNOPSIS
  Calculates and reports RTO metrics, comparing actual recovery time to target.
.PARAMETER ActualDuration
  The actual recovery duration as a TimeSpan.
.OUTPUTS
  PSCustomObject with RTOTarget, RTOActual, Met, DeltaMinutes, or $null if no target set.
#>
function Measure-RTOCompliance {
  param([Parameter(Mandatory)][TimeSpan]$ActualDuration)

  if (-not $RTOTargetMinutes) { return $null }

  $actualMinutes = [Math]::Round($ActualDuration.TotalMinutes, 1)
  $met = $actualMinutes -le $RTOTargetMinutes
  $delta = [Math]::Round($RTOTargetMinutes - $actualMinutes, 1)

  $level = if ($met) { "SUCCESS" } else { "WARNING" }
  $status = if ($met) { "MET" } else { "BREACHED" }
  Write-Log "RTO $status - Target: ${RTOTargetMinutes}m | Actual: ${actualMinutes}m | Delta: ${delta}m" -Level $level

  Write-AuditEvent -EventType "VALIDATE" -Action "RTO compliance check" -Details @{
    target = $RTOTargetMinutes; actual = $actualMinutes; met = $met
  }

  return [PSCustomObject]@{
    RTOTarget = $RTOTargetMinutes
    RTOActual = $actualMinutes
    Met       = $met
    Delta     = $delta
  }
}
