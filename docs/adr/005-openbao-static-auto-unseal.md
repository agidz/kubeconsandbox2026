# ADR-005 — Static auto-unseal for the single-host sandbox

**Status** Accepted on 2026-11-15, implemented on 2026-11-14

The platform uses OpenBao for generated credentials, so an unattended restart must return it to service. Use a static seal in the sandbox. Step `30-openbao` writes a 32-byte key to `.state/openbao/unseal.key` with mode 600 and mounts it in OpenBao from the `openbao/openbao-unseal` Secret. Keep the init output and the single recovery key in ignored local state. OpenBao runs with PebbleDB and TLS issued by the sandbox CA.

This arrangement enables automatic restart but puts the unseal key and the protected storage under the same cluster administration boundary. A cluster administrator can reach both. If local state is lost, its recovery material is lost with it, and a rebuild generates fresh material. Bootstrap revokes the root token after setup and uses 15-minute credentials issued for the `sandbox-operator` role for normal work.

Manual Shamir unseal would require an operator after restart. Transit on a second OpenBao introduces another instance that itself needs unsealing. A cloud KMS or HSM is the production approach.
