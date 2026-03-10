# SPDX-License-Identifier: MIT
# =========================================================================
# Auth.ps1 - Module checks, Azure authentication, subscription resolution
# =========================================================================

<#
.SYNOPSIS
  Checks that all required Az modules are installed and exits with instructions if any are missing.
#>
function Initialize-RequiredModules {
  $requiredModules = @(
    'Az.Accounts', 'Az.Resources', 'Az.Compute', 'Az.Network',
    'Az.Sql', 'Az.Storage', 'Az.RecoveryServices'
  )

  $missingModules = @()
  foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
      $missingModules += $mod
    }
  }

  if ($missingModules.Count -gt 0) {
    Write-Log "Missing required Azure PowerShell modules:" -Level "ERROR"
    foreach ($mod in $missingModules) {
      Write-Log "  - $mod" -Level "ERROR"
    }
    Write-Host ""
    Write-Host "Install all missing modules with:" -ForegroundColor Yellow
    Write-Host "  Install-Module $($missingModules -join ', ') -Scope CurrentUser" -ForegroundColor Cyan
    Write-Host ""
    throw "Missing required Azure PowerShell modules: $($missingModules -join ', '). Install with: Install-Module $($missingModules -join ', ') -Scope CurrentUser"
  }
}

<#
.SYNOPSIS
  Tests whether an existing Azure session is valid and reusable.
.OUTPUTS
  [bool] True if a usable session exists, false otherwise.
#>
function Test-AzSession {
  try {
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $ctx) { return $false }
    if (-not $ctx.Account) { return $false }

    Write-Log "Reusing existing Azure session" -Level "SUCCESS"
    return $true
  } catch {
    Write-Log "No valid Azure session found" -Level "INFO"
    return $false
  }
}

<#
.SYNOPSIS
  Authenticates to Azure using the modern authentication hierarchy.
.NOTES
  Hierarchy: Managed Identity > Certificate > Client Secret > Device Code > Interactive Browser.
  Reuses existing sessions when available.
#>
function Connect-AzureModern {
  Write-ProgressStep -Activity "Authenticating to Azure" -Status "Checking session..."

  if (Test-AzSession) { return }

  $connectParams = @{ ErrorAction = "Stop" }

  if ($UseManagedIdentity) {
    Write-Log "Connecting with Azure Managed Identity..." -Level "INFO"
    $connectParams.Identity = $true
  }
  elseif ($ServicePrincipalId -and $CertificateThumbprint) {
    Write-Log "Connecting with Service Principal (certificate)..." -Level "INFO"
    if ($TenantId) { $connectParams.TenantId = $TenantId }
    $connectParams.ServicePrincipal = $true
    $connectParams.ApplicationId = $ServicePrincipalId
    $connectParams.CertificateThumbprint = $CertificateThumbprint
  }
  elseif ($ServicePrincipalId -and $ServicePrincipalSecret) {
    Write-Log "Connecting with Service Principal (client secret)..." -Level "WARNING"
    if ($TenantId) { $connectParams.TenantId = $TenantId }
    $cred = New-Object System.Management.Automation.PSCredential($ServicePrincipalId, $ServicePrincipalSecret)
    $connectParams.ServicePrincipal = $true
    $connectParams.Credential = $cred
  }
  elseif ($UseDeviceCode) {
    Write-Log "Connecting with device code flow..." -Level "INFO"
    if ($TenantId) { $connectParams.TenantId = $TenantId }
    $connectParams.UseDeviceAuthentication = $true
  }
  else {
    Write-Log "Connecting with interactive browser authentication..." -Level "INFO"
    if ($TenantId) { $connectParams.TenantId = $TenantId }
  }

  try {
    Connect-AzAccount @connectParams | Out-Null
    $ctx = Get-AzContext
    # Mask sensitive identifiers in log output
    $maskedAccount = if ($ctx.Account.Id -and $ctx.Account.Id.Length -gt 8) { $ctx.Account.Id.Substring(0, 4) + "****" + $ctx.Account.Id.Substring($ctx.Account.Id.Length - 4) } else { "****" }
    $maskedTenant = if ($ctx.Tenant.Id -and $ctx.Tenant.Id.Length -gt 12) { $ctx.Tenant.Id.Substring(0, 8) + "..." } else { "****" }
    Write-Log "Successfully authenticated (Account: $maskedAccount, Tenant: $maskedTenant)" -Level "SUCCESS"
  } catch {
    Write-Log "Authentication failed: $($_.Exception.Message)" -Level "ERROR"
    throw
  }
}

<#
.SYNOPSIS
  Resolves target subscriptions from user input or returns all accessible subscriptions.
.OUTPUTS
  Array of subscription objects.
#>
function Resolve-Subscriptions {
  Write-ProgressStep -Activity "Resolving Subscriptions" -Status "Querying accessible subscriptions..."

  $all = @(Get-AzSubscription -ErrorAction Stop)

  if ($Subscriptions -and $Subscriptions.Count -gt 0) {
    $resolved = New-Object System.Collections.Generic.List[object]
    foreach ($s in $Subscriptions) {
      $hit = $all | Where-Object { $_.Id -eq $s -or $_.Name -eq $s } | Select-Object -First 1
      if (-not $hit) {
        Write-Log "Subscription '$s' not found or not accessible" -Level "WARNING"
        continue
      }
      $resolved.Add($hit)
      Write-Log "Added subscription: $($hit.Name) [$($hit.Id)]" -Level "INFO"
    }

    if ($resolved.Count -eq 0) {
      throw "No valid subscriptions found matching the provided criteria"
    }

    return @($resolved)
  }

  Write-Log "Using all accessible subscriptions ($($all.Count) found)" -Level "INFO"
  return @($all)
}

<#
.SYNOPSIS
  Validates that the current identity has at least Reader role on target subscriptions.
.PARAMETER Subs
  Array of subscription objects to check.
.NOTES
  Non-blocking: logs warnings for inaccessible subscriptions but does not terminate.
  Returns the filtered list of accessible subscriptions.
#>
function Test-SubscriptionAccess {
  param([Parameter(Mandatory=$true)][array]$Subs)

  Write-Log "Pre-flight: validating access to $($Subs.Count) subscription(s)..." -Level "INFO"
  $accessible = New-Object System.Collections.Generic.List[object]

  foreach ($sub in $Subs) {
    try {
      Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null
      # Quick smoke test — list a single resource to confirm read access
      $null = Get-AzResource -Top 1 -ErrorAction Stop
      $accessible.Add($sub)
    } catch {
      $msg = "$($_.Exception.Message)"
      if ($msg -like "*AuthorizationFailed*" -or $msg -like "*does not have authorization*") {
        Write-Log "No read access to subscription '$($sub.Name)' ($($sub.Id)) — skipping" -Level "WARNING"
      } else {
        Write-Log "Access check failed for '$($sub.Name)': $msg — skipping" -Level "WARNING"
      }
    }
  }

  if ($accessible.Count -eq 0) {
    throw "No accessible subscriptions found. Ensure the identity has at least Reader role on target subscriptions."
  }

  if ($accessible.Count -lt $Subs.Count) {
    $skipped = $Subs.Count - $accessible.Count
    Write-Log "$skipped subscription(s) skipped due to insufficient permissions" -Level "WARNING"
  }

  return @($accessible)
}
