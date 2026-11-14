# Ergo Privacy Policy

Last updated 11 Nov 2026

Ergo is an app for laying out arguments, checking logic and asking an AI model about reasoning. It is made by JDQC ("we"). This policy says what the app and its server hold about you, who else receives it, and what you can do about it.

Questions go to meriadon@outlook.com.

## The short version

- You can use most of Ergo without an account. Then your boards, scratchpads and chats stay on your device.
- If you sign in, your boards, scratchpads, bookmarks and some settings are kept on our server so they sync between your devices.
- When you use an AI feature, what you send goes to the company that runs the model. Which company depends on what you chose in Settings.
- We don't sell your data, show ads, or track you across other apps and websites.
- You can delete your account, and everything kept under it, from inside the app.

## What we hold

### Without an account

Nothing you write leaves your device, except what you send to an AI feature (see below). The server gives each device an anonymous account so AI features can work, which is a random id with nothing else attached.

### Your account

If you sign in, we keep:

- **With Sign in with Apple:** the identifier Apple gives us for you, and the email address Apple passes on, which may be a private relay address. We also keep a token from Apple, encrypted, so that deleting your account can end the link with your Apple ID.
- **With email and password:** your email address and a hash of your password. We can't read the password back.
- **A token for each signed-in device**, which is how the app proves who it is.

### What you make

When you're signed in, the server keeps your boards (their cards, arrows and sources), scratchpads, library bookmarks and synced settings, including any instructions you wrote for the AI. They are encrypted when stored. Deleted items leave a marker so your other devices learn of the deletion, and markers are removed after 90 days.

Your chats in the Ask tab are kept on your device. The server does not store them. Each question is sent with its conversation so the model can answer, and the answer is held in the server's memory for up to an hour so the app can pick it up if it was closed. Break Down and Deep Research work the same way, except that Deep Research's findings are saved with the board.

### Shared boards

If you share a board, or join one, the other people on it can see the board, the name you typed for sharing, and your role. They never see your email address. A copy of the board is kept for each person on it. If someone reports a board, we keep the report and the reason they gave, and we may keep it after an account is deleted so we can act on abuse.

### AI logins and keys

If you connect your own Claude or ChatGPT login, or an API key, the server keeps that credential encrypted and uses it only to run your own requests. Disconnecting it, or deleting your account, removes it.

### Purchases and allowances

If you buy the paid plan, Apple handles the payment. We receive the signed record of the purchase from Apple, never your card details, and keep which plan your account has. We count how much of the included AI allowance each account has used. To give each device one free allowance, we use Apple's DeviceCheck, which lets us mark a device without learning anything that identifies it.

### Notifications

If you're signed in, we keep a push token for your device so shared boards and finished research can reach you. It is removed when you sign out on that device.

### Logs

The server logs problems, such as a failed request. These entries carry a pseudonym in place of your account id, and never your email address, tokens, or anything you wrote. We keep logs for 30 days.

## Who else receives your data

### AI providers

AI features send what you ask, and what the question is about (the conversation, the board, text you attached, the text of a web page you shared), to a model. Which provider receives it depends on Settings → AI:

- **Ergo's model:** requests go through **OpenRouter** (OpenRouter, Inc.), which passes them to the company hosting the model. See [openrouter.ai/privacy](https://openrouter.ai/privacy).
- **Your Claude login or key:** requests go to **Anthropic** under your own account with them. See [anthropic.com/legal/privacy](https://www.anthropic.com/legal/privacy).
- **Your ChatGPT login or key:** requests go to **OpenAI** under your own account with them. See [openai.com/policies/privacy-policy](https://openai.com/policies/privacy-policy).

These companies handle what they receive under their own terms. We send them no account details of ours: not your email address, your name, or your Ergo account id. Don't put anything in a question that you wouldn't want a model provider to receive.

### Others

- **Apple**, for Sign in with Apple, purchases, push notifications and DeviceCheck.
- **OVHCloud**, which runs the server in Sydney.
- **Websites you link to.** When you share or add a web link, your device fetches that page itself, as a browser would.

We give your data to nobody else, unless the law requires it.

## Tracking and analytics

Ergo has no advertising, no analytics SDKs and no third-party trackers. We don't track you across apps or websites.

## Keeping and deleting

We keep your account and what's synced under it until you delete it. Settings → Account → Delete Account removes the account, its synced data, its connected AI logins, its device and push tokens, and ends its Sign in with Apple link. Boards you own stop being shared. This can't be undone.

Data on your device is removed when you delete the app.

## Your rights

Depending on where you live, you may have the right to see, correct, export or delete the data we hold about you, and to complain to your local data protection authority. Most of this you can do in the app. For anything else, write to omeriadon@outlook.com and we will answer within 30 days.

## Security

Data travels over HTTPS. Synced data and stored credentials are encrypted on the server, and passwords are hashed. No system is perfectly secure, and we will tell you if a breach affects your data.

## Changes

If this policy changes in a way that matters, the app will say so before the change takes effect. The date at the top shows the latest version.
