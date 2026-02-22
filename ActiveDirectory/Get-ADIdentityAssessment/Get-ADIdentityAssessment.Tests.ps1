#Requires -Module Pester

<#
.SYNOPSIS
  Pester 5.x unit tests for Get-ADIdentityAssessment.ps1
.DESCRIPTION
  Tests complexity scoring, Invoke-ADQuery wrapper, Write-Log, and other
  pure-logic functions by extracting them from the script AST without
  executing the script body (which requires AD module/connectivity).
#>

BeforeAll {
  # ── Extract function definitions from the production script via AST ──
  $scriptPath = Join-Path $PSScriptRoot 'Get-ADIdentityAssessment.ps1'
  $ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath, [ref]$null, [ref]$null
  )

  $functionDefs = $ast.FindAll(
    { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
    $true
  )

  # Script-scope variables used by functions
  $script:logPath        = Join-Path $TestDrive 'test-ad-log.txt'
  $script:SkipModuleCheck = $true
  $script:Full           = $false
  $script:Credential     = $null
  $script:StaleUserDays  = 90
  $script:StaleComputerDays = 90

  # Dot-source each function definition into the test scope
  $targetFunctions = @(
    'Write-Log', 'Assert-ADModule', 'Invoke-ADQuery',
    'Get-EnvironmentComplexity', 'Get-ForestTopology', 'Get-DomainDetail'
  )

  foreach ($funcDef in $functionDefs) {
    if ($funcDef.Name -in $targetFunctions) {
      . ([scriptblock]::Create($funcDef.Extent.Text))
    }
  }
}

# ============================================================================
# WRITE-LOG TESTS
# ============================================================================
Describe 'Write-Log (AD Assessment)' {

  BeforeEach {
    $script:logPath = Join-Path $TestDrive "log-$(Get-Random).txt"
  }

  It 'writes INFO messages to log file' {
    Write-Log -Message "Test info message" -Level 'INFO'
    Test-Path $script:logPath | Should -Be $true
    $content = Get-Content $script:logPath -Raw
    $content | Should -Match '\[INFO\]'
    $content | Should -Match 'Test info message'
  }

  It 'writes WARN messages to log file' {
    Write-Log -Message "Test warning" -Level 'WARN' -WarningAction SilentlyContinue
    $content = Get-Content $script:logPath -Raw
    $content | Should -Match '\[WARN\]'
    $content | Should -Match 'Test warning'
  }

  It 'writes ERROR messages to log file' {
    Write-Log -Message "Test error" -Level 'ERROR' 6>&1 | Out-Null
    $content = Get-Content $script:logPath -Raw
    $content | Should -Match '\[ERROR\]'
  }

  It 'includes timestamp in ISO-like format' {
    Write-Log -Message "timestamp test"
    $content = Get-Content $script:logPath -Raw
    $content | Should -Match '\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}'
  }
}

# ============================================================================
# ASSERT-ADMODULE TESTS
# ============================================================================
Describe 'Assert-ADModule' {

  Context 'when SkipModuleCheck is true' {
    BeforeAll {
      $script:SkipModuleCheck = $true
    }
    It 'returns without error' {
      { Assert-ADModule } | Should -Not -Throw
    }
  }

  Context 'when ActiveDirectory module is not available' {
    BeforeAll {
      $script:SkipModuleCheck = $false
      Mock Get-Module { return $null } -ParameterFilter { $Name -eq 'ActiveDirectory' }
    }
    AfterAll {
      $script:SkipModuleCheck = $true
    }
    It 'throws with installation instructions' {
      { Assert-ADModule } | Should -Throw "*ActiveDirectory*"
    }
  }
}

# ============================================================================
# INVOKE-ADQUERY TESTS
# ============================================================================
Describe 'Invoke-ADQuery' {

  It 'executes query and returns result' {
    $result = Invoke-ADQuery -Description "test" -DefaultValue "fallback" -Query {
      param($Server, $Credential)
      return "success"
    }
    $result | Should -Be "success"
  }

  It 'returns DefaultValue on exception' {
    $result = Invoke-ADQuery -Description "failing query" -DefaultValue "fallback" -Query {
      param($Server, $Credential)
      throw "Simulated AD failure"
    }
    $result | Should -Be "fallback"
  }

  It 'returns $null as DefaultValue when not specified' {
    $result = Invoke-ADQuery -Description "failing query" -Query {
      param($Server, $Credential)
      throw "Simulated AD failure"
    }
    $result | Should -BeNullOrEmpty
  }

  It 'returns numeric DefaultValue' {
    $result = Invoke-ADQuery -Description "count query" -DefaultValue 0 -Query {
      param($Server, $Credential)
      throw "Access denied"
    }
    $result | Should -Be 0
  }

  It 'returns array DefaultValue' {
    $result = Invoke-ADQuery -Description "list query" -DefaultValue @() -Query {
      param($Server, $Credential)
      throw "Network error"
    }
    $result | Should -HaveCount 0
  }

  It 'passes Server parameter to query' {
    $capturedServer = $null
    Invoke-ADQuery -Description "server test" -Server "dc01.contoso.com" -DefaultValue $null -Query {
      param($Server, $Credential)
      $script:capturedServerValue = $Server
      return $Server
    }
    $script:capturedServerValue | Should -Be "dc01.contoso.com"
  }
}

# ============================================================================
# GET-ENVIRONMENTCOMPLEXITY TESTS
# ============================================================================
Describe 'Get-EnvironmentComplexity' {

  BeforeAll {
  # Helper to build a minimal forest topology object
  # Uses [PSCustomObject] for DomainData entries so Measure-Object -Property works correctly
  function New-TestForest {
    param(
      [int]$DomainCount    = 1,
      [int]$SiteCount      = 1,
      [int]$GCCount        = 1,
      [int]$TrustCount     = 0,
      [int]$SiteLinkCount  = 1,
      [array]$DomainData   = @(),
      [array]$UPNSuffixes  = @()
    )
    $trustArr = if ($TrustCount -gt 0) {
      @(1..$TrustCount | ForEach-Object { [PSCustomObject]@{ Source = 'contoso.com'; Target = "partner$_.com" } })
    } else { @() }
    $slArr = if ($SiteLinkCount -gt 0) {
      @(1..$SiteLinkCount | ForEach-Object { [PSCustomObject]@{ Name = "Link$_"; Cost = 100 } })
    } else { @() }
    return [PSCustomObject]@{
      ForestName    = 'contoso.com'
      ForestMode    = 'Windows2016Forest'
      RootDomain    = 'contoso.com'
      Domains       = @(1..$DomainCount | ForEach-Object { "domain$_.contoso.com" })
      DomainCount   = $DomainCount
      GlobalCatalogs = @(1..$GCCount | ForEach-Object { "gc$_.contoso.com" })
      GCCount       = $GCCount
      Sites         = @(1..$SiteCount | ForEach-Object { "Site$_" })
      SiteCount     = $SiteCount
      SchemaMaster  = 'dc01.contoso.com'
      DomainNamingMaster = 'dc01.contoso.com'
      SPNSuffixes   = @()
      UPNSuffixes   = $UPNSuffixes
      SchemaVersion = 88
      DomainData    = $DomainData
      Trusts        = $trustArr
      SiteLinks     = $slArr
      Subnets       = @()
    }
  }

  function New-TestDomain {
    param(
      [int]$EnabledUsers     = 100,
      [int]$DisabledUsers    = 10,
      [int]$EnabledComputers = 50,
      [int]$Groups           = 20,
      [int]$OUs              = 10,
      [int]$GPOs             = 15,
      [int]$ServiceAccounts  = 2,
      [int]$DCCount          = 2,
      [int]$TotalPrivUsers   = 5,
      [int]$FGPPs            = 0,
      [int]$DNSZones         = 1
    )
    $dcArr = if ($DCCount -gt 0) {
      @(1..$DCCount | ForEach-Object { [PSCustomObject]@{ Name = "DC$_" } })
    } else { @() }
    return [PSCustomObject]@{
      DomainName          = 'contoso.com'
      DomainNetBIOS       = 'CONTOSO'
      DomainMode          = 'Windows2016Domain'
      DomainDN            = 'DC=contoso,DC=com'
      PDCEmulator         = 'dc01.contoso.com'
      RIDMaster           = 'dc01.contoso.com'
      InfrastructureMaster = 'dc01.contoso.com'
      EnabledUsers        = $EnabledUsers
      DisabledUsers       = $DisabledUsers
      TotalUsers          = $EnabledUsers + $DisabledUsers
      EnabledComputers    = $EnabledComputers
      Groups              = $Groups
      OUs                 = $OUs
      GPOs                = $GPOs
      ServiceAccounts     = $ServiceAccounts
      FGPPs               = $FGPPs
      DNSZones            = $DNSZones
      DomainControllers   = $dcArr
      DCCount             = $DCCount
      Trusts              = @()
      TrustCount          = 0
      PrivilegedGroups    = @(
        [PSCustomObject]@{ GroupName = 'Domain Admins';  MemberCount = [math]::Ceiling($TotalPrivUsers / 2) },
        [PSCustomObject]@{ GroupName = 'Administrators'; MemberCount = [math]::Floor($TotalPrivUsers / 2) }
      )
      TotalPrivilegedUsers = $TotalPrivUsers
      StaleUsers          = 0
      StaleComputers      = 0
      NeverLoggedOn       = 0
      PwdNeverExpires     = 0
      AdminCountObjects   = 0
    }
  }
  }  # end BeforeAll

  Context 'Composite score ranges' {
    It 'returns Standard tier for simple environment' {
      $domain = New-TestDomain -EnabledUsers 100 -GPOs 5 -DCCount 1 -TotalPrivUsers 3
      $forest = New-TestForest -DomainCount 1 -SiteCount 1 -GCCount 1 -DomainData @($domain)

      $result = Get-EnvironmentComplexity -Forests @($forest)
      $result.Tier | Should -Be 'Standard'
      $result.CompositeScore | Should -BeLessThan 30
    }

    It 'returns Moderate tier for medium environment' {
      $domain = New-TestDomain -EnabledUsers 3000 -GPOs 50 -DCCount 4 -TotalPrivUsers 25 -ServiceAccounts 5
      $forest = New-TestForest -DomainCount 2 -SiteCount 5 -GCCount 3 -DomainData @($domain) -UPNSuffixes @('alt.com')

      $result = Get-EnvironmentComplexity -Forests @($forest)
      $result.Tier | Should -BeIn @('Moderate', 'High')
      $result.CompositeScore | Should -BeGreaterOrEqual 30
    }

    It 'returns High or Critical tier for complex environment' {
      $domain = New-TestDomain -EnabledUsers 25000 -GPOs 250 -DCCount 15 -TotalPrivUsers 75 -ServiceAccounts 20
      $forest = New-TestForest -DomainCount 4 -SiteCount 15 -GCCount 8 -TrustCount 3 -SiteLinkCount 10 -DomainData @($domain) -UPNSuffixes @('alt1.com', 'alt2.com')

      $result = Get-EnvironmentComplexity -Forests @($forest)
      $result.Tier | Should -BeIn @('High', 'Critical')
      $result.CompositeScore | Should -BeGreaterOrEqual 50
    }

    It 'returns Critical tier for enterprise-scale environment' {
      $domain = New-TestDomain -EnabledUsers 60000 -GPOs 600 -DCCount 30 -TotalPrivUsers 120 -ServiceAccounts 50 -DNSZones 20
      $forest1 = New-TestForest -DomainCount 5 -SiteCount 25 -GCCount 15 -TrustCount 5 -SiteLinkCount 20 -DomainData @($domain)
      $forest2 = New-TestForest -DomainCount 2 -SiteCount 5 -GCCount 3 -TrustCount 2 -SiteLinkCount 5 -DomainData @(
        (New-TestDomain -EnabledUsers 10000 -GPOs 100 -DCCount 5 -TotalPrivUsers 30)
      )

      $result = Get-EnvironmentComplexity -Forests @($forest1, $forest2)
      $result.Tier | Should -Be 'Critical'
      $result.CompositeScore | Should -BeGreaterOrEqual 75
    }
  }

  Context 'Score dimensions' {
    It 'has all 7 scoring dimensions' {
      $domain = New-TestDomain
      $forest = New-TestForest -DomainData @($domain)

      $result = Get-EnvironmentComplexity -Forests @($forest)
      $result.Dimensions.Count | Should -Be 7
      $result.Dimensions.Keys | Should -Contain 'ForestTopology'
      $result.Dimensions.Keys | Should -Contain 'IdentityScale'
      $result.Dimensions.Keys | Should -Contain 'ReplicationTopology'
      $result.Dimensions.Keys | Should -Contain 'DCInfrastructure'
      $result.Dimensions.Keys | Should -Contain 'GroupPolicy'
      $result.Dimensions.Keys | Should -Contain 'PrivilegedAccess'
      $result.Dimensions.Keys | Should -Contain 'ServiceDependencies'
    }

    It 'weights sum to 100%' {
      $domain = New-TestDomain
      $forest = New-TestForest -DomainData @($domain)

      $result = Get-EnvironmentComplexity -Forests @($forest)
      $totalWeight = 0
      foreach ($dim in $result.Dimensions.Values) { $totalWeight += $dim.Weight }
      $totalWeight | Should -Be 100
    }

    It 'all dimension scores are between 0 and 100' {
      $domain = New-TestDomain -EnabledUsers 25000 -GPOs 300 -DCCount 10 -TotalPrivUsers 60
      $forest = New-TestForest -DomainCount 3 -SiteCount 10 -GCCount 5 -DomainData @($domain)

      $result = Get-EnvironmentComplexity -Forests @($forest)
      foreach ($dim in $result.Dimensions.Values) {
        $dim.Score | Should -BeGreaterOrEqual 0
        $dim.Score | Should -BeLessOrEqual 100
      }
    }
  }

  Context 'Identity scale scoring bands' {
    It 'scores 15 for less than 1000 users' {
      $domain = New-TestDomain -EnabledUsers 500
      $forest = New-TestForest -DomainData @($domain)

      $result = Get-EnvironmentComplexity -Forests @($forest)
      $result.Dimensions['IdentityScale'].Score | Should -Be 15
    }

    It 'scores 30 for 1000-5000 users' {
      $domain = New-TestDomain -EnabledUsers 2000
      $forest = New-TestForest -DomainData @($domain)

      $result = Get-EnvironmentComplexity -Forests @($forest)
      $result.Dimensions['IdentityScale'].Score | Should -Be 30
    }

    It 'scores 50 for 5000-20000 users' {
      $domain = New-TestDomain -EnabledUsers 10000
      $forest = New-TestForest -DomainData @($domain)

      $result = Get-EnvironmentComplexity -Forests @($forest)
      $result.Dimensions['IdentityScale'].Score | Should -Be 50
    }

    It 'scores 70 for 20000-50000 users' {
      $domain = New-TestDomain -EnabledUsers 30000
      $forest = New-TestForest -DomainData @($domain)

      $result = Get-EnvironmentComplexity -Forests @($forest)
      $result.Dimensions['IdentityScale'].Score | Should -Be 70
    }

    It 'scores 90 for 50000+ users' {
      $domain = New-TestDomain -EnabledUsers 60000
      $forest = New-TestForest -DomainData @($domain)

      $result = Get-EnvironmentComplexity -Forests @($forest)
      $result.Dimensions['IdentityScale'].Score | Should -Be 90
    }
  }

  Context 'GPO scoring bands' {
    It 'scores 15 for < 30 GPOs' {
      $domain = New-TestDomain -GPOs 10
      $forest = New-TestForest -DomainData @($domain)

      $result = Get-EnvironmentComplexity -Forests @($forest)
      $result.Dimensions['GroupPolicy'].Score | Should -Be 15
    }

    It 'scores 35 for 30-100 GPOs' {
      $domain = New-TestDomain -GPOs 50
      $forest = New-TestForest -DomainData @($domain)

      $result = Get-EnvironmentComplexity -Forests @($forest)
      $result.Dimensions['GroupPolicy'].Score | Should -Be 35
    }

    It 'scores 55 for 100-200 GPOs' {
      $domain = New-TestDomain -GPOs 150
      $forest = New-TestForest -DomainData @($domain)

      $result = Get-EnvironmentComplexity -Forests @($forest)
      $result.Dimensions['GroupPolicy'].Score | Should -Be 55
    }

    It 'scores 75 for 200-500 GPOs' {
      $domain = New-TestDomain -GPOs 300
      $forest = New-TestForest -DomainData @($domain)

      $result = Get-EnvironmentComplexity -Forests @($forest)
      $result.Dimensions['GroupPolicy'].Score | Should -Be 75
    }

    It 'scores 95 for 500+ GPOs' {
      $domain = New-TestDomain -GPOs 600
      $forest = New-TestForest -DomainData @($domain)

      $result = Get-EnvironmentComplexity -Forests @($forest)
      $result.Dimensions['GroupPolicy'].Score | Should -Be 95
    }
  }

  Context 'Privileged access scoring bands' {
    It 'scores 20 for < 20 privileged users' {
      $domain = New-TestDomain -TotalPrivUsers 10
      $forest = New-TestForest -DomainData @($domain)

      $result = Get-EnvironmentComplexity -Forests @($forest)
      $result.Dimensions['PrivilegedAccess'].Score | Should -Be 20
    }

    It 'scores 45 for 20-50 privileged users' {
      $domain = New-TestDomain -TotalPrivUsers 30
      $forest = New-TestForest -DomainData @($domain)

      $result = Get-EnvironmentComplexity -Forests @($forest)
      $result.Dimensions['PrivilegedAccess'].Score | Should -Be 45
    }

    It 'scores 70 for 50-100 privileged users' {
      $domain = New-TestDomain -TotalPrivUsers 75
      $forest = New-TestForest -DomainData @($domain)

      $result = Get-EnvironmentComplexity -Forests @($forest)
      $result.Dimensions['PrivilegedAccess'].Score | Should -Be 70
    }

    It 'scores 90 for 100+ privileged users' {
      $domain = New-TestDomain -TotalPrivUsers 150
      $forest = New-TestForest -DomainData @($domain)

      $result = Get-EnvironmentComplexity -Forests @($forest)
      $result.Dimensions['PrivilegedAccess'].Score | Should -Be 90
    }
  }

  Context 'Totals aggregation' {
    It 'correctly aggregates totals from single forest' {
      $domain = New-TestDomain -EnabledUsers 500 -EnabledComputers 200 -Groups 30 -OUs 15 -GPOs 10 -DCCount 2 -ServiceAccounts 3 -TotalPrivUsers 5
      $forest = New-TestForest -DomainCount 1 -SiteCount 2 -GCCount 1 -DomainData @($domain)

      $result = Get-EnvironmentComplexity -Forests @($forest)
      $result.Totals.Forests | Should -Be 1
      $result.Totals.Domains | Should -Be 1
      $result.Totals.Sites | Should -Be 2
      $result.Totals.EnabledUsers | Should -Be 500
      $result.Totals.EnabledComputers | Should -Be 200
      $result.Totals.Groups | Should -Be 30
      $result.Totals.OUs | Should -Be 15
      $result.Totals.GPOs | Should -Be 10
      $result.Totals.DomainControllers | Should -Be 2
      $result.Totals.ServiceAccounts | Should -Be 3
      $result.Totals.PrivilegedUsers | Should -Be 5
    }

    It 'correctly aggregates totals from multiple forests' {
      $domain1 = New-TestDomain -EnabledUsers 500 -GPOs 10 -DCCount 2
      $domain2 = New-TestDomain -EnabledUsers 300 -GPOs 20 -DCCount 3
      $forest1 = New-TestForest -DomainCount 1 -SiteCount 2 -GCCount 1 -DomainData @($domain1)
      $forest2 = New-TestForest -DomainCount 1 -SiteCount 3 -GCCount 2 -DomainData @($domain2)

      $result = Get-EnvironmentComplexity -Forests @($forest1, $forest2)
      $result.Totals.Forests | Should -Be 2
      $result.Totals.EnabledUsers | Should -Be 800
      $result.Totals.GPOs | Should -Be 30
      $result.Totals.DomainControllers | Should -Be 5
      $result.Totals.Sites | Should -Be 5
    }
  }

  Context 'Recovery considerations' {
    It 'flags multi-forest topology' {
      $domain = New-TestDomain
      $forest1 = New-TestForest -DomainData @($domain)
      $forest2 = New-TestForest -DomainData @($domain)

      $result = Get-EnvironmentComplexity -Forests @($forest1, $forest2)
      ($result.RecoveryConsiderations | Where-Object { $_ -match 'Multi-forest' }).Count | Should -BeGreaterThan 0
    }

    It 'flags trust relationships' {
      $domain = New-TestDomain
      $forest = New-TestForest -TrustCount 3 -DomainData @($domain)

      $result = Get-EnvironmentComplexity -Forests @($forest)
      ($result.RecoveryConsiderations | Where-Object { $_ -match 'trust relationship' }).Count | Should -BeGreaterThan 0
    }

    It 'flags large GPO count' {
      $domain = New-TestDomain -GPOs 200
      $forest = New-TestForest -DomainData @($domain)

      $result = Get-EnvironmentComplexity -Forests @($forest)
      ($result.RecoveryConsiderations | Where-Object { $_ -match 'Group Policy' }).Count | Should -BeGreaterThan 0
    }

    It 'flags high privileged user count' {
      $domain = New-TestDomain -TotalPrivUsers 75
      $forest = New-TestForest -DomainData @($domain)

      $result = Get-EnvironmentComplexity -Forests @($forest)
      ($result.RecoveryConsiderations | Where-Object { $_ -match 'privileged' }).Count | Should -BeGreaterThan 0
    }

    It 'flags large user base' {
      $domain = New-TestDomain -EnabledUsers 15000
      $forest = New-TestForest -DomainData @($domain)

      $result = Get-EnvironmentComplexity -Forests @($forest)
      ($result.RecoveryConsiderations | Where-Object { $_ -match 'user objects' }).Count | Should -BeGreaterThan 0
    }

    It 'flags managed service accounts' {
      $domain = New-TestDomain -ServiceAccounts 5
      $forest = New-TestForest -DomainData @($domain)

      $result = Get-EnvironmentComplexity -Forests @($forest)
      ($result.RecoveryConsiderations | Where-Object { $_ -match 'managed service account' }).Count | Should -BeGreaterThan 0
    }

    It 'flags fine-grained password policies' {
      $domain = New-TestDomain -FGPPs 3
      $forest = New-TestForest -DomainData @($domain)

      $result = Get-EnvironmentComplexity -Forests @($forest)
      ($result.RecoveryConsiderations | Where-Object { $_ -match 'fine-grained password' }).Count | Should -BeGreaterThan 0
    }

    It 'returns no considerations for minimal environment' {
      $domain = New-TestDomain -EnabledUsers 100 -GPOs 5 -DCCount 1 -TotalPrivUsers 3 -ServiceAccounts 0 -FGPPs 0
      $forest = New-TestForest -DomainCount 1 -SiteCount 1 -GCCount 1 -TrustCount 0 -DomainData @($domain)

      $result = Get-EnvironmentComplexity -Forests @($forest)
      $result.RecoveryConsiderations.Count | Should -Be 0
    }
  }

  Context 'Tier boundary values' {
    It 'tier boundary: score 29 is Standard' {
      # This tests the boundary condition at exactly 30
      $domain = New-TestDomain -EnabledUsers 100 -GPOs 5 -DCCount 1 -TotalPrivUsers 3
      $forest = New-TestForest -DomainCount 1 -SiteCount 1 -GCCount 1 -DomainData @($domain)

      $result = Get-EnvironmentComplexity -Forests @($forest)
      if ($result.CompositeScore -lt 30) {
        $result.Tier | Should -Be 'Standard'
      }
    }

    It 'composite score is between 0 and 100' {
      $domain = New-TestDomain
      $forest = New-TestForest -DomainData @($domain)

      $result = Get-EnvironmentComplexity -Forests @($forest)
      $result.CompositeScore | Should -BeGreaterOrEqual 0
      $result.CompositeScore | Should -BeLessOrEqual 100
    }
  }
}

# ============================================================================
# FOREST TOPOLOGY STRUCTURE TESTS
# ============================================================================
Describe 'Forest topology data structure' {

  It 'Get-ForestTopology returns null for unreachable forest' {
    Mock Invoke-ADQuery { return $null } -ParameterFilter { $Description -match 'Get-ADForest' }

    $result = Get-ForestTopology -ForestName 'unreachable.com'
    $result | Should -BeNullOrEmpty
  }
}

# ============================================================================
# DOMAIN DETAIL STRUCTURE TESTS
# ============================================================================
Describe 'Domain detail data structure' {

  It 'Get-DomainDetail returns null when domain is unreachable' {
    Mock Invoke-ADQuery { return $null } -ParameterFilter { $Description -match 'Get-ADDomain' }

    $result = Get-DomainDetail -DomainName 'unreachable.com'
    $result | Should -BeNullOrEmpty
  }
}

# ============================================================================
# SCRIPT PARAMETER VALIDATION TESTS
# ============================================================================
Describe 'Script parameter definitions' {

  BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot 'Get-ADIdentityAssessment.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
      $scriptPath, [ref]$null, [ref]$null
    )
    $script:paramBlock = $ast.ParamBlock
  }

  It 'has CmdletBinding attribute' {
    $ast.ParamBlock | Should -Not -BeNullOrEmpty
    $attrs = $ast.FindAll(
      { param($node) $node -is [System.Management.Automation.Language.AttributeAst] -and $node.TypeName.Name -eq 'CmdletBinding' },
      $true
    )
    $attrs.Count | Should -BeGreaterThan 0
  }

  It 'StaleUserDays has ValidateRange(30, 730)' {
    $params = $ast.ParamBlock.Parameters
    $staleParam = $params | Where-Object { $_.Name.VariablePath.UserPath -eq 'StaleUserDays' }
    $staleParam | Should -Not -BeNullOrEmpty
    $rangeAttr = $staleParam.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateRange' }
    $rangeAttr | Should -Not -BeNullOrEmpty
  }

  It 'StaleComputerDays has ValidateRange(30, 730)' {
    $params = $ast.ParamBlock.Parameters
    $staleParam = $params | Where-Object { $_.Name.VariablePath.UserPath -eq 'StaleComputerDays' }
    $staleParam | Should -Not -BeNullOrEmpty
    $rangeAttr = $staleParam.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateRange' }
    $rangeAttr | Should -Not -BeNullOrEmpty
  }

  It 'ForestNames parameter exists and accepts string array' {
    $params = $ast.ParamBlock.Parameters
    $forestParam = $params | Where-Object { $_.Name.VariablePath.UserPath -eq 'ForestNames' }
    $forestParam | Should -Not -BeNullOrEmpty
  }

  It 'has Full switch parameter' {
    $params = $ast.ParamBlock.Parameters
    $fullParam = $params | Where-Object { $_.Name.VariablePath.UserPath -eq 'Full' }
    $fullParam | Should -Not -BeNullOrEmpty
  }
}

# ============================================================================
# M365 SCRIPT PARAMETER VALIDATION TESTS
# ============================================================================
Describe 'M365 Sizing script parameter definitions' {

  BeforeAll {
    $m365Path = Join-Path (Split-Path $PSScriptRoot -Parent) 'Get-VeeamM365Sizing' 'Get-VeeamM365Sizing.ps1'
    if (-not (Test-Path $m365Path)) {
      $m365Path = Join-Path $PSScriptRoot '..' '..' 'M365' 'Get-VeeamM365Sizing' 'Get-VeeamM365Sizing.ps1'
    }
    $script:m365Ast = [System.Management.Automation.Language.Parser]::ParseFile(
      $m365Path, [ref]$null, [ref]$null
    )
  }

  It 'has CmdletBinding attribute' {
    $attrs = $script:m365Ast.FindAll(
      { param($node) $node -is [System.Management.Automation.Language.AttributeAst] -and $node.TypeName.Name -eq 'CmdletBinding' },
      $true
    )
    $attrs.Count | Should -BeGreaterThan 0
  }

  It 'Period parameter has ValidateSet(7,30,90,180)' {
    $params = $script:m365Ast.ParamBlock.Parameters
    $periodParam = $params | Where-Object { $_.Name.VariablePath.UserPath -eq 'Period' }
    $periodParam | Should -Not -BeNullOrEmpty
    $validateSet = $periodParam.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }
    $validateSet | Should -Not -BeNullOrEmpty
  }

  It 'AnnualGrowthPct has ValidateRange(0.0, 5.0)' {
    $params = $script:m365Ast.ParamBlock.Parameters
    $param = $params | Where-Object { $_.Name.VariablePath.UserPath -eq 'AnnualGrowthPct' }
    $param | Should -Not -BeNullOrEmpty
    $rangeAttr = $param.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateRange' }
    $rangeAttr | Should -Not -BeNullOrEmpty
  }

  It 'RetentionMultiplier has ValidateRange(1.0, 10.0)' {
    $params = $script:m365Ast.ParamBlock.Parameters
    $param = $params | Where-Object { $_.Name.VariablePath.UserPath -eq 'RetentionMultiplier' }
    $param | Should -Not -BeNullOrEmpty
    $rangeAttr = $param.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateRange' }
    $rangeAttr | Should -Not -BeNullOrEmpty
  }

  It 'has Quick and Full parameter sets' {
    $params = $script:m365Ast.ParamBlock.Parameters
    $quickParam = $params | Where-Object { $_.Name.VariablePath.UserPath -eq 'Quick' }
    $fullParam  = $params | Where-Object { $_.Name.VariablePath.UserPath -eq 'Full' }
    $quickParam | Should -Not -BeNullOrEmpty
    $fullParam  | Should -Not -BeNullOrEmpty
  }

  It 'has all authentication parameters' {
    $params = $script:m365Ast.ParamBlock.Parameters
    $authParams = @('TenantId', 'ClientId', 'ClientSecret', 'CertificateThumbprint',
                    'CertificateSubjectName', 'UseManagedIdentity', 'UseDeviceCode', 'AccessToken')
    foreach ($name in $authParams) {
      $p = $params | Where-Object { $_.Name.VariablePath.UserPath -eq $name }
      $p | Should -Not -BeNullOrEmpty -Because "parameter $name should exist"
    }
  }
}
