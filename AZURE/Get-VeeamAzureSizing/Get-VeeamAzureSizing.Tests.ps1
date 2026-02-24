#Requires -Modules Pester
<#
.SYNOPSIS
  Pester tests for Get-VeeamAzureSizing.ps1

.DESCRIPTION
  Validates script syntax, parameter definitions, helper function logic,
  and module requirement checks. These tests run offline without Azure connectivity.

.NOTES
  Run with: Invoke-Pester -Path .\Get-VeeamAzureSizing.Tests.ps1 -Output Detailed
#>

BeforeAll {
  $script:ScriptPath = Join-Path $PSScriptRoot 'Get-VeeamAzureSizing.ps1'

  # Parse AST without executing the script
  $script:ParseErrors = $null
  $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $script:ScriptPath, [ref]$null, [ref]$script:ParseErrors
  )

  # Extract all function definitions from the AST
  $script:FunctionDefs = $script:Ast.FindAll(
    { $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false
  )

  # Load helper functions into test scope (only non-Azure-dependent functions)
  $helperFunctions = @(
    'Test-RegionMatch', 'Test-TagMatch', 'ConvertTo-FlatTagString',
    '_ParseResourceId', 'Format-BytesToGB', 'Format-BytesToTB', 'Write-Log'
  )
  foreach ($fn in $script:FunctionDefs) {
    if ($fn.Name -in $helperFunctions) {
      Invoke-Expression $fn.Extent.Text
    }
  }

  # Set up script-scoped variables that helper functions depend on
  $script:LogEntries = New-Object System.Collections.Generic.List[object]
}

Describe 'Get-VeeamAzureSizing Script Validation' {

  Context 'Syntax and Structure' {

    It 'Has no syntax errors' {
      $script:ParseErrors | Should -BeNullOrEmpty
    }

    It 'Includes #Requires -Version 5.1' {
      $content = Get-Content $script:ScriptPath -Raw
      $content | Should -Match '#Requires\s+-Version\s+5\.1'
    }

    It 'Sets $ErrorActionPreference to Stop' {
      $content = Get-Content $script:ScriptPath -Raw
      $content | Should -Match '\$ErrorActionPreference\s*=\s*"Stop"'
    }

    It 'Has a CmdletBinding attribute' {
      $script:Ast.ParamBlock | Should -Not -BeNullOrEmpty
      $bindingAttr = $script:Ast.ParamBlock.Attributes | Where-Object {
        $_.TypeName.Name -eq 'CmdletBinding'
      }
      $bindingAttr | Should -Not -BeNullOrEmpty
    }

    It 'Uses DefaultParameterSetName for authentication' {
      $bindingAttr = $script:Ast.ParamBlock.Attributes | Where-Object {
        $_.TypeName.Name -eq 'CmdletBinding'
      }
      $bindingText = $bindingAttr.Extent.Text
      $bindingText | Should -Match 'DefaultParameterSetName'
    }

    It 'Has comment-based help' {
      $content = Get-Content $script:ScriptPath -Raw
      $content | Should -Match '\.SYNOPSIS'
      $content | Should -Match '\.DESCRIPTION'
      $content | Should -Match '\.PARAMETER'
      $content | Should -Match '\.EXAMPLE'
      $content | Should -Match '\.NOTES'
    }
  }

  Context 'Parameter Definitions' {

    BeforeAll {
      $script:ParamNames = $script:Ast.ParamBlock.Parameters.Name.VariablePath.UserPath
    }

    It 'Defines the Subscriptions parameter' {
      $script:ParamNames | Should -Contain 'Subscriptions'
    }

    It 'Defines the TenantId parameter' {
      $script:ParamNames | Should -Contain 'TenantId'
    }

    It 'Defines the Region parameter' {
      $script:ParamNames | Should -Contain 'Region'
    }

    It 'Defines the TagFilter parameter' {
      $script:ParamNames | Should -Contain 'TagFilter'
    }

    It 'Defines all authentication parameters' {
      $script:ParamNames | Should -Contain 'UseManagedIdentity'
      $script:ParamNames | Should -Contain 'ServicePrincipalId'
      $script:ParamNames | Should -Contain 'ServicePrincipalSecret'
      $script:ParamNames | Should -Contain 'CertificateThumbprint'
      $script:ParamNames | Should -Contain 'UseDeviceCode'
    }

    It 'Defines Veeam sizing parameters with validation' {
      $script:ParamNames | Should -Contain 'SnapshotRetentionDays'
      $script:ParamNames | Should -Contain 'RepositoryOverhead'

      # Check ValidateRange exists on SnapshotRetentionDays
      $snapshotParam = $script:Ast.ParamBlock.Parameters | Where-Object {
        $_.Name.VariablePath.UserPath -eq 'SnapshotRetentionDays'
      }
      $validateAttr = $snapshotParam.Attributes | Where-Object {
        $_.TypeName.Name -eq 'ValidateRange'
      }
      $validateAttr | Should -Not -BeNullOrEmpty
    }

    It 'Defines output parameters' {
      $script:ParamNames | Should -Contain 'OutputPath'
      $script:ParamNames | Should -Contain 'GenerateHTML'
      $script:ParamNames | Should -Contain 'ZipOutput'
    }
  }

  Context 'Function Naming Conventions' {

    It 'All public functions use approved PowerShell verbs' {
      $approvedVerbs = (Get-Verb).Verb

      foreach ($fn in $script:FunctionDefs) {
        # Skip private helper functions (prefixed with underscore)
        if ($fn.Name.StartsWith('_')) { continue }

        $verb = ($fn.Name -split '-')[0]
        $verb | Should -BeIn $approvedVerbs -Because "Function '$($fn.Name)' should use an approved verb (found '$verb')"
      }
    }

    It 'No functions have hyphens in the noun part' {
      foreach ($fn in $script:FunctionDefs) {
        if ($fn.Name.StartsWith('_')) { continue }
        $parts = $fn.Name -split '-'
        # Verb-Noun should have exactly 2 parts
        $parts.Count | Should -BeLessOrEqual 2 -Because "Function '$($fn.Name)' should follow Verb-Noun convention without extra hyphens"
      }
    }

    It 'Defines expected helper functions' {
      $fnNames = $script:FunctionDefs.Name
      $fnNames | Should -Contain 'Write-Log'
      $fnNames | Should -Contain 'Write-ProgressStep'
      $fnNames | Should -Contain 'Test-RegionMatch'
      $fnNames | Should -Contain 'Test-TagMatch'
      $fnNames | Should -Contain 'ConvertTo-FlatTagString'
      $fnNames | Should -Contain '_ParseResourceId'
      $fnNames | Should -Contain 'Format-BytesToGB'
      $fnNames | Should -Contain 'Format-BytesToTB'
    }

    It 'Defines expected Azure functions' {
      $fnNames = $script:FunctionDefs.Name
      $fnNames | Should -Contain 'Test-AzSession'
      $fnNames | Should -Contain 'Connect-AzureModern'
      $fnNames | Should -Contain 'Resolve-Subscriptions'
      $fnNames | Should -Contain 'Get-VMInventory'
      $fnNames | Should -Contain 'Get-SqlInventory'
      $fnNames | Should -Contain 'Get-StorageInventory'
      $fnNames | Should -Contain 'Get-AzureBackupInventory'
      $fnNames | Should -Contain 'Measure-VeeamSizing'
      $fnNames | Should -Contain 'New-HtmlReport'
    }
  }

  Context 'Module Requirements' {

    It 'Checks for all required Azure modules' {
      $content = Get-Content $script:ScriptPath -Raw
      $content | Should -Match 'Az\.Accounts'
      $content | Should -Match 'Az\.Resources'
      $content | Should -Match 'Az\.Compute'
      $content | Should -Match 'Az\.Network'
      $content | Should -Match 'Az\.Sql'
      $content | Should -Match 'Az\.Storage'
      $content | Should -Match 'Az\.RecoveryServices'
    }
  }

  Context 'Azure Backup API Usage' {

    It 'Uses -VaultId parameter instead of deprecated Set-AzRecoveryServicesVaultContext' {
      $content = Get-Content $script:ScriptPath -Raw
      $content | Should -Not -Match 'Set-AzRecoveryServicesVaultContext'
      $content | Should -Match 'Get-AzRecoveryServicesBackupItem.*-VaultId'
    }

    It 'Specifies mandatory -BackupManagementType and -WorkloadType for backup item queries' {
      $content = Get-Content $script:ScriptPath -Raw
      $content | Should -Match 'Get-AzRecoveryServicesBackupItem\s+-BackupManagementType\s+AzureIaasVM\s+-WorkloadType\s+AzureVM'
      $content | Should -Match 'Get-AzRecoveryServicesBackupItem\s+-BackupManagementType\s+AzureWorkload\s+-WorkloadType\s+MSSQL'
      $content | Should -Match 'Get-AzRecoveryServicesBackupItem\s+-BackupManagementType\s+AzureStorage\s+-WorkloadType\s+AzureFiles'
    }

    It 'Uses -VaultId for backup protection policy queries' {
      $content = Get-Content $script:ScriptPath -Raw
      $content | Should -Match 'Get-AzRecoveryServicesBackupProtectionPolicy\s+-VaultId'
    }
  }

  Context 'Cross-Platform Compatibility' {

    It 'Uses Join-Path for ZIP archive path construction' {
      $content = Get-Content $script:ScriptPath -Raw
      # Should not use backslash glob pattern directly
      $content | Should -Not -Match 'Compress-Archive.*\$OutputPath\\\*'
      # Should use Join-Path or variable
      $content | Should -Match '\$zipItems\s*=\s*Join-Path'
    }

    It 'Uses Join-Path for output file paths' {
      $lines = Get-Content $script:ScriptPath
      ($lines | Select-String 'Join-Path \$OutputPath').Count | Should -BeGreaterThan 5
    }
  }
}

Describe 'Helper Function Unit Tests' {

  Context 'Test-RegionMatch' {

    It 'Returns $true when no region filter is set' {
      $Region = $null
      Test-RegionMatch -ResourceRegion 'eastus' | Should -BeTrue
    }

    It 'Returns $true when region matches (case-insensitive)' {
      $Region = 'eastus'
      Test-RegionMatch -ResourceRegion 'EastUS' | Should -BeTrue
    }

    It 'Returns $false when region does not match' {
      $Region = 'westus'
      Test-RegionMatch -ResourceRegion 'eastus' | Should -BeFalse
    }

    It 'Returns $true for empty region filter' {
      $Region = ''
      Test-RegionMatch -ResourceRegion 'eastus' | Should -BeTrue
    }
  }

  Context 'Test-TagMatch' {

    It 'Returns $true when no tag filter is set' {
      $TagFilter = $null
      Test-TagMatch -Tags @{ "Env" = "Prod" } | Should -BeTrue
    }

    It 'Returns $true when tag filter is empty hashtable' {
      $TagFilter = @{}
      Test-TagMatch -Tags @{ "Env" = "Prod" } | Should -BeTrue
    }

    It 'Returns $true when all filter tags match' {
      $TagFilter = @{ "Env" = "Prod"; "Team" = "IT" }
      Test-TagMatch -Tags @{ "Env" = "Prod"; "Team" = "IT"; "Extra" = "Value" } | Should -BeTrue
    }

    It 'Returns $false when a filter tag key is missing' {
      $TagFilter = @{ "Env" = "Prod"; "Team" = "IT" }
      Test-TagMatch -Tags @{ "Env" = "Prod" } | Should -BeFalse
    }

    It 'Returns $false when a filter tag value does not match' {
      $TagFilter = @{ "Env" = "Prod" }
      Test-TagMatch -Tags @{ "Env" = "Dev" } | Should -BeFalse
    }

    It 'Returns $false when resource has no tags' {
      $TagFilter = @{ "Env" = "Prod" }
      Test-TagMatch -Tags $null | Should -BeFalse
    }

    It 'Matches when filter value is $null (key-only filter)' {
      $TagFilter = @{ "Env" = $null }
      Test-TagMatch -Tags @{ "Env" = "anything" } | Should -BeTrue
    }
  }

  Context 'ConvertTo-FlatTagString' {

    It 'Returns empty string for null tags' {
      ConvertTo-FlatTagString -Tags $null | Should -BeExactly ""
    }

    It 'Returns empty string for empty hashtable' {
      ConvertTo-FlatTagString -Tags @{} | Should -BeExactly ""
    }

    It 'Converts single tag to Key=Value format' {
      ConvertTo-FlatTagString -Tags @{ "Env" = "Prod" } | Should -BeExactly "Env=Prod"
    }

    It 'Sorts multiple tags alphabetically and joins with semicolons' {
      $result = ConvertTo-FlatTagString -Tags @{ "Zebra" = "Z"; "Alpha" = "A"; "Middle" = "M" }
      $result | Should -BeExactly "Alpha=A;Middle=M;Zebra=Z"
    }
  }

  Context '_ParseResourceId' {

    It 'Extracts components from a NIC resource ID' {
      $id = '/subscriptions/sub-123/resourceGroups/myRG/providers/Microsoft.Network/networkInterfaces/myNIC'
      $result = _ParseResourceId -ResourceId $id
      $result.SubscriptionId | Should -BeExactly 'sub-123'
      $result.ResourceGroupName | Should -BeExactly 'myRG'
      $result.ProviderNamespace | Should -BeExactly 'Microsoft.Network'
      $result.ResourceType | Should -BeExactly 'networkInterfaces'
      $result.Name | Should -BeExactly 'myNIC'
    }

    It 'Extracts components from a VM resource ID' {
      $id = '/subscriptions/aaaabbbb-1234/resourceGroups/Production-RG/providers/Microsoft.Compute/virtualMachines/WebServer01'
      $result = _ParseResourceId -ResourceId $id
      $result.SubscriptionId | Should -BeExactly 'aaaabbbb-1234'
      $result.ResourceGroupName | Should -BeExactly 'Production-RG'
      $result.Name | Should -BeExactly 'WebServer01'
    }

    It 'Handles resource IDs with special characters in names' {
      $id = '/subscriptions/sub-1/resourceGroups/rg-test-01/providers/Microsoft.Storage/storageAccounts/sa01'
      $result = _ParseResourceId -ResourceId $id
      $result.ResourceGroupName | Should -BeExactly 'rg-test-01'
      $result.Name | Should -BeExactly 'sa01'
    }
  }

  Context 'Format-BytesToGB' {

    It 'Converts 0 bytes to 0 GB' {
      Format-BytesToGB -Bytes 0 | Should -Be 0
    }

    It 'Converts 1 GB in bytes to 1 GB' {
      Format-BytesToGB -Bytes 1073741824 | Should -Be 1
    }

    It 'Rounds to 2 decimal places' {
      # 1.5 GB = 1610612736 bytes
      Format-BytesToGB -Bytes 1610612736 | Should -Be 1.5
    }

    It 'Handles large values' {
      # 100 GB = 107374182400 bytes
      Format-BytesToGB -Bytes 107374182400 | Should -Be 100
    }
  }

  Context 'Format-BytesToTB' {

    It 'Converts 0 bytes to 0 TB' {
      Format-BytesToTB -Bytes 0 | Should -Be 0
    }

    It 'Converts 1 TB in bytes to 1 TB' {
      Format-BytesToTB -Bytes 1099511627776 | Should -Be 1
    }

    It 'Rounds to 3 decimal places' {
      # 1.5 TB
      Format-BytesToTB -Bytes 1649267441664 | Should -Be 1.5
    }
  }

  Context 'Write-Log' {

    BeforeEach {
      $script:LogEntries = New-Object System.Collections.Generic.List[object]
    }

    It 'Adds an entry to the log list' {
      Write-Log -Message "Test message" -Level "INFO" 6>$null
      $script:LogEntries.Count | Should -Be 1
    }

    It 'Records correct level' {
      Write-Log -Message "Warning test" -Level "WARNING" 6>$null
      $script:LogEntries[0].Level | Should -Be "WARNING"
    }

    It 'Records correct message' {
      Write-Log -Message "Hello World" -Level "SUCCESS" 6>$null
      $script:LogEntries[0].Message | Should -Be "Hello World"
    }

    It 'Records a timestamp' {
      Write-Log -Message "Timestamp test" 6>$null
      $script:LogEntries[0].Timestamp | Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
    }

    It 'Defaults to INFO level' {
      Write-Log -Message "Default level" 6>$null
      $script:LogEntries[0].Level | Should -Be "INFO"
    }
  }
}

Describe 'Defensive Coding Checks' {

  Context 'Empty Collection Guards' {

    It 'Script guards CSV exports for empty collections' {
      $content = Get-Content $script:ScriptPath -Raw
      # Should check count before exporting VMs, SQL, Storage, Backup data
      ($content | Select-String '\.Count\s*-gt\s*0.*Export-Csv' -AllMatches).Matches.Count | Should -Be 0
      # Check pattern: if ($collection -and $collection.Count -gt 0) { ... Export-Csv ... }
      ($content | Select-String 'Count -gt 0' -AllMatches).Matches.Count | Should -BeGreaterOrEqual 7
    }
  }

  Context 'Null Safety' {

    It 'Handles null DiskSizeGB with explicit check' {
      $content = Get-Content $script:ScriptPath -Raw
      $content | Should -Match 'if\s*\(\$vm\.StorageProfile\.OsDisk\.DiskSizeGB\)'
    }

    It 'Guards $htmlPath before referencing in summary' {
      $content = Get-Content $script:ScriptPath -Raw
      $content | Should -Match 'if\s*\(\$htmlPath\)'
    }
  }

  Context 'Error Handling' {

    It 'Wraps Set-AzContext calls in try/catch' {
      $content = Get-Content $script:ScriptPath -Raw
      # Count Set-AzContext calls
      $contextCalls = ($content | Select-String 'Set-AzContext' -AllMatches).Matches.Count
      $contextCalls | Should -BeGreaterThan 0

      # All should be inside try blocks (check for -ErrorAction Stop pattern)
      $safeCalls = ($content | Select-String 'Set-AzContext.*-ErrorAction Stop' -AllMatches).Matches.Count
      $safeCalls | Should -Be $contextCalls
    }

    It 'Has a top-level try/catch/finally in main execution' {
      $content = Get-Content $script:ScriptPath -Raw
      $content | Should -Match '(?s)#region Main Execution.*try\s*\{.*catch\s*\{.*finally\s*\{'
    }

    It 'Saves execution log on failure in catch block' {
      $content = Get-Content $script:ScriptPath -Raw
      $content | Should -Match '(?s)catch\s*\{.*execution_log\.csv.*throw'
    }
  }
}

Describe 'Multi-Subscription Support' {

  Context 'Per-Subscription Sizing' {

    BeforeAll {
      $script:ScriptPath = Join-Path $PSScriptRoot 'Get-VeeamAzureSizing.ps1'
      $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$null, [ref]$null
      )
      $script:FunctionDefs = $script:Ast.FindAll(
        { $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false
      )

      # Load Measure-VeeamSizing and Write-Log into test scope
      foreach ($fn in $script:FunctionDefs) {
        if ($fn.Name -in @('Measure-VeeamSizing', 'Write-Log', 'Write-ProgressStep')) {
          Invoke-Expression $fn.Extent.Text
        }
      }

      # Mock script-level variables needed by loaded functions
      $script:LogEntries = New-Object System.Collections.Generic.List[object]
      $script:TotalSteps = 10
      $script:CurrentStep = 0
      $script:Subs = @(
        [PSCustomObject]@{ Id = 'sub-aaa'; Name = 'Production' }
        [PSCustomObject]@{ Id = 'sub-bbb'; Name = 'Development' }
      )
    }

    It 'Measure-VeeamSizing returns PerSubscription property' {
      $vmInv = @(
        [PSCustomObject]@{ SubscriptionId='sub-aaa'; TotalProvisionedGB=100; VeeamSnapshotStorageGB=5; VeeamRepositoryGB=120 }
        [PSCustomObject]@{ SubscriptionId='sub-bbb'; TotalProvisionedGB=200; VeeamSnapshotStorageGB=10; VeeamRepositoryGB=240 }
      )
      $sqlInv = @{
        Databases = @(
          [PSCustomObject]@{ SubscriptionId='sub-aaa'; MaxSizeGB=50; VeeamRepositoryGB=65 }
        )
        ManagedInstances = @()
      }
      $stInv = @{ Files = @(); Blobs = @() }
      $abInv = @{ Vaults = @(); Policies = @() }

      $result = Measure-VeeamSizing -VmInventory $vmInv -SqlInventory $sqlInv `
        -StorageInventory $stInv -AzureBackupInventory $abInv 6>$null

      $result.PerSubscription | Should -Not -BeNullOrEmpty
      $result.PerSubscription.Count | Should -Be 2
    }

    It 'Per-subscription breakdown sums correctly per subscription' {
      $vmInv = @(
        [PSCustomObject]@{ SubscriptionId='sub-aaa'; TotalProvisionedGB=100; VeeamSnapshotStorageGB=5; VeeamRepositoryGB=120 }
        [PSCustomObject]@{ SubscriptionId='sub-aaa'; TotalProvisionedGB=50; VeeamSnapshotStorageGB=3; VeeamRepositoryGB=60 }
        [PSCustomObject]@{ SubscriptionId='sub-bbb'; TotalProvisionedGB=200; VeeamSnapshotStorageGB=10; VeeamRepositoryGB=240 }
      )
      $sqlInv = @{ Databases = @(); ManagedInstances = @() }
      $stInv = @{ Files = @(); Blobs = @() }
      $abInv = @{ Vaults = @(); Policies = @() }

      $result = Measure-VeeamSizing -VmInventory $vmInv -SqlInventory $sqlInv `
        -StorageInventory $stInv -AzureBackupInventory $abInv 6>$null

      $prodSub = $result.PerSubscription | Where-Object { $_.SubscriptionId -eq 'sub-aaa' }
      $devSub = $result.PerSubscription | Where-Object { $_.SubscriptionId -eq 'sub-bbb' }

      $prodSub.VMs | Should -Be 2
      $prodSub.VMStorageGB | Should -Be 150
      $prodSub.VeeamSnapshotGB | Should -Be 8
      $prodSub.VeeamRepositoryGB | Should -Be 180

      $devSub.VMs | Should -Be 1
      $devSub.VMStorageGB | Should -Be 200
    }

    It 'Per-subscription totals match grand totals' {
      $vmInv = @(
        [PSCustomObject]@{ SubscriptionId='sub-aaa'; TotalProvisionedGB=100; VeeamSnapshotStorageGB=5; VeeamRepositoryGB=120 }
        [PSCustomObject]@{ SubscriptionId='sub-bbb'; TotalProvisionedGB=200; VeeamSnapshotStorageGB=10; VeeamRepositoryGB=240 }
      )
      $sqlInv = @{
        Databases = @(
          [PSCustomObject]@{ SubscriptionId='sub-aaa'; MaxSizeGB=50; VeeamRepositoryGB=65 }
          [PSCustomObject]@{ SubscriptionId='sub-bbb'; MaxSizeGB=80; VeeamRepositoryGB=104 }
        )
        ManagedInstances = @()
      }
      $stInv = @{ Files = @(); Blobs = @() }
      $abInv = @{ Vaults = @(); Policies = @() }

      $result = Measure-VeeamSizing -VmInventory $vmInv -SqlInventory $sqlInv `
        -StorageInventory $stInv -AzureBackupInventory $abInv 6>$null

      # Sum the per-subscription VeeamRepositoryGB values
      $perSubRepoTotal = ($result.PerSubscription | Measure-Object -Property VeeamRepositoryGB -Sum).Sum
      $perSubRepoTotal | Should -Be $result.TotalRepositoryGB

      # Sum the per-subscription source data
      $perSubSourceTotal = ($result.PerSubscription | Measure-Object -Property TotalSourceGB -Sum).Sum
      $perSubSourceTotal | Should -Be $result.TotalSourceStorageGB
    }

    It 'Handles subscription with zero resources' {
      $vmInv = @(
        [PSCustomObject]@{ SubscriptionId='sub-aaa'; TotalProvisionedGB=100; VeeamSnapshotStorageGB=5; VeeamRepositoryGB=120 }
      )
      $sqlInv = @{ Databases = @(); ManagedInstances = @() }
      $stInv = @{ Files = @(); Blobs = @() }
      $abInv = @{ Vaults = @(); Policies = @() }

      $result = Measure-VeeamSizing -VmInventory $vmInv -SqlInventory $sqlInv `
        -StorageInventory $stInv -AzureBackupInventory $abInv 6>$null

      $emptySub = $result.PerSubscription | Where-Object { $_.SubscriptionId -eq 'sub-bbb' }
      $emptySub | Should -Not -BeNullOrEmpty
      $emptySub.VMs | Should -Be 0
      $emptySub.VMStorageGB | Should -Be 0
      $emptySub.SQLDatabases | Should -Be 0
      $emptySub.VeeamSnapshotGB | Should -Be 0
      $emptySub.VeeamRepositoryGB | Should -Be 0
    }
  }

  Context 'HTML Report Per-Subscription Table' {

    It 'HTML template includes Resources by Subscription section' {
      $content = Get-Content $script:ScriptPath -Raw
      $content | Should -Match 'Resources by Subscription'
    }

    It 'HTML template includes per-subscription table headers' {
      $content = Get-Content $script:ScriptPath -Raw
      $content | Should -Match 'Veeam Snapshot'
      $content | Should -Match 'Veeam Repository'
      $content | Should -Match 'Source Data'
    }

    It 'HTML template uses subscriptionRows variable' {
      $content = Get-Content $script:ScriptPath -Raw
      $content | Should -Match '\$subscriptionRows'
    }
  }

  Context 'Per-Subscription CSV Export' {

    It 'Script defines per-subscription sizing CSV path' {
      $lines = Get-Content $script:ScriptPath
      ($lines | Select-String 'veeam_sizing_per_subscription\.csv').Count | Should -BeGreaterOrEqual 1
    }

    It 'Script exports per-subscription sizing CSV with guard' {
      $content = Get-Content $script:ScriptPath -Raw
      $content | Should -Match 'PerSubscription.*Count.*-gt.*0'
      $content | Should -Match 'Export-Csv.*sizingPerSubCsv'
    }
  }

  Context 'Resolve-Subscriptions Defensive Returns' {

    It 'Uses List[object] for filtered subscription collection' {
      $content = Get-Content $script:ScriptPath -Raw
      $content | Should -Match 'System\.Collections\.Generic\.List\[object\]'
    }

    It 'Uses Select-Object -First 1 to prevent duplicate subscription matches' {
      $content = Get-Content $script:ScriptPath -Raw
      $content | Should -Match 'Select-Object\s+-First\s+1'
    }

    It 'Uses comma operator to prevent array unrolling on return' {
      $content = Get-Content $script:ScriptPath -Raw
      $content | Should -Match 'return\s*,\s*\$resolved'
    }

    It 'Caller wraps Resolve-Subscriptions with @() for safety' {
      $content = Get-Content $script:ScriptPath -Raw
      $content | Should -Match '@\(Resolve-Subscriptions\)'
    }
  }
}
