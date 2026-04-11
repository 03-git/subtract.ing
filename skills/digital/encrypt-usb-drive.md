---
aliases: encrypt a USB drive, secure USB drive, encrypt flash drive, protect files on USB, encrypted thumb drive
tags: digital-hygiene, encryption, usb, storage, security
verified: true
---

ENCRYPT A USB DRIVE

Steps:
1. IMPORTANT: Encryption erases the drive. Copy any existing files off first.

2. MAC (FileVault/APFS):
   - Insert USB. Open Finder.
   - Right-click the drive in the sidebar > Encrypt.
   - Choose a strong password. Store it in your password manager.
   - Wait for encryption to complete.

3. WINDOWS (BitLocker — Pro/Enterprise only):
   - Insert USB. Open File Explorer.
   - Right-click the drive > Turn on BitLocker.
   - Check "Use a password to unlock the drive." Enter a strong password.
   - Save the recovery key (to a file or print it — NOT on the USB itself).
   - Choose "Encrypt entire drive." Select "Compatible mode" if using with older Windows.
   - Start encrypting.

4. WINDOWS HOME (no BitLocker) or LINUX or CROSS-PLATFORM:
   - Use VeraCrypt (free, open source): veracrypt.com/en/Downloads.html
   - Install VeraCrypt. Select Create Volume > Encrypt a non-system partition/device.
   - Select the USB drive. Choose a strong password. Format and encrypt.
   - To access: always mount through VeraCrypt.

Notes:
- If you forget the password and don't have the recovery key, the data is gone. No backdoor.
- BitLocker-encrypted drives only work on Windows. For cross-platform use, use VeraCrypt.
- LUKS is the standard for Linux-only encryption: `sudo cryptsetup luksFormat /dev/sdX`

