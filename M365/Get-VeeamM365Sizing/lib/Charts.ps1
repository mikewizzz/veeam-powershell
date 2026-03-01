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
  Text label below the gauge (e.g., "Protection Readiness").
.PARAMETER Width
  SVG width in pixels. Default 220.
.EXAMPLE
  New-SvgGaugeChart -Score 72 -Label "Protection Readiness"
#>
function New-SvgGaugeChart {
  param(
    [int]$Score = 0,
    [string]$Label = "",
    [int]$Width = 220
  )

  if ($Score -lt 0) { $Score = 0 }
  if ($Score -gt 100) { $Score = 100 }

  # Color based on score
  if ($Score -ge 70) { $color = "#107C10" }
  elseif ($Score -ge 40) { $color = "#F7630C" }
  else { $color = "#D13438" }

  # Gauge geometry: semicircle from left to right, center (110,100), radius 80
  $cx = 110; $cy = 100; $r = 80
  $x1 = $cx - $r  # left point
  $x2 = $cx + $r  # right point

  # Arc path (counterclockwise in SVG = upward visually)
  $arcPath = "M $x1,$cy A $r,$r 0 0,1 $x2,$cy"

  # Use pathLength=100 so dasharray maps directly to percentage
  $dashFill = $Score
  $dashGap = 100

  # Tick marks at 0, 25, 50, 75, 100
  $ticks = ""
  $tickLabels = ""
  for ($i = 0; $i -le 4; $i++) {
    $pct = $i * 25
    $angle = [Math]::PI * (1 - $pct / 100)  # 180° to 0°
    $tx1 = $cx + ($r - 6) * [Math]::Cos($angle)
    $ty1 = $cy - ($r - 6) * [Math]::Sin($angle)
    $tx2 = $cx + ($r + 2) * [Math]::Cos($angle)
    $ty2 = $cy - ($r + 2) * [Math]::Sin($angle)
    $tlx = $cx + ($r + 16) * [Math]::Cos($angle)
    $tly = $cy - ($r + 16) * [Math]::Sin($angle)
    $ticks += "      <line x1=`"$([Math]::Round($tx1,1))`" y1=`"$([Math]::Round($ty1,1))`" x2=`"$([Math]::Round($tx2,1))`" y2=`"$([Math]::Round($ty2,1))`" stroke=`"#D2D0CE`" stroke-width=`"1.5`"/>`n"
    $tickLabels += "      <text x=`"$([Math]::Round($tlx,1))`" y=`"$([Math]::Round($tly,1))`" text-anchor=`"middle`" dominant-baseline=`"middle`" fill=`"#605E5C`" font-size=`"10`" font-family=`"'Segoe UI',sans-serif`">$pct</text>`n"
  }

  # Needle position
  $needleAngle = [Math]::PI * (1 - $Score / 100)
  $nx = $cx + ($r - 18) * [Math]::Cos($needleAngle)
  $ny = $cy - ($r - 18) * [Math]::Sin($needleAngle)

  $escapedLabel = Escape-Html $Label

  return @"
    <svg viewBox="0 0 220 160" width="$Width" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Gauge showing score $Score out of 100">
      <!-- Background arc -->
      <path d="$arcPath" fill="none" stroke="#EDEBE9" stroke-width="14" stroke-linecap="round" pathLength="100" />
      <!-- Score arc -->
      <path d="$arcPath" fill="none" stroke="$color" stroke-width="14" stroke-linecap="round" pathLength="100" stroke-dasharray="$dashFill, $dashGap" />
      <!-- Ticks -->
$ticks
$tickLabels
      <!-- Needle -->
      <circle cx="$cx" cy="$cy" r="6" fill="$color" />
      <line x1="$cx" y1="$cy" x2="$([Math]::Round($nx,1))" y2="$([Math]::Round($ny,1))" stroke="$color" stroke-width="2.5" stroke-linecap="round" />
      <!-- Score text -->
      <text x="$cx" y="$($cy + 22)" text-anchor="middle" dominant-baseline="middle" fill="$color" font-size="32" font-weight="700" font-family="'Cascadia Code','Consolas','Courier New',monospace">$Score</text>
      <text x="$cx" y="$($cy + 38)" text-anchor="middle" fill="#605E5C" font-size="11" font-family="'Segoe UI',sans-serif">/ 100</text>
      <!-- Label -->
      <text x="$cx" y="154" text-anchor="middle" fill="#323130" font-size="12" font-weight="600" font-family="'Segoe UI',sans-serif">$escapedLabel</text>
    </svg>
"@
}

<#
.SYNOPSIS
  Generates a donut (ring) chart SVG with colored segments and center label.
.PARAMETER Segments
  Array of hashtables: @{ Label="Exchange"; Value=150; Color="#0078D4" }
.PARAMETER CenterLabel
  Text in the center of the donut (e.g., "1.2 TB").
.PARAMETER CenterSubLabel
  Smaller text below center label.
.PARAMETER Size
  SVG width/height in pixels. Default 200.
.EXAMPLE
  New-SvgDonutChart -Segments @(@{Label="Exchange";Value=50;Color="#0078D4"}) -CenterLabel "1.2 TB"
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

  # Build circle segments using stroke-dasharray
  $circles = ""
  $legendItems = ""
  $offset = 25  # Start at 12 o'clock (25% offset on a pathLength=100 circle)

  foreach ($seg in $Segments) {
    $pct = ($seg.Value / $total) * 100
    $gap = 100 - $pct
    $segColor = $seg.Color
    $circles += "      <circle cx=`"$cx`" cy=`"$cy`" r=`"$r`" fill=`"none`" stroke=`"$segColor`" stroke-width=`"$strokeWidth`" pathLength=`"100`" stroke-dasharray=`"$([Math]::Round($pct,2)), $([Math]::Round($gap,2))`" stroke-dashoffset=`"$([Math]::Round(-$offset,2))`" />`n"
    $offset += $pct

    $pctDisplay = [Math]::Round($pct, 0)
    $escapedSegLabel = Escape-Html $seg.Label
    $legendItems += "      <div style=`"display:flex;align-items:center;gap:8px;font-size:12px;color:#605E5C`"><span style=`"width:10px;height:10px;border-radius:2px;background:$segColor;flex-shrink:0`"></span>$escapedSegLabel ($pctDisplay%)</div>`n"
  }

  $escapedCenter = Escape-Html $CenterLabel
  $escapedSub = Escape-Html $CenterSubLabel

  return @"
    <div style="display:flex;align-items:center;gap:24px;flex-wrap:wrap">
      <svg viewBox="0 0 200 200" width="$Size" height="$Size" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Donut chart">
        <!-- Background ring -->
        <circle cx="$cx" cy="$cy" r="$r" fill="none" stroke="#EDEBE9" stroke-width="$strokeWidth" />
        <!-- Segments -->
$circles
        <!-- Center text -->
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
  Generates a 3-bar capacity forecast chart (Current / Projected / MBS Recommended).
.PARAMETER CurrentGB
  Current dataset size in GB.
.PARAMETER ProjectedGB
  Projected dataset after growth.
.PARAMETER RecommendedGB
  Recommended MBS capacity (with buffer).
.EXAMPLE
  New-SvgCapacityForecast -CurrentGB 500 -ProjectedGB 575 -RecommendedGB 820
#>
function New-SvgCapacityForecast {
  param(
    [double]$CurrentGB = 0,
    [double]$ProjectedGB = 0,
    [double]$RecommendedGB = 0
  )

  $maxVal = $RecommendedGB
  if ($ProjectedGB -gt $maxVal) { $maxVal = $ProjectedGB }
  if ($CurrentGB -gt $maxVal) { $maxVal = $CurrentGB }
  if ($maxVal -le 0) { return "" }

  # Scale to fit in 400px wide chart area
  $chartW = 400
  $barH = 32
  $gap = 20
  $labelW = 140
  $totalW = $labelW + $chartW + 80
  $totalH = 3 * $barH + 2 * $gap + 40

  $bars = @(
    @{ Label = "Current Dataset"; Value = $CurrentGB; Color = "#0078D4"; Y = 20 }
    @{ Label = "Projected (1yr)"; Value = $ProjectedGB; Color = "#106EBE"; Y = 20 + $barH + $gap }
    @{ Label = "Recommended MBS"; Value = $RecommendedGB; Color = "#00B336"; Y = 20 + 2 * ($barH + $gap) }
  )

  $barsSvg = ""
  foreach ($bar in $bars) {
    $w = [Math]::Round(($bar.Value / $maxVal) * $chartW, 1)
    if ($w -lt 4) { $w = 4 }
    $valDisplay = Format-Storage $bar.Value
    $escapedBarLabel = Escape-Html $bar.Label
    $barsSvg += @"
      <text x="$($labelW - 8)" y="$($bar.Y + $barH / 2 + 1)" text-anchor="end" dominant-baseline="middle" fill="#323130" font-size="12" font-weight="600" font-family="'Segoe UI',sans-serif">$escapedBarLabel</text>
      <rect x="$labelW" y="$($bar.Y)" width="$w" height="$barH" rx="4" fill="$($bar.Color)" opacity="0.9" />
      <text x="$($labelW + $w + 8)" y="$($bar.Y + $barH / 2 + 1)" dominant-baseline="middle" fill="#323130" font-size="13" font-weight="700" font-family="'Cascadia Code','Consolas',monospace">$valDisplay</text>

"@
  }

  return @"
    <svg viewBox="0 0 $totalW $totalH" width="100%" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Capacity forecast chart" style="max-width:${totalW}px">
$barsSvg
    </svg>
"@
}

<#
.SYNOPSIS
  Generates horizontal bar chart SVG for license utilization or similar data.
.PARAMETER Items
  Array of hashtables: @{ Label="E5"; Value=85; MaxValue=100; Color="#0078D4" }
  If MaxValue is omitted, uses the largest Value as 100%.
.PARAMETER MaxBars
  Maximum number of bars to render. Default 8.
.EXAMPLE
  New-SvgHorizontalBarChart -Items @(@{Label="E5";Value=85;Color="#0078D4"})
#>
function New-SvgHorizontalBarChart {
  param(
    [array]$Items = @(),
    [int]$MaxBars = 8
  )

  if ($Items.Count -eq 0) { return "" }

  # Limit bars
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

  # Find max for scaling
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
    $escapedItemLabel = Escape-Html $item.Label

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
  Generates a severity x category risk matrix heatmap grid.
.PARAMETER Categories
  Array of category names (columns).
.PARAMETER Severities
  Array of severity names (rows), ordered high to low.
.PARAMETER Data
  Hashtable keyed by "Category|Severity" with count values.
.EXAMPLE
  New-SvgRiskMatrix -Categories @("Identity","Data","Access") -Severities @("High","Medium","Low") -Data @{"Identity|High"=2;"Data|Medium"=1}
#>
function New-SvgRiskMatrix {
  param(
    [string[]]$Categories = @(),
    [string[]]$Severities = @(),
    [hashtable]$Data = @{}
  )

  if ($Categories.Count -eq 0 -or $Severities.Count -eq 0) { return "" }

  $cellSize = 56
  $labelW = 90
  $headerH = 40
  $totalW = $labelW + $Categories.Count * $cellSize + 20
  $totalH = $headerH + $Severities.Count * $cellSize + 10

  # Color mapping for severity levels
  $severityColors = @{
    "Critical" = @{ bg = "#D13438"; fg = "#FFFFFF" }
    "High"     = @{ bg = "#D13438"; fg = "#FFFFFF" }
    "Warning"  = @{ bg = "#F7630C"; fg = "#FFFFFF" }
    "Medium"   = @{ bg = "#F7630C"; fg = "#FFFFFF" }
    "Low"      = @{ bg = "#0078D4"; fg = "#FFFFFF" }
    "Info"     = @{ bg = "#107C10"; fg = "#FFFFFF" }
  }

  $gridSvg = ""

  # Column headers
  for ($c = 0; $c -lt $Categories.Count; $c++) {
    $x = $labelW + $c * $cellSize + $cellSize / 2
    $escapedCat = Escape-Html $Categories[$c]
    $gridSvg += "      <text x=`"$x`" y=`"25`" text-anchor=`"middle`" fill=`"#605E5C`" font-size=`"10`" font-weight=`"600`" font-family=`"'Segoe UI',sans-serif`">$escapedCat</text>`n"
  }

  # Rows
  for ($s = 0; $s -lt $Severities.Count; $s++) {
    $y = $headerH + $s * $cellSize
    $sev = $Severities[$s]
    $escapedSev = Escape-Html $sev

    # Row label
    $gridSvg += "      <text x=`"$($labelW - 8)`" y=`"$($y + $cellSize / 2 + 1)`" text-anchor=`"end`" dominant-baseline=`"middle`" fill=`"#323130`" font-size=`"11`" font-weight=`"600`" font-family=`"'Segoe UI',sans-serif`">$escapedSev</text>`n"

    for ($c = 0; $c -lt $Categories.Count; $c++) {
      $x = $labelW + $c * $cellSize
      $key = "$($Categories[$c])|$sev"
      $count = 0
      if ($Data.ContainsKey($key)) { $count = $Data[$key] }

      # Cell color: intensity based on count
      if ($count -gt 0) {
        $colors = $severityColors[$sev]
        if ($null -eq $colors) { $colors = @{ bg = "#D2D0CE"; fg = "#323130" } }
        $opacity = [Math]::Min(0.4 + ($count * 0.2), 1.0)
        $gridSvg += "      <rect x=`"$($x + 2)`" y=`"$($y + 2)`" width=`"$($cellSize - 4)`" height=`"$($cellSize - 4)`" rx=`"4`" fill=`"$($colors.bg)`" opacity=`"$([Math]::Round($opacity,2))`" />`n"
        $gridSvg += "      <text x=`"$($x + $cellSize / 2)`" y=`"$($y + $cellSize / 2 + 1)`" text-anchor=`"middle`" dominant-baseline=`"middle`" fill=`"$($colors.fg)`" font-size=`"16`" font-weight=`"700`" font-family=`"'Cascadia Code','Consolas',monospace`">$count</text>`n"
      }
      else {
        $gridSvg += "      <rect x=`"$($x + 2)`" y=`"$($y + 2)`" width=`"$($cellSize - 4)`" height=`"$($cellSize - 4)`" rx=`"4`" fill=`"#F3F2F1`" />`n"
        $gridSvg += "      <text x=`"$($x + $cellSize / 2)`" y=`"$($y + $cellSize / 2 + 1)`" text-anchor=`"middle`" dominant-baseline=`"middle`" fill=`"#D2D0CE`" font-size=`"14`" font-family=`"'Cascadia Code','Consolas',monospace`">-</text>`n"
      }
    }
  }

  return @"
    <svg viewBox="0 0 $totalW $totalH" width="100%" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Risk matrix" style="max-width:${totalW}px">
$gridSvg
    </svg>
"@
}

<#
.SYNOPSIS
  Generates a tiny progress ring SVG (48px) for use inside KPI cards.
.PARAMETER Percent
  Fill percentage (0-100).
.PARAMETER Color
  Stroke color for the filled arc. Default blue.
.PARAMETER Size
  Width/height in pixels. Default 48.
.EXAMPLE
  New-SvgMiniRing -Percent 73 -Color "#0078D4"
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
