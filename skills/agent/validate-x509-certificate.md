---
aliases: validate ssl cert, check certificate, verify certificate chain, x509 validation, cert expired, tls certificate check
tags: auth, certificate, tls, x509, security
verified: true
source: RFC 5280
---

VALIDATE AN X.509 CERTIFICATE CHAIN

Steps:
1. Extract the certificate: `openssl s_client -connect HOST:443 -showcerts` or read from file with `openssl x509 -in CERT.pem -text -noout`.
2. Check expiry: find `Not Before` and `Not After` fields. If current time is outside this range, the certificate is invalid.
3. Check the subject/SAN: the Common Name (CN) or Subject Alternative Name (SAN) must match the hostname you're connecting to. SAN takes precedence over CN.
4. Verify the chain: each certificate's Issuer must match the next certificate's Subject, up to a trusted root CA.
   - `openssl verify -CAfile ROOT.pem -untrusted INTERMEDIATE.pem LEAF.pem`
5. Check revocation (CRL): find the CRL Distribution Points extension. Download the CRL. Verify the certificate serial number is not listed.
   - `openssl crl -in CRL.pem -text -noout`
6. Check revocation (OCSP): find the Authority Information Access extension. Send an OCSP request.
   - `openssl ocsp -issuer ISSUER.pem -cert LEAF.pem -url OCSP_URL -resp_text`
7. Check key usage: the Key Usage and Extended Key Usage extensions must permit the intended operation (e.g., serverAuth for TLS servers).

Notes:
- Self-signed certificates fail chain validation by design. To trust one, add it explicitly to your CA bundle.
- Certificate Transparency (CT) logs can verify a certificate was publicly logged. Check via crt.sh.
- If OCSP stapling is supported, the server provides the OCSP response -- no separate request needed.
- A valid chain with an expired intermediate is invalid. Check every certificate in the chain, not just the leaf.
