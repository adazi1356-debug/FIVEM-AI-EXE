$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe = Join-Path $root 'engine\yaneuraou.exe'
$eval = Join-Path $root 'engine\eval'
$out = Join-Path $root 'engine_evaldir_probe.txt'
$plans = @(
    @{ name = 'default-no-evaldir'; eval = $null },
    @{ name = 'relative-eval'; eval = 'eval' },
    @{ name = 'absolute-evaldir'; eval = $eval }
)
'' | Set-Content -LiteralPath $out -Encoding UTF8
foreach ($plan in $plans) {
    "=== mode=$($plan.name) ===" | Add-Content -LiteralPath $out -Encoding UTF8
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.WorkingDirectory = Split-Path -Parent $exe
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    try {
        $proc.StandardInput.WriteLine('usi')
        $proc.StandardInput.Flush()
        while ($true) {
            $line = $proc.StandardOutput.ReadLine()
            if ($null -eq $line) { break }
            $line | Add-Content -LiteralPath $out -Encoding UTF8
            if ($line -eq 'usiok') { break }
        }
        if ($plan.eval) {
            $proc.StandardInput.WriteLine(('setoption name EvalDir value {0}' -f $plan.eval))
            $proc.StandardInput.Flush()
        }
        $proc.StandardInput.WriteLine('isready')
        $proc.StandardInput.Flush()
        while ($true) {
            $line = $proc.StandardOutput.ReadLine()
            if ($null -eq $line) { break }
            $line | Add-Content -LiteralPath $out -Encoding UTF8
            if ($line -eq 'readyok') { break }
        }
    } finally {
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch {}
        try { if (-not [string]::IsNullOrWhiteSpace($proc.StandardError.ReadToEnd())) { $proc.StandardError.ReadToEnd() | Add-Content -LiteralPath $out -Encoding UTF8 } } catch {}
    }
    '' | Add-Content -LiteralPath $out -Encoding UTF8
}
Write-Host ('written: ' + $out)
