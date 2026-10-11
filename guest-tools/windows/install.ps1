# VMPane guest tools for Windows 11 ARM64. Runs from the VMPANE_TOOLS disc: at the first logon of an
# unattended install (FirstLogonCommands, elevated) or by hand ("Update guest tools"). Idempotent; logs to
# C:\ProgramData\VMPane\tools-install.log.
#   1. drivers: every INF under drivers\ (virtio-win ARM64 w11, the set that passed Gate 00 S2), with pnputil;
#      viogpudo is installed while ramfb is the only display (VMPane adds virtio-gpu afterwards);
#   2. reports "VMPANE-INSTALL firstLogon" on the VMPane agent port (it exists once vioserial is installed);
#   3. spice-vdagent (clipboard, display resize) and the VMPane agent, when the disc has them;
#   4. unattended: checks the install's password is gone from Windows (Setup's answer copies, the auto-logon
#      password; the unattend removed them before running this script) and, only then,
#   5. reports "VMPANE-INSTALL toolsInstalled" and shuts Windows down: VMPane restarts it with its network and
#      virtio display. Unreported, the install times out as failed and VMPane asks the user to change the password.
param([switch]$Unattended)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$logDir = Join-Path $env:ProgramData 'VMPane'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir 'tools-install.log'

function Log([string]$message) {
    $line = '{0:yyyy-MM-ddTHH:mm:ss} {1}' -f (Get-Date), $message
    Add-Content -Path $log -Value $line
    Write-Host $line
}

# The agent port is a device path (\\.\Global\...), which .NET's FileStream refuses: open it with CreateFile.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class VMPanePort {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteFile(SafeFileHandle file, byte[] buffer, uint count, out uint written, IntPtr overlapped);
    public static bool Send(string line) {
        using (SafeFileHandle port = CreateFile(@"\\.\Global\app.vmpane.agent.0", 0x40000000, 0, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
            if (port.IsInvalid) { return false; }
            byte[] bytes = System.Text.Encoding.ASCII.GetBytes(line + "\n");
            uint written;
            return WriteFile(port, bytes, (uint)bytes.Length, out written, IntPtr.Zero) && written == bytes.Length;
        }
    }
}
'@

function Report([string]$phase) {
    # The port appears a moment after vioserial binds: retry for up to a minute.
    for ($i = 0; $i -lt 60; $i++) {
        if ([VMPanePort]::Send("VMPANE-INSTALL $phase")) { Log "reported $phase"; return $true }
        Start-Sleep -Seconds 1
    }
    Log "could not report $phase (no agent port)"
    return $false
}

Log "VMPane guest tools from $root (unattended: $Unattended)"

# 1. Drivers
$drivers = Join-Path $root 'drivers'
foreach ($dir in Get-ChildItem -Path $drivers -Directory -ErrorAction SilentlyContinue | Sort-Object Name) {
    $output = & pnputil.exe /add-driver (Join-Path $dir.FullName '*.inf') /subdirs /install 2>&1
    Log ("driver {0}: exit {1} {2}" -f $dir.Name, $LASTEXITCODE, (($output | Select-Object -Last 2) -join ' '))
}

# 2. The VMPane agent port works now.
Report 'firstLogon' | Out-Null

# 3. spice-vdagent and the VMPane agent (installers on the disc, when present)
foreach ($msi in @(Get-ChildItem -Path $root -Filter '*.msi' -Recurse -ErrorAction SilentlyContinue)) {
    $process = Start-Process -FilePath msiexec.exe -ArgumentList @('/i', "`"$($msi.FullName)`"", '/qn', '/norestart') -Wait -PassThru
    Log ("installer {0}: exit {1}" -f $msi.Name, $process.ExitCode)
}

# The MSI installs the agent service without starting it: during an unattended install this script still needs
# the agent port (a single-open device) for its reports, and the service starts with the restart that follows.
# By hand ("Update guest tools"), start it now; an upgrade stopped the old one.
if (-not $Unattended) {
    Start-Service -Name vmpane-agent -ErrorAction SilentlyContinue
    Log ("agent service: {0}" -f (Get-Service -Name vmpane-agent -ErrorAction SilentlyContinue).Status)
    Log 'done'
    exit 0
}

# 4. The install's password, removed again in case a FirstLogonCommand failed, then checked.
$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$answers = @("$env:WINDIR\Panther\unattend*.xml", "$env:WINDIR\Panther\Unattend\unattend*.xml")
Remove-ItemProperty -Path $winlogon -Name DefaultPassword -ErrorAction SilentlyContinue
Set-ItemProperty -Path $winlogon -Name AutoAdminLogon -Value '0' -ErrorAction SilentlyContinue
Remove-Item -Path $answers -Force -ErrorAction SilentlyContinue
$left = @(Get-ItemProperty -Path $winlogon -Name DefaultPassword -ErrorAction SilentlyContinue) +
    @(Get-ChildItem -Path $answers -ErrorAction SilentlyContinue)
if ($left.Count -gt 0) { Log "the install's password is still in Windows ($($left.Count) copies); not reporting"; exit 1 }
Log 'the install password is removed'

# 5. Done: VMPane restarts the VM with its network and virtio display once Windows is down.
if (Report 'toolsInstalled') { & shutdown.exe /s /t 5 /c 'VMPane is finishing the install' }
Log 'done'
