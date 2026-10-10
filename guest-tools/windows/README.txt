VMPane guest tools for Windows 11 on Arm
=========================================

This disc holds the drivers and tools a Windows VM needs under VMPane:

  drivers\     virtio drivers for Arm64 Windows 11 (virtio-win): storage (viostor), network (NetKVM),
               display (viogpudo), input (vioinput), serial ports (vioserial), memory balloon (Balloon),
               random numbers (viorng) and crash reporting (pvpanic)
  install.ps1  installs the drivers and any tools on this disc; logs to
               C:\ProgramData\VMPane\tools-install.log
  LICENSES\    the licences of the software on this disc

VMPane runs install.ps1 by itself at the end of an automatic Windows install. To run it by hand (for example
to update the tools), open PowerShell as administrator and run:

  powershell -NoProfile -ExecutionPolicy Bypass -File D:\install.ps1

replacing D: with the letter of the VMPANE_TOOLS drive. Running it again is safe.
