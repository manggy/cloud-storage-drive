# Cloud Storage Drive

Cloud Storage Drive lets you use a Windows PC as a home file server. Share a folder from an internal or external drive, then open that same **Cloud Storage** folder in Finder on your Mac and File Explorer on Windows.

- **Work together from different computers.** Save a design file on your MacBook, and someone on the Windows PC can open the updated version from the same project folder.
- **Free up space on your Mac or PC.** Move large files like video footage to a drive with room to spare and open them from the shared folder when you need them.

You can also keep the shared drive's files in private Amazon S3 storage in your own AWS account.

## Set it up with an agent

Paste this into a coding agent that can run commands on your computer. The agent can walk you through any steps it needs you to do on another device.

```text
Set up Cloud Storage Drive for me using https://github.com/manggy/cloud-storage-drive.

Read the README, then ask which computers need access, where I want the files
to live, and whether I need to connect away from home or while the other
computer is off. Recommend a setup and ask only for the details it needs.
If we're using AWS, ask which account and region to use, how much I expect
to store and download, and what I'm willing to spend.

Tell me what you'll change and ask before changing network access or creating
AWS resources. If we're using AWS, show me the estimated charges first. Have
me sign in and enter passwords on the device so secrets stay out of chat.

Follow the guide for the setup we choose. Do the work on the devices you can
access and give me the exact steps for any others. Then open the drive, check
that each device can save and read a test file, and tell me how to reconnect.
```

## Set it up yourself

Clone this repo and follow the guide for your setup.

```bash
git clone https://github.com/manggy/cloud-storage-drive.git
cd cloud-storage-drive
```

| Setup | How it works |
| --- | --- |
| [Share a Windows drive with your Mac](docs/local.md) | Both computers open the same Windows folder. The PC stays awake while you use it from the Mac. Add Tailscale if you need access away from home. This setup has no cloud storage bill. |
| [Use S3 on one Mac](docs/s3.md#mac-only) | Open the drive in Finder. The Mac keeps track of your files and downloads them as you open them. |
| [Use S3 on Mac and Windows](docs/s3.md#mac-and-windows) | Both computers open the same drive. By default, Windows needs the Mac online. A [small cloud server](docs/s3.md#optional-hosted-index) can keep track of the files so either computer can connect while the other is off. |

With S3, AWS can charge for storage, requests, and downloads. The optional cloud server and its disk add to your bill. [AWS setup and costs](docs/s3.md#aws-setup)

## How your files are protected

- The Windows share uses a dedicated sign-in and an encrypted connection. The firewall limits access to the Mac you choose. Enable disk encryption on the Windows drive to protect the files stored there.
- The S3 bucket blocks public access, encrypts stored files, and requires HTTPS. Each device signs in with temporary AWS credentials that have limited permissions. Connections to the file index from another computer stay on your private Tailscale network.

Keep a separate backup before moving important files. The Windows share was tested on Windows, and the S3 setup was tested with simulated AWS resources and disposable local storage. Try the drive on your own devices with test files first. [Setup checks and recovery guide](docs/operations.md)

Released under the [MIT License](LICENSE).
