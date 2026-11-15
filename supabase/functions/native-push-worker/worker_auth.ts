export async function authorized(
  value: string | null,
  secret: string,
): Promise<boolean> {
  if (!value || secret.length < 32 || value.length > 512) return false;
  const hash = async (text: string) =>
    new Uint8Array(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)),
    );
  const [actual, expected] = await Promise.all([
    hash(value),
    hash("Bearer " + secret),
  ]);
  let different = 0;
  for (let i = 0; i < actual.length; i++) different |= actual[i] ^ expected[i];
  return different === 0;
}
