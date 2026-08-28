/**
 * Version constants.
 *
 * Their own module so that `connection.ts` can send `cv` on the handshake without importing the
 * package barrel, which would be a cycle.
 */

/**
 * The client contract this build implements, from `sdk/endpoint-inventory.json`.
 *
 * Reported separately from the package version because they answer different questions. The
 * package version says which build you have; this says which *behaviour* all five SDKs agreed on,
 * so "we're on contract 1.0" answers "which endpoints do you have" without anyone having to ask
 * which platform (CONTRACT §9.1).
 */
export const CONTRACT_VERSION = '1.0';

/** This package's own version. Keep it equal to `package.json`; it is sent as `cv`. */
export const SDK_VERSION = '0.9.0';

/** What goes on the wire as `cv` when the application does not set `clientVersion` itself. */
export const SDK_CLIENT_VERSION = `im-ts/${SDK_VERSION}`;

/**
 * The pair a support ticket needs, in one place.
 *
 * Both members are spelled the same way in all five SDKs — `contractVersion` and `packageVersion`
 * (Unity: `ContractVersion` / `PackageVersion`). They used to be three different names across the
 * five, which turns "quote your SDK version" into a per-platform lookup at exactly the moment
 * nobody has time for one.
 */
export const ImSdk = {
  contractVersion: CONTRACT_VERSION,
  packageVersion: SDK_VERSION,

  /** @deprecated Use {@link ImSdk.packageVersion}, the name the other four SDKs use. Removed in 2.0. */
  version: SDK_VERSION,
} as const;
