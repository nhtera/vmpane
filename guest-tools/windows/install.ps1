# VMPane guest tools for Windows 11 ARM64. Runs from the VMPANE_TOOLS disc: at the first logon of an
# unattended install (FirstLogonCommands, elevated) or by hand ("Update guest tools"). Idempotent; logs to
# C:\ProgramData\VMPane\tools-install.log.
#   1. drivers: every INF under drivers\ (virtio-win ARM64 w11, the set that passed Gate 00 S2), with pnputil;
#      viogpudo is installed while ramfb is the only display (VMPane adds virtio-gpu afterwards);
#   2. reports "VMPANE-INSTALL firstLogon" on the VMPane agent port (it exists once vioserial is installed);
#   3. spice-vdagent (clipboard, display resize) and the VMPane agent, when the disc has them;
#   4. reports "VMPANE-INSTALL toolsInstalled": VMPane then shuts Windows down and restarts it with its network
#      and virtio display. That is why the unattend runs this script last, after it removed the password.
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
        if ([VMPanePort]::Send("VMPANE-INSTALL $phase")) { Log "reported $phase"; return }
        Start-Sleep -Seconds 1
    }
    Log "could not report $phase (no agent port)"
}

Log "VMPane guest tools from $root (unattended: $Unattended)"

# 1. Drivers
$drivers = Join-Path $root 'drivers'
foreach ($dir in Get-ChildItem -Path $drivers -Directory -ErrorAction SilentlyContinue | Sort-Object Name) {
    $output = & pnputil.exe /add-driver (Join-Path $dir.FullName '*.inf') /subdirs /install 2>&1
    Log ("driver {0}: exit {1} {2}" -f $dir.Name, $LASTEXITCODE, (($output | Select-Object -Last 2) -join ' '))
}

# 2. The VMPane agent port works now.
Report 'firstLogon'

# 3. spice-vdagent and the VMPane agent (installers on the disc, when present)
foreach ($msi in @(Get-ChildItem -Path $root -Filter '*.msi' -Recurse -ErrorAction SilentlyContinue)) {
    $process = Start-Process -FilePath msiexec.exe -ArgumentList @('/i', "`"$($msi.FullName)`"", '/qn', '/norestart') -Wait -PassThru
    Log ("installer {0}: exit {1}" -f $msi.Name, $process.ExitCode)
}

# 4. Done: VMPane restarts the VM with its network and virtio display.
Report 'toolsInstalled'
Log 'done'
