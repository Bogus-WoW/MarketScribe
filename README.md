# MarketScribe

A small WoW: Forever addon that:

1. Shows the last-seen lowest Auction House price for an item in its tooltip.
2. Shows expected crafting profit next to each recipe in the profession window.

Prices are shown in a compact decimal form rather than WoW's usual
"1g 65s 23c": anything under 100 copper shows as e.g. `45c`, 100 copper and
above shows in silver (`165c` -> `1.65s`), and 100 silver and above shows in
gold (`165s` -> `1.65g`). Displaying in gold rounds off any leftover copper
below the nearest silver.

## Install

Copy the whole `MarketScribe` folder into your WoW: Forever `Interface/AddOns/`
folder, so you end up with `Interface/AddOns/MarketScribe/MarketScribe.toc`.
Then enable it on the character-select AddOns list.

The `.toc` targets interface version `120105` (Forever's 12.1.5 API). If it
shows as "out of date" in the AddOns list, just tick "Load out of date
AddOns" -- the code doesn't depend on the exact patch number, only on the
modern `C_AuctionHouse` / `C_TradeSkillUI` APIs being present, which they are.

## How pricing works (and its real limits)

Forever runs the modern retail-style Auction House API, and Blizzard removed
the old "dump every auction" scan years ago. The only thing that still
supports a full, cheap price scan is **commodities** -- stackable reagents
like ore, herbs, cloth, motes, etc. Individual/equippable items (most
crafted gear) can only be priced once *something* has searched for them.

So MarketScribe does three things:

- **On-demand scanning**: click the **Scan Prices** button (or `/ms scan`)
  while the Auction House is open and it walks through every reagent and
  crafted item tied to a recipe you know (built from your professions
  automatically), querying each one, throttled to stay well under
  Blizzard's query limit. See "Scanning on demand" below for exactly what
  it does and doesn't bother re-querying. Nothing scans automatically just
  from opening the Auction House -- you're always the one who starts it.
- **Passive AH capture**: it also listens for the results of *any* AH
  search, including ones you type in yourself, plus a light opportunistic
  queue of whatever single item you're actually hovering (its tooltip) or
  looking at (a recipe in the profession window) if it has no price yet --
  that's just the one item, not a scan of everything. So the first time you
  manually look up a crafted sword's price, or hover a reagent that hasn't
  been priced, MarketScribe remembers it from then on.
- **Vendor capture**: every time you open a merchant window, it records the
  plain-copper price of everything they sell (skipping reputation/token
  purchases, which don't have a comparable copper cost). Vendor-only
  reagents like Coarse Thread or an Empty Vial never show up on the AH, so
  without this they'd always show as unknown cost. A vendor price is used
  automatically whenever it's cheaper than (or the only) price on file, no
  setup needed -- just visit the vendor once. **Limited-stock vendor items
  are skipped entirely** -- if a merchant sells something in restocking,
  finite quantity (the API's `numAvailable` is a real count rather than
  unlimited), that price is never recorded, since a slow-restock vendor
  isn't a reliable, repeatable floor price the way an infinite-stock
  reagent vendor is. This came up specifically for fish sold in limited
  quantity by a vendor -- recording that price would have corrupted the
  raw-vs-cooked comparison you'd actually want. There's no dedicated "Fish"
  category exposed by the item API to key off of instead (fish share a
  single lumped "Cooking" trade-goods category with meat, eggs, and
  spices), but limited stock is the actual underlying problem either way,
  and this correctly excludes any other limited-stock vendor item too, not
  just fish.

Net effect: reagent prices (commodities from the AH, plus anything sold by a
vendor) stay accurate with a Scan Prices click now and then, plus whatever
you naturally hover along the way. Non-commodity item prices from the AH
(mostly crafted gear) show up once you've searched for or scanned them at
least once -- exactly the tradeoff you asked to accept.

Tooltip and profession-window numbers both show a small grey `~` when part
of the calculation is based on missing data, and prices carry an age (e.g.
"3h ago") so you can tell how stale a number might be.

## Scanning on demand

While the Auction House is open, a small **Scan Prices** button appears
(drag it wherever you like the first time -- it remembers where you put
it). Clicking it (re-)queries every reagent/crafted item tied to your known
recipes *except* the ones that don't need it -- vendor prices (never change)
and commodities that already have a price on file (a plain commodity price
barely goes stale enough to matter between scans; if one has no price yet
it's still included). Everything else -- items with no price yet, and items
whose only price came from a past individual search -- gets queried, so
those stay current instead of only ever being priced once. Its label counts
down while it works ("Scanning (12 left)"). This is the only thing that
queries your whole watch list -- there's no automatic background version of
it anymore, so it only ever runs when you click the button or type
`/ms scan`. A 30-minute per-item cooldown still applies to the light
opportunistic hover-queueing described above, just to stop that from
hammering the same item repeatedly; the Scan Prices button always bypasses
it and queries everything eligible right away.

## Slash commands

- `/ms scan stop` -- stops a running scan (clicking the button while it says "Stop scan" does the same); searches already sent still finish.
- `/ms scan` -- same as clicking Scan Prices: (re-)queue everything except
  vendor and commodity prices, which don't need it (only useful while the
  Auction House is open).
- `/ms status` -- print how many AH and vendor prices are currently cached.
- `/ms export` -- opens a window with every cached price as a JSON blob you
  can copy out of the game (see "Exporting your data" below).
- `/ms debug <recipe name or part of it>` -- prints the raw reagent-slot
  data (`reagentType`, `required`, item IDs, quantities) for every known
  recipe matching that text, straight from the game's own API. Useful for
  reporting exactly why a specific reagent isn't being priced.
- `/ms debug vendor` -- with a merchant window open, prints every item it
  sells with its raw `price`, `stackCount`, `numAvailable`, and whether it's
  a reputation/token cost, straight from the game's own API. Useful for
  confirming exactly why a given vendor item was or wasn't recorded (e.g.
  if a vendor's stock behaves differently than expected).

## Exporting your data

`/ms export` pops up a window with a text box already selected -- Ctrl+A,
Ctrl+C copies the whole thing. It's a JSON array of every item MarketScribe
currently has a price for (vendor and AH alike), sorted most-expensive-first,
with each entry's item ID, name (when known -- see below), price in copper,
source (`vendor`, `commodity`, or `auction`), and age in seconds for AH
prices. For example:

```json
{"realm":"Realm-Alliance","exportedAt":1732200000,"itemCount":2,"items":[
  {"id":12811,"name":"Jadefire Silk","price":8500,"source":"commodity","ageSeconds":120},
  {"id":2320,"name":"Coarse Thread","price":10,"source":"vendor"}
]}
```

Item names come from the client's own item cache; an item you haven't
actually seen in a tooltip or search yet may still show up as `"Item #12345"`
instead of its real name -- the ID is always correct either way, it's just a
display nicety.

This is meant to be pasted straight into a chat with Claude (or whatever
you're using) to go do something with the numbers -- e.g. figuring out which
of your farmable materials are actually worth the trip. MarketScribe only
ever knows prices, never drop sources or zones, so that reasoning always
happens outside the addon.

## Disenchant estimates

Hovering a weapon or armor piece that's Uncommon (green) or Rare (blue)
quality adds a line estimating its average disenchant value, using your own
price cache for the dust/essence/shard it could turn into, e.g.
"Disenchant (avg): 1.22g". Underneath that, it shows how that value compares
to each way you could have gotten the item in the first place:

- "+40s vs buying" -- shown whenever MarketScribe has a price for the item
  itself (AH or vendor): disenchanting is worth 40s more than what it'd cost
  to just buy the item and disenchant that.
- "-12s vs crafting" -- shown whenever the item is the output of a recipe
  you know: disenchanting is worth 12s less than what the reagents to craft
  one yourself would cost. This uses the same per-item reagent-cost math as
  the profession window's profit column (cheapest known option per slot,
  divided down for recipes that yield more than one item per craft), so
  it's the honest cost of making one, not the recipe's total batch cost.

Either, both, or neither line can show up depending on what MarketScribe
actually knows: a looted/found item that's not craftable only ever gets the
"vs buying" line (there's no recipe to compare against), and an item you've
never seen priced anywhere yet won't get "vs buying" until it has been. Both
comparisons can carry their own `~` if the underlying price/cost is
incomplete, same meaning as elsewhere.

**This is an estimate, not a guarantee, and it comes with real caveats:**

- Blizzard has never published the actual disenchant odds, even for
  original vanilla content -- the percentages and material tiers used here
  are reconstructed from community testing (Wowpedia's disenchanting
  tables, wow-professions.com, and cross-referenced farming guides), not
  confirmed against Forever specifically. Treat it as a reasonable
  ballpark, not gospel, and expect real results to vary run to run --
  disenchanting is a dice roll every time, this is just the average.
- It only covers Uncommon and Rare weapons/armor. Common (white),
  Epic (purple), and non-equipment items aren't estimated at all, since
  the odds for those are even less well-established.
- A `~` marker means one or more of the possible outcome materials
  (usually the rarer essence or shard) isn't priced in your data yet, so
  the shown value is a floor, not the true average -- the real expected
  value is at least that much, likely more.
- Each item-level bracket produces exactly one named essence tier (e.g.
  items in the 16-20 range can yield Greater Magic Essence, never Lesser
  Magic Essence) -- there's no Lesser-or-Greater coin flip within a single
  bracket, that's confirmed against the actual community-documented table,
  not a simplification. Multiple-item drops (e.g. "2-3 dust") are folded
  into a single average quantity rather than modeled as their own
  probability, which comes out to the same expected value either way.
- The weapon-vs-armor split (armor rolls dust more; weapons roll essence
  more) is documented, but weapons don't have their own confirmed drop
  quantities anywhere I could find -- they reuse armor's quantities with
  the odds swapped, which is the single least-confident assumption in this
  whole feature.
- Items below character/item level 5 aren't estimated at all -- they don't
  disenchant into anything meaningful.
- The "vs price" comparison only appears when MarketScribe already has a
  price for the item itself; with no price for it yet, you'll just see the
  raw disenchant estimate.
- Material item IDs (Strange Dust, Lesser Magic Essence, and so on) are
  hardcoded from Wowhead's classic item data rather than looked up by name,
  since name lookup silently failed -- permanently -- for any material the
  client hadn't already cached locally, which is why early builds of this
  feature could show a flat 0c for every item regardless of scanning. These
  are standard vanilla-WoW IDs that don't change between WoW versions, but
  they aren't confirmed against Forever's data specifically, same caveat as
  the odds/quantities above.

## Price history (v1.6)
`/ms show` opens a window with the price history of every item MarketScribe has seen, for the last two weeks. Left: a searchable list (name or item ID) and a sort button: **Movers** (biggest price change over the last 3 days), **Cheap now** (lowest against its two-week average), A-Z, Most data, Latest. The **Watched** button shows only the items you have starred; star the selected item with **Watch** at the top right of the graph (watched items get a * in the list, and stay in the Watched list even before they have history). Right: the graph for the selected item with 1D / 3D / 7D / 14D buttons. The gold line is the lowest AH price when it was seen (held flat until the next scan), grey is the average, green the vendor price, and blue bars underneath show how many units were listed. Hover the graph for the exact time, price and count. `/ms show <name, item ID or item link>` opens it straight on an item.

Item tooltips get a line with the 3-day trend: how the lowest AH price has changed over the last three days, and what it was then.

History starts with 1.6.0: before that only the last price per item was kept, so every item begins with the one price it had. Each scan adds a point (a rescan within 10 minutes replaces the last one, an unchanged price is stored again after 6 hours), and prices friends share bring their own scan times, which fills in earlier days. Points older than two weeks are dropped. `/ms purge <hours>` also removes the history points you recorded in that time; `/ms share purge` (without a name) removes friend-sourced points too.

## Files

- `Core.lua` -- SavedVariables storage, price lookup (AH + vendor merged),
  the reagent/output "watch list", slash commands.
- `Scanner.lua` -- Auction House querying and result capture.
- `Vendor.lua` -- records merchant sell prices (excluding limited-stock
  items -- see "How pricing works" above).
- `ScanButton.lua` -- the draggable "Scan Prices" button shown over the AH.
- `Disenchant.lua` -- estimates a green/blue item's average disenchant
  value from your price cache (see "Disenchant estimates" above).
- `Tooltip.lua` -- adds the price and disenchant lines to item tooltips.
- `Professions.lua` -- adds the profit label to each row in the profession
  window's recipe list.
- `Export.lua` -- builds the `/ms export` JSON blob and its copy window.

## Known rough edges

- Reagent slots are only priced/tracked when they're required to craft at
  all: "Basic" reagents, plus any other slot (Finishing/Modifying, e.g. a
  mandatory quality reagent like a pearl clasp) the recipe itself marks as
  required. Slots you can freely leave empty are still skipped, since
  they're not part of the item's real cost. When a slot offers a choice of
  several interchangeable reagents, the cheapest known option is used for
  cost, and every option gets queued for a price.
- Non-commodity items are searched using the item's currently-cached item
  level (needed because the AH keys equipment listings by item level, not
  just item ID), so a crafted item with several possible outcome qualities
  will only track whichever level happens to be cached at scan time -- not
  all quality variants at once. If an item's data isn't cached yet (usually
  only an issue the very first time you ever encounter it), that one scan
  attempt is skipped rather than sent with a guaranteed-wrong key; it should
  pick up normally on the next pass once the client has loaded it.
- Prices are per-faction (all WoW: Forever realms share one auction house) and only saved to disk on logout/reload,
  same as any other addon's SavedVariables.

## Neutral Auction House (1.2.1)

Neutral AHs (Booty Bay, Everlook, Gadgetzan) are a separate market. While one is open MarketScribe reads, searches and saves nothing, the Scan Prices button does nothing, and tooltips keep showing your faction's prices. It prints one line when it detects a Neutral AH.

- `/ms price <item link, itemID or part of a name>` (also `/ms pc` and `/ms pricecheck`) prints the price on file anywhere, without opening the Auction House: AH price with age, listings, who sent it if it came from a friend, and the vendor price. Shift-click an item to insert its link. A name search lists up to 8 matches.
- `/ms realmtype pve|pvp` sets which ruleset you play on (default PvP, same as before). Prices are stored separately per faction and per ruleset (`WoWForever-Horde`, `WoWForever-Horde-PvE`, ...), and price sharing only happens between friends with the same faction and ruleset. Anyone on a PvE realm should run `/ms realmtype pve` once after updating; their old data stays under the PvP key and can be ignored or wiped.
- `/ms neutral` shows the protection mode and what the last check saw.
- `/ms neutral auto|always|off` sets the mode: auto (default) detects by the auctioneer's faction, falling back to the town name; always blocks every AH; off disables the protection.
- `/ms share purge [friend]` deletes the prices received from that friend (or from all friends). If the friend scanned a Neutral AH with an older version, run `/ms share off` first, have them update and run `/ms purge <hours>`, then purge and `/ms share on`.
- `/ms purge <hours>` deletes the prices and listing counts you recorded in the last N hours (prices received from friends are kept). Use it to remove data from a Neutral AH visit made before 1.2.1.


## Disenchant Scan (v1.4)

A **Disenchant Scan** button appears under *Scan Prices* while the Auction House is open (or type `/ms de`). It opens a window beside the Auction House. Press **Scan**: it first refreshes the price of every dust, essence and shard (so the values are current), then browses every green and blue weapon and armour piece on the AH. The window lists the ones that cost less than what they disenchant into, best profit first.

- Profit = disenchant value x 0.95 (the AH cut) minus the lowest buyout. The value uses the dust, essence and shard prices MarketScribe has saved; a `*` means one had no price saved. 
- **Click a row to buy.** It looks up the cheapest buyout, then asks you to confirm the cost and profit. The game only allows an addon to spend gold on a click, so buying takes two clicks.
- It does not check your Enchanting skill.
- `/ms de scan` starts a scan, `/ms de min <silver>` hides anything under that profit (default 1 silver; `/ms de min 0` shows everything profitable).

## Stack price (v1.5)

Hold **Shift** while hovering an item and the tooltip adds the price for the whole stack you're hovering (for example "AH x20: 3.40g"). It reads the stack size from the item slot (bags, bank, vendor, loot and similar). Pressing or releasing Shift redraws the tooltip at once.
