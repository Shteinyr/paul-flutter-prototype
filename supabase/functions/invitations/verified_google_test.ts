import { verifiedGoogleEmail } from "./verified_google.ts";

function user() {
  return {
    email: "Owner@EXAMPLE.test",
    email_confirmed_at: "2026-11-12T00:00:00Z",
    identities: [{
      provider: "google",
      identity_data: { email: "owner@example.test", email_verified: true },
    }],
  };
}
function equal(actual: unknown, expected: unknown) {
  if (actual !== expected) {
    throw new Error("Unexpected verified identity result");
  }
}

Deno.test("owner activation uses the canonical confirmed Google email", () => {
  equal(verifiedGoogleEmail(user()), "owner@example.test");
});

Deno.test("editable profile metadata cannot establish Google ownership", () => {
  equal(
    verifiedGoogleEmail({
      ...user(),
      identities: [],
      ...{ user_metadata: { provider: "google", email_verified: true } },
    }),
    null,
  );
  equal(verifiedGoogleEmail({ ...user(), email_confirmed_at: null }), null);
  equal(verifiedGoogleEmail({ ...user(), is_anonymous: true }), null);
});

Deno.test("unverified or unrelated provider identities cannot activate owner", () => {
  for (
    const identity of [
      { provider: "email", identity_data: user().identities[0].identity_data },
      { provider: "google", identity_data: { email: "owner@example.test" } },
      {
        provider: "google",
        identity_data: { email: "owner@example.test", email_verified: "true" },
      },
      {
        provider: "google",
        identity_data: { email: "other@example.test", email_verified: true },
      },
    ]
  ) equal(verifiedGoogleEmail({ ...user(), identities: [identity] }), null);
});
