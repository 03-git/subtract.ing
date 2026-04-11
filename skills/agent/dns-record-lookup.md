---
aliases: dns lookup, dig command, resolve dns, query dns records, check dns, nslookup, dns propagation
tags: dns, network, infra, resolution
verified: true
source: RFC 1035, RFC 8484
---

DNS RECORD LOOKUP AND INTERPRETATION

Steps:
1. Query a specific record type:
   - `dig A example.com` -- IPv4 address
   - `dig AAAA example.com` -- IPv6 address
   - `dig MX example.com` -- mail servers (priority + hostname)
   - `dig TXT example.com` -- text records (SPF, DKIM, verification)
   - `dig CNAME example.com` -- canonical name alias
   - `dig NS example.com` -- authoritative nameservers
   - `dig SOA example.com` -- start of authority (serial, refresh, retry, expire)
2. Query a specific nameserver: `dig @8.8.8.8 A example.com` to bypass local resolver/cache.
3. Trace the full resolution path: `dig +trace A example.com` shows root > TLD > authoritative.
4. Check propagation: query multiple public resolvers (8.8.8.8, 1.1.1.1, 9.9.9.9). If results differ, propagation is incomplete.
5. Check TTL: the number in the answer section is seconds until the record expires from cache. Low TTL (300) means frequent re-queries. High TTL (86400) means changes propagate slowly.
6. Reverse lookup: `dig -x IP_ADDRESS` returns the PTR record.

Notes:
- NXDOMAIN means the name does not exist. NOERROR with empty answer means the name exists but has no record of that type.
- After changing DNS records, propagation depends on the old TTL. If old TTL was 86400 (24 hours), some resolvers will serve stale data for up to 24 hours.
- MX records point to hostnames, never IP addresses. The hostname must have its own A/AAAA record.
- DNSSEC adds signatures. `dig +dnssec` shows RRSIG records. `dig +cd` disables DNSSEC validation for debugging.
