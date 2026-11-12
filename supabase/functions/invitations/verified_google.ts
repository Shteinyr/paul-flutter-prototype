/** Accept only identity data returned by the Auth server's verified getUser. */
export function verifiedGoogleEmail(user: {
  email?: string | null;
  email_confirmed_at?: string | null;
  is_anonymous?: boolean;
  identities?: {
    provider?: string;
    identity_data?: Record<string, unknown>;
  }[];
}): string | null {
  if (user.is_anonymous || !user.email_confirmed_at || !user.email) return null;
  const email = user.email.trim().toLowerCase();
  return user.identities?.some((identity) =>
      identity.provider === "google" &&
      identity.identity_data?.email_verified === true &&
      typeof identity.identity_data?.email === "string" &&
      identity.identity_data.email.trim().toLowerCase() === email
    )
    ? email
    : null;
}
