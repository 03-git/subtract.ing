---
aliases: connect wifi, join network, wireless setup, wifi password
tags: network, wireless, internet
---

CONNECTING TO WIFI

Steps:
1. List available networks: nmcli device wifi list
2. Connect: nmcli device wifi connect "NETWORK_NAME" password "PASSWORD"
3. Verify: ping -c1 8.8.8.8

Notes:
- Replace NETWORK_NAME and PASSWORD with your actual values.
- If nmcli is not installed: ip link show to find interface, then wpa_supplicant.
- To see saved connections: nmcli connection show
- To forget a network: nmcli connection delete "NETWORK_NAME"
