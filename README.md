# discord-role-tools

Scripts for managing Discord server roles via the Discord API.

## Scripts

### `duplicate-role.sh`

Duplicates a role's permissions to another role by name. If the target role
already exists its permissions are updated in place. If it does not exist a new
role is created.

### `set-event-folder-permissions.sh`

Sets channel permission overwrites for the Organizer, Volunteer, Nonprofit, and
Year Organizer roles on a category (folder) channel and every child channel
inside it.

The category name is automatically set to `<year> Projects`. Role names are
constructed from the year you provide:

| Argument | Category | Role names |
|----------|----------|------------|
| `2026`   | `2026 Projects` | `Event Organizers`, `2026 Organizer`, `2026 Volunteer`, `2026 Nonprofit` |

**Permission sets applied:**

| Role | Permissions allowed |
|------|---------------------|
| Event Organizers | View Channel, Send Messages, Manage Messages, Manage Threads, Embed Links, Attach Files, Read Message History, Add Reactions, Mention Everyone, Create Public Threads, Send Messages in Threads, Send Polls |
| `<year>` Organizer | Same as Volunteer/Nonprofit |
| `<year>` Volunteer | View Channel, Send Messages, Embed Links, Attach Files, Read Message History, Add Reactions, Send Messages in Threads |
| `<year>` Nonprofit | Same as Volunteer |

Dry-run mode is the default — current overwrites are printed without making any
changes. Pass `--run` to actually apply the permission overwrites.

### `find-duplicate-year-roles.sh`

Finds members that hold more than one year-scoped role for a given year (any
combination of `<year> Organizer`, `<year> Nonprofit`, and `<year> Volunteer`)
and removes the lower-priority role(s).

Priority order (highest to lowest):

1. `<year> Organizer`
2. `<year> Nonprofit`
3. `<year> Volunteer`

When a member holds more than one of the three roles the script keeps only the
highest-priority role and removes the rest. A member holding all three would
keep only `<year> Organizer`.

Dry-run mode is the default — affected members are listed without making any
changes. Pass `--run` to actually remove the lower-priority roles.

### `set-organizer-folder-permissions.sh`

Sets channel permission overwrites for the Organizers role on the "Organizers"
category channel and every child channel inside it.

The category targeted is always `Organizers`. The role name is constructed from
the year you provide:

| Argument | Category | Role name |
|----------|----------|-----------|
| `2026`   | `Organizers` | `2026 Organizer` |

**Permission sets applied:**

| Role | Permissions allowed |
|------|---------------------|
| Organizer | View Channel, Send Messages, Manage Messages, Manage Threads, Embed Links, Attach Files, Read Message History, Add Reactions, Mention Everyone, Create Public Threads, Send Messages in Threads, Send Polls |

Dry-run mode is the default — current overwrites are printed without making any
changes. Pass `--run` to actually apply the permission overwrites.

## Setup

### 1. Create a Discord bot

1. Go to [discord.com/developers/applications](https://discord.com/developers/applications)
2. Click **New Application**, give it a name, click **Create**
3. In the left sidebar click **Bot**, then **Reset Token** — save the token
4. Scroll down and disable **Public Bot**
5. Still on the **Bot** page, scroll to **Privileged Gateway Intents** and enable **Server Members Intent** — this is required by `find-duplicate-year-roles` to read guild members
6. In the left sidebar click **OAuth2 → URL Generator**
7. Check the `bot` scope, then check the **Manage Roles** and **Manage Channels** bot permissions
8. Copy the generated URL, open it in your browser, and add the bot to your server

### 2. Get your server ID

1. In Discord open **Settings → Advanced** and enable **Developer Mode**
2. Right-click your server name in the sidebar → **Copy Server ID**

### 3. Configure credentials

```bash
cp .env.example .env
```

Edit `.env` and fill in both values:

```
DISCORD_BOT_TOKEN=your_bot_token_here
DISCORD_SERVER_ID=your_server_id_here
```

> **Note:** `.env` is git-ignored. Never commit your bot token.

### 4. Bot role hierarchy

The bot can only manage roles that sit **below its own role** in the server
hierarchy. In **Server Settings → Roles**, drag the bot's role above any roles
you want the script to create or update.

### 5. Bot channel access

These scripts must be able to see and manage every channel in the target folder.
If the bot's role is denied `View Channel` on a category or any
child channel — including by a pre-existing `@everyone` overwrite — the script
will warn and skip that channel rather than updating it.

To ensure full access before running the script, temporarily grant the bot's
role **View Channel** and **Manage Permissions** overwrites on the category in
**Server Settings → Channels**, or make sure the bot's role has those
permissions at the guild level.

---

## Running with Nix

Requires [Nix](https://nixos.org/download) with flakes enabled. No other
dependencies needed — `curl` and `jq` are provided by the flake.

**Run directly without installing:**

```bash
nix run .#duplicate-role -- "2025 Volunteer" "2026 Volunteer"
nix run .#duplicate-role -- "2025 Nonprofit" "2026 Nonprofit"
nix run .#duplicate-role -- "2025 Organizer" "2026 Organizer"

nix run .#set-event-folder-permissions -- 2026
nix run .#set-event-folder-permissions -- 2026 --run

nix run .#set-organizer-folder-permissions -- 2026
nix run .#set-organizer-folder-permissions -- 2026 --run

nix run .#find-duplicate-year-roles -- 2026
nix run .#find-duplicate-year-roles -- 2026 --run
```

**Install into your profile:**

```bash
nix profile install .#duplicate-role
nix profile install .#set-event-folder-permissions
nix profile install .#set-organizer-folder-permissions
nix profile install .#find-duplicate-year-roles

duplicate-role "2025 Volunteer" "2026 Volunteer"
set-event-folder-permissions 2026
set-organizer-folder-permissions 2026
find-duplicate-year-roles 2026
```

**Drop into a dev shell with `curl` and `jq` on your PATH:**

```bash
nix develop
./duplicate-role.sh "2025 Volunteer" "2026 Volunteer"
./set-event-folder-permissions.sh 2026
./set-event-folder-permissions.sh 2026 --run
./set-organizer-folder-permissions.sh 2026
./set-organizer-folder-permissions.sh 2026 --run
./find-duplicate-year-roles.sh 2026
./find-duplicate-year-roles.sh 2026 --run
```

---

## Running without Nix

**Dependencies:**

| Tool | Install |
|------|---------|
| `bash` | Pre-installed on macOS and Linux |
| `curl` | `brew install curl` / `apt install curl` |
| `jq` | `brew install jq` / `apt install jq` |

**Make the scripts executable (first time only):**

```bash
chmod +x duplicate-role.sh
chmod +x set-event-folder-permissions.sh
chmod +x set-organizer-folder-permissions.sh
chmod +x find-duplicate-year-roles.sh
```

**Run:**

```bash
./duplicate-role.sh "2025 Volunteer" "2026 Volunteer"
./duplicate-role.sh "2025 Nonprofit" "2026 Nonprofit"
./duplicate-role.sh "2025 Organizer" "2026 Organizer"

./set-event-folder-permissions.sh 2026
./set-event-folder-permissions.sh 2026 --run

./set-organizer-folder-permissions.sh 2026
./set-organizer-folder-permissions.sh 2026 --run

./find-duplicate-year-roles.sh 2026
./find-duplicate-year-roles.sh 2026 --run
```

---

## Usage

### `duplicate-role`

```
duplicate-role <source_role_name> <new_role_name>
```

| Argument | Description |
|----------|-------------|
| `source_role_name` | Name of the existing role to copy permissions from |
| `new_role_name` | Name of the role to create or update |

**What is copied from the source role:**

- Permission bitfield
- Color
- Hoist (whether the role is shown separately in the member list)
- Mentionable

**What is not copied:**

- Channel permission overwrites (stored on channels, not roles)
- Role position in the hierarchy (new roles are created at the bottom)

### `set-event-folder-permissions`

```
set-event-folder-permissions <year> [--run]
```

| Argument | Description |
|----------|-------------|
| `--run` | Apply the permission overwrites (default is dry-run) |
| `year` | Year prefix used to build role names and the category name (e.g. `2026`) |

The category targeted is always `<year> Projects` (e.g. `2026 Projects`). The
script targets three roles — `<year> Organizer`, `<year> Volunteer`, and
`<year> Nonprofit` — and sets permission overwrites on the category and every
child channel inside it.

**Bot permissions required:** Manage Roles, Manage Channels

### `set-organizer-folder-permissions`

```
set-organizer-folder-permissions <year> [--run]
```

| Argument | Description |
|----------|-------------|
| `--run` | Apply the permission overwrites (default is dry-run) |
| `year` | Year prefix used to build the role name (e.g. `2026`) |

The category targeted is always `Organizers`. The script targets one role —
`<year> Organizer` — and sets permission overwrites on the category and every
child channel inside it.

**Bot permissions required:** Manage Roles, Manage Channels

### `find-duplicate-year-roles`

```
find-duplicate-year-roles <year> [--run]
```

| Argument | Description |
|----------|-------------|
| `--run` | Remove lower-priority roles (default is dry-run) |
| `year` | Year prefix used to identify the three year-scoped roles (e.g. `2026`) |

Scans all guild members for anyone holding more than one of `<year> Organizer`,
`<year> Nonprofit`, or `<year> Volunteer`. In dry-run mode it prints a table of
affected members, the role that would be kept, and the role(s) that would be
removed. In `--run` mode it removes the lower-priority role(s) via the Discord
API.

**Bot permissions required:** Manage Roles

**Privileged intent required:** Server Members Intent — must be enabled in the
Discord Developer Portal under your bot's **Bot → Privileged Gateway Intents**
settings before this script can read guild members.
