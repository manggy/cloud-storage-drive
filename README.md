# Cloud Storage Drive

Use a Windows disk you already own from Finder, or mount Amazon S3 as a shared filesystem. Keep large files on the selected storage and open them through Finder or File Explorer on demand.

| Setup | Where files live | What needs to be online |
| --- | --- | --- |
| **1. Local Windows storage for Mac** | An internal or external NTFS disk attached to Windows | Windows PC. Optional Tailscale access for the Mac away from home. |
| **2. S3 for Mac only** | A private S3 bucket | Mac and internet. The Mac hosts the file index and keeps a small disk cache. |
| **3. S3 for Mac and Windows** | A private S3 bucket | Internet and a shared file index. Use the Mac as the index host or choose the optional Lightsail setup for independent access. |

## Start here

Clone this repository, then follow the guide for your devices.

```bash
git clone https://github.com/manggy/cloud-storage-drive.git
cd cloud-storage-drive
```

1. **Use an existing Windows disk.** Get a native **Cloud Storage** folder on both devices, with no cloud storage bill. [Local Windows and Mac setup](docs/local.md)
2. **Use S3 on one Mac.** Get a native Finder mount with on-demand file reads and an encrypted, bounded cache volume. [S3 setup for Mac](docs/s3.md#mac-only)
3. **Use S3 on both computers.** Mount one filesystem in Finder and File Explorer. Windows reaches the file index through Tailscale. [S3 setup for Mac and Windows](docs/s3.md#mac-and-windows)

An SMB save or copy is available to both devices through the same Windows folder once it finishes. The S3 version uses JuiceFS to give both configured clients a shared filesystem. The share can store files of any type with compatible filenames. Opening a file requires an app that supports its format.

## Cost and recovery

The local setup uses the capacity of your existing Windows disk. With S3 Standard in Ohio, 100 GB stored for a full month costs about **$2.30 USD for storage**, before request charges, internet downloads, and credits. Heavy downloads can dominate the bill. The S3 guide covers AWS credentials, billing, and cost controls. [Ohio S3 price list](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonS3/current/us-east-2/index.json)

Keep a separate backup before moving important files. The [operations guide](docs/operations.md) covers a 20 GB smoke test, cross-device checks, dated backups, and an index restore drill.

## Verification

The local SMB data path and Windows file notifications were exercised on Windows. The S3 infrastructure has mock-provider tests, and PostgreSQL and JuiceFS were exercised with disposable local file storage. Run the acceptance checks on your devices and AWS account before relying on the S3 mounts for important files.

Released under the [MIT License](LICENSE).
