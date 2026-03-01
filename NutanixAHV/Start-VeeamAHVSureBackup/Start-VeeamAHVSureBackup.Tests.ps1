#Requires -Module Pester
<#
.SYNOPSIS
  Pester 5.x test suite for Start-VeeamAHVSureBackup.ps1
.DESCRIPTION
  Comprehensive unit and integration-safe tests covering:
  - Parameter validation and edge cases
  - API request construction (v3 and v4)
  - Retry/backoff behaviour with jitter
  - Error handling paths (401/403/404/429/5xx)
  - Pagination behaviour
  - Idempotency checks (NTNX-Request-Id)
  - Output contract/schema validation
  - VBAHV Plugin REST API functions
  - Smoke tests (no real AHV credentials needed)

  All external calls (Invoke-RestMethod) are mocked.
  No destructive live calls are made in default test runs.

.NOTES
  Run with:  Invoke-Pester ./Start-VeeamAHVSureBackup.Tests.ps1 -Output Detailed
  CI mode:   Invoke-Pester ./Start-VeeamAHVSureBackup.Tests.ps1 -CI
  Expected:  All tests pass without AHV/VBR credentials
#>

BeforeAll {
  # Collect all script files: main entry point + lib files
  $libPath = Join-Path $PSScriptRoot "lib"
  $scriptFiles = @(
    (Join-Path $PSScriptRoot "Start-VeeamAHVSureBackup.ps1")
  )
  if (Test-Path $libPath) {
    $scriptFiles += Get-ChildItem -Path $libPath -Filter "*.ps1" | Select-Object -ExpandProperty FullName
  }

  # Set up script-scoped variables that functions depend on
  $script:PrismApiVersion = "v4"
  $script:PrismOrigin = "https://testpc:9440"
  $script:PrismBaseUrl = "https://testpc:9440/api"
  $script:PrismHeaders = @{
    "Authorization" = "Basic dGVzdDp0ZXN0"
    "Content-Type"  = "application/json"
    "Accept"        = "application/json"
  }
  $script:PrismEndpoints = @{
    VMs      = "vmm/v4.0/ahv/config/vms"
    Subnets  = "networking/v4.0/config/subnets"
    Clusters = "clustermgmt/v4.0/config/clusters"
    Tasks    = "prism/v4.0/config/tasks"
  }
  $script:SkipCert = $false
  $script:LogEntries = New-Object System.Collections.Generic.List[object]
  $script:TestResults = New-Object System.Collections.Generic.List[object]
  $script:RecoverySessions = New-Object System.Collections.Generic.List[object]
  $script:StartTime = Get-Date
  $script:TotalSteps = 9
  $script:CurrentStep = 0

  # Parse AST from all script files and extract function definitions without executing main
  foreach ($scriptFile in $scriptFiles) {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptFile, [ref]$tokens, [ref]$parseErrors)
    $functionDefs = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    foreach ($funcDef in $functionDefs) {
      Invoke-Expression $funcDef.Extent.Text
    }
  }

  # Helper to create mock HTTP exceptions with proper Response.StatusCode
  function script:New-MockHttpException {
    param([int]$StatusCode, [string]$Message = "Mock HTTP error $StatusCode")
    $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]$StatusCode)
    return [Microsoft.PowerShell.Commands.HttpResponseException]::new($Message, $response)
  }
}

# ============================================================
Describe "Write-Log" {
  BeforeEach {
    $script:LogEntries = New-Object System.Collections.Generic.List[object]
  }

  It "adds an entry with correct level and message" {
    Write-Log -Message "Test message" -Level "INFO"
    $script:LogEntries.Count | Should -Be 1
    $script:LogEntries[0].Level | Should -Be "INFO"
    $script:LogEntries[0].Message | Should -Be "Test message"
  }

  It "defaults to INFO level" {
    Write-Log -Message "Default level"
    $script:LogEntries[0].Level | Should -Be "INFO"
  }

  It "accepts all valid log levels" {
    foreach ($level in @("INFO", "WARNING", "ERROR", "SUCCESS", "TEST-PASS", "TEST-FAIL")) {
      Write-Log -Message "test" -Level $level
    }
    $script:LogEntries.Count | Should -Be 6
  }

  It "includes a timestamp in yyyy-MM-dd HH:mm:ss format" {
    Write-Log -Message "ts test"
    $script:LogEntries[0].Timestamp | Should -Match "^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"
  }
}

# ============================================================
Describe "Resolve-PrismResponseBody" {
  It "unwraps a Body/ETag wrapper object" {
    $wrapper = [PSCustomObject]@{
      Body = @{ data = @("item1") }
      ETag = "abc123"
    }
    $result = Resolve-PrismResponseBody $wrapper
    $result.data | Should -Contain "item1"
  }

  It "returns raw response when no wrapper present" {
    $raw = @{ entities = @("e1") }
    $result = Resolve-PrismResponseBody $raw
    $result.entities | Should -Contain "e1"
  }
}

# ============================================================
Describe "Invoke-PrismAPI" {
  BeforeEach {
    $script:LogEntries = New-Object System.Collections.Generic.List[object]
  }

  Context "Successful requests" {
    It "calls Invoke-RestMethod and returns response" {
      Mock Invoke-RestMethod { return @{ data = @(@{ name = "test-vm" }) } }

      $result = Invoke-PrismAPI -Method "GET" -Endpoint "vmm/v4.0/ahv/config/vms"
      Should -Invoke Invoke-RestMethod -Times 1
    }

    It "includes NTNX-Request-Id header for v4 POST mutations" {
      $script:capturedHeaders = $null
      Mock Invoke-RestMethod {
        $script:capturedHeaders = $Headers
        return @{ data = @() }
      }

      Invoke-PrismAPI -Method "POST" -Endpoint "test" -Body @{ kind = "vm" }
      $script:capturedHeaders["NTNX-Request-Id"] | Should -Not -BeNullOrEmpty
    }

    It "includes If-Match header when IfMatch is provided" {
      $script:capturedHeaders = $null
      Mock Invoke-RestMethod {
        $script:capturedHeaders = $Headers
        return @{ data = @() }
      }

      Invoke-PrismAPI -Method "PUT" -Endpoint "test" -IfMatch "etag123"
      $script:capturedHeaders["If-Match"] | Should -Be "etag123"
    }

    It "serialises Body as JSON with depth" {
      $script:capturedBody = $null
      Mock Invoke-RestMethod {
        $script:capturedBody = $Body
        return @{ data = @() }
      }

      Invoke-PrismAPI -Method "POST" -Endpoint "test" -Body @{ kind = "vm"; nested = @{ a = 1 } }
      $parsed = $script:capturedBody | ConvertFrom-Json
      $parsed.kind | Should -Be "vm"
    }
  }

  Context "Retry on transient errors" {
    It "retries on 5xx and eventually succeeds" {
      $script:mockCallCount = 0
      Mock Invoke-RestMethod {
        $script:mockCallCount++
        if ($script:mockCallCount -le 1) {
          throw (New-MockHttpException -StatusCode 500)
        }
        return @{ data = @() }
      }
      Mock Start-Sleep {}

      $result = Invoke-PrismAPI -Method "GET" -Endpoint "test" -RetryCount 2
      $script:mockCallCount | Should -Be 2
    }

    It "retries on 429 rate-limit and eventually succeeds" {
      $script:mockCallCount = 0
      Mock Invoke-RestMethod {
        $script:mockCallCount++
        if ($script:mockCallCount -le 1) {
          throw (New-MockHttpException -StatusCode 429)
        }
        return @{ data = @() }
      }
      Mock Start-Sleep {}

      Invoke-PrismAPI -Method "GET" -Endpoint "test" -RetryCount 2
      $script:mockCallCount | Should -Be 2
    }

    It "throws after exhausting all retries" {
      Mock Invoke-RestMethod {
        throw (New-MockHttpException -StatusCode 502)
      }
      Mock Start-Sleep {}

      { Invoke-PrismAPI -Method "GET" -Endpoint "test" -RetryCount 2 } | Should -Throw
      Should -Invoke Invoke-RestMethod -Times 3  # 1 initial + 2 retries
    }

    It "uses Start-Sleep for backoff between retries" {
      $script:mockCallCount = 0
      Mock Invoke-RestMethod {
        $script:mockCallCount++
        if ($script:mockCallCount -le 2) {
          throw (New-MockHttpException -StatusCode 503)
        }
        return @{ data = @() }
      }
      Mock Start-Sleep {}

      Invoke-PrismAPI -Method "GET" -Endpoint "test" -RetryCount 3
      Should -Invoke Start-Sleep -Times 2
    }
  }

  Context "Non-retryable client errors" {
    It "does NOT retry on 401 Unauthorized" {
      Mock Invoke-RestMethod { throw (New-MockHttpException -StatusCode 401) }
      Mock Start-Sleep {}

      { Invoke-PrismAPI -Method "GET" -Endpoint "test" -RetryCount 3 } | Should -Throw
      Should -Invoke Invoke-RestMethod -Times 1
    }

    It "does NOT retry on 403 Forbidden" {
      Mock Invoke-RestMethod { throw (New-MockHttpException -StatusCode 403) }
      Mock Start-Sleep {}

      { Invoke-PrismAPI -Method "GET" -Endpoint "test" -RetryCount 3 } | Should -Throw
      Should -Invoke Invoke-RestMethod -Times 1
    }

    It "does NOT retry on 404 Not Found" {
      Mock Invoke-RestMethod { throw (New-MockHttpException -StatusCode 404) }
      Mock Start-Sleep {}

      { Invoke-PrismAPI -Method "GET" -Endpoint "test" -RetryCount 3 } | Should -Throw
      Should -Invoke Invoke-RestMethod -Times 1
    }

    It "logs client error with status code" {
      Mock Invoke-RestMethod { throw (New-MockHttpException -StatusCode 400) }

      { Invoke-PrismAPI -Method "GET" -Endpoint "test" } | Should -Throw
      $script:LogEntries | Where-Object { $_.Level -eq "ERROR" -and $_.Message -match "client error.*400" } |
        Should -Not -BeNullOrEmpty
    }
  }
}

# ============================================================
Describe "Get-PrismEntities" {
  BeforeEach {
    $script:LogEntries = New-Object System.Collections.Generic.List[object]
  }

  Context "v4 pagination" {
    BeforeAll { $script:PrismApiVersion = "v4" }

    It "fetches all pages until totalAvailableResults is reached" {
      $script:mockPage = 0
      Mock Invoke-PrismAPI {
        $script:mockPage++
        if ($script:mockPage -eq 1) {
          return @{
            data     = @(@{ extId = "1"; name = "vm1" }, @{ extId = "2"; name = "vm2" })
            metadata = @{ totalAvailableResults = 3 }
          }
        }
        return @{
          data     = @(@{ extId = "3"; name = "vm3" })
          metadata = @{ totalAvailableResults = 3 }
        }
      }

      $result = Get-PrismEntities -EndpointKey "VMs" -PageSize 2
      $result.Count | Should -Be 3
    }

    It "passes OData filter in query string" {
      Mock Invoke-PrismAPI {
        param($Method, $Endpoint)
        $Endpoint | Should -Match '\$filter='
        return @{ data = @(); metadata = @{ totalAvailableResults = 0 } }
      }

      Get-PrismEntities -EndpointKey "VMs" -Filter "name eq 'test'"
    }

    It "uses GET method for v4 list operations" {
      Mock Invoke-PrismAPI {
        param($Method)
        $Method | Should -Be "GET"
        return @{ data = @(); metadata = @{ totalAvailableResults = 0 } }
      }

      Get-PrismEntities -EndpointKey "Clusters"
    }

    It "returns empty list when no data" {
      Mock Invoke-PrismAPI {
        return @{ data = @(); metadata = @{ totalAvailableResults = 0 } }
      }

      $result = Get-PrismEntities -EndpointKey "Subnets"
      $result.Count | Should -Be 0
    }
  }

  Context "v3 pagination" {
    BeforeAll { $script:PrismApiVersion = "v3" }
    AfterAll { $script:PrismApiVersion = "v4" }

    It "uses POST method with kind/length/offset body" {
      Mock Invoke-PrismAPI {
        param($Method, $Endpoint, $Body)
        $Method | Should -Be "POST"
        $Endpoint | Should -Match "list$"
        $Body.kind | Should -Be "cluster"
        $Body.length | Should -BeGreaterThan 0
        return @{ entities = @(); metadata = @{ total_matches = 0 } }
      }

      Get-PrismEntities -EndpointKey "Clusters"
    }

    It "pages through v3 results" {
      $script:mockOffset = -1
      Mock Invoke-PrismAPI {
        param($Body)
        $script:mockOffset++
        if ($script:mockOffset -eq 0) {
          return @{
            entities = @(@{ metadata = @{ uuid = "1" } }, @{ metadata = @{ uuid = "2" } })
            metadata = @{ total_matches = 3 }
          }
        }
        return @{
          entities = @(@{ metadata = @{ uuid = "3" } })
          metadata = @{ total_matches = 3 }
        }
      }

      $result = Get-PrismEntities -EndpointKey "Subnets" -PageSize 2
      $result.Count | Should -Be 3
    }
  }

  Context "Error handling" {
    It "throws on unknown endpoint key" {
      { Get-PrismEntities -EndpointKey "Nonexistent" } | Should -Throw "*Unknown Prism endpoint*"
    }
  }
}

# ============================================================
Describe "Get-PrismVMByName" {
  BeforeAll {
    $script:PrismApiVersion = "v4"
    $script:LogEntries = New-Object System.Collections.Generic.List[object]
  }

  It "returns only exact-match VMs by name (v4)" {
    Mock Invoke-PrismAPI {
      return @{
        data = @(
          @{ extId = "uuid1"; name = "test-vm" }
          @{ extId = "uuid2"; name = "test-vm-other" }
        )
      }
    }

    $result = @(Get-PrismVMByName -Name "test-vm")
    $result.Count | Should -Be 1
    $result[0].name | Should -Be "test-vm"
  }

  It "uses OData filter in v4 endpoint URL" {
    Mock Invoke-PrismAPI {
      param($Method, $Endpoint)
      $Endpoint | Should -Match "filter=name eq 'myvm'"
      return @{ data = @() }
    }

    Get-PrismVMByName -Name "myvm"
  }

  Context "v3 mode" {
    BeforeAll { $script:PrismApiVersion = "v3" }
    AfterAll { $script:PrismApiVersion = "v4" }

    It "uses POST vms/list with vm_name filter (v3)" {
      Mock Invoke-PrismAPI {
        param($Method, $Endpoint, $Body)
        $Method | Should -Be "POST"
        $Body.filter | Should -Match "vm_name=="
        return @{ entities = @(@{ spec = @{ name = "target-vm" }; metadata = @{ uuid = "u1" } }) }
      }

      $result = @(Get-PrismVMByName -Name "target-vm")
      $result.Count | Should -Be 1
    }
  }
}

# ============================================================
Describe "Get-PrismVMByUUID" {
  BeforeAll {
    $script:PrismApiVersion = "v4"
    $script:LogEntries = New-Object System.Collections.Generic.List[object]
  }

  It "returns VM data with ETag wrapper (v4)" {
    Mock Invoke-PrismAPI {
      return [PSCustomObject]@{
        Body = @{ data = @{ extId = "uuid1"; name = "vm1"; powerState = "ON" } }
        ETag = "etag-abc"
      }
    }

    $result = Get-PrismVMByUUID -UUID "uuid1"
    $result.VM | Should -Not -BeNullOrEmpty
    $result.ETag | Should -Be "etag-abc"
  }
}

# ============================================================
Describe "Get-PrismVMIPAddress" {
  BeforeAll {
    $script:PrismApiVersion = "v4"
    $script:LogEntries = New-Object System.Collections.Generic.List[object]
  }

  It "extracts IP from v4 NIC learnedIpAddresses" {
    Mock Get-PrismVMByUUID {
      return [PSCustomObject]@{
        VM = @{
          extId      = "uuid1"
          powerState = "ON"
          nics       = @(
            @{
              networkInfo = @{
                ipv4Info = @{
                  learnedIpAddresses = @(@{ value = "10.0.1.50" })
                }
              }
            }
          )
        }
        ETag = "e1"
      }
    }

    $ip = Get-PrismVMIPAddress -UUID "uuid1"
    $ip | Should -Be "10.0.1.50"
  }

  It "skips link-local 169.254.x.x addresses" {
    Mock Get-PrismVMByUUID {
      return [PSCustomObject]@{
        VM = @{
          nics = @(
            @{
              networkInfo = @{
                ipv4Info = @{
                  learnedIpAddresses = @(@{ value = "169.254.1.1" }, @{ value = "10.0.1.99" })
                }
              }
            }
          )
        }
        ETag = $null
      }
    }

    $ip = Get-PrismVMIPAddress -UUID "uuid1"
    $ip | Should -Be "10.0.1.99"
  }

  It "returns null when no IPs available" {
    Mock Get-PrismVMByUUID {
      return [PSCustomObject]@{
        VM   = @{ nics = @() }
        ETag = $null
      }
    }

    $ip = Get-PrismVMIPAddress -UUID "uuid1"
    $ip | Should -BeNullOrEmpty
  }

  Context "v3 mode" {
    BeforeAll { $script:PrismApiVersion = "v3" }
    AfterAll { $script:PrismApiVersion = "v4" }

    It "extracts IP from v3 nic_list.ip_endpoint_list" {
      Mock Get-PrismVMByUUID {
        return @{
          status = @{
            resources = @{
              nic_list = @(
                @{
                  ip_endpoint_list = @(@{ ip = "192.168.1.10" })
                }
              )
            }
          }
        }
      }

      $ip = Get-PrismVMIPAddress -UUID "uuid1"
      $ip | Should -Be "192.168.1.10"
    }
  }
}

# ============================================================
Describe "Get-PrismVMPowerState" {
  It "extracts power state from v4 VM result" {
    $script:PrismApiVersion = "v4"
    $vmResult = [PSCustomObject]@{ VM = @{ powerState = "ON" }; ETag = "e" }
    Get-PrismVMPowerState $vmResult | Should -Be "ON"
  }

  It "extracts power state from v3 VM result" {
    $script:PrismApiVersion = "v3"
    $vmResult = @{ status = @{ resources = @{ power_state = "OFF" } } }
    Get-PrismVMPowerState $vmResult | Should -Be "OFF"
    $script:PrismApiVersion = "v4"
  }
}

# ============================================================
Describe "Wait-PrismVMPowerState" {
  BeforeAll {
    $script:LogEntries = New-Object System.Collections.Generic.List[object]
  }

  It "returns true when VM reaches desired power state" {
    $script:waitCallCount = 0
    Mock Get-PrismVMByUUID {
      $script:waitCallCount++
      $state = if ($script:waitCallCount -ge 2) { "ON" } else { "OFF" }
      return [PSCustomObject]@{
        VM   = @{ powerState = $state }
        ETag = $null
      }
    }
    Mock Start-Sleep {}

    $result = Wait-PrismVMPowerState -UUID "u1" -State "ON" -TimeoutSec 300
    $result | Should -Be $true
  }

  It "returns false when timeout expires" {
    Mock Get-PrismVMByUUID {
      return [PSCustomObject]@{ VM = @{ powerState = "OFF" }; ETag = $null }
    }
    Mock Start-Sleep {}

    $result = Wait-PrismVMPowerState -UUID "u1" -State "ON" -TimeoutSec 0
    $result | Should -Be $false
  }
}

# ============================================================
Describe "Test-VMHeartbeat" {
  BeforeAll {
    $script:PrismApiVersion = "v4"
    $script:LogEntries = New-Object System.Collections.Generic.List[object]
  }

  It "returns PASS when VM is powered ON with NGT" {
    Mock Get-PrismVMByUUID {
      return [PSCustomObject]@{
        VM = @{ powerState = "ON"; guestTools = @{ isEnabled = $true } }
        ETag = "e"
      }
    }

    $result = Test-VMHeartbeat -UUID "u1" -VMName "testvm"
    $result.Passed | Should -Be $true
    $result.TestName | Should -Be "Heartbeat (NGT)"
    $result.Details | Should -Match "Power: ON"
  }

  It "returns FAIL when VM is powered OFF" {
    Mock Get-PrismVMByUUID {
      return [PSCustomObject]@{
        VM   = @{ powerState = "OFF"; guestTools = $null }
        ETag = "e"
      }
    }

    $result = Test-VMHeartbeat -UUID "u1" -VMName "testvm"
    $result.Passed | Should -Be $false
  }

  It "handles API exceptions gracefully" {
    Mock Get-PrismVMByUUID { throw "Connection refused" }

    $result = Test-VMHeartbeat -UUID "u1" -VMName "testvm"
    $result.Passed | Should -Be $false
    $result.Details | Should -Match "Error"
  }
}

# ============================================================
Describe "Test-VMPing" {
  BeforeAll {
    $script:LogEntries = New-Object System.Collections.Generic.List[object]
  }

  It "returns PASS when ping succeeds" {
    Mock Test-Connection { return $true } -ParameterFilter { $Quiet }
    Mock Test-Connection {
      return @(
        [PSCustomObject]@{ ResponseTime = 1.5 },
        [PSCustomObject]@{ ResponseTime = 2.0 }
      )
    } -ParameterFilter { -not $Quiet }

    $result = Test-VMPing -IPAddress "10.0.1.1" -VMName "vm1"
    $result.Passed | Should -Be $true
    $result.Details | Should -Match "Reply from"
  }

  It "returns FAIL when ping fails" {
    Mock Test-Connection { return $false } -ParameterFilter { $Quiet }

    $result = Test-VMPing -IPAddress "10.0.1.1" -VMName "vm1"
    $result.Passed | Should -Be $false
    $result.Details | Should -Match "No reply"
  }
}

# ============================================================
Describe "Test-VMPort" {
  BeforeAll {
    $script:LogEntries = New-Object System.Collections.Generic.List[object]
  }

  It "returns PASS when TCP port is open" {
    Mock New-Object {
      $mock = [PSCustomObject]@{ Connected = $true }
      $mock | Add-Member -MemberType ScriptMethod -Name ConnectAsync -Value {
        $task = [PSCustomObject]@{}
        $task | Add-Member -MemberType ScriptMethod -Name Wait -Value { return $true }
        return $task
      }
      $mock | Add-Member -MemberType ScriptMethod -Name Close -Value {}
      $mock | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
      return $mock
    } -ParameterFilter { $TypeName -eq "System.Net.Sockets.TcpClient" }

    $result = Test-VMPort -IPAddress "10.0.1.1" -Port 443 -VMName "vm1"
    $result.Passed | Should -Be $true
    $result.TestName | Should -Be "TCP Port 443"
  }

  It "returns FAIL on connection exception" {
    Mock New-Object {
      throw "Connection refused"
    } -ParameterFilter { $TypeName -eq "System.Net.Sockets.TcpClient" }

    $result = Test-VMPort -IPAddress "10.0.1.1" -Port 22 -VMName "vm1"
    $result.Passed | Should -Be $false
    $result.Details | Should -Match "refused|unreachable"
  }
}

# ============================================================
Describe "Test-VMDNS" {
  BeforeAll {
    $script:LogEntries = New-Object System.Collections.Generic.List[object]
  }

  It "returns test result with correct schema" {
    # DNS resolution depends on runtime environment; test the contract
    $result = Test-VMDNS -IPAddress "127.0.0.1" -VMName "vm1"
    $result.VMName | Should -Be "vm1"
    $result.TestName | Should -Be "DNS Resolution"
    $result.PSObject.Properties.Name | Should -Contain "Passed"
    $result.PSObject.Properties.Name | Should -Contain "Details"
  }
}

# ============================================================
Describe "Test-VMHttpEndpoint" {
  BeforeAll {
    $script:LogEntries = New-Object System.Collections.Generic.List[object]
  }

  It "replaces localhost with actual VM IP in URL" {
    Mock Invoke-WebRequest {
      param($Uri)
      $Uri | Should -Match "10\.0\.1\.1"
      $Uri | Should -Not -Match "localhost"
      return @{ StatusCode = 200; Headers = @{ "Content-Length" = "42" } }
    }

    $result = Test-VMHttpEndpoint -IPAddress "10.0.1.1" -Url "http://localhost/health" -VMName "vm1"
    $result.Passed | Should -Be $true
  }

  It "returns FAIL on HTTP error" {
    Mock Invoke-WebRequest { throw "500 Internal Server Error" }

    $result = Test-VMHttpEndpoint -IPAddress "10.0.1.1" -Url "http://10.0.1.1/api" -VMName "vm1"
    $result.Passed | Should -Be $false
    $result.Details | Should -Match "HTTP request failed"
  }

  It "replaces 127.0.0.1 with actual IP" {
    Mock Invoke-WebRequest {
      param($Uri)
      $Uri | Should -Match "10\.0\.1\.1"
      return @{ StatusCode = 200; Headers = @{ "Content-Length" = "10" } }
    }

    $result = Test-VMHttpEndpoint -IPAddress "10.0.1.1" -Url "http://127.0.0.1:8080/status" -VMName "vm1"
    $result.Passed | Should -Be $true
  }
}

# ============================================================
Describe "Test-VMCustomScript" {
  BeforeAll {
    $script:LogEntries = New-Object System.Collections.Generic.List[object]
  }

  It "returns FAIL when script path does not exist" {
    $result = Test-VMCustomScript -ScriptPath "/nonexistent/script.ps1" -VMName "vm1"
    $result.Passed | Should -Be $false
    $result.Details | Should -Match "Script not found"
  }
}

# ============================================================
Describe "Get-VMBootOrder" {
  It "returns a single 'All VMs' group when no ApplicationGroups defined" {
    $rps = @(
      [PSCustomObject]@{ VMName = "vm1" },
      [PSCustomObject]@{ VMName = "vm2" }
    )
    $script:ApplicationGroups = $null
    $result = Get-VMBootOrder -RestorePoints $rps
    $result.Count | Should -Be 1
    $result.Keys | Should -Contain "All VMs"
  }
}

# ============================================================
Describe "Get-SubnetName / Get-SubnetUUID" {
  It "extracts from v4 entity (name, extId)" {
    $script:PrismApiVersion = "v4"
    $subnet = @{ name = "isolated-net"; extId = "abc-123" }
    Get-SubnetName $subnet | Should -Be "isolated-net"
    Get-SubnetUUID $subnet | Should -Be "abc-123"
  }

  It "extracts from v3 entity (spec.name, metadata.uuid)" {
    $script:PrismApiVersion = "v3"
    $subnet = @{ spec = @{ name = "isolated-net" }; metadata = @{ uuid = "abc-123" } }
    Get-SubnetName $subnet | Should -Be "isolated-net"
    Get-SubnetUUID $subnet | Should -Be "abc-123"
    $script:PrismApiVersion = "v4"
  }
}

# ============================================================
Describe "Resolve-IsolatedNetwork" {
  BeforeAll {
    $script:PrismApiVersion = "v4"
    $script:LogEntries = New-Object System.Collections.Generic.List[object]
  }

  It "finds network by UUID" {
    Mock Get-PrismSubnets {
      return @(
        @{ extId = "net-uuid-1"; name = "prod-net"; vlanId = 100; subnetType = "VLAN"; clusterReference = @{ extId = "c1" } },
        @{ extId = "net-uuid-2"; name = "isolated-lab"; vlanId = 999; subnetType = "VLAN"; clusterReference = @{ extId = "c1" } }
      )
    }

    $IsolatedNetworkUUID = "net-uuid-2"
    $IsolatedNetworkName = $null
    $result = Resolve-IsolatedNetwork
    $result.UUID | Should -Be "net-uuid-2"
    $result.Name | Should -Be "isolated-lab"
  }

  It "auto-detects isolated network by name pattern" {
    Mock Get-PrismSubnets {
      return @(
        @{ extId = "n1"; name = "production"; vlanId = 10; subnetType = "VLAN"; clusterReference = @{ extId = "c1" } },
        @{ extId = "n2"; name = "surebackup-lab"; vlanId = 999; subnetType = "VLAN"; clusterReference = @{ extId = "c1" } }
      )
    }

    $IsolatedNetworkUUID = $null
    $IsolatedNetworkName = $null
    $result = Resolve-IsolatedNetwork
    $result.Name | Should -Be "surebackup-lab"
  }

  It "throws when no matching network exists" {
    Mock Get-PrismSubnets {
      return @(
        @{ extId = "n1"; name = "production"; vlanId = 10; subnetType = "VLAN"; clusterReference = @{ extId = "c1" } }
      )
    }

    $IsolatedNetworkUUID = $null
    $IsolatedNetworkName = $null
    { Resolve-IsolatedNetwork } | Should -Throw "*No isolated network*"
  }
}

# ============================================================
Describe "Remove-PrismVM" {
  BeforeAll {
    $script:PrismApiVersion = "v4"
    $script:LogEntries = New-Object System.Collections.Generic.List[object]
  }

  It "fetches ETag before DELETE in v4 mode" {
    Mock Get-PrismVMByUUID {
      return [PSCustomObject]@{
        VM   = @{ extId = "uuid1"; name = "vm1" }
        ETag = "del-etag"
      }
    }
    $script:capturedIfMatch = $null
    Mock Invoke-PrismAPI {
      $script:capturedIfMatch = $IfMatch
    }

    $result = Remove-PrismVM -UUID "uuid1"
    $result | Should -Be $true
    $script:capturedIfMatch | Should -Be "del-etag"
  }

  It "returns false on failure" {
    Mock Get-PrismVMByUUID { throw "not found" }

    $result = Remove-PrismVM -UUID "uuid1"
    $result | Should -Be $false
  }
}

# ============================================================
Describe "Test-PrismConnection" {
  BeforeAll {
    $script:LogEntries = New-Object System.Collections.Generic.List[object]
  }

  Context "v4 API" {
    BeforeAll { $script:PrismApiVersion = "v4" }

    It "returns true on successful cluster list" {
      Mock Invoke-PrismAPI {
        return @{
          data     = @(@{ extId = "c1"; name = "cluster1" })
          metadata = @{ totalAvailableResults = 1 }
        }
      }

      Test-PrismConnection | Should -Be $true
    }

    It "returns false on connection error" {
      Mock Invoke-PrismAPI { throw "Connection refused" }

      Test-PrismConnection | Should -Be $false
    }
  }

  Context "v3 API" {
    BeforeAll { $script:PrismApiVersion = "v3" }
    AfterAll { $script:PrismApiVersion = "v4" }

    It "uses POST clusters/list for v3" {
      Mock Invoke-PrismAPI {
        param($Method)
        $Method | Should -Be "POST"
        return @{ metadata = @{ total_matches = 2 } }
      }

      Test-PrismConnection | Should -Be $true
    }
  }
}

# ============================================================
Describe "Wait-PrismTask" {
  BeforeAll {
    $script:LogEntries = New-Object System.Collections.Generic.List[object]
  }

  It "returns task on SUCCEEDED status" {
    Mock Get-PrismTaskStatus {
      return @{ status = "SUCCEEDED"; extId = "task1" }
    }

    $result = Wait-PrismTask -TaskUUID "task1" -TimeoutSec 10
    $result.status | Should -Be "SUCCEEDED"
  }

  It "throws on FAILED status with error detail" {
    Mock Get-PrismTaskStatus {
      return @{ status = "FAILED"; errorMessages = @(@{ message = "disk full" }) }
    }

    { Wait-PrismTask -TaskUUID "task1" -TimeoutSec 10 } | Should -Throw "*disk full*"
  }

  It "throws on timeout when task stays RUNNING" {
    Mock Get-PrismTaskStatus {
      return @{ status = "RUNNING" }
    }
    Mock Start-Sleep {}

    { Wait-PrismTask -TaskUUID "task1" -TimeoutSec 0 } | Should -Throw "*timed out*"
  }
}

# ============================================================
Describe "Output contract validation" {
  It "test result objects have all required properties" {
    $script:LogEntries = New-Object System.Collections.Generic.List[object]
    $script:PrismApiVersion = "v4"

    Mock Get-PrismVMByUUID {
      return [PSCustomObject]@{
        VM = @{ powerState = "ON"; guestTools = @{ isEnabled = $true } }
        ETag = "e"
      }
    }

    $result = Test-VMHeartbeat -UUID "u1" -VMName "testvm"
    $result.PSObject.Properties.Name | Should -Contain "VMName"
    $result.PSObject.Properties.Name | Should -Contain "TestName"
    $result.PSObject.Properties.Name | Should -Contain "Passed"
    $result.PSObject.Properties.Name | Should -Contain "Details"
    $result.PSObject.Properties.Name | Should -Contain "Duration"
    $result.PSObject.Properties.Name | Should -Contain "Timestamp"
    $result.Passed | Should -BeOfType [bool]
    $result.Duration | Should -BeOfType [double]
  }

  It "log entry objects have Timestamp, Level, Message" {
    $script:LogEntries = New-Object System.Collections.Generic.List[object]
    Write-Log -Message "test" -Level "INFO"
    $entry = $script:LogEntries[0]
    $entry.PSObject.Properties.Name | Should -Contain "Timestamp"
    $entry.PSObject.Properties.Name | Should -Contain "Level"
    $entry.PSObject.Properties.Name | Should -Contain "Message"
  }
}

# ============================================================
Describe "Smoke test - script integrity" {
  It "script file parses with no syntax errors" {
    $scriptPath = Join-Path $PSScriptRoot "Start-VeeamAHVSureBackup.ps1"
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
    $errors.Count | Should -Be 0
  }

  It "script uses CmdletBinding" {
    $scriptPath = Join-Path $PSScriptRoot "Start-VeeamAHVSureBackup.ps1"
    $content = Get-Content $scriptPath -Raw
    $content | Should -Match '\[CmdletBinding'
  }

  It "script defines all expected functions" {
    $expectedFunctions = @(
      "Write-Log", "Invoke-PrismAPI", "Test-PrismConnection",
      "Get-PrismEntities", "Get-PrismClusters", "Get-PrismSubnets",
      "Get-PrismVMByName", "Get-PrismVMByUUID", "Get-PrismVMIPAddress",
      "Wait-PrismVMPowerState", "Wait-PrismVMIPAddress", "Remove-PrismVM",
      "Get-PrismTaskStatus", "Wait-PrismTask",
      "Test-VMHeartbeat", "Test-VMPing", "Test-VMPort", "Test-VMDNS",
      "Test-VMHttpEndpoint", "Test-VMCustomScript",
      "Invoke-VMVerificationTests", "Get-VMBootOrder",
      "New-HTMLReport", "Export-Results"
    )
    foreach ($fn in $expectedFunctions) {
      Get-Command $fn -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because "function $fn should be defined"
    }
  }

  It "v4 API endpoint constants are set correctly" {
    $script:PrismEndpoints.VMs | Should -Match "vmm/v4"
    $script:PrismEndpoints.Subnets | Should -Match "networking/v4"
    $script:PrismEndpoints.Clusters | Should -Match "clustermgmt/v4"
    $script:PrismEndpoints.Tasks | Should -Match "prism/v4"
  }

  It "all library files parse without syntax errors" {
    $libPath = Join-Path $PSScriptRoot "lib"
    $libFiles = Get-ChildItem -Path $libPath -Filter "*.ps1" -ErrorAction SilentlyContinue
    foreach ($file in $libFiles) {
      $tokens = $null; $errors = $null
      [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
      $errors.Count | Should -Be 0 -Because "$($file.Name) should have no syntax errors"
    }
  }

  It "defines Test-NetworkIsolation function" {
    Get-Command "Test-NetworkIsolation" -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
  }

  It "defines _EscapeHTML function" {
    Get-Command "_EscapeHTML" -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
  }

  It "defines preflight functions" {
    foreach ($fn in @("Test-PreflightRequirements", "Test-ClusterHealth", "Test-ClusterCapacity",
        "Test-IsolatedNetworkHealth", "Test-RestorePointConsistency", "Test-RestorePointRecency",
        "Test-BackupJobStatus", "Test-VBRConnectivity")) {
      Get-Command $fn -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because "function $fn should be defined"
    }
  }

  It "defines VBAHV Plugin REST API functions" {
    foreach ($fn in @("Initialize-VBAHVPluginConnection", "Invoke-VBAHVPluginAPI",
        "Get-VBAHVPrismCentrals", "Get-VBAHVPrismCentralVMs", "Get-VBAHVProtectedVMs",
        "Get-VBAHVRestorePointMetadata",
        "Get-VBAHVJobs", "Get-VBAHVClusters", "Get-VBAHVStorageContainers",
        "Start-AHVFullRestore", "Stop-AHVFullRestore")) {
      Get-Command $fn -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because "function $fn should be defined"
    }
  }

}

# ============================================================
Describe "Network Isolation Safety" {

  BeforeEach {
    $script:LogEntries = New-Object System.Collections.Generic.List[object]
    $script:PrismApiVersion = "v4"
  }

  It "Test-NetworkIsolation warns when VM NIC matches isolated network UUID" {
    $isolatedNet = [PSCustomObject]@{ Name = "SureBackup-Isolated"; UUID = "net-abc-123" }

    # Return Body/ETag wrapper so Resolve-PrismResponseBody can unwrap it
    Mock Invoke-PrismAPI {
      return [PSCustomObject]@{
        Body = @{ data = @(
          @{ extId = "nic1"; networkInfo = @{ subnet = @{ extId = "net-abc-123" } } }
        ) }
        ETag = "e1"
      }
    }

    Test-NetworkIsolation -VMUUID "vm-uuid-1" -IsolatedNetwork $isolatedNet

    $warnings = $script:LogEntries | Where-Object { $_.Level -eq "WARNING" -and $_.Message -match "already on the 'isolated' network" }
    $warnings.Count | Should -BeGreaterThan 0
  }

  It "Test-NetworkIsolation does not warn when VM NIC is on different subnet" {
    $isolatedNet = [PSCustomObject]@{ Name = "SureBackup-Isolated"; UUID = "net-abc-123" }

    Mock Invoke-PrismAPI {
      return [PSCustomObject]@{
        Body = @{ data = @(
          @{ extId = "nic1"; networkInfo = @{ subnet = @{ extId = "net-production-456" } } }
        ) }
        ETag = "e1"
      }
    }

    Test-NetworkIsolation -VMUUID "vm-uuid-1" -IsolatedNetwork $isolatedNet

    $warnings = $script:LogEntries | Where-Object { $_.Level -eq "WARNING" -and $_.Message -match "already on the 'isolated' network" }
    $warnings.Count | Should -Be 0
  }

  It "Test-NetworkIsolation handles API errors gracefully" {
    $isolatedNet = [PSCustomObject]@{ Name = "SureBackup-Isolated"; UUID = "net-abc-123" }

    Mock Invoke-PrismAPI { throw "API connection refused" }

    # Should not throw — just log a warning
    { Test-NetworkIsolation -VMUUID "vm-uuid-1" -IsolatedNetwork $isolatedNet } | Should -Not -Throw

    $warnings = $script:LogEntries | Where-Object { $_.Level -eq "WARNING" -and $_.Message -match "Could not validate" }
    $warnings.Count | Should -BeGreaterThan 0
  }
}

# ============================================================
Describe "HTML Report XSS Protection" {

  It "_EscapeHTML escapes all dangerous HTML characters" {
    _EscapeHTML '<script>alert("xss")</script>' | Should -Be '&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;'
  }

  It "_EscapeHTML handles ampersands" {
    _EscapeHTML 'foo & bar' | Should -Be 'foo &amp; bar'
  }

  It "_EscapeHTML handles single quotes" {
    _EscapeHTML "it's" | Should -Be "it&#39;s"
  }

  It "_EscapeHTML returns empty string for null input" {
    _EscapeHTML $null | Should -Be ""
  }

  It "_EscapeHTML returns empty string for empty input" {
    _EscapeHTML "" | Should -Be ""
  }
}

# ============================================================
Describe "Invoke-PrismAPI Parameter Validation" {

  It "rejects invalid HTTP method" {
    { Invoke-PrismAPI -Method "PATCH" -Endpoint "test" } | Should -Throw
  }

  It "rejects empty endpoint" {
    { Invoke-PrismAPI -Method "GET" -Endpoint "" } | Should -Throw
  }

  It "rejects RetryCount above 10" {
    { Invoke-PrismAPI -Method "GET" -Endpoint "test" -RetryCount 11 } | Should -Throw
  }

  It "rejects negative TimeoutSec" {
    { Invoke-PrismAPI -Method "GET" -Endpoint "test" -TimeoutSec 0 } | Should -Throw
  }
}

# ============================================================
Describe "Boot Order and Application Groups" {

  BeforeEach {
    $script:LogEntries = New-Object System.Collections.Generic.List[object]
    $script:PrismApiVersion = "v4"
  }

  It "returns ordered groups when ApplicationGroups is defined" {
    $script:ApplicationGroups = @{
      1 = @("dc01")
      2 = @("sql01", "web01")
    }

    $restorePoints = @(
      [PSCustomObject]@{ VMName = "dc01"; JobName = "Job1"; RestorePoint = @{}; CreationTime = (Get-Date); BackupSize = 100; IsConsistent = $true }
      [PSCustomObject]@{ VMName = "sql01"; JobName = "Job1"; RestorePoint = @{}; CreationTime = (Get-Date); BackupSize = 200; IsConsistent = $true }
      [PSCustomObject]@{ VMName = "web01"; JobName = "Job1"; RestorePoint = @{}; CreationTime = (Get-Date); BackupSize = 300; IsConsistent = $true }
    )

    $order = Get-VMBootOrder -RestorePoints $restorePoints
    $keys = @($order.Keys)
    $keys.Count | Should -BeGreaterOrEqual 2
    # First group should contain dc01
    $order[$keys[0]] | ForEach-Object { $_.VMName } | Should -Contain "dc01"
  }

  It "puts ungrouped VMs in a catch-all group" {
    $script:ApplicationGroups = @{
      1 = @("dc01")
    }

    $restorePoints = @(
      [PSCustomObject]@{ VMName = "dc01"; JobName = "Job1"; RestorePoint = @{}; CreationTime = (Get-Date); BackupSize = 100; IsConsistent = $true }
      [PSCustomObject]@{ VMName = "orphan01"; JobName = "Job1"; RestorePoint = @{}; CreationTime = (Get-Date); BackupSize = 200; IsConsistent = $true }
    )

    $order = Get-VMBootOrder -RestorePoints $restorePoints
    $allVMs = $order.Values | ForEach-Object { $_ | ForEach-Object { $_.VMName } }
    $allVMs | Should -Contain "orphan01"
  }

  It "returns single group when no ApplicationGroups defined" {
    $script:ApplicationGroups = $null

    $restorePoints = @(
      [PSCustomObject]@{ VMName = "vm1"; JobName = "Job1"; RestorePoint = @{}; CreationTime = (Get-Date); BackupSize = 100; IsConsistent = $true }
      [PSCustomObject]@{ VMName = "vm2"; JobName = "Job1"; RestorePoint = @{}; CreationTime = (Get-Date); BackupSize = 200; IsConsistent = $true }
    )

    $order = Get-VMBootOrder -RestorePoints $restorePoints
    $order.Count | Should -Be 1
  }
}

# ============================================================
Describe "Cleanup Idempotency" {

  BeforeEach {
    $script:LogEntries = New-Object System.Collections.Generic.List[object]
    $script:RecoverySessions = New-Object System.Collections.Generic.List[object]
  }

  It "only cleans up Running or Failed sessions" {
    $cleanedUpSession = [PSCustomObject]@{ OriginalVMName = "vm1"; Status = "CleanedUp"; RecoveryVMUUID = $null; RestoreMethod = "FullRestore" }
    $runningSession = [PSCustomObject]@{ OriginalVMName = "vm2"; Status = "Running"; RecoveryVMUUID = "uuid2"; RestoreMethod = "FullRestore" }
    $script:RecoverySessions.Add($cleanedUpSession)
    $script:RecoverySessions.Add($runningSession)

    Mock Stop-AHVFullRestore {}

    Invoke-Cleanup

    Should -Invoke Stop-AHVFullRestore -Times 1 -Exactly
  }

  It "continues cleanup after individual session failure" {
    $session1 = [PSCustomObject]@{ OriginalVMName = "vm1"; Status = "Running"; RecoveryVMUUID = "uuid1"; RestoreMethod = "FullRestore" }
    $session2 = [PSCustomObject]@{ OriginalVMName = "vm2"; Status = "Running"; RecoveryVMUUID = "uuid2"; RestoreMethod = "FullRestore" }
    $script:RecoverySessions.Add($session1)
    $script:RecoverySessions.Add($session2)

    $callCount = 0
    Mock Stop-AHVFullRestore {
      $callCount++
      if ($callCount -eq 1) { throw "Cleanup failed for first session" }
    }

    Invoke-Cleanup

    Should -Invoke Stop-AHVFullRestore -Times 2 -Exactly
  }

  It "calls Stop-AHVFullRestore for running sessions" {
    $session = [PSCustomObject]@{ OriginalVMName = "vm-full"; Status = "Running"; RecoveryVMUUID = "uuid-full"; RestoreMethod = "FullRestore" }
    $script:RecoverySessions.Add($session)

    Mock Stop-AHVFullRestore {}

    Invoke-Cleanup

    Should -Invoke Stop-AHVFullRestore -Times 1 -Exactly
  }
}

# ============================================================
Describe "Preflight Health Checks" {

  BeforeEach {
    $script:LogEntries = New-Object System.Collections.Generic.List[object]
    $script:PrismApiVersion = "v4"
  }

  Context "Test-ClusterHealth" {
    It "reports CRITICAL cluster as blocking issue" {
      $clusters = @(@{ name = "cluster1"; status = "CRITICAL" })
      $result = Test-ClusterHealth -Clusters $clusters
      $result.Issues.Count | Should -BeGreaterThan 0
      $result.Issues[0] | Should -Match "CRITICAL"
    }

    It "reports DEGRADED cluster as warning" {
      $clusters = @(@{ name = "cluster1"; status = "DEGRADED" })
      $result = Test-ClusterHealth -Clusters $clusters
      $result.Warnings.Count | Should -BeGreaterThan 0
      $result.Issues.Count | Should -Be 0
    }

    It "passes healthy cluster" {
      $clusters = @(@{ name = "cluster1"; status = "NORMAL" })
      $result = Test-ClusterHealth -Clusters $clusters
      $result.Issues.Count | Should -Be 0
      $result.Warnings.Count | Should -Be 0
    }
  }

  Context "Test-ClusterCapacity" {
    It "warns when MaxConcurrentVMs exceeds heuristic" {
      $clusters = @(@{ name = "cluster1"; nodes = @{ nodeList = @(1, 2) } })
      $result = Test-ClusterCapacity -Clusters $clusters -MaxConcurrentVMs 10
      $result.Warnings.Count | Should -BeGreaterThan 0
      $result.Warnings[0] | Should -Match "exceeds recommended"
    }

    It "passes when within capacity" {
      $clusters = @(@{ name = "cluster1"; nodes = @{ nodeList = @(1, 2, 3, 4) } })
      $result = Test-ClusterCapacity -Clusters $clusters -MaxConcurrentVMs 3
      $result.Issues.Count | Should -Be 0
      $result.Warnings.Count | Should -Be 0
    }
  }

  Context "Test-IsolatedNetworkHealth" {
    It "blocks when network has no UUID" {
      $net = [PSCustomObject]@{ UUID = $null; Name = "test"; VlanId = 999 }
      $result = Test-IsolatedNetworkHealth -IsolatedNetwork $net
      $result.Issues.Count | Should -BeGreaterThan 0
    }

    It "warns when network name looks like production" {
      $net = [PSCustomObject]@{ UUID = "net-123"; Name = "production-vlan"; VlanId = 10 }
      $result = Test-IsolatedNetworkHealth -IsolatedNetwork $net
      $result.Warnings.Count | Should -BeGreaterThan 0
      $result.Warnings[0] | Should -Match "production"
    }

    It "passes a properly named isolated network" {
      $net = [PSCustomObject]@{ UUID = "net-123"; Name = "surebackup-isolated"; VlanId = 999 }
      $result = Test-IsolatedNetworkHealth -IsolatedNetwork $net
      $result.Issues.Count | Should -Be 0
      $result.Warnings.Count | Should -Be 0
    }
  }

  Context "Test-RestorePointRecency" {
    It "warns about stale restore points" {
      $rps = @([PSCustomObject]@{ VMName = "vm1"; CreationTime = (Get-Date).AddDays(-30) })
      $result = Test-RestorePointRecency -RestorePoints $rps -MaxAgeDays 7
      $result.Warnings.Count | Should -BeGreaterThan 0
      $result.Warnings[0] | Should -Match "days old"
    }

    It "passes recent restore points" {
      $rps = @([PSCustomObject]@{ VMName = "vm1"; CreationTime = (Get-Date).AddDays(-1) })
      $result = Test-RestorePointRecency -RestorePoints $rps -MaxAgeDays 7
      $result.Warnings.Count | Should -Be 0
    }
  }

  Context "Test-RestorePointConsistency" {
    It "warns about crash-consistent restore points" {
      $rps = @([PSCustomObject]@{ VMName = "vm1"; IsConsistent = $false; JobName = "Job1"; CreationTime = Get-Date })
      $result = Test-RestorePointConsistency -RestorePoints $rps
      $result.Warnings.Count | Should -BeGreaterThan 0
    }

    It "passes application-consistent restore points" {
      $rps = @([PSCustomObject]@{ VMName = "vm1"; IsConsistent = $true; JobName = "Job1"; CreationTime = Get-Date })
      $result = Test-RestorePointConsistency -RestorePoints $rps
      $result.Warnings.Count | Should -Be 0
    }
  }

  Context "Test-VBRConnectivity" {
    It "reports blocking issue when VBR is unreachable" {
      $result = Test-VBRConnectivity -VBRHost "192.168.255.254" -VBRPort 9419
      $result.Issues.Count | Should -BeGreaterThan 0
    }
  }

  Context "Test-PreflightRequirements orchestrator" {
    It "returns Success=true when no blocking issues" {
      $clusters = @(@{ name = "cluster1"; status = "NORMAL"; nodes = @{ nodeList = @(1, 2, 3) } })
      $net = [PSCustomObject]@{ UUID = "net-123"; Name = "surebackup-lab"; VlanId = 999 }
      $rps = @([PSCustomObject]@{ VMName = "vm1"; IsConsistent = $true; CreationTime = (Get-Date).AddHours(-2); JobName = "Job1" })

      Mock Test-BackupJobStatus { return [PSCustomObject]@{ Issues = @(); Warnings = @() } }

      $result = Test-PreflightRequirements -Clusters $clusters -IsolatedNetwork $net -RestorePoints $rps -BackupJobs @(@{}) -MaxConcurrentVMs 3 -MaxAgeDays 7
      $result.Success | Should -Be $true
    }

    It "returns Success=false when cluster is CRITICAL" {
      $clusters = @(@{ name = "cluster1"; status = "CRITICAL"; nodes = @{ nodeList = @(1) } })
      $net = [PSCustomObject]@{ UUID = "net-123"; Name = "surebackup-lab"; VlanId = 999 }
      $rps = @([PSCustomObject]@{ VMName = "vm1"; IsConsistent = $true; CreationTime = (Get-Date); JobName = "Job1" })

      Mock Test-BackupJobStatus { return [PSCustomObject]@{ Issues = @(); Warnings = @() } }

      $result = Test-PreflightRequirements -Clusters $clusters -IsolatedNetwork $net -RestorePoints $rps -BackupJobs @(@{}) -MaxConcurrentVMs 3 -MaxAgeDays 7
      $result.Success | Should -Be $false
    }
  }
}

# ============================================================
Describe "VBAHV Plugin REST API" {

  BeforeEach {
    $script:LogEntries = New-Object System.Collections.Generic.List[object]
    $script:VBAHVBaseUrl = "https://vbr01:9419/extension/799a5a3e-ae1e-4eaf-86eb-8a9acc2670e2/api/v9"
    $script:VBAHVHeaders = @{
      "Authorization" = "Bearer test-token"
      "Content-Type"  = "application/json"
    }
  }

  Context "Invoke-VBAHVPluginAPI" {
    It "rejects invalid HTTP method" {
      { Invoke-VBAHVPluginAPI -Method "PATCH" -Endpoint "test" } | Should -Throw
    }

    It "rejects empty endpoint" {
      { Invoke-VBAHVPluginAPI -Method "GET" -Endpoint "" } | Should -Throw
    }

    It "calls Invoke-RestMethod with correct URL" {
      $script:capturedUri = $null
      Mock Invoke-RestMethod {
        $script:capturedUri = $Uri
        return @{ data = @() }
      }

      Invoke-VBAHVPluginAPI -Method "GET" -Endpoint "restorePoints"
      $script:capturedUri | Should -Match "extension/799a5a3e.*restorePoints"
    }

    It "serializes body as JSON" {
      $script:capturedBody = $null
      Mock Invoke-RestMethod {
        $script:capturedBody = $Body
        return @{ id = "session-1" }
      }

      Invoke-VBAHVPluginAPI -Method "POST" -Endpoint "restorePoints/restore" -Body @{ restorePointId = "rp1" }
      $parsed = $script:capturedBody | ConvertFrom-Json
      $parsed.restorePointId | Should -Be "rp1"
    }

    It "retries on 5xx errors" {
      $script:callCount = 0
      Mock Invoke-RestMethod {
        $script:callCount++
        if ($script:callCount -le 1) {
          throw (New-MockHttpException -StatusCode 500)
        }
        return @{ data = @() }
      }
      Mock Start-Sleep {}

      Invoke-VBAHVPluginAPI -Method "GET" -Endpoint "test" -RetryCount 2
      $script:callCount | Should -Be 2
    }

    It "does NOT retry on 401" {
      Mock Invoke-RestMethod { throw (New-MockHttpException -StatusCode 401) }
      Mock Start-Sleep {}

      { Invoke-VBAHVPluginAPI -Method "GET" -Endpoint "test" -RetryCount 3 } | Should -Throw
      Should -Invoke Invoke-RestMethod -Times 1
    }
  }

  Context "Get-VBAHVJobs" {
    It "returns all jobs from REST API" {
      Mock Invoke-VBAHVPluginAPI {
        return @{
          results = @(
            @{ name = "AHV-Job1"; id = "j1" },
            @{ name = "AHV-Job2"; id = "j2" }
          )
        }
      }

      $result = Get-VBAHVJobs
      @($result).Count | Should -Be 2
    }

    It "filters by job names" {
      Mock Invoke-VBAHVPluginAPI {
        return @{
          results = @(
            @{ name = "AHV-Job1"; id = "j1" },
            @{ name = "AHV-Job2"; id = "j2" }
          )
        }
      }

      $result = @(Get-VBAHVJobs -JobNames @("AHV-Job1"))
      $result.Count | Should -Be 1
      $result[0].name | Should -Be "AHV-Job1"
    }

    It "throws when no jobs found" {
      Mock Invoke-VBAHVPluginAPI { return @{ results = @() } }

      { Get-VBAHVJobs } | Should -Throw "*No Nutanix AHV backup jobs found*"
    }
  }

  Context "Get-VBAHVRestorePointMetadata" {
    It "calls correct endpoint" {
      $script:capturedEndpoint = $null
      Mock Invoke-VBAHVPluginAPI {
        $script:capturedEndpoint = $Endpoint
        return @{
          id = "rp1"
          clusterId = "c1"
          networkAdapters = @(@{ macAddress = "aa:bb:cc:dd:ee:ff"; networkId = "net1"; networkName = "prod" })
          disks = @(@{ id = "d1"; size = 100 })
        }
      }

      $result = Get-VBAHVRestorePointMetadata -RestorePointId "rp1"
      $script:capturedEndpoint | Should -Be "restorePoints/rp1/metadata"
      $result.clusterId | Should -Be "c1"
      $result.networkAdapters.Count | Should -Be 1
    }
  }

  Context "Get-VBAHVClusters" {
    It "calls clusters endpoint" {
      Mock Invoke-VBAHVPluginAPI {
        return @(
          @{ id = "c1"; name = "NX-Cluster-01" }
        )
      }

      $result = @(Get-VBAHVClusters)
      $result.Count | Should -Be 1
      $result[0].name | Should -Be "NX-Cluster-01"
    }
  }

  Context "Get-VBAHVStorageContainers" {
    It "calls correct cluster-scoped endpoint" {
      $script:capturedEndpoint = $null
      Mock Invoke-VBAHVPluginAPI {
        $script:capturedEndpoint = $Endpoint
        return @{
          results = @(
            @{ id = "sc1"; name = "default-container" }
          )
        }
      }

      $result = Get-VBAHVStorageContainers -ClusterId "c1"
      $script:capturedEndpoint | Should -Be "clusters/c1/storageContainers"
      @($result).Count | Should -Be 1
    }
  }

  Context "Start-AHVFullRestore NIC remap" {
    It "uses originalMacAddress (not macAddress) in network adapter remap" {
      $script:capturedBody = $null

      Mock Get-VBAHVRestorePointMetadata {
        return @{
          clusterId = "c1"
          networkAdapters = @(
            @{ macAddress = "aa:bb:cc:dd:ee:ff"; networkId = "net-prod"; networkName = "production" }
          )
        }
      }

      Mock Invoke-VBAHVPluginAPI {
        param($Method, $Endpoint, $Body)
        if ($Method -eq "POST" -and $Endpoint -eq "restorePoints/restore") {
          $script:capturedBody = $Body
          return @{ sessionId = "session-1" }
        }
        if ($Endpoint -match "sessions/") {
          return @{ state = "Finished"; result = "Success" }
        }
        return @()
      }

      Mock Get-PrismVMByName { return @(@{ extId = "vm-uuid-1"; name = "SureBackup_test-vm_123456_abc" }) }
      Mock Set-PrismVMPowerState {}
      Mock Start-Sleep {}

      $script:RecoverySessions = New-Object System.Collections.Generic.List[object]
      $rpInfo = [PSCustomObject]@{ VMName = "test-vm"; RestorePointId = "rp1"; CreationTime = Get-Date; JobName = "Job1" }
      $isolatedNet = [PSCustomObject]@{ UUID = "net-iso-1"; Name = "isolated-lab" }

      Start-AHVFullRestore -RestorePointInfo $rpInfo -IsolatedNetwork $isolatedNet

      $script:capturedBody | Should -Not -BeNullOrEmpty
      $script:capturedBody.networkAdapters[0].originalMacAddress | Should -Be "aa:bb:cc:dd:ee:ff"
      # Should NOT have 'macAddress' key at the top level of the remap
      $script:capturedBody.networkAdapters[0].Keys | Should -Not -Contain "macAddress"
    }

    It "always sends required fields in restore body" {
      $script:capturedBody = $null

      Mock Get-VBAHVRestorePointMetadata {
        return @{ clusterId = "c1"; networkAdapters = @() }
      }

      Mock Invoke-VBAHVPluginAPI {
        param($Method, $Endpoint, $Body)
        if ($Method -eq "POST" -and $Endpoint -eq "restorePoints/restore") {
          $script:capturedBody = $Body
          return @{ sessionId = "session-1" }
        }
        if ($Endpoint -match "sessions/") {
          return @{ state = "Finished"; result = "Success" }
        }
        return @()
      }

      Mock Get-PrismVMByName { return @(@{ extId = "vm-uuid-1" }) }
      Mock Set-PrismVMPowerState {}
      Mock Start-Sleep {}

      $script:RecoverySessions = New-Object System.Collections.Generic.List[object]
      $rpInfo = [PSCustomObject]@{ VMName = "test-vm"; RestorePointId = "rp1"; CreationTime = Get-Date; JobName = "Job1" }
      $isolatedNet = [PSCustomObject]@{ UUID = "net-iso-1"; Name = "isolated-lab" }

      Start-AHVFullRestore -RestorePointInfo $rpInfo -IsolatedNetwork $isolatedNet

      $script:capturedBody | Should -Not -BeNullOrEmpty
      $script:capturedBody.Keys | Should -Contain "restoreToOriginal"
      $script:capturedBody.Keys | Should -Contain "powerOnVmAfterRestore"
      $script:capturedBody.Keys | Should -Contain "restoreVmCategories"
      $script:capturedBody.restoreToOriginal | Should -Be $false
      $script:capturedBody.powerOnVmAfterRestore | Should -Be $false
      $script:capturedBody.restoreVmCategories | Should -Be $false
    }

    It "returns Failed status when restore API returns no sessionId" {
      Mock Get-VBAHVRestorePointMetadata {
        return @{ clusterId = "c1"; networkAdapters = @() }
      }

      Mock Invoke-VBAHVPluginAPI {
        param($Method, $Endpoint, $Body)
        if ($Method -eq "POST" -and $Endpoint -eq "restorePoints/restore") {
          return @{ unexpectedField = "no-session-id" }
        }
        return @()
      }

      Mock Start-Sleep {}

      $script:RecoverySessions = New-Object System.Collections.Generic.List[object]
      $rpInfo = [PSCustomObject]@{ VMName = "test-vm"; RestorePointId = "rp1"; CreationTime = Get-Date; JobName = "Job1" }
      $isolatedNet = [PSCustomObject]@{ UUID = "net-iso-1"; Name = "isolated-lab" }

      $result = Start-AHVFullRestore -RestorePointInfo $rpInfo -IsolatedNetwork $isolatedNet
      $result.Status | Should -Be "Failed"
      $result.Error | Should -BeLike "*no sessionId*"
    }
  }

  Context "_NewRecoveryInfo" {
    It "defaults to FullRestore" {
      $info = _NewRecoveryInfo -OriginalVMName "vm1" -RecoveryVMName "rec1" -Status "Running"
      $info.RestoreMethod | Should -Be "FullRestore"
    }

    It "does not have VBRSession property" {
      $info = _NewRecoveryInfo -OriginalVMName "vm1" -RecoveryVMName "rec1" -Status "Running"
      $info.PSObject.Properties.Name | Should -Not -Contain "VBRSession"
    }
  }
}
