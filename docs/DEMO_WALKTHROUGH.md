# Review the prototype

Use the shared browser preview on a phone or desktop. Hosted access is configured separately; a private preview URL requires an account that has been granted access. The same app can be run locally using the README instructions.

## 1. Original test: Profile → Contacts

1. Open Profile. Change the name, occupation and photo.
2. Switch to Contacts. Your own card appears first with those same values; the five sample connections are separate from your own card.
3. Open your card to see its public profile. The edit icon returns to Profile. There is no self-chat button.
4. Refresh the page. Your edits, actual photo bytes, summary and committed skills remain on this browser/device.

## 2. Profile details

1. In Profile, edit the summary and both skill lists. Add with + or Enter; remove with ×.
2. Open View profile, or open your card in Contacts, to inspect the public view.
3. Open any sample contact. Check the photo, name, occupation, description, Offer Skills and Network Hiring.
4. See More opens a complete skill list; Back returns to the profile.

Names, occupations and descriptions of the sample contacts are fictional demo content.

## 3. Chat and connection

1. Open Chat. On first entry, choose whether to enable the in-app demo notifications.
2. The initial Julia Robinson conversation has one unread welcome. Opening it clears the counter.
3. Reply to the welcome. “You’re connected!” appears; Julia is added to Contacts after the first message from each side.
4. A local sample reply arrives after approximately 1.2 seconds. Messages, drafts and connection state persist after a refresh.
5. Open a conversation from the chat icon in another person's public profile.
6. In Chat, Demo notification simulates a background message. With demo notifications enabled, its toast has an Open action. Unread counts clear when the conversation opens.

No message is sent to another person or device. This is a single-device local conversation simulation.

## 4. QR and Connect

1. In Contacts, use the QR button at the bottom right.
2. The QR screen shows your current profile and demo invite code 84654619.
3. The link icon opens Connect, with five fictional address-book entries.
4. Invite shows a simulated contacts permission prompt. Try both Don’t Allow and Allow.
5. After Allow, preview an invitation and use Prepare invite. Only its local status changes to Prepared.
6. Share opens a preview and can copy clearly labelled demo invitation text.

The bundled QR contains a non-URL demo payload. It does not connect accounts. Device contacts, phone numbers, camera, real messages and system notifications are not accessed by this flow.

## 5. Removal and persistence

- Delete Connection asks for confirmation, removes that person from Contacts and retains the conversation. A fresh exchange is needed to reconnect.
- Delete Account is best tested last: it removes your local profile and resets local chat/demo preferences. An explicitly deleted profile stays empty after refresh. The fictional sample contacts remain available.
- Storage is scoped to one browser/device and origin. It does not sync between a phone and a computer.

When reporting a problem, include the screen, action, expected result, actual result and device/browser. A screenshot or short recording is useful.
