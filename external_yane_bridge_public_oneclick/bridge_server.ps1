$ErrorActionPreference = 'Stop'

$script:BridgeRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ConfigPath = Join-Path $script:BridgeRoot 'bridge_config.json'
$script:LogPath = Join-Path $script:BridgeRoot 'bridge_server.log'
$script:EngineProc = $null
$script:EngineReady = $false
$script:EngineError = $null
$script:ListenPrefix = 'http://127.0.0.1:18777/'
$script:EngineExePath = Join-Path $script:BridgeRoot 'engine\yaneuraou.exe'
$script:EvalDir = Join-Path $script:BridgeRoot 'engine\eval'
$script:Threads = 1
$script:HashMb = 64
$script:MultiPv = 1
$script:FvScale = 20
$script:SyncRoot = New-Object object
$script:BackendName = 'local_external_bridge'
$script:VariantName = 'native_exe'
$script:RecentEngineStderr = New-Object System.Collections.Generic.List[string]
$script:LastEngineExitCode = $null
$script:LastEngineStartAt = $null
$script:LastEngineStdoutLine = $null
$script:LastEngineExitSummaryLogged = $null
$script:LastStartupMode = $null
$script:LastStartupAttempts = @()
$script:LastNnHeader = $null
$script:StartupFailureCacheAt = $null
$script:StartupFailureCacheMessage = $null
$script:StartupFailureCooldownMs = 4000
$script:ThinkStopGraceMs = 8000
$script:DefaultThinkTimeoutPaddingMs = 6000
$script:DisplayName = 'ローカルやねうら王'
$script:CustomDifficulty = @{
    moveTimeMs = $null
    depth = $null
    timeoutPaddingMs = $null
    hashMb = $null
    threads = $null
    multiPv = $null
    fvScale = $null
}

function Write-Log {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    Write-Host $line
}

function Add-RecentStderr {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return }
    [void]$script:RecentEngineStderr.Add($Line)
    while ($script:RecentEngineStderr.Count -gt 20) {
        $script:RecentEngineStderr.RemoveAt(0)
    }
}

function Get-RecentStderrSummary {
    if (-not $script:RecentEngineStderr -or $script:RecentEngineStderr.Count -eq 0) {
        return ''
    }
    return (($script:RecentEngineStderr | Select-Object -Last 5) -join ' || ')
}

function Get-EngineExitSummary {
    $parts = New-Object System.Collections.Generic.List[string]
    if ($null -ne $script:LastEngineExitCode) {
        [void]$parts.Add(('exit code {0}' -f $script:LastEngineExitCode))
    }
    $stderrSummary = Get-RecentStderrSummary
    if (-not [string]::IsNullOrWhiteSpace($stderrSummary)) {
        [void]$parts.Add(('stderr: {0}' -f $stderrSummary))
    }
    if (-not [string]::IsNullOrWhiteSpace($script:LastEngineStdoutLine)) {
        [void]$parts.Add(('last stdout: {0}' -f $script:LastEngineStdoutLine))
    }
    if ($parts.Count -eq 0) {
        return ''
    }
    return (' (' + ($parts -join '; ') + ')')
}

function Capture-ExitedEngineDetails {
    param(
        [System.Diagnostics.Process]$Process = $script:EngineProc,
        [string]$Reason = 'unknown'
    )

    if (-not $Process) { return }

    $hasExited = $false
    try { $hasExited = $Process.HasExited } catch {}
    if (-not $hasExited) { return }

    try { $script:LastEngineExitCode = $Process.ExitCode } catch {}

    try {
        $stderrText = $Process.StandardError.ReadToEnd()
        if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
            foreach ($line in ($stderrText -split "`r?`n")) {
                if (-not [string]::IsNullOrWhiteSpace($line)) {
                    Add-RecentStderr -Line $line
                }
            }
        }
    } catch {
        Add-RecentStderr -Line ('failed to read remaining stderr: ' + $_.Exception.Message)
    }

    $summary = 'reason=' + $Reason + (Get-EngineExitSummary)
    if ($summary -ne $script:LastEngineExitSummaryLogged) {
        $script:LastEngineExitSummaryLogged = $summary
        Write-Log ('engine exited ' + $summary)
    }
}

function Stop-EngineProcess {
    param([string]$Reason = 'stop')
    if (-not $script:EngineProc) { return }
    try {
        if (-not $script:EngineProc.HasExited) {
            try { $script:EngineProc.Kill() } catch {}
            try { $script:EngineProc.WaitForExit(1500) | Out-Null } catch {}
        }
        Capture-ExitedEngineDetails -Process $script:EngineProc -Reason $Reason
    } finally {
        $script:EngineProc = $null
        $script:EngineReady = $false
    }
}

function Load-Config {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) { return }
    $raw = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    $cfg = $raw | ConvertFrom-Json

    if ($cfg.listenPrefix) { $script:ListenPrefix = [string]$cfg.listenPrefix }
    elseif ($cfg.bridgeUrl) {
        $url = [string]$cfg.bridgeUrl
        if ($url.EndsWith('/')) { $script:ListenPrefix = $url } else { $script:ListenPrefix = $url + '/' }
    }

    if ($cfg.engineExePath) {
        $p = [string]$cfg.engineExePath
        if ([System.IO.Path]::IsPathRooted($p)) { $script:EngineExePath = $p }
        else { $script:EngineExePath = Join-Path $script:BridgeRoot $p }
    }

    if ($cfg.evalDir) {
        $p = [string]$cfg.evalDir
        if ([System.IO.Path]::IsPathRooted($p)) { $script:EvalDir = $p }
        else { $script:EvalDir = Join-Path $script:BridgeRoot $p }
    }

    if ($cfg.threads) {
        try { $script:Threads = [int]$cfg.threads } catch {}
        if ($script:Threads -lt 1) { $script:Threads = 1 }
    }
    if ($cfg.hashMb) {
        try { $script:HashMb = [int]$cfg.hashMb } catch {}
        if ($script:HashMb -lt 1) { $script:HashMb = 1 }
    }
    if ($cfg.multiPv) {
        try { $script:MultiPv = [int]$cfg.multiPv } catch {}
        if ($script:MultiPv -lt 1) { $script:MultiPv = 1 }
    }
    if ($null -ne $cfg.fvScale) {
        try { $script:FvScale = [int]$cfg.fvScale } catch {}
        if ($script:FvScale -lt 1) { $script:FvScale = 1 }
    }
    if ($cfg.displayName) {
        $script:DisplayName = [string]$cfg.displayName
    }
    if ($null -ne $cfg.timeoutPaddingMs) {
        try { $script:DefaultThinkTimeoutPaddingMs = [int]$cfg.timeoutPaddingMs } catch {}
        if ($script:DefaultThinkTimeoutPaddingMs -lt 1000) { $script:DefaultThinkTimeoutPaddingMs = 1000 }
    }
    if ($null -ne $cfg.defaultThinkTimeoutPaddingMs) {
        try { $script:DefaultThinkTimeoutPaddingMs = [int]$cfg.defaultThinkTimeoutPaddingMs } catch {}
        if ($script:DefaultThinkTimeoutPaddingMs -lt 1000) { $script:DefaultThinkTimeoutPaddingMs = 1000 }
    }
    if ($cfg.customDifficulty) {
        $custom = $cfg.customDifficulty
        $script:CustomDifficulty = @{
            moveTimeMs = $null
            depth = $null
            timeoutPaddingMs = $null
            hashMb = $null
            threads = $null
            multiPv = $null
            fvScale = $null
        }
        if ($null -ne $custom.moveTimeMs) {
            try { $script:CustomDifficulty.moveTimeMs = [int]$custom.moveTimeMs } catch {}
            if ($script:CustomDifficulty.moveTimeMs -lt 1) { $script:CustomDifficulty.moveTimeMs = 1 }
        }
        if ($null -ne $custom.depth) {
            try { $script:CustomDifficulty.depth = [int]$custom.depth } catch {}
            if ($script:CustomDifficulty.depth -lt 1) { $script:CustomDifficulty.depth = $null }
        }
        if ($null -ne $custom.timeoutPaddingMs) {
            try { $script:CustomDifficulty.timeoutPaddingMs = [int]$custom.timeoutPaddingMs } catch {}
            if ($script:CustomDifficulty.timeoutPaddingMs -lt 1000) { $script:CustomDifficulty.timeoutPaddingMs = 1000 }
        }
        if ($null -ne $custom.hashMb) {
            try { $script:CustomDifficulty.hashMb = [int]$custom.hashMb } catch {}
            if ($script:CustomDifficulty.hashMb -lt 1) { $script:CustomDifficulty.hashMb = 1 }
        }
        if ($null -ne $custom.threads) {
            try { $script:CustomDifficulty.threads = [int]$custom.threads } catch {}
            if ($script:CustomDifficulty.threads -lt 1) { $script:CustomDifficulty.threads = 1 }
        }
        if ($null -ne $custom.multiPv) {
            try { $script:CustomDifficulty.multiPv = [int]$custom.multiPv } catch {}
            if ($script:CustomDifficulty.multiPv -lt 1) { $script:CustomDifficulty.multiPv = 1 }
        }
        if ($null -ne $custom.fvScale) {
            try { $script:CustomDifficulty.fvScale = [int]$custom.fvScale } catch {}
            if ($script:CustomDifficulty.fvScale -lt 1) { $script:CustomDifficulty.fvScale = 1 }
        }
    }
}

function Get-NnHeaderSummary {
    param([string]$EvalDirPath)
    if ([string]::IsNullOrWhiteSpace($EvalDirPath)) { return $null }
    $nnPath = Join-Path $EvalDirPath 'nn.bin'
    if (-not (Test-Path -LiteralPath $nnPath)) { return $null }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($nnPath)
        if ($bytes.Length -lt 32) { return ('size=' + $bytes.Length) }
        $ascii = [System.Text.Encoding]::ASCII.GetString($bytes, 12, [Math]::Min(180, $bytes.Length - 12))
        $nul = $ascii.IndexOf([char]0)
        if ($nul -ge 0) { $ascii = $ascii.Substring(0, $nul) }
        $ascii = $ascii.Trim()
        if ([string]::IsNullOrWhiteSpace($ascii)) { return ('size=' + $bytes.Length) }
        return ('size=' + $bytes.Length + '; header=' + $ascii)
    } catch {
        return ('header-read-failed: ' + $_.Exception.Message)
    }
}

function Get-StartupPlans {
    $engineDir = Split-Path -Parent $script:EngineExePath
    $plans = New-Object System.Collections.Generic.List[hashtable]
    [void]$plans.Add(@{ Name = 'default-no-evaldir'; SetEvalDir = $false; EvalValue = $null; DisplayEval = '<default>' })

    if (Test-Path -LiteralPath $script:EvalDir) {
        try {
            $resolvedEval = [System.IO.Path]::GetFullPath($script:EvalDir)
            $defaultEval = [System.IO.Path]::GetFullPath((Join-Path $engineDir 'eval'))
            if ($resolvedEval -ieq $defaultEval) {
                [void]$plans.Add(@{ Name = 'relative-eval'; SetEvalDir = $true; EvalValue = 'eval'; DisplayEval = 'eval' })
            }
            [void]$plans.Add(@{ Name = 'absolute-evaldir'; SetEvalDir = $true; EvalValue = $resolvedEval; DisplayEval = $resolvedEval })
        } catch {
            [void]$plans.Add(@{ Name = 'configured-evaldir'; SetEvalDir = $true; EvalValue = $script:EvalDir; DisplayEval = $script:EvalDir })
        }
    }
    return ,$plans.ToArray()
}

function Start-EngineAttempt {
    param([hashtable]$Plan)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:EngineExePath
    $psi.WorkingDirectory = Split-Path -Parent $script:EngineExePath
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
    $script:EngineProc = $proc

    Start-Sleep -Milliseconds 150
    if ($proc.HasExited) {
        Capture-ExitedEngineDetails -Process $proc -Reason ('startup wait mode=' + $Plan.Name)
        throw ('engine exited during startup mode=' + $Plan.Name + (Get-EngineExitSummary))
    }

    Send-Command 'usi'
    $usiLines = Read-Until -Predicate { param($line) $line -eq 'usiok' } -TimeoutMs 30000

    if ($Plan.SetEvalDir -and -not [string]::IsNullOrWhiteSpace([string]$Plan.EvalValue)) {
        Try-SetOption -Name 'EvalDir' -Value ([string]$Plan.EvalValue)
        Write-Log ('startup mode=' + $Plan.Name + ' set EvalDir=' + [string]$Plan.DisplayEval)
    } else {
        Write-Log ('startup mode=' + $Plan.Name + ' using engine default EvalDir')
    }

    if ($script:Threads -ge 1) {
        Try-SetOption -Name 'Threads' -Value ([string]$script:Threads)
    }
    if ($script:HashMb -ge 1) {
        Try-SetOption -Name 'USI_Hash' -Value ([string]$script:HashMb)
    }
    if ($script:MultiPv -ge 1) {
        Try-SetOption -Name 'MultiPV' -Value ([string]$script:MultiPv)
    }
    if ($script:FvScale -ge 1) {
        Try-SetOption -Name 'FV_SCALE' -Value ([string]$script:FvScale)
    }

    Send-Command 'isready'
    $null = Read-Until -Predicate { param($line) $line -eq 'readyok' } -TimeoutMs 30000

    Send-Command 'usinewgame'
    $script:EngineReady = $true
    $script:LastStartupMode = $Plan.Name
}

function Build-CompatibilityHint {
    $stdout = [string]$script:LastEngineStdoutLine
    if ($stdout -like '*failed to read nn.bin*FileReadError*') {
        return 'nn.bin read failed. If all EvalDir modes fail, yaneuraou.exe and nn.bin may be incompatible.'
    }
    if ($stdout -like '*failed to read nn.bin*') {
        return 'nn.bin read failed.'
    }
    return $null
}

function Ensure-Started {
    if ($script:EngineReady -and $script:EngineProc -and -not $script:EngineProc.HasExited) {
        return
    }

    if ($script:StartupFailureCacheAt) {
        $elapsed = ((Get-Date) - $script:StartupFailureCacheAt).TotalMilliseconds
        if ($elapsed -lt $script:StartupFailureCooldownMs -and -not [string]::IsNullOrWhiteSpace($script:StartupFailureCacheMessage)) {
            throw $script:StartupFailureCacheMessage
        }
    }

    $script:EngineError = $null
    $script:EngineReady = $false

    if (-not (Test-Path -LiteralPath $script:EngineExePath)) {
        throw ('engine exe not found: {0}' -f $script:EngineExePath)
    }

    $script:RecentEngineStderr.Clear()
    $script:LastEngineExitCode = $null
    $script:LastEngineStdoutLine = $null
    $script:LastEngineStartAt = Get-Date
    $script:LastEngineExitSummaryLogged = $null
    $script:LastStartupMode = $null
    $script:LastStartupAttempts = @()
    $script:LastNnHeader = Get-NnHeaderSummary -EvalDirPath $script:EvalDir
    Stop-EngineProcess -Reason 'pre-start cleanup'

    $plans = Get-StartupPlans
    $lastError = $null

    foreach ($plan in $plans) {
        $attemptInfo = [ordered]@{ mode = $plan.Name; eval = $plan.DisplayEval; ok = $false; error = $null }
        try {
            Start-EngineAttempt -Plan $plan
            $attemptInfo.ok = $true
            $script:LastStartupAttempts += [pscustomobject]$attemptInfo
            $script:StartupFailureCacheAt = $null
            $script:StartupFailureCacheMessage = $null
            return
        } catch {
            $attemptInfo.error = $_.Exception.Message
            $script:LastStartupAttempts += [pscustomobject]$attemptInfo
            $lastError = $_.Exception.Message
            Write-Log ('startup attempt failed mode=' + $plan.Name + ' error=' + $lastError)
            Stop-EngineProcess -Reason ('startup failure mode=' + $plan.Name)
        }
    }

    $hint = Build-CompatibilityHint
    if (-not [string]::IsNullOrWhiteSpace($hint)) {
        $lastError = ($lastError + ' / ' + $hint)
    }
    $script:StartupFailureCacheAt = Get-Date
    $script:StartupFailureCacheMessage = $lastError
    throw $lastError
}

function Send-Command {
    param([string]$Command)
    if (-not $script:EngineProc) {
        throw 'engine process is not running'
    }
    if ($script:EngineProc.HasExited) {
        Capture-ExitedEngineDetails -Reason 'send command'
        throw ('engine process is not running' + (Get-EngineExitSummary))
    }
    $script:EngineProc.StandardInput.WriteLine($Command)
    $script:EngineProc.StandardInput.Flush()
}

function Read-LineWithTimeout {
    param([int]$TimeoutMs = 30000)

    if (-not $script:EngineProc) {
        throw 'engine process is not running'
    }
    if ($script:EngineProc.HasExited) {
        Capture-ExitedEngineDetails -Reason 'read before wait'
        throw ('engine stdout closed' + (Get-EngineExitSummary))
    }

    $task = $script:EngineProc.StandardOutput.ReadLineAsync()
    if (-not $task.Wait($TimeoutMs)) {
        if ($script:EngineProc.HasExited) {
            Capture-ExitedEngineDetails -Reason 'timeout with exited process'
            throw ('engine stdout closed' + (Get-EngineExitSummary))
        }
        throw ('timeout while waiting for engine output ({0} ms)' -f $TimeoutMs)
    }

    try {
        $line = $task.Result
    } catch {
        if ($script:EngineProc.HasExited) {
            Capture-ExitedEngineDetails -Reason 'task result after exit'
        }
        throw
    }

    if ($null -eq $line) {
        if ($script:EngineProc.HasExited) {
            Capture-ExitedEngineDetails -Reason 'stdout returned null'
        }
        throw ('engine stdout closed' + (Get-EngineExitSummary))
    }

    $script:LastEngineStdoutLine = [string]$line
    return [string]$line
}

function Read-Until {
    param(
        [scriptblock]$Predicate,
        [int]$TimeoutMs = 30000
    )

    $lines = New-Object System.Collections.Generic.List[string]
    while ($true) {
        $line = Read-LineWithTimeout -TimeoutMs $TimeoutMs
        [void]$lines.Add($line)
        if (& $Predicate $line) {
            return ,$lines.ToArray()
        }
    }
}

function Try-SetOption {
    param([string]$Name, [string]$Value)
    try {
        Send-Command ('setoption name {0} value {1}' -f $Name, $Value)
    } catch {
    }
}

function Get-StatusObject {
    $ok = $false
    $error = $null
    $entered = $false
    try {
        [System.Threading.Monitor]::Enter($script:SyncRoot)
        $entered = $true
        Ensure-Started
        $ok = $true
    } catch {
        $error = $_.Exception.Message
        Write-Log ('status error: ' + $error)
        $script:EngineError = $error
        $script:EngineReady = $false
    } finally {
        if ($entered) {
            [System.Threading.Monitor]::Exit($script:SyncRoot)
        }
    }

    return @{
        ok = $ok
        ready = ($ok -and $script:EngineReady)
        backend = $script:BackendName
        variant = $script:VariantName
        listenPrefix = $script:ListenPrefix
        engineExePath = $script:EngineExePath
        evalDir = $script:EvalDir
        displayName = $script:DisplayName
        customDifficulty = $script:CustomDifficulty
        startupMode = $script:LastStartupMode
        startupAttempts = @($script:LastStartupAttempts)
        nnHeader = $script:LastNnHeader
        error = $error
        lastEngineExitCode = $script:LastEngineExitCode
        recentEngineStderr = @($script:RecentEngineStderr)
        lastEngineStdoutLine = $script:LastEngineStdoutLine
    }
}

function Read-BestmoveWithGuard {
    param(
        [int]$SearchTimeoutMs = 120000,
        [int]$StopAfterMs = 9000,
        [int]$StopGraceMs = 8000
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $stopSent = $false
    $pendingTask = $null

    while ($sw.ElapsedMilliseconds -lt ($SearchTimeoutMs + $StopGraceMs + 2000)) {
        if ($null -eq $pendingTask) {
            if ($script:EngineProc.HasExited -and $script:EngineProc.StandardOutput.EndOfStream) {
                break
            }
            $pendingTask = $script:EngineProc.StandardOutput.ReadLineAsync()
        }

        if (-not $pendingTask.Wait(250)) {
            if (-not $stopSent -and $sw.ElapsedMilliseconds -ge $StopAfterMs) {
                Write-Log ('think guard: stop after ' + $sw.ElapsedMilliseconds + ' ms')
                Send-Command 'stop'
                $stopSent = $true
            }
            if ($script:EngineProc.HasExited -and $script:EngineProc.StandardOutput.EndOfStream) {
                break
            }
            continue
        }

        $line = $pendingTask.Result
        $pendingTask = $null
        if ($null -eq $line) {
            if ($script:EngineProc.HasExited) {
                Capture-ExitedEngineDetails -Reason 'think stdout null'
                break
            }
            continue
        }

        $line = [string]$line
        $script:LastEngineStdoutLine = $line
        [void]$lines.Add($line)
        if ($line -like 'bestmove *') {
            Write-Log ('think bestmove=' + $line)
            return ,$lines.ToArray()
        }
        if ($line -like 'info *' -and $line -match '\bdepth\b') {
            Write-Log ('engine info: ' + $line)
        }
    }

    throw ('timeout while waiting for bestmove' + (Get-EngineExitSummary))
}

function Invoke-Think {
    param([hashtable]$Payload)

    [System.Threading.Monitor]::Enter($script:SyncRoot)
    try {
        Ensure-Started

        $positionCmd = $null
        $startposSfen = 'lnsgkgsnl/1r5b1/ppppppppp/9/9/9/PPPPPPPPP/1B5R1/LNSGKGSNL b - 1'
        if ($Payload.ContainsKey('usiPosition') -and -not [string]::IsNullOrWhiteSpace([string]$Payload['usiPosition'])) {
            $rawPosition = ([string]$Payload['usiPosition']).Trim()
            if ($rawPosition -match '^(?i:position)\s+sfen\s+' + [regex]::Escape($startposSfen) + '$') {
                $positionCmd = 'position startpos'
            } elseif ($rawPosition -match '^(?i:position)\b') {
                $positionCmd = $rawPosition
            } else {
                $positionCmd = 'position ' + $rawPosition
            }
        } elseif ($Payload.ContainsKey('sfen') -and -not [string]::IsNullOrWhiteSpace([string]$Payload['sfen'])) {
            $rawSfen = ([string]$Payload['sfen']).Trim()
            if ($rawSfen -ieq $startposSfen) {
                $positionCmd = 'position startpos'
            } elseif ($rawSfen -match '^(?i:position)\b') {
                $positionCmd = $rawSfen
            } elseif ($rawSfen -match '^(?i:startpos)\b') {
                $positionCmd = 'position ' + $rawSfen
            } elseif ($rawSfen -match '^(?i:sfen)\b') {
                $positionCmd = 'position ' + $rawSfen
            } else {
                $positionCmd = 'position sfen ' + $rawSfen
            }
        } else {
            throw 'missing sfen or usiPosition'
        }

        $requestedDepth = $null
        $requestedMoveTime = $null
        $requestedTimeoutPaddingMs = $null
        $requestedThreads = $null
        $requestedHashMb = $null
        $requestedMultiPv = $null
        $requestedFvScale = $null
        $useCustomProfile = $false
        if ($Payload.ContainsKey('useCustomProfile') -and $null -ne $Payload['useCustomProfile']) {
            try { $useCustomProfile = [bool]$Payload['useCustomProfile'] } catch { $useCustomProfile = $false }
        }
        if (-not $useCustomProfile -and $Payload.ContainsKey('profileKey') -and $null -ne $Payload['profileKey']) {
            $useCustomProfile = ([string]$Payload['profileKey']).Trim().ToLowerInvariant() -eq 'custom'
        }
        if ($Payload.ContainsKey('depth') -and $null -ne $Payload['depth']) {
            try { $requestedDepth = [int]$Payload['depth'] } catch {}
        }
        if ($Payload.ContainsKey('movetime') -and $null -ne $Payload['movetime']) {
            try { $requestedMoveTime = [int]$Payload['movetime'] } catch {}
        }
        if ($Payload.ContainsKey('timeoutPaddingMs') -and $null -ne $Payload['timeoutPaddingMs']) {
            try { $requestedTimeoutPaddingMs = [int]$Payload['timeoutPaddingMs'] } catch {}
        }
        if ($Payload.ContainsKey('threads') -and $null -ne $Payload['threads']) {
            try { $requestedThreads = [int]$Payload['threads'] } catch {}
        }
        if ($Payload.ContainsKey('hash') -and $null -ne $Payload['hash']) {
            try { $requestedHashMb = [int]$Payload['hash'] } catch {}
        }
        if ($Payload.ContainsKey('multipv') -and $null -ne $Payload['multipv']) {
            try { $requestedMultiPv = [int]$Payload['multipv'] } catch {}
        }
        if ($Payload.ContainsKey('fvScale') -and $null -ne $Payload['fvScale']) {
            try { $requestedFvScale = [int]$Payload['fvScale'] } catch {}
        }

        $reqThreads = $script:Threads
        $reqHashMb = $script:HashMb
        $reqMultiPv = $script:MultiPv
        $reqFvScale = $script:FvScale
        $resolvedDepth = $requestedDepth
        $resolvedMoveTime = $requestedMoveTime
        $timeoutPaddingMs = $script:DefaultThinkTimeoutPaddingMs

        if ($useCustomProfile -and $null -ne $script:CustomDifficulty) {
            if ($null -ne $script:CustomDifficulty.threads) { $reqThreads = [int]$script:CustomDifficulty.threads }
            if ($null -ne $script:CustomDifficulty.hashMb) { $reqHashMb = [int]$script:CustomDifficulty.hashMb }
            if ($null -ne $script:CustomDifficulty.multiPv) { $reqMultiPv = [int]$script:CustomDifficulty.multiPv }
            if ($null -ne $script:CustomDifficulty.fvScale) { $reqFvScale = [int]$script:CustomDifficulty.fvScale }
            if ($null -ne $script:CustomDifficulty.depth -and $null -eq $resolvedDepth) { $resolvedDepth = [int]$script:CustomDifficulty.depth }
            if ($null -ne $script:CustomDifficulty.moveTimeMs -and $null -eq $resolvedMoveTime) { $resolvedMoveTime = [int]$script:CustomDifficulty.moveTimeMs }
            if ($null -ne $script:CustomDifficulty.timeoutPaddingMs) { $timeoutPaddingMs = [int]$script:CustomDifficulty.timeoutPaddingMs }
        }

        if ($null -ne $requestedThreads -and $requestedThreads -ge 1) { $reqThreads = $requestedThreads }
        if ($null -ne $requestedHashMb -and $requestedHashMb -ge 1) { $reqHashMb = $requestedHashMb }
        if ($null -ne $requestedMultiPv -and $requestedMultiPv -ge 1) { $reqMultiPv = $requestedMultiPv }
        if ($null -ne $requestedFvScale -and $requestedFvScale -ge 1) { $reqFvScale = $requestedFvScale }
        if ($null -ne $requestedTimeoutPaddingMs -and $requestedTimeoutPaddingMs -ge 1000) { $timeoutPaddingMs = $requestedTimeoutPaddingMs }

        if ($reqThreads -lt 1) { $reqThreads = 1 }
        if ($reqHashMb -lt 1) { $reqHashMb = 1 }
        if ($reqMultiPv -lt 1) { $reqMultiPv = 1 }
        if ($reqFvScale -lt 1) { $reqFvScale = 1 }

        if ($null -ne $resolvedDepth -and $resolvedDepth -gt 0) {
            $goCmd = 'go depth ' + $resolvedDepth
            $movetime = 1000
            if ($null -ne $resolvedMoveTime -and $resolvedMoveTime -gt 0) { $movetime = [int]$resolvedMoveTime }
        } else {
            $movetime = 3000
            if ($null -ne $resolvedMoveTime) {
                $movetime = [int]$resolvedMoveTime
            }
            if ($movetime -lt 1) { $movetime = 1 }
            $goCmd = 'go movetime ' + $movetime
        }

        Try-SetOption -Name 'Threads' -Value ([string]$reqThreads)
        Try-SetOption -Name 'USI_Hash' -Value ([string]$reqHashMb)
        Try-SetOption -Name 'MultiPV' -Value ([string]$reqMultiPv)
        if ($reqFvScale -ge 1) {
            Try-SetOption -Name 'FV_SCALE' -Value ([string]$reqFvScale)
        }

        Send-Command 'usinewgame'
        Send-Command 'isready'
        $null = Read-Until -Predicate { param($line) $line -eq 'readyok' } -TimeoutMs 30000

        if ($timeoutPaddingMs -lt 1000) { $timeoutPaddingMs = 1000 }
        $stopAfterMs = $movetime + $timeoutPaddingMs

        Write-Log ('think position=' + $positionCmd)
        Write-Log ('think go=' + $goCmd + ' threads=' + $reqThreads + ' hash=' + $reqHashMb + ' multipv=' + $reqMultiPv + ' fvScale=' + $reqFvScale + ' requestedThreads=' + $requestedThreads + ' requestedHash=' + $requestedHashMb + ' requestedMultiPv=' + $requestedMultiPv + ' requestedDepth=' + $requestedDepth + ' requestedMoveTime=' + $requestedMoveTime + ' custom=' + $useCustomProfile + ' stopAfterMs=' + $stopAfterMs)

        Send-Command $positionCmd
        Send-Command $goCmd

        $lines = Read-BestmoveWithGuard -SearchTimeoutMs ($movetime + $timeoutPaddingMs + 30000) -StopAfterMs $stopAfterMs -StopGraceMs $script:ThinkStopGraceMs
        $bestmoveLine = $lines[-1]
        $m = [regex]::Match($bestmoveLine, '^bestmove\s+(\S+)(?:\s+ponder\s+(\S+))?$')
        if (-not $m.Success) {
            throw ('invalid bestmove line: {0}' -f $bestmoveLine)
        }

        $ponder = $null
        if ($m.Groups.Count -ge 3 -and $m.Groups[2].Success) {
            $ponder = $m.Groups[2].Value
        }

        return @{
            ok = $true
            bestmove = $m.Groups[1].Value
            ponder = $ponder
            raw = $bestmoveLine
            output = $lines
            backend = $script:BackendName
            variant = $script:VariantName
        }
    } catch {
        $script:EngineError = $_.Exception.Message
        Write-Log ('think error: ' + $_.Exception.Message)
        $script:EngineReady = $false
        return @{
            ok = $false
            error = $_.Exception.Message
            backend = $script:BackendName
            variant = $script:VariantName
            startupMode = $script:LastStartupMode
            startupAttempts = @($script:LastStartupAttempts)
            nnHeader = $script:LastNnHeader
            lastEngineExitCode = $script:LastEngineExitCode
            recentEngineStderr = @($script:RecentEngineStderr)
            lastEngineStdoutLine = $script:LastEngineStdoutLine
        }
    } finally {
        [System.Threading.Monitor]::Exit($script:SyncRoot)
    }
}

function Read-RequestBody {
    param([System.Net.HttpListenerRequest]$Request)

    if (-not $Request.HasEntityBody) {
        return ''
    }

    $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    try {
        return $reader.ReadToEnd()
    } finally {
        $reader.Dispose()
    }
}

function Add-CorsHeaders {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [System.Net.HttpListenerRequest]$Request
    )

    $origin = $Request.Headers['Origin']
    if ([string]::IsNullOrWhiteSpace($origin)) {
        $origin = '*'
    }

    $Response.Headers['Access-Control-Allow-Origin'] = $origin
    if ($origin -ne '*') {
        $Response.Headers['Vary'] = 'Origin'
    }
    $Response.Headers['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS'
    $Response.Headers['Access-Control-Allow-Headers'] = 'Content-Type, X-Requested-With'
    $Response.Headers['Access-Control-Max-Age'] = '86400'

    $reqPrivateNetwork = $Request.Headers['Access-Control-Request-Private-Network']
    if ($reqPrivateNetwork -and $reqPrivateNetwork.ToLowerInvariant() -eq 'true') {
        $Response.Headers['Access-Control-Allow-Private-Network'] = 'true'
    }
}

function Write-EmptyResponse {
    param(
        [System.Net.HttpListenerContext]$Context,
        [int]$StatusCode = 204
    )

    $resp = $Context.Response
    try {
        Add-CorsHeaders -Response $resp -Request $Context.Request
        $resp.StatusCode = $StatusCode
        $resp.ContentLength64 = 0
    } catch {
        Write-Log ('empty response setup failed: ' + $_.Exception.Message)
    } finally {
        try { $resp.OutputStream.Close() } catch {}
        try { $resp.Close() } catch {}
    }
}

function Write-JsonResponse {
    param(
        [System.Net.HttpListenerContext]$Context,
        [int]$StatusCode,
        [object]$Payload
    )

    $resp = $Context.Response
    try {
        $json = $Payload | ConvertTo-Json -Depth 8 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        Add-CorsHeaders -Response $resp -Request $Context.Request
        $resp.StatusCode = $StatusCode
        $resp.ContentType = 'application/json; charset=utf-8'
        $resp.ContentEncoding = [System.Text.Encoding]::UTF8
        $resp.ContentLength64 = $bytes.Length
        $resp.OutputStream.Write($bytes, 0, $bytes.Length)
    } catch {
        Write-Log ('json response write failed: ' + $_.Exception.Message)
    } finally {
        try { $resp.OutputStream.Close() } catch {}
        try { $resp.Close() } catch {}
    }
}

function Start-ListenerLoop {
    Load-Config
    Write-Log ('bridge listening on ' + $script:ListenPrefix)
    Write-Log ('engineExePath=' + $script:EngineExePath)
    Write-Log ('evalDir=' + $script:EvalDir)
    Write-Log ('threads=' + $script:Threads + ' hashMb=' + $script:HashMb + ' multiPv=' + $script:MultiPv + ' fvScale=' + $script:FvScale)
    if ($script:LastNnHeader) {
        Write-Log ('nnHeader=' + $script:LastNnHeader)
    }

    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($script:ListenPrefix)
    $listener.Start()

    try {
        while ($listener.IsListening) {
            $ctx = $null
            try {
                $ctx = $listener.GetContext()
            } catch {
                if ($listener.IsListening) {
                    Write-Log ('listener getcontext error: ' + $_.Exception.Message)
                    Start-Sleep -Milliseconds 200
                    continue
                }
                break
            }

            try {
                $path = $ctx.Request.Url.AbsolutePath
                $method = $ctx.Request.HttpMethod.ToUpperInvariant()
                Write-Log ('request ' + $method + ' ' + $path)

                if ($method -eq 'OPTIONS') {
                    Write-EmptyResponse -Context $ctx -StatusCode 204
                    continue
                }

                switch ($path) {
                    '/status' {
                        $result = Get-StatusObject
                        Write-JsonResponse -Context $ctx -StatusCode 200 -Payload $result
                    }
                    '/warmup' {
                        $result = Get-StatusObject
                        Write-JsonResponse -Context $ctx -StatusCode 200 -Payload $result
                    }
                    '/think' {
                        if ($method -ne 'POST') {
                            Write-JsonResponse -Context $ctx -StatusCode 405 -Payload @{ ok = $false; error = 'POST required'; backend = $script:BackendName; variant = $script:VariantName }
                            break
                        }
                        $body = Read-RequestBody -Request $ctx.Request
                        $payload = @{}
                        if (-not [string]::IsNullOrWhiteSpace($body)) {
                            $obj = $body | ConvertFrom-Json
                            foreach ($p in $obj.PSObject.Properties) {
                                $payload[$p.Name] = $p.Value
                            }
                        }
                        $result = Invoke-Think -Payload $payload
                        Write-JsonResponse -Context $ctx -StatusCode 200 -Payload $result
                    }
                    default {
                        $result = @{ ok = $false; error = ('unknown path: ' + $path); backend = $script:BackendName; variant = $script:VariantName }
                        Write-JsonResponse -Context $ctx -StatusCode 404 -Payload $result
                    }
                }
            } catch {
                $reqError = $_.Exception.Message
                Write-Log ('request error: ' + $reqError)
                try {
                    Write-JsonResponse -Context $ctx -StatusCode 500 -Payload @{ ok = $false; error = $reqError; backend = $script:BackendName; variant = $script:VariantName; startupMode = $script:LastStartupMode; startupAttempts = @($script:LastStartupAttempts); nnHeader = $script:LastNnHeader; lastEngineExitCode = $script:LastEngineExitCode; recentEngineStderr = @($script:RecentEngineStderr); lastEngineStdoutLine = $script:LastEngineStdoutLine }
                } catch {
                    Write-Log ('request error response failed: ' + $_.Exception.Message)
                }
            }
        }
    } finally {
        if ($listener.IsListening) {
            $listener.Stop()
        }
        Stop-EngineProcess -Reason 'listener shutdown'
    }
}

try {
    Start-ListenerLoop
} catch {
    Write-Log ('fatal bridge error: ' + $_.Exception.Message)
    throw
}
