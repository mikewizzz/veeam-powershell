# Functional Test Plan — Start-VeeamAHVSureBackup

Local reference only. Do not commit.

## Lab Requirements

| Component | Minimum | Notes |
|---|---|---|
| VBR Server | v13.0.1+ | AHV Plugin v9 installed, REST API on port 9419 |
| Prism Central | pc.2024.1+ | Admin credentials, at least 1 cluster registered |
| AHV Cluster | AOS 6.x+ | At least 1 VM backed up by VBR |
| Isolated Network | 1 subnet | No gateway to production, DHCP optional |
| Test VMs | 1-3 small VMs | Backed up with at least 1 restore point, NGT installed |

**Cheapest option:** Request a Nutanix HPOC (Hosted POC) cluster — comes with Prism Central and AHV pre-configured. Install VBR on a Windows VM in the cluster.

## Credentials Setup

```powershell
# Run once — saves encrypted credentials to disk (user+machine specific)
Get-Credential | Export-Clixml -Path "$HOME/.vbr-cred.xml"    # VBR admin
Get-Credential | Export-Clixml -Path "$HOME/.prism-cred.xml"  # Prism admin

# Load in test sessions
$vbrCred  = Import-Clixml "$HOME/.vbr-cred.xml"
$pcCred   = Import-Clixml "$HOME/.prism-cred.xml"
$vbr      = "vbr01.lab.local"
$pc       = "pc01.lab.local"
```

## Test Stages

Run these in order. Each stage validates a layer before moving to the next.

---

### Stage 1: Auth + Connectivity Only (DryRun)

**Goal:** Validate VBR OAuth2 and Prism Central auth work. No VMs recovered.

```powershell
.\Start-VeeamAHVSureBackup.ps1 -VBRServer $vbr -VBRCredential $vbrCred `
    -PrismCentral $pc -PrismCredential $pcCred `
    -DryRun -SkipCertificateCheck
```

**Expected:** Script completes with a dry-run summary showing discovered jobs, restore points, and resolved isolated network. No VMs restored.

**Common failures:**
- `VBAHV Plugin authentication failed` — wrong VBR creds, port 9419 blocked, plugin not installed
- `Prism Central connection failed` — wrong PC hostname, port 9440 blocked, bad creds
- `No Nutanix AHV backup jobs found` — no AHV backup jobs configured in VBR
- `Isolated network not found` — create a subnet with "isolated" in the name

**Fix loop:** Paste the full error output into Claude Code. I'll diagnose and fix.

---

### Stage 2: Single VM Full Restore + Cleanup

**Goal:** Validate the complete lifecycle: restore -> boot -> test -> cleanup.

Pick your smallest VM (least disk, fastest boot).

```powershell
.\Start-VeeamAHVSureBackup.ps1 -VBRServer $vbr -VBRCredential $vbrCred `
    -PrismCentral $pc -PrismCredential $pcCred `
    -VMNames @("your-small-vm") `
    -TestBootTimeoutSec 600 `
    -SkipCertificateCheck
```

**Expected:** VM restores with `SureBackup_` prefix, powers on, heartbeat test passes (if NGT installed), ping test runs, cleanup deletes the VM.

**What to watch for:**
- Does the restore point match correctly? (check log for "Matched plugin restore point")
- Does NIC remap work? (check log for "NIC xx:xx:xx -> isolated-network")
- Does the VM appear in Prism Central after restore?
- Does the VM get an IP? (needs DHCP on isolated VLAN, or static in NGT)
- Does cleanup actually delete the VM from Prism?

**If VM doesn't get an IP:** The heartbeat test may still pass (NGT), but ping/port tests will skip. Check DHCP on the isolated VLAN.

---

### Stage 3: Port + Application Tests

**Goal:** Validate the test phases beyond heartbeat/ping.

Pick a VM that has known open ports (e.g., a Linux VM with SSH, or Windows with RDP).

```powershell
.\Start-VeeamAHVSureBackup.ps1 -VBRServer $vbr -VBRCredential $vbrCred `
    -PrismCentral $pc -PrismCredential $pcCred `
    -VMNames @("your-linux-vm") `
    -TestPorts @(22) `
    -TestBootTimeoutSec 600 `
    -SkipCertificateCheck
```

**Expected:** Heartbeat PASS, Ping PASS, TCP Port 22 PASS.

---

### Stage 4: Multi-VM + Application Groups

**Goal:** Validate concurrent recovery and boot ordering.

```powershell
$groups = @{
    1 = @("your-infra-vm")
    2 = @("your-app-vm-1", "your-app-vm-2")
}

.\Start-VeeamAHVSureBackup.ps1 -VBRServer $vbr -VBRCredential $vbrCred `
    -PrismCentral $pc -PrismCredential $pcCred `
    -ApplicationGroups $groups `
    -MaxConcurrentVMs 2 `
    -SkipCertificateCheck
```

**Expected:** Group 1 VM restores and passes tests first, then Group 2 VMs restore concurrently.

---

### Stage 5: Interactive Mode

**Goal:** Validate the interactive selection UI.

```powershell
.\Start-VeeamAHVSureBackup.ps1 -VBRServer $vbr -VBRCredential $vbrCred `
    -PrismCentral $pc -PrismCredential $pcCred `
    -Interactive -SkipCertificateCheck
```

**Expected:** Shows numbered list of all discovered VMs with restore point ages, prompts for selection.

---

### Stage 6: Preflight Checks

**Goal:** Validate preflight catches real issues.

```powershell
# Normal run (preflight enabled by default)
.\Start-VeeamAHVSureBackup.ps1 -VBRServer $vbr -VBRCredential $vbrCred `
    -PrismCentral $pc -PrismCredential $pcCred `
    -DryRun -SkipCertificateCheck

# With strict recency (will warn if restore points > 1 day old)
.\Start-VeeamAHVSureBackup.ps1 -VBRServer $vbr -VBRCredential $vbrCred `
    -PrismCentral $pc -PrismCredential $pcCred `
    -DryRun -PreflightMaxAgeDays 1 -SkipCertificateCheck
```

---

### Stage 7: HTML Report Validation

After any successful run (Stage 2+), open the HTML report in a browser:

```powershell
# Find the latest output
Get-ChildItem ./VeeamAHVSureBackup_* -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1

# Open the report
Invoke-Item ./VeeamAHVSureBackup_*/SureBackup_Report.html
```

**Check:** Report renders correctly, all test results visible, no XSS issues with VM names.

---

## Prism API Version Testing

By default the script uses Prism v4 API. If your Prism Central is older (pre-pc.2024.3), test v3:

```powershell
.\Start-VeeamAHVSureBackup.ps1 -VBRServer $vbr -VBRCredential $vbrCred `
    -PrismCentral $pc -PrismCredential $pcCred `
    -PrismApiVersion "v3" `
    -DryRun -SkipCertificateCheck
```

## Claude Code Workflow

The testing flywheel when working with Claude Code:

1. Run a test stage from above
2. If it fails, copy the full terminal output
3. Paste it into Claude Code: "This failed when running Stage X: [paste output]"
4. I'll read the relevant source, diagnose, and fix
5. Re-run the same stage
6. Repeat until it passes, then move to next stage

For each fix, I'll also update the unit tests to cover the scenario so it doesn't regress.
