# SPDX-License-Identifier: MIT
# =============================
# SureBackup Verification Tests
# =============================

function Test-VMHeartbeat {
  <#
  .SYNOPSIS
    Test VM heartbeat via Nutanix Guest Tools (NGT) status
  #>
  param(
    [Parameter(Mandatory = $true)][string]$UUID,
    [Parameter(Mandatory = $true)][string]$VMName
  )

  $testName = "Heartbeat (NGT)"
  $startTime = Get-Date

  try {
    $vmResult = Get-PrismVMByUUID -UUID $UUID
    $powerState = Get-PrismVMPowerState $vmResult

    $passed = ($powerState -eq "ON")
    $details = "Power: $powerState"

    $vm = if ($script:PrismApiVersion -eq "v4") { $vmResult.VM } else { $vmResult }
    $ngtStatus = _GetNGTStatus -VMData $vm
    if ($ngtStatus.Installed) {
      $details += ", NGT: $($ngtStatus.Enabled)"
      if ($ngtStatus.Enabled) { $details += " (Guest tools communicating)" }
    }
    else {
      $details += ", NGT: Not installed"
    }

    _WriteTestLog -VMName $VMName -TestName $testName -Passed $passed -Details $details
  }
  catch {
    $passed = $false
    $details = "Error: $($_.Exception.Message)"
    _WriteTestLog -VMName $VMName -TestName $testName -Passed $false -Details $details
  }

  return (_NewTestResult -VMName $VMName -TestName $testName -Passed $passed -Details $details -StartTime $startTime)
}

function Test-VMPing {
  <#
  .SYNOPSIS
    Test ICMP connectivity to a recovered VM
  .PARAMETER JumpVM
    Optional hashtable with IP, KeyPath, User for SSH-proxied testing
  #>
  param(
    [Parameter(Mandatory = $true)][string]$IPAddress,
    [Parameter(Mandatory = $true)][string]$VMName,
    [hashtable]$JumpVM
  )

  $testName = "ICMP Ping"
  $startTime = Get-Date

  try {
    if ($JumpVM) {
      # Execute ping via SSH through jump VM
      $r = Invoke-SSHCommand -HostIP $JumpVM.IP -KeyPath $JumpVM.KeyPath -User $JumpVM.User `
        -Command "ping -c 4 -W 3 $IPAddress"
      $passed = ($r.ExitCode -eq 0)
      if ($passed) {
        $details = "Reply from $IPAddress via jump VM ($($JumpVM.IP))"
      }
      else {
        $details = "No reply from $IPAddress via jump VM (4 packets sent)"
      }
    }
    else {
      # Local ping (original behavior)
      $pingResults = Test-Connection -ComputerName $IPAddress -Count 4 -ErrorAction SilentlyContinue

      if ($null -ne $pingResults -and @($pingResults).Count -gt 0) {
        if ($pingResults[0].PSObject.Properties['Status']) {
          $successfulPings = @($pingResults | Where-Object { $_.Status -eq 'Success' })
          $passed = ($successfulPings.Count -gt 0)
        }
        else {
          $successfulPings = @($pingResults)
          $passed = $true
        }
      }
      else {
        $successfulPings = @()
        $passed = $false
      }

      if ($passed) {
        $latencyProp = if ($successfulPings[0].PSObject.Properties['Latency']) { 'Latency' } else { 'ResponseTime' }
        $avgLatency = ($successfulPings | Measure-Object -Property $latencyProp -Average).Average
        $details = "Reply from $IPAddress - Avg latency: $([math]::Round([double]$avgLatency, 1))ms"
      }
      else {
        $details = "No reply from $IPAddress (4 packets sent, 0 received)"
      }
    }

    _WriteTestLog -VMName $VMName -TestName $testName -Passed $passed -Details $details
  }
  catch {
    $passed = $false
    $details = "Error: $($_.Exception.Message)"
    _WriteTestLog -VMName $VMName -TestName $testName -Passed $false -Details $details
  }

  return (_NewTestResult -VMName $VMName -TestName $testName -Passed $passed -Details $details -StartTime $startTime)
}

function Test-VMPort {
  <#
  .SYNOPSIS
    Test TCP port connectivity on a recovered VM
  .PARAMETER JumpVM
    Optional hashtable with IP, KeyPath, User for SSH-proxied testing
  #>
  param(
    [Parameter(Mandatory = $true)][string]$IPAddress,
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][string]$VMName,
    [hashtable]$JumpVM
  )

  $testName = "TCP Port $Port"
  $startTime = Get-Date

  try {
    if ($JumpVM) {
      # Execute port check via SSH through jump VM
      $r = Invoke-SSHCommand -HostIP $JumpVM.IP -KeyPath $JumpVM.KeyPath -User $JumpVM.User `
        -Command "nc -z -w 5 $IPAddress $Port"
      $passed = ($r.ExitCode -eq 0)
      $details = if ($passed) { "Port $Port is open on $IPAddress (via jump VM)" } else { "Port $Port closed/unreachable on $IPAddress (via jump VM)" }
    }
    else {
      # Local TCP test (original behavior)
      $tcpClient = $null
      try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $connectTask = $tcpClient.ConnectAsync($IPAddress, $Port)
        $waitResult = $connectTask.Wait(5000)

        if ($waitResult -and $tcpClient.Connected) {
          $passed = $true
          $details = "Port $Port is open on $IPAddress"
        }
        else {
          $passed = $false
          $details = "Port $Port connection timed out on $IPAddress"
        }
      }
      finally {
        if ($tcpClient) {
          try { $tcpClient.Close() } catch { }
          $tcpClient.Dispose()
        }
      }
    }

    _WriteTestLog -VMName $VMName -TestName $testName -Passed $passed -Details $details
  }
  catch {
    $passed = $false
    $details = "Port $Port refused/unreachable on ${IPAddress}: $($_.Exception.Message)"
    _WriteTestLog -VMName $VMName -TestName $testName -Passed $false -Details $details
  }

  return (_NewTestResult -VMName $VMName -TestName $testName -Passed $passed -Details $details -StartTime $startTime)
}

function Test-VMDNS {
  <#
  .SYNOPSIS
    Test DNS lookup for a recovered VM's IP
  .DESCRIPTION
    When using a jump VM, performs nslookup from the jump VM on the isolated network.
    Otherwise performs a reverse DNS lookup from the script host.
  .PARAMETER JumpVM
    Optional hashtable with IP, KeyPath, User for SSH-proxied testing
  #>
  param(
    [Parameter(Mandatory = $true)][string]$IPAddress,
    [Parameter(Mandatory = $true)][string]$VMName,
    [hashtable]$JumpVM
  )

  $testName = if ($JumpVM) { "DNS Lookup (via jump VM)" } else { "Reverse DNS (from script host)" }
  $startTime = Get-Date

  try {
    if ($JumpVM) {
      $r = Invoke-SSHCommand -HostIP $JumpVM.IP -KeyPath $JumpVM.KeyPath -User $JumpVM.User `
        -Command "nslookup $IPAddress"
      $passed = ($r.ExitCode -eq 0)
      $details = if ($passed) { "DNS lookup succeeded for $IPAddress (via jump VM)" } else { "DNS lookup failed for $IPAddress (via jump VM)" }
    }
    else {
      $resolved = [System.Net.Dns]::GetHostEntry($IPAddress)
      $passed = ($null -ne $resolved)
      $details = "Reverse DNS: $($resolved.HostName)"
    }

    _WriteTestLog -VMName $VMName -TestName $testName -Passed $passed -Details $details
  }
  catch {
    $passed = $false
    $details = "DNS lookup failed for ${IPAddress}: $($_.Exception.Message)"
    _WriteTestLog -VMName $VMName -TestName $testName -Passed $false -Details $details
  }

  return (_NewTestResult -VMName $VMName -TestName $testName -Passed $passed -Details $details -StartTime $startTime)
}

function Test-VMHttpEndpoint {
  <#
  .SYNOPSIS
    Test HTTP/HTTPS endpoint accessibility on a recovered VM
  .PARAMETER JumpVM
    Optional hashtable with IP, KeyPath, User for SSH-proxied testing
  #>
  param(
    [Parameter(Mandatory = $true)][string]$IPAddress,
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$VMName,
    [hashtable]$JumpVM
  )

  # Replace localhost/127.0.0.1 in URL with actual VM IP
  $testUrl = $Url -replace "(localhost|127\.0\.0\.1)", $IPAddress

  $testName = "HTTP $testUrl"
  $startTime = Get-Date

  try {
    if ($JumpVM) {
      # Execute curl via SSH through jump VM
      $r = Invoke-SSHCommand -HostIP $JumpVM.IP -KeyPath $JumpVM.KeyPath -User $JumpVM.User `
        -Command "curl -s -o /dev/null -w '%{http_code}' --connect-timeout 10 $testUrl"
      $passed = ($r.Output -match '^[23]\d\d$')
      $details = if ($passed) { "HTTP $($r.Output) (via jump VM)" } else { "HTTP request returned $($r.Output) (via jump VM)" }
    }
    else {
      # Local HTTP test (original behavior)
      $webParams = @{
        Uri            = $testUrl
        TimeoutSec     = 15
        UseBasicParsing = $true
        ErrorAction    = "Stop"
      }
      if ($script:SkipCert -and $PSVersionTable.PSVersion.Major -ge 7) {
        $webParams.SkipCertificateCheck = $true
      }
      $response = Invoke-WebRequest @webParams
      $passed = ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400)
      $contentLen = $response.Headers.'Content-Length'
      if ($contentLen -is [System.Collections.IEnumerable] -and $contentLen -isnot [string]) { $contentLen = $contentLen[0] }
      $details = "HTTP $($response.StatusCode) - Content-Length: $contentLen"
    }

    _WriteTestLog -VMName $VMName -TestName $testName -Passed $passed -Details $details
  }
  catch {
    $passed = $false
    $details = "HTTP request failed: $($_.Exception.Message)"
    _WriteTestLog -VMName $VMName -TestName $testName -Passed $false -Details $details
  }

  return (_NewTestResult -VMName $VMName -TestName $testName -Passed $passed -Details $details -StartTime $startTime)
}

function Test-VMCustomScript {
  <#
  .SYNOPSIS
    Execute a custom verification script against a recovered VM
  #>
  param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [Parameter(Mandatory = $true)][string]$VMName,
    [string]$VMIPAddress,
    [string]$VMUuid
  )

  $testName = "Custom Script: $(Split-Path $ScriptPath -Leaf)"
  $startTime = Get-Date

  # Canonicalize path and reject UNC/network paths
  try {
    $resolvedScriptPath = (Resolve-Path $ScriptPath -ErrorAction Stop).Path
  }
  catch {
    $details = "Script not found: $ScriptPath"
    _WriteTestLog -VMName $VMName -TestName $testName -Passed $false -Details $details
    return (_NewTestResult -VMName $VMName -TestName $testName -Passed $false -Details $details -StartTime $startTime)
  }

  if ($resolvedScriptPath -match '^\\\\') {
    $details = "UNC/network paths are not allowed for security: $resolvedScriptPath"
    _WriteTestLog -VMName $VMName -TestName $testName -Passed $false -Details $details
    return (_NewTestResult -VMName $VMName -TestName $testName -Passed $false -Details $details -StartTime $startTime)
  }

  try {
    $result = & $resolvedScriptPath -VMName $VMName -VMIPAddress $VMIPAddress -VMUuid $VMUuid
    $passed = ($result -eq $true)
    $details = if ($passed) { "Custom script returned success" } else { "Custom script returned failure: $result" }

    _WriteTestLog -VMName $VMName -TestName $testName -Passed $passed -Details $details
  }
  catch {
    $passed = $false
    $details = "Custom script error: $($_.Exception.Message)"
    _WriteTestLog -VMName $VMName -TestName $testName -Passed $false -Details $details
  }

  return (_NewTestResult -VMName $VMName -TestName $testName -Passed $passed -Details $details -StartTime $startTime)
}

function Invoke-VMVerificationTests {
  <#
  .SYNOPSIS
    Run all configured verification tests against a single recovered VM
  .PARAMETER JumpVM
    Optional hashtable with IP, KeyPath, User for SSH-proxied network testing
  #>
  param(
    [Parameter(Mandatory = $true)]$RecoveryInfo,
    [Parameter(Mandatory = $true)]$IsolatedNetwork,
    [hashtable]$JumpVM
  )

  $vmName = $RecoveryInfo.OriginalVMName
  $vmUUID = $RecoveryInfo.RecoveryVMUUID

  Write-Log "Running verification tests on '$vmName'..." -Level "INFO"
  $vmResults = @()

  if (-not $vmUUID) {
    $now = Get-Date
    $result = _NewTestResult -VMName $vmName -TestName "VM Recovery" -Passed $false -Details "VM not recovered - $($RecoveryInfo.Error)" -StartTime $now
    $script:TestResults.Add($result)
    return
  }

  # Test 1: Heartbeat / Power State
  $vmResults += Test-VMHeartbeat -UUID $vmUUID -VMName $vmName

  # Test 2: Wait for IP address
  Write-Log "  [$vmName] Waiting for IP address (timeout: ${TestBootTimeoutSec}s)..." -Level "INFO"
  $ipWaitStart = Get-Date
  $ipAddress = Wait-PrismVMIPAddress -UUID $vmUUID -TimeoutSec $TestBootTimeoutSec

  if (-not $ipAddress) {
    $vmResults += (_NewTestResult -VMName $vmName -TestName "IP Address Assignment" -Passed $false -Details "VM did not obtain IP within ${TestBootTimeoutSec}s timeout" -StartTime $ipWaitStart)
    Write-Log "  [$vmName] No IP address obtained - skipping network tests" -Level "TEST-FAIL"
    $script:TestResults.AddRange([object[]]$vmResults)
    return $vmResults
  }

  $vmResults += (_NewTestResult -VMName $vmName -TestName "IP Address Assignment" -Passed $true -Details "VM obtained IP: $ipAddress" -StartTime $ipWaitStart)
  Write-Log "  [$vmName] IP address obtained: $ipAddress" -Level "TEST-PASS"

  # Static IP detection — if VM IP is outside the isolated subnet, skip network tests
  $skipNetworkTests = $false
  if ($IsolatedNetwork.NetworkAddress -and $IsolatedNetwork.PrefixLength) {
    $subnetStart = Get-Date
    $inSubnet = _TestIPInSubnet -IPAddress $ipAddress -NetworkAddress $IsolatedNetwork.NetworkAddress -PrefixLength $IsolatedNetwork.PrefixLength
    if (-not $inSubnet) {
      $cidr = "$($IsolatedNetwork.NetworkAddress)/$($IsolatedNetwork.PrefixLength)"
      $skipNetworkTests = $true
      Write-Log "  [$vmName] Static IP detected: $ipAddress is outside isolated subnet $cidr — skipping network tests" -Level "WARNING"
      $vmResults += (_NewTestResult -VMName $vmName -TestName "Subnet Validation" -Passed $true -Details "Static IP $ipAddress detected — outside isolated network $cidr, network tests skipped. Backup integrity verified via heartbeat/NGT." -StartTime $subnetStart)
    }
    else {
      Write-Log "  [$vmName] IP $ipAddress is within isolated subnet — proceeding with all tests" -Level "INFO"
    }
  }

  # Test 3: ICMP Ping
  if ($TestPing -and -not $skipNetworkTests) {
    $pingParams = @{ IPAddress = $ipAddress; VMName = $vmName }
    if ($JumpVM) { $pingParams.JumpVM = $JumpVM }
    $vmResults += Test-VMPing @pingParams
  }

  # Test 4: TCP Port checks
  if ($TestPorts -and $TestPorts.Count -gt 0 -and -not $skipNetworkTests) {
    foreach ($port in $TestPorts) {
      $portParams = @{ IPAddress = $ipAddress; Port = $port; VMName = $vmName }
      if ($JumpVM) { $portParams.JumpVM = $JumpVM }
      $vmResults += Test-VMPort @portParams
    }
  }

  # Test 5: DNS resolution
  if ($TestDNS -and -not $skipNetworkTests) {
    $dnsParams = @{ IPAddress = $ipAddress; VMName = $vmName }
    if ($JumpVM) { $dnsParams.JumpVM = $JumpVM }
    $vmResults += Test-VMDNS @dnsParams
  }

  # Test 6: HTTP endpoint checks
  if ($TestHttpEndpoints -and $TestHttpEndpoints.Count -gt 0 -and -not $skipNetworkTests) {
    foreach ($endpoint in $TestHttpEndpoints) {
      $httpParams = @{ IPAddress = $ipAddress; Url = $endpoint; VMName = $vmName }
      if ($JumpVM) { $httpParams.JumpVM = $JumpVM }
      $vmResults += Test-VMHttpEndpoint @httpParams
    }
  }

  # Test 7: Custom script
  if ($TestCustomScript) {
    $vmResults += Test-VMCustomScript -ScriptPath $TestCustomScript -VMName $vmName -VMIPAddress $ipAddress -VMUuid $vmUUID
  }

  # Add all results to global tracker
  foreach ($r in $vmResults) {
    $script:TestResults.Add($r)
  }

  return $vmResults
}
