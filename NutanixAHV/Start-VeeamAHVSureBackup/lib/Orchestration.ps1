# SPDX-License-Identifier: MIT
# =============================
# Application Group Orchestration
# =============================

function Get-VMBootOrder {
  <#
  .SYNOPSIS
    Determine VM boot order from ApplicationGroups or return flat list
  .DESCRIPTION
    If ApplicationGroups is defined, VMs boot in group order (group 1 first, then 2, etc.)
    VMs within the same group boot concurrently up to MaxConcurrentVMs.
    VMs not in any group are added to a final catch-all group.
  #>
  param(
    [Parameter(Mandatory = $true)]$RestorePoints
  )

  $ordered = [ordered]@{}

  if ($ApplicationGroups -and $ApplicationGroups.Count -gt 0) {
    $assignedVMs = @()

    # Process defined groups in order
    $sortedKeys = $ApplicationGroups.Keys | Sort-Object
    foreach ($groupId in $sortedKeys) {
      $groupVMs = $ApplicationGroups[$groupId]
      $groupRPs = @()

      $missingVMs = @()
      foreach ($vmName in $groupVMs) {
        $rp = $RestorePoints | Where-Object { $_.VMName -eq $vmName }
        if ($rp) {
          $groupRPs += $rp
          $assignedVMs += $vmName
        }
        else {
          $missingVMs += $vmName
          Write-Log "Application group $groupId : VM '$vmName' has no restore point - MISSING" -Level "ERROR"
        }
      }

      if ($missingVMs.Count -gt 0) {
        Write-Log "Application group $groupId has $($missingVMs.Count) missing VM(s): $($missingVMs -join ', ') — dependent groups may fail" -Level "WARNING"
      }

      # Always add group to ordered (even if empty) to maintain dependency chain
      $ordered["Group $groupId"] = @($groupRPs)
    }

    # Add unassigned VMs to catch-all group (wrap in @() for PS 5.1 .Count)
    $unassigned = @($RestorePoints | Where-Object { $_.VMName -notin $assignedVMs })
    if ($unassigned.Count -gt 0) {
      $ordered["Ungrouped"] = @($unassigned)
    }
  }
  else {
    # No groups defined - single flat group
    $ordered["All VMs"] = @($RestorePoints)
  }

  return $ordered
}
