SPSE Dev-Box Setup
==================

All setup scripts have been provisioned to C:\Installs.

To start the automated install:
  1. Open an elevated PowerShell prompt (Run as Administrator).
  2. Run:  C:\Installs\Start-Setup.ps1

The bootstrap will execute 13 phases (AD DS, SQL, SharePoint, VS 2026).
Some phases require a reboot - a scheduled task will resume automatically.
Progress is tracked in C:\SPSESetup\state.json.
