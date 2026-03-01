# =============================
# Post-Restore Validation
# =============================

<#
.SYNOPSIS
  Discovers the EC2 instance created by the restore and validates it is running.
.PARAMETER InstanceName
  The Name tag of the restored instance.
.OUTPUTS
  EC2 instance object.
#>
function Test-EC2InstanceHealth {
  param([Parameter(Mandatory)][string]$InstanceName)

  Write-Log "Validating restored EC2 instance: '$InstanceName'"

  # Find the instance by Name tag
  $instance = Invoke-WithRetry -OperationName "Find EC2 Instance" -ScriptBlock {
    $result = Get-EC2Instance -Filter @(
      @{ Name="tag:Name"; Values=$InstanceName }
      @{ Name="instance-state-name"; Values=@("pending","running") }
    ) -Region $AWSRegion

    $result.Instances | Select-Object -First 1
  }

  if (-not $instance) {
    throw "Restored EC2 instance '$InstanceName' not found in $AWSRegion."
  }

  $script:RestoredInstanceId = $instance.InstanceId
  Write-Log "Found instance: $($instance.InstanceId) (State: $($instance.State.Name))"

  if ($SkipValidation) {
    Write-Log "Skipping post-restore validation (SkipValidation flag)" -Level WARNING
    return $instance
  }

  # Phase 1: Wait for instance to reach running state (independent timeout)
  $runningTimeoutMin = [Math]::Max(5, [int]($ValidationTimeoutMinutes / 2))
  $runningDeadline = (Get-Date).AddMinutes($runningTimeoutMin)

  Write-Log "Waiting for instance to reach 'running' state (timeout: $runningTimeoutMin min)..."
  $reachedRunning = $false
  while ((Get-Date) -lt $runningDeadline) {
    $state = (Get-EC2Instance -InstanceId $instance.InstanceId -Region $AWSRegion).Instances[0].State.Name
    if ($state -eq "running") {
      Write-Log "Instance is running" -Level SUCCESS
      $reachedRunning = $true
      break
    }
    if ($state -eq "terminated" -or $state -eq "shutting-down") {
      throw "Instance $($instance.InstanceId) entered '$state' state unexpectedly."
    }
    Start-Sleep -Seconds 10
  }

  if (-not $reachedRunning) {
    Write-Log "Instance did not reach 'running' state within $runningTimeoutMin minutes" -Level WARNING
  }

  # Phase 2: Wait for status checks (fresh timeout after running state confirmed)
  $statusCheckTimeoutMin = [Math]::Max(5, $ValidationTimeoutMinutes - $runningTimeoutMin)
  $statusCheckDeadline = (Get-Date).AddMinutes($statusCheckTimeoutMin)

  Write-Log "Waiting for EC2 status checks (timeout: $statusCheckTimeoutMin min)..."
  $checksPass = $false
  while ((Get-Date) -lt $statusCheckDeadline) {
    $status = Get-EC2InstanceStatus -InstanceId $instance.InstanceId -Region $AWSRegion
    if ($status) {
      $instanceStatus = $status.InstanceStatus.Status
      $systemStatus = $status.SystemStatus.Status
      Write-Log "  Instance status: $instanceStatus | System status: $systemStatus"

      if ($instanceStatus -eq "ok" -and $systemStatus -eq "ok") {
        $checksPass = $true
        break
      }
    }
    Start-Sleep -Seconds 15
  }

  if (-not $checksPass) {
    Write-Log "EC2 status checks did not pass within $statusCheckTimeoutMin minutes" -Level WARNING
  }
  else {
    Write-Log "All EC2 status checks passed" -Level SUCCESS
  }

  # Application-level health checks
  if ($HealthCheckPorts -or $HealthCheckUrls -or $SSMHealthCheckCommand) {
    Write-Log "Running application-level health checks..."
    $healthResults = Invoke-EC2HealthChecks -Instance $instance
    $script:HealthCheckResults = $healthResults

    $failedChecks = @($healthResults | Where-Object { -not $_.Passed })
    if ($failedChecks.Count -gt 0) {
      Write-Log "$($failedChecks.Count) health check(s) failed" -Level WARNING
    }
    else {
      Write-Log "All application health checks passed ($($healthResults.Count) checks)" -Level SUCCESS
    }
  }

  # Refresh instance data
  $instance = (Get-EC2Instance -InstanceId $instance.InstanceId -Region $AWSRegion).Instances[0]
  return $instance
}

# =============================
# Application Health Checks
# =============================

<#
.SYNOPSIS
  Tests TCP port connectivity on the restored EC2 instance.
.PARAMETER IPAddress
  The IP address to test against.
.PARAMETER Port
  The TCP port to check.
.PARAMETER TimeoutMs
  Connection timeout in milliseconds. Default: 10000.
.OUTPUTS
  PSCustomObject with TestName, Passed, Details, Duration.
#>
function Test-EC2Port {
  param(
    [Parameter(Mandatory)][string]$IPAddress,
    [Parameter(Mandatory)][int]$Port,
    [int]$TimeoutMs = 10000
  )

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $passed = $false
  $details = ""

  try {
    $tcpClient = New-Object System.Net.Sockets.TcpClient
    $connectTask = $tcpClient.ConnectAsync($IPAddress, $Port)
    if ($connectTask.Wait($TimeoutMs)) {
      if ($tcpClient.Connected) {
        $passed = $true
        $details = "TCP port $Port is open"
      }
      else {
        $details = "TCP port $Port connection failed"
      }
    }
    else {
      $details = "TCP port $Port connection timed out after ${TimeoutMs}ms"
    }
  }
  catch {
    $details = "TCP port $Port error: $($_.Exception.Message)"
  }
  finally {
    if ($tcpClient) { $tcpClient.Dispose() }
  }

  $sw.Stop()
  $level = if ($passed) { "SUCCESS" } else { "WARNING" }
  Write-Log "  Port check $IPAddress`:$Port - $(if($passed){'PASS'}else{'FAIL'}): $details" -Level $level

  return [PSCustomObject]@{
    TestName = "TCP:$Port"
    Passed   = $passed
    Details  = $details
    Duration = $sw.Elapsed.TotalSeconds
  }
}

<#
.SYNOPSIS
  Tests HTTP/HTTPS endpoint accessibility on the restored EC2 instance.
.PARAMETER IPAddress
  The instance IP address (replaces localhost in URL).
.PARAMETER Url
  The HTTP/HTTPS URL to test.
.OUTPUTS
  PSCustomObject with TestName, Passed, Details, Duration.
#>
function Test-EC2HttpEndpoint {
  param(
    [Parameter(Mandatory)][string]$IPAddress,
    [Parameter(Mandatory)][string]$Url
  )

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $passed = $false
  $details = ""

  # Replace localhost with actual IP (word boundary match to avoid partial replacements)
  $testUrl = $Url -replace '\blocalhost\b', $IPAddress -replace '127\.0\.0\.1', $IPAddress

  try {
    $response = Invoke-WebRequest -Uri $testUrl -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
    $statusCode = $response.StatusCode
    if ($statusCode -ge 200 -and $statusCode -lt 400) {
      $passed = $true
      $details = "HTTP $statusCode OK"
    }
    else {
      $details = "HTTP $statusCode unexpected status"
    }
  }
  catch {
    $details = "HTTP error: $($_.Exception.Message)"
  }

  $sw.Stop()
  $level = if ($passed) { "SUCCESS" } else { "WARNING" }
  Write-Log "  HTTP check $testUrl - $(if($passed){'PASS'}else{'FAIL'}): $details" -Level $level

  return [PSCustomObject]@{
    TestName = "HTTP:$Url"
    Passed   = $passed
    Details  = $details
    Duration = $sw.Elapsed.TotalSeconds
  }
}

<#
.SYNOPSIS
  Executes an SSM RunCommand on the restored instance for in-guest health check.
.PARAMETER InstanceId
  EC2 instance ID to run the command on.
.PARAMETER Command
  The shell command to execute.
.PARAMETER TimeoutSeconds
  Maximum wait time for command completion. Default: 120.
.OUTPUTS
  PSCustomObject with TestName, Passed, Details, Duration.
#>
function Test-EC2SSMCommand {
  param(
    [Parameter(Mandatory)][string]$InstanceId,
    [Parameter(Mandatory)][string]$Command,
    [int]$TimeoutSeconds = 120
  )

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $passed = $false
  $details = ""

  try {
    $ssmResult = Send-SSMCommand -InstanceId $InstanceId `
      -DocumentName "AWS-RunShellScript" `
      -Parameter @{ commands = @($Command) } `
      -TimeoutSecond $TimeoutSeconds `
      -Region $AWSRegion

    $commandId = $ssmResult.CommandId
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
      Start-Sleep -Seconds 5
      $invocation = Get-SSMCommandInvocation -CommandId $commandId `
        -InstanceId $InstanceId -Details:$true -Region $AWSRegion

      if ($invocation.Status -eq "Success") {
        $passed = $true
        $output = $invocation.CommandPlugins[0].Output
        $details = "SSM command succeeded: $($output.Substring(0, [Math]::Min(200, $output.Length)))"
        break
      }
      elseif ($invocation.Status -in @("Failed", "Cancelled", "TimedOut")) {
        $details = "SSM command $($invocation.Status): $($invocation.CommandPlugins[0].Output)"
        break
      }
    }

    if (-not $passed -and -not $details) {
      $details = "SSM command timed out after ${TimeoutSeconds}s"
    }
  }
  catch {
    $details = "SSM error: $($_.Exception.Message)"
  }

  $sw.Stop()
  $level = if ($passed) { "SUCCESS" } else { "WARNING" }
  Write-Log "  SSM check - $(if($passed){'PASS'}else{'FAIL'}): $details" -Level $level

  return [PSCustomObject]@{
    TestName = "SSM:RunCommand"
    Passed   = $passed
    Details  = $details
    Duration = $sw.Elapsed.TotalSeconds
  }
}

<#
.SYNOPSIS
  Orchestrates all configured application-level health checks.
.PARAMETER Instance
  The EC2 instance object.
.OUTPUTS
  Array of PSCustomObject health check results.
#>
function Invoke-EC2HealthChecks {
  param([Parameter(Mandatory)][object]$Instance)

  $results = New-Object System.Collections.Generic.List[object]
  $ip = $Instance.PrivateIpAddress

  # TCP port checks
  if ($HealthCheckPorts) {
    foreach ($port in $HealthCheckPorts) {
      $results.Add((Test-EC2Port -IPAddress $ip -Port $port))
    }
  }

  # HTTP endpoint checks
  if ($HealthCheckUrls) {
    foreach ($url in $HealthCheckUrls) {
      $results.Add((Test-EC2HttpEndpoint -IPAddress $ip -Url $url))
    }
  }

  # SSM in-guest check
  if ($SSMHealthCheckCommand) {
    $results.Add((Test-EC2SSMCommand -InstanceId $Instance.InstanceId -Command $SSMHealthCheckCommand))
  }

  Write-AuditEvent -EventType "VALIDATE" -Action "Application health checks" -Resource $Instance.InstanceId -Details @{
    total  = $results.Count
    passed = @($results | Where-Object { $_.Passed }).Count
    failed = @($results | Where-Object { -not $_.Passed }).Count
  }

  return $results.ToArray()
}
