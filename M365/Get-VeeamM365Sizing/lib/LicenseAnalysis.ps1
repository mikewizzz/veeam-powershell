# =========================================================================
# LicenseAnalysis.ps1 - License SKU retrieval and analysis
# =========================================================================

<#
.SYNOPSIS
  Retrieves and analyzes tenant license SKU data from Microsoft Graph.
.DESCRIPTION
  Fetches subscribedSkus, filters to SKUs with purchased > 0,
  calculates utilization percentages, and returns formatted license data.
.NOTES
  Requires Organization.Read.All scope (already included in base scopes).
  Returns array of license objects or "access_denied" on permission failure.
#>
function Get-LicenseAnalysis {
  try {
    $uri = "https://graph.microsoft.com/v1.0/subscribedSkus"
    $resp = Invoke-Graph -Uri $uri
    $skus = @($resp.value)

    $licenses = New-Object System.Collections.Generic.List[object]
    foreach ($sku in $skus) {
      $purchased = [int]$sku.prepaidUnits.enabled
      if ($purchased -le 0) { continue }

      $assigned  = [int]$sku.consumedUnits
      $available = $purchased - $assigned
      $utilPct   = if ($purchased -gt 0) { [math]::Round(($assigned / $purchased) * 100, 1) } else { 0 }

      $licenses.Add([PSCustomObject]@{
        SkuPartNumber = $sku.skuPartNumber
        SkuId         = $sku.skuId
        DisplayName   = _Get-SkuFriendlyName $sku.skuPartNumber
        Purchased     = $purchased
        Assigned      = $assigned
        Available     = $available
        UtilizationPct = $utilPct
      })
    }

    # Sort by purchased count descending
    return @($licenses | Sort-Object -Property Purchased -Descending)
  } catch {
    $msg = $_.Exception.Message
    if ($msg -match 'Insufficient privileges|Authorization_RequestDenied|access denied|permission|consent|401|403|Forbidden') {
      Write-Log "License analysis: access denied"
      return "access_denied"
    }
    Write-Log "License analysis error: $msg"
    return "unknown"
  }
}

<#
.SYNOPSIS
  Maps common SKU part numbers to human-readable display names.
.PARAMETER skuPartNumber
  The SKU part number from Microsoft Graph (e.g., "ENTERPRISEPREMIUM").
.NOTES
  Covers the most common M365 SKUs. Falls back to the raw part number
  with underscores replaced by spaces for unknown SKUs.
#>
function _Get-SkuFriendlyName([string]$skuPartNumber) {
  $map = @{
    "ENTERPRISEPREMIUM"            = "Microsoft 365 E5"
    "ENTERPRISEPREMIUM_NOPSTNCONF" = "Microsoft 365 E5 (no PSTN)"
    "SPE_E5"                       = "Microsoft 365 E5"
    "SPE_E3"                       = "Microsoft 365 E3"
    "ENTERPRISEPACK"               = "Office 365 E3"
    "ENTERPRISEWITHSCAL"           = "Office 365 E4"
    "SPE_F1"                       = "Microsoft 365 F1"
    "M365_F1"                      = "Microsoft 365 F1"
    "DESKLESSPACK"                 = "Office 365 F3"
    "O365_BUSINESS_PREMIUM"        = "Microsoft 365 Business Premium"
    "SMB_BUSINESS_PREMIUM"         = "Microsoft 365 Business Premium"
    "O365_BUSINESS_ESSENTIALS"     = "Microsoft 365 Business Basic"
    "SMB_BUSINESS_ESSENTIALS"      = "Microsoft 365 Business Basic"
    "O365_BUSINESS"                = "Microsoft 365 Apps for business"
    "SMB_BUSINESS"                 = "Microsoft 365 Apps for business"
    "OFFICESUBSCRIPTION"           = "Microsoft 365 Apps for enterprise"
    "EMS_E5"                       = "Enterprise Mobility + Security E5"
    "EMSPREMIUM"                   = "Enterprise Mobility + Security E5"
    "EMS_E3"                       = "Enterprise Mobility + Security E3"
    "AAD_PREMIUM"                  = "Microsoft Entra ID P1"
    "AAD_PREMIUM_P2"               = "Microsoft Entra ID P2"
    "POWER_BI_PRO"                 = "Power BI Pro"
    "POWER_BI_STANDARD"            = "Power BI (free)"
    "PROJECTPREMIUM"               = "Project Plan 5"
    "PROJECTPROFESSIONAL"          = "Project Plan 3"
    "VISIOCLIENT"                  = "Visio Plan 2"
    "WIN_DEF_ATP"                  = "Microsoft Defender for Endpoint"
    "THREAT_INTELLIGENCE"          = "Microsoft Defender for Office 365 P2"
    "ATP_ENTERPRISE"               = "Microsoft Defender for Office 365 P1"
    "STREAM"                       = "Microsoft Stream"
    "EXCHANGESTANDARD"             = "Exchange Online (Plan 1)"
    "EXCHANGEENTERPRISE"           = "Exchange Online (Plan 2)"
    "EXCHANGEARCHIVE_ADDON"        = "Exchange Online Archiving"
    "RIGHTSMANAGEMENT"             = "Azure Information Protection P1"
    "TEAMS_EXPLORATORY"            = "Microsoft Teams Exploratory"
    "MCOSTANDARD"                  = "Skype for Business Online (Plan 2)"
    "FLOW_FREE"                    = "Power Automate (free)"
    "POWERAPPS_VIRAL"              = "Power Apps (free)"
  }

  if ($map.ContainsKey($skuPartNumber)) { return $map[$skuPartNumber] }
  return ($skuPartNumber -replace '_', ' ')
}
