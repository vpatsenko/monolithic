# GenerousAuction

`src/GenerousAuction.sol` — the distribution rule of [`generous-auction.md`](../human-docs/generous-auction.md)
as a **single continuous sale**: one token, one currency, one persistent book, emitting
`emissionPerRound` every `roundBlocks` blocks with no operator in the loop.

It is also **the harvest channel** of HANDBOOK §3.5: `token` is [`Mono`](Mono.md), `currency` is the
INDEX that backs it, and the auction is `Mono`'s owner. See [The mint path](#the-mint-path).

Spec is the paper; this doc only records what the contract does differently and why.

## Shape

One deployment = one sale, configured by a single `Config` struct (fourteen positional arguments
overflowed the constructor stack, and a deployer transposing two `uint64`s would too). Everything in
it is immutable — `token`, `currency`, `floorPrice`, `tickSpacing`, `decayQ` (`q`, Q96),
`windowTicks`, `minPremiumBips`, `admin`, `startBlock`, `endBlock` — except
`roundBlocks` / `emissionPerRound`, which `admin` may re-schedule. There is no market id, no market
registry, and no cross-market `reserved` ledger — a second sale is a second deployment.

The book is keyed by price alone, so a round boundary copies nothing — it is a division, not a
transaction, at any depth.

**Bids are owner-only.** `submitBid` requires `owner == msg.sender` before syncing or pulling
currency. This covers first bids, same-price top-ups, exhausted positions and re-entry after a
withdrawal. Third-party funding through this method is rejected with `Unauthorized`: a gift
must not choose or modify a position on someone else's stake. The `owner` argument remains in
the ABI, but may only name the caller. Round 10 extends the round-8 check, which only protected
price changes on an existing position and left first bids and post-withdrawal bids exposed.

Two consequences that shape the whole implementation:

- **The hot path never walks the list to write.** `_initializeTick` takes the exact predecessor
  from the caller and validates it in O(1); a wrong or stale hint is repaired on-chain by a walk
  up `next` from the floor, paid by the bidder who guessed wrong — never a revert, because hints
  are racy by construction (the bid's own implicit sync may unlink the node the UI read).
- **ONE bid per owner, keyed by `owner` alone.** `Position.price` says where it stands; a second
  price with live escrow reverts `BidExists` (move = withdraw + bid). This is also what makes the
  stake → tick attachment unambiguous: the whole of `stakes[owner]` weighs at the one price the
  owner stands at. Seats per tick are UNLIMITED: each live tick keeps a min-heap of its positions
  keyed by exhaustion point (`Position.kappa`), and the pour touches only the ones that die —
  `tickPositions` lists the seated set in heap order. Seating capacity also restores
REACHABILITY: it re-raises a dropped `highestTick` — a revived tick above the high-water would
otherwise be skipped by every sweep (caught by the adversarial review from three lenses at
once; regression-tested). No cursor interplay remains: the SettleFirst guard means no seat ever
happens while a truncated sweep is pending. Un-seating the last stake of a tick zeroes its
capacity, so floor-dust cannot anchor a window.

The contract's own header comment is deliberately short and points here. This doc is the mechanism;
the source carries only the *why* of each local decision.

Lifecycle:

```
stake ⇄ unstake (frozen from endBlock until finalize)
submitBid ⇄ withdrawBid → claim (mints)
                           ↑
                  sync (anyone, any time; also implicit in all five above)
```

## Emission is a schedule, not a transaction

`emittedToDate()` is a closed form of the block number:

```
anchorEmitted + floor((block - anchorBlock) / roundBlocks) * emissionPerRound
```

with at most one queued generation of `(K, R)` folded in at its boundary, and the block clamped to
`[startBlock, endBlock]` (`endBlock == 0` is open-ended). Accrual is BLOCK-LINEAR — `R/K` per
block, no flooring to whole rounds: an atomic round chunk made the first post-boundary sync a
weight SNAPSHOT, and one block of doubled stake before a boundary captured a whole round's
inflated share (round-4 review, PoC'd; regression-tested down to a one-block earning). "Rounds"
pace the schedule; they are not an allocation unit. Nobody has to open or close anything, and a
keeper is optional: `sync(maxTicks)` distributes
`emittedToDate() - tokensSold`, and `submitBid`/`withdrawBid`/`claim`/`stake`/`unstake` all run
it first so the book is never reshaped or reweighed in the middle of a backlog. A life not divisible by `K` emits its exact
pro-rata tail up to `endBlock`.

### Lazy is exact, not approximate

A thousand silent rounds cost **one** sweep, and land exactly where a thousand sweeps would.
`_solveBand` parameterises the whole pour by a single scalar `C`, and relative weights
`w_i/w_j = q^(j-i)` do not depend on the anchor `tau`. So one sweep of `N·R` is the same allocation
as `N` sweeps of `R` over a static book, down to flooring dust — **band membership included**: the
moment the band's top runs dry the walk admits what the lower edge now reaches (see "Bounded
window"), exactly as the next per-block sync would have. This is why the paper's §3 accumulator is
unnecessary here, not merely skipped — there is nothing left for it to amortise.

### Carry

A round the book cannot absorb — every tick capped, or no book at all — is **not** burned.
`tokensSold` is cumulative and `due()` is measured against the schedule, so the shortfall stays
owed and the next sync distributes it. Nothing can reach `due()`, so carry is out of
the seller's hands too.

The known ceiling, marked `ponytail:` in the source: carry is unbounded. A long dry spell hands the
first bidder back a large backlog at their own price. Cap the per-sync draw if that turns out to be
worth gaming.

### Rescheduling

`setRoundParams(K, R)` is admin-only and takes effect at the **next** round boundary — the round in
flight finishes at the rate it started under. Note the admin CAN dump the whole remaining
`saleSupply` into one round (`setRoundParams(1, saleSupply)`) — the admin is trusted with pacing
by construction; anyone for whom that matters should read the pacing from chain. It needs no
sync first: `_emittedAt` is exact for
every past block regardless of what is queued, so rounds that already elapsed keep their old rate
whether or not anyone settled them. A second call before the boundary replaces the first.

## Distribution

Live tick `i` at distance `d = (tau - price) / tickSpacing` below the top of book `tau` carries
weight `w = q^d` and takes `w/W` of the round's supply, paying **its own price** (pay-as-bid).
A tick that exhausts mid-round leaves the live set, `W` shrinks, and the rest of that same round
re-flows by renormalised weights — the paper's waterfall (§1.2), most of it upward.

Solved in one sweep, not iterated (§A.6). With `a_i = w_i · C`, tick `i` dies at
`kappa_i = cap_i / w_i` where `cap_i = demand_i / price_i`. `_pour` sorts by `kappa` and walks it:
each step either reaches the next death (drop it from `W`, continue) or exhausts the supply (fix
`C`, stop). `O(n log n)`. **Death order is not price order** — a rich low tick outlives a poor high
tick — which is why the sort exists and a bitmap would not do.

`q → 0` is strict high → low priority; `q = 1` splits evenly. In a dense book the top tick's share
tends to `(1 - q)`, so `q` **is** the soft anti-whale cap.

**Within a tick the same rule runs again, with stakes for weights** (`_pourTick`, the two-level
waterfall of `docs/staked-generous-auction.md`): each position takes `stake/stakeSum` of the
tick's pour, capped by what its own escrow buys; a position that exhausts leaves the live set and
the rest re-flows to its co-stakers. The exhaustion order is a per-tick MIN-HEAP on `kappa`
(seated by `_reseat` on every bid/stake move, O(log seats)), so the pour walks head pops only:
O(deaths), one death per position per lifetime, however many bidders share the price. A sync owing
more than `MAX_DEATHS_PER_SYNC = 128` deaths — a GLOBAL budget across every tick it pours, so a
window of half-dead ticks cannot multiply it — pauses at a death boundary (the partial advance of
`acc` is exact) and parks the cursor on the WINDOW'S TOP, not the paused tick: ticks above the
pause may have survived their pour with capacity, and "above the cursor is dry" must stay true.
Known pause semantics (ponytail in source, pinned by test): the paused tick's un-poured share
returns to `due()`, and each resumed pour re-splits by q-weight — so across repeated forced
pauses the window's top compounds toward the whole remainder. Forcing a pause costs a sybil per
death, and the leak flows to the highest price payer. Price competition decides between
ticks, skin-in-the-game decides within one.

### Deliberately not implemented: the lazy `G` accumulator

The paper's §3 — global accumulator `G`, mantissa+shift rebase on a change of `tau`, sorted death
queue with hints — exists to smear the sweep across transactions. This contract runs the sweep
inline at settle over a bounded window instead. No accumulator to drift, no queue to keep sorted,
no rebase when `tau` moves. What is kept from §3 is the part that actually buys O(1) claims: the
per-tick multiplicative index.

Cost of that trade: a sync is O(live ticks), not O(1). It is chunked (below) so it never has to fit
in one block. Revisit only if a live book gets deep enough that a chunked sync is uncomfortable.

## Bounded window

Only the top `windowTicks` grid steps participate; past that `q^d` has rounded to nothing. A window
is a **price band** `[tau - windowTicks·tickSpacing, tau]` for the top live tick `tau`, so it holds
at most `windowTicks + 1` distinct tick prices — the gather is bounded by construction, no
caller-supplied cap needed.

**The band moves with its top.** Ratios inside a band are shift-invariant, so a lower tick running
dry changes nothing about who else is served; but the TOP running dry moves the lower edge down
with it, and ticks that were just past the old edge now sit inside the curve with real weight. A
pour that carried on against the old band handed the whole remainder to its survivors and 0 to the
tick just below the edge, while a sync that happened to land right after the top dried gave that
tick its full `q^d` share — the allocation depended on who called `sync` when (round-7: 0 vs 29.67
of 100), and a 2-wei dust bid parked `windowTicks` steps above a whale kept the honest tick out of
every pour (round-6). So the sorted walk (`_solveBand`) ADMITS, at the moment a top dies, every
live tick the new edge reaches — read straight off the list, weighted `q^d` from the new top in the
walk's own scale (weights are rescaled up before they could underflow), joining at the current `C`
and slotted into the sorted order at its own exhaustion point — and carries on. One walk however
many times the band moves, one `_pourTick` per tick at the end; a book of 256 clearing ticks
re-anchors 255 times for ~35k gas per tick, the same as before. Band moves are charged to the
caller's tick budget; when it runs out the walk stops at the next top death, what was poured is
exact, and the cursor parks on the band's original top.

The constructor rejects `q^windowTicks > 1%` (`WindowTooNarrow`), and a band narrower than 1% of
the floor in PRICE terms (`windowTicks * tickSpacing < floorPrice / 100`, same error — on a 2-wei
grid the whole curve spanned 16 wei and an 18-wei overbid took entire rounds, round-7), so a
deployment cannot silently
strand real demand just past the edge. `q == Q96` (flat) is exempt: there the window *is* the
intended participation set.

Calibrate `q` **with** `tickSpacing`: weights decay per grid step, so on this arithmetic grid `q`'s
reach is an absolute price band. Window width and top-cap strength are one knob, not two.

**Cadence exactness depends on `q` being exact.** `_extend` weighs a newcomer against the band's
CURRENT top (`wTop · q^d`), so across a sweep that moves the band many times the weights compose as
a product of rounded powers rather than one exact power. With `q` a power of one half every power
is exact and one lazy sweep matches one sweep per block to integer dust (81 token-wei over a
96-price book, 185 blocks). With an inexact `q` each `rpow` and each `_rescale` carries about
`2^-96` of relative error, and the band's weight range amplifies it: at `q = 0.6` and
`windowTicks = 64` the worst per-bidder difference between the two cadences is 1.12e9 token-wei on
a 185 MONO pour — six parts per trillion (round-11, pinned in `Review11_cadence`). So "`N·R` in one
sweep lands where `N` sweeps of `R` would" is exact for an exact `q` and holds to a relative bound
otherwise. Prefer a `q` of the form `Q96 >> k` when the choice is free.

## Depletion index (why claims are O(1))

Per tick: `acc` (Q128) — **additive** tokens-per-unit-of-stake, monotone, never reset. The old
multiplicative `survival` index assumed every position in a tick drains in the same proportion;
stake weights break exactly that, so the index is now the running integral instead, and the
epoch machinery is gone with it (nothing ever needs resetting — `min` below prices death).

A position stores `amount` and `accAtEntry`. Its consumption is

```
min(cap, stake * (acc - accAtEntry))        cap = tokens `amount` buys at `price`
```

— one closed form, however many rounds, partial fills and other people's exhaustions went by. The
`min` IS the death: an exhausted position reads `cap` forever, no flag needed.

**Allocations are never stored, and the pour writes no position but the dying one's seat.**
`_pourTick` advances `acc` from heap head to heap head and writes back only
`acc`/`capTokens`/`stakeSum`; a position's numbers crystallise on its own next touch, with the
identical formula the seat accounting used, so the two can never drift. `Tick.capTokens` — the
stake-covered capacity, now in sale tokens — is what the inter-tick pour reads as the tick's cap. `Position.tokensOwed` is materialised
lazily on the first claim/bid/withdraw/stake that touches the position — and EVERY harvest
re-anchors `accAtEntry`, including the nothing-live early path: an exhausted position left at a
stale anchor would count the whole index gap since its death as phantom consumption of a later
same-price top-up (round-5 critical, PoC'd theft; regression-tested). Reading the raw
`positions` mapping shows only that crystallised half — **`positionOf` is the number to trust**.

Tokens round DOWN, escrow charges round UP, and **the pot books a lower bound**. Allocations
never exceed supply. But every seat crystallises with its own floor, so what `n` positions can
ever claim — and be charged for — can trail a pour by up to `n - 1` token-wei; booking the whole
pour recorded currency in `currencyRaised` that nobody was debited for, and at a whole-number
price (the 1.00 floor is one) the per-position ceil charge recovers nothing, so the pack pulled
escrow that still belonged to live bidders and, once they withdrew, every claim reverted on the
vault pull (round-7 finding). `_pourTick` therefore books `poured - (seats - 1)` into
`tokensBooked` / `tokensUnclaimed` / `currencyRaised` (while `tokensSold` keeps the full pour, so
the schedule never re-offers the reserve). The pot is only ever ahead by dust: `claim` clamps
against `tokensUnclaimed` (the last claimant may lose the reserve wei), and the matching charge
stays here as surplus. Frequent claiming costs the claimer up to one token-wei of their own
capacity per claim: the re-seat re-derives capacity from an escrow the ceil charge has just
reduced, so a bidder's total is a function of price, stake and escrow to within that dust, not
exactly (round-14). Every harvest re-seats the position at its post-charge escrow — `claim`
included (it used to be the one path that did not, leaving a phantom token-wei of seat capacity
the next pour booked and charged for; at a single-seat tick and a price of a few INDEX that put
the pot short, round-8). `currency.balanceOf(this) >= sum(live escrow)` holds exactly, with no
slack, and the invariant suite asserts it that way.

## Staking (who gets what within a tick)

`stake(amount)` / `unstake(amount)` move the SALE token (MONO) into and out of the contract, one
account per address, tracked apart in `totalStaked` — stake can never pay a claim or a pack, and
`claim`'s balance clamp nets it out.

**The strict rule.** Within a tick, supply splits by stake — and escrow with zero stake buys
nothing under any composition. It follows that such escrow is not capacity either: `Tick.demand`
counts only stake-covered escrow, so the inter-tick pour never allocates supply to a tick that
cannot buy it. `submitBid` refuses stakeless bids (`NoStake`) at the door; un-staking to zero with
a live bid is legal and leaves it **inert** — everything the old stake earned is harvested first,
the escrow leaves `demand`, and re-staking re-anchors (`accAtEntry = acc`) so nothing is ever
earned retroactively. A tick whose whole stake left is a zombie: `demand == 0`, skipped like any
dead tick, revived by the first re-stake.

**Compounding is one call away, never automatic.** `claimAndStake()` books exactly what `claim`
would and credits it to the caller's stake instead of transferring out — caller-only (nobody may
force someone else's winnings into a stake), and inside the lock window it degrades to a plain
claim, because winnings must always flow while only the stake leg is frozen.

**Weight changes demand a settled BOOK — price-independent.** The implicit pre-change sync is
budget-bounded; a truncated sweep leaves accrued backlog un-poured, and any new weight competes
for it: below the cursor by joining the pour (round-2 PoC: 25/25 became 49.7/0.05), above it by
becoming the new top so the next sweep opens on the newcomer and never reaches the standing book
(round-3 critical PoC: a latecomer above a dead-tick wall took a floor bidder's entire 400e18
backlog — which is why the guard's original `price > cursor` exemption was itself the bypass).
So `submitBid`/`withdrawBid` — and `stake`/`unstake` when the caller HAS a standing bid (a
bidless stake moves no weight and passes) — revert `SettleFirst` while
`settleCursor != 0 && due() != 0`, whatever the price; `claimAndStake` degrades to a plain
claim there. The remedy is a real `sync`, and WALL SHAVING makes that a bounded one-time cost:
every truncated skip-walk permanently drops `highestTick` to its resume point, so a spam ridge
is paid for once across all syncs and never re-walked — shaving handles ridges above the
high-water, and walked dead runs are additionally SPLICED out of the tick list (an interior
ridge below a risen top would otherwise be re-walked by every sync forever, round-5 soak
finding). The splice UNLINKS every interior node (`prev = next = 0`), never merely bypasses
it: a bypassed node kept pointers into the run and its run-neighbours kept pointing back, so
`_initializeTick`'s one-sided "still linked" test read it as live — a re-bid there was seated
without ever being re-linked (orphaned from the sweep), and a second splice onto the same
lower endpoint could leave a tick whose only acceptable hint was `.next == price`, which
wrote `ticks[p].prev = p` and looped every `_gather` walk into a Panic (round-7 critical,
reached by honest re-bids alone). With the list free of stale pointers, `_initializeTick`
checks every hint against the LIVE list: the hint must itself be linked, its upper neighbour
must point back at it and sit strictly above the new price. A hint that fails — stale, off by
one, a node the bid's own implicit sync has just unlinked (a dead ex-top with nothing above it is
dropped by the splice in O(1); one with live ticks above it stays as the run's endpoint until a
sweep walks down through it) — is replaced by a walk up `next` from the floor, at the bidder's
expense, never a revert: the round-7 organic sims showed every such case to be an honest bid
racing its own sync. Read hints from the FLOOR, not from `highestTick`.

**What the `next` chain holds.** A sweep unlinks every dead run it walks, and that now includes
each window's own band once the band has run dry (it used to stop at the band's surviving top, so
every swept window left its whole band linked forever — 78 permanent nodes from 160 bids,
round-9). What remains is the live book plus whatever no sweep has reached: `_sync` stops when the
supply runs out, so dead ticks below a top of book that keeps absorbing the emission are never
walked. That tail is the residual cost of a demand-driven sweep — one `submitBid` + `withdrawBid`
per node to create, ~2.3k gas apiece on a later hintless bid, nothing at all to a bidder who sends
the exact predecessor.

Two consequences an
integrator should know: a `ticks(p)` row with `init == true` and `prev == 0` (`p != floorPrice`)
is an unlinked price, re-inserted by the next bid there; and a position
whose owner un-staked to zero is inert (escrow bound, no capacity), so its tick can read dead and
be unlinked while the escrow is still there — when the owner stakes again, `_reseat` re-links the
tick (a walk up `next` from the floor, the one place no hint is available) before seating. The
invariant suite walks the list from `highestTick` after every step (`invariant_tickListSound`).

**Stake moves are forward-only by construction.** Every `stake`/`unstake` syncs the book and
harvests the caller at the OLD stake before the new one applies — a stake weighs exactly the
rounds it stood for. There is no snapshot to game: weight flicker buys precisely the rounds it
covered.

**The lock window.** From `endBlock` until `finalize()`, stakes freeze — and so do escrow
withdrawals while anything is still owed (`withdrawBid` reverts `StakeLocked` when the lock is on
and `due() != 0`): a withdrawal moves weights too, and would reprice the frozen backlog onto the
remaining stakers. Once finalized the sale is OVER for good: `due()` reads 0 forever, so a
post-finalize re-stake revives nothing and cannot vacuum leftover carry. Not ceremony: the lazy
sync may settle pre-`endBlock` rounds after `endBlock`, reading weights from current stakes —
moving stake in that window would reprice rounds that already happened. `finalize(maxTicks)` is
permissionless: it syncs, and flips when `due() == 0` — or when a COMPLETE sweep sold nothing,
because with bids and stakes both frozen a book that cannot absorb the carry now never will, and
holding stakes hostage to it serves nobody. A call that is neither keeps the progress its sync
made and returns false (never reverts on progress — the revert would undo the sync itself). Open-ended sales (`endBlock == 0`) never lock.

## The mint path

**Nothing is pre-funded, and MONO is minted in one pack, not per claim.**

`mintPack()` mints every booked-but-unpacked token at once — `tokensBooked - tokensMinted` shares
against `currencyRaised - currencyMinted` of escrow — and holds the MONO here for claimants. The
escrow goes to the vault in the same call, so supply and backing still arrive together and NAV
cannot fall. `claim` is then a plain `transfer` out of that pack.

It is permissionless and idempotent (it mints a delta, so a second call in the same block is a
no-op), and it runs from two places:

| Trigger | Why |
| --- | --- |
| head of `claim`, after `_sync` | the first claimant packs the sale; everyone after is a transfer |
| the **next sale's constructor** | closes the outgoing sale out before the new one opens |

**Deliberately not in `_sync`.** A pack lifts NAV, and `submitBid` floors bids at `nav()` — so
packing on every sync would ratchet the floor out from under the bottom tick mid-sale, and a bid
at `floorPrice` would revert `BelowNav` the moment anybody synced. Bidding has to be able to
happen against a still price.

### Succession

`Config.previousAuction` is the sale this one replaces (`address(0)` for the first). The
constructor calls `mintPack()` on it, so deploying the successor *is* the settlement of the
predecessor. No registry, no deployer step.

**The ordering that bites:** the outgoing auction must still hold `MINTER_ROLE` when the successor
is deployed. Revoke it first and the constructor reverts `AccessControlUnauthorizedAccount`, which
is the natural instinct and the wrong order. Correct sequence:

1. deploy the successor (its constructor packs the predecessor FIRST, then reads the premium —
   so the new sale is gated and sized against the post-handoff market, not a stale one);
2. `grantRole(MINTER_ROLE, successor)`;
3. `revokeRole(MINTER_ROLE, predecessor)` — **only once the predecessor has nothing left to
   pack**: `currencyRaised() - currencyMinted()` under one NAV-wei (a delta `maxIssuable` floors
   to zero can never pack; it is at most `nav() / 1e18` plus rounding, and a later pour absorbs
   it). "Drained" (`due() == 0`) is NOT that signal: a predecessor that still sells after losing
   the role has claims that need packing and cannot pack, bricking them (round-3 finding), and
   `finalize` itself sells the frozen tail the successor's constructor packed nothing of (round-6
   finding). `finalize` therefore packs on completion and propagates every failure of that pack
   except the revoked-role error (a bare catch used to swallow an out-of-gas inside the self-call
   and report a finalized-but-unpacked sale on a band of gas stipends, round-8), so for a bounded
   sale "finalized" does mean "packed" to within that wei. For an OPEN-ENDED predecessor there is
   no stable checkpoint while its book can still sell — `_claim` packs unconditionally and would
   revert on the revoked role the moment another pour lands — so revoke only once it has sold
   out (`tokensSold == saleSupply`) or its book is provably dead, and pack first.

### The shortfall, and why it is pro-rata

`Mono.mint` refuses anything dilutive, and NAV can rise between a fill and the pack — a donation or
tax sweep is the only thing that does it, since nothing else moves NAV before the first pack. When
it does, the pooled escrow buys less MONO than the book promised, so the pack takes `maxIssuable`
rather than reverting and stranding every claimant. All of the escrow is still paid in; it simply
bought less, and the difference raises NAV for everyone.

`tokensMinted` then sits below `tokensSold`, and every claim takes its share of the REMAINING pot:

```solidity
tokens = owed * held / tokensUnclaimed;   // held = balance - totalStaked
```

The ratio `held/unclaimed` is invariant under claiming, so the haircut is identical whatever the
claim order within one settled state. Across INTERLEAVED packs the pot is pooled between
generations — a claim's haircut reflects every clamp outstanding at claim time, so timing around
new packs shifts who carries how much of a shortfall (round-3 finding, documented as the cost of
one pot; per-generation ledgers are the fix if it ever matters). Order within a state cannot — a cumulative `tokensMinted/tokensSold` ratio looked fair but was not (claims made
before the shortfall took ratio 1 and the deficit fell entirely on whoever claimed last; caught
by the adversarial review, regression-tested). The haircut pools across the whole book — a bidder
who filled at 1.03 shares it with one who filled at 1.00.

The constructor enforces the wiring it needs: `currency == address(Mono.index())`, or `mint` would
pull the wrong token. After construction the deployer must grant this contract `Mono`'s
`MINTER_ROLE` and renounce its own — see [Mono.md](Mono.md#roles). A grant without the renounce
leaves two minters, which the auction cannot detect and does not check.

### The premium gate

A sale only opens into a premium. The constructor reads
[`Mono.premiumBips()`](Mono.md#the-pool-and-the-premium) and reverts `PremiumTooLow` unless it is
at least `Config.minPremiumBips` — 1,500 (15%) is the intended setting.

The reason is the mechanism, not caution. `claim` mints MONO against escrow valued at **NAV**; the
market pays the **pool price**. The spread between them is the entire harvest. With MONO at or
below book there is no spread, and the sale stops being a harvest and becomes plain supply sold at
book into a market that did not ask for it.

The comparison is `<`, so exactly at the bar passes. `minPremiumBips` is a `uint16` and unsigned,
while `premiumBips()` is signed — a discount is a negative number, so it fails the same test
without a special case. Setting the bar to `0` does not disable the gate; it still requires the
market not to be under book.

This moves the deploy order — the pool has to exist and be registered before the auction is
constructed, or the constructor reverts `PoolNotSet`:

1. deploy `Mono`, `mint` once to set the opening NAV;
2. create the MONO/INDEX pool, `mono.setPool(pool)`;
3. deploy `GenerousAuction` (the gate is read here);
4. `mono.grantRole(MINTER_ROLE, auction)`;
5. `mono.renounceRole(MINTER_ROLE, deployer)`.

### The premium sizes the sale

The same read that gates the sale also *sizes* it. The constructor stores

```solidity
saleSupply = IMono(token).premiumCloseAmount();
```

— the MONO that, sold into the pool, would carry its price back down to NAV. That is precisely
what this sale exists to sell, so it is the sale's whole size. `saleSupply == 0` reverts
`NothingToSell`: a premium the pool has no liquidity to absorb is not a sale, and this catches the
zero-gap case that a `minPremiumBips` of 0 would otherwise wave through.

Struck **once** and never recomputed, like `floorPrice` and `targetPerIndex` before it. The sale
sells the gap that stood when it opened, not whatever the gap is today — a sale that re-sized
itself every block would let anyone resize it by pushing the pool.

The sizing math and its accuracy ceiling live in
[Mono.md](Mono.md#sizing-the-premium-as-supply); the short version is that it reads only the
*in-range* liquidity, so it is exact within the current tick and understates once a swap would
cross one.

**Known ceiling.** Checked **once**, at construction, against a spot `slot0` read. It stops a sale
being opened into a flat market; it does not keep one honest afterwards, and a deployer who
controls the pool can push it for a single block. The right home for this is `submitBid`, but
gating every bid on a spot price hands anyone a cheap DoS — so it waits on the v4 TWAP hook
(HANDBOOK §3.6), the same upgrade `Index._poolPrice` waits on.

`due()` is `emittedToDate() - tokensSold`, **capped at `saleSupply`**. Two constraints, and
whichever binds first wins: the schedule paces the sale out over time, the premium sizes it. Once
the schedule passes `saleSupply`, `due()` is 0 forever and the sale is over. `remaining()` is the
unsold half of it.

### The NAV clamp

`Mono.mint` refuses any mint that would lower NAV, and NAV rises every time someone else claims. So
two guards, at the two ends:

- **`submitBid` floors bids at `nav()`**, not at the immutable `floorPrice`. NAV only rises, so the
  two diverge over the life of the sale and only the live one is a real floor.
- **`claim` clamps instead of reverting.** A position that filled before NAV grew past its price
  would otherwise be stranded forever, its escrow already spent. Instead it mints
  `maxIssuable(assetsIn)` — what that escrow buys at the *current* NAV.

The clamp does not short-change the claimer: they receive MONO backed by exactly the INDEX they
paid, which is the most a non-dilutive mint can hand anyone. `maxIssuable` rather than
`assetsIn / nav()` because `nav()` floors, and dividing by a floored NAV lands a wei over what
`mint` accepts.

The whole escrow goes to the vault either way, so NAV is non-decreasing across every claim —
`test_navNeverFallsAcrossClaims`.

## Sync chunking

`sync(maxTicks)` processes one window at a time from the top of book down, saving `settleCursor`
between windows. `settleCursor == 0` means "start from the top"; anything else is a genuinely
truncated sweep, where every tick above the cursor is known dry. The implicit syncs inside
`submitBid`/`withdrawBid`/`claim`/`stake`/`unstake` run at `SYNC_TICKS = 128`, and every
`sync`/`finalize` budget below that is raised to it: a sync may park the cursor — and with it
lock every weight change behind `SettleFirst` — only after that much real work. (`sync(0)` used
to park it with the loop never entered, a ~30k-gas-per-block bid DoS, round-6.) Since spliced
ridges are unlinked for good, parking now needs more than 128 LIVE ticks, each a funded bid.

**`SYNC_TICKS` does not bound one window.** `_gather` step 2 always collects its whole band, so a
single window of up to `windowTicks + 1` live ticks runs to completion regardless. The real ceiling
on what one bidder pays for someone else's backlog is therefore **`windowTicks`**, which is a
deployment choice:

| Book | Implicit sweep a bid drags behind it |
| --- | --- |
| `windowTicks = 8`, 10 live ticks | ~169k |
| `windowTicks = 255`, 256 live ticks | ~2.3M |
| nothing due (the common path) | ~26k |

Measured at ~9–17k per live tick plus the tick's deaths this pour (~10–30k each, heap pop
included, amortised one per position per lifetime; capped at `MAX_DEATHS_PER_SYNC = 128` per sync
across all its ticks, with an exact mid-tick pause). Pick `windowTicks` with the bid cost in mind, not only the
`MAX_EDGE_WEIGHT` pairing — and note that a spammer can fill the top window with dust ticks and
make every bid pay for the full sweep.

On the first window of a sweep that started from the top, `highestTick` is dropped onto the real top
of book, and after every pour onto the top still standing. Walked dead runs are unlinked (see the
splice note above), so an abandoned run of spam ticks above the book is paid for once. A window is
**never left half-poured** — a partial `W` would misprice every tick in it — so `maxTicks` budgets
*list nodes visited*, not work inside a window; the nodes a moving band admits count too.

Two stop conditions, and the difference matters:

- **window ran dry** (every tick in it exhausted): the book below can still be served, keep walking;
- **supply ran out inside the window**: nothing below is reachable, stop. Without this the walk
  would chase per-tick flooring dust down the entire book.

Permissionless and always callable. It only ever moves the book to where the schedule already says
it should be, so who calls it and when decides nothing but who pays the gas — no operation is ever
blocked waiting for a settle to finish.

## Invariants

- `currency.balanceOf(this) >= sum(live escrow) + (currencyRaised - currencyMinted)`, exactly —
  the booking reserve keeps `currencyRaised` at or under what positions are charged.
- `token.balanceOf(this) >= totalStaked` — stake is custody, never spendable by the sale.
- `tokensUnclaimed <= sum of every position's tokensOwed <= tokensUnclaimed + reserve dust` —
  MONO booked and not yet claimed; `tokensMinted <= tokensBooked <= tokensSold`.
- `Mono.nav()` is non-decreasing across every `claim`.
- `Tick.capTokens == what the seated (staked, un-exhausted) positions can still buy` —
  un-staked escrow is withdrawable but is not capacity, and dust drift is clamped to zero when
  the heap empties.
- `Tick.acc` is monotone; a stake change re-anchors before it re-weighs (never retroactive).
- A position's tokens are recoverable in O(1) at any time, across unlimited rounds.

## Surface

Declared in `src/interfaces/IGenerousAuction.sol`, which the contract inherits and which carries
all structs, events and errors. `Window` stays in the implementation — memory-only, never crosses
the ABI.


| Function | Notes |
| --- | --- |
| `sync(maxTicks)` | Permissionless, chunked, resumable. Implicit at the head of the five below. |
| `setRoundParams(K, R)` | Admin only. Effective next boundary, never retroactive. |
| `stake(amount)` / `unstake(amount)` | The caller's intra-tick weight, in sale tokens. Free during the sale, frozen `[endBlock, finalize)`, free after. Unstake-to-zero leaves a live bid inert. |
| `finalize(maxTicks)` | Permissionless, returns `done`. Flips when the post-`endBlock` backlog is drained — or provably undrainable (a complete sweep selling nothing). A call that still made progress KEEPS it and returns false; reverting here would roll the sync back, so it never does. |
| `submitBid(price, amount, owner, prevTick)` | Owner-only: `owner == msg.sender`, otherwise `Unauthorized`, including same-price top-ups. ONE bid per owner: same price harvests and grows, a different price with live escrow reverts `BidExists`. Requires `stakes[owner] > 0`. `prevTick` is a hint — the exact predecessor is used in O(1), anything else costs the bidder a list walk. Reverts `AuctionEnded` past `endBlock`. |
| `withdrawBid()` | Returns all live escrow and closes the bid (the stake stays). Won tokens stay claimable. Free cancel — see the `ponytail:` note in the source. |
| `claim(owner)` | Permissionless, always pays `owner`. **Transfers** out of the pack, packing it first if nobody has. Does **not** close the position. Scaled by the remaining pot ratio if a pack was clamped. |
| `claimAndStake()` | The same claim, credited to the caller's stake account instead of transferred. Caller-only. Degrades to a plain claim inside the lock window. |
| `mintPack()` | Permissionless, idempotent. Mints every unpacked sold token against the escrow that bought it. Implicit at the head of `claim` and called by the next sale's constructor. |
| `tokensSold` / `tokensBooked` | Cumulative. Sold paces the schedule; booked is what the pot owes claimants (sold less one token-wei per extra seat per pour). |
| `tokensMinted` / `currencyMinted` | Cumulative. The gap to `tokensBooked` is the shortfall; the gap to `currencyRaised` is what is not packed yet. |
| `saleSupply` | Immutable. The sale's entire size: the MONO it takes to close the premium standing at deploy. |
| `remaining()` | `saleSupply - tokensSold`. |
| `minPremiumBips` | Immutable. The premium the market had to show for this sale to be deployed. Readable so the bar a live sale cleared is on-chain, not just in the deploy tx. |
| `remaining` / `due` / `emittedToDate` / `roundsElapsed` / `positionOf` / `previewWindow` / `weightAt` / `tickPositions` / `stakes` / `totalStaked` / `finalized` | Views. `previewWindow` runs the same `_gather` + `_solveBand` a sync would over the same `due()`, window after window down the book (band moves included), so a UI never reimplements the curve. Two caveats it is easy to get wrong: its per-tick figure does NOT divide among the tick's seats by stake alone (a seat that reaches its escrow cap takes exactly that cap and the rest re-flows to the survivors), and it is unbudgeted while a real sync is bounded, so on a deep backlog it shows a whole sweep the next transaction only partly performs. `positionOf` has the mirror-image caveat: it mirrors `_harvest` but not the `_sync` that `claim` runs first, so with anything due it reads low by the pending pour; its per-tick figures split within the tick by stake — read `tickPositions` + `stakes` for that. |

## Tests

`test/GenerousAuction.t.sol` and `test/GenerousStaking.t.sol`. Two anchors. The staking suite
pins the worked example of `docs/staked-generous-auction.md` §5 — one tick, stakes 50/40/10
against budgets 5/100/100, a 95-token pour, answer **5 / 72 / 18** (the stake-whale dies on its
own budget and its excess re-flows) — plus the strict rule end to end (stakeless bids refused,
zombie ticks skipped by the inter-tick pour and revived by re-staking), forward-only reweighing,
the lock window with both finalize paths, seat-cap and one-bid-per-owner mechanics, and stake
custody across claims. `test/GenerousInvariants.t.sol` walks the whole surface at random (six actors, five prices;
bid/withdraw/stake/unstake/claim/claimAndStake/sync/time) and holds after every step: currency
conserved to the wei (in = held + refunded + packed), stake custody, the three token gates
(claimed ≤ minted ≤ sold ≤ saleSupply), owed ≤ unclaimed, and heap well-formedness; NAV
monotonicity is asserted inside the handler on every op. A scripted smoke pass guards the suite
against vacuity. The original suite's anchor is the paper's appendix A.9 worked example — four ticks,
`q = 0.5`, a 150-token draw (one emission round), published answer **20 / 96 / 10 / 24** — asserted
through `previewWindow`, through the sync that follows it in the same block, and through settlement.
Alongside it: emission accrual and the trailing partial round, one lazy sweep equalling three
sequential ones bit for bit, carry over an empty book, sweep-cannot-take-carry, and the three
non-retroactivity properties of `setRoundParams`. Prices sit on this contract's arithmetic grid rather than the
paper's geometric ladder, which changes nothing: the allocation depends only on each tick's weight
and its capacity in tokens.

## Relationship to `MonoAuction`

`src/MonoAuction.sol` is the same mechanism with a multi-market wrapper (`marketId`, a `reserved`
ledger, an explicit `fund`) plus a MONO/NAV price stub. `GenerousAuction` is that mechanism with the
wrapper removed for the one-sale-after-another case. Changing the distribution math in one without
the other will drift them.
