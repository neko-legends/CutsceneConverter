param(
	[switch]$SmokeTest,
	[switch]$InstallFfmpeg
)

Set-StrictMode -Version 2.0

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ConfigPath = Join-Path $script:AppDir "config.json"
$script:DefaultOutputDir = "D:\NekoLegends-Universe\games\neko-legends-awakening\godot\assets\video\cutscenes"
$script:PortableFfmpegPath = "D:\Tools\ffmpeg\bin\ffmpeg.exe"
$script:FfmpegDownloadUrl = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
$script:FfmpegPath = ""
$script:CancelRequested = $false
$script:ActiveConversionProcesses = New-Object System.Collections.ArrayList

function Write-Log {
	param(
		[string]$Message,
		[System.Windows.Forms.TextBox]$LogBox = $null
	)

	$line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message
	if ($LogBox -ne $null) {
		$LogBox.AppendText($line + [Environment]::NewLine)
		$LogBox.SelectionStart = $LogBox.TextLength
		$LogBox.ScrollToCaret()
		[System.Windows.Forms.Application]::DoEvents()
	} else {
		Write-Host $line
	}
}

function Test-CancelRequested {
	return ($script:CancelRequested -eq $true)
}

function Register-ActiveConversionProcess {
	param([object]$Process)

	if ($null -eq $Process) {
		return
	}

	[void]$script:ActiveConversionProcesses.Add($Process)
}

function Unregister-ActiveConversionProcess {
	param([object]$Process)

	if ($null -eq $Process -or -not ($Process.PSObject.Properties.Name -contains "Id")) {
		return
	}

	for ($index = ($script:ActiveConversionProcesses.Count - 1); $index -ge 0; $index--) {
		$current = $script:ActiveConversionProcesses[$index]
		if ($null -eq $current) {
			$script:ActiveConversionProcesses.RemoveAt($index)
			continue
		}
		if ($current.Id -eq $Process.Id) {
			$script:ActiveConversionProcesses.RemoveAt($index)
		}
	}
}

function Stop-ActiveConversionProcesses {
	foreach ($process in @($script:ActiveConversionProcesses)) {
		if ($null -eq $process) {
			continue
		}
		try {
			if (-not $process.HasExited) {
				$process.Kill()
				$process.WaitForExit(2000) | Out-Null
			}
		} catch {
		}
	}
}

function Remove-PartialOutput {
	param(
		[string]$OutputPath,
		[System.Windows.Forms.TextBox]$LogBox = $null
	)

	if ([string]::IsNullOrWhiteSpace($OutputPath) -or -not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
		return
	}

	try {
		Remove-Item -LiteralPath $OutputPath -Force -ErrorAction Stop
		Write-Log "Removed canceled partial output: $OutputPath" $LogBox
	} catch {
	}
}

function Remove-FileWithRetry {
	param(
		[string]$Path,
		[int]$Attempts = 8
	)

	if ([string]::IsNullOrWhiteSpace($Path)) {
		return $true
	}

	for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
		if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
			return $true
		}
		try {
			Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
			return $true
		} catch {
			Start-Sleep -Milliseconds 250
		}
	}

	return (-not (Test-Path -LiteralPath $Path -PathType Leaf))
}

function New-ConversionOutcome {
	param(
		[ValidateSet("success", "failed", "canceled")]
		[string]$Status
	)

	return [pscustomobject]@{
		Status = $Status
	}
}

function Read-Config {
	if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
		return @{}
	}

	try {
		$json = Get-Content -LiteralPath $script:ConfigPath -Raw
		if ([string]::IsNullOrWhiteSpace($json)) {
			return @{}
		}
		return ConvertFrom-Json -InputObject $json
	} catch {
		return @{}
	}
}

function Save-Config {
	param(
		[string]$FfmpegPath,
		[string]$OutputDir,
		[string]$SourcePath = "",
		[string]$Quality = "Balanced",
		[bool]$Downscale1080 = $false,
		[bool]$IncludeSubfolders = $false,
		[bool]$Overwrite = $true,
		[int]$ParallelJobs = 1,
		[double]$TrimStartSeconds = 0.0,
		[double]$TrimSeconds = 0.0,
		[string]$Mp4Codec = "H264",
		[string]$OutputResolution = ""
	)

	$normalizedResolution = Normalize-OutputResolution -Value $OutputResolution
	if ([string]::IsNullOrWhiteSpace($normalizedResolution)) {
		$normalizedResolution = $(if ($Downscale1080) { "1920x1080" } else { "(native)" })
	}

	$config = [ordered]@{
		ffmpegPath = $FfmpegPath
		outputDir = $OutputDir
		sourcePath = $SourcePath
		quality = $Quality
		downscale1080 = ($normalizedResolution -eq "1920x1080")
		outputResolution = $normalizedResolution
		includeSubfolders = $IncludeSubfolders
		overwrite = $Overwrite
		parallelJobs = $ParallelJobs
		trimStartSeconds = $TrimStartSeconds
		trimSeconds = $TrimSeconds
		mp4Codec = (Normalize-Mp4Codec -Value $Mp4Codec)
	}
	$config | ConvertTo-Json | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
}

function Find-Ffmpeg {
	$config = Read-Config
	if ($config -ne $null -and $config.PSObject.Properties.Name -contains "ffmpegPath") {
		$configPath = [string]$config.ffmpegPath
		if (-not [string]::IsNullOrWhiteSpace($configPath) -and (Test-Path -LiteralPath $configPath)) {
			return $configPath
		}
	}

	if (Test-Path -LiteralPath $script:PortableFfmpegPath) {
		return $script:PortableFfmpegPath
	}

	$localMatch = Get-ChildItem -Path "D:\Tools" -Recurse -Filter "ffmpeg.exe" -ErrorAction SilentlyContinue |
		Select-Object -First 1 -ExpandProperty FullName
	if (-not [string]::IsNullOrWhiteSpace($localMatch)) {
		return $localMatch
	}

	$command = Get-Command ffmpeg -ErrorAction SilentlyContinue
	if ($command -ne $null) {
		return $command.Source
	}

	return ""
}

function Get-ConfiguredOutputDir {
	$config = Read-Config
	if ($config -ne $null -and $config.PSObject.Properties.Name -contains "outputDir") {
		$outputDir = [string]$config.outputDir
		if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
			return $outputDir
		}
	}
	return $script:DefaultOutputDir
}

function Get-ConfiguredString {
	param(
		[string]$Name,
		[string]$DefaultValue = ""
	)

	$config = Read-Config
	if ($config -ne $null -and $config.PSObject.Properties.Name -contains $Name) {
		$value = [string]$config.$Name
		if (-not [string]::IsNullOrWhiteSpace($value)) {
			return $value
		}
	}
	return $DefaultValue
}

function Get-ConfiguredBool {
	param(
		[string]$Name,
		[bool]$DefaultValue
	)

	$config = Read-Config
	if ($config -ne $null -and $config.PSObject.Properties.Name -contains $Name) {
		return [bool]$config.$Name
	}
	return $DefaultValue
}

function Get-ConfiguredInt {
	param(
		[string]$Name,
		[int]$DefaultValue,
		[int]$MinValue,
		[int]$MaxValue
	)

	$config = Read-Config
	$value = $DefaultValue
	if ($config -ne $null -and $config.PSObject.Properties.Name -contains $Name) {
		[void][int]::TryParse(([string]$config.$Name), [ref]$value)
	}

	return [Math]::Max($MinValue, [Math]::Min($MaxValue, $value))
}

function Get-ConfiguredDouble {
	param(
		[string]$Name,
		[double]$DefaultValue,
		[double]$MinValue,
		[double]$MaxValue
	)

	$config = Read-Config
	$value = $DefaultValue
	if ($config -ne $null -and $config.PSObject.Properties.Name -contains $Name) {
		[void][double]::TryParse(([string]$config.$Name), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)
	}

	return [Math]::Max($MinValue, [Math]::Min($MaxValue, $value))
}

function Format-SecondsOption {
	param([double]$Seconds)

	return $Seconds.ToString("0.#", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-TrimOptionValues {
	$options = @()
	for ($halfSeconds = 0; $halfSeconds -le 20; $halfSeconds++) {
		$options += (Format-SecondsOption -Seconds ([double]$halfSeconds / 2.0))
	}
	return $options
}

function Get-ConfiguredQuality {
	$quality = Get-ConfiguredString -Name "quality" -DefaultValue "Balanced"
	if (@("Balanced", "High", "Smaller") -contains $quality) {
		return $quality
	}
	return "Balanced"
}

function Normalize-Mp4Codec {
	param([string]$Value)

	if (-not [string]::IsNullOrWhiteSpace($Value) -and $Value -match "265|hevc|h\.265") {
		return "H265"
	}
	return "H264"
}

function Get-ConfiguredMp4Codec {
	return (Normalize-Mp4Codec -Value (Get-ConfiguredString -Name "mp4Codec" -DefaultValue "H264"))
}

function Normalize-OutputResolution {
	param([string]$Value)

	if ([string]::IsNullOrWhiteSpace($Value)) {
		return ""
	}

	$cleanValue = $Value.Trim().ToLowerInvariant()
	switch -Regex ($cleanValue) {
		"native" {
			return "(native)"
		}
		"1920|1080" {
			return "1920x1080"
		}
		"1444" {
			return "1444p"
		}
		"2160|4k|uhd" {
			return "2160p"
		}
		default {
			return ""
		}
	}
}

function Get-ConfiguredOutputResolution {
	$configValue = Normalize-OutputResolution -Value (Get-ConfiguredString -Name "outputResolution" -DefaultValue "")
	if (-not [string]::IsNullOrWhiteSpace($configValue)) {
		return $configValue
	}

	if (Get-ConfiguredBool -Name "downscale1080" -DefaultValue $false) {
		return "1920x1080"
	}
	return "(native)"
}

function Get-ResolutionScaleFilter {
	param([string]$OutputResolution)

	switch (Normalize-OutputResolution -Value $OutputResolution) {
		"1920x1080" {
			return "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p"
		}
		"1444p" {
			return "scale=2568:1444:force_original_aspect_ratio=decrease,pad=2568:1444:(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p"
		}
		"2160p" {
			return "scale=3840:2160:force_original_aspect_ratio=decrease,pad=3840:2160:(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p"
		}
		default {
			return ""
		}
	}
}

function Get-MaxParallelJobs {
	return [Math]::Max(1, [Math]::Min(16, [Environment]::ProcessorCount))
}

function Get-ConfiguredParallelJobs {
	return Get-ConfiguredInt -Name "parallelJobs" -DefaultValue 2 -MinValue 1 -MaxValue (Get-MaxParallelJobs)
}

function Get-ConfiguredTrimSeconds {
	return Get-ConfiguredDouble -Name "trimSeconds" -DefaultValue 0.0 -MinValue 0.0 -MaxValue 10.0
}

function Get-ConfiguredTrimStartSeconds {
	return Get-ConfiguredDouble -Name "trimStartSeconds" -DefaultValue 0.0 -MinValue 0.0 -MaxValue 10.0
}

function Install-PortableFfmpeg {
	param(
		[System.Windows.Forms.TextBox]$LogBox = $null
	)

	$targetBin = Split-Path -Parent $script:PortableFfmpegPath
	if (Test-Path -LiteralPath $script:PortableFfmpegPath) {
		Write-Log "FFmpeg already exists at $script:PortableFfmpegPath" $LogBox
		$script:FfmpegPath = $script:PortableFfmpegPath
		return $true
	}

	$downloadDir = Join-Path $script:AppDir "downloads"
	$zipPath = Join-Path $downloadDir "ffmpeg-release-essentials.zip"
	$extractDir = Join-Path $downloadDir "ffmpeg_extract"

	New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null
	New-Item -ItemType Directory -Force -Path $targetBin | Out-Null

	try {
		Write-Log "Downloading FFmpeg essentials build..." $LogBox
		Invoke-WebRequest -Uri $script:FfmpegDownloadUrl -OutFile $zipPath -UseBasicParsing

		if (Test-Path -LiteralPath $extractDir) {
			Remove-Item -LiteralPath $extractDir -Recurse -Force
		}
		New-Item -ItemType Directory -Force -Path $extractDir | Out-Null

		Write-Log "Extracting FFmpeg..." $LogBox
		Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

		$extractedFfmpeg = Get-ChildItem -Path $extractDir -Recurse -Filter "ffmpeg.exe" |
			Select-Object -First 1 -ExpandProperty FullName
		if ([string]::IsNullOrWhiteSpace($extractedFfmpeg)) {
			Write-Log "Could not find ffmpeg.exe in the downloaded ZIP." $LogBox
			return $false
		}

		$extractedBin = Split-Path -Parent $extractedFfmpeg
		Copy-Item -LiteralPath (Join-Path $extractedBin "ffmpeg.exe") -Destination $targetBin -Force
		if (Test-Path -LiteralPath (Join-Path $extractedBin "ffprobe.exe")) {
			Copy-Item -LiteralPath (Join-Path $extractedBin "ffprobe.exe") -Destination $targetBin -Force
		}
		if (Test-Path -LiteralPath (Join-Path $extractedBin "ffplay.exe")) {
			Copy-Item -LiteralPath (Join-Path $extractedBin "ffplay.exe") -Destination $targetBin -Force
		}

		$script:FfmpegPath = $script:PortableFfmpegPath
		Write-Log "Installed FFmpeg to $targetBin" $LogBox
		Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
		Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
		return $true
	} catch {
		Write-Log ("FFmpeg install failed: " + $_.Exception.Message) $LogBox
		return $false
	}
}

function Quote-Arg {
	param([string]$Value)
	return '"' + $Value.Replace('"', '\"') + '"'
}

function Get-FfprobePath {
	if (-not [string]::IsNullOrWhiteSpace($script:FfmpegPath)) {
		$ffmpegDir = Split-Path -Parent $script:FfmpegPath
		$ffprobePath = Join-Path $ffmpegDir "ffprobe.exe"
		if (Test-Path -LiteralPath $ffprobePath) {
			return $ffprobePath
		}
	}

	$command = Get-Command ffprobe -ErrorAction SilentlyContinue
	if ($command -ne $null) {
		return $command.Source
	}

	return ""
}

function Get-VideoDurationSeconds {
	param([string]$InputPath)

	$ffprobePath = Get-FfprobePath
	if ([string]::IsNullOrWhiteSpace($ffprobePath)) {
		return 0.0
	}

	try {
		$output = @(& $ffprobePath -v error -show_entries format=duration -of "default=noprint_wrappers=1:nokey=1" $InputPath 2>$null)
		if ($LASTEXITCODE -ne 0 -or $output.Count -eq 0) {
			return 0.0
		}

		$duration = 0.0
		$durationText = [string]$output[0]
		if ([double]::TryParse($durationText, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$duration)) {
			return $duration
		}
	} catch {
		return 0.0
	}

	return 0.0
}

function Test-CompletedOutputLooksValid {
	param(
		[string]$OutputPath,
		[double]$ExpectedDurationSeconds = 0.0
	)

	if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
		return $false
	}

	try {
		$item = Get-Item -LiteralPath $OutputPath -ErrorAction Stop
		if ($item.Length -le 4096) {
			return $false
		}

		$outputDuration = Get-VideoDurationSeconds -InputPath $OutputPath
		if ($outputDuration -le 0.0) {
			return $false
		}

		if ($ExpectedDurationSeconds -le 0.0) {
			return $true
		}

		$minimumDuration = [Math]::Max(0.25, ($ExpectedDurationSeconds - 1.0))
		return ($outputDuration -ge $minimumDuration)
	} catch {
		return $false
	}
}

function Test-CombinedOutputLooksValid {
	param(
		[string]$OutputPath,
		[double]$ExpectedDurationSeconds
	)

	if (-not (Test-CompletedOutputLooksValid -OutputPath $OutputPath)) {
		return $false
	}

	if ($ExpectedDurationSeconds -le 0.0) {
		return $true
	}

	$outputDuration = Get-VideoDurationSeconds -InputPath $OutputPath
	if ($outputDuration -le 0.0) {
		return $false
	}

	$minimumDuration = [Math]::Max(0.25, ($ExpectedDurationSeconds * 0.85))
	return ($outputDuration -ge $minimumDuration)
}

function Get-EffectiveTargetDurationSeconds {
	param(
		[double]$SourceDurationSeconds,
		[double]$TrimStartSeconds = 0.0,
		[double]$TrimSeconds = 0.0
	)

	if ($TrimStartSeconds -gt 0.0 -or $TrimSeconds -gt 0.0) {
		if ($SourceDurationSeconds -gt 0.0) {
			return [Math]::Max(0.0, ($SourceDurationSeconds - $TrimStartSeconds - $TrimSeconds))
		}
		return 0.0
	}

	return $SourceDurationSeconds
}

function Convert-FfmpegProgressTimeToSeconds {
	param([string]$TimeText)

	if ([string]::IsNullOrWhiteSpace($TimeText)) {
		return 0.0
	}

	$parts = @($TimeText.Split(":"))
	if ($parts.Count -ne 3) {
		return 0.0
	}

	$hours = 0
	$minutes = 0
	$seconds = 0.0
	if (-not [int]::TryParse($parts[0], [ref]$hours)) {
		return 0.0
	}
	if (-not [int]::TryParse($parts[1], [ref]$minutes)) {
		return 0.0
	}
	if (-not [double]::TryParse($parts[2], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$seconds)) {
		return 0.0
	}

	return (($hours * 3600.0) + ($minutes * 60.0) + $seconds)
}

function Read-FfmpegProgressSeconds {
	param([string]$ProgressPath)

	if ([string]::IsNullOrWhiteSpace($ProgressPath) -or -not (Test-Path -LiteralPath $ProgressPath)) {
		return 0.0
	}

	try {
		$text = Get-Content -LiteralPath $ProgressPath -Raw -ErrorAction SilentlyContinue
		if ([string]::IsNullOrWhiteSpace($text)) {
			return 0.0
		}

		$timeMatches = [regex]::Matches($text, "(?m)^out_time=(.+)$")
		if ($timeMatches.Count -gt 0) {
			$timeText = $timeMatches[$timeMatches.Count - 1].Groups[1].Value.Trim()
			return (Convert-FfmpegProgressTimeToSeconds -TimeText $timeText)
		}

		$usMatches = [regex]::Matches($text, "(?m)^out_time_us=(\d+)$")
		if ($usMatches.Count -gt 0) {
			$microseconds = 0.0
			$microsecondText = $usMatches[$usMatches.Count - 1].Groups[1].Value
			if ([double]::TryParse($microsecondText, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$microseconds)) {
				return ($microseconds / 1000000.0)
			}
		}
	} catch {
		return 0.0
	}

	return 0.0
}

function Set-ConversionProgress {
	param(
		[System.Windows.Forms.ProgressBar]$ProgressBar = $null,
		[System.Windows.Forms.Label]$StatusLabel = $null,
		[int]$Percent,
		[string]$Message
	)

	$boundedPercent = [Math]::Max(0, [Math]::Min(100, $Percent))
	if ($ProgressBar -ne $null) {
		$ProgressBar.Value = $boundedPercent
	}
	if ($StatusLabel -ne $null) {
		$StatusLabel.Text = $Message
	}
	[System.Windows.Forms.Application]::DoEvents()
}

function Build-FfmpegArguments {
	param(
		[string]$InputPath,
		[string]$OutputPath,
		[string]$Quality,
		[bool]$Downscale1080,
		[bool]$Overwrite,
		[double]$TrimStartSeconds = 0.0,
		[double]$TargetDurationSeconds = 0.0,
		[string]$ProgressPath = "",
		[ValidateSet("WebmVp9", "Ogv", "Mp4Copy")]
		[string]$OutputKind = "WebmVp9",
		[ValidateSet("H264", "H265")]
		[string]$Mp4Codec = "H264",
		[string]$OutputResolution = ""
	)

	$args = @(
		"-hide_banner",
		"-nostats",
		"-loglevel", "error"
	)

	if (-not [string]::IsNullOrWhiteSpace($ProgressPath)) {
		$args += @("-progress", (Quote-Arg $ProgressPath))
	}

	$args += @(
		$(if ($Overwrite) { "-y" } else { "-n" }),
		"-i", (Quote-Arg $InputPath)
	)

	if ($TrimStartSeconds -gt 0.0) {
		$args += @("-ss", $TrimStartSeconds.ToString([System.Globalization.CultureInfo]::InvariantCulture))
	}

	if ($TargetDurationSeconds -gt 0.0) {
		$args += @("-t", $TargetDurationSeconds.ToString([System.Globalization.CultureInfo]::InvariantCulture))
	}

	$scaleFilter = Get-ResolutionScaleFilter -OutputResolution $(if ([string]::IsNullOrWhiteSpace($OutputResolution)) { $(if ($Downscale1080) { "1920x1080" } else { "(native)" }) } else { $OutputResolution })

	if ($OutputKind -eq "Mp4Copy") {
		$args += @(
			"-map", "0:v:0",
			"-map", "0:a?"
		)

		$mp4Crf = 20
		$mp4AudioBitrate = "128k"
		switch ($Quality) {
			"High" {
				$mp4Crf = 18
				$mp4AudioBitrate = "160k"
			}
			"Smaller" {
				$mp4Crf = 24
				$mp4AudioBitrate = "96k"
			}
			default {
				$mp4Crf = 20
				$mp4AudioBitrate = "128k"
			}
		}

		if (-not [string]::IsNullOrWhiteSpace($scaleFilter)) {
			$args += @(
				"-vf",
				(Quote-Arg $scaleFilter)
			)
		} else {
			$args += @("-pix_fmt", "yuv420p")
		}

		if ($Mp4Codec -eq "H265") {
			$args += @(
				"-c:v", "libx265",
				"-preset", "fast",
				"-crf", ([Math]::Min(30, $mp4Crf + 4)).ToString(),
				"-tag:v", "hvc1"
			)
		} else {
			$args += @(
				"-c:v", "libx264",
				"-preset", "veryfast",
				"-crf", $mp4Crf.ToString()
			)
		}

		$args += @(
			"-c:a", "aac",
			"-b:a", $mp4AudioBitrate,
			"-movflags", "+faststart",
			(Quote-Arg $OutputPath)
		)
		return ($args -join " ")
	}

	$args += @(
		"-map", "0:v:0",
		"-map", "0:a?"
	)

	if (-not [string]::IsNullOrWhiteSpace($scaleFilter)) {
		$args += @(
			"-vf",
			(Quote-Arg $scaleFilter)
		)
	}

	if ($OutputKind -eq "Ogv") {
		$qv = 6
		$qa = 6
		switch ($Quality) {
			"High" {
				$qv = 7
				$qa = 7
			}
			"Smaller" {
				$qv = 5
				$qa = 5
			}
			default {
				$qv = 6
				$qa = 6
			}
		}

		$args += @(
			"-c:v", "libtheora",
			"-q:v", $qv.ToString(),
			"-c:a", "libvorbis",
			"-q:a", $qa.ToString(),
			(Quote-Arg $OutputPath)
		)
		return ($args -join " ")
	}

	$crf = 32
	$cpuUsed = 4
	$audioBitrate = "96k"
	switch ($Quality) {
		"High" {
			$crf = 28
			$cpuUsed = 3
			$audioBitrate = "128k"
		}
		"Smaller" {
			$crf = 36
			$cpuUsed = 5
			$audioBitrate = "80k"
		}
		default {
			$crf = 32
			$cpuUsed = 4
			$audioBitrate = "96k"
		}
	}

	$args += @(
		"-c:v", "libvpx-vp9",
		"-b:v", "0",
		"-crf", $crf.ToString(),
		"-deadline", "good",
		"-cpu-used", $cpuUsed.ToString(),
		"-row-mt", "1",
		"-tile-columns", "2",
		"-c:a", "libopus",
		"-b:a", $audioBitrate,
		(Quote-Arg $OutputPath)
	)

	return ($args -join " ")
}

function Get-VideoOutputPath {
	param(
		[System.IO.FileInfo]$Video,
		[string]$OutputDir,
		[ValidateSet("WebmVp9", "Ogv", "Mp4Copy")]
		[string]$OutputKind
	)

	$extension = ".webm"
	if ($OutputKind -eq "Mp4Copy") {
		$extension = ".mp4"
	} elseif ($OutputKind -eq "Ogv") {
		$extension = ".ogv"
	}
	$outputPath = Join-Path $OutputDir ($Video.BaseName + $extension)
	if ($OutputKind -eq "Mp4Copy") {
		try {
			$inputFullPath = [System.IO.Path]::GetFullPath($Video.FullName)
			$outputFullPath = [System.IO.Path]::GetFullPath($outputPath)
			if ([string]::Equals($inputFullPath, $outputFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
				$outputPath = Join-Path $OutputDir ($Video.BaseName + "_export.mp4")
			}
		} catch {
		}
	}
	return $outputPath
}

function Get-JobActionLabel {
	param(
		[ValidateSet("WebmVp9", "Ogv", "Mp4Copy")]
		[string]$OutputKind
	)

	if ($OutputKind -eq "Mp4Copy") {
		return "Exporting MP4"
	}
	if ($OutputKind -eq "Ogv") {
		return "Converting OGV"
	}
	return "Converting WebM VP9"
}

function Convert-OneVideo {
	param(
		[string]$InputPath,
		[string]$OutputPath,
		[string]$Quality,
		[bool]$Downscale1080,
		[bool]$Overwrite,
		[ValidateSet("WebmVp9", "Ogv", "Mp4Copy")]
		[string]$OutputKind = "WebmVp9",
		[ValidateSet("H264", "H265")]
		[string]$Mp4Codec = "H264",
		[string]$OutputResolution = "",
		[double]$TrimStartSeconds = 0.0,
		[double]$TrimSeconds = 0.0,
		[System.Windows.Forms.TextBox]$LogBox,
		[System.Windows.Forms.ProgressBar]$ProgressBar = $null,
		[System.Windows.Forms.Label]$ProgressLabel = $null,
		[int]$FileIndex = 1,
		[int]$FileCount = 1
	)

	if (Test-CancelRequested) {
		return (New-ConversionOutcome -Status "canceled")
	}

	if (-not (Test-Path -LiteralPath $InputPath)) {
		Write-Log "Missing input: $InputPath" $LogBox
		return (New-ConversionOutcome -Status "failed")
	}

	$outputDir = Split-Path -Parent $OutputPath
	New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

	if ((Test-Path -LiteralPath $OutputPath) -and -not $Overwrite) {
		Write-Log "Skipping existing output: $OutputPath" $LogBox
		$skippedPercent = [int][Math]::Floor(($FileIndex / [Math]::Max(1, $FileCount)) * 100)
		Set-ConversionProgress -ProgressBar $ProgressBar -StatusLabel $ProgressLabel -Percent $skippedPercent -Message "Skipped ${FileIndex} of ${FileCount}: $(Split-Path -Leaf $InputPath)"
		return (New-ConversionOutcome -Status "success")
	}

	$sourceDurationSeconds = Get-VideoDurationSeconds -InputPath $InputPath
	if (($TrimStartSeconds -gt 0.0 -or $TrimSeconds -gt 0.0) -and $sourceDurationSeconds -le 0.0) {
		Write-Log "Could not determine source duration, so trim settings could not be applied." $LogBox
		return (New-ConversionOutcome -Status "failed")
	}
	$durationSeconds = Get-EffectiveTargetDurationSeconds -SourceDurationSeconds $sourceDurationSeconds -TrimStartSeconds $TrimStartSeconds -TrimSeconds $TrimSeconds
	if (($TrimStartSeconds -gt 0.0 -or $TrimSeconds -gt 0.0) -and $durationSeconds -le 0.0) {
		Write-Log "Trim settings are too large for this file." $LogBox
		return (New-ConversionOutcome -Status "failed")
	}
	$tempProgress = [System.IO.Path]::GetTempFileName()
	$args = Build-FfmpegArguments -InputPath $InputPath -OutputPath $OutputPath -Quality $Quality -Downscale1080 $Downscale1080 -Overwrite $Overwrite -TrimStartSeconds $TrimStartSeconds -TargetDurationSeconds $durationSeconds -ProgressPath $tempProgress -OutputKind $OutputKind -Mp4Codec $Mp4Codec -OutputResolution $OutputResolution
	$tempOut = [System.IO.Path]::GetTempFileName()
	$tempErr = [System.IO.Path]::GetTempFileName()
	$fileName = Split-Path -Leaf $InputPath
	$totalFiles = [Math]::Max(1, $FileCount)
	$baseOverallPercent = [int][Math]::Floor((($FileIndex - 1) / $totalFiles) * 100)
	$process = $null
	$actionLabel = Get-JobActionLabel -OutputKind $OutputKind

	Write-Log "${actionLabel}: $InputPath" $LogBox
	Write-Log "Output: $OutputPath" $LogBox
	Set-ConversionProgress -ProgressBar $ProgressBar -StatusLabel $ProgressLabel -Percent $baseOverallPercent -Message "${actionLabel} ${FileIndex} of ${FileCount}: $fileName - 0%"

	try {
		$process = Start-Process -FilePath $script:FfmpegPath -ArgumentList $args -NoNewWindow -PassThru -RedirectStandardOutput $tempOut -RedirectStandardError $tempErr
		Register-ActiveConversionProcess -Process $process
		while (-not $process.HasExited) {
			if (Test-CancelRequested) {
				try {
					if (-not $process.HasExited) {
						$process.Kill()
					}
				} catch {
				}
			}
			if ($durationSeconds -gt 0) {
				$elapsedSeconds = Read-FfmpegProgressSeconds -ProgressPath $tempProgress
				$filePercent = [int][Math]::Floor([Math]::Min(100.0, (($elapsedSeconds / $durationSeconds) * 100.0)))
				$overallPercent = [int][Math]::Floor(((($FileIndex - 1) + ($filePercent / 100.0)) / $totalFiles) * 100.0)
				Set-ConversionProgress -ProgressBar $ProgressBar -StatusLabel $ProgressLabel -Percent $overallPercent -Message "${actionLabel} ${FileIndex} of ${FileCount}: $fileName - $filePercent%"
			}
			[System.Windows.Forms.Application]::DoEvents()
			Start-Sleep -Milliseconds 250
		}
		$process.WaitForExit()

		$errorText = ""
		if (Test-Path -LiteralPath $tempErr) {
			$errorText = Get-Content -LiteralPath $tempErr -Raw -ErrorAction SilentlyContinue
		}

		if (Test-CancelRequested) {
			Remove-PartialOutput -OutputPath $OutputPath -LogBox $LogBox
			Write-Log "Canceled: $InputPath" $LogBox
			return (New-ConversionOutcome -Status "canceled")
		}

		if ($process.ExitCode -ne 0) {
			Write-Log "FFmpeg failed with exit code $($process.ExitCode)." $LogBox
			if (-not [string]::IsNullOrWhiteSpace($errorText)) {
				$lastLines = ($errorText -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 8
				foreach ($line in $lastLines) {
					Write-Log $line $LogBox
				}
			}
			if (Test-CompletedOutputLooksValid -OutputPath $OutputPath -ExpectedDurationSeconds $durationSeconds) {
				Write-Log "Readable output was produced anyway; treating this as success." $LogBox
				$completePercent = [int][Math]::Floor(($FileIndex / $totalFiles) * 100.0)
				Set-ConversionProgress -ProgressBar $ProgressBar -StatusLabel $ProgressLabel -Percent $completePercent -Message "Completed ${FileIndex} of ${FileCount}: $fileName"
				return (New-ConversionOutcome -Status "success")
			}
			return (New-ConversionOutcome -Status "failed")
		}

		Write-Log "Done: $OutputPath" $LogBox
		$completePercent = [int][Math]::Floor(($FileIndex / $totalFiles) * 100.0)
		Set-ConversionProgress -ProgressBar $ProgressBar -StatusLabel $ProgressLabel -Percent $completePercent -Message "Completed ${FileIndex} of ${FileCount}: $fileName"
		return (New-ConversionOutcome -Status "success")
	} finally {
		Unregister-ActiveConversionProcess -Process $process
		Remove-Item -LiteralPath $tempProgress -Force -ErrorAction SilentlyContinue
		Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue
		Remove-Item -LiteralPath $tempErr -Force -ErrorAction SilentlyContinue
	}
}

function Start-ParallelConversionTask {
	param(
		[System.IO.FileInfo]$Video,
		[string]$OutputPath,
		[string]$Quality,
		[bool]$Downscale1080,
		[bool]$Overwrite,
		[ValidateSet("WebmVp9", "Ogv", "Mp4Copy")]
		[string]$OutputKind = "WebmVp9",
		[ValidateSet("H264", "H265")]
		[string]$Mp4Codec = "H264",
		[string]$OutputResolution = "",
		[double]$TrimStartSeconds = 0.0,
		[double]$TrimSeconds = 0.0,
		[System.Windows.Forms.TextBox]$LogBox,
		[int]$FileIndex,
		[int]$FileCount
	)

	$outputDir = Split-Path -Parent $OutputPath
	New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

	$tempProgress = [System.IO.Path]::GetTempFileName()
	$tempOut = [System.IO.Path]::GetTempFileName()
	$tempErr = [System.IO.Path]::GetTempFileName()
	$sourceDurationSeconds = Get-VideoDurationSeconds -InputPath $Video.FullName
	if (($TrimStartSeconds -gt 0.0 -or $TrimSeconds -gt 0.0) -and $sourceDurationSeconds -le 0.0) {
		Write-Log "Could not determine source duration for $($Video.FullName), so trim settings could not be applied." $LogBox
		Remove-Item -LiteralPath $tempProgress -Force -ErrorAction SilentlyContinue
		Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue
		Remove-Item -LiteralPath $tempErr -Force -ErrorAction SilentlyContinue
		return $null
	}

	$targetDurationSeconds = Get-EffectiveTargetDurationSeconds -SourceDurationSeconds $sourceDurationSeconds -TrimStartSeconds $TrimStartSeconds -TrimSeconds $TrimSeconds
	if (($TrimStartSeconds -gt 0.0 -or $TrimSeconds -gt 0.0) -and $targetDurationSeconds -le 0.0) {
		Write-Log "Trim settings are too large for $($Video.FullName)." $LogBox
		Remove-Item -LiteralPath $tempProgress -Force -ErrorAction SilentlyContinue
		Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue
		Remove-Item -LiteralPath $tempErr -Force -ErrorAction SilentlyContinue
		return $null
	}

	$args = Build-FfmpegArguments -InputPath $Video.FullName -OutputPath $OutputPath -Quality $Quality -Downscale1080 $Downscale1080 -Overwrite $Overwrite -TrimStartSeconds $TrimStartSeconds -TargetDurationSeconds $targetDurationSeconds -ProgressPath $tempProgress -OutputKind $OutputKind -Mp4Codec $Mp4Codec -OutputResolution $OutputResolution
	$actionLabel = Get-JobActionLabel -OutputKind $OutputKind

	Write-Log "${actionLabel}: $($Video.FullName)" $LogBox
	Write-Log "Output: $OutputPath" $LogBox

	try {
		$process = Start-Process -FilePath $script:FfmpegPath -ArgumentList $args -NoNewWindow -PassThru -RedirectStandardOutput $tempOut -RedirectStandardError $tempErr
		Register-ActiveConversionProcess -Process $process
		return [pscustomobject]@{
			InputPath = $Video.FullName
			OutputPath = $OutputPath
			FileName = $Video.Name
			FileIndex = $FileIndex
			FileCount = $FileCount
			OutputKind = $OutputKind
			DurationSeconds = $targetDurationSeconds
			TempProgress = $tempProgress
			TempOut = $tempOut
			TempErr = $tempErr
			Process = $process
			FilePercent = 0
		}
	} catch {
		Write-Log ("Failed to start FFmpeg for $($Video.FullName): " + $_.Exception.Message) $LogBox
		Remove-Item -LiteralPath $tempProgress -Force -ErrorAction SilentlyContinue
		Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue
		Remove-Item -LiteralPath $tempErr -Force -ErrorAction SilentlyContinue
		return $null
	}
}

function Complete-ParallelConversionTask {
	param(
		[pscustomobject]$Task,
		[System.Windows.Forms.TextBox]$LogBox
	)

	try {
		$Task.Process.WaitForExit()
		$errorText = ""
		if (Test-Path -LiteralPath $Task.TempErr) {
			$errorText = Get-Content -LiteralPath $Task.TempErr -Raw -ErrorAction SilentlyContinue
		}

		if (Test-CancelRequested) {
			Remove-PartialOutput -OutputPath $Task.OutputPath -LogBox $LogBox
			Write-Log "Canceled: $($Task.InputPath)" $LogBox
			return (New-ConversionOutcome -Status "canceled")
		}

		if ($Task.Process.ExitCode -ne 0) {
			Write-Log "FFmpeg failed for $($Task.InputPath) with exit code $($Task.Process.ExitCode)." $LogBox
			if (-not [string]::IsNullOrWhiteSpace($errorText)) {
				$lastLines = ($errorText -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 8
				foreach ($line in $lastLines) {
					Write-Log $line $LogBox
				}
			}
			if (Test-CompletedOutputLooksValid -OutputPath $Task.OutputPath -ExpectedDurationSeconds $Task.DurationSeconds) {
				Write-Log "Readable output was produced anyway; treating this as success." $LogBox
				return (New-ConversionOutcome -Status "success")
			}
			return (New-ConversionOutcome -Status "failed")
		}

		Write-Log "Done: $($Task.OutputPath)" $LogBox
		return (New-ConversionOutcome -Status "success")
	} finally {
		Unregister-ActiveConversionProcess -Process $Task.Process
		Remove-Item -LiteralPath $Task.TempProgress -Force -ErrorAction SilentlyContinue
		Remove-Item -LiteralPath $Task.TempOut -Force -ErrorAction SilentlyContinue
		Remove-Item -LiteralPath $Task.TempErr -Force -ErrorAction SilentlyContinue
	}
}

function Convert-BatchVideos {
	param(
		[object[]]$Videos,
		[string]$OutputDir,
		[string]$Quality,
		[bool]$Downscale1080,
		[bool]$Overwrite,
		[ValidateSet("WebmVp9", "Ogv", "Mp4Copy")]
		[string]$OutputKind = "WebmVp9",
		[ValidateSet("H264", "H265")]
		[string]$Mp4Codec = "H264",
		[string]$OutputResolution = "",
		[double]$TrimStartSeconds = 0.0,
		[double]$TrimSeconds = 0.0,
		[int]$MaxParallelJobs,
		[System.Windows.Forms.TextBox]$LogBox,
		[System.Windows.Forms.ProgressBar]$ProgressBar,
		[System.Windows.Forms.Label]$ProgressLabel
	)

	$totalFiles = [Math]::Max(1, $Videos.Count)
	$parallelLimit = [Math]::Max(1, [Math]::Min($MaxParallelJobs, $totalFiles))
	$pending = New-Object System.Collections.Queue
	$fileIndex = 0
	foreach ($video in $Videos) {
		$fileIndex += 1
		$pending.Enqueue([pscustomobject]@{
			Video = $video
			OutputPath = (Get-VideoOutputPath -Video $video -OutputDir $OutputDir -OutputKind $OutputKind)
			FileIndex = $fileIndex
		})
	}

	$running = @()
	$success = 0
	$failed = 0
	$completed = 0
	$canceled = $false

	$actionLabel = Get-JobActionLabel -OutputKind $OutputKind
	Write-Log "Using up to $parallelLimit parallel $($actionLabel.ToLowerInvariant()) job(s)." $LogBox

	while ($completed -lt $totalFiles) {
		if (Test-CancelRequested) {
			$canceled = $true
			$pending.Clear()
		}

		while (-not (Test-CancelRequested) -and $running.Count -lt $parallelLimit -and $pending.Count -gt 0) {
			$item = $pending.Dequeue()
			if ((Test-Path -LiteralPath $item.OutputPath) -and -not $Overwrite) {
				Write-Log "Skipping existing output: $($item.OutputPath)" $LogBox
				$success += 1
				$completed += 1
				continue
			}

			$task = Start-ParallelConversionTask -Video $item.Video -OutputPath $item.OutputPath -Quality $Quality -Downscale1080 $Downscale1080 -Overwrite $Overwrite -OutputKind $OutputKind -Mp4Codec $Mp4Codec -OutputResolution $OutputResolution -TrimStartSeconds $TrimStartSeconds -TrimSeconds $TrimSeconds -LogBox $LogBox -FileIndex $item.FileIndex -FileCount $totalFiles
			if ($task -ne $null) {
				$running += $task
			} else {
				$failed += 1
				$completed += 1
			}
		}

		$stillRunning = @()
		foreach ($task in $running) {
			if (Test-CancelRequested -and -not $task.Process.HasExited) {
				try {
					$task.Process.Kill()
				} catch {
				}
			}
			if ($task.Process.HasExited) {
				$taskResult = Complete-ParallelConversionTask -Task $task -LogBox $LogBox
				switch ($taskResult.Status) {
					"success" {
						$success += 1
					}
					"failed" {
						$failed += 1
					}
					"canceled" {
						$canceled = $true
					}
				}
				$completed += 1
			} else {
				if ($task.DurationSeconds -gt 0) {
					$elapsedSeconds = Read-FfmpegProgressSeconds -ProgressPath $task.TempProgress
					$task.FilePercent = [int][Math]::Floor([Math]::Min(100.0, (($elapsedSeconds / $task.DurationSeconds) * 100.0)))
				}
				$stillRunning += $task
			}
		}
		$running = @($stillRunning)

		$runningFraction = 0.0
		foreach ($task in $running) {
			$runningFraction += ([Math]::Max(0, [Math]::Min(100, $task.FilePercent)) / 100.0)
		}
		$overallPercent = [int][Math]::Floor([Math]::Min(100.0, ((($completed + $runningFraction) / $totalFiles) * 100.0)))
		$message = $(if ($canceled) { "Canceling batch: $completed finished, $($running.Count) stopping" } else { "Batch ${actionLabel}: $completed of $totalFiles finished, $($running.Count) active" })
		Set-ConversionProgress -ProgressBar $ProgressBar -StatusLabel $ProgressLabel -Percent $overallPercent -Message $message

		[System.Windows.Forms.Application]::DoEvents()
		if ($canceled -and $running.Count -eq 0) {
			break
		}
		if ($completed -lt $totalFiles) {
			Start-Sleep -Milliseconds 250
		}
	}

	return [pscustomobject]@{
		Success = $success
		Failed = $failed
		Canceled = $canceled
	}
}

function Invoke-ConversionJob {
	param(
		[pscustomobject]$Job,
		[System.Windows.Forms.TextBox]$LogBox,
		[System.Windows.Forms.ProgressBar]$ProgressBar,
		[System.Windows.Forms.Label]$ProgressLabel
	)

	$actionLabel = Get-JobActionLabel -OutputKind $Job.OutputKind
	Set-ConversionProgress -ProgressBar $ProgressBar -StatusLabel $ProgressLabel -Percent 0 -Message "Starting ${actionLabel}..."
	Write-Log "Starting ${actionLabel} for $($Job.Videos.Count) file(s)." $LogBox

	$success = 0
	$failed = 0
	$canceled = $false
	if ($Job.Videos.Count -gt 1 -and $Job.ParallelJobs -gt 1) {
		$result = Convert-BatchVideos -Videos $Job.Videos -OutputDir $Job.OutputDir -Quality $Job.Quality -Downscale1080 $Job.Downscale1080 -Overwrite $Job.Overwrite -OutputKind $Job.OutputKind -Mp4Codec $Job.Mp4Codec -OutputResolution $Job.OutputResolution -TrimStartSeconds $Job.TrimStartSeconds -TrimSeconds $Job.TrimSeconds -MaxParallelJobs $Job.ParallelJobs -LogBox $LogBox -ProgressBar $ProgressBar -ProgressLabel $ProgressLabel
		$success = $result.Success
		$failed = $result.Failed
		$canceled = $result.Canceled
	} else {
		$fileIndex = 0
		foreach ($video in $Job.Videos) {
			if (Test-CancelRequested) {
				$canceled = $true
				break
			}
			$fileIndex += 1
			$outputPath = Get-VideoOutputPath -Video $video -OutputDir $Job.OutputDir -OutputKind $Job.OutputKind
			$fileResult = Convert-OneVideo -InputPath $video.FullName -OutputPath $outputPath -Quality $Job.Quality -Downscale1080 $Job.Downscale1080 -Overwrite $Job.Overwrite -OutputKind $Job.OutputKind -Mp4Codec $Job.Mp4Codec -OutputResolution $Job.OutputResolution -TrimStartSeconds $Job.TrimStartSeconds -TrimSeconds $Job.TrimSeconds -LogBox $LogBox -ProgressBar $ProgressBar -ProgressLabel $ProgressLabel -FileIndex $fileIndex -FileCount $Job.Videos.Count
			switch ($fileResult.Status) {
				"success" {
					$success += 1
				}
				"failed" {
					$failed += 1
				}
				"canceled" {
					$canceled = $true
					break
				}
			}
		}
	}

	if ($canceled) {
		$currentPercent = $(if ($ProgressBar -ne $null) { $ProgressBar.Value } else { 0 })
		Write-Log "Canceled. Success: $success. Failed: $failed." $LogBox
		Set-ConversionProgress -ProgressBar $ProgressBar -StatusLabel $ProgressLabel -Percent $currentPercent -Message "Canceled. Success: $success. Failed: $failed."
	} else {
		Write-Log "Finished. Success: $success. Failed: $failed." $LogBox
		Set-ConversionProgress -ProgressBar $ProgressBar -StatusLabel $ProgressLabel -Percent 100 -Message "Finished. Success: $success. Failed: $failed."
	}

	return [pscustomobject]@{
		Success = $success
		Failed = $failed
		Canceled = $canceled
	}
}

function Get-InputVideos {
	param(
		[string]$SourcePath,
		[bool]$IncludeSubfolders
	)

	$extensions = Get-CombineVideoExtensions
	if (Test-Path -LiteralPath $SourcePath -PathType Leaf) {
		$item = Get-Item -LiteralPath $SourcePath
		if ($extensions -contains $item.Extension.ToLowerInvariant()) {
			return @($item)
		}
		return @()
	}

	if (Test-Path -LiteralPath $SourcePath -PathType Container) {
		if ($IncludeSubfolders) {
			return @(Get-ChildItem -LiteralPath $SourcePath -Recurse -File | Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() } | Sort-Object BaseName, Name, FullName)
		}
		return @(Get-ChildItem -LiteralPath $SourcePath -File | Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() } | Sort-Object BaseName, Name, FullName)
	}

	return @()
}

function Get-CombineVideoExtensions {
	return @(".mp4", ".webm", ".ogv", ".mov", ".mkv", ".avi", ".m4v", ".wmv", ".flv")
}

function Get-CombineVideoFiles {
	param([string[]]$Paths)

	$extensions = Get-CombineVideoExtensions
	$videos = @()
	foreach ($rawPath in @($Paths)) {
		if ([string]::IsNullOrWhiteSpace($rawPath)) {
			continue
		}
		if (Test-Path -LiteralPath $rawPath -PathType Leaf) {
			$item = Get-Item -LiteralPath $rawPath
			if ($extensions -contains $item.Extension.ToLowerInvariant()) {
				$videos += $item
			}
			continue
		}
		if (Test-Path -LiteralPath $rawPath -PathType Container) {
			$videos += @(Get-ChildItem -LiteralPath $rawPath -File | Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() })
		}
	}

	return @($videos | Sort-Object BaseName, Name, FullName -Unique)
}

function Get-CombinedOutputPath {
	param([System.IO.FileInfo[]]$Videos)

	if ($null -eq $Videos -or $Videos.Count -eq 0) {
		return ""
	}

	$firstVideo = $Videos[0]
	return (Join-Path $firstVideo.DirectoryName ($firstVideo.BaseName + "_combined" + $firstVideo.Extension))
}

function Test-VideoHasAudio {
	param([string]$InputPath)

	$ffprobePath = Get-FfprobePath
	if ([string]::IsNullOrWhiteSpace($ffprobePath)) {
		return $false
	}

	try {
		$output = @(& $ffprobePath -v error -select_streams a:0 -show_entries stream=codec_type -of "default=noprint_wrappers=1:nokey=1" $InputPath 2>$null)
		return ($LASTEXITCODE -eq 0 -and $output.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$output[0]))
	} catch {
		return $false
	}
}

function Write-ConcatListFile {
	param(
		[System.IO.FileInfo[]]$Videos,
		[string]$ListPath
	)

	$lines = @()
	foreach ($video in $Videos) {
		$escapedPath = $video.FullName.Replace("\", "/").Replace("'", "'\''")
		$lines += "file '$escapedPath'"
	}
	Set-Content -LiteralPath $ListPath -Value $lines -Encoding ASCII
}

function Invoke-FfmpegSimple {
	param(
		[string]$Arguments,
		[System.Windows.Forms.TextBox]$LogBox,
		[System.Windows.Forms.ProgressBar]$ProgressBar = $null,
		[System.Windows.Forms.Label]$ProgressLabel = $null,
		[string]$ProgressMessage = "Working..."
	)

	$tempOut = [System.IO.Path]::GetTempFileName()
	$tempErr = [System.IO.Path]::GetTempFileName()
	$process = $null
	try {
		$process = Start-Process -FilePath $script:FfmpegPath -ArgumentList $Arguments -NoNewWindow -PassThru -RedirectStandardOutput $tempOut -RedirectStandardError $tempErr
		Register-ActiveConversionProcess -Process $process
		while (-not $process.HasExited) {
			if (Test-CancelRequested) {
				try {
					if (-not $process.HasExited) {
						$process.Kill()
					}
				} catch {
				}
			}
			if ($ProgressLabel -ne $null) {
				$ProgressLabel.Text = $ProgressMessage
			}
			[System.Windows.Forms.Application]::DoEvents()
			Start-Sleep -Milliseconds 250
		}
		$process.WaitForExit()
		$errorText = ""
		if (Test-Path -LiteralPath $tempErr) {
			$errorText = Get-Content -LiteralPath $tempErr -Raw -ErrorAction SilentlyContinue
		}
		return [pscustomobject]@{
			ExitCode = $process.ExitCode
			ErrorText = $errorText
			Canceled = (Test-CancelRequested)
		}
	} catch {
		Write-Log ("Failed to start FFmpeg: " + $_.Exception.Message) $LogBox
		return [pscustomobject]@{
			ExitCode = 1
			ErrorText = $_.Exception.Message
			Canceled = (Test-CancelRequested)
		}
	} finally {
		Unregister-ActiveConversionProcess -Process $process
		Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue
		Remove-Item -LiteralPath $tempErr -Force -ErrorAction SilentlyContinue
	}
}

function Get-CombineNormalizeArguments {
	param(
		[System.IO.FileInfo]$Video,
		[string]$OutputPath,
		[string]$TargetExtension
	)

	$duration = Get-VideoDurationSeconds -InputPath $Video.FullName
	$hasAudio = Test-VideoHasAudio -InputPath $Video.FullName
	$args = @(
		"-hide_banner",
		"-nostats",
		"-loglevel", "error",
		"-y",
		"-i", (Quote-Arg $Video.FullName)
	)

	if (-not $hasAudio) {
		$args += @(
			"-f", "lavfi",
			"-t", ([Math]::Max(0.1, $duration)).ToString([System.Globalization.CultureInfo]::InvariantCulture),
			"-i", (Quote-Arg "anullsrc=channel_layout=stereo:sample_rate=48000")
		)
	}

	$args += @(
		"-map", "0:v:0",
		"-map", $(if ($hasAudio) { "0:a:0" } else { "1:a:0" }),
		"-vf", (Quote-Arg "fps=30,scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p"),
		"-shortest"
	)

	switch ($TargetExtension.ToLowerInvariant()) {
		".webm" {
			$args += @(
				"-c:v", "libvpx-vp9",
				"-b:v", "0",
				"-crf", "32",
				"-deadline", "good",
				"-cpu-used", "4",
				"-row-mt", "1",
				"-tile-columns", "2",
				"-c:a", "libopus",
				"-b:a", "96k"
			)
		}
		".ogv" {
			$args += @(
				"-c:v", "libtheora",
				"-q:v", "6",
				"-c:a", "libvorbis",
				"-q:a", "6"
			)
		}
		default {
			$args += @(
				"-c:v", "libx264",
				"-preset", "veryfast",
				"-crf", "20",
				"-c:a", "aac",
				"-b:a", "128k"
			)
		}
	}

	$args += (Quote-Arg $OutputPath)
	return ($args -join " ")
}

function Invoke-CombineVideos {
	param(
		[System.IO.FileInfo[]]$Videos,
		[bool]$Overwrite,
		[System.Windows.Forms.TextBox]$LogBox,
		[System.Windows.Forms.ProgressBar]$ProgressBar,
		[System.Windows.Forms.Label]$ProgressLabel
	)

	$sortedVideos = @($Videos | Sort-Object BaseName, Name, FullName)
	if ($sortedVideos.Count -lt 2) {
		[System.Windows.Forms.MessageBox]::Show("Drop at least two video files to combine.", "Combine videos", "OK", "Information") | Out-Null
		return (New-ConversionOutcome -Status "failed")
	}

	$outputPath = Get-CombinedOutputPath -Videos $sortedVideos
	if ((Test-Path -LiteralPath $outputPath) -and -not $Overwrite) {
		Write-Log "Combine output already exists: $outputPath" $LogBox
		[System.Windows.Forms.MessageBox]::Show("Combined output already exists. Enable overwrite or rename the existing file.", "Combine videos", "OK", "Warning") | Out-Null
		return (New-ConversionOutcome -Status "failed")
	}

	$outputDir = Split-Path -Parent $outputPath
	New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
	$expectedDurationSeconds = 0.0
	foreach ($video in $sortedVideos) {
		$expectedDurationSeconds += [Math]::Max(0.0, (Get-VideoDurationSeconds -InputPath $video.FullName))
	}

	Write-Log "Combining $($sortedVideos.Count) video file(s) in alphabetical order." $LogBox
	foreach ($video in $sortedVideos) {
		Write-Log "  $($video.Name)" $LogBox
	}
	Write-Log "Combined output: $outputPath" $LogBox
	Set-ConversionProgress -ProgressBar $ProgressBar -StatusLabel $ProgressLabel -Percent 5 -Message "Combining videos..."

	$tempList = [System.IO.Path]::GetTempFileName()
	try {
		Write-ConcatListFile -Videos $sortedVideos -ListPath $tempList
		$audioPresence = @($sortedVideos | ForEach-Object { Test-VideoHasAudio -InputPath $_.FullName })
		$audioLayoutCount = @($audioPresence | Sort-Object -Unique).Count
		if ($audioLayoutCount -eq 1) {
			$directArgs = @(
				"-hide_banner",
				"-nostats",
				"-loglevel", "error",
				$(if ($Overwrite) { "-y" } else { "-n" }),
				"-f", "concat",
				"-safe", "0",
				"-i", (Quote-Arg $tempList),
				"-c", "copy",
				(Quote-Arg $outputPath)
			) -join " "

			Write-Log "Trying fast combine without re-encoding." $LogBox
			$directResult = Invoke-FfmpegSimple -Arguments $directArgs -LogBox $LogBox -ProgressBar $ProgressBar -ProgressLabel $ProgressLabel -ProgressMessage "Combining videos..."
			if ($directResult.Canceled) {
				Remove-PartialOutput -OutputPath $outputPath -LogBox $LogBox
				return (New-ConversionOutcome -Status "canceled")
			}
			if ($directResult.ExitCode -eq 0 -and (Test-CombinedOutputLooksValid -OutputPath $outputPath -ExpectedDurationSeconds $expectedDurationSeconds)) {
				Set-ConversionProgress -ProgressBar $ProgressBar -StatusLabel $ProgressLabel -Percent 100 -Message "Combined videos: $($sortedVideos.Count) file(s)"
				Write-Log "Done: $outputPath" $LogBox
				return (New-ConversionOutcome -Status "success")
			}

			Write-Log "Fast combine failed. Retrying with normalized re-encode." $LogBox
			if (-not [string]::IsNullOrWhiteSpace($directResult.ErrorText)) {
				$lastLines = ($directResult.ErrorText -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 5
				foreach ($line in $lastLines) {
					Write-Log $line $LogBox
				}
			}
		} else {
			Write-Log "Video audio layouts differ; using normalized re-encode so audio is preserved." $LogBox
		}

		[void](Remove-FileWithRetry -Path $outputPath)
		$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("neko-combine-" + [guid]::NewGuid().ToString("N"))
		New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
		try {
			$targetExtension = $sortedVideos[0].Extension.ToLowerInvariant()
			$segmentExtension = $(if ($targetExtension -eq ".webm" -or $targetExtension -eq ".ogv") { $targetExtension } else { ".mkv" })
			$segments = @()
			for ($index = 0; $index -lt $sortedVideos.Count; $index++) {
				if (Test-CancelRequested) {
					return (New-ConversionOutcome -Status "canceled")
				}
				$segmentPath = Join-Path $tempDir ("segment_{0:0000}{1}" -f $index, $segmentExtension)
				$percent = [int][Math]::Floor((($index / [Math]::Max(1, $sortedVideos.Count)) * 70) + 10)
				Set-ConversionProgress -ProgressBar $ProgressBar -StatusLabel $ProgressLabel -Percent $percent -Message "Normalizing $($index + 1) of $($sortedVideos.Count): $($sortedVideos[$index].Name)"
				$normalizeArgs = Get-CombineNormalizeArguments -Video $sortedVideos[$index] -OutputPath $segmentPath -TargetExtension $targetExtension
				$normalizeResult = Invoke-FfmpegSimple -Arguments $normalizeArgs -LogBox $LogBox -ProgressBar $ProgressBar -ProgressLabel $ProgressLabel -ProgressMessage "Normalizing $($index + 1) of $($sortedVideos.Count): $($sortedVideos[$index].Name)"
				if ($normalizeResult.Canceled) {
					return (New-ConversionOutcome -Status "canceled")
				}
				if ($normalizeResult.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $segmentPath)) {
					Write-Log "Failed to normalize: $($sortedVideos[$index].FullName)" $LogBox
					if (-not [string]::IsNullOrWhiteSpace($normalizeResult.ErrorText)) {
						$lastLines = ($normalizeResult.ErrorText -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 8
						foreach ($line in $lastLines) {
							Write-Log $line $LogBox
						}
					}
					return (New-ConversionOutcome -Status "failed")
				}
				$segments += (Get-Item -LiteralPath $segmentPath)
			}

			$segmentList = Join-Path $tempDir "segments.txt"
			Write-ConcatListFile -Videos $segments -ListPath $segmentList
			Set-ConversionProgress -ProgressBar $ProgressBar -StatusLabel $ProgressLabel -Percent 85 -Message "Writing combined output..."
			$tempFinalOutput = Join-Path $tempDir ("combined" + $targetExtension)
			$finalArgs = @(
				"-hide_banner",
				"-nostats",
				"-loglevel", "error",
				"-y",
				"-f", "concat",
				"-safe", "0",
				"-i", (Quote-Arg $segmentList),
				"-c", "copy",
				$(if ($targetExtension -eq ".mp4" -or $targetExtension -eq ".m4v" -or $targetExtension -eq ".mov") { "-movflags +faststart" } else { "" }),
				(Quote-Arg $tempFinalOutput)
			) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
			$finalResult = Invoke-FfmpegSimple -Arguments ($finalArgs -join " ") -LogBox $LogBox -ProgressBar $ProgressBar -ProgressLabel $ProgressLabel -ProgressMessage "Writing combined output..."
			if ($finalResult.Canceled) {
				Remove-PartialOutput -OutputPath $outputPath -LogBox $LogBox
				return (New-ConversionOutcome -Status "canceled")
			}
			if ($finalResult.ExitCode -ne 0 -or -not (Test-CombinedOutputLooksValid -OutputPath $tempFinalOutput -ExpectedDurationSeconds $expectedDurationSeconds)) {
				Write-Log "Failed to write combined output." $LogBox
				if (-not [string]::IsNullOrWhiteSpace($finalResult.ErrorText)) {
					$lastLines = ($finalResult.ErrorText -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 8
					foreach ($line in $lastLines) {
						Write-Log $line $LogBox
					}
				}
				return (New-ConversionOutcome -Status "failed")
			}

			if (-not (Remove-FileWithRetry -Path $outputPath)) {
				Write-Log "Could not replace existing combined output: $outputPath" $LogBox
				return (New-ConversionOutcome -Status "failed")
			}

			try {
				Move-Item -LiteralPath $tempFinalOutput -Destination $outputPath -Force -ErrorAction Stop
			} catch {
				Write-Log ("Could not move combined output into place: " + $_.Exception.Message) $LogBox
				return (New-ConversionOutcome -Status "failed")
			}

			if (-not (Test-CombinedOutputLooksValid -OutputPath $outputPath -ExpectedDurationSeconds $expectedDurationSeconds)) {
				Write-Log "Combined output did not pass validation after writing." $LogBox
				return (New-ConversionOutcome -Status "failed")
			}

			Set-ConversionProgress -ProgressBar $ProgressBar -StatusLabel $ProgressLabel -Percent 100 -Message "Combined videos: $($sortedVideos.Count) file(s)"
			Write-Log "Done: $outputPath" $LogBox
			return (New-ConversionOutcome -Status "success")
		} finally {
			Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
		}
	} finally {
		Remove-Item -LiteralPath $tempList -Force -ErrorAction SilentlyContinue
	}
}

function Start-Gui {
	$script:FfmpegPath = Find-Ffmpeg

	$form = New-Object System.Windows.Forms.Form
	$form.Text = "Neko Cutscene Converter"
	$form.StartPosition = "CenterScreen"
	$form.Size = New-Object System.Drawing.Size(820, 805)
	$form.MinimumSize = New-Object System.Drawing.Size(760, 805)

	$font = New-Object System.Drawing.Font("Segoe UI", 9)
	$form.Font = $font
	$conversionQueue = New-Object System.Collections.Queue
	$isProcessing = $false
	$sourceUiState = [pscustomobject]@{ IsUpdatingSourceBox = $false }
	$sourceVideos = New-Object System.Collections.ArrayList
	$combineVideos = New-Object System.Collections.ArrayList

	$title = New-Object System.Windows.Forms.Label
	$title.Text = "Neko Cutscene Converter"
	$title.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
	$title.Location = New-Object System.Drawing.Point(16, 14)
	$title.Size = New-Object System.Drawing.Size(420, 34)
	$form.Controls.Add($title)

	$ffmpegStatus = New-Object System.Windows.Forms.Label
	$ffmpegStatus.Location = New-Object System.Drawing.Point(18, 55)
	$ffmpegStatus.Size = New-Object System.Drawing.Size(520, 24)
	$form.Controls.Add($ffmpegStatus)

	$dropPanel = New-Object System.Windows.Forms.Panel
	$dropPanel.Location = New-Object System.Drawing.Point(565, 14)
	$dropPanel.Size = New-Object System.Drawing.Size(232, 106)
	$dropPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
	$dropPanel.BackColor = [System.Drawing.Color]::FromArgb(246, 246, 246)
	$dropPanel.AllowDrop = $true
	$dropPanel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
	$form.Controls.Add($dropPanel)

	$dropTitle = New-Object System.Windows.Forms.Label
	$dropTitle.Text = "Drop Source Here"
	$dropTitle.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
	$dropTitle.Location = New-Object System.Drawing.Point(14, 18)
	$dropTitle.Size = New-Object System.Drawing.Size(140, 24)
	$dropTitle.BackColor = $dropPanel.BackColor
	$dropTitle.AllowDrop = $true
	$dropPanel.Controls.Add($dropTitle)

	$clearSourceButton = New-Object System.Windows.Forms.Button
	$clearSourceButton.Text = "Clear"
	$clearSourceButton.Location = New-Object System.Drawing.Point(164, 14)
	$clearSourceButton.Size = New-Object System.Drawing.Size(54, 28)
	$clearSourceButton.Enabled = $false
	$dropPanel.Controls.Add($clearSourceButton)

	$dropHint = New-Object System.Windows.Forms.Label
	$dropHint.Text = "Video file(s) or folder"
	$dropHint.Location = New-Object System.Drawing.Point(14, 48)
	$dropHint.Size = New-Object System.Drawing.Size(190, 20)
	$dropHint.BackColor = $dropPanel.BackColor
	$dropHint.AllowDrop = $true
	$dropPanel.Controls.Add($dropHint)

	$dropSubHint = New-Object System.Windows.Forms.Label
	$dropSubHint.Text = "Updates the source field"
	$dropSubHint.Location = New-Object System.Drawing.Point(14, 68)
	$dropSubHint.Size = New-Object System.Drawing.Size(200, 20)
	$dropSubHint.BackColor = $dropPanel.BackColor
	$dropSubHint.ForeColor = [System.Drawing.Color]::DimGray
	$dropSubHint.AllowDrop = $true
	$dropPanel.Controls.Add($dropSubHint)

	$installButton = New-Object System.Windows.Forms.Button
	$installButton.Text = "Install FFmpeg to D:\Tools"
	$installButton.Location = New-Object System.Drawing.Point(18, 88)
	$installButton.Size = New-Object System.Drawing.Size(180, 32)
	$form.Controls.Add($installButton)

	$locateButton = New-Object System.Windows.Forms.Button
	$locateButton.Text = "Locate ffmpeg.exe"
	$locateButton.Location = New-Object System.Drawing.Point(208, 88)
	$locateButton.Size = New-Object System.Drawing.Size(140, 32)
	$form.Controls.Add($locateButton)

	$sourceLabel = New-Object System.Windows.Forms.Label
	$sourceLabel.Text = "Video file(s) or folder"
	$sourceLabel.Location = New-Object System.Drawing.Point(18, 137)
	$sourceLabel.Size = New-Object System.Drawing.Size(180, 22)
	$form.Controls.Add($sourceLabel)

	$sourceBox = New-Object System.Windows.Forms.TextBox
	$sourceBox.Location = New-Object System.Drawing.Point(18, 160)
	$sourceBox.Size = New-Object System.Drawing.Size(560, 24)
	$sourceBox.Text = Get-ConfiguredString -Name "sourcePath" -DefaultValue ""
	$form.Controls.Add($sourceBox)

	$fileButton = New-Object System.Windows.Forms.Button
	$fileButton.Text = "Browse File"
	$fileButton.Location = New-Object System.Drawing.Point(590, 157)
	$fileButton.Size = New-Object System.Drawing.Size(95, 30)
	$form.Controls.Add($fileButton)

	$folderButton = New-Object System.Windows.Forms.Button
	$folderButton.Text = "Browse Folder"
	$folderButton.Location = New-Object System.Drawing.Point(692, 157)
	$folderButton.Size = New-Object System.Drawing.Size(105, 30)
	$form.Controls.Add($folderButton)

	$outputLabel = New-Object System.Windows.Forms.Label
	$outputLabel.Text = "Output folder"
	$outputLabel.Location = New-Object System.Drawing.Point(18, 200)
	$outputLabel.Size = New-Object System.Drawing.Size(180, 22)
	$form.Controls.Add($outputLabel)

	$outputBox = New-Object System.Windows.Forms.TextBox
	$outputBox.Location = New-Object System.Drawing.Point(18, 223)
	$outputBox.Size = New-Object System.Drawing.Size(667, 24)
	$outputBox.Text = Get-ConfiguredOutputDir
	$form.Controls.Add($outputBox)

	$outputButton = New-Object System.Windows.Forms.Button
	$outputButton.Text = "Browse"
	$outputButton.Location = New-Object System.Drawing.Point(692, 220)
	$outputButton.Size = New-Object System.Drawing.Size(105, 30)
	$form.Controls.Add($outputButton)

	$qualityLabel = New-Object System.Windows.Forms.Label
	$qualityLabel.Text = "Quality"
	$qualityLabel.Location = New-Object System.Drawing.Point(18, 265)
	$qualityLabel.Size = New-Object System.Drawing.Size(52, 22)
	$form.Controls.Add($qualityLabel)

	$qualityBox = New-Object System.Windows.Forms.ComboBox
	$qualityBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
	[void]$qualityBox.Items.Add("Balanced")
	[void]$qualityBox.Items.Add("High")
	[void]$qualityBox.Items.Add("Smaller")
	$qualityBox.SelectedItem = Get-ConfiguredQuality
	$qualityBox.Location = New-Object System.Drawing.Point(76, 262)
	$qualityBox.Size = New-Object System.Drawing.Size(130, 26)
	$form.Controls.Add($qualityBox)

	$parallelLabel = New-Object System.Windows.Forms.Label
	$parallelLabel.Text = "Batch jobs"
	$parallelLabel.Location = New-Object System.Drawing.Point(230, 265)
	$parallelLabel.Size = New-Object System.Drawing.Size(68, 22)
	$form.Controls.Add($parallelLabel)

	$parallelBox = New-Object System.Windows.Forms.NumericUpDown
	$parallelBox.Minimum = 1
	$parallelBox.Maximum = Get-MaxParallelJobs
	$parallelBox.Value = Get-ConfiguredParallelJobs
	$parallelBox.Location = New-Object System.Drawing.Point(306, 262)
	$parallelBox.Size = New-Object System.Drawing.Size(58, 26)
	$form.Controls.Add($parallelBox)

	$trimOptions = Get-TrimOptionValues

	$trimStartLabel = New-Object System.Windows.Forms.Label
	$trimStartLabel.Text = "Trim Start"
	$trimStartLabel.Location = New-Object System.Drawing.Point(390, 265)
	$trimStartLabel.Size = New-Object System.Drawing.Size(72, 22)
	$form.Controls.Add($trimStartLabel)

	$trimStartBox = New-Object System.Windows.Forms.ComboBox
	$trimStartBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
	foreach ($seconds in $trimOptions) {
		[void]$trimStartBox.Items.Add($seconds)
	}
	$trimStartBox.SelectedItem = Format-SecondsOption -Seconds (Get-ConfiguredTrimStartSeconds)
	if ($trimStartBox.SelectedIndex -lt 0) {
		$trimStartBox.SelectedIndex = 0
	}
	$trimStartBox.Location = New-Object System.Drawing.Point(470, 262)
	$trimStartBox.Size = New-Object System.Drawing.Size(58, 26)
	$form.Controls.Add($trimStartBox)

	$trimLabel = New-Object System.Windows.Forms.Label
	$trimLabel.Text = "Trim End"
	$trimLabel.Location = New-Object System.Drawing.Point(548, 265)
	$trimLabel.Size = New-Object System.Drawing.Size(65, 22)
	$form.Controls.Add($trimLabel)

	$trimBox = New-Object System.Windows.Forms.ComboBox
	$trimBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
	foreach ($seconds in $trimOptions) {
		[void]$trimBox.Items.Add($seconds)
	}
	$trimBox.SelectedItem = Format-SecondsOption -Seconds (Get-ConfiguredTrimSeconds)
	if ($trimBox.SelectedIndex -lt 0) {
		$trimBox.SelectedIndex = 0
	}
	$trimBox.Location = New-Object System.Drawing.Point(620, 262)
	$trimBox.Size = New-Object System.Drawing.Size(58, 26)
	$form.Controls.Add($trimBox)

	$resolutionLabel = New-Object System.Windows.Forms.Label
	$resolutionLabel.Text = "Resolution"
	$resolutionLabel.Location = New-Object System.Drawing.Point(18, 298)
	$resolutionLabel.Size = New-Object System.Drawing.Size(70, 22)
	$form.Controls.Add($resolutionLabel)

	$resolutionBox = New-Object System.Windows.Forms.ComboBox
	$resolutionBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
	[void]$resolutionBox.Items.Add("(native)")
	[void]$resolutionBox.Items.Add("1920x1080")
	[void]$resolutionBox.Items.Add("1444p")
	[void]$resolutionBox.Items.Add("2160p")
	$resolutionBox.SelectedItem = Get-ConfiguredOutputResolution
	if ($resolutionBox.SelectedIndex -lt 0) {
		$resolutionBox.SelectedItem = "(native)"
	}
	$resolutionBox.Location = New-Object System.Drawing.Point(92, 294)
	$resolutionBox.Size = New-Object System.Drawing.Size(120, 26)
	$form.Controls.Add($resolutionBox)

	$recursiveCheck = New-Object System.Windows.Forms.CheckBox
	$recursiveCheck.Text = "Include subfolders"
	$recursiveCheck.Checked = Get-ConfiguredBool -Name "includeSubfolders" -DefaultValue $false
	$recursiveCheck.Location = New-Object System.Drawing.Point(230, 296)
	$recursiveCheck.Size = New-Object System.Drawing.Size(145, 24)
	$form.Controls.Add($recursiveCheck)

	$overwriteCheck = New-Object System.Windows.Forms.CheckBox
	$overwriteCheck.Text = "Overwrite existing output"
	$overwriteCheck.Checked = Get-ConfiguredBool -Name "overwrite" -DefaultValue $true
	$overwriteCheck.Location = New-Object System.Drawing.Point(372, 296)
	$overwriteCheck.Size = New-Object System.Drawing.Size(165, 24)
	$form.Controls.Add($overwriteCheck)

	$mp4CodecLabel = New-Object System.Windows.Forms.Label
	$mp4CodecLabel.Text = "MP4 codec"
	$mp4CodecLabel.Location = New-Object System.Drawing.Point(552, 298)
	$mp4CodecLabel.Size = New-Object System.Drawing.Size(70, 22)
	$form.Controls.Add($mp4CodecLabel)

	$mp4CodecBox = New-Object System.Windows.Forms.ComboBox
	$mp4CodecBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
	[void]$mp4CodecBox.Items.Add("H264")
	[void]$mp4CodecBox.Items.Add("H265")
	$mp4CodecBox.SelectedItem = Get-ConfiguredMp4Codec
	if ($mp4CodecBox.SelectedIndex -lt 0) {
		$mp4CodecBox.SelectedItem = "H264"
	}
	$mp4CodecBox.Location = New-Object System.Drawing.Point(625, 294)
	$mp4CodecBox.Size = New-Object System.Drawing.Size(70, 26)
	$form.Controls.Add($mp4CodecBox)

	$moreFormatsCheck = New-Object System.Windows.Forms.CheckBox
	$moreFormatsCheck.Text = "More Formats"
	$moreFormatsCheck.Checked = $false
	$moreFormatsCheck.Location = New-Object System.Drawing.Point(18, 316)
	$moreFormatsCheck.Size = New-Object System.Drawing.Size(120, 18)
	$form.Controls.Add($moreFormatsCheck)

	$exportMp4Button = New-Object System.Windows.Forms.Button
	$exportMp4Button.Text = "Export MP4"
	$exportMp4Button.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
	$exportMp4Button.Location = New-Object System.Drawing.Point(18, 338)
	$exportMp4Button.Size = New-Object System.Drawing.Size(130, 40)
	$form.Controls.Add($exportMp4Button)

	$convertButton = New-Object System.Windows.Forms.Button
	$convertButton.Text = "Convert WebM VP9"
	$convertButton.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
	$convertButton.Location = New-Object System.Drawing.Point(158, 338)
	$convertButton.Size = New-Object System.Drawing.Size(170, 40)
	$convertButton.Visible = $false
	$form.Controls.Add($convertButton)

	$convertOgvButton = New-Object System.Windows.Forms.Button
	$convertOgvButton.Text = "Convert OGV"
	$convertOgvButton.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
	$convertOgvButton.Location = New-Object System.Drawing.Point(338, 338)
	$convertOgvButton.Size = New-Object System.Drawing.Size(130, 40)
	$convertOgvButton.Visible = $false
	$form.Controls.Add($convertOgvButton)

	$stopButton = New-Object System.Windows.Forms.Button
	$stopButton.Text = "Stop"
	$stopButton.Location = New-Object System.Drawing.Point(478, 343)
	$stopButton.Size = New-Object System.Drawing.Size(90, 32)
	$stopButton.Enabled = $false
	$form.Controls.Add($stopButton)

	$openOutputButton = New-Object System.Windows.Forms.Button
	$openOutputButton.Text = "Open Output Folder"
	$openOutputButton.Location = New-Object System.Drawing.Point(578, 343)
	$openOutputButton.Size = New-Object System.Drawing.Size(160, 32)
	$form.Controls.Add($openOutputButton)

	$queueStatus = New-Object System.Windows.Forms.Label
	$queueStatus.Text = "Queue: idle"
	$queueStatus.Location = New-Object System.Drawing.Point(18, 383)
	$queueStatus.Size = New-Object System.Drawing.Size(779, 18)
	$form.Controls.Add($queueStatus)

	$combineDivider = New-Object System.Windows.Forms.Label
	$combineDivider.BorderStyle = [System.Windows.Forms.BorderStyle]::Fixed3D
	$combineDivider.Location = New-Object System.Drawing.Point(18, 410)
	$combineDivider.Size = New-Object System.Drawing.Size(779, 2)
	$form.Controls.Add($combineDivider)

	$combineDropPanel = New-Object System.Windows.Forms.Panel
	$combineDropPanel.Location = New-Object System.Drawing.Point(18, 424)
	$combineDropPanel.Size = New-Object System.Drawing.Size(450, 58)
	$combineDropPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
	$combineDropPanel.BackColor = [System.Drawing.Color]::FromArgb(246, 246, 246)
	$combineDropPanel.AllowDrop = $true
	$form.Controls.Add($combineDropPanel)

	$combineDropLabel = New-Object System.Windows.Forms.Label
	$combineDropLabel.Text = "Drop videos to combine"
	$combineDropLabel.Location = New-Object System.Drawing.Point(12, 9)
	$combineDropLabel.Size = New-Object System.Drawing.Size(425, 20)
	$combineDropLabel.BackColor = $combineDropPanel.BackColor
	$combineDropLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
	$combineDropLabel.AllowDrop = $true
	$combineDropPanel.Controls.Add($combineDropLabel)

	$combineDropHint = New-Object System.Windows.Forms.Label
	$combineDropHint.Text = "Alphabetical order -> first_name_combined.ext"
	$combineDropHint.Location = New-Object System.Drawing.Point(12, 31)
	$combineDropHint.Size = New-Object System.Drawing.Size(425, 18)
	$combineDropHint.BackColor = $combineDropPanel.BackColor
	$combineDropHint.ForeColor = [System.Drawing.Color]::DimGray
	$combineDropHint.AllowDrop = $true
	$combineDropPanel.Controls.Add($combineDropHint)

	$combineButton = New-Object System.Windows.Forms.Button
	$combineButton.Text = "Combine videos"
	$combineButton.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
	$combineButton.Location = New-Object System.Drawing.Point(482, 433)
	$combineButton.Size = New-Object System.Drawing.Size(145, 40)
	$form.Controls.Add($combineButton)

	$clearCombineButton = New-Object System.Windows.Forms.Button
	$clearCombineButton.Text = "Clear"
	$clearCombineButton.Location = New-Object System.Drawing.Point(638, 437)
	$clearCombineButton.Size = New-Object System.Drawing.Size(75, 32)
	$form.Controls.Add($clearCombineButton)

	$progressStatus = New-Object System.Windows.Forms.Label
	$progressStatus.Text = "Progress: idle"
	$progressStatus.Location = New-Object System.Drawing.Point(18, 498)
	$progressStatus.Size = New-Object System.Drawing.Size(779, 22)
	$form.Controls.Add($progressStatus)

	$progressBar = New-Object System.Windows.Forms.ProgressBar
	$progressBar.Location = New-Object System.Drawing.Point(18, 523)
	$progressBar.Size = New-Object System.Drawing.Size(779, 22)
	$progressBar.Minimum = 0
	$progressBar.Maximum = 100
	$progressBar.Value = 0
	$progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
	$form.Controls.Add($progressBar)

	$logBox = New-Object System.Windows.Forms.TextBox
	$logBox.Location = New-Object System.Drawing.Point(18, 558)
	$logBox.Size = New-Object System.Drawing.Size(779, 172)
	$logBox.Multiline = $true
	$logBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
	$logBox.ReadOnly = $true
	$form.Controls.Add($logBox)

	function Update-MoreFormatsVisibility {
		$showMoreFormats = ($moreFormatsCheck.Checked -eq $true)
		$convertButton.Visible = $showMoreFormats
		$convertOgvButton.Visible = $showMoreFormats
	}

	function Update-ConvertButtonState {
		$hasFfmpeg = (-not [string]::IsNullOrWhiteSpace($script:FfmpegPath)) -and (Test-Path -LiteralPath $script:FfmpegPath)
		Update-MoreFormatsVisibility
		$convertButton.Enabled = $hasFfmpeg -and (-not (Test-CancelRequested)) -and $moreFormatsCheck.Checked
		$convertOgvButton.Enabled = $hasFfmpeg -and (-not (Test-CancelRequested)) -and $moreFormatsCheck.Checked
		$exportMp4Button.Enabled = $hasFfmpeg -and (-not (Test-CancelRequested))
		$combineButton.Enabled = $hasFfmpeg -and (-not (Test-CancelRequested)) -and (-not $isProcessing) -and ($combineVideos.Count -ge 2)
		$convertButton.Text = $(if (Test-CancelRequested) { "Canceling..." } elseif ($isProcessing) { "Queue WebM" } else { "Convert WebM VP9" })
		$convertOgvButton.Text = $(if (Test-CancelRequested) { "Canceling..." } elseif ($isProcessing) { "Queue OGV" } else { "Convert OGV" })
		$exportMp4Button.Text = $(if (Test-CancelRequested) { "Canceling..." } elseif ($isProcessing) { "Queue MP4" } else { "Export MP4" })
		$stopButton.Enabled = $isProcessing -and (-not (Test-CancelRequested))
	}

	function Update-QueueStatus {
		if (Test-CancelRequested) {
			$queueStatus.Text = "Queue: canceling current work"
		} elseif ($isProcessing) {
			if ($conversionQueue.Count -gt 0) {
				$queueStatus.Text = "Queue: converting now, $($conversionQueue.Count) job(s) waiting"
			} else {
				$queueStatus.Text = "Queue: converting now, no waiting jobs"
			}
		} elseif ($conversionQueue.Count -gt 0) {
			$queueStatus.Text = "Queue: $($conversionQueue.Count) job(s) waiting"
		} else {
			$queueStatus.Text = "Queue: idle"
		}
	}

	function Update-FfmpegStatus {
		if (-not [string]::IsNullOrWhiteSpace($script:FfmpegPath) -and (Test-Path -LiteralPath $script:FfmpegPath)) {
			$ffmpegStatus.Text = "FFmpeg: $script:FfmpegPath"
			$ffmpegStatus.ForeColor = [System.Drawing.Color]::DarkGreen
		} else {
			$ffmpegStatus.Text = "FFmpeg: not found. Click Install FFmpeg or locate ffmpeg.exe."
			$ffmpegStatus.ForeColor = [System.Drawing.Color]::DarkRed
		}
		Update-ConvertButtonState
	}

	function Test-SourceVideoPath {
		param([string]$Path)

		if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
			return $false
		}

		$extension = [System.IO.Path]::GetExtension($Path)
		if ([string]::IsNullOrWhiteSpace($extension)) {
			return $false
		}

		return ((Get-CombineVideoExtensions) -contains $extension.ToLowerInvariant())
	}

	function Get-SourceVideosFromPaths {
		param(
			[string[]]$Paths,
			[bool]$IncludeSubfolders = $false
		)

		$videos = @()
		foreach ($rawPath in @($Paths)) {
			if ([string]::IsNullOrWhiteSpace($rawPath)) {
				continue
			}
			if (Test-Path -LiteralPath $rawPath -PathType Leaf) {
				if (Test-SourceVideoPath -Path $rawPath) {
					$videos += (Get-Item -LiteralPath $rawPath)
				}
				continue
			}
			if (Test-Path -LiteralPath $rawPath -PathType Container) {
				$videos += @(Get-InputVideos -SourcePath $rawPath -IncludeSubfolders $IncludeSubfolders)
			}
		}

		return @($videos | Sort-Object BaseName, Name, FullName -Unique)
	}

	function Set-SourceBoxText {
		param([string]$Text)

		$previous = $sourceUiState.IsUpdatingSourceBox
		$sourceUiState.IsUpdatingSourceBox = $true
		try {
			$sourceBox.Text = $Text
		} finally {
			$sourceUiState.IsUpdatingSourceBox = $previous
		}
	}

	function Get-SourceSelectionDisplayText {
		if ($sourceVideos.Count -eq 0) {
			return $sourceBox.Text
		}
		if ($sourceVideos.Count -eq 1) {
			return [string]$sourceVideos[0].FullName
		}

		$names = @($sourceVideos | Select-Object -First 3 | ForEach-Object { $_.Name })
		$suffix = $(if ($sourceVideos.Count -gt 3) { ", ..." } else { "" })
		return "$($sourceVideos.Count) source videos: $($names -join ', ')$suffix"
	}

	function Update-SourceSelectionState {
		if ($sourceVideos.Count -gt 0) {
			Set-SourceBoxText -Text (Get-SourceSelectionDisplayText)
			$dropSubHint.Text = "$($sourceVideos.Count) source video(s) selected"
		} else {
			$dropSubHint.Text = "Updates the source field"
		}
		$clearSourceButton.Enabled = ($sourceVideos.Count -gt 0 -or -not [string]::IsNullOrWhiteSpace($sourceBox.Text))
	}

	function Add-SourceVideosToSelection {
		param(
			[System.IO.FileInfo[]]$Videos,
			[bool]$Replace = $false,
			[bool]$SortAlphabetically = $false
		)

		if ($Replace) {
			$sourceVideos.Clear()
		}

		$items = @($Videos)
		if ($SortAlphabetically) {
			$items = @($items | Sort-Object BaseName, Name, FullName -Unique)
		}

		$added = 0
		foreach ($video in $items) {
			if ($null -eq $video -or -not (Test-SourceVideoPath -Path $video.FullName)) {
				continue
			}

			$exists = $false
			foreach ($selectedVideo in $sourceVideos) {
				if ([string]::Equals($selectedVideo.FullName, $video.FullName, [System.StringComparison]::OrdinalIgnoreCase)) {
					$exists = $true
					break
				}
			}
			if (-not $exists) {
				[void]$sourceVideos.Add($video)
				$added++
			}
		}

		Update-SourceSelectionState
		return $added
	}

	function Import-ExistingSourceFileIntoSelection {
		if ($sourceVideos.Count -gt 0) {
			return
		}

		$currentSource = $sourceBox.Text.Trim()
		if (Test-SourceVideoPath -Path $currentSource) {
			[void](Add-SourceVideosToSelection -Videos @((Get-Item -LiteralPath $currentSource)) -Replace $false -SortAlphabetically $false)
		}
	}

	function Clear-SourceVideos {
		if ($sourceVideos.Count -gt 0) {
			$sourceVideos.Clear()
			Update-SourceSelectionState
		}
	}

	function Clear-SourceSelection {
		if ($sourceVideos.Count -gt 0) {
			$sourceVideos.Clear()
		}
		Set-SourceBoxText -Text ""
		Update-SourceSelectionState
	}

	function Get-SourcePathToSave {
		if ($sourceVideos.Count -gt 0) {
			return [string]$sourceVideos[0].FullName
		}
		return $sourceBox.Text
	}

	function Save-CurrentSettings {
		Save-Config `
			-FfmpegPath $script:FfmpegPath `
			-OutputDir $outputBox.Text `
			-SourcePath (Get-SourcePathToSave) `
			-Quality ([string]$qualityBox.SelectedItem) `
			-Downscale1080 ((Normalize-OutputResolution -Value ([string]$resolutionBox.SelectedItem)) -eq "1920x1080") `
			-IncludeSubfolders $recursiveCheck.Checked `
			-Overwrite $overwriteCheck.Checked `
			-ParallelJobs ([int]$parallelBox.Value) `
			-TrimStartSeconds ([double]::Parse([string]$trimStartBox.SelectedItem, [System.Globalization.CultureInfo]::InvariantCulture)) `
			-TrimSeconds ([double]::Parse([string]$trimBox.SelectedItem, [System.Globalization.CultureInfo]::InvariantCulture)) `
			-Mp4Codec ([string]$mp4CodecBox.SelectedItem) `
			-OutputResolution ([string]$resolutionBox.SelectedItem)
	}

	function Update-CombineDropState {
		if ($combineVideos.Count -gt 0) {
			$combineDropLabel.Text = "$($combineVideos.Count) video(s) ready to combine"
			$combineDropHint.Text = "First output: $(Split-Path -Leaf (Get-CombinedOutputPath -Videos @($combineVideos)))"
		} else {
			$combineDropLabel.Text = "Drop videos to combine"
			$combineDropHint.Text = "Alphabetical order -> first_name_combined.ext"
		}
		Update-ConvertButtonState
	}

	function Set-DropZoneHighlight {
		param([bool]$Highlighted)

		$panelColor = $(if ($Highlighted) { [System.Drawing.Color]::FromArgb(227, 238, 255) } else { [System.Drawing.Color]::FromArgb(246, 246, 246) })
		$dropPanel.BackColor = $panelColor
		$dropTitle.BackColor = $panelColor
		$dropHint.BackColor = $panelColor
		$dropSubHint.BackColor = $panelColor
	}

	function Set-CombineDropHighlight {
		param([bool]$Highlighted)

		$panelColor = $(if ($Highlighted) { [System.Drawing.Color]::FromArgb(227, 238, 255) } else { [System.Drawing.Color]::FromArgb(246, 246, 246) })
		$combineDropPanel.BackColor = $panelColor
		$combineDropLabel.BackColor = $panelColor
		$combineDropHint.BackColor = $panelColor
	}

	function Try-SetSourceFromDroppedPaths {
		param([string[]]$DroppedPaths)

		if ($null -eq $DroppedPaths -or $DroppedPaths.Count -eq 0) {
			return $false
		}

		$validPaths = @($DroppedPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
		if ($validPaths.Count -eq 1 -and (Test-Path -LiteralPath $validPaths[0] -PathType Container)) {
			Clear-SourceVideos
			Set-SourceBoxText -Text $validPaths[0]
			Save-CurrentSettings
			Write-Log "Source folder set by drag and drop: $($validPaths[0])" $logBox
			return $true
		}

		$videos = @(Get-SourceVideosFromPaths -Paths $validPaths -IncludeSubfolders $false)
		if ($videos.Count -eq 0) {
			Write-Log "Drop ignored. Use video file(s) or a folder." $logBox
			[System.Windows.Forms.MessageBox]::Show("Drop video file(s) or a folder.", "Unsupported drop", "OK", "Information") | Out-Null
			return $false
		}

		$append = ($videos.Count -eq 1)
		if ($append) {
			Import-ExistingSourceFileIntoSelection
		}
		[void](Add-SourceVideosToSelection -Videos $videos -Replace (-not $append) -SortAlphabetically (-not $append))
		Save-CurrentSettings
		if ($append) {
			Write-Log "Source video added by drag and drop: $($videos[0].Name)" $logBox
		} else {
			Write-Log "Source list set by drag and drop: $($sourceVideos.Count) video(s), alphabetical order." $logBox
		}
		return $true
	}

	$dragEnterHandler = {
		param($sender, $e)
		if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
			$e.Effect = [System.Windows.Forms.DragDropEffects]::Copy
			Set-DropZoneHighlight -Highlighted $true
		} else {
			$e.Effect = [System.Windows.Forms.DragDropEffects]::None
			Set-DropZoneHighlight -Highlighted $false
		}
	}

	$dragOverHandler = {
		param($sender, $e)
		if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
			$e.Effect = [System.Windows.Forms.DragDropEffects]::Copy
			Set-DropZoneHighlight -Highlighted $true
		} else {
			$e.Effect = [System.Windows.Forms.DragDropEffects]::None
			Set-DropZoneHighlight -Highlighted $false
		}
	}

	$dragLeaveHandler = {
		param($sender, $e)
		Set-DropZoneHighlight -Highlighted $false
	}

	$dragDropHandler = {
		param($sender, $e)
		Set-DropZoneHighlight -Highlighted $false
		$droppedPaths = @($e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop))
		[void](Try-SetSourceFromDroppedPaths -DroppedPaths $droppedPaths)
	}

	$combineDragEnterHandler = {
		param($sender, $e)
		if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
			$e.Effect = [System.Windows.Forms.DragDropEffects]::Copy
			Set-CombineDropHighlight -Highlighted $true
		} else {
			$e.Effect = [System.Windows.Forms.DragDropEffects]::None
			Set-CombineDropHighlight -Highlighted $false
		}
	}

	$combineDragOverHandler = {
		param($sender, $e)
		if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
			$e.Effect = [System.Windows.Forms.DragDropEffects]::Copy
			Set-CombineDropHighlight -Highlighted $true
		} else {
			$e.Effect = [System.Windows.Forms.DragDropEffects]::None
			Set-CombineDropHighlight -Highlighted $false
		}
	}

	$combineDragLeaveHandler = {
		param($sender, $e)
		Set-CombineDropHighlight -Highlighted $false
	}

	$combineDragDropHandler = {
		param($sender, $e)
		Set-CombineDropHighlight -Highlighted $false
		$droppedPaths = @($e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop))
		$videos = @(Get-CombineVideoFiles -Paths $droppedPaths)
		if ($videos.Count -lt 2) {
			Write-Log "Combine drop ignored. Drop at least two video files or a folder with video files." $logBox
			[System.Windows.Forms.MessageBox]::Show("Drop at least two video files or a folder with video files.", "Combine videos", "OK", "Information") | Out-Null
			return
		}
		$combineVideos.Clear()
		foreach ($video in $videos) {
			[void]$combineVideos.Add($video)
		}
		Write-Log "Combine list set: $($combineVideos.Count) video(s), alphabetical order." $logBox
		foreach ($video in $combineVideos) {
			Write-Log "  $($video.Name)" $logBox
		}
		Update-CombineDropState
	}

	function New-ConversionJobFromInputs {
		param(
			[ValidateSet("WebmVp9", "Ogv", "Mp4Copy")]
			[string]$OutputKind = "WebmVp9"
		)

		$outputDir = $outputBox.Text.Trim()
		if ([string]::IsNullOrWhiteSpace($outputDir)) {
			[System.Windows.Forms.MessageBox]::Show("Choose an output folder first.", "Missing output", "OK", "Warning") | Out-Null
			return $null
		}

		$source = ""
		$videos = @()
		$sourceLabelText = ""
		if ($sourceVideos.Count -gt 0) {
			foreach ($selectedVideo in $sourceVideos) {
				if ($null -ne $selectedVideo -and (Test-SourceVideoPath -Path $selectedVideo.FullName)) {
					$videos += (Get-Item -LiteralPath $selectedVideo.FullName)
				}
			}
			if ($videos.Count -gt 0) {
				$source = [string]$videos[0].FullName
				if ($videos.Count -eq 1) {
					$sourceLabelText = $videos[0].Name
				} else {
					$sourceLabelText = "$($videos.Count) selected source videos"
				}
			}
		} else {
			$source = $sourceBox.Text.Trim()
			if ([string]::IsNullOrWhiteSpace($source) -or -not (Test-Path -LiteralPath $source)) {
				[System.Windows.Forms.MessageBox]::Show("Choose video file(s) or a folder first.", "Missing source", "OK", "Warning") | Out-Null
				return $null
			}
			$videos = @(Get-InputVideos -SourcePath $source -IncludeSubfolders $recursiveCheck.Checked)
			$sourceLabelText = Split-Path -Leaf $source
			if ([string]::IsNullOrWhiteSpace($sourceLabelText)) {
				$sourceLabelText = $source
			}
		}

		if ($videos.Count -eq 0) {
			[System.Windows.Forms.MessageBox]::Show("No supported video files found.", "Nothing to convert", "OK", "Information") | Out-Null
			return $null
		}

		Save-CurrentSettings
		$trimStartSeconds = [double]::Parse([string]$trimStartBox.SelectedItem, [System.Globalization.CultureInfo]::InvariantCulture)
		$trimSeconds = [double]::Parse([string]$trimBox.SelectedItem, [System.Globalization.CultureInfo]::InvariantCulture)
		$trimSummaryParts = @()
		if ($trimStartSeconds -gt 0.0) {
			$trimSummaryParts += "trim start by $(Format-SecondsOption -Seconds $trimStartSeconds)s"
		}
		if ($trimSeconds -gt 0) {
			$trimSummaryParts += "trim end by $(Format-SecondsOption -Seconds $trimSeconds)s"
		}
		$trimSummary = ""
		if ($trimSummaryParts.Count -gt 0) {
			$trimSummary = ", " + ($trimSummaryParts -join ", ")
		}
		$actionSummary = switch ($OutputKind) {
			"Mp4Copy" { "export MP4" }
			"Ogv" { "convert OGV" }
			default { "convert WebM VP9" }
		}

		return [pscustomobject]@{
			SourcePath = $source
			OutputDir = $outputDir
			Videos = $videos
			Quality = [string]$qualityBox.SelectedItem
			Downscale1080 = ((Normalize-OutputResolution -Value ([string]$resolutionBox.SelectedItem)) -eq "1920x1080")
			OutputResolution = (Normalize-OutputResolution -Value ([string]$resolutionBox.SelectedItem))
			Overwrite = $overwriteCheck.Checked
			OutputKind = $OutputKind
			Mp4Codec = (Normalize-Mp4Codec -Value ([string]$mp4CodecBox.SelectedItem))
			ParallelJobs = [int]$parallelBox.Value
			TrimStartSeconds = $trimStartSeconds
			TrimSeconds = $trimSeconds
			Summary = "$actionSummary $($videos.Count) file(s) from $sourceLabelText$trimSummary"
		}
	}

	function Enqueue-ConversionJob {
		param([pscustomobject]$Job)

		$conversionQueue.Enqueue($Job)
		Write-Log "Queued: $($Job.Summary) -> $($Job.OutputDir)" $logBox
		Update-QueueStatus
	}

	function Process-QueuedJobs {
		if ($isProcessing) {
			return
		}

		$script:CancelRequested = $false
		$script:ActiveConversionProcesses.Clear()
		Set-Variable -Name isProcessing -Value $true -Scope 1
		$installButton.Enabled = $false
		$locateButton.Enabled = $false
		Update-ConvertButtonState
		Update-QueueStatus

		$generatedAny = $false
		$wasCanceled = $false
		try {
			while ($conversionQueue.Count -gt 0) {
				$job = [pscustomobject]$conversionQueue.Dequeue()
				Update-QueueStatus
				Write-Log "Starting job: $($job.Summary) -> $($job.OutputDir)" $logBox
				$jobResult = Invoke-ConversionJob -Job $job -LogBox $logBox -ProgressBar $progressBar -ProgressLabel $progressStatus
				if ($jobResult.Success -gt 0) {
					$generatedAny = $true
				}
				if ($jobResult.Canceled) {
					$wasCanceled = $true
					break
				}
				if ($conversionQueue.Count -gt 0) {
					Write-Log "$($conversionQueue.Count) queued job(s) remaining." $logBox
				}
				Update-QueueStatus
			}
			if ($generatedAny -and -not $wasCanceled) {
				Clear-SourceSelection
				Save-CurrentSettings
				Write-Log "Source video selection auto-cleared after output generation." $logBox
			}
		} finally {
			$script:ActiveConversionProcesses.Clear()
			$script:CancelRequested = $false
			Set-Variable -Name isProcessing -Value $false -Scope 1
			$installButton.Enabled = $true
			$locateButton.Enabled = $true
			Update-ConvertButtonState
			Update-QueueStatus
		}
	}

	$sourceBox.Add_TextChanged({
		if (-not $sourceUiState.IsUpdatingSourceBox) {
			if ($sourceVideos.Count -gt 0) {
				$sourceVideos.Clear()
			}
			Update-SourceSelectionState
		}
	})

	$clearSourceButton.Add_Click({
		Clear-SourceSelection
		Save-CurrentSettings
		Write-Log "Source video selection cleared." $logBox
	})

	$fileButton.Add_Click({
		$dialog = New-Object System.Windows.Forms.OpenFileDialog
		$dialog.Title = "Choose source video file(s)"
		$dialog.Filter = "Video files (*.mp4;*.webm;*.ogv;*.mov;*.mkv;*.avi;*.m4v;*.wmv;*.flv)|*.mp4;*.webm;*.ogv;*.mov;*.mkv;*.avi;*.m4v;*.wmv;*.flv|All files (*.*)|*.*"
		$dialog.Multiselect = $true
		if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
			$videos = @(Get-SourceVideosFromPaths -Paths @($dialog.FileNames) -IncludeSubfolders $false)
			if ($videos.Count -eq 0) {
				[System.Windows.Forms.MessageBox]::Show("Choose supported video file(s).", "Unsupported source", "OK", "Information") | Out-Null
				return
			}
			$append = ($videos.Count -eq 1 -and $sourceVideos.Count -gt 0)
			[void](Add-SourceVideosToSelection -Videos $videos -Replace (-not $append) -SortAlphabetically (-not $append))
			Save-CurrentSettings
			Write-Log "Source file selection set: $($sourceVideos.Count) video(s)." $logBox
		}
	})

	$folderButton.Add_Click({
		$dialog = New-Object System.Windows.Forms.FolderBrowserDialog
		$dialog.Description = "Choose a folder containing video files"
		if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
			Clear-SourceVideos
			Set-SourceBoxText -Text $dialog.SelectedPath
			Save-CurrentSettings
		}
	})

	$outputButton.Add_Click({
		$dialog = New-Object System.Windows.Forms.FolderBrowserDialog
		$dialog.Description = "Choose the output folder"
		$dialog.SelectedPath = $outputBox.Text
		if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
			$outputBox.Text = $dialog.SelectedPath
			Save-CurrentSettings
		}
	})

	foreach ($dropTarget in @($dropPanel, $dropTitle, $dropHint, $dropSubHint)) {
		$dropTarget.Add_DragEnter($dragEnterHandler)
		$dropTarget.Add_DragOver($dragOverHandler)
		$dropTarget.Add_DragLeave($dragLeaveHandler)
		$dropTarget.Add_DragDrop($dragDropHandler)
	}

	foreach ($combineDropTarget in @($combineDropPanel, $combineDropLabel, $combineDropHint)) {
		$combineDropTarget.Add_DragEnter($combineDragEnterHandler)
		$combineDropTarget.Add_DragOver($combineDragOverHandler)
		$combineDropTarget.Add_DragLeave($combineDragLeaveHandler)
		$combineDropTarget.Add_DragDrop($combineDragDropHandler)
	}

	$locateButton.Add_Click({
		$dialog = New-Object System.Windows.Forms.OpenFileDialog
		$dialog.Title = "Locate ffmpeg.exe"
		$dialog.Filter = "ffmpeg.exe|ffmpeg.exe|Executables (*.exe)|*.exe"
		if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
			$script:FfmpegPath = $dialog.FileName
			Save-CurrentSettings
			Update-FfmpegStatus
			Write-Log "Using FFmpeg at $script:FfmpegPath" $logBox
		}
	})

	$installButton.Add_Click({
		$installButton.Enabled = $false
		$convertButton.Enabled = $false
		$convertOgvButton.Enabled = $false
		$exportMp4Button.Enabled = $false
		$combineButton.Enabled = $false
		try {
			if (Install-PortableFfmpeg -LogBox $logBox) {
				Save-CurrentSettings
			}
		} finally {
			$installButton.Enabled = $true
			Update-FfmpegStatus
		}
	})

	$moreFormatsCheck.Add_CheckedChanged({
		Update-ConvertButtonState
	})

	$mp4CodecBox.Add_SelectedIndexChanged({
		Save-CurrentSettings
	})

	$resolutionBox.Add_SelectedIndexChanged({
		Save-CurrentSettings
	})

	$openOutputButton.Add_Click({
		if (-not (Test-Path -LiteralPath $outputBox.Text)) {
			New-Item -ItemType Directory -Force -Path $outputBox.Text | Out-Null
		}
		Start-Process explorer.exe -ArgumentList (Quote-Arg $outputBox.Text)
	})

	$stopButton.Add_Click({
		if (-not $isProcessing -or (Test-CancelRequested)) {
			return
		}

		$queuedJobs = $conversionQueue.Count
		$script:CancelRequested = $true
		$conversionQueue.Clear()
		Write-Log "Cancel requested. Stopping current conversion work and clearing $queuedJobs queued job(s)." $logBox
		Set-ConversionProgress -ProgressBar $progressBar -StatusLabel $progressStatus -Percent $progressBar.Value -Message "Canceling..."
		Update-ConvertButtonState
		Update-QueueStatus
		Stop-ActiveConversionProcesses
	})

	$convertButton.Add_Click({
		$job = New-ConversionJobFromInputs -OutputKind "WebmVp9"
		if ($job -eq $null) {
			return
		}

		Enqueue-ConversionJob -Job $job
		Process-QueuedJobs
	})

	$convertOgvButton.Add_Click({
		$job = New-ConversionJobFromInputs -OutputKind "Ogv"
		if ($job -eq $null) {
			return
		}

		Enqueue-ConversionJob -Job $job
		Process-QueuedJobs
	})

	$exportMp4Button.Add_Click({
		$job = New-ConversionJobFromInputs -OutputKind "Mp4Copy"
		if ($job -eq $null) {
			return
		}

		Enqueue-ConversionJob -Job $job
		Process-QueuedJobs
	})

	$clearCombineButton.Add_Click({
		$combineVideos.Clear()
		Update-CombineDropState
		Write-Log "Combine list cleared." $logBox
	})

	$combineButton.Add_Click({
		if ($isProcessing -or $combineVideos.Count -lt 2) {
			return
		}

		$script:CancelRequested = $false
		$script:ActiveConversionProcesses.Clear()
		Set-Variable -Name isProcessing -Value $true -Scope 1
		$installButton.Enabled = $false
		$locateButton.Enabled = $false
		Update-ConvertButtonState
		Update-QueueStatus
		try {
			$result = Invoke-CombineVideos -Videos @($combineVideos) -Overwrite $overwriteCheck.Checked -LogBox $logBox -ProgressBar $progressBar -ProgressLabel $progressStatus
			if ($result.Status -eq "canceled") {
				Write-Log "Combine canceled." $logBox
			}
		} finally {
			$script:ActiveConversionProcesses.Clear()
			$script:CancelRequested = $false
			Set-Variable -Name isProcessing -Value $false -Scope 1
			$installButton.Enabled = $true
			$locateButton.Enabled = $true
			Update-ConvertButtonState
			Update-QueueStatus
		}
	})

	$form.Add_FormClosing({
		Save-CurrentSettings
	})

	Update-FfmpegStatus
	Update-QueueStatus
	Update-SourceSelectionState
	Update-CombineDropState
	Save-CurrentSettings
	Write-Log "Ready. Select video file(s) or a folder of video files." $logBox
	Write-Log "Export MP4 defaults to H264 and follows trim, the MP4 codec dropdown, and the resolution dropdown." $logBox
	Write-Log "More Formats reveals WebM VP9 and OGV." $logBox
	Write-Log "Batch jobs can use more CPU by converting multiple files at once; WebM VP9 and OGV encoding are CPU-based." $logBox
	Write-Log "Drop videos into the combine box to merge them alphabetically into one _combined output." $logBox
	Write-Log "While a conversion is running, change the source and click Add to Queue to append another job." $logBox
	Write-Log "Click Stop to cancel the current conversion and clear any queued jobs." $logBox
	[void]$form.ShowDialog()
}

if ($SmokeTest) {
	$script:FfmpegPath = Find-Ffmpeg
	Write-Host "AppDir=$script:AppDir"
	Write-Host "DefaultOutputDir=$script:DefaultOutputDir"
	Write-Host "FfmpegPath=$script:FfmpegPath"
	exit 0
}

if ($InstallFfmpeg) {
	if (Install-PortableFfmpeg) {
		Save-Config -FfmpegPath $script:FfmpegPath -OutputDir (Get-ConfiguredOutputDir) -SourcePath (Get-ConfiguredString -Name "sourcePath" -DefaultValue "") -Quality (Get-ConfiguredQuality) -Downscale1080 ((Get-ConfiguredOutputResolution) -eq "1920x1080") -IncludeSubfolders (Get-ConfiguredBool -Name "includeSubfolders" -DefaultValue $false) -Overwrite (Get-ConfiguredBool -Name "overwrite" -DefaultValue $true) -ParallelJobs (Get-ConfiguredParallelJobs) -TrimStartSeconds (Get-ConfiguredTrimStartSeconds) -TrimSeconds (Get-ConfiguredTrimSeconds) -Mp4Codec (Get-ConfiguredMp4Codec) -OutputResolution (Get-ConfiguredOutputResolution)
		exit 0
	}
	exit 1
}

Start-Gui
