# Playerbot Control 0.1.1

> [!WARNING]
> **Early version (0.1.1).** Playerbot Control is in active development. This version has the bar, its
> options and the Movement and Combat buttons. The Group, Upkeep and Party buttons come in the next
> versions (see [Versions](#versions)).

<div align="center">

![Interface Version](https://img.shields.io/badge/Interface-30300-blue)
![WoW Version](https://img.shields.io/badge/WoW-3.3.5a-orange)
[![Version](https://img.shields.io/badge/Version-0.1.1-green)](https://github.com/EvilTactician/PlayerbotControl)
[![License](https://img.shields.io/badge/License-MIT-yellow)](LICENSE)

**A World of Warcraft 3.3.5a addon with a small, clean control bar for your
[playerbots](https://github.com/mod-playerbots/mod-playerbots), for realms running
[mod-multibot-bridge](https://github.com/Wishmaster117/mod-multibot-bridge).**

</div>

It keeps the handful of orders you give every day one click away, and always shows what your bots were
last told. Orders go to the server through mod-multibot-bridge, so nothing is typed into chat and no bot
is whispered.

- **Follow or Stay** and **Passive or Active** are single buttons that show the current mode, with a
  coloured glow so you can tell at a glance.
- **Attack** and **CC** work on whatever you have targeted, in a party or a raid.
- The bar can be moved anywhere, resized, hidden from a minimap button, and every button can be switched
  off.

Open the options with `/pbc`, or right-click the minimap button or the grip on the left of the bar.

## Screenshots

Screenshots are coming soon.

## What's on the bar

The bar has one button per group, and that button is the group's toggle. **Left-click** uses it,
**Shift-click** repeats its current order for bots that just joined, and **right-click** shows or hides
the group's other buttons above it. Groups you leave open stay open.

### Movement

| Button | What it does |
| --- | --- |
| **Follow / Stay** (on the bar) | Tells the bots in your group to follow you or to stay where they are. Green glow: following. Orange: staying. Red: fleeing. |
| **Flee** | Your bots run to you and ignore enemies until you order Follow or Stay. |
| **Summon** | Brings the bots in your group to you. |

### Combat

| Button | What it does |
| --- | --- |
| **Passive / Active** (on the bar) | Passive bots don't fight. Blue glow: passive. Red: active. |
| **Attack my target** | Your bots attack what you have targeted. It also puts the Skull marker on it, which you can switch off in the options. |
| **CC my target** | Puts the Moon marker on your target; bots that can crowd control keep it controlled. Right-click takes the marker off. |

A **?** on Follow / Stay or Passive / Active means no order has been given yet this session, so the addon
doesn't know the mode. Leaving your group clears both.

Playerbots switches passive off whenever bots are told to follow or stay. While the Passive button is on,
the addon puts it straight back, so the button stays right.

## Options

Under **Interface > AddOns > Playerbot Control**, or `/pbc`:

- **Size**: scale the bar from 50% to 200%.
- **Show the bar**: the minimap button and `/pbc toggle` switch this too.
- **Lock the bar in place**: hides the grip on the left of the bar. Unlocked, drag the grip to move it.
- **Open groups downwards**: a group's buttons appear below the bar instead of above it.
- **Show the minimap button**: left-click it to show or hide the bar, right-click it for the options, drag
  it to move it around the minimap.
- **Reset position**: puts the bar back in the middle of the screen.
- **Attack also marks the target with Skull**
- **Confirm orders in chat**: off by default. Failures are always printed, with the reason.
- **Buttons on the bar**: switch each button on or off. A group with no buttons left disappears.

| Command | What it does |
| --- | --- |
| `/pbc` | Opens the options. |
| `/pbc toggle`, `/pbc show`, `/pbc hide` | Shows or hides the bar. |
| `/pbc lock`, `/pbc unlock` | Locks or unlocks the bar. |
| `/pbc reset` | Puts the bar back in the middle of the screen at normal size. |
| `/pbc status` | Says whether mod-multibot-bridge answered. |

## Requirements

On the realm:

- **[mod-playerbots](https://github.com/mod-playerbots/mod-playerbots)**, with the AzerothCore fork it
  needs.
- **[mod-multibot-bridge](https://github.com/Wishmaster117/mod-multibot-bridge)** by Wishmaster117,
  unmodified. Every button except CC needs it. A button the server's version of the bridge doesn't support
  is left off the bar.

On your client:

- Nothing else. [MultiBot-Chatless](https://github.com/Wishmaster117/MultiBot-Chatless) isn't needed, but
  the two can run side by side: they share the bridge and ignore each other's messages.

The buttons planned for later versions will also use these when they're on the realm; without them, their
buttons stay hidden:

- **[mod-levelsync](https://github.com/Lichborne-AC/mod-levelsync)**: Level sync, and resetting raid
  lockouts without game master rights (needs `LevelSync.AllowRaidUnbind = 1`).
- **[mod-token-turnin](https://github.com/Zerathane/mod-token-turnin)**: checking and redeeming raid
  tokens.

## Installation

**[Download the latest version](https://github.com/EvilTactician/PlayerbotControl/archive/refs/heads/main.zip)**

1. Open the downloaded `PlayerbotControl-main.zip`. Inside is a folder called `PlayerbotControl-main`, and
   inside that is the `PlayerbotControl` folder: that's the one you need. The outer folder is just
   GitHub's packaging.
2. Copy that inner `PlayerbotControl` folder into `World of Warcraft\Interface\AddOns`. It must keep that
   exact name, so `Interface\AddOns\PlayerbotControl\PlayerbotControl.toc` is where the files end up, not
   inside a `PlayerbotControl-main` folder.
3. Restart the game. A `/reload` isn't enough the first time, because the game only finds new addons
   when it starts.

## Performance

- The addon sends a message only when you click a button, plus one hello after you log in. It never polls
  the server.
- Nothing runs every frame. A timer runs for a few seconds after a click, to notice an order the server
  didn't answer.
- Orders are addon messages that the bridge takes before anyone could see them. Bots aren't whispered and
  don't answer in chat, so chat modules such as mod-llm-chatter have nothing to react to.
- CC is a raid marker and sends no order at all.

## Versions

| Version | What's in it |
| --- | --- |
| **0.1.x** (now) | The bar, its options, the minimap button, and the Movement and Combat buttons. |
| 0.2.0 | Group (Drink, Release, Revive, Roll, Reset AI) and Upkeep (Maintenance, Autogear, Sell, Level sync, raid token check and redeem). |
| 0.3.0 | Party: your altbot lists, Quick group, Park altbots, Logout altbots, resetting dungeons and raid lockouts. |
| 0.4.0 | Key bindings, unbound by default. |
| **1.0.0** | Everything above, tested. |

## Things to know

- **Whose bots:** the bridge only lets you command bots that are yours, or random bots in your group.
  Orders go to those bots in your party or raid, not to bots outside it.
- **The mode is what you last ordered.** The addon doesn't ask the server what each bot is doing. If
  something else changes a bot's orders (another addon, a chat command), the buttons won't know. Shift-click
  a toggle to repeat its order.
- **Attack mid-fight:** bots already attacking your target don't need the order, so nothing is printed
  when they turn it down.
- **After logging in** the mode isn't known until you give an order. A `/reload` keeps it.
- **CC** relies on Playerbots' default crowd control marker (Moon). If you changed a bot's `rti cc`, mark
  with that one instead.
- **Raid markers** need leader or assistant in a raid; in a party anyone can set them.
- **Bridge updates:** the bridge's messages can change between its versions. The addon checks what the
  server says it supports, but a large bridge update may need a matching update here.

## Credits

- [mod-multibot-bridge](https://github.com/Wishmaster117/mod-multibot-bridge) and
  [MultiBot-Chatless](https://github.com/Wishmaster117/MultiBot-Chatless) by Wishmaster117: the bridge this
  addon talks to, and the addon whose ideas it borrows.
- [mod-playerbots](https://github.com/mod-playerbots/mod-playerbots) for the bots themselves.
