# =========================================================================
# Auth.ps1 - Authentication, module management, and scope validation
# =========================================================================

# =============================
# Module Management
# =============================

<#
.SYNOPSIS
  Ensures required PowerShell modules are installed and imported.
.NOTES
  Module list varies based on run mode and group filtering options.
#>
function Initialize-RequiredModules {
  $requiredModules = @(
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.Reports',
    'Microsoft.Graph.Identity.DirectoryManagement'
  )
  if ($ADGroup -or $ExcludeADGroup) { $requiredModules += 'Microsoft.Graph.Groups' }

  foreach ($m in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $m)) {
      if ($SkipModuleInstall) {
        throw "Missing required module '$m'. Install with: Install-Module $m -Scope CurrentUser"
      }
      Write-Log "Installing module $m"
      Install-Module $m -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module $m -ErrorAction Stop
  }
}

# =============================
# Scope Validation
# =============================

<#
.SYNOPSIS
  Validates that current Microsoft Graph session has required scopes.
.PARAMETER mustHaveScopes
  Array of required scope strings (e.g., "Reports.Read.All").
.NOTES
  Throws an error if any required scopes are missing from the current session.
#>
function Assert-Scopes([string[]]$mustHaveScopes) {
  $ctx = Get-MgContext
  $have = @()
  try { $have = @($ctx.Scopes) } catch { $have = @() }
  $missing = $mustHaveScopes | Where-Object { $_ -notin $have }
  if ($missing.Count -gt 0) {
    throw "Missing required Graph scopes in this session: $($missing -join ', '). Disconnect and reconnect to consent these scopes."
  }
}

<#
.SYNOPSIS
  Checks if there's a valid, reusable Microsoft Graph session.
.PARAMETER requiredScopes
  Array of scopes that must be present in the session.
.NOTES
  Returns $true if session exists and has all required scopes.
  Returns $false if no session, expired session, or missing scopes.
#>
function Test-GraphSession([string[]]$requiredScopes) {
  try {
    $ctx = Get-MgContext
    if (-not $ctx) { return $false }

    if ($ctx.AuthType -in @("Delegated", "AppOnly") -and $ctx.TokenExpires -and $ctx.TokenExpires -lt (Get-Date).AddMinutes(5)) {
      Write-Log "Existing session token expires soon: $($ctx.TokenExpires)"
      return $false
    }

    if ($ctx.AuthType -eq "AppOnly") {
      $haveScopes = @($ctx.Scopes)
      $missing = $requiredScopes | Where-Object { $_ -notin $haveScopes }
      if ($missing.Count -gt 0) {
        Write-Log "Existing app-only session missing scopes: $($missing -join ', ')"
        return $false
      }
    }

    Write-Log "Reusing existing Graph session (type: $($ctx.AuthType), expires: $($ctx.TokenExpires))"
    return $true
  } catch {
    Write-Log "No valid Graph session found: $($_.Exception.Message)"
    return $false
  }
}

# =============================
# Authentication
# =============================

<#
.SYNOPSIS
  Establishes Microsoft Graph connection using the appropriate authentication method.
.DESCRIPTION
  Supports delegated (interactive), certificate, managed identity, access token,
  client secret, and device code flows. Adds new scopes for Full mode identity assessment.
.NOTES
  New Full mode scopes: AuditLog.Read.All, IdentityRiskEvent.Read.All,
  SecurityEvents.Read.All, Group.Read.All (for Teams count).
#>
function Connect-GraphSession {
  if (-not $UseAppAccess) {
    # Determine required scopes based on run mode
    $script:baseScopes = @("Reports.Read.All","Directory.Read.All","User.Read.All","Organization.Read.All")
    if ($ADGroup -or $ExcludeADGroup) { $script:baseScopes += "Group.Read.All" }

    if ($Full) {
      # Existing posture signals
      $script:baseScopes += @(
        "Application.Read.All",
        "Policy.Read.All",
        "DeviceManagementManagedDevices.Read.All",
        "DeviceManagementConfiguration.Read.All"
      )
      # New identity assessment scopes
      $script:baseScopes += @(
        "AuditLog.Read.All",
        "IdentityRiskEvent.Read.All",
        "SecurityEvents.Read.All"
      )
      # Group.Read.All needed for Teams count (add only if not already present)
      if ("Group.Read.All" -notin $script:baseScopes) {
        $script:baseScopes += "Group.Read.All"
      }
    }

    # Check if we can reuse existing session
    if (Test-GraphSession -requiredScopes $script:baseScopes) {
      Write-Host "Reusing existing Microsoft Graph session..." -ForegroundColor Green
    } else {
      Write-Host "Connecting to Microsoft Graph (delegated)..." -ForegroundColor Green
      try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch {}

      $connectParams = @{
        Scopes = $script:baseScopes
        NoWelcome = $true
      }

      if ($UseDeviceCode) {
        $connectParams.UseDeviceCode = $true
      }

      Connect-MgGraph @connectParams
    }

    Assert-Scopes -mustHaveScopes $script:baseScopes
  } else {
    # App-only authentication (service principal)
    $connectParams = @{
      NoWelcome = $true
      TenantId = $TenantId
    }

    if ($AccessToken) {
      Write-Host "Connecting to Microsoft Graph (access token)..." -ForegroundColor Green
      $connectParams.AccessToken = $AccessToken
    } elseif ($UseManagedIdentity) {
      Write-Host "Connecting to Microsoft Graph (managed identity)..." -ForegroundColor Green
      $connectParams.Identity = $true
    } elseif ($CertificateThumbprint) {
      if (-not $ClientId) { throw "CertificateThumbprint requires -ClientId" }
      Write-Host "Connecting to Microsoft Graph (certificate)..." -ForegroundColor Green
      $connectParams.ClientId = $ClientId
      $connectParams.CertificateThumbprint = $CertificateThumbprint
    } elseif ($CertificateSubjectName) {
      if (-not $ClientId) { throw "CertificateSubjectName requires -ClientId" }
      Write-Host "Connecting to Microsoft Graph (certificate by subject)..." -ForegroundColor Green
      $connectParams.ClientId = $ClientId
      $connectParams.CertificateSubjectName = $CertificateSubjectName
    } elseif ($ClientSecret) {
      if (-not $ClientId) { throw "ClientSecret requires -ClientId" }
      Write-Host "Connecting to Microsoft Graph (client secret)..." -ForegroundColor Green
      $clientSecretCred = [System.Management.Automation.PSCredential]::new($ClientId, $ClientSecret)
      $connectParams.ClientSecretCredential = $clientSecretCred
    } else {
      throw "For -UseAppAccess please provide one of: -AccessToken, -UseManagedIdentity, -CertificateThumbprint, -CertificateSubjectName, or -ClientSecret/-ClientId"
    }

    Connect-MgGraph @connectParams
  }
}

<#
.SYNOPSIS
  Retrieves tenant organization details after authentication.
.NOTES
  Sets script-level variables: OrgId, OrgName, DefaultDomain, TenantCategory, envName.
#>
function Get-TenantInfo {
  $ctx = Get-MgContext
  $script:envName = try { $ctx.Environment.Name } catch { "Unknown" }

  $script:TenantCategory = switch ($script:envName) {
    "AzureUSGovernment" { "US Government (GCC/GCC High/DoD)" }
    "AzureChinaCloud"   { "China (21Vianet)" }
    "AzureCloud"        { "Commercial" }
    default             { "Unknown" }
  }

  $org = (Get-MgOrganization)[0]
  $script:OrgId = $org.Id
  $script:OrgName = $org.DisplayName
  $script:DefaultDomain = ($org.VerifiedDomains | Where-Object { $_.IsDefault -eq $true } | Select-Object -First 1).Name

  Write-Log "Tenant: $($script:OrgName) ($($script:OrgId)), DefaultDomain: $($script:DefaultDomain), Env: $($script:envName), Category: $($script:TenantCategory)"
}
