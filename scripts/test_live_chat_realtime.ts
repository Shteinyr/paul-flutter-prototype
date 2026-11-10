// Explicitly assigned disposable Paul identities only. Never print sessions,
// credentials, private channel payloads, or invitation data.
import {
  createClient,
  type SupabaseClient,
} from "npm:@supabase/supabase-js@2.108.2";

const [configPath, fixturePath] = Deno.args;
if (!configPath || !fixturePath) {
  throw new Error("Pass public config and private QA fixture paths");
}
const config = JSON.parse(await Deno.readTextFile(configPath));
const fixture = JSON.parse(await Deno.readTextFile(fixturePath));
if (config.SUPABASE_URL !== "https://ejopxxhgozsxygvkwrfr.supabase.co") {
  throw new Error("Wrong target");
}
const a = fixture.accounts[fixture.review_roles.implementation];
const b = fixture.accounts[fixture.review_roles.coordinator];
const c = fixture.accounts.find((item: { id: string }) =>
  item.id !== a.id && item.id !== b.id
);
const clients: SupabaseClient[] = [];
async function login(account: { email: string; password: string }) {
  const client = createClient(
    config.SUPABASE_URL,
    config.SUPABASE_PUBLISHABLE_KEY,
    {
      auth: { persistSession: false, autoRefreshToken: false },
    },
  );
  clients.push(client);
  const result = await client.auth.signInWithPassword(account);
  if (result.error || !result.data.session) {
    throw new Error("QA sign-in failed");
  }
  await client.realtime.setAuth(result.data.session.access_token);
  return client;
}
async function api(
  client: SupabaseClient,
  action: string,
  fields: Record<string, unknown> = {},
) {
  const result = await client.functions.invoke("chat", {
    body: { action, ...fields },
  });
  if (result.error) throw new Error("Chat API failed during realtime gate");
  return result.data;
}
async function subscribe(
  client: SupabaseClient,
  userId: string,
  signals: Record<string, unknown>[],
  denied = false,
) {
  const channel = client.channel("chat:user:" + userId, {
    config: { private: true },
  });
  channel.on("broadcast", { event: "changed" }, (event) => {
    signals.push(event.payload ?? event);
  });
  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error("Private channel subscription timed out")),
      20000,
    );
    channel.subscribe((status) => {
      if (status === "SUBSCRIBED") {
        clearTimeout(timer);
        denied
          ? reject(new Error("Unauthorized inbox was accepted"))
          : resolve();
      } else if (status === "CHANNEL_ERROR") {
        clearTimeout(timer);
        denied ? resolve() : reject(new Error("Authorized inbox was rejected"));
      } else if (status === "TIMED_OUT") {
        clearTimeout(timer);
        reject(new Error("Channel timed out, authorization not verified"));
      }
    });
  });
  return channel;
}
async function waitForSignal(
  signals: Record<string, unknown>[],
  conversationId: string,
) {
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    if (signals.some((signal) => signal.conversation_id === conversationId)) {
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error("Committed message signal was not delivered");
}
try {
  const ca = await login(a), cb = await login(b), cc = await login(c);
  const signalsA: Record<string, unknown>[] = [],
    signalsB: Record<string, unknown>[] = [],
    signalsC: Record<string, unknown>[] = [];
  await subscribe(ca, a.id, signalsA);
  const channelB = await subscribe(cb, b.id, signalsB);
  await subscribe(cc, c.id, signalsC);
  const forbidden = await subscribe(cc, a.id, [], true);
  await cc.removeChannel(forbidden);
  console.log(
    "PASS private inbox admits its owner and rejects another authenticated identity",
  );
  const conversation = await api(ca, "open", { peer_id: b.id });
  const sent = await api(ca, "send", {
    conversation_id: conversation.id,
    client_message_id: crypto.randomUUID(),
    text: "Disposable realtime QA",
  });
  await waitForSignal(signalsB, conversation.id);
  if (signalsC.length !== 0) {
    throw new Error("Third account received another conversation signal");
  }
  if (
    [...signalsA, ...signalsB].some((signal) =>
      "text" in signal || "name" in signal
    )
  ) throw new Error("Signal included private text");
  const history = await api(cb, "history", {
    conversation_id: conversation.id,
    after_seq: sent.message.seq - 1,
  });
  if (
    !history.messages.some((message: { id: string }) =>
      message.id === sent.message.id
    )
  ) throw new Error("Signal did not correspond to durable history");
  console.log(
    "PASS recipient receives metadata-only signal and loads committed text under participant rights",
  );
  await cb.removeChannel(channelB);
  const missed = await api(ca, "send", {
    conversation_id: conversation.id,
    client_message_id: crypto.randomUUID(),
    text: "Disposable disconnected QA",
  });
  await subscribe(cb, b.id, []);
  const catchup = await api(cb, "history", {
    conversation_id: conversation.id,
    after_seq: sent.message.seq,
  });
  if (
    !catchup.messages.some((message: { id: string }) =>
      message.id === missed.message.id
    )
  ) throw new Error("Reconnect lost durable history");
  console.log(
    "PASS reconnect recovers messages committed while the recipient channel was closed",
  );
} finally {
  for (const client of clients) {
    await client.removeAllChannels();
    client.realtime.disconnect();
    await client.auth.stopAutoRefresh();
  }
}
