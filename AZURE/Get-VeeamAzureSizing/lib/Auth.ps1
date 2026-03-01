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

    # Verify context is usable
    $null = Get-AzSubscription -ErrorAction Stop | Select-Object -First 1
    Write-Log "Reusing existing Azure session (Account: $($ctx.Account.Id))" -Level "SUCCESS"
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
    Write-Log "Successfully authenticated (Account: $($ctx.Account.Id), Tenant: $($ctx.Tenant.Id))" -Level "SUCCESS"
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
      $hit = $all | Where-Object { $_.Id -eq $s -or $_.Name -eq $s }
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
  return $all
}
