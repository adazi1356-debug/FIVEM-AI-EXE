param(
    [string]$EngineReleaseTag = 'v8.30git',
    [string]$EngineArchivePath = ''
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$engineDir = Join-Path $root 'engine'
$evalDir = Join-Path $engineDir 'eval'
$downloadsDir = Join-Path $root 'downloads'
$summaryPath = Join-Path $root 'INSTALL_MATCHING_YANEOURAOU_EXE_RESULT.txt'
$verifyPath = Join-Path $engineDir 'MATCHING_ENGINE_VERIFIED.txt'
$evalInfoPath = Join-Path $engineDir 'EVAL_CURRENT.txt'
$configPath = Join-Path $root 'bridge_config.json'
$logDir = 'C:\Users\adazi\Downloads\powershell'
$runId = Get-Date -Format 'yyyyMMdd_HHmmss'
$scriptVersion = 'v300_public_oneclick'

New-Item -ItemType Directory -Force -Path $engineDir | Out-Null
New-Item -ItemType Directory -Force -Path $evalDir | Out-Null
New-Item -ItemType Directory -Force -Path $downloadsDir | Out-Null
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
Remove-Item -Force $summaryPath -ErrorAction SilentlyContinue
Remove-Item -Force $verifyPath -ErrorAction SilentlyContinue

function New-LogPath([string]$name) {
    $safe = ($name -replace '[^A-Za-z0-9._-]', '_')
    return (Join-Path $logDir ('yane_bridge_' + $runId + '_' + $safe + '.txt'))
}

function Write-Summary([string]$line) {
    $line | Tee-Object -FilePath $summaryPath -Append | Out-Host
}

function Write-StepInfo([string]$logPath, [string]$line) {
    $line | Tee-Object -FilePath $logPath -Append | Out-Host
}

function Get-ReleaseByTag([string]$repo, [string]$tag, [string]$label) {
    $log = New-LogPath ($label + '_release_query')
    Write-StepInfo $log ('repo=' + $repo)
    Write-StepInfo $log ('tag=' + $tag)
    $headers = @{
        'User-Agent' = 'PowerShell-YaneBridge-Installer'
        'Accept' = 'application/vnd.github+json'
    }
    $api = 'https://api.github.com/repos/' + $repo + '/releases/tags/' + $tag
    $release = Invoke-RestMethod -UseBasicParsing -Headers $headers -Uri $api -Method Get
    $release | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $log -Encoding UTF8
    if (-not $release) {
        throw 'GitHub release query returned empty data for ' + $repo + ' tag ' + $tag
    }
    return $release
}

function Select-ReleaseAsset($release, [string[]]$patterns, [string]$label) {
    $assets = @($release.assets)
    if (-not $assets -or $assets.Count -eq 0) {
        throw 'GitHub release assets were empty for ' + $label
    }

    foreach ($pattern in $patterns) {
        $hit = $assets | Where-Object { $_.name -like $pattern } | Select-Object -First 1
        if ($hit) { return $hit }
    }

    $assetNames = @($assets | Select-Object -ExpandProperty name)
    throw ('Could not find a matching asset for ' + $label + '. assets=' + ($assetNames -join ', '))
}

function Save-ReleaseAsset([string]$repo, [string]$tag, [string[]]$patterns, [string]$label) {
    $release = Get-ReleaseByTag -repo $repo -tag $tag -label $label
    $asset = Select-ReleaseAsset -release $release -patterns $patterns -label $label
    $archiveOut = Join-Path $downloadsDir $asset.name
    $log = New-LogPath ($label + '_download_asset')
    Write-StepInfo $log ('assetName=' + $asset.name)
    Write-StepInfo $log ('assetUrl=' + $asset.browser_download_url)
    if (-not (Test-Path -LiteralPath $archiveOut)) {
        $headers = @{ 'User-Agent' = 'PowerShell-YaneBridge-Installer' }
        Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri $asset.browser_download_url -OutFile $archiveOut
    }
    Write-StepInfo $log ('saved=' + $archiveOut)
    return [PSCustomObject]@{
        ArchivePath = $archiveOut
        AssetName = $asset.name
        Repo = $repo
        Tag = $tag
        ReleaseName = [string]$release.name
    }
}

function Get-7ZipExtractor([string]$logPath) {
    $sevenZipCandidates = @(
        (Join-Path $env:ProgramFiles '7-Zip\7z.exe'),
        (Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe'),
        (Join-Path $env:ProgramFiles '7-Zip\7zr.exe'),
        (Join-Path ${env:ProgramFiles(x86)} '7-Zip\7zr.exe')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    $sevenZip = $sevenZipCandidates | Select-Object -First 1
    if ($sevenZip) {
        Write-StepInfo $logPath ('extractor=' + $sevenZip)
        return $sevenZip
    }

    $toolDir = Join-Path $downloadsDir 'tools'
    New-Item -ItemType Directory -Force -Path $toolDir | Out-Null
    $sevenZrPath = Join-Path $toolDir '7zr.exe'
    if (-not (Test-Path -LiteralPath $sevenZrPath)) {
        $url = 'https://www.7-zip.org/a/7zr.exe'
        Write-StepInfo $logPath ('downloadingExtractor=' + $url)
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $sevenZrPath
    }
    if (-not (Test-Path -LiteralPath $sevenZrPath)) {
        throw 'Could not get 7zr.exe extractor.'
    }
    Write-StepInfo $logPath ('extractor=' + $sevenZrPath)
    return $sevenZrPath
}

function Expand-ArchiveAny([string]$archive, [string]$destination, [string]$label) {
    $log = New-LogPath ($label + '_extract')
    Remove-Item -Recurse -Force $destination -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    Write-StepInfo $log ('archive=' + $archive)
    Write-StepInfo $log ('destination=' + $destination)

    $ext = [System.IO.Path]::GetExtension($archive)
    if ($ext -and $ext.ToLowerInvariant() -eq '.zip') {
        Expand-Archive -LiteralPath $archive -DestinationPath $destination -Force
    }
    elseif ($ext -and $ext.ToLowerInvariant() -eq '.7z') {
        $sevenZip = Get-7ZipExtractor -logPath $log
        & $sevenZip x $archive ('-o' + $destination) -y 2>&1 | Tee-Object -FilePath $log -Append | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw '7-Zip extraction failed with exit code ' + $LASTEXITCODE
        }
    }
    else {
        $tarCmd = Get-Command tar -ErrorAction SilentlyContinue
        if ($tarCmd) {
            Write-StepInfo $log ('extractor=' + $tarCmd.Source)
            & $tarCmd.Source -xf $archive -C $destination 2>&1 | Tee-Object -FilePath $log -Append | Out-Host
            if ($LASTEXITCODE -ne 0) {
                throw 'tar extraction failed with exit code ' + $LASTEXITCODE
            }
        }
        else {
            $sevenZip = Get-7ZipExtractor -logPath $log
            & $sevenZip x $archive ('-o' + $destination) -y 2>&1 | Tee-Object -FilePath $log -Append | Out-Host
            if ($LASTEXITCODE -ne 0) {
                throw 'archive extraction failed with exit code ' + $LASTEXITCODE
            }
        }
    }

    $files = Get-ChildItem -Recurse -File -LiteralPath $destination | Select-Object -ExpandProperty FullName
    if (-not $files -or $files.Count -eq 0) {
        throw 'Archive extraction produced no files for ' + $label
    }
}

function Find-NnBin([string]$searchRoot) {
    $files = Get-ChildItem -Recurse -File -LiteralPath $searchRoot | Where-Object { $_.Name -ieq 'nn.bin' }
    if (-not $files -or $files.Count -eq 0) {
        throw 'nn.bin was not found in extracted files.'
    }
    $best = $files | Sort-Object -Property @{Expression={ if ($_.FullName -match '[\\/]eval[\\/]') { 0 } else { 1 } }}, @{Expression={ $_.FullName.Length }} | Select-Object -First 1
    return $best.FullName
}

function Find-OptionalEvalOptions([string]$searchRoot) {
    $files = Get-ChildItem -Recurse -File -LiteralPath $searchRoot | Where-Object { $_.Name -ieq 'eval_options.txt' }
    if (-not $files -or $files.Count -eq 0) {
        return $null
    }
    $best = $files | Sort-Object -Property @{Expression={ if ($_.FullName -match '[\\/]eval[\\/]') { 0 } else { 1 } }}, @{Expression={ $_.FullName.Length }} | Select-Object -First 1
    return $best.FullName
}

function Install-EvalPackage([string]$name, [string]$repo, [string]$tag, [int]$fvScale) {
    $label = 'eval_' + $name.ToLowerInvariant()
    $download = Save-ReleaseAsset -repo $repo -tag $tag -patterns @('*.7z', '*.zip') -label $label
    $extractDir = Join-Path $downloadsDir ($label + '_extract')
    Expand-ArchiveAny -archive $download.ArchivePath -destination $extractDir -label $label

    $nnPath = Find-NnBin -searchRoot $extractDir
    $optionsPath = Find-OptionalEvalOptions -searchRoot $extractDir

    New-Item -ItemType Directory -Force -Path $evalDir | Out-Null
    Remove-Item -Force (Join-Path $evalDir 'nn.bin') -ErrorAction SilentlyContinue
    Remove-Item -Force (Join-Path $evalDir 'eval_options.txt') -ErrorAction SilentlyContinue

    Copy-Item -Force -LiteralPath $nnPath -Destination (Join-Path $evalDir 'nn.bin')
    if ($optionsPath) {
        Copy-Item -Force -LiteralPath $optionsPath -Destination (Join-Path $evalDir 'eval_options.txt')
    }

    @(
        'name=' + $name,
        'repo=' + $repo,
        'tag=' + $tag,
        'asset=' + $download.AssetName,
        'fvScale=' + $fvScale,
        'installedAt=' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    ) | Set-Content -LiteralPath $evalInfoPath -Encoding ASCII

    return [PSCustomObject]@{
        Name = $name
        Repo = $repo
        Tag = $tag
        AssetName = $download.AssetName
        FvScale = $fvScale
        NnPath = (Join-Path $evalDir 'nn.bin')
    }
}

function Update-BridgeConfigFvScale([int]$fvScale) {
    $cfg = [ordered]@{
        listenPrefix = 'http://127.0.0.1:18777/'
        engineExePath = 'engine\yaneuraou.exe'
        evalDir = 'engine\eval'
        hashMb = 64
        threads = 1
        multiPv = 1
        fvScale = $fvScale
        displayName = 'Local YaneuraOu'
    }

    if (Test-Path -LiteralPath $configPath) {
        try {
            $raw = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $obj = $raw | ConvertFrom-Json
                foreach ($prop in $obj.PSObject.Properties) {
                    $cfg[$prop.Name] = $prop.Value
                }
            }
        }
        catch {
        }
    }

    $cfg['fvScale'] = $fvScale
    $json = $cfg | ConvertTo-Json -Depth 5
    $utf8 = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($configPath, ($json + [Environment]::NewLine), $utf8)
}


function Get-CandidateScore([string]$name) {
    $u = $name.ToUpperInvariant()
    $score = 0
    if ($u -match 'HALFKP256') { $score += 1000 }
    if ($u -match 'NNUE') { $score += 200 }
    if ($u -match 'AVX512VNNI') { $score += 260 }
    elseif ($u -match 'AVX512') { $score += 250 }
    elseif ($u -match 'AVXVNNI') { $score += 240 }
    elseif ($u -match 'ZEN3') { $score += 230 }
    elseif ($u -match 'ZEN2') { $score += 220 }
    elseif ($u -match 'ZEN1') { $score += 210 }
    elseif ($u -match 'AVX2') { $score += 200 }
    elseif ($u -match 'SSE4[._]?2') { $score += 190 }
    elseif ($u -match 'SSE4[._]?1') { $score += 180 }
    elseif ($u -match 'AVX') { $score += 170 }
    return $score
}

function Get-CandidateExecutables([string]$searchRoot) {
    $log = New-LogPath 'engine_candidate_list'
    $files = Get-ChildItem -Recurse -File -LiteralPath $searchRoot | Where-Object {
        $_.Extension -ieq '.exe' -and $_.Name -match 'halfkp256'
    }
    if (-not $files -or $files.Count -eq 0) {
        throw 'Could not find any halfKP256 exe in the extracted archive.'
    }

    $cand = $files | ForEach-Object {
        [PSCustomObject]@{
            Name = $_.Name
            FullName = $_.FullName
            Score = Get-CandidateScore $_.Name
        }
    } | Sort-Object -Property @{Expression='Score';Descending=$true}, @{Expression='Name';Descending=$false}

    $cand | Format-Table -AutoSize | Out-String | Set-Content -LiteralPath $log -Encoding UTF8
    return ,$cand
}

function Read-UntilMatch([System.Diagnostics.Process]$proc, [System.Collections.Generic.List[string]]$stdoutLines, [string]$matchText, [int]$timeoutMs) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $pendingTask = $null
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        if ($null -eq $pendingTask) {
            if ($proc.HasExited -and $proc.StandardOutput.EndOfStream) { break }
            $pendingTask = $proc.StandardOutput.ReadLineAsync()
        }

        if (-not $pendingTask.Wait(400)) {
            if ($proc.HasExited -and $proc.StandardOutput.EndOfStream) { break }
            continue
        }

        $line = $pendingTask.Result
        $pendingTask = $null
        if ($null -eq $line) {
            if ($proc.HasExited) { break }
            continue
        }

        [void]$stdoutLines.Add($line)
        if ($line -eq $matchText) {
            return $true
        }
    }
    return $false
}

function Read-BestmoveProbe([System.Diagnostics.Process]$proc, [System.Collections.Generic.List[string]]$stdoutLines, [int]$timeoutMs) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $pendingTask = $null
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        if ($null -eq $pendingTask) {
            if ($proc.HasExited -and $proc.StandardOutput.EndOfStream) { break }
            $pendingTask = $proc.StandardOutput.ReadLineAsync()
        }

        if (-not $pendingTask.Wait(400)) {
            if ($proc.HasExited -and $proc.StandardOutput.EndOfStream) { break }
            continue
        }

        $line = $pendingTask.Result
        $pendingTask = $null
        if ($null -eq $line) {
            if ($proc.HasExited) { break }
            continue
        }

        [void]$stdoutLines.Add($line)
        if ($line -like 'bestmove *') {
            return $line
        }
    }
    return $null
}

function Test-CandidateExe([string]$candidatePath, [string]$evalDirAbs, [int]$fvScale, [string]$logPath) {
    $stdoutLines = New-Object 'System.Collections.Generic.List[string]'
    $stderrText = ''
    $exitCode = -999
    $usiok = $false
    $readyok = $false
    $bestmove = $null
    $thinkok = $false
    $proc = $null

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $candidatePath
        $psi.WorkingDirectory = $engineDir
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
        $usiok = Read-UntilMatch -proc $proc -stdoutLines $stdoutLines -matchText 'usiok' -timeoutMs 6000

        if ($usiok -and -not $proc.HasExited) {
            $proc.StandardInput.WriteLine('setoption name EvalDir value ' + $evalDirAbs)
            $proc.StandardInput.WriteLine('setoption name Threads value 1')
            $proc.StandardInput.WriteLine('setoption name USI_Hash value 64')
            $proc.StandardInput.WriteLine('setoption name MultiPV value 1')
            if ($fvScale -ge 1) {
                $proc.StandardInput.WriteLine('setoption name FV_SCALE value ' + $fvScale)
            }
            $proc.StandardInput.WriteLine('isready')
            $proc.StandardInput.Flush()
            $readyok = Read-UntilMatch -proc $proc -stdoutLines $stdoutLines -matchText 'readyok' -timeoutMs 10000
            if ($readyok -and -not $proc.HasExited) {
                $proc.StandardInput.WriteLine('usinewgame')
                $proc.StandardInput.WriteLine('isready')
                $proc.StandardInput.WriteLine('position startpos')
                $proc.StandardInput.WriteLine('go movetime 100')
                $proc.StandardInput.Flush()
                $readyok = Read-UntilMatch -proc $proc -stdoutLines $stdoutLines -matchText 'readyok' -timeoutMs 10000
                if ($readyok -and -not $proc.HasExited) {
                    $bestmove = Read-BestmoveProbe -proc $proc -stdoutLines $stdoutLines -timeoutMs 15000
                    if ($bestmove -and $bestmove -like 'bestmove *') {
                        $thinkok = $true
                    }
                }
            }
        }

        if (-not $proc.HasExited) {
            try {
                $proc.StandardInput.WriteLine('quit')
                $proc.StandardInput.Flush()
            } catch {}
            if (-not $proc.WaitForExit(2000)) {
                try { $proc.Kill() } catch {}
            }
        }
        else {
            $null = $proc.WaitForExit(200)
        }

        try { $stderrText = $proc.StandardError.ReadToEnd() } catch {}
        try { $exitCode = $proc.ExitCode } catch {}
    }
    finally {
        if ($proc) {
            try {
                if (-not $proc.HasExited) { $proc.Kill() }
            } catch {}
            $proc.Dispose()
        }
    }

    @(
        'candidate=' + $candidatePath,
        'usiok=' + $usiok,
        'readyok=' + $readyok,
        'thinkok=' + $thinkok,
        'bestmove=' + $bestmove,
        'exitCode=' + $exitCode,
        'evalDir=' + $evalDirAbs,
        'fvScale=' + $fvScale,
        '--- stdout ---'
    ) | Set-Content -LiteralPath $logPath -Encoding UTF8
    $stdoutLines | Add-Content -LiteralPath $logPath -Encoding UTF8
    Add-Content -LiteralPath $logPath -Encoding UTF8 -Value '--- stderr ---'
    Add-Content -LiteralPath $logPath -Encoding UTF8 -Value $stderrText

    return [PSCustomObject]@{
        Success = ($usiok -and $readyok -and $thinkok)
        Usiok = $usiok
        Readyok = $readyok
        Thinkok = $thinkok
        Bestmove = $bestmove
        ExitCode = $exitCode
        StderrText = $stderrText
    }
}

Write-Summary ('scriptVersion=' + $scriptVersion)
Write-Summary ('scriptPath=' + $MyInvocation.MyCommand.Path)
Write-Summary ('runId=' + $runId)
Write-Summary ('root=' + $root)
Write-Summary ('engineDir=' + $engineDir)
Write-Summary ('evalDir=' + $evalDir)

$selectedEval = $null
$evalCandidates = @(
    [PSCustomObject]@{ Name = 'Hao'; Repo = 'nodchip/tanuki-'; Tag = 'tanuki-.halfkp_256x2-32-32.2023-05-08'; FvScale = 20 },
    [PSCustomObject]@{ Name = 'Suisho5'; Repo = 'yaneurao/YaneuraOu'; Tag = 'suisho5'; FvScale = 24 }
)

foreach ($evalCandidate in $evalCandidates) {
    try {
        Write-Summary ('evalAttempt=' + $evalCandidate.Name)
        $selectedEval = Install-EvalPackage -name $evalCandidate.Name -repo $evalCandidate.Repo -tag $evalCandidate.Tag -fvScale $evalCandidate.FvScale
        Write-Summary ('evalSelected=' + $selectedEval.Name)
        Write-Summary ('evalRepo=' + $selectedEval.Repo)
        Write-Summary ('evalTag=' + $selectedEval.Tag)
        Write-Summary ('evalAsset=' + $selectedEval.AssetName)
        Write-Summary ('evalFvScale=' + $selectedEval.FvScale)
        break
    }
    catch {
        Write-Summary ('evalFailed=' + $evalCandidate.Name + ' : ' + $_.Exception.Message)
    }
}

if (-not $selectedEval) {
    Write-Summary 'result=No evaluation package could be installed.'
    exit 1
}

Update-BridgeConfigFvScale -fvScale $selectedEval.FvScale
Write-Summary ('configUpdatedFvScale=' + $selectedEval.FvScale)

$engineArchive = $EngineArchivePath
if (-not $engineArchive) {
    $engineDownload = Save-ReleaseAsset -repo 'yaneurao/YaneuraOu' -tag $EngineReleaseTag -patterns @('*win64*all.7z', '*win*all.7z', '*.7z', '*.zip') -label 'engine'
    $engineArchive = $engineDownload.ArchivePath
    Write-Summary ('engineAsset=' + $engineDownload.AssetName)
}
else {
    Write-Summary ('usingExistingEngineArchive=' + $engineArchive)
}

$engineExtractDir = Join-Path $downloadsDir 'engine_extract'
Expand-ArchiveAny -archive $engineArchive -destination $engineExtractDir -label 'engine'
$candidates = Get-CandidateExecutables -searchRoot $engineExtractDir

Write-Summary 'candidate order:'
foreach ($c in $candidates) {
    Write-Summary ('  ' + $c.Name + ' score=' + $c.Score)
}

$selected = $null
foreach ($c in $candidates) {
    $probeLog = New-LogPath ('probe_' + $c.Name)
    Write-Summary ('probing=' + $c.Name)
    $result = Test-CandidateExe -candidatePath $c.FullName -evalDirAbs $evalDir -fvScale $selectedEval.FvScale -logPath $probeLog
    Write-Summary ('  usiok=' + $result.Usiok + ' readyok=' + $result.Readyok + ' thinkok=' + $result.Thinkok + ' bestmove=' + $result.Bestmove + ' exitCode=' + $result.ExitCode)
    if ($result.Success) {
        $selected = $c
        break
    }
}

if (-not $selected) {
    Write-Summary 'selected=NONE'
    Write-Summary 'result=No halfKP256 candidate from the official archive passed usi/isready/think with the installed eval.'
    exit 1
}

$currentExe = Join-Path $engineDir 'yaneuraou.exe'
$backupExe = Join-Path $engineDir ('yaneuraou_backup_' + $runId + '.exe')
$copyLog = New-LogPath 'copy_selected'
if (Test-Path -LiteralPath $currentExe) {
    Copy-Item -Force -LiteralPath $currentExe -Destination $backupExe
    Write-StepInfo $copyLog ('backup=' + $backupExe)
}
Copy-Item -Force -LiteralPath $selected.FullName -Destination $currentExe
Write-StepInfo $copyLog ('installed=' + $currentExe)
Write-StepInfo $copyLog ('source=' + $selected.FullName)

$finalProbeLog = New-LogPath 'final_probe_installed'
$finalResult = Test-CandidateExe -candidatePath $currentExe -evalDirAbs $evalDir -fvScale $selectedEval.FvScale -logPath $finalProbeLog
Write-Summary ('selected=' + $selected.Name)
Write-Summary ('backup=' + $backupExe)
Write-Summary ('final usiok=' + $finalResult.Usiok)
Write-Summary ('final readyok=' + $finalResult.Readyok)
Write-Summary ('final thinkok=' + $finalResult.Thinkok)
Write-Summary ('final bestmove=' + $finalResult.Bestmove)
Write-Summary ('final exitCode=' + $finalResult.ExitCode)

if (-not $finalResult.Success) {
    Write-Summary 'finalProbe=FAILED after install'
    exit 1
}

Write-Summary 'finalProbe=OK'
@(
    'verified=OK',
    'scriptVersion=' + $scriptVersion,
    'runId=' + $runId,
    'selected=' + $selected.Name,
    'eval=' + $selectedEval.Name,
    'fvScale=' + $selectedEval.FvScale,
    'engineExe=' + $currentExe
) | Set-Content -LiteralPath $verifyPath -Encoding ASCII
Write-Summary ('verifyFile=' + $verifyPath)
Write-Summary 'next=START_LOCAL_YANEOURAOU_BRIDGE.cmd will reuse this verified engine and eval without re-download.'
exit 0
