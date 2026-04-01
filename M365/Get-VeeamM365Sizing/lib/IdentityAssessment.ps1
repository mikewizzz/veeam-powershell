# =========================================================================
# IdentityAssessment.ps1 - MFA, admins, guests, stale, risky users, Secure Score
# =========================================================================

<#
.SYNOPSIS
  Retrieves Global Administrator directory role members.
.NOTES
  Uses /v1.0/directoryRoles and member enumeration.
  Returns list of admin display names or "access_denied" on permission failure.
#>
function Get-GlobalAdmins {
  try {
    $roles = Invoke-Graph -Uri "https://graph.microsoft.com/v1.0/directoryRoles"
    $globalAdminRole = $roles.value | Where-Object { $_.displayName -eq "Global Administrator" }
    if (-not $globalAdminRole) { return @() }

    $members = Invoke-Graph -Uri "https://graph.microsoft.com/v1.0/directoryRoles/$($globalAdminRole.id)/members"
    $admins = New-Object System.Collections.Generic.List[object]
    foreach ($m in $members.value) {
      $admins.Add([PSCustomObject]@{
        DisplayName       = $m.displayName
        UserPrincipalName = $m.userPrincipalName
        Id                = $m.id
      })
    }
    return ,@($admins)
  } catch {
    $msg = $_.Exception.Message
    if ($msg -match 'Insufficient privileges|Authorization_RequestDenied|access denied|permission|consent|401|403|Forbidden') {
      Write-Log "Global Admins: access denied"
      return "access_denied"
    }
    Write-Log "Global Admins error: $msg"
    return "unknown"
  }
}

<#
.SYNOPSIS
  Counts guest users in the tenant.
.NOTES
  Uses $count=true with ConsistencyLevel: eventual for efficient counting.
#>
function Get-GuestUserCount {
  try {
    $headers = @{ "ConsistencyLevel" = "eventual" }
    $uri = "https://graph.microsoft.com/v1.0/users?`$filter=userType eq 'Guest'&`$count=true&`$top=1"
    $resp = Invoke-Graph -Uri $uri -Headers $headers
    if ($resp.'@odata.count') { return [int]$resp.'@odata.count' }
    return 0
  } catch {
    $msg = $_.Exception.Message
    if ($msg -match 'Insufficient privileges|Authorization_RequestDenied|access denied|permission|consent|401|403|Forbidden') { return "access_denied" }
    Write-Log "Guest count error: $msg"
    return "unknown"
  }
}

<#
.SYNOPSIS
  Gets MFA registration count from authentication methods report.
.NOTES
  Requires AuditLog.Read.All scope.
  Returns count of users with MFA registered or "access_denied".
#>
function Get-MfaRegistrationCount {
  try {
    $headers = @{ "ConsistencyLevel" = "eventual" }
    $uri = "https://graph.microsoft.com/v1.0/reports/authenticationMethods/userRegistrationDetails?`$filter=isMfaRegistered eq true&`$count=true&`$top=1"
    $resp = Invoke-Graph -Uri $uri -Headers $headers
    if ($resp.'@odata.count') { return [int]$resp.'@odata.count' }
    return 0
  } catch {
    $msg = $_.Exception.Message
    if ($msg -match 'Insufficient privileges|Authorization_RequestDenied|access denied|permission|consent|401|403|Forbidden') { return "access_denied" }
    Write-Log "MFA registration count error: $msg"
    return "unknown"
  }
}

<#
.SYNOPSIS
  Counts stale accounts (no sign-in within threshold days).
.NOTES
  Requires AuditLog.Read.All scope for signInActivity.
  Uses $STALE_DAYS constant from Constants.ps1.
#>
function Get-StaleAccountCount {
  try {
    $cutoff = (Get-Date).AddDays(-$STALE_DAYS).ToString("yyyy-MM-ddTHH:mm:ssZ")
    $headers = @{ "ConsistencyLevel" = "eventual" }
    $uri = "https://graph.microsoft.com/v1.0/users?`$filter=signInActivity/lastSignInDateTime le $cutoff&`$count=true&`$top=1"
    $resp = Invoke-Graph -Uri $uri -Headers $headers
    if ($resp.'@odata.count') { return [int]$resp.'@odata.count' }
    return 0
  } catch {
    $msg = $_.Exception.Message
    if ($msg -match 'Insufficient privileges|Authorization_RequestDenied|access denied|permission|consent|401|403|Forbidden') { return "access_denied" }
    if ($msg -match '404|NotFound|No resource was found') { return "not_available" }
    Write-Log "Stale account count error: $msg"
    return "unknown"
  }
}

<#
.SYNOPSIS
  Retrieves risky users from Identity Protection.
.NOTES
  Requires IdentityRiskEvent.Read.All scope.
  Returns hashtable with High, Medium, Low counts or "access_denied".
#>
function Get-RiskyUsers {
  try {
    $uri = "https://graph.microsoft.com/v1.0/identityProtection/riskyUsers?`$filter=riskLevel ne 'none'"
    $resp = Invoke-Graph -Uri $uri
    $users = @($resp.value)

    $result = @{
      High   = @($users | Where-Object { $_.riskLevel -eq 'high' }).Count
      Medium = @($users | Where-Object { $_.riskLevel -eq 'medium' }).Count
      Low    = @($users | Where-Object { $_.riskLevel -eq 'low' }).Count
      Total  = $users.Count
    }
    return $result
  } catch {
    $msg = $_.Exception.Message
    if ($msg -match 'Insufficient privileges|Authorization_RequestDenied|access denied|permission|consent|401|403|Forbidden') { return "access_denied" }
    if ($msg -match '404|NotFound|No resource was found') { return "not_available" }
    Write-Log "Risky users error: $msg"
    return "unknown"
  }
}

<#
.SYNOPSIS
  Retrieves Microsoft Secure Score (latest).
.NOTES
  Requires SecurityEvents.Read.All scope.
  Returns hashtable with CurrentScore, MaxScore, Percentage or "access_denied".
#>
function Get-SecureScore {
  try {
    $uri = "https://graph.microsoft.com/v1.0/security/secureScores?`$top=1"
    $resp = Invoke-Graph -Uri $uri
    if ($resp.value -and @($resp.value).Count -gt 0) {
      $score = $resp.value[0]
      return @{
        CurrentScore = [double]$score.currentScore
        MaxScore     = [double]$score.maxScore
        Percentage   = if ($score.maxScore -gt 0) { [math]::Round(($score.currentScore / $score.maxScore) * 100, 1) } else { 0 }
      }
    }
    return @{ CurrentScore = 0; MaxScore = 0; Percentage = 0 }
  } catch {
    $msg = $_.Exception.Message
    if ($msg -match 'Insufficient privileges|Authorization_RequestDenied|access denied|permission|consent|401|403|Forbidden') { return "access_denied" }
    if ($msg -match '404|NotFound|No resource was found') { return "not_available" }
    Write-Log "Secure Score error: $msg"
    return "unknown"
  }
}

<#
.SYNOPSIS
  Counts Microsoft Teams in the tenant.
.NOTES
  Uses group filter for Teams-provisioned groups.
  Requires Group.Read.All scope.
#>
function Get-TeamsCount {
  try {
    $headers = @{ "ConsistencyLevel" = "eventual" }
    $uri = "https://graph.microsoft.com/v1.0/groups?`$filter=resourceProvisioningOptions/Any(x:x eq 'Team')&`$count=true&`$top=1"
    $resp = Invoke-Graph -Uri $uri -Headers $headers
    if ($resp.'@odata.count') { return [int]$resp.'@odata.count' }
    return 0
  } catch {
    $msg = $_.Exception.Message
    if ($msg -match 'Insufficient privileges|Authorization_RequestDenied|access denied|permission|consent|401|403|Forbidden') { return "access_denied" }
    Write-Log "Teams count error: $msg"
    return "unknown"
  }
}

# =============================
# Orchestrator
# =============================

<#
.SYNOPSIS
  Runs the full identity and security assessment (Full mode only).
.DESCRIPTION
  Collects existing posture signals (directory, CA, Intune) plus new
  identity assessment signals (admins, guests, MFA, stale, risky, Secure Score, Teams).
.NOTES
  Sets script-level variables for all collected signals.
  Gracefully handles permission denials for each signal independently.
#>
function Invoke-IdentityAssessment {
  # Existing posture signals
  $script:userCount       = $null
  $script:groupCount      = $null
  $script:appRegCount     = $null
  $script:spnCount        = $null
  $script:caPolicyCount   = $null
  $script:caNamedLocCount = $null
  $script:intuneManagedDevices        = $null
  $script:intuneCompliancePolicies    = $null
  $script:intuneDeviceConfigurations  = $null
  $script:intuneConfigurationPolicies = $null

  # New identity signals
  $script:globalAdmins    = $null
  $script:guestUserCount  = $null
  $script:mfaCount        = $null
  $script:staleAccounts   = $null
  $script:riskyUsers      = $null
  $script:secureScore     = $null
  $script:teamsCount      = $null
  $script:copilotLicenses = $null

  if ($Full) {
    Write-Host "Collecting posture signals (directory/CA/Intune)..." -ForegroundColor Green
    $script:userCount       = Get-GraphEntityCount -Path "users"
    $script:groupCount      = Get-GraphEntityCount -Path "groups"
    $script:appRegCount     = Get-GraphEntityCount -Path "applications"
    $script:spnCount        = Get-GraphEntityCount -Path "servicePrincipals"
    $script:caPolicyCount   = Get-GraphEntityCount -Path "identity/conditionalAccess/policies"
    $script:caNamedLocCount = Get-GraphEntityCount -Path "identity/conditionalAccess/namedLocations"

    $script:intuneManagedDevices        = Get-GraphEntityCount -Path "deviceManagement/managedDevices"
    $script:intuneCompliancePolicies    = Get-GraphEntityCount -Path "deviceManagement/deviceCompliancePolicies"
    $script:intuneDeviceConfigurations  = Get-GraphEntityCount -Path "deviceManagement/deviceConfigurations"
    $script:intuneConfigurationPolicies = Get-GraphEntityCount -Path "deviceManagement/configurationPolicies"

    Write-Host "Collecting identity assessment signals..." -ForegroundColor Green
    $script:globalAdmins   = Get-GlobalAdmins
    $script:guestUserCount = Get-GuestUserCount
    $script:mfaCount       = Get-MfaRegistrationCount
    $script:staleAccounts  = Get-StaleAccountCount
    $script:riskyUsers     = Get-RiskyUsers
    $script:secureScore    = Get-SecureScore
    $script:teamsCount     = Get-TeamsCount
  }
}
