# SPDX-License-Identifier: MIT
# =========================================================================
# Charts.ps1 - Inline SVG chart generators for HTML reports
# =========================================================================
# All functions return raw <svg> strings. No JavaScript, no CDN dependencies.
# PS 5.1 compatible: no ternary, no null-coalescing, no [Type]::new().
# =========================================================================

<#
.SYNOPSIS
  Generates a semicircular gauge dial SVG (0-100 score).
.PARAMETER Score
  Numeric score from 0 to 100.
.PARAMETER Label
  Text label below the gauge.
.PARAMETER Width
  SVG width in pixels. Default 220.
#>
function New-SvgGaugeChart {
  param(
    [int]$Score = 0,
    [string]$Label = "",
    [int]$Width = 220
  )

  if ($Score -lt 0) { $Score = 0 }
  if ($Score -gt 100) { $Score = 100 }

  if ($Score -ge 70) { $color = "#107C10" }
  elseif ($Score -ge 40) { $color = "#F7630C" }
  else { $color = "#D13438" }

  $cx = 110; $cy = 100; $r = 80
  $x1 = $cx - $r
  $x2 = $cx + $r

  $arcPath = "M $x1,$cy A $r,$r 0 0,1 $x2,$cy"

  $dashFill = $Score
  $dashGap = 100

  $ticks = ""
  $tickLabels = ""
  for ($i = 0; $i -le 4; $i++) {
    $pct = $i * 25
    $angle = [Math]::PI * (1 - $pct / 100)
    $tx1 = $cx + ($r - 6) * [Math]::Cos($angle)
    $ty1 = $cy - ($r - 6) * [Math]::Sin($angle)
    $tx2 = $cx + ($r + 2) * [Math]::Cos($angle)
    $ty2 = $cy - ($r + 2) * [Math]::Sin($angle)
    $tlx = $cx + ($r + 16) * [Math]::Cos($angle)
    $tly = $cy - ($r + 16) * [Math]::Sin($angle)
    $ticks += "      <line x1=`"$([Math]::Round($tx1,1))`" y1=`"$([Math]::Round($ty1,1))`" x2=`"$([Math]::Round($tx2,1))`" y2=`"$([Math]::Round($ty2,1))`" stroke=`"#D2D0CE`" stroke-width=`"1.5`"/>`n"
    $tickLabels += "      <text x=`"$([Math]::Round($tlx,1))`" y=`"$([Math]::Round($tly,1))`" text-anchor=`"middle`" dominant-baseline=`"middle`" fill=`"#605E5C`" font-size=`"10`" font-family=`"'Segoe UI',sans-serif`">$pct</text>`n"
  }

  $needleAngle = [Math]::PI * (1 - $Score / 100)
  $nx = $cx + ($r - 18) * [Math]::Cos($needleAngle)
  $ny = $cy - ($r - 18) * [Math]::Sin($needleAngle)

  $escapedLabel = _EscapeHtml $Label

  return @"
    <svg viewBox="0 0 220 160" width="$Width" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Gauge showing score $Score out of 100">
      <path d="$arcPath" fill="none" stroke="#EDEBE9" stroke-width="14" stroke-linecap="round" pathLength="100" />
      <path d="$arcPath" fill="none" stroke="$color" stroke-width="14" stroke-linecap="round" pathLength="100" stroke-dasharray="$dashFill, $dashGap" />
$ticks
$tickLabels
      <circle cx="$cx" cy="$cy" r="6" fill="$color" />
      <line x1="$cx" y1="$cy" x2="$([Math]::Round($nx,1))" y2="$([Math]::Round($ny,1))" stroke="$color" stroke-width="2.5" stroke-linecap="round" />
      <text x="$cx" y="$($cy + 22)" text-anchor="middle" dominant-baseline="middle" fill="$color" font-size="32" font-weight="700" font-family="'Cascadia Code','Consolas','Courier New',monospace">$Score</text>
      <text x="$cx" y="$($cy + 38)" text-anchor="middle" fill="#605E5C" font-size="11" font-family="'Segoe UI',sans-serif">/ 100</text>
      <text x="$cx" y="154" text-anchor="middle" fill="#323130" font-size="12" font-weight="600" font-family="'Segoe UI',sans-serif">$escapedLabel</text>
    </svg>
"@
}

<#
.SYNOPSIS
  Generates a donut (ring) chart SVG with colored segments.
.PARAMETER Segments
  Array of hashtables: @{ Label="Protected"; Value=150; Color="#00B336" }
.PARAMETER CenterLabel
  Text in the center of the donut.
.PARAMETER CenterSubLabel
  Smaller text below center label.
.PARAMETER Size
  SVG width/height in pixels. Default 200.
#>
function New-SvgDonutChart {
  param(
    [array]$Segments = @(),
    [string]$CenterLabel = "",
    [string]$CenterSubLabel = "",
    [int]$Size = 200
  )

  if ($Segments.Count -eq 0) { return "" }

  $cx = 100; $cy = 100; $r = 70
  $strokeWidth = 24
  $total = 0
  foreach ($seg in $Segments) { $total += $seg.Value }
  if ($total -le 0) { return "" }

  $circles = ""
  $legendItems = ""
  $offset = 25

  foreach ($seg in $Segments) {
    $pct = ($seg.Value / $total) * 100
    $gap = 100 - $pct
    $segColor = $seg.Color
    $circles += "      <circle cx=`"$cx`" cy=`"$cy`" r=`"$r`" fill=`"none`" stroke=`"$segColor`" stroke-width=`"$strokeWidth`" pathLength=`"100`" stroke-dasharray=`"$([Math]::Round($pct,2)), $([Math]::Round($gap,2))`" stroke-dashoffset=`"$([Math]::Round(-$offset,2))`" />`n"
    $offset += $pct

    $pctDisplay = [Math]::Round($pct, 0)
    $escapedSegLabel = _EscapeHtml $seg.Label
    $legendItems += "      <div style=`"display:flex;align-items:center;gap:8px;font-size:12px;color:#605E5C`"><span style=`"width:10px;height:10px;border-radius:2px;background:$segColor;flex-shrink:0`"></span>$escapedSegLabel ($pctDisplay%)</div>`n"
  }

  $escapedCenter = _EscapeHtml $CenterLabel
  $escapedSub = _EscapeHtml $CenterSubLabel

  return @"
    <div style="display:flex;align-items:center;gap:24px;flex-wrap:wrap">
      <svg viewBox="0 0 200 200" width="$Size" height="$Size" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Donut chart">
        <circle cx="$cx" cy="$cy" r="$r" fill="none" stroke="#EDEBE9" stroke-width="$strokeWidth" />
$circles
        <text x="$cx" y="$($cy - 4)" text-anchor="middle" dominant-baseline="middle" fill="#323130" font-size="22" font-weight="700" font-family="'Cascadia Code','Consolas',monospace">$escapedCenter</text>
        <text x="$cx" y="$($cy + 16)" text-anchor="middle" fill="#605E5C" font-size="11" font-family="'Segoe UI',sans-serif">$escapedSub</text>
      </svg>
      <div style="display:flex;flex-direction:column;gap:6px">
$legendItems
      </div>
    </div>
"@
}

<#
.SYNOPSIS
  Generates horizontal bar chart SVG.
.PARAMETER Items
  Array of hashtables: @{ Label="Policy A"; Value=85; MaxValue=100; Color="#0078D4" }
.PARAMETER MaxBars
  Maximum bars. Default 8.
#>
function New-SvgHorizontalBarChart {
  param(
    [array]$Items = @(),
    [int]$MaxBars = 8
  )

  if ($Items.Count -eq 0) { return "" }

  if ($Items.Count -gt $MaxBars) {
    $Items = $Items | Select-Object -First $MaxBars
  }

  $barH = 26
  $gap = 12
  $labelW = 180
  $chartW = 320
  $valueW = 60
  $totalW = $labelW + $chartW + $valueW
  $totalH = $Items.Count * ($barH + $gap) + 10

  $maxVal = 0
  foreach ($item in $Items) {
    $mv = $item.MaxValue
    if ($null -eq $mv -or $mv -le 0) { $mv = $item.Value }
    if ($mv -gt $maxVal) { $maxVal = $mv }
  }
  if ($maxVal -le 0) { return "" }

  $barsSvg = ""
  $idx = 0
  foreach ($item in $Items) {
    $y = $idx * ($barH + $gap) + 5
    $mv = $item.MaxValue
    if ($null -eq $mv -or $mv -le 0) { $mv = $maxVal }
    $pct = [Math]::Min(($item.Value / $mv) * 100, 100)
    $w = [Math]::Round(($pct / 100) * $chartW, 1)
    if ($w -lt 2) { $w = 2 }
    $barColor = $item.Color
    if ([string]::IsNullOrWhiteSpace($barColor)) { $barColor = "#0078D4" }
    $pctDisplay = [Math]::Round($pct, 0)
    $escapedItemLabel = _EscapeHtml $item.Label

    $barsSvg += @"
      <text x="$($labelW - 8)" y="$($y + $barH / 2 + 1)" text-anchor="end" dominant-baseline="middle" fill="#323130" font-size="11" font-family="'Segoe UI',sans-serif" textLength="$($labelW - 16)">$escapedItemLabel</text>
      <rect x="$labelW" y="$y" width="$chartW" height="$barH" rx="4" fill="#EDEBE9" />
      <rect x="$labelW" y="$y" width="$w" height="$barH" rx="4" fill="$barColor" opacity="0.85" />
      <text x="$($labelW + $chartW + 8)" y="$($y + $barH / 2 + 1)" dominant-baseline="middle" fill="#605E5C" font-size="11" font-weight="600" font-family="'Cascadia Code','Consolas',monospace">${pctDisplay}%</text>

"@
    $idx++
  }

  return @"
    <svg viewBox="0 0 $totalW $totalH" width="100%" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Horizontal bar chart" style="max-width:${totalW}px">
$barsSvg
    </svg>
"@
}

<#
.SYNOPSIS
  Generates a tiny progress ring SVG for KPI cards.
.PARAMETER Percent
  Fill percentage (0-100).
.PARAMETER Color
  Stroke color. Default blue.
.PARAMETER Size
  Width/height in pixels. Default 48.
#>
function New-SvgMiniRing {
  param(
    [double]$Percent = 0,
    [string]$Color = "#0078D4",
    [int]$Size = 48
  )

  if ($Percent -lt 0) { $Percent = 0 }
  if ($Percent -gt 100) { $Percent = 100 }

  $cx = 24; $cy = 24; $r = 18
  $dashFill = [Math]::Round($Percent, 1)
  $dashGap = 100

  return @"
<svg viewBox="0 0 48 48" width="$Size" height="$Size" xmlns="http://www.w3.org/2000/svg" style="transform:rotate(-90deg)">
  <circle cx="$cx" cy="$cy" r="$r" fill="none" stroke="#EDEBE9" stroke-width="5" />
  <circle cx="$cx" cy="$cy" r="$r" fill="none" stroke="$Color" stroke-width="5" pathLength="100" stroke-dasharray="$dashFill, $dashGap" stroke-linecap="round" />
</svg>
"@
}

<#
.SYNOPSIS
  Generates a stacked horizontal bar for session success/warning/error visualization.
.PARAMETER SuccessCount
  Number of successful sessions.
.PARAMETER WarningCount
  Number of warning sessions.
.PARAMETER ErrorCount
  Number of error sessions.
.PARAMETER Width
  Chart width in pixels. Default 500.
#>
function New-SvgStackedBar {
  param(
    [double]$SuccessCount = 0,
    [double]$WarningCount = 0,
    [double]$ErrorCount = 0,
    [int]$Width = 500
  )

  $total = $SuccessCount + $WarningCount + $ErrorCount
  if ($total -le 0) { return "" }

  $barH = 32
  $chartW = $Width - 20
  $successW = [Math]::Round(($SuccessCount / $total) * $chartW, 1)
  $warningW = [Math]::Round(($WarningCount / $total) * $chartW, 1)
  $errorW = [Math]::Round(($ErrorCount / $total) * $chartW, 1)

  if ($successW -lt 1 -and $SuccessCount -gt 0) { $successW = 1 }
  if ($warningW -lt 1 -and $WarningCount -gt 0) { $warningW = 1 }
  if ($errorW -lt 1 -and $ErrorCount -gt 0) { $errorW = 1 }

  $x1 = 10
  $x2 = $x1 + $successW
  $x3 = $x2 + $warningW

  $svg = @"
    <svg viewBox="0 0 $Width 80" width="100%" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Session status breakdown" style="max-width:${Width}px">
      <rect x="$x1" y="10" width="$successW" height="$barH" rx="4" fill="#00B336" />
      <rect x="$x2" y="10" width="$warningW" height="$barH" fill="#FF8C00" />
      <rect x="$x3" y="10" width="$errorW" height="$barH" rx="4" fill="#D13438" />
      <text x="$x1" y="65" fill="#00B336" font-size="11" font-weight="600" font-family="'Segoe UI',sans-serif">Success: $([int]$SuccessCount)</text>
      <text x="$([Math]::Round($Width / 2))" y="65" text-anchor="middle" fill="#FF8C00" font-size="11" font-weight="600" font-family="'Segoe UI',sans-serif">Warning: $([int]$WarningCount)</text>
      <text x="$($Width - 10)" y="65" text-anchor="end" fill="#D13438" font-size="11" font-weight="600" font-family="'Segoe UI',sans-serif">Error: $([int]$ErrorCount)</text>
    </svg>
"@

  return $svg
}
