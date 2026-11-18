# Local storage for Mac and Windows

Choose this route to use free space on a Windows internal drive or an external NTFS drive connected to it. The Mac uses Finder's built-in SMB client. Both devices read and write the same Windows folder. For access from another network, use the optional Tailscale setup below.

## Share the folder from Windows

1. Choose a new folder named **Cloud Storage** on a local NTFS drive. The example uses D:. Use the letter of your selected drive. Keep the drive connected, and enable BitLocker or suitable volume encryption before using it for important files.
2. Get the Mac's IPv4 address from **System Settings → Network**. Get the Windows interface and profile with `Get-NetConnectionProfile`. The example values are for a trusted home LAN. The script limits SMB to the specified Mac address and uses a dedicated local account. Set a DHCP reservation or rerun the configuration if the DHCP addresses change.
3. Open 64-bit Windows PowerShell as administrator in the clone and run the command below using your actual values. Add `-WhatIf` for a read-only preflight. At the prompt, choose a long unique passphrase or press Enter to generate one. Save the generated password from the setup window.

   ```powershell
   .\scripts\Enable-WindowsShare.ps1 -DataDirectory 'D:\Cloud Storage' -LanInterface 'Wi-Fi' -MacLanIp '192.168.50.20'
   ```

If the LAN profile is Public and you trust that specific network, pass its exact name with `-TrustedLanName` to switch it to Private. The script checks for other broad SMB rules and stops for review when it finds one. Use `-ShareUserName` if you need a different dedicated account name. The default is `projectdrive-smb`.

## Open the same folder on both devices

- **Windows** opens the folder you selected directly in File Explorer. Right-click **Cloud Storage** and pin it to Quick Access for a sidebar shortcut.
- **Mac** uses **⌘K** in Finder. Enter the address printed by the Windows script, such as `smb://192.168.50.10/Cloud%20Storage`. Sign in as `WINDOWS-PC\projectdrive-smb` with the share password, replacing `WINDOWS-PC` with your computer name.
- **Finder sidebar** can show the folder as **Cloud Storage**. Open `/Volumes` in Finder and drag the mounted Cloud Storage volume into **Favorites**. Clear **Connected servers** in Finder's Sidebar settings if you want to hide server addresses in Locations. That setting applies to all connected servers. [Apple Finder sidebar guide](https://support.apple.com/en-qa/guide/mac-help/mchl83c9e8b8/mac)

The PC stays awake and connected while the Mac uses the share. Save a disposable file on each device and confirm it appears on the other.

## Optional Tailscale access away from home

Install Tailscale on both devices and join them to the same private tailnet. Use the devices' Tailscale IPv4 addresses. In the tailnet policy, allow the Mac to access the Windows PC on TCP 445. Review grants and ACLs that could also allow that port.

```json
{
  "grants": [
    {
      "src": ["100.64.0.20"],
      "dst": ["100.64.0.10"],
      "ip": ["tcp:445"]
    }
  ]
}
```

Merge the example entry with your existing policy and replace the example IPs with the Mac and Windows tailnet addresses. Rerun the Windows script with `-MacTailnetIp`. Include both sets of network arguments if using both LAN and Tailscale. Tailscale-only mode can keep the Windows Wi-Fi profile Public.

```powershell
.\scripts\Enable-WindowsShare.ps1 -DataDirectory 'D:\Cloud Storage' -MacTailnetIp '100.64.0.20'
```

Connect through the Windows tailnet IP in Finder, such as `smb://100.64.0.10/Cloud%20Storage`. Keep TCP 445 private and leave router port forwarding off. [Tailscale grants](https://tailscale.com/docs/reference/syntax/grants) · [Tailscale plans](https://tailscale.com/pricing)

## Add the friendly name to an existing installation

For a ProjectDrive share created by these scripts, rerun the setup with the existing `-DataDirectory`, `-ShareUserName` and authorized network arguments, plus `-CloudStorageAliasOnly`. If useful, pass a new `-ExplorerDirectory` named **Cloud Storage** to create a Windows junction that opens the same data. The SMB alias points to the current folder.
