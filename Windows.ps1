$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$Repository = "https://github.com/xRookieFight/VortexSync"
$CargoHome = if ($env:CARGO_HOME) {
  $env:CARGO_HOME
} else {
  Join-Path $HOME ".cargo"
}
$CargoBin = Join-Path $CargoHome "bin"
$TempDir = Join-Path $env:TEMP "VortexSyncInstaller"
$VsInstaller = Join-Path $TempDir "vs_buildtools.exe"

function Write-Step([string]$Message) {
  Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Stop-Install([string]$Message) {
  throw $Message
}

function Download-File([string]$Url, [string]$Destination) {
  Write-Host "Downloading $Url"

  Invoke-WebRequest `
    -Uri $Url `
    -OutFile $Destination `
    -UseBasicParsing
}

function Invoke-Checked(
  [string]$File,
  [string[]]$Arguments
) {
  & $File @Arguments

  if ($LASTEXITCODE -ne 0) {
    Stop-Install "$File failed with exit code $LASTEXITCODE."
  }
}

function Test-Command([string]$Name) {
  return $null -ne (
    Get-Command $Name -ErrorAction SilentlyContinue
  )
}

function Add-UserPath([string]$Directory) {
  $CurrentPath = [Environment]::GetEnvironmentVariable(
    "Path",
    "User"
  )

  $Entries = @(
    $CurrentPath -split ";" |
        Where-Object { $_.Trim() -ne "" }
  )

  $Exists = $false

  foreach ($Entry in $Entries) {
    if ($Entry.TrimEnd("\") -ieq $Directory.TrimEnd("\")) {
        $Exists = $true
        break
    }
  }

  if (-not $Exists) {
    $NewPath = (@($Entries) + $Directory) -join ";"

    [Environment]::SetEnvironmentVariable(
        "Path",
        $NewPath,
        "User"
    )
  }

  if ($env:PATH -notlike "*$Directory*") {
    $env:PATH = "$Directory;$env:PATH"
  }
}

try {
  Write-Host "VortexSync Installer" -ForegroundColor Green
  Write-Host "This installer will install Rust, build tools, and VortexSync."

  $Architecture = $env:PROCESSOR_ARCHITECTURE

  switch ($Architecture) {
    "AMD64" {
        $RustTarget = "x86_64-pc-windows-msvc"
    }
    "ARM64" {
        $RustTarget = "aarch64-pc-windows-msvc"
    }
    default {
        Stop-Install "Unsupported architecture: $Architecture"
    }
  }

  New-Item -ItemType Directory -Path $TempDir -Force |
    Out-Null

  Write-Step "Checking C++ build tools"

  $VsWhere = Join-Path `
    ${env:ProgramFiles(x86)} `
    "Microsoft Visual Studio\Installer\vswhere.exe"

  $HasBuildTools = $false

  if (Test-Path $VsWhere) {
    $VsPath = & $VsWhere `
        -latest `
        -products "*" `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath

    if ($LASTEXITCODE -eq 0 -and $VsPath) {
        $HasBuildTools = $true
        Write-Host "Existing MSVC build tools found."
    }
  }

  if (-not $HasBuildTools) {
    Write-Step "Installing Microsoft C++ Build Tools and Windows SDK"

    Download-File `
        "https://aka.ms/vs/17/release/vs_buildtools.exe" `
        $VsInstaller

    $Signature = Get-AuthenticodeSignature $VsInstaller

    if ($Signature.Status -ne "Valid" -or
        $Signature.SignerCertificate.Subject -notmatch "Microsoft") {
        Stop-Install "The Microsoft installer signature could not be verified."
    }

    $InstallPath = Join-Path `
        ${env:ProgramFiles(x86)} `
        "Microsoft Visual Studio\2022\BuildTools"

    $VsArguments = @(
        "--quiet",
        "--wait",
        "--norestart",
        "--nocache",
        "--installPath",
        "`"$InstallPath`"",
        "--add",
        "Microsoft.VisualStudio.Workload.VCTools",
        "--includeRecommended"
    )

    Write-Host "Microsoft's installer may request administrator approval."

    $Process = Start-Process `
        -FilePath $VsInstaller `
        -ArgumentList $VsArguments `
        -Verb RunAs `
        -Wait `
        -PassThru

    if ($Process.ExitCode -notin @(0, 1641, 3010)) {
        Stop-Install "Build Tools installation failed with exit code $($Process.ExitCode)."
    }

    Write-Host "C++ build tools installation finished."
  }

  Write-Step "Checking Rust and Cargo"

  $Rustup = Join-Path $CargoBin "rustup.exe"
  $Cargo = Join-Path $CargoBin "cargo.exe"

  if (-not (Test-Path $Rustup)) {
    Write-Step "Installing Rust"

    $RustupInstaller = Join-Path $TempDir "rustup-init.exe"
    $RustupUrl = "https://static.rust-lang.org/rustup/dist/$RustTarget/rustup-init.exe"

    Download-File $RustupUrl $RustupInstaller

    $Signature = Get-AuthenticodeSignature $RustupInstaller

    if ($Signature.Status -ne "Valid" -or
        $Signature.SignerCertificate.Subject -notmatch "Rust") {
        Stop-Install "The Rust installer signature could not be verified."
    }

    Invoke-Checked $RustupInstaller @(
        "-y",
        "--default-host", $RustTarget,
        "--default-toolchain", "stable",
        "--profile", "minimal"
    )
  }

  if (-not (Test-Path $Cargo)) {
    Stop-Install "Cargo was not found at $Cargo."
  }

  Add-UserPath $CargoBin

  Write-Step "Installing or updating the stable Rust toolchain"

  Invoke-Checked $Rustup @(
    "toolchain", "install", "stable",
    "--profile", "minimal"
  )

  Write-Step "Installing VortexSync from GitHub"

  Invoke-Checked $Cargo @(
    "+stable",
    "install",
    "--git", $Repository,
    "--locked"
  )

  Write-Host "`nVortexSync installed successfully!" -ForegroundColor Green
}
catch {
  Write-Host "`nInstallation failed:" -ForegroundColor Red
  Write-Host $_.Exception.Message -ForegroundColor Red
  exit 1
}
finally {
  Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
}
