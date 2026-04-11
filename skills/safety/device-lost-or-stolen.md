---
aliases: lost device, stolen device, lost laptop, stolen tablet, device stolen
tags: safety, security, lost
---

DEVICE LOST OR STOLEN

Immediate steps:
1. Change passwords for any accounts used on the device.
2. If the device had an API key stored (~/.subtract/api_key), revoke it at the provider's site.
3. If the device had SSH keys, remove the public key from any server's authorized_keys.

If you prepared in advance:
- Full disk encryption (LUKS) means data is unreadable without your passphrase.
- No stored browser passwords means no account exposure.
- subtract stores no credentials by default except the optional API key.

Notes:
- subtract has no telemetry or tracking. There is no "find my device" built in.
- If the device had clinical data, notify your supervisor per your organization's breach protocol.
