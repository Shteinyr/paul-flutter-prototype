import { createClient } from "npm:@supabase/supabase-js@2.108.2";
import { handleChat } from "./handler.ts";

const conversation = "10000000-0000-4000-8000-000000000001";
const message = "20000000-0000-4000-8000-000000000001";
function check(value: boolean, description: string) {
  if (!value) throw new Error(description);
}
function client() {
  const calls: string[] = [];
  const sentTexts: string[] = [];
  const database = createClient("https://chat-test.invalid", "test-key", {
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      fetch: (input, options) => {
        const url = String(input);
        calls.push(url);
        if (url.endsWith("/chat_send")) {
          sentTexts.push(JSON.parse(String(options?.body)).p_text);
        }
        const body = url.endsWith("/auth/v1/user")
          ? { id: conversation, is_anonymous: false }
          : url.endsWith("/invite_request_limit")
          ? true
          : {};
        return Promise.resolve(
          new Response(JSON.stringify(body), {
            status: 200,
            headers: { "Content-Type": "application/json" },
          }),
        );
      },
    },
  });
  return { database, calls, sentTexts };
}
function request(body: BodyInit) {
  return new Request("https://chat-test.invalid", {
    method: "POST",
    headers: { Authorization: "Bearer test-session" },
    body,
  });
}
Deno.test("oversized chunked body without Content-Length is cancelled and rejected before RPC", async () => {
  const { database, calls } = client();
  let cancelled = false;
  const stream = new ReadableStream({
    pull(controller) {
      controller.enqueue(new Uint8Array(20000));
    },
    cancel() {
      cancelled = true;
    },
  });
  const req = request(stream);
  check(!req.headers.has("Content-Length"), "Test must use no Content-Length");
  const response = await handleChat(req, database);
  check(response.status === 413, "Expected HTTP 413");
  check(cancelled, "Oversized input must be cancelled");
  check(
    calls.every((url) => !url.includes("/rpc/")),
    "No RPC allowed for oversized input",
  );
});
Deno.test("live text limit counts graphemes and preserves exact Unicode payload", async () => {
  for (const text of ["👩🏽‍💻".repeat(2000), "e\u0301".repeat(2000)]) {
    const { database, sentTexts } = client();
    const response = await handleChat(
      request(JSON.stringify({
        action: "send",
        conversation_id: conversation,
        client_message_id: message,
        text,
      })),
      database,
    );
    check(response.status === 200, "2000 graphemes must be accepted");
    check(sentTexts[0] === text, "Exact raw text must reach the service RPC");
  }
});
Deno.test("empty, NUL and over-limit texts are rejected", async () => {
  for (const text of [" \n\t", "bad\0text", "e\u0301".repeat(2001)]) {
    const { database } = client();
    const response = await handleChat(
      request(JSON.stringify({
        action: "send",
        conversation_id: conversation,
        client_message_id: message,
        text,
      })),
      database,
    );
    check(response.status === 400, "Invalid text must be rejected");
  }
});
Deno.test("client sender identity and simultaneous cursors are rejected", async () => {
  for (
    const body of [
      {
        action: "send",
        conversation_id: conversation,
        client_message_id: message,
        text: "Test",
        sender_profile_id: conversation,
      },
      {
        action: "history",
        conversation_id: conversation,
        after_seq: 0,
        before_seq: 10,
      },
    ]
  ) {
    const { database } = client();
    const response = await handleChat(request(JSON.stringify(body)), database);
    check(response.status === 400, "Invalid request must be rejected");
  }
});
