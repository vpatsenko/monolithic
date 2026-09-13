# MonoHook

`src/MonoHook.sol` — the MONO/INDEX Uniswap v4 hook. Three jobs: the price accumulator of
HANDBOOK §3.6, the trade tax of §3.4, and the wall of §3.3.
Interface: `src/interfaces/IMonoHook.sol`. Tests: `test/MonoHook.t.sol`, `test/MonoWall.t.sol`.
Rulings implemented here: `MONOHOOK-REVIEW.md` (D24), D25 (wall in the hook).

## Why all three jobs are in one contract

A v4 hook's permissions are encoded in its **address**, and the address is inside the `PoolKey`.
A hook that gains a permission later is a different hook, which means a different pool and a POL
migration. **Anything this hook cannot do on the day it ships, it can never do.** That is why the
tax is here at deploy rather than "added to `_beforeSwap` later", and why the oracle-only version
must never reach mainnet.

The wall is the same argument taken one step further: D25 moved it out of a keeper and into
`_beforeSwap` precisely because a keeper cannot be atomic with the sell it is defending against.
It needs no permission bit the tax did not already require, so it costs nothing at the address —
see **Deploying**.

## Why the oracle has to exist

§3.6 is `[LAW]`: every trigger reads a TWAP, never spot, computed from the pool's own accumulator,
and "in v4 the accumulator lives in our hook". That is not a preference — **v4 ships no oracle at
all**. `grep -ri observ lib/v4-periphery/lib/v4-core/src` returns nothing; v3's `observe()` has no
v4 counterpart.

## An EMA, not a ring buffer

v3's oracle is an array of `(timestamp, tickCumulative)` samples with a binary search over it. At
τ of a few minutes a buffer would be perfectly affordable — the sizing argument is **not** what
decides this. Two things do:

- **`grow()` is griefable and someone has to pay it.** Cardinality is a live operational chore
  with no natural owner.
- **It fails closed.** Under-grown, `observe` reverts `OLD` — and the reading that goes dark is
  the *gate*. A price oracle whose failure mode is "the machine stops" is worse than one that
  cannot fail.

An EMA in tick space is one slot, forever, at any horizon, with nothing to grow and nothing to
search. It carries the same information: a time-weighted mean of ticks is a geometric mean of
prices, exactly what `tickCumulative` averages.

The trade, named honestly: an EMA has **no fixed cutoff**. A boxcar TWAP forgets everything older
than its window; an EMA's tail decays but never reaches zero. For a gate, a rate and a strike leg,
"recent matters more, old fades" is the property being bought.

### The horizons: three names, two EMAs

They are **`tau`, not window widths**: a displacement held `t` seconds moves the reading
`1 - exp(-t/tau)` of the way, so `tau` is the 63% point.

| Horizon | Consumer | τ (HANDBOOK §4) | EMA |
| --- | --- | --- | --- |
| `Strike` | the money path, composed by the caller as `max(spot, strike)` | **1 min** | `emaStrike` |
| `Throttle` | accrual rate + tap refill | **5 min** | `emaSlow` |
| `Gate` | the LIVE/PAUSED chatter-damper on the 15% threshold | **5 min** | `emaSlow` |

**Gate and throttle are one EMA, not two that agree.** §4 is explicit — "one EMA for
gate+throttle", "gate and throttle read one EMA" — and the earlier 1/5/15 triple could not express
it: the constructor demanded *strictly* increasing horizons, so the §4 numbers reverted
`InvalidHorizons` at deploy. Collapsing them is the literal reading and it is also simply better
code: 64 bits less per pool and one `_decay` less per swap.

The enum keeps three members anyway. `Throttle` and `Gate` are separate *decisions* — a rate and a
door — and a call site should say which it is making; if a re-sim ever splits them again, nothing
at the call sites moves. For the same reason there is no `tauThrottle()`/`tauGate()` pair: two
accessors for one number read as two knobs that happen to agree, and invite a caller to believe
they can be set apart. There is `tauStrike()` and `tauSlow()`.

D24 collapsed these from day-length windows. Day lengths solved a problem the round structure
already solves: the prize per round is lot-bounded, so every attack must hold a displaced price
across blocks, against arbitrage and tax, for pocket change. The strike window equals the round
length — each round prices at the standing price of its own minute.

Two standing instructions from the ruling:

- **The gate is a chatter-damper, not a security boundary.** Throttle is ≈ 0 at the 15% threshold,
  so there is nothing behind the door to fake open. **Do not add hysteresis.**
- **The strike reference is plain `max(spot, EMA_1m)`.** No band, no crash-skip, no clamp; a ±band
  guard was considered and rejected. At τ = 1 min the EMA converges in ~2 minutes, and a
  pump-at-crank only overpays the vault. **Do not re-add defensively.**

They stay constructor arguments so a re-sim needs no new bytecode. Strictly increasing, or the
constructor reverts `InvalidHorizons`.

## What accrues, and why nothing intra-block does

`beforeSwap` reads the tick the pool is **sitting on** — the price that has stood since
`lastUpdate` — and accrues that over the elapsed seconds. The tick a swap is about to move to has
been true for zero seconds and is worth zero.

So a price pushed and released inside one block contributes **nothing**: the first swap accrues the
pre-push price, the second reaches `dt == 0` and accrues nothing. To move the reading you must hold
the displacement across a block boundary, exposed to arbitrage the whole time. **There is no atomic
path**, which is the load-bearing half of why τ can be minutes rather than hours.
`test_intraBlockSpikeCostsTheOracleNothing` is the check;
`test_heldDisplacementDoesMoveTheReading` is its control, so it cannot pass on a dead oracle.

## Reading

`meanTick(id, horizon)` folds the seconds since `lastUpdate` in before answering, using the same
accrual the next swap will write. So a pool nobody has swapped in hours reads as the price
**actually standing**, and the preview never disagrees with the commit
(`test_readAgreesWithTheNextWrite`). `meanSqrtPriceX96` is the same reading as a `sqrtPriceX96` —
a drop-in for `slot0`'s.

Both revert `NotInitialized` for a pool this hook has never been named by, rather than answering
with tick 0, which would silently mean a price of 1:1.

**`max(spot, strike)` is the caller's job.** The consumer already reads spot and already owns the
orientation and unit conversion; splitting one formula across two contracts would be worse.

## The tax

### A continuous curve, not stepped zones

Stepped mNAV zones put a front-runnable boundary on the chart — a 3× sell-fee jump at 1.5 is worth
nudging a trade across, and it also fails router slippage checks in a burst when it flips. A lerp
between two anchors has no boundary at all:

```
tax(m) = lerp((mStart, rateStart) -> (mEnd, rateEnd)), clamped flat outside both anchors
```

Rates are in **pips** (1e6 = 100%), v4's own fee unit. `m` is mNAV in WAD. Each side is one
storage slot.

**Launch anchors (D24, tunable):**

| Side | anchors | at book | at 2× | at ≥3× |
| --- | --- | --- | --- | --- |
| `sellTax` | 0.5% @ 1.00 → 4.5% @ 3.00 | 0.5% | 2.5% | 4.5% |
| `buyTax` | 2.0% @ 1.00 → 1.5% @ 1.50 | 2.0% | 1.5% | 1.5% |
| **round trip** | | **2.5%** | **4.0%** | **6.0%** |

Sell rises with the premium — the profit-taker at a high premium is the primary NAV engine. Buy
falls, so the vault is cheapest to enter when it most needs entrants. `test_launchAnchorsMatchTheRuling`
pins these against the ruling's own numbers.

### The rate input is spot over book — deliberately not a TWAP

`mNav()` is `spot / Mono.nav()`, both in INDEX per MONO, WAD. NAV comes off **balances**; the
accumulator is not consulted anywhere in the tax path.

That is the right way round. Pushing the price towards a cheaper rate **is** the taxed trade, so
the manipulation pays for itself, while a lagging reference would invent an exploit the live read
does not have. `test_taxReadsNavFromBalancesNotTheOracle` proves the coupling: a donation to the
vault reprices the tax in the same block while the EMA does not move.

**Nothing in the tax path may revert** — a tax that can revert is a pool that can be bricked. Every
input is either bounded by construction or degrades to a rate: an unpriceable vault answers `mNav`
of 0, which clamps both curves to their opening anchor.

### Ceilings governance cannot reach

| | |
| --- | --- |
| `MAX_TAX_PIPS` | 5% per side. Checked on both anchors. Constant. |
| `MIN_VAULT_BIPS` | 50%. The vault's share of the take can never be voted below it. Constant. |
| `mStart < mEnd`, `mStart != 0` | or the lerp divides by zero / runs backwards |

Anchors, the split and the treasury are all settable **behind the timelock** — `queue` / `cancel` /
`execute` with a 2-day notice and a `timelocked` modifier that only `address(this)` satisfies, the
same pattern as [`Index`](Index.md). Numbers adjustable forever; code frozen at deploy.

### Collection: hook-take, not an LP fee

**An LP fee accrues to liquidity providers.** That is harmless while the pool is 100% POL and a
silent siphon the moment it is not, so the hook takes the fee itself, in the **input** token,
whoever is LPing.

Taking the input token needs both return-delta legs, because the input is on a different leg
depending on the swap type:

| Swap | specified currency | fee taken in | where |
| --- | --- | --- | --- |
| exact input | the input | specified leg | `_beforeSwap` |
| exact output | the output — the input amount is not knowable until the swap has run | unspecified leg | `_afterSwap` |

This is the only reason `_afterSwap` exists; the accumulator wants nothing from it.

### Distribution and the crank

Fees accumulate as real ERC-20 on the hook and are paid out by `crank()`, which is permissionless.

| Side | Collected in | Vault share (default 70%) | Treasury (30%) |
| --- | --- | --- | --- |
| Buy | INDEX | transferred to `Mono` — it has no entry point, so this is pure backing and NAV rises | INDEX |
| Sell | MONO | **burned** — supply down, NAV up | MONO |

The vault may never hold MONO `[LAW]`, which is why its share of the sell tax is retired rather
than banked; burning counts as vault-side for the 50% floor. The treasury's MONO share is a natural
source for P11 referral payouts — spent without ever being market-sold.

## Cost

Measured against the identical pair with no hook, both warm (`test_hookOverheadPerSwap`):

| | gas |
| --- | --- |
| swap, no hook | ~85k |
| swap, this hook | ~129k |
| **overhead** | **~44k** |

Roughly 19k of that is the accumulator (one hook call, one `extsload`, one slot write, three
`expWad`s) and the rest is the tax (a `nav()` call, the curve read, and the `take`). The test
asserts `< 60_000` as a regression guard.

`expWad` rather than the cheaper Padé factor `tau / (dt + tau)`: Padé is first-order, so after a
silence it leaves a residual `tau / (dt + tau)` where the truth is `exp(-dt/tau)` — at τ of a
minute, a pool quiet for an hour would still read 1.6% of the way back to an hour-stale price.
`expWad` saturates to 0 past ~41 time constants instead of reverting, which is correct.

**ponytail: the fee is `take`n as real ERC-20 on every taxed swap** rather than minted as an
ERC-6909 claim and settled in the crank. Claims would save perhaps 8k a swap at the cost of an
`unlockCallback` and a second accounting surface; `balanceOf` being the whole ledger is worth more
today. Revisit if swap gas becomes the binding constraint.

## The wall

§3.3 `[LAW]`. On a MONO → INDEX sell the pool is allowed down to `NAV x (1 - wallTick)` and no
further; whatever the seller still has left at that point, the hook buys off the vault at the wall
price and **burns in the same transaction**. Buys are untouched.

### It does not compute the split — it asks the pool for it

The obvious implementation solves `dx = L x (1/sqrtT - 1/sqrtC)` for the pool's leg. We do not.
`_wall` re-enters `poolManager.swap` on its own pool with `sqrtPriceLimitX96` set to the wall
price and hands it the whole (post-tax) input; v4's own engine takes what it can and stops dead at
the bound, and the returned delta says how much that was. The remainder is the wall's.

What that buys:

- **"The pool never ends below the wall" is enforced by the price limit, exactly**, across any
  liquidity shape. No approximation to audit. `Mono.premiumCloseAmount` carries a standing
  `ponytail:` note that the same closed form is single-range-only and silently understates once a
  tick is crossed — that note would have become a correctness bug here.
- **The one-sided POL case needs no special handling.** §3.5's POL is MONO-only from NAV up, so
  on day 0 there is no bid at all; the inner swap simply takes nothing and the wall fills 100%.
  Same code path as a book that is merely thin. (`_wall` still skips the inner call when the pool
  is already at or past the wall, because `Pool.swap` reverts `PriceLimitAlreadyExceeded` rather
  than no-opping.)
- **No re-entrancy guard of our own.** `Hooks.beforeSwap` and `Hooks.afterSwap` both open with
  `if (msg.sender == address(self)) return` — v4 skips a hook's own hooks. So the inner swap does
  not recurse and does not double-accrue the oracle.

The hook then full-consumes the swap: it returns `+amountIn` on the specified leg and `-out` on
the unspecified one, so the outer `Pool.swap` is handed `amountToSwap == 0` and returns without
touching a pool that is already exactly where `_wall` left it.

**Indexers: a wall sell emits two `Swap` events** — the inner one with the pool leg's real
amounts, then the outer one with zeros. The seller's true fill is the inner `Swap` plus the
`WallFilled` alongside it, not either on its own.

### Why the burn is the law and not an optimisation

The vault pays `R x (1 - t) x NAV` and retires `R` shares, so the floor moves from `I/S` to
`(I - R*w)/(S - R)`, which is strictly greater for any `w < NAV`. **The one outflow the vault has
raises the floor it drains.** Skip the burn and the identical code is a redemption that empties
the pot. It is also the whole reason `Mono.setWall` can grant an *unbounded* allowance: the only
thing this hook can do with the pot is lift NAV.

That is also why `wallTickBips` may never be zero. At zero the bid sits exactly at NAV and a fill
is floor-*neutral*; the tick is what makes the outflow accretive. `MAX_WALL_TICK_BIPS = 1000` is
the ceiling governance cannot reach — what it really guarantees is that the bid stays strictly
under NAV, and 10% is simply far more room than the 0.5–1% `[SIM]` range will ever want. The
launch value is 100 bips, the `0.99 x NAV` §3.2 spells out.

### Arming, and standing down

The hook ships inert. `Mono.setWall(hook)` is a one-shot `DEFAULT_ADMIN_ROLE` call that stores the
address and grants the allowance together, so `wallArmed()` — `mono.wall() == address(this)` — is
an exact reading of "can pull from the vault" with no allowance read. Solady does not erode a max
allowance, so it never goes stale. `Mono` checks `wall_.mono()` is itself before granting: the
allowance is unbounded, so the address it points at is the entire protection.

`_wall` stands down — falls through to the plain taxed swap, with nothing to unwind because every
one of these is decided before anything moves — when the wall is unarmed, when the post-tax amount
is zero, when the **vault** could not cover the worst case, or when the **PoolManager** could not.

The vault one is unreachable arithmetic (the bid is under NAV and nobody can sell more MONO than
exists, so the worst case is `S x (1-t) x I/S < I`) and is checked anyway: this is a branch where
being wrong reverts inside someone else's swap, and §3.3 is explicit that the wall never bricks
the pool.

### The manager-balance ceiling

The other one is real, and it is the least obvious thing in this contract.

`poolManager.take` moves **real ERC-20**. Mid-swap, the MONO the manager is holding is the pools'
**reserves** — the seller's own input does not arrive until the router settles, which happens after
every hook has run. So the wall can only buy MONO the manager already has, and `_wall` checks
`mono.balanceOf(poolManager) >= net` up front.

Why it is usually slack: §3.5's POL is **one-sided MONO from NAV up**, so the book the wall
defends is precisely the book that is full of MONO. It binds only once the pool has been bought
out into mostly INDEX — and in that state the pool leg absorbs most of the sale by itself, so the
fill left for the vault is small. The two move against each other.

Why the bound is `net` and not the actual fill: the split is only known *after* the inner swap, and
by then standing down is no longer free. `fill <= net` always, so the worst case is what can be
tested before committing.

**ponytail: conservative, and it degrades to the plain swap rather than to a revert.** The exact
fix is to take the fill as an ERC-6909 claim and redeem it in `crank` — but a claim is not MONO
and cannot be burned, so that trades this ceiling for a burn that is no longer same-transaction,
which is the `[LAW]`. Revisit only with that resolved.

`test_aBookTooMonoPoorToCoverTheFillStandsDown` pins the degraded path, and it is worth knowing
that it exists: `test_aBookWithNoBidIsFilledEntirelyByTheWall` is **not** on its own evidence that
a thin book works, because that test's manager is still fat with MONO from liquidity at other
ticks.

### Exact-output sells are refused

§3.3 permits either mirroring the split or reverting. We revert (`ExactOutputSellUnsupported`),
and only once the wall is armed — buys and pre-arming sells are untouched. Mirroring means running
the whole split again in the output direction and moving the tax out of `_afterSwap` to pay for
it: a lot of consequential code for a path routers essentially never take on a sell.

**ponytail: refusal, not mirroring.** Build the mirror if a real integrator turns up needing
exact-output sells.

### Tax interaction

The tax is charged on the **whole** input before the split, which is what §3.3's "sell tax applies
to wall fills" asks for, and it means the split never has to know the tax exists.

## Storage

One slot per pool for the accumulator: `int64` × 2 EMAs (mean tick × `PRECISION = 1e6`) +
`uint32 lastUpdate` + `bool initialized` = 168 bits. A tick maxes at 887272, so a scaled EMA
reaches 8.9e11 — ten million times inside `int64`, resolving a millionth of a tick against a tick
that is already only 1bp. One slot each for `buyTax` and `sellTax`. `vaultShareBips`, `wallTickBips` and `treasury` share
one: 16 + 16 + 160 = 192 bits.

`lastUpdate` wraps in 2106, and wraps correctly: modular subtraction still yields the true elapsed
seconds unless a pool sits unswapped for 136 years. Same assumption v3 makes.

## Deploying

`script/DeployMonoHook.s.sol`, in two phases. The split is the point: after phase 1 the oracle and
the tax are live on a real pool and the **wall is still inert**, so all of it can be watched with
real swaps before anything can reach the vault. Phase 2 is the irreversible step.

A v4 hook's address **is** its permission set, so it has to be mined:

```
AFTER_INITIALIZE | BEFORE_SWAP | BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA
= (1<<12) | (1<<7) | (1<<3) | (1<<6) | (1<<2) = 0x10CC
```

**The wall added nothing to this.** It works entirely inside `beforeSwap` and its return delta,
both of which the tax already needed — so the address the tax mines is the address the wall wants,
and the `[LAW]` that a hook can never gain a permission cost nothing here.

1. `DeployGenerousAuction.s.sol --sig 'deployMono()'` — deploy `Mono`, genesis-mint to set the
   opening NAV;
2. **`DeployMonoHook.s.sol`** — mines `0x10CC` against forge's CREATE2 deployer
   (`0x4e59b4…4956C`, which is what a salted `new` broadcasts through), deploys, initialises the
   MONO/INDEX pool **at NAV** so mNAV opens at 1.0, and calls `mono.setPool(manager, key)`.
   `afterInitialize` refuses any other pair (`WrongPair`) and seeds the accumulator, so the oracle
   is live from that block rather than dark until the first swap. `BaseHook`'s constructor asserts
   the address matches `getHookPermissions()`, so a bad mine reverts at deploy —
   `test_theMinedAddressSatisfiesTheHookItDeploys` proves the script's flag word and the
   permissions agree before deploy day rather than during it;
3. `DeployGenerousAuction.s.sol` phase 2 — the auction, whose constructor reads the premium gate
   off this hook's EMA. It `require`s the pool is already named;
4. **`DeployMonoHook.s.sol --sig 'armWall()'`** — `Mono.setWall`, granting this hook the vault's
   one unbounded INDEX allowance. One shot, forever, and the only thing that turns the wall on.

**Initialise with `LPFeeLibrary.DYNAMIC_FEE_FLAG` (`0x800000`) as `PoolKey.fee`.** Nothing sets a
dynamic fee — the tax is hook-take, not an LP fee — but `updateDynamicLPFee` is gated on the pool
having been *created* dynamic (`PoolManager.sol:340`) and the fee is in the `PoolKey`, so a static
pool can never become one. Free now, a POL migration later. Same argument as the permission bits.

`POOL_TICK_SPACING` is duplicated in both scripts and must match: the key hashes to a different
(uninitialised) pool otherwise, and `setPool` refuses it.

### Routing, unresolved

HANDBOOK:617 chose dynamic LP fees precisely *because* fee-only hooks auto-route on uniswap.org
while "return-delta (custom-curve) hooks need Labs allowlist". D24 overrides that on
LP-siphoning grounds, which is right — but it spends auto-routing. **Confirm the 4663 allowlist is
actually held before this is deployed**, because §3's whole point is that it cannot be changed
after.

## Not this contract

- **The launch ramp is retired.** `afterInitialize` seeding makes readings valid from t = 0, so the
  old `min(elapsed, target)` bootstrap has nothing left to cover. Remove it from any consumer that
  inherited one; there was never one here.
- **Consumer-side (auction), still outstanding:** a permissionless, incentivised crank for the
  rounds, and an **escalator lot-cap that is hardcoded and modest**. The second one matters here:
  "the amount at stake per round is tiny" is the invariant the short τ choice leans on, and
  `GenerousAuction.emissionPerRound` is currently an admin-settable `uint128` with no ceiling —
  `saleSupply` caps the total, not the round. Until that lands, the oracle's security rests on an
  admin's discretion.
- **`Mono` is wired to this contract now, both halves.** `setWall` arms the wall; `setPool` names
  the v4 pool and, with it, pins this hook as the oracle. `Mono.emaPrice` / `emaPremiumBips` read
  `meanSqrtPriceX96` here, and `GenerousAuction`'s premium gate reads those. The v3
  `IUniswapV3Pool` stub is gone from `Mono` entirely. What is still NOT built is the §4 round
  machinery that would consult the gate and throttle EVERY ROUND rather than once at deploy. Migrating it
  means `Mono.pool` (an `address`) becomes a `PoolKey`/`PoolId`, `setPool`'s `token0()/token1()`
  check becomes a `currency0/currency1` check that can also pin the hook address, and
  `poolPrice()` / `premiumCloseAmount()` reroute through `StateLibrary` and this hook.
- **`Index._poolPrice` is a separate pile.** Two notes for it, per D24: the stock/USDG pools on
  this chain were found via the **V4Quoter** (a v3 stub may read nothing at all), and the ratified
  D22 veto prefers the **Rialto propAMM `getAmountOut`** as the live-market source. Steer there
  rather than reusing anything here.
