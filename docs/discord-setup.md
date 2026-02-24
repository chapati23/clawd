# Discord Integration Setup

This guide documents how to connect an OpenClaw agent to Discord so you can chat with it across dedicated channels, use threads for subagent sessions, and get streaming responses in real-time.

---

## 1. Discord Developer Portal

### Create the Application & Bot

1. Go to [discord.com/developers/applications](https://discord.com/developers/applications)
2. Click **New Application** → give it a name (match your agent name, e.g. `Giskard`)
3. In the left sidebar, go to **Bot**
4. Under **Privileged Gateway Intents**, enable:
   - **Server Members Intent**
   - **Message Content Intent**
5. Click **Reset Token** → copy the bot token (you only see it once)

### OAuth2 Invite URL

1. Go to **OAuth2 → URL Generator**
2. Select scopes: `bot` + `applications.commands`
3. Select bot permissions:
   - View Channels
   - Send Messages
   - Read Message History
   - Embed Links
   - Attach Files
   - Add Reactions
   - **Manage Channels** ← not in the default set, needed for auto-channel creation
   - **Manage Threads** ← not in the default set, needed for auto-thread creation
4. Copy the generated URL and open it in your browser to invite the bot to your server

---

## 2. Server Setup

### Create a Private Server

1. In Discord, click **+** → **Create My Own** → **For me and my friends**
2. Name it whatever you like (e.g. `Giskard HQ`)

### Enable Developer Mode

1. **Settings → Advanced → Developer Mode** → toggle on
2. This lets you right-click to copy IDs

### Collect Your IDs

- **Server ID:** Right-click the server icon in the left sidebar → **Copy Server ID**
- **Your User ID:** Right-click your avatar in the member list → **Copy User ID**

### Enable DMs from Server Members (Required for Pairing)

1. In the server, click the server name → **Privacy Settings**
2. Enable **Allow direct messages from server members**

> ⚠️ Without this, the bot cannot DM you the pairing code. Pairing will fail silently.

---

## 3. OpenClaw Configuration

### Set the Bot Token Securely

```bash
# Don't paste your token in chat — set it via CLI
openclaw config set channels.discord.token '"YOUR_BOT_TOKEN"' --json
```

### Config Block

Add the following to your OpenClaw config (`~/.openclaw/openclaw.json`):

```json5
{
  channels: {
    discord: {
      enabled: true,
      dmPolicy: "allowlist",
      allowFrom: ["YOUR_DISCORD_USER_ID"],
      groupPolicy: "allowlist",
      guilds: {
        YOUR_SERVER_ID: {
          requireMention: false,
          users: ["YOUR_DISCORD_USER_ID"],
        },
      },
      streaming: "partial",
      replyToMode: "first",
    },
  },
  session: {
    threadBindings: {
      enabled: true,
      ttlHours: 48,
    },
  },
}
```

**Key settings:**

- `dmPolicy: "allowlist"` — only your user ID can DM the bot
- `groupPolicy: "allowlist"` — only allowlisted users in listed guilds can use it
- `requireMention: false` — bot responds to all messages in guild channels (no `@mention` needed)
- `streaming: "partial"` — responses stream in real-time as the model generates
- `replyToMode: "first"` — reply threading targets the original message
- `threadBindings.ttlHours: 48` — thread→subagent bindings expire after 48h

---

## 4. Pairing

1. **DM the bot** in Discord — it will reply with a pairing code
2. **Approve via an existing channel** (e.g. Telegram) or via CLI:

```bash
openclaw pairing approve discord <CODE>
```

Once approved, the bot is live in your server.

---

## 5. Recommended Channel Structure

Channels can't be auto-created via CLI yet — create them manually in Discord or use the API (see below).

### Suggested Channels

| Channel     | Type  | Purpose                                                      |
| ----------- | ----- | ------------------------------------------------------------ |
| `#general`  | Text  | Catch-all, main session                                      |
| `#coding`   | Text  | Software projects, PRs, debugging                            |
| `#research` | Text  | Deep dives, analysis                                         |
| `#projects` | Forum | Project tracking — each post = a thread with its own session |

Each text channel gets its own isolated session. Forum channel posts also bind to separate sessions.

### Creating Channels via Discord API

Until there's a CLI command, use the API directly:

```bash
TOKEN=$(jq -r '.channels.discord.token' ~/.openclaw/openclaw.json)
GUILD=YOUR_SERVER_ID
CATEGORY=YOUR_TEXT_CHANNELS_CATEGORY_ID

# Create a text channel inside a category
curl -s -X POST "https://discord.com/api/v10/guilds/$GUILD/channels" \
  -H "Authorization: Bot $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"coding","topic":"Software projects","type":0,"parent_id":"'"$CATEGORY"'"}'
```

> **Get the category ID:** Enable Developer Mode → right-click the category → **Copy Category ID**

Channel types: `0` = text, `15` = forum

---

## 6. Key Features vs Telegram

| Feature        | Discord                                | Telegram            |
| -------------- | -------------------------------------- | ------------------- |
| Sessions       | Per-channel isolation                  | Single DM session   |
| Threads        | Bind to subagent sessions via `/focus` | Not available       |
| Streaming      | Partial (real-time)                    | Partial (real-time) |
| Interactive UI | Buttons, selects, modals               | Inline buttons only |
| Slash commands | ✅ with autocomplete                   | ✅                  |
| Forum channels | ✅ per-post sessions                   | ❌                  |
| Voice channels | ✅ real-time                           | ❌                  |

### Thread Commands

In any channel, you can bind a thread to a running subagent session:

- `/focus` — bind this thread to the current subagent
- `/unfocus` — unbind
- `/agents` — list active subagent sessions

---

## 7. Gotchas & Troubleshooting

### Pairing fails / bot doesn't DM you

→ Enable **Allow direct messages from server members** in the server's Privacy Settings

### Bot can't create channels

→ Ensure the bot has **Manage Channels** permission (set during OAuth2 invite, or grant in Server Settings → Roles)

### Bot can't create or manage threads

→ Ensure the bot has **Manage Threads** permission

### No CLI command for channel creation

→ Use the Discord API directly (see Section 5)

### Discord DMs vs guild channels

→ Discord DMs share the **main session** (same as Telegram DM). Guild channels each get their own **isolated session**. Don't expect context to carry over between DMs and channels.

### Thread bindings expire

→ Default TTL is 48h (`session.threadBindings.ttlHours`). Adjust in config if needed.
