# =========================================================================
# Compliance.ps1 - NIS2, SOC2, ISO27001 control mappings for findings
# =========================================================================

# =============================
# Framework Control Definitions
# =============================

<#
.SYNOPSIS
  Returns the compliance framework control mappings database.
.DESCRIPTION
  Maps finding categories and types to specific regulatory controls across
  NIS2, SOC2 Trust Services Criteria, and ISO 27001:2022 Annex A.
  Each mapping includes the control ID, short description, and article reference.
.NOTES
  Only loaded when -Compliance switch is active. Does not add new Graph API calls.
#>
function Get-ComplianceControlMappings {
  return @{
    # --- MFA / Authentication Controls ---
    "MFA" = @{
      NIS2 = @(
        @{ Control = "Art. 21(2)(j)"; Description = "Multi-factor authentication and access control"; Article = "NIS2 Directive Article 21(2)(j)" }
      )
      SOC2 = @(
        @{ Control = "CC6.1"; Description = "Logical access security — authentication mechanisms"; Article = "Trust Services Criteria CC6.1" },
        @{ Control = "CC6.3"; Description = "Restricting access based on additional controls"; Article = "Trust Services Criteria CC6.3" }
      )
      ISO27001 = @(
        @{ Control = "A.8.5"; Description = "Secure authentication"; Article = "ISO 27001:2022 Annex A 8.5" },
        @{ Control = "A.5.17"; Description = "Authentication information"; Article = "ISO 27001:2022 Annex A 5.17" }
      )
    }

    # --- Privileged Access Management ---
    "PrivilegedAccess" = @{
      NIS2 = @(
        @{ Control = "Art. 21(2)(i)"; Description = "Human resources security and access control policies"; Article = "NIS2 Directive Article 21(2)(i)" }
      )
      SOC2 = @(
        @{ Control = "CC6.1"; Description = "Logical access security — role-based access"; Article = "Trust Services Criteria CC6.1" },
        @{ Control = "CC6.2"; Description = "Authorization to access based on role"; Article = "Trust Services Criteria CC6.2" }
      )
      ISO27001 = @(
        @{ Control = "A.8.2"; Description = "Privileged access rights"; Article = "ISO 27001:2022 Annex A 8.2" },
        @{ Control = "A.5.15"; Description = "Access control"; Article = "ISO 27001:2022 Annex A 5.15" }
      )
    }

    # --- Identity Risk / Risky Users ---
    "IdentityRisk" = @{
      NIS2 = @(
        @{ Control = "Art. 21(2)(b)"; Description = "Incident handling and detection"; Article = "NIS2 Directive Article 21(2)(b)" },
        @{ Control = "Art. 23(1)"; Description = "Reporting obligations for significant incidents"; Article = "NIS2 Directive Article 23(1)" }
      )
      SOC2 = @(
        @{ Control = "CC7.2"; Description = "Security event monitoring and anomaly detection"; Article = "Trust Services Criteria CC7.2" },
        @{ Control = "CC7.3"; Description = "Detection of unauthorized activities"; Article = "Trust Services Criteria CC7.3" }
      )
      ISO27001 = @(
        @{ Control = "A.5.7"; Description = "Threat intelligence"; Article = "ISO 27001:2022 Annex A 5.7" },
        @{ Control = "A.8.16"; Description = "Monitoring activities"; Article = "ISO 27001:2022 Annex A 8.16" }
      )
    }

    # --- Stale Account Hygiene ---
    "AccountHygiene" = @{
      NIS2 = @(
        @{ Control = "Art. 21(2)(i)"; Description = "Human resources security and access control"; Article = "NIS2 Directive Article 21(2)(i)" }
      )
      SOC2 = @(
        @{ Control = "CC6.2"; Description = "User access removal on change/termination"; Article = "Trust Services Criteria CC6.2" },
        @{ Control = "CC6.5"; Description = "Periodic review of access"; Article = "Trust Services Criteria CC6.5" }
      )
      ISO27001 = @(
        @{ Control = "A.5.18"; Description = "Access rights — provisioning and revocation"; Article = "ISO 27001:2022 Annex A 5.18" },
        @{ Control = "A.8.2"; Description = "Privileged access rights review"; Article = "ISO 27001:2022 Annex A 8.2" }
      )
    }

    # --- Conditional Access / Access Governance ---
    "AccessGovernance" = @{
      NIS2 = @(
        @{ Control = "Art. 21(2)(j)"; Description = "Access control and authentication policies"; Article = "NIS2 Directive Article 21(2)(j)" }
      )
      SOC2 = @(
        @{ Control = "CC6.1"; Description = "Logical access security mechanisms"; Article = "Trust Services Criteria CC6.1" },
        @{ Control = "CC6.6"; Description = "System boundaries and access restrictions"; Article = "Trust Services Criteria CC6.6" }
      )
      ISO27001 = @(
        @{ Control = "A.5.15"; Description = "Access control policy"; Article = "ISO 27001:2022 Annex A 5.15" },
        @{ Control = "A.5.16"; Description = "Identity management"; Article = "ISO 27001:2022 Annex A 5.16" }
      )
    }

    # --- Guest / External Access ---
    "ExternalAccess" = @{
      NIS2 = @(
        @{ Control = "Art. 21(2)(d)"; Description = "Supply chain security and third-party access"; Article = "NIS2 Directive Article 21(2)(d)" }
      )
      SOC2 = @(
        @{ Control = "CC6.1"; Description = "Logical access security — external users"; Article = "Trust Services Criteria CC6.1" },
        @{ Control = "CC9.2"; Description = "Risk management of vendors and third parties"; Article = "Trust Services Criteria CC9.2" }
      )
      ISO27001 = @(
        @{ Control = "A.5.19"; Description = "Information security in supplier relationships"; Article = "ISO 27001:2022 Annex A 5.19" },
        @{ Control = "A.5.20"; Description = "Addressing security within supplier agreements"; Article = "ISO 27001:2022 Annex A 5.20" }
      )
    }

    # --- Data Protection / Backup ---
    "DataProtection" = @{
      NIS2 = @(
        @{ Control = "Art. 21(2)(c)"; Description = "Business continuity and disaster recovery"; Article = "NIS2 Directive Article 21(2)(c)" },
        @{ Control = "Art. 21(2)(j)"; Description = "Access control to prevent unauthorized data access"; Article = "NIS2 Directive Article 21(2)(j)" }
      )
      SOC2 = @(
        @{ Control = "A1.2"; Description = "Recovery from environmental disruptions"; Article = "Trust Services Criteria A1.2" },
        @{ Control = "A1.3"; Description = "Recovery plan testing"; Article = "Trust Services Criteria A1.3" },
        @{ Control = "CC7.5"; Description = "Recovery from identified security events"; Article = "Trust Services Criteria CC7.5" }
      )
      ISO27001 = @(
        @{ Control = "A.8.13"; Description = "Information backup"; Article = "ISO 27001:2022 Annex A 8.13" },
        @{ Control = "A.8.14"; Description = "Redundancy of information processing facilities"; Article = "ISO 27001:2022 Annex A 8.14" },
        @{ Control = "A.5.30"; Description = "ICT readiness for business continuity"; Article = "ISO 27001:2022 Annex A 5.30" }
      )
    }

    # --- Configuration Protection (Entra ID) ---
    "ConfigProtection" = @{
      NIS2 = @(
        @{ Control = "Art. 21(2)(e)"; Description = "Security in network and system acquisition, development, and maintenance"; Article = "NIS2 Directive Article 21(2)(e)" }
      )
      SOC2 = @(
        @{ Control = "CC8.1"; Description = "Change management — configuration baselines"; Article = "Trust Services Criteria CC8.1" },
        @{ Control = "CC7.5"; Description = "Recovery of system configurations"; Article = "Trust Services Criteria CC7.5" }
      )
      ISO27001 = @(
        @{ Control = "A.8.9"; Description = "Configuration management"; Article = "ISO 27001:2022 Annex A 8.9" },
        @{ Control = "A.8.32"; Description = "Change management"; Article = "ISO 27001:2022 Annex A 8.32" }
      )
    }

    # --- Device Management ---
    "DeviceManagement" = @{
      NIS2 = @(
        @{ Control = "Art. 21(2)(e)"; Description = "Security in acquisition and maintenance of systems"; Article = "NIS2 Directive Article 21(2)(e)" }
      )
      SOC2 = @(
        @{ Control = "CC6.7"; Description = "Restriction of access based on device"; Article = "Trust Services Criteria CC6.7" },
        @{ Control = "CC6.8"; Description = "Controls over endpoint devices"; Article = "Trust Services Criteria CC6.8" }
      )
      ISO27001 = @(
        @{ Control = "A.8.1"; Description = "User endpoint devices"; Article = "ISO 27001:2022 Annex A 8.1" },
        @{ Control = "A.7.9"; Description = "Security of assets off-premises"; Article = "ISO 27001:2022 Annex A 7.9" }
      )
    }

    # --- AI / Copilot Data Governance ---
    "AIGovernance" = @{
      NIS2 = @(
        @{ Control = "Art. 21(2)(a)"; Description = "Risk analysis and information system security policies"; Article = "NIS2 Directive Article 21(2)(a)" }
      )
      SOC2 = @(
        @{ Control = "CC3.2"; Description = "Risk assessment for new technologies"; Article = "Trust Services Criteria CC3.2" },
        @{ Control = "CC6.1"; Description = "Logical access to AI-generated data"; Article = "Trust Services Criteria CC6.1" }
      )
      ISO27001 = @(
        @{ Control = "A.5.12"; Description = "Classification of information (AI-generated content)"; Article = "ISO 27001:2022 Annex A 5.12" },
        @{ Control = "A.5.9"; Description = "Inventory of information and associated assets"; Article = "ISO 27001:2022 Annex A 5.9" }
      )
    }
  }
}

# =============================
# Compliance Finding Functions
# =============================

<#
.SYNOPSIS
  Creates a compliance-enriched finding by mapping controls to an existing finding.
.PARAMETER Finding
  The base finding object from Get-Findings.
.PARAMETER ControlArea
  The compliance control area key (e.g., "MFA", "PrivilegedAccess").
.PARAMETER Frameworks
  Array of frameworks to include: "NIS2", "SOC2", "ISO27001".
#>
function Add-ComplianceMapping {
  param(
    [Parameter(Mandatory)][PSCustomObject]$Finding,
    [Parameter(Mandatory)][string]$ControlArea,
    [string[]]$Frameworks = @("NIS2", "SOC2", "ISO27001")
  )

  $mappings = Get-ComplianceControlMappings
  if (-not $mappings.ContainsKey($ControlArea)) { return $Finding }

  $controls = $mappings[$ControlArea]
  $complianceRefs = New-Object System.Collections.Generic.List[object]

  foreach ($fw in $Frameworks) {
    if ($controls.ContainsKey($fw) -and $controls[$fw]) {
      foreach ($ctrl in $controls[$fw]) {
        $complianceRefs.Add([PSCustomObject]@{
          Framework   = $fw
          Control     = $ctrl.Control
          Description = $ctrl.Description
          Article     = $ctrl.Article
        })
      }
    }
  }

  # Attach compliance references to the finding
  $Finding | Add-Member -NotePropertyName "ComplianceControls" -NotePropertyValue @($complianceRefs) -Force
  return $Finding
}

<#
.SYNOPSIS
  Maps existing findings to compliance framework controls.
.DESCRIPTION
  Takes the findings array from Get-Findings and enriches each finding
  with relevant NIS2, SOC2, and ISO27001 control references based on
  the finding's title and category.
.PARAMETER Findings
  Array of finding objects from Get-Findings.
.NOTES
  Only runs when -Compliance switch is active.
  Does not modify the original findings — returns enriched copies.
#>
function Get-ComplianceFindings {
  param([Parameter(Mandatory)][object[]]$Findings)

  $enriched = New-Object System.Collections.Generic.List[object]

  foreach ($f in $Findings) {
    $controlArea = $null

    # Map finding title to control area
    switch -Wildcard ($f.Title) {
      "*MFA*"                        { $controlArea = "MFA" }
      "*Global Administrator*"       { $controlArea = "PrivilegedAccess" }
      "*Privileged Access*"          { $controlArea = "PrivilegedAccess" }
      "*Risky User*"                 { $controlArea = "IdentityRisk" }
      "*Stale Account*"              { $controlArea = "AccountHygiene" }
      "*Active Account*"             { $controlArea = "AccountHygiene" }
      "*Conditional Access*"         { $controlArea = "AccessGovernance" }
      "*Guest*"                      { $controlArea = "ExternalAccess" }
      "*Data Protection*"            { $controlArea = "DataProtection" }
      "*Configuration at Risk*"      { $controlArea = "ConfigProtection" }
      "*Device Management*"          { $controlArea = "DeviceManagement" }
      "*Zero Trust*"                 { $controlArea = "AccessGovernance" }
      "*Copilot*"                    { $controlArea = "AIGovernance" }
      "*Teams*"                      { $controlArea = "DataProtection" }
      default                        { $controlArea = $null }
    }

    if ($controlArea) {
      $mapped = Add-ComplianceMapping -Finding $f -ControlArea $controlArea
      $enriched.Add($mapped)
    } else {
      $enriched.Add($f)
    }
  }

  return ,$enriched.ToArray()
}

<#
.SYNOPSIS
  Calculates a compliance readiness score per framework.
.DESCRIPTION
  Analyzes findings severity and control coverage to produce a 0-100
  compliance readiness score for each framework. Based on the ratio of
  positive/info findings to total findings in mapped control areas.
.NOTES
  Returns hashtable with per-framework scores and overall.
#>
function Get-ComplianceScores {
  param([Parameter(Mandatory)][object[]]$Findings)

  $frameworks = @("NIS2", "SOC2", "ISO27001")
  $scores = @{}

  foreach ($fw in $frameworks) {
    $mappedFindings = @($Findings | Where-Object {
      $_.PSObject.Properties.Name -contains "ComplianceControls" -and
      @($_.ComplianceControls | Where-Object { $_.Framework -eq $fw }).Count -gt 0
    })

    if ($mappedFindings.Count -eq 0) {
      $scores[$fw] = @{ Score = 0; MappedControls = 0; Status = "No Data" }
      continue
    }

    $totalWeight = 0
    $earnedWeight = 0

    foreach ($f in $mappedFindings) {
      $controlCount = @($f.ComplianceControls | Where-Object { $_.Framework -eq $fw }).Count
      $weight = $controlCount

      switch ($f.Severity) {
        "High"   { $earned = 0;    $weight = $weight * 3 }
        "Medium" { $earned = 0.4;  $weight = $weight * 2 }
        "Low"    { $earned = 0.7;  $weight = $weight * 1 }
        "Info"   { $earned = 1.0;  $weight = $weight * 1 }
        default  { $earned = 0.5;  $weight = $weight * 1 }
      }

      # Positive tone findings earn full weight
      if ($f.Tone -eq "Strong") { $earned = 1.0 }

      $totalWeight += $weight
      $earnedWeight += ($weight * $earned)
    }

    $score = if ($totalWeight -gt 0) { [int][math]::Round(($earnedWeight / $totalWeight) * 100, 0) } else { 0 }
    $maturity = if ($score -ge 80) { "Advanced" } elseif ($score -ge 50) { "Developing" } else { "Initial" }

    $scores[$fw] = @{
      Score          = $score
      MappedControls = @($mappedFindings.ComplianceControls | Where-Object { $_.Framework -eq $fw }).Count
      Maturity       = $maturity
      Status         = "$score/100 ($maturity)"
    }
  }

  # Overall = average of all framework scores
  $avgScore = [int][math]::Round(($scores.Values | ForEach-Object { $_.Score } | Measure-Object -Average).Average, 0)
  $overallMaturity = if ($avgScore -ge 80) { "Advanced" } elseif ($avgScore -ge 50) { "Developing" } else { "Initial" }
  $scores["Overall"] = @{ Score = $avgScore; Maturity = $overallMaturity; Status = "$avgScore/100 ($overallMaturity)" }

  return $scores
}

<#
.SYNOPSIS
  Generates compliance-specific findings that only appear in -Compliance mode.
.DESCRIPTION
  Creates additional findings around regulatory gaps that are derived from
  existing data but only relevant in a compliance assessment context.
.NOTES
  These findings supplement Get-Findings output, not replace it.
#>
function Get-ComplianceSpecificFindings {
  $compFindings = New-Object System.Collections.Generic.List[object]

  # --- Business Continuity Planning (NIS2 Art 21(2)(c)) ---
  $totalDataGB = $script:exGB + $script:odGB + $script:spGB
  if ($totalDataGB -gt 0) {
    $compFindings.Add((New-Finding -Title "Business Continuity Coverage Assessment" `
      -Detail "$('{0:N2}' -f $totalDataGB) GB of Microsoft 365 data identified across $('{0:N0}' -f $script:UsersToProtect) users. NIS2 Article 21(2)(c) requires documented backup, disaster recovery, and crisis management procedures for this data scope." `
      -Severity "Medium" -Category "Compliance" -Tone "Informational"))
  }

  # --- Incident Response Readiness ---
  if ($script:riskyUsers -is [hashtable] -and $script:riskyUsers.Total -gt 0) {
    $compFindings.Add((New-Finding -Title "Incident Detection and Response Capability" `
      -Detail "$($script:riskyUsers.Total) users flagged by Identity Protection. NIS2 Article 23 requires significant incidents to be reported within 24 hours. SOC2 CC7.3 requires documented incident response procedures." `
      -Severity "Medium" -Category "Compliance" -Tone "Opportunity"))
  }

  # --- Copilot AI Governance ---
  if ($script:copilotLicenses -is [int] -and $script:copilotLicenses -gt 0) {
    $compFindings.Add((New-Finding -Title "AI-Generated Content Governance Required" `
      -Detail "$($script:copilotLicenses) Microsoft 365 Copilot licenses detected. AI-generated content creates new data classification obligations under ISO 27001 A.5.12 and data protection requirements." `
      -Severity "Medium" -Category "Compliance" -Tone "Opportunity"))
  }

  # --- Supply Chain (Guest Users) ---
  if ($script:guestUserCount -is [int] -and $script:guestUserCount -gt 10) {
    $compFindings.Add((New-Finding -Title "Third-Party Access Governance" `
      -Detail "$($script:guestUserCount) external guest users with directory access. NIS2 Article 21(2)(d) requires supply chain security measures including third-party access controls and periodic reviews." `
      -Severity "Medium" -Category "Compliance" -Tone "Opportunity"))
  }

  # --- Configuration Management ---
  $configCount = 0
  if ($script:caPolicyCount -is [int]) { $configCount += $script:caPolicyCount }
  if ($script:intuneCompliancePolicies -is [int]) { $configCount += $script:intuneCompliancePolicies }
  if ($script:intuneDeviceConfigurations -is [int]) { $configCount += $script:intuneDeviceConfigurations }
  if ($configCount -gt 0) {
    $compFindings.Add((New-Finding -Title "Configuration Backup for Change Management" `
      -Detail "$configCount security configurations (CA policies, compliance policies, device configs) represent auditable baselines. SOC2 CC8.1 and ISO 27001 A.8.9 require configuration management with backup and recovery capabilities." `
      -Severity "Low" -Category "Compliance" -Tone "Informational"))
  }

  return ,$compFindings.ToArray()
}

