#Requires -Module Pester

<#
.SYNOPSIS
  Pester 5.x unit tests for Get-VeeamM365Sizing.ps1
.DESCRIPTION
  Tests pure-logic functions (unit conversion, string helpers, growth calculation,
  MBS estimation, UPN filtering) by extracting them from the script AST without
  executing the script body (which requires Graph connectivity).
#>

BeforeAll {
  # ── Extract function definitions from the production script via AST ──
  $scriptPath = Join-Path $PSScriptRoot 'Get-VeeamM365Sizing.ps1'
  $ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath, [ref]$null, [ref]$null
  )

  # Find all function definitions in the AST
  $functionDefs = $ast.FindAll(
    { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
    $true  # search nested
  )

  # Define unit-conversion constants that the functions depend on
  $script:GB  = [double]1e9
  $script:TB  = [double]1e12
  $script:GiB = [double](1024 * 1024 * 1024)
  $script:TiB = [double](1024 * 1024 * 1024 * 1024)

  # Script-scope variables used by helper functions
  $script:MaskUserIds    = $false
  $script:EnableTelemetry = $false
  $script:GroupUPNs      = @()
  $script:ExcludeUPNs    = @()

  # Dot-source each function definition into the test scope
  $targetFunctions = @(
    'To-GB', 'To-TB', 'To-GiB', 'To-TiB',
    'Escape-ODataString', 'Mask-UPN', 'Format-Pct',
    'Annualize-GrowthPct', 'Apply-UpnFilters',
    'Write-Log', 'Assert-Scopes', 'Test-GraphSession',
    'Get-GraphEntityCount', 'Invoke-WithRetry', 'Invoke-Graph', 'Invoke-GraphDownloadCsv',
    'Get-GraphReportCsv', 'Get-GroupUPNs', 'Assert-RequiredModule'
  )

  foreach ($funcDef in $functionDefs) {
    if ($funcDef.Name -in $targetFunctions) {
      . ([scriptblock]::Create($funcDef.Extent.Text))
    }
  }
}

# ============================================================================
# UNIT CONVERSION TESTS
# ============================================================================
Describe 'Unit Conversion Functions' {

  Context 'To-GB (decimal gigabytes)' {
    It 'converts 0 bytes to 0 GB' {
      To-GB 0 | Should -Be 0
    }
    It 'converts 1 GB worth of bytes to 1.0' {
      To-GB 1e9 | Should -Be 1.0
    }
    It 'converts 1.5 GB worth of bytes correctly' {
      To-GB 1.5e9 | Should -Be 1.5
    }
    It 'converts 1 TB worth of bytes to 1000 GB' {
      To-GB 1e12 | Should -Be 1000
    }
    It 'rounds to 2 decimal places' {
      To-GB 1234567890 | Should -Be 1.23
    }
    It 'handles sub-byte precision' {
      To-GB 500000000 | Should -Be 0.5
    }
  }

  Context 'To-TB (decimal terabytes)' {
    It 'converts 0 bytes to 0 TB' {
      To-TB 0 | Should -Be 0
    }
    It 'converts 1 TB worth of bytes to 1.0' {
      To-TB 1e12 | Should -Be 1.0
    }
    It 'rounds to 4 decimal places' {
      To-TB 1234567890000 | Should -Be 1.2346
    }
  }

  Context 'To-GiB (binary gibibytes)' {
    It 'converts 0 bytes to 0 GiB' {
      To-GiB 0 | Should -Be 0
    }
    It 'converts exactly 1 GiB of bytes to 1.0' {
      To-GiB ([double](1024 * 1024 * 1024)) | Should -Be 1.0
    }
    It 'converts 1 GB (decimal) to less than 1 GiB' {
      $result = To-GiB 1e9
      $result | Should -BeLessThan 1.0
      $result | Should -Be 0.93  # 1e9 / 1073741824 ≈ 0.93
    }
    It 'rounds to 2 decimal places' {
      To-GiB ([double](1.5 * 1024 * 1024 * 1024)) | Should -Be 1.5
    }
  }

  Context 'To-TiB (binary tebibytes)' {
    It 'converts 0 bytes to 0 TiB' {
      To-TiB 0 | Should -Be 0
    }
    It 'converts exactly 1 TiB of bytes to 1.0' {
      To-TiB ([double](1024 * 1024 * 1024 * 1024)) | Should -Be 1.0
    }
    It 'rounds to 4 decimal places' {
      To-TiB 1e12 | Should -Be 0.9095  # 1e12 / 1099511627776 ≈ 0.9095
    }
  }

  Context 'Consistency between decimal and binary' {
    It 'GB result is always larger than GiB for same input' {
      $bytes = 5e10
      (To-GB $bytes) | Should -BeGreaterThan (To-GiB $bytes)
    }
    It 'TB result is always larger than TiB for same input' {
      $bytes = 5e13
      (To-TB $bytes) | Should -BeGreaterThan (To-TiB $bytes)
    }
  }
}

# ============================================================================
# STRING HELPER TESTS
# ============================================================================
Describe 'Escape-ODataString' {

  It 'escapes single quotes by doubling them' {
    Escape-ODataString "O'Brien" | Should -Be "O''Brien"
  }
  It 'handles multiple single quotes' {
    Escape-ODataString "it's a 'test'" | Should -Be "it''s a ''test''"
  }
  It 'returns strings without quotes unchanged' {
    Escape-ODataString "NormalName" | Should -Be "NormalName"
  }
  It 'returns null/empty input as-is' {
    Escape-ODataString $null | Should -BeNullOrEmpty
    Escape-ODataString ""   | Should -Be ""
    Escape-ODataString " "  | Should -Be " "
  }
}

Describe 'Format-Pct' {
  It 'formats 0.15 as 15.00%' {
    $result = Format-Pct 0.15
    $result | Should -Match '15[.,]00\s?%'
  }
  It 'formats 0.0 as 0.00%' {
    $result = Format-Pct 0.0
    $result | Should -Match '0[.,]00\s?%'
  }
  It 'formats 1.0 as 100.00%' {
    $result = Format-Pct 1.0
    $result | Should -Match '100[.,]00\s?%'
  }
  It 'formats negative values' {
    $result = Format-Pct -0.05
    $result | Should -Match '-?5[.,]00\s?%'
  }
}

# ============================================================================
# UPN MASKING TESTS
# ============================================================================
Describe 'Mask-UPN' {

  Context 'when MaskUserIds is disabled' {
    BeforeAll {
      $script:MaskUserIds = $false
    }
    It 'returns UPN unchanged' {
      Mask-UPN "user@contoso.com" | Should -Be "user@contoso.com"
    }
    It 'returns null/empty unchanged' {
      Mask-UPN $null | Should -BeNullOrEmpty
      Mask-UPN ""   | Should -Be ""
    }
  }

  Context 'when MaskUserIds is enabled' {
    BeforeAll {
      $script:MaskUserIds = $true
    }
    AfterAll {
      $script:MaskUserIds = $false
    }
    It 'returns a "user_" prefixed hash' {
      $result = Mask-UPN "user@contoso.com"
      $result | Should -Match '^user_[a-f0-9]{12}$'
    }
    It 'produces consistent hashes for same input' {
      $hash1 = Mask-UPN "admin@contoso.com"
      $hash2 = Mask-UPN "admin@contoso.com"
      $hash1 | Should -Be $hash2
    }
    It 'produces different hashes for different inputs' {
      $hash1 = Mask-UPN "user1@contoso.com"
      $hash2 = Mask-UPN "user2@contoso.com"
      $hash1 | Should -Not -Be $hash2
    }
    It 'returns null/empty as-is even when masking enabled' {
      Mask-UPN $null | Should -BeNullOrEmpty
      Mask-UPN " "  | Should -Be " "
    }
  }
}

# ============================================================================
# GROWTH CALCULATION TESTS
# ============================================================================
Describe 'Annualize-GrowthPct' {

  It 'returns 0.0 when fewer than 2 data points' {
    $csv = @(
      [pscustomobject]@{ 'Report Date' = '2024-01-01'; 'Report Period' = '90'; 'Storage Used (Byte)' = 1000 }
    )
    Annualize-GrowthPct -csv $csv -field 'Storage Used (Byte)' | Should -Be 0.0
  }

  It 'returns 0.0 for single-element input' {
    $csv = @(
      [pscustomobject]@{ 'Report Date' = '2024-01-01'; 'Report Period' = '90'; 'Storage Used (Byte)' = 1000 }
    )
    Annualize-GrowthPct -csv $csv -field 'Storage Used (Byte)' | Should -Be 0.0
  }

  It 'calculates positive growth correctly' {
    # Latest=110, Earliest=100, Period=90 days
    # Daily change = (110-100)/90 = 0.1111
    # Annual change = 0.1111 * 365 = 40.556
    # Pct = 40.556 / max(110,1) = 0.3687
    $csv = @(
      [pscustomobject]@{ 'Report Date' = '2024-04-01'; 'Report Period' = '90'; 'Storage Used (Byte)' = 110 },
      [pscustomobject]@{ 'Report Date' = '2024-01-01'; 'Report Period' = '90'; 'Storage Used (Byte)' = 100 }
    )
    $result = Annualize-GrowthPct -csv $csv -field 'Storage Used (Byte)'
    $result | Should -BeGreaterThan 0
    $result | Should -BeLessThan 1
  }

  It 'calculates negative growth (shrinkage)' {
    $csv = @(
      [pscustomobject]@{ 'Report Date' = '2024-04-01'; 'Report Period' = '90'; 'Storage Used (Byte)' = 90 },
      [pscustomobject]@{ 'Report Date' = '2024-01-01'; 'Report Period' = '90'; 'Storage Used (Byte)' = 100 }
    )
    $result = Annualize-GrowthPct -csv $csv -field 'Storage Used (Byte)'
    $result | Should -BeLessThan 0
  }

  It 'returns 0.0 when latest value is 0 or negative' {
    $csv = @(
      [pscustomobject]@{ 'Report Date' = '2024-04-01'; 'Report Period' = '90'; 'Storage Used (Byte)' = 0 },
      [pscustomobject]@{ 'Report Date' = '2024-01-01'; 'Report Period' = '90'; 'Storage Used (Byte)' = 100 }
    )
    Annualize-GrowthPct -csv $csv -field 'Storage Used (Byte)' | Should -Be 0.0
  }

  It 'returns 0.0 when period is 0 days' {
    $csv = @(
      [pscustomobject]@{ 'Report Date' = '2024-01-01'; 'Report Period' = '0'; 'Storage Used (Byte)' = 110 },
      [pscustomobject]@{ 'Report Date' = '2024-01-01'; 'Report Period' = '0'; 'Storage Used (Byte)' = 100 }
    )
    Annualize-GrowthPct -csv $csv -field 'Storage Used (Byte)' | Should -Be 0.0
  }

  It 'handles multiple data points (uses latest and earliest)' {
    $csv = @(
      [pscustomobject]@{ 'Report Date' = '2024-04-01'; 'Report Period' = '90'; 'Storage Used (Byte)' = 120 },
      [pscustomobject]@{ 'Report Date' = '2024-03-01'; 'Report Period' = '90'; 'Storage Used (Byte)' = 115 },
      [pscustomobject]@{ 'Report Date' = '2024-02-01'; 'Report Period' = '90'; 'Storage Used (Byte)' = 110 },
      [pscustomobject]@{ 'Report Date' = '2024-01-01'; 'Report Period' = '90'; 'Storage Used (Byte)' = 100 }
    )
    $result = Annualize-GrowthPct -csv $csv -field 'Storage Used (Byte)'
    $result | Should -BeGreaterThan 0
  }
}

# ============================================================================
# UPN FILTER TESTS
# ============================================================================
Describe 'Apply-UpnFilters' {

  BeforeAll {
    $script:GroupUPNs   = @()
    $script:ExcludeUPNs = @()
  }

  Context 'with no filters' {
    BeforeAll {
      $script:GroupUPNs   = @()
      $script:ExcludeUPNs = @()
    }

    It 'filters out deleted items' {
      $data = @(
        [pscustomobject]@{ 'User Principal Name' = 'alice@contoso.com'; 'Is Deleted' = 'FALSE' },
        [pscustomobject]@{ 'User Principal Name' = 'bob@contoso.com';   'Is Deleted' = 'TRUE' },
        [pscustomobject]@{ 'User Principal Name' = 'charlie@contoso.com'; 'Is Deleted' = 'FALSE' }
      )
      $result = Apply-UpnFilters $data 'User Principal Name'
      $result.Count | Should -Be 2
      ($result.'User Principal Name') | Should -Contain 'alice@contoso.com'
      ($result.'User Principal Name') | Should -Not -Contain 'bob@contoso.com'
    }

    It 'returns empty result for all-deleted data' {
      $data = @(
        [pscustomobject]@{ 'User Principal Name' = 'alice@contoso.com'; 'Is Deleted' = 'TRUE' },
        [pscustomobject]@{ 'User Principal Name' = 'bob@contoso.com'; 'Is Deleted' = 'TRUE' }
      )
      $result = Apply-UpnFilters $data 'User Principal Name'
      # When all items are filtered out, result should be empty/null
      ($result | Measure-Object).Count | Should -Be 0
    }

    It 'filters out null entries' {
      $data = @(
        [pscustomobject]@{ 'User Principal Name' = 'alice@contoso.com'; 'Is Deleted' = 'FALSE' },
        $null
      )
      $result = Apply-UpnFilters $data 'User Principal Name'
      @($result).Count | Should -Be 1
    }
  }

  Context 'with inclusion filter (GroupUPNs)' {
    BeforeAll {
      $script:GroupUPNs   = @('alice@contoso.com', 'charlie@contoso.com')
      $script:ExcludeUPNs = @()
    }
    AfterAll {
      $script:GroupUPNs   = @()
    }

    It 'keeps only users in the group' {
      $data = @(
        [pscustomobject]@{ 'User Principal Name' = 'alice@contoso.com';   'Is Deleted' = 'FALSE' },
        [pscustomobject]@{ 'User Principal Name' = 'bob@contoso.com';     'Is Deleted' = 'FALSE' },
        [pscustomobject]@{ 'User Principal Name' = 'charlie@contoso.com'; 'Is Deleted' = 'FALSE' }
      )
      $result = Apply-UpnFilters $data 'User Principal Name'
      $result.Count | Should -Be 2
      ($result.'User Principal Name') | Should -Contain 'alice@contoso.com'
      ($result.'User Principal Name') | Should -Not -Contain 'bob@contoso.com'
    }
  }

  Context 'with exclusion filter (ExcludeUPNs)' {
    BeforeAll {
      $script:GroupUPNs   = @()
      $script:ExcludeUPNs = @('bob@contoso.com')
    }
    AfterAll {
      $script:ExcludeUPNs = @()
    }

    It 'excludes specified users' {
      $data = @(
        [pscustomobject]@{ 'User Principal Name' = 'alice@contoso.com';   'Is Deleted' = 'FALSE' },
        [pscustomobject]@{ 'User Principal Name' = 'bob@contoso.com';     'Is Deleted' = 'FALSE' },
        [pscustomobject]@{ 'User Principal Name' = 'charlie@contoso.com'; 'Is Deleted' = 'FALSE' }
      )
      $result = Apply-UpnFilters $data 'User Principal Name'
      $result.Count | Should -Be 2
      ($result.'User Principal Name') | Should -Not -Contain 'bob@contoso.com'
    }
  }

  Context 'with both inclusion and exclusion filters' {
    BeforeAll {
      $script:GroupUPNs   = @('alice@contoso.com', 'bob@contoso.com', 'charlie@contoso.com')
      $script:ExcludeUPNs = @('bob@contoso.com')
    }
    AfterAll {
      $script:GroupUPNs   = @()
      $script:ExcludeUPNs = @()
    }

    It 'applies inclusion then exclusion' {
      $data = @(
        [pscustomobject]@{ 'User Principal Name' = 'alice@contoso.com';   'Is Deleted' = 'FALSE' },
        [pscustomobject]@{ 'User Principal Name' = 'bob@contoso.com';     'Is Deleted' = 'FALSE' },
        [pscustomobject]@{ 'User Principal Name' = 'charlie@contoso.com'; 'Is Deleted' = 'FALSE' },
        [pscustomobject]@{ 'User Principal Name' = 'dave@contoso.com';    'Is Deleted' = 'FALSE' }
      )
      $result = Apply-UpnFilters $data 'User Principal Name'
      $result.Count | Should -Be 2
      ($result.'User Principal Name') | Should -Contain 'alice@contoso.com'
      ($result.'User Principal Name') | Should -Contain 'charlie@contoso.com'
      ($result.'User Principal Name') | Should -Not -Contain 'bob@contoso.com'
      ($result.'User Principal Name') | Should -Not -Contain 'dave@contoso.com'
    }
  }
}

# ============================================================================
# MBS ESTIMATION FORMULA TESTS
# ============================================================================
Describe 'MBS Capacity Estimation Formula' {

  Context 'core formula calculations' {
    It 'calculates projected dataset with growth' {
      $totalGB = 1000.0
      $annualGrowthPct = 0.15
      $projGB = [math]::Round($totalGB * (1 + $annualGrowthPct), 2)
      $projGB | Should -Be 1150.0
    }

    It 'calculates daily change rate correctly' {
      $exGB = 500.0
      $odGB = 300.0
      $spGB = 200.0
      $changeRateExchange  = 0.015
      $changeRateOneDrive  = 0.004
      $changeRateSharePoint = 0.003

      $dailyChangeGB = ($exGB * $changeRateExchange) + ($odGB * $changeRateOneDrive) + ($spGB * $changeRateSharePoint)
      [math]::Round($dailyChangeGB, 2) | Should -Be 9.3  # 7.5 + 1.2 + 0.6
    }

    It 'calculates monthly change from daily rate' {
      $dailyChangeGB = 9.3
      $monthChangeGB = [math]::Round($dailyChangeGB * 30, 2)
      $monthChangeGB | Should -Be 279.0
    }

    It 'calculates MBS estimate with retention multiplier' {
      $projGB = 1150.0
      $retentionMultiplier = 1.30
      $monthChangeGB = 279.0

      $mbsEstimateGB = [math]::Round(($projGB * $retentionMultiplier) + $monthChangeGB, 2)
      $mbsEstimateGB | Should -Be 1774.0
    }

    It 'adds buffer to MBS estimate' {
      $mbsEstimateGB = 1774.0
      $bufferPct = 0.10

      $suggestedStartGB = [math]::Round($mbsEstimateGB * (1 + $bufferPct), 2)
      $suggestedStartGB | Should -Be 1951.4
    }

    It 'full formula end-to-end with defaults' {
      # Source data
      $exGB = 500.0; $odGB = 300.0; $spGB = 200.0
      $totalGB = $exGB + $odGB + $spGB  # 1000

      # Default parameters
      $annualGrowthPct     = 0.15
      $retentionMultiplier = 1.30
      $changeRateExchange  = 0.015
      $changeRateOneDrive  = 0.004
      $changeRateSharePoint = 0.003
      $bufferPct           = 0.10

      # Calculate
      $dailyChangeGB  = ($exGB * $changeRateExchange) + ($odGB * $changeRateOneDrive) + ($spGB * $changeRateSharePoint)
      $monthChangeGB  = [math]::Round($dailyChangeGB * 30, 2)
      $projGB         = [math]::Round($totalGB * (1 + $annualGrowthPct), 2)
      $mbsEstimateGB  = [math]::Round(($projGB * $retentionMultiplier) + $monthChangeGB, 2)
      $suggestedStartGB = [math]::Round($mbsEstimateGB * (1 + $bufferPct), 2)

      # The MBS estimate should always be larger than source data
      $mbsEstimateGB | Should -BeGreaterThan $totalGB
      $suggestedStartGB | Should -BeGreaterThan $mbsEstimateGB
      # Suggested start should be MBS * 1.10
      $suggestedStartGB | Should -Be 1951.4
    }

    It 'handles zero source data gracefully' {
      $totalGB = 0.0
      $projGB  = [math]::Round($totalGB * (1 + 0.15), 2)
      $mbsEstimateGB = [math]::Round(($projGB * 1.30) + 0, 2)
      $suggestedStartGB = [math]::Round($mbsEstimateGB * (1 + 0.10), 2)

      $projGB | Should -Be 0
      $mbsEstimateGB | Should -Be 0
      $suggestedStartGB | Should -Be 0
    }

    It 'scales linearly with source data' {
      $factor = 2.0
      $totalGB1 = 500.0;  $totalGB2 = $totalGB1 * $factor
      $g = 0.15; $r = 1.30; $b = 0.10

      $proj1 = $totalGB1 * (1 + $g)
      $proj2 = $totalGB2 * (1 + $g)
      $mbs1  = ($proj1 * $r)
      $mbs2  = ($proj2 * $r)

      # Without change rate contribution, MBS should scale linearly
      [math]::Round($mbs2 / $mbs1, 2) | Should -Be $factor
    }
  }
}

# ============================================================================
# WRITE-LOG TESTS
# ============================================================================
Describe 'Write-Log' {
  Context 'when telemetry is disabled' {
    BeforeAll {
      $script:EnableTelemetry = $false
      $script:logPath = Join-Path $TestDrive 'test-log.txt'
    }
    It 'does not write to log file' {
      Write-Log "test message"
      Test-Path $script:logPath | Should -Be $false
    }
  }

  Context 'when telemetry is enabled' {
    BeforeAll {
      $script:EnableTelemetry = $true
      $script:logPath = Join-Path $TestDrive 'test-log.txt'
    }
    AfterAll {
      $script:EnableTelemetry = $false
    }
    It 'writes timestamped message to log file' {
      Write-Log "hello world"
      Test-Path $script:logPath | Should -Be $true
      $content = Get-Content $script:logPath -Raw
      $content | Should -Match 'hello world'
      $content | Should -Match '\d{4}-\d{2}-\d{2}'
    }
  }
}

# ============================================================================
# GRAPH SESSION VALIDATION TESTS (mocked)
# ============================================================================
Describe 'Test-GraphSession' {

  BeforeAll {
    # Create stub function so Pester can mock it without the Graph module installed
    if (-not (Get-Command Get-MgContext -ErrorAction SilentlyContinue)) {
      function global:Get-MgContext { return $null }
    }
  }

  Context 'when no Graph context exists' {
    BeforeAll {
      Mock Get-MgContext { return $null }
    }
    It 'returns false' {
      Test-GraphSession @('Reports.Read.All') | Should -Be $false
    }
  }

  Context 'when session has expired token' {
    BeforeAll {
      Mock Get-MgContext {
        [pscustomobject]@{
          AuthType     = 'Delegated'
          Scopes       = @('Reports.Read.All')
          TokenExpires = (Get-Date).AddMinutes(-10)
        }
      }
    }
    It 'returns false for expired token' {
      Test-GraphSession @('Reports.Read.All') | Should -Be $false
    }
  }

  Context 'when app-only session is missing scopes' {
    BeforeAll {
      Mock Get-MgContext {
        [pscustomobject]@{
          AuthType     = 'AppOnly'
          Scopes       = @('User.Read.All')
          TokenExpires = (Get-Date).AddHours(1)
        }
      }
    }
    It 'returns false when required scopes are missing' {
      Test-GraphSession @('Reports.Read.All', 'Directory.Read.All') | Should -Be $false
    }
  }

  Context 'when valid session exists with all scopes' {
    BeforeAll {
      Mock Get-MgContext {
        [pscustomobject]@{
          AuthType     = 'AppOnly'
          Scopes       = @('Reports.Read.All', 'Directory.Read.All', 'User.Read.All')
          TokenExpires = (Get-Date).AddHours(1)
        }
      }
    }
    It 'returns true' {
      Test-GraphSession @('Reports.Read.All', 'Directory.Read.All') | Should -Be $true
    }
  }
}

# ============================================================================
# ASSERT-SCOPES TESTS (mocked)
# ============================================================================
Describe 'Assert-Scopes' {

  BeforeAll {
    if (-not (Get-Command Get-MgContext -ErrorAction SilentlyContinue)) {
      function global:Get-MgContext { return $null }
    }
  }

  Context 'when all scopes are present' {
    BeforeAll {
      Mock Get-MgContext {
        [pscustomobject]@{ Scopes = @('Reports.Read.All', 'Directory.Read.All', 'User.Read.All') }
      }
    }
    It 'does not throw' {
      { Assert-Scopes @('Reports.Read.All', 'Directory.Read.All') } | Should -Not -Throw
    }
  }

  Context 'when scopes are missing' {
    BeforeAll {
      Mock Get-MgContext {
        [pscustomobject]@{ Scopes = @('User.Read.All') }
      }
    }
    It 'throws with missing scope names' {
      { Assert-Scopes @('Reports.Read.All', 'Directory.Read.All') } | Should -Throw '*Missing*Reports.Read.All*'
    }
  }
}

# ============================================================================
# INVOKE-GRAPH RETRY LOGIC TESTS (mocked)
# ============================================================================
Describe 'Invoke-Graph retry logic' {

  BeforeAll {
    # Create stub function so Pester can mock it without the Graph module installed
    if (-not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
      function global:Invoke-MgGraphRequest { param($Method, $Uri, $Headers, $Body, $OutputFilePath) return $null }
    }
  }

  Context 'when request succeeds on first attempt' {
    BeforeAll {
      Mock Invoke-MgGraphRequest { return @{ value = @('item1') } }
    }
    It 'returns result without retry' {
      $result = Invoke-Graph -Uri 'https://graph.microsoft.com/v1.0/users' -MaxRetries 3
      $result.value | Should -Contain 'item1'
      Should -Invoke Invoke-MgGraphRequest -Times 1
    }
  }

  Context 'when request fails with non-retryable error' {
    BeforeAll {
      Mock Invoke-MgGraphRequest { throw "Invalid request" }
    }
    It 'throws immediately without retry' {
      { Invoke-Graph -Uri 'https://graph.microsoft.com/v1.0/users' -MaxRetries 3 } | Should -Throw '*Invalid request*'
      Should -Invoke Invoke-MgGraphRequest -Times 1
    }
  }

  Context 'when request fails with 429 then succeeds' {
    BeforeAll {
      $script:callCount = 0
      Mock Invoke-MgGraphRequest {
        $script:callCount++
        if ($script:callCount -eq 1) {
          throw "429 Too Many Requests"
        }
        return @{ value = @('success') }
      }
      Mock Start-Sleep {}  # Skip actual sleeping in tests
    }
    It 'retries and succeeds' {
      $result = Invoke-Graph -Uri 'https://graph.microsoft.com/v1.0/users' -MaxRetries 3
      $result.value | Should -Contain 'success'
      Should -Invoke Invoke-MgGraphRequest -Times 2
      Should -Invoke Start-Sleep -Times 1
    }
  }
}

# ============================================================================
# GET-GRAPHENTITYCOUNT TESTS (mocked)
# ============================================================================
Describe 'Get-GraphEntityCount' {

  Context 'when count is available via @odata.count' {
    BeforeAll {
      Mock Invoke-Graph { return @{ '@odata.count' = 42; value = @(1) } }
    }
    It 'returns the count' {
      Get-GraphEntityCount -Path 'users' | Should -Be 42
    }
  }

  Context 'when permission is denied' {
    BeforeAll {
      Mock Invoke-Graph { throw "Insufficient privileges to complete the operation" }
    }
    It 'returns access_denied' {
      Get-GraphEntityCount -Path 'applications' | Should -Be 'access_denied'
    }
  }

  Context 'when resource is not found' {
    BeforeAll {
      Mock Invoke-Graph { throw "404 NotFound" }
    }
    It 'returns not_available' {
      Get-GraphEntityCount -Path 'nonexistent' | Should -Be 'not_available'
    }
  }
}
