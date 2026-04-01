# =========================================================================
# GraphApi.ps1 - Microsoft Graph API functions with retry logic
# =========================================================================

<#
.SYNOPSIS
  Invokes Microsoft Graph API with exponential backoff retry logic for throttling.
.DESCRIPTION
  Wraps Invoke-MgGraphRequest with automatic retry on throttling (429) and transient errors.
  Uses exponential backoff with respect for Retry-After headers.
.PARAMETER Uri
  The Graph API endpoint URI.
.PARAMETER Method
  HTTP method (GET, POST, PATCH, DELETE).
.PARAMETER Headers
  Optional hashtable of custom headers.
.PARAMETER Body
  Optional request body for POST/PATCH operations.
.PARAMETER MaxRetries
  Maximum number of retry attempts (default: 6).
.NOTES
  Sleeps between retries using exponential backoff: 2^attempt seconds (max 30s).
  Respects Retry-After header when provided by Graph API.
#>
function Invoke-Graph {
  param(
    [Parameter(Mandatory)][string]$Uri,
    [ValidateSet('GET','POST','PATCH','DELETE')][string]$Method='GET',
    [hashtable]$Headers,
    $Body,
    [int]$MaxRetries = 6
  )
  $attempt = 0
  do {
    try {
      Write-Log "Graph $Method $Uri"
      if ($Body) { return Invoke-MgGraphRequest -Method $Method -Uri $Uri -Headers $Headers -Body $Body }
      else       { return Invoke-MgGraphRequest -Method $Method -Uri $Uri -Headers $Headers }
    } catch {
      $attempt++
      $msg = $_.Exception.Message
      $retryAfter = 0
      try {
        if ($_.Exception.Response -and $_.Exception.Response.Headers['Retry-After']) {
          [int]::TryParse($_.Exception.Response.Headers['Retry-After'], [ref]$retryAfter) | Out-Null
        }
      } catch {}
      $isRetryable = ($msg -match 'Too Many Requests|throttle|429|5\d\d|temporarily unavailable')
      if ($attempt -le $MaxRetries -and $isRetryable) {
        $sleep = [Math]::Min([int]([Math]::Pow(2, $attempt)), 30)
        if ($retryAfter -gt 0) { $sleep = [Math]::Max($sleep, $retryAfter) }
        Write-Log "Throttled/retryable error: sleeping $sleep sec (attempt $attempt/$MaxRetries)"
        Start-Sleep -Seconds $sleep
      } else {
        throw
      }
    }
  } while ($true)
}

<#
.SYNOPSIS
  Downloads CSV files from Graph API with retry logic for throttling.
.PARAMETER Uri
  The Graph API report endpoint URI.
.PARAMETER OutPath
  Local file path to save the downloaded CSV.
.PARAMETER MaxRetries
  Maximum number of retry attempts (default: 6).
#>
function Invoke-GraphDownloadCsv {
  param(
    [Parameter(Mandatory)][string]$Uri,
    [Parameter(Mandatory)][string]$OutPath,
    [int]$MaxRetries = 6
  )
  $attempt = 0
  do {
    try {
      Write-Log "Graph DOWNLOAD $Uri -> $OutPath"
      Invoke-MgGraphRequest -Uri $Uri -OutputFilePath $OutPath | Out-Null
      return
    } catch {
      $attempt++
      $msg = $_.Exception.Message
      $retryAfter = 0
      try {
        if ($_.Exception.Response -and $_.Exception.Response.Headers['Retry-After']) {
          [int]::TryParse($_.Exception.Response.Headers['Retry-After'], [ref]$retryAfter) | Out-Null
        }
      } catch {}
      $isRetryable = ($msg -match 'Too Many Requests|throttle|429|5\d\d|temporarily unavailable')
      if ($attempt -le $MaxRetries -and $isRetryable) {
        $sleep = [Math]::Min([int]([Math]::Pow(2, $attempt)), 30)
        if ($retryAfter -gt 0) { $sleep = [Math]::Max($sleep, $retryAfter) }
        Write-Log "Throttled/retryable download error: sleeping $sleep sec (attempt $attempt/$MaxRetries)"
        Start-Sleep -Seconds $sleep
      } else {
        throw
      }
    }
  } while ($true)
}

<#
.SYNOPSIS
  Counts entities in Microsoft Graph (users, groups, devices, policies, etc.).
.PARAMETER Path
  Graph API path relative to v1.0 (e.g., "users", "groups").
.NOTES
  Uses $count=true with eventual consistency for efficient counting.
  Returns special strings for permission/availability errors:
  - "access_denied": Insufficient permissions
  - "not_available": Resource not provisioned in tenant
  - "unknown": Unexpected error
  - "present": Entity exists but count unavailable
#>
function Get-GraphEntityCount {
  param([Parameter(Mandatory)][string]$Path)
  $headers = @{ "ConsistencyLevel" = "eventual" }
  $uri = "https://graph.microsoft.com/v1.0/${Path}?`$top=1&`$count=true"
  try {
    $resp = Invoke-Graph -Uri $uri -Headers $headers
    if ($resp.'@odata.count') { return [int]$resp.'@odata.count' }
    elseif ($resp.value)      { return [int]@($resp.value).Count }
    else                      { return 0 }
  } catch {
    $msg = $_.Exception.Message
    if ($msg -match 'Insufficient privileges|Authorization_RequestDenied|access denied|permission|consent|401|403|Forbidden') {
      return "access_denied"
    }
    if ($msg -match '404|NotFound|No resource was found') {
      return "not_available"
    }
    try {
      $fallbackUri = "https://graph.microsoft.com/v1.0/${Path}?`$top=1"
      $fallback = Invoke-Graph -Uri $fallbackUri
      if ($fallback.value -and @($fallback.value).Count -gt 0) { return "present" }
      return 0
    } catch {
      $fallbackMsg = $_.Exception.Message
      if ($fallbackMsg -match 'Insufficient privileges|Authorization_RequestDenied|access denied|permission|consent|401|403|Forbidden') { return "access_denied" }
      if ($fallbackMsg -match '404|NotFound|No resource was found') { return "not_available" }
      return "unknown"
    }
  }
}
