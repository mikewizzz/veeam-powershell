# SPDX-License-Identifier: MIT
# =========================================================================
# ApiClient.ps1 - VBA REST API client with OAuth2 auth, retry, pagination
# =========================================================================

# =============================
# Certificate Validation Bypass (PS 5.1)
# =============================

<#
.SYNOPSIS
  Configures TLS certificate validation bypass for self-signed certs.
  PS 7+ uses -SkipCertificateCheck on Invoke-RestMethod.
  PS 5.1 requires a .NET CertificatePolicy override.
#>
function Initialize-CertificateBypass {
  if (-not $script:SkipCertCheck) { return }

  if ($PSVersionTable.PSVersion.Major -ge 6) {
    # PS 7+ handles this per-request via -SkipCertificateCheck
    Write-Log "Certificate validation bypass enabled (PS 7+ native)" -Level "INFO"
    return
  }

  # PS 5.1: override global .NET certificate policy
  if (-not ([System.Management.Automation.PSTypeName]'VBATrustAllCertsPolicy').Type) {
    Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class VBATrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint srvPoint, X509Certificate certificate,
        WebRequest request, int certificateProblem) { return true; }
}
"@
  }
  $script:OriginalCertPolicy = [System.Net.ServicePointManager]::CertificatePolicy
  [System.Net.ServicePointManager]::CertificatePolicy = New-Object VBATrustAllCertsPolicy
  Write-Log "Certificate validation bypass enabled (PS 5.1 policy override)" -Level "INFO"
}

<#
.SYNOPSIS
  Restores original certificate validation policy. Called in cleanup.
#>
function Restore-CertificatePolicy {
  if ($null -ne $script:OriginalCertPolicy -and $PSVersionTable.PSVersion.Major -lt 6) {
    [System.Net.ServicePointManager]::CertificatePolicy = $script:OriginalCertPolicy
    $script:OriginalCertPolicy = $null
  }
}

# =============================
# OAuth2 Authentication
# =============================

<#
.SYNOPSIS
  Establishes a connection to the VBA appliance.
  Uses -Token if provided, otherwise authenticates via OAuth2 Password grant.
#>
function Initialize-VBAConnection {
  Write-ProgressStep -Activity "Connecting to VBA Appliance" -Status "Authenticating..."

  Initialize-CertificateBypass

  # Validate appliance is reachable
  $serviceUrl = "$($script:BaseUrl)/api/v8.1/system/serviceIsUp"
  try {
    $restParams = @{
      Uri = $serviceUrl
      Method = "GET"
      UseBasicParsing = $true
      ErrorAction = "Stop"
    }
    if ($script:SkipCertCheck -and $PSVersionTable.PSVersion.Major -ge 6) {
      $restParams.SkipCertificateCheck = $true
    }
    $null = Invoke-RestMethod @restParams
  }
  catch {
    throw "Cannot reach VBA appliance at $($script:BaseUrl). Verify the server address and port. Error: $($_.Exception.Message)"
  }

  if ($script:ProvidedToken) {
    # Validate the provided token
    $script:AuthToken = $script:ProvidedToken
    try {
      $null = Invoke-VBAApi -Endpoint "/api/v8.1/system/about"
      Write-Log "Connected using provided bearer token" -Level "SUCCESS"
    }
    catch {
      throw "Provided token is invalid or expired. Error: $($_.Exception.Message)"
    }
    return
  }

  # Authenticate via OAuth2
  if ($null -eq $script:VBACredential) {
    $script:VBACredential = Get-Credential -Message "Enter VBA appliance credentials"
    if ($null -eq $script:VBACredential) {
      throw "Credentials are required to connect to the VBA appliance."
    }
  }

  Get-VBAToken -Credential $script:VBACredential
  Write-Log "Connected to VBA appliance at $($script:BaseUrl)" -Level "SUCCESS"
}

<#
.SYNOPSIS
  Acquires an OAuth2 token using the Password grant type.
.PARAMETER Credential
  PSCredential with username and password.
#>
function Get-VBAToken {
  param(
    [Parameter(Mandatory=$true)]
    [System.Management.Automation.PSCredential]$Credential
  )

  $tokenUrl = "$($script:BaseUrl)/api/oauth2/token"
  $body = "grant_type=Password&username=$([System.Net.WebUtility]::UrlEncode($Credential.UserName))&password=$([System.Net.WebUtility]::UrlEncode($Credential.GetNetworkCredential().Password))"

  $restParams = @{
    Uri = $tokenUrl
    Method = "POST"
    Body = $body
    ContentType = "application/x-www-form-urlencoded"
    UseBasicParsing = $true
    ErrorAction = "Stop"
  }
  if ($script:SkipCertCheck -and $PSVersionTable.PSVersion.Major -ge 6) {
    $restParams.SkipCertificateCheck = $true
  }

  try {
    $response = Invoke-RestMethod @restParams
  }
  catch {
    $msg = $_.Exception.Message
    if ($msg -match '401|Unauthorized') {
      throw "Authentication failed. Check your username and password."
    }
    throw "OAuth2 token request failed: $msg"
  }

  $script:AuthToken = $response.access_token
  $script:RefreshToken = $response.refresh_token
  # Buffer 60 seconds before actual expiry
  $expiresIn = 3600
  if ($response.expires_in) { $expiresIn = [int]$response.expires_in }
  $script:TokenExpiry = (Get-Date).AddSeconds($expiresIn - 60)

  Write-Log "OAuth2 token acquired (expires in $expiresIn seconds)" -Level "INFO"
}

<#
.SYNOPSIS
  Refreshes the OAuth2 token using the refresh token.
#>
function Update-VBAToken {
  if ([string]::IsNullOrWhiteSpace($script:RefreshToken)) {
    # No refresh token, re-authenticate
    if ($null -ne $script:VBACredential) {
      Get-VBAToken -Credential $script:VBACredential
    }
    else {
      throw "Token expired and no refresh token or credentials available for re-authentication."
    }
    return
  }

  $tokenUrl = "$($script:BaseUrl)/api/oauth2/token"
  $body = "grant_type=Refresh_token&refresh_token=$([System.Net.WebUtility]::UrlEncode($script:RefreshToken))"

  $restParams = @{
    Uri = $tokenUrl
    Method = "POST"
    Body = $body
    ContentType = "application/x-www-form-urlencoded"
    UseBasicParsing = $true
    ErrorAction = "Stop"
  }
  if ($script:SkipCertCheck -and $PSVersionTable.PSVersion.Major -ge 6) {
    $restParams.SkipCertificateCheck = $true
  }

  try {
    $response = Invoke-RestMethod @restParams
    $script:AuthToken = $response.access_token
    if ($response.refresh_token) { $script:RefreshToken = $response.refresh_token }
    $expiresIn = 3600
    if ($response.expires_in) { $expiresIn = [int]$response.expires_in }
    $script:TokenExpiry = (Get-Date).AddSeconds($expiresIn - 60)
    Write-Log "Token refreshed successfully" -Level "INFO"
  }
  catch {
    Write-Log "Token refresh failed, re-authenticating..." -Level "WARNING"
    if ($null -ne $script:VBACredential) {
      Get-VBAToken -Credential $script:VBACredential
    }
    else {
      throw "Token refresh failed and no credentials available: $($_.Exception.Message)"
    }
  }
}

# =============================
# Core API Invocation
# =============================

<#
.SYNOPSIS
  Calls a VBA REST API endpoint with automatic token refresh, retry, and error handling.
.PARAMETER Endpoint
  API path (e.g., "/api/v8.1/system/about").
.PARAMETER Method
  HTTP method. Default GET.
.PARAMETER QueryParams
  Hashtable of query string parameters.
.PARAMETER Body
  Request body (will be converted to JSON if hashtable).
.PARAMETER ContentType
  Content type header. Default application/json.
.PARAMETER MaxRetries
  Maximum retry attempts. Default 3.
.PARAMETER NoPagination
  Switch to skip pagination logic.
#>
function Invoke-VBAApi {
  param(
    [Parameter(Mandatory=$true)][string]$Endpoint,
    [string]$Method = "GET",
    [hashtable]$QueryParams = @{},
    [object]$Body = $null,
    [string]$ContentType = "application/json",
    [int]$MaxRetries = 3
  )

  # Auto-refresh token if near expiry
  if ($null -ne $script:TokenExpiry -and (Get-Date) -ge $script:TokenExpiry) {
    Update-VBAToken
  }

  # Build URI with query parameters
  $uri = "$($script:BaseUrl)$Endpoint"
  if ($QueryParams.Count -gt 0) {
    $queryParts = New-Object System.Collections.Generic.List[string]
    foreach ($key in $QueryParams.Keys) {
      $val = [System.Net.WebUtility]::UrlEncode("$($QueryParams[$key])")
      $queryParts.Add("$key=$val")
    }
    $uri += "?" + ($queryParts -join "&")
  }

  # Build request parameters
  $restParams = @{
    Uri = $uri
    Method = $Method
    ContentType = $ContentType
    UseBasicParsing = $true
    ErrorAction = "Stop"
    Headers = @{
      Authorization = "Bearer $($script:AuthToken)"
    }
  }

  if ($null -ne $Body) {
    if ($Body -is [hashtable]) {
      $restParams.Body = ($Body | ConvertTo-Json -Depth 10)
    }
    else {
      $restParams.Body = $Body
    }
  }

  if ($script:SkipCertCheck -and $PSVersionTable.PSVersion.Major -ge 6) {
    $restParams.SkipCertificateCheck = $true
  }

  # Retry loop with exponential backoff
  $attempt = 0
  while ($true) {
    try {
      $response = Invoke-RestMethod @restParams
      return $response
    }
    catch {
      $statusCode = 0
      if ($_.Exception.Response) {
        $statusCode = [int]$_.Exception.Response.StatusCode
      }

      # Don't retry client errors (except 429)
      if ($statusCode -ge 400 -and $statusCode -lt 500 -and $statusCode -ne 429) {
        throw $_
      }

      $attempt++
      if ($attempt -gt $MaxRetries) {
        throw $_
      }

      # Exponential backoff, capped at 30 seconds
      $sleepSeconds = [Math]::Min([int]([Math]::Pow(2, $attempt)), 30)

      # Honor Retry-After header if present
      if ($_.Exception.Response -and $_.Exception.Response.Headers) {
        try {
          $retryAfter = $_.Exception.Response.Headers['Retry-After']
          if ($retryAfter) {
            $parsedRetry = 0
            if ([int]::TryParse($retryAfter, [ref]$parsedRetry)) {
              $sleepSeconds = [Math]::Min($parsedRetry, 60)
            }
          }
        }
        catch {
          $null = $_ # Retry-After header parsing is best-effort
        }
      }

      Write-Log "API call to $Endpoint failed (attempt $attempt/$MaxRetries), retrying in ${sleepSeconds}s..." -Level "WARNING"
      Start-Sleep -Seconds $sleepSeconds
    }
  }
}

<#
.SYNOPSIS
  Calls a paginated VBA API endpoint and returns all results.
  VBA uses offset/limit pagination with { offset, limit, totalCount, results }.
.PARAMETER Endpoint
  API path.
.PARAMETER QueryParams
  Additional query string parameters.
.PARAMETER PageSize
  Number of items per page. Default 500.
#>
function Invoke-VBAApiPaginated {
  param(
    [Parameter(Mandatory=$true)][string]$Endpoint,
    [hashtable]$QueryParams = @{},
    [int]$PageSize = 500
  )

  $allResults = New-Object System.Collections.Generic.List[object]
  $offset = 0

  while ($true) {
    $pageParams = @{}
    foreach ($key in $QueryParams.Keys) {
      $pageParams[$key] = $QueryParams[$key]
    }
    $pageParams["Offset"] = $offset
    $pageParams["Limit"] = $PageSize

    $response = Invoke-VBAApi -Endpoint $Endpoint -QueryParams $pageParams

    # Handle different response shapes
    $results = $null
    $totalCount = 0

    if ($null -ne $response.results) {
      $results = $response.results
      $totalCount = [int]$response.totalCount
    }
    elseif ($response -is [array]) {
      # Some endpoints return a plain array
      return $response
    }
    else {
      # Single object or empty response
      return $response
    }

    if ($null -ne $results) {
      foreach ($item in $results) {
        $allResults.Add($item)
      }
    }

    # Check if we've retrieved everything
    $retrieved = $offset + @($results).Count
    if ($retrieved -ge $totalCount -or @($results).Count -eq 0) {
      break
    }

    $offset = $retrieved
  }

  return @($allResults.ToArray())
}
