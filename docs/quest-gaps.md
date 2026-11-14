# Quest gaps: what AskBot still can't place

Class quests where neither Questie's data nor `KnownLocations.lua` says where to go. Last checked 2026-11-14 against QuestieDB's Forever data.

To fill a gap, add an entry to `KnownLocations.lua` (the format is described at the top of that file), then rerun the check below. For each objective you need the zone and coordinates, or a Questie object/NPC ID to borrow spawns from.

## Still missing

| Class | Quest (ID) | Side | Level | What's missing |
|---|---|---|---|---|
| Paladin | The Reliquary of Tyr (99187) | Horde | 58 | Everything: Questie has no giver, no turn-in, and no location for the Reliquary of Tyr (item 286415). |
| Rogue | Covert Extraction (96782) | Alliance | 36 | Where the Blade of House Perenolde (item 275635, object 656100) and the Royal Aegis of Perenolde (item 275636, object 656101) are in the ruins of Alterac. |
| Rogue | Ain't No Telling (96785) | Both | 36 | Where the Stolen Funds (item 275709, object 656405) are in Stromgarde Keep. |
| Rogue | The Syndicate Sting (96786) | Both | 36 | Where the secret deal happens and the Intercepted Shipment (item 275882, object 656398) is. |

No guide site had coordinates for these yet.

## Unsure whether they're in Forever

Questie flags these, but they may not exist in Forever. Only fill them if someone sees them in-game.

- **Warlock:** later versions of the succubus quests: What Is Love? (65602), The Binding (65597, 65603, 65604). They need items Questie can't place (Burning Torch, Lovers' Hearts, Wooden Figurine, Withered Scarf).
- **Paladin:** the Aeonas chain and other Season of Discovery imports: 79945, 79946, 79963, 79970, 81766, 81790, 81944, 96476, 84318.
- **Rogue:** Season of Discovery imports: The Horn of Xelthos (78307), The Eye of Bhossca (78676, 78699), The Talisman of Kazdor (80411).

## Not location problems (ignored)

- **Crafted or bought materials:** The Quarry's Smith (95217, Copper Bars), Brutal Armor (1838, Iron Bars), Components for the Enchanted Gold Bloodrobe (1796, 4784).
- **Quests the game probably offers automatically** (no giver in Questie, turn-in covered): priest Divine Grace (94778, 94779) and Confounding Flash (94823, 94825, 94826); shaman Call of Fire (98517).
- **Never released:** the `<NYI>` priest quests.
- **Level 60 raid armour quests** (Naxxramas, AQ): they need crafted materials or raid drops, not places.

## Community data to check in-game

These come from guide sites or other game versions, not from Questie's Forever data. Fix them in `KnownLocations.lua` if they turn out wrong.

| Quest (ID) | What | Source |
|---|---|---|
| Body and Heart (6001, 6002) | Moonkin Stones: Darkshore 43.5, 46.0 and Barrens 42.0, 60.9 | Questie's Era data |
| Call of Water, Alliance (94497, 94499, 94500) | Waterskin spots: Wetlands 64.8, 74.8; Redridge 66.3, 62.9; Ashenvale 34.2, 47.8 | bindonforever.com |
| Call of Water, Alliance (94502, 94503) | Corrupt and Minor Manifestation at the Forgotten Shrine, Westfall 45.6, 59.9 | Questie's shrine position plus guide text |
| A Moon-Kissed Blade (95036) | Enchanted Silver Ingot in Shadowfang Keep (by Arugal) | Guide text |
| Investigate the Blue Recluse / Alchemist Shop (1920, 1960) | Rift Spawn positions | Questie's Forever NPC data, pinned per faction |

**Already confirmed in-game:** Trial of the Sea Lion lockboxes (15882, 15883). Questie links each pendant half to the other half's lockboxes, which is why our entries take priority over Questie's.

## Rerunning the check

From the repo folder (LuaJIT is at `C:\Users\panne\AppData\Local\Programs\LuaJIT\bin\luajit.exe`):

```
luajit tools/classgaps.lua "<WoW>/_forever_/Interface/AddOns/QuestieDB/QuestieDB_Forever.toc" [Class ...]
luajit tools/questinfo.lua "<same toc>" <questId> [questId ...]
```

`classgaps.lua` lists every class quest with a gap, counting `KnownLocations.lua` entries as filled. `questinfo.lua` dumps everything Questie has for a quest. Rerun them after Questie updates: it adds data over time, and sometimes gets things wrong.
