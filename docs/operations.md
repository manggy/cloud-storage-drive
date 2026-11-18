# Acceptance and recovery

Use a disposable project and retain the original data through all checks. Record the date, OS/client versions, route, test result, and measured time. For real data, verify encryption on the two devices and on the independent backup destination.

## Mount and application checks

| Check | What to record |
| --- | --- |
| Local baseline | Run the same app save and disposable build on the Mac's local disk first. |
| SMB from Finder | Mount **Cloud Storage** while the PC is awake. Save a disposable file from the Mac and check that **Cloud Storage** in Windows File Explorer sees it. Save from Windows and check Finder in the other direction. Review `smbutil statshares -a` for the SMB 3 dialect and encryption. Verify a sign-in without the share account is rejected and that another LAN client cannot reach TCP 445. |
| AWS mount and visibility | Open the mount on the Mac with Windows off. Bring Windows online and save different files on the two devices. Compare file hashes on both. Take the Mac off the network and check the Windows failure and reconnect. For Lightsail, repeat the test with each peer off in turn. |
| Timing | Aim to list the initial directory within 5 seconds and reconnect within 30 seconds once sign-in and the network are ready. Measure cold and repeat range reads and save times. Record the route, internet connection, and whether Tailscale is direct or relayed. |
| App compatibility | Run the same disposable game or app build on the local disk, SMB, and JuiceFS. Check file watchers, byte-range locks, two-device visibility, and case-only names. Use one editor per binary asset until that app's simultaneous-save behavior passes. Keep separate Git checkouts for source work unless that tool passes. |
| Failed save | Interrupt the network during a synthetic large save. Check for an intact file or an explicit app error. Compare a small in-place edit with a whole-file save and hash the intended result. |
| Cache and transfer | Record `df -k /Volumes/ProjectDriveCache` and `diskutil apfs list` before and after range reads and the build. Keep the APFS quota at or below 2 GiB. Measure AWS transfer and request usage over the test window and include background traffic in the credit check. |
| Access and revocation | Run the security checks below on disposable files. Complete an independent native restore and an index restore before increasing the quota. |

Create one 20 GB random fixture within the 25 GiB quota. Copy that fixture to the other routes for a comparable read, and place the JSON evidence outside the tested mount. The reads below fetch only the first and last 4 MiB twice. Add `--full` when testing whole-file integrity and account for that download.

```bash
python3 tools/probe.py create /path/to/disposable-project --bytes 20000000000 > fixture.json
python3 tools/probe.py read /path/to/disposable-project --expected fixture.json > result.json
```

Get first-open timing in Finder separately. For cross-device write visibility, create and save a small uniquely named file on one computer and use `Get-FileHash -Algorithm SHA256` on Windows or `shasum -a 256` on Mac to compare. Create a second file in the other direction. Once the app, restore, and measured credit tests pass, run `bash scripts/client-mac.sh grow 100-after-acceptance`. A JuiceFS quota limits logical file capacity. Budget for blocks retained in trash, rewrites, requests, and download usage.

## Security checks and containment

Use the actual bucket and dedicated AWS mount profile for each device. Confirm that unauthenticated HTTPS listing fails and that the scoped authenticated HTTPS listing succeeds. Verify the bucket's `DenyCleartext` policy with the provisioning profile or the Terraform policy test. Test administration denial using a read-only action such as `get-bucket-policy` with the mount role. Verify a known protected external location is denied using a read-only request. Record the denial status and timestamp without storing credential material.

```bash
aws s3api list-objects-v2 --bucket "$BUCKET" --prefix project-drive/ --max-keys 1 --no-sign-request
aws s3api list-objects-v2 --bucket "$BUCKET" --prefix project-drive/ --max-keys 1 --profile "$MOUNT_PROFILE"
aws s3api get-bucket-policy --bucket "$BUCKET" --profile "$MOUNT_PROFILE"
```

- Confirm PostgreSQL listens only on the index host's loopback. An approved Windows peer should pass `Test-NetConnection <index-tailnet-host> -Port 55432`. An unapproved tailnet device, a LAN peer using the LAN IP and an off-network test must fail. Attempt a disposable invalid DB login on the approved path and verify authentication rejects it.
- Verify mount credential refresh on both devices. Keep a mount through one one-hour role session expiry while the source identity can still refresh. Save and read a fresh file after expiry and confirm a fresh request succeeds. Then expire or revoke the source and mount role session for one test device, and verify fresh object access fails independently of Tailscale. A warm cached file can remain readable.
- To contain a lost device, remove it from the tailnet, block its AWS source from minting new sessions and revoke its mount role sessions, then run `index-mac.sh revoke mac` or `index-mac.sh revoke windows` on the index owner session. Use the corresponding hosted index command when hosted. The DB script disables future logins and terminates existing sessions by login name. For SMB, disable the dedicated share account and close its SMB sessions from Windows. Keep working originals and independent recovery material.
- To close the SMB network path, an administrator can disable `ProjectDrive-SMB-LAN` and `ProjectDrive-SMB-Tailnet` firewall rules, then close the share account's sessions. To close the index's Tailscale listener, use `tailscale serve --bg --tcp=55432 off` on the index host. Inspect its Serve status before and after.

## Daily independent checkpoints

Create dated checkpoints on an encrypted independent disk or with a separate backup account beyond the mount users' write access. Disks in the same PC can protect against a single disk failure. Disconnect or isolate the backup to cover compromise or loss of that PC. Keep source code in Git and scope asset snapshots to the folders you need. Close editors on both devices and wait for current saves before capturing both files and index metadata.

On the index owner Mac, place the dumps in a private staging folder on the encrypted backup device. For a hosted index use `hosted-index.sh dump` in place of the PostgreSQL dump below. The Mac's JuiceFS export command also works against the configured hosted index. The JSON exporter checks the settings for credentials before publishing the file. Treat metadata as private because it holds names and paths.

```bash
bash scripts/index-mac.sh dump /path/to/encrypted-staging/projectdrive.dump
bash scripts/client-mac.sh dump /path/to/encrypted-staging/projectdrive.json
python3 tools/checkpoint.py create --source "$HOME/Cloud Storage/ImportantAssets" --root /path/to/backup \
  --index-file /path/to/encrypted-staging/projectdrive.dump \
  --index-file /path/to/encrypted-staging/projectdrive.json
```

On Windows use `python` and set `--source` to the local shared folder or the mounted S3 drive letter. Supply the previous successful snapshot with `--previous` to use verified native copies from the backup disk when source size and modification time match. Omit it periodically and whenever a tool can preserve timestamps during edits. The source must contain ordinary files. Complete checkpoints are published only after checksum verification.

Restore a prior native checkpoint to a new location while the drive is disconnected. The tool verifies hashes before publishing the restored files. Omit `--file` to restore all native files and any index exports. Open the restored asset and compare its hash and expected content against the recorded version. Record elapsed time.

```bash
python3 tools/checkpoint.py verify --checkpoint /path/to/backup/checkpoint-...
python3 tools/checkpoint.py restore --checkpoint /path/to/backup/checkpoint-... \
  --to /path/to/new-restore-folder --file files/Example.asset
bash scripts/index-mac.sh restore-test /path/to/backup/checkpoint-.../index/projectdrive.dump projectdrive_restore_trial
```

The PostgreSQL restore drill uses a new scratch database that the remote device roles cannot connect to. Check that its table and metadata counts match the checkpoint. For a replacement-host drill, stop the original index before restoring to a fresh instance of the same PostgreSQL major version. Restore the archive into the fresh database or load the credential-free JuiceFS JSON with `juicefs load` into an empty database. Set fresh device credentials and use `bash scripts/client-mac.sh mount-readonly` to verify representative files with background jobs and same-bucket backups disabled. The same S3 blocks must still exist. If AWS access is gone or required blocks have aged out, restore the independent native copy. [JuiceFS metadata recovery](https://juicefs.com/docs/community/metadata_dump_load/)

### Optional Lightsail disk snapshot

Confirm the remaining credits, quiesce both clients, and stop `projectdrive-index` on the hosted instance. Use the provisioner profile to snapshot the separate database disk. Wait for the snapshot state to become `completed`, then start PostgreSQL. For a restore drill, attach a disk created from the snapshot to a scratch Ubuntu host with PostgreSQL 16. Use `hosted-index.sh prepare-disk <device>` and `hosted-index.sh init` to mount the restored disk and start the index. Keep the scratch index isolated from the live clients. Track retained snapshots against the modeled storage budget and maintain the independent copies above. [Lightsail disk snapshots](https://docs.aws.amazon.com/cli/latest/reference/lightsail/create-disk-snapshot.html)

```bash
aws lightsail create-disk-snapshot --disk-name project-drive-index-data --disk-snapshot-name "$SNAPSHOT" --region "$REGION" --profile provisioner
aws lightsail get-disk-snapshot --disk-snapshot-name "$SNAPSHOT" --region "$REGION" --profile provisioner --query 'diskSnapshot.state'
```
