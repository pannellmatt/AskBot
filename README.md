# AskBot

![AskBot: ask where anything is, right from chat](https://raw.githubusercontent.com/pannellmatt/AskBot/main/media/askbot-hero.png)

**Ask where anything is, right from chat.**

AskBot answers the questions you'd normally alt-tab to a database site for, without leaving the game. Type a question, get the nearest answer for *your* character, and click once to put a waypoint on it.

```
/ab where is my nearest skinning trainer
AskBot: Nearest Skinning trainer:
  Helene Peltskinner <Skinning Trainer> - Stormwind City 71.6, 62.8 (~2 min, fly Westfall > Stormwind City) [pin]
```

Built for **World of Warcraft: Forever**.

---

## What you can ask

### Levelling helper
- `/ab what's next`: everything in your quest log that's ready to hand in, then the nearest unfinished objectives across all your quests.
- `/ab quests here`: quests you can pick up, nearest first, grouped by who gives them and coloured by difficulty. AskBot uses Questie's own checks, so completed quests, missing prerequisites, quests for other classes and grey quests are all left out.
- `/ab dungeons` (or `/ab dungeons for level 25`): dungeons that suit your level, with entrance pins and a link to their loot *(with AtlasLoot)*.
- `/ab rares`: the nearest rare and rare-elite mobs, with their levels.

### Where's the nearest...?
Profession and class trainers, weapon masters, pet trainers, flight masters, innkeepers, bankers, auctioneers, stable masters and repair vendors. Only NPCs friendly to your faction are shown.

- `/ab where is my nearest skinning trainer`
- `/ab nearest fp`
- `/ab where's my class trainer`
- `/ab closest inn`

### Quests
Shift-click a quest into the command, or type its name.

- **A quest in your log:** the nearest place for each objective you haven't finished, then where to hand it in.
- **A quest you don't have:** who gives it, with its level.

Examples:
- `/ab [The Defias Brotherhood]`
- `/ab who gives Bounty on Murlocs`
- `/ab turn in [Hilary's Necklace]`

### Items
Vendors that sell it, mobs and objects that drop it, quests that reward it, and items that contain it.

- `/ab where can I buy Coarse Thread`
- `/ab where does Linen Cloth drop`
- `/ab where can I get [shift-clicked item]`

### Dungeon loot and drop rates *(with AtlasLoot)*
What a boss drops, with drop rates, plus a pin on the dungeon entrance.

- `/ab what does VanCleef drop`
- `/ab Deadmines loot`

### Prices *(with Auctionator)*
The auction house price, how old that price is, and what vendors pay.

- `/ab price of Linen Cloth`
- `/ab how much is [item] worth`

Ask at the auction house and AskBot checks the live price for you. Away from it, you get the price from Auctionator's last scan. AskBot also keeps a list of the items you've asked about: `/ab refresh prices` re-checks them all, straight away at the auction house or automatically the next time you open it, and tells you what changed.

### NPCs by name
- `/ab where is Gryan Stoutmantle`

You don't have to type names exactly. Lower case, missing apostrophes and partial names all work. When AskBot isn't sure what you meant, it offers clickable "Did you mean" suggestions.

---

## Nearest means quickest

Answers are ranked by estimated travel time, not straight-line distance. AskBot compares walking (mounted from level 40) with flight paths, boats and zeppelins, and spells out the route when it isn't just a walk:

```
Jannok Breezesong - Teldrassil 56.0, 60.0 (~10 min, fly Westfall > Stormwind City,
  boat Stormwind Harbor > Auberdine, boat Auberdine > Rut'theran Village) [pin]
```

Open any flight master's map once and AskBot learns which flight paths your character knows, so it only plans routes you can actually take.

## Waypoints

Every answer has a **[pin]** link. The best answer is pinned automatically (you can turn that off), and you can click any other one. With **TomTom** installed you get its arrow; without it, AskBot uses the game's own map pin. `/ab clear` removes the pin.

## Let friends ask too

Friends don't need AskBot themselves. Switch sharing on (`/ab share guild on`, or `party` / `whisper`) and anyone can type in guild or party chat:

```
!ask where's the nearest flight master
[AskBot] Nearest Flight master:
Thor <Gryphon Master> - Westfall 56.6, 52.6 (71 yds, <1 min)
```

- **Where they are:** answers are worked out from the asker's position (exact for group members, their zone for guild members) and their class, so "my class trainer" means *their* class.
- **No spam:** it's off by default, answers are at most four lines, and there's a cooldown per person.
- **Several AskBots:** when more than one guild member runs AskBot, only one of them answers.
- **Quest log questions:** "what's next" and "quests here" need the asker's own quest log, so they only work with `/ab`.

## Settings

`/ab options` opens AskBot's page in the game's Settings, under AddOns:
- whether to pin the best answer automatically
- how many results to list (1-5)
- which chats friends can `!ask` in

---

## Requirements

| Addon | Required? | What it adds |
|---|---|---|
| **Questie** (with QuestieDB) | **Required** | All NPC, quest and item locations |
| TomTom | Optional | Waypoint arrow |
| AtlasLoot (Forever) | Optional | Boss loot tables, drop rates, dungeon gear |
| Auctionator | Optional | Auction house prices |

## Commands

| Command | Does |
|---|---|
| `/askbot <question>` (also `/ab`, `/ask`) | Ask a question |
| `/ab help` | Example questions |
| `/ab clear` | Remove the waypoint |
| `/ab status` | What AskBot has loaded |
| `/ab forget flights` | Forget learned flight paths |
| `/ab refresh prices` | Re-check the prices you've asked about (needs Auctionator) |
| `/ab forget prices` | Clear that price list |
| `/ab options` | Settings |
| `/ab share` | Who can ask with `!ask` (`/ab share guild on`, `party`, `whisper`; `on`/`off`) |

AskBot answers in whichever chat tab you type in, so you can give it a tab of its own.

---

## How it works, and its limits

- **No internet, no AI.** WoW addons can't go online, so AskBot reads the data your other addons already have: Questie's database for locations and quests, AtlasLoot for loot, Auctionator for prices. When those addons update, AskBot's answers improve with them.
- **Questions are matched by keywords.** AskBot understands the kinds of questions listed above, not anything you can type.
- **Travel times are estimates.** AskBot doesn't know about mountains or water in the way, and uses average waiting times for boats and zeppelins.
- **Drop rates** come from AtlasLoot and mostly cover dungeon and raid drops. Prices are only as fresh as your last Auctionator scan.

## Credits

AskBot stands on the shoulders of **Questie** and **QuestieDB** (data), **HereBeDragons** (map maths), **TomTom**, **AtlasLoot** and **Auctionator**. Thanks to their authors.

## License

AskBot is free software under the **GNU General Public License v3** (or later); see `LICENSE.md`.

*AskBot is a fan-made addon and is not affiliated with or endorsed by Blizzard Entertainment.*
