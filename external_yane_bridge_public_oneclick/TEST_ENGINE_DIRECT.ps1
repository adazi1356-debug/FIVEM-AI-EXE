$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$engineExe = Join-Path $root 'engine\yaneuraou.exe'
$workDir = Split-Path -Parent $engineExe
$outPath = Join-Path $root 'engine_direct_stdout.txt'
$errPath = Join-Path $root 'engine_direct_stderr.txt'
$resPath = Join-Path $root 'engine_direct_result.txt'

Remove-Item -Force $outPath,$errPath,$resPath -ErrorAction SilentlyContinue

if (-not (Test-Path -LiteralPath $engineExe)) {
    "engine exe not found: $engineExe" | Set-Content -LiteralPath $resPath -Encoding UTF8
    throw "engine exe not found: $engineExe"
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $engineExe
$psi.WorkingDirectory = $workDir
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
$psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi
[void]$proc.Start()
$proc.StandardInput.WriteLine('usi')
$proc.StandardInput.Flush()

$stdoutLines = New-Object System.Collections.Generic.List[string]
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$usiok = $false

while ($sw.ElapsedMilliseconds -lt 10000) {
    if ($proc.HasExited) { break }
    $task = $proc.StandardOutput.ReadLineAsync()
    if (-not $task.Wait(500)) { continue }
    $line = $task.Result
    if ($null -eq $line) { break }
    [void]$stdoutLines.Add($line)
    if ($line -eq 'usiok') {
        $usiok = $true
        break
    }
}

if (-not $proc.HasExited) {
    try { $proc.Kill() } catch {}
}
$proc.WaitForExit()

$stderrText = ''
try { $stderrText = $proc.StandardError.ReadToEnd() } catch {}

$stdoutLines | Set-Content -LiteralPath $outPath -Encoding UTF8
$stderrText | Set-Content -LiteralPath $errPath -Encoding UTF8
@(
    'engineExe=' + $engineExe,
    'exitCode=' + $proc.ExitCode,
    'usiok=' + $usiok,
    'stdoutLineCount=' + $stdoutLines.Count,
    'stdoutPath=' + $outPath,
    'stderrPath=' + $errPath
) | Set-Content -LiteralPath $resPath -Encoding UTF8

Get-Content -LiteralPath $resPath -Encoding UTF8
