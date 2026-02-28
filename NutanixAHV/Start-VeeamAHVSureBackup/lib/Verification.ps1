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

    $vm = if ($PrismApiVersion -eq "v4") { $vmResult.VM } else { $vmResult }
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
  #>
  param(
    [Parameter(Mandatory = $true)][string]$IPAddress,
    [Parameter(Mandatory = $true)][string]$VMName
  )

  $testName = "ICMP Ping"
  $startTime = Get-Date

  try {
    $pingResult = Test-Connection -ComputerName $IPAddress -Count 4 -Quiet -ErrorAction SilentlyContinue
    $passed = $pingResult

    if ($passed) {
      # Get latency details (PS 7 uses 'Latency', PS 5.1 uses 'ResponseTime')
      $pingDetail = Test-Connection -ComputerName $IPAddress -Count 2 -ErrorAction SilentlyContinue
      $latencyProp = if ($pingDetail[0].PSObject.Properties['Latency']) { 'Latency' } else { 'ResponseTime' }
      $avgLatency = ($pingDetail | Measure-Object -Property $latencyProp -Average).Average
      $details = "Reply from $IPAddress - Avg latency: $([math]::Round($avgLatency, 1))ms"
    }
    else {
      $details = "No reply from $IPAddress (4 packets sent, 0 received)"
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
  #>
  param(
    [Parameter(Mandatory = $true)][string]$IPAddress,
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][string]$VMName
  )

  $testName = "TCP Port $Port"
  $startTime = Get-Date

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

    $tcpClient.Close()
    $tcpClient.Dispose()

    _WriteTestLog -VMName $VMName -TestName $testName -Passed $passed -Details $details
  }
  catch {
    $passed = $false
    $details = "Port $Port refused/unreachable on ${IPAddress}: $($_.Exception.Message)"
    _WriteTestLog -VMName $VMName -TestName $testName -Passed $false -Details $details

    if ($tcpClient) {
      $tcpClient.Dispose()
    }
  }

  return (_NewTestResult -VMName $VMName -TestName $testName -Passed $passed -Details $details -StartTime $startTime)
}

function Test-VMDNS {
  <#
  .SYNOPSIS
    Test DNS resolution capability
  #>
  param(
    [Parameter(Mandatory = $true)][string]$IPAddress,
    [Parameter(Mandatory = $true)][string]$VMName
  )

  $testName = "DNS Resolution"
  $startTime = Get-Date

  try {
    # Test if the VM can be resolved by its name and if DNS is functional
    $resolved = [System.Net.Dns]::GetHostEntry($IPAddress)
    $passed = ($null -ne $resolved)
    $details = "Reverse DNS: $($resolved.HostName)"

    _WriteTestLog -VMName $VMName -TestName $testName -Passed $passed -Details $details
  }
  catch {
    $passed = $false
    $details = "DNS resolution failed for ${IPAddress}: $($_.Exception.Message)"
    _WriteTestLog -VMName $VMName -TestName $testName -Passed $false -Details $details
  }

  return (_NewTestResult -VMName $VMName -TestName $testName -Passed $passed -Details $details -StartTime $startTime)
}

function Test-VMHttpEndpoint {
  <#
  .SYNOPSIS
    Test HTTP/HTTPS endpoint accessibility on a recovered VM
  #>
  param(
    [Parameter(Mandatory = $true)][string]$IPAddress,
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$VMName
  )

  # Replace localhost/127.0.0.1 in URL with actual VM IP
  $testUrl = $Url -replace "(localhost|127\.0\.0\.1)", $IPAddress

  $testName = "HTTP $testUrl"
  $startTime = Get-Date

  try {
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
    $details = "HTTP $($response.StatusCode) - Content-Length: $($response.Headers.'Content-Length')"

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

  if (-not (Test-Path $ScriptPath)) {
    $details = "Script not found: $ScriptPath"
    _WriteTestLog -VMName $VMName -TestName $testName -Passed $false -Details $details
    return (_NewTestResult -VMName $VMName -TestName $testName -Passed $false -Details $details -StartTime $startTime)
  }

  try {
    $result = & $ScriptPath -VMName $VMName -VMIPAddress $VMIPAddress -VMUuid $VMUuid
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
  #>
  param(
    [Parameter(Mandatory = $true)]$RecoveryInfo,
    [Parameter(Mandatory = $true)]$IsolatedNetwork
  )

  $vmName = $RecoveryInfo.OriginalVMName
  $vmUUID = $RecoveryInfo.RecoveryVMUUID

  Write-Log "Running verification tests on '$vmName'..." -Level "INFO"
  $vmResults = @()

  if (-not $vmUUID) {
    $now = Get-Date
    $vmResults += (_NewTestResult -VMName $vmName -TestName "VM Recovery" -Passed $false -Details "VM not recovered - $($RecoveryInfo.Error)" -StartTime $now)
    return $vmResults
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

  # Test 3: ICMP Ping
  if ($TestPing) {
    $vmResults += Test-VMPing -IPAddress $ipAddress -VMName $vmName
  }

  # Test 4: TCP Port checks
  if ($TestPorts -and $TestPorts.Count -gt 0) {
    foreach ($port in $TestPorts) {
      $vmResults += Test-VMPort -IPAddress $ipAddress -Port $port -VMName $vmName
    }
  }

  # Test 5: DNS resolution
  if ($TestDNS) {
    $vmResults += Test-VMDNS -IPAddress $ipAddress -VMName $vmName
  }

  # Test 6: HTTP endpoint checks
  if ($TestHttpEndpoints -and $TestHttpEndpoints.Count -gt 0) {
    foreach ($endpoint in $TestHttpEndpoints) {
      $vmResults += Test-VMHttpEndpoint -IPAddress $ipAddress -Url $endpoint -VMName $vmName
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
