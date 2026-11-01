param(
    [Parameter(Mandatory = $true)][string]$Out,
    [string]$Text = ''
)
# Generate the image probe fixture. Size is the load-bearing variable, not the content:
# a small PNG survives every upstream, a full-page-screenshot-sized one does not.
# See PROGRESS 5f and 5i.
Add-Type -AssemblyName System.Drawing

$W = 1093
$H = 6000
# A marker that cannot be guessed from the filename and cannot be recovered from base64
# that was tokenised as text: six random characters drawn as pixels.
# (The "tokenised as text" failure did not reproduce; PROGRESS 5i. The random marker is still
# worth it — body text would be readable from a degraded path.)
if (-not $Text) {
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $Text = -join (1..6 | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
}

$bmp = New-Object System.Drawing.Bitmap $W, $H
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::White)
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$font = New-Object System.Drawing.Font 'Consolas', 22
$brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(20, 20, 20))
# Body text is deliberately uninformative: only the marker line carries the answer.
$body = 'lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor'
for ($y = 20; $y -lt $H - 60; $y += 28) {
    $g.DrawString($body, $font, $brush, 20, $y)
}
$big = New-Object System.Drawing.Font 'Consolas', 90, ([System.Drawing.FontStyle]::Bold)
$g.DrawString($Text, $big, [System.Drawing.Brushes]::Black, 20, ($H - 140))
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose()
$bmp.Dispose()
$font.Dispose()
$big.Dispose()
$brush.Dispose()

Write-Output $Text
Write-Output (Get-Item $Out).Length
