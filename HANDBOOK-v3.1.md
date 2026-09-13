# MONOLITHIC — Protocol Handbook v3.1 (MONO-only)
**2026-09-07 · supersedes v3.0 · authoritative spec, ratified-only content**
Tags: `[LAW]` immutable · `[LOCKED]` decided · `[SIM]` number pending sim ·
`[DECIDE]` principal's call pending · `[OPEN]` design gap · `[DRAFT]` under
cofounder review, not ratified (§12)

Naming: the wrapper token is **UNIT** everywhere (public and code). "INDEX"
was the working name; the ticker is taken.

## What changed: v3.0 → v3.1
| Area | v3.0 | v3.1 |
|---|---|---|
| Wall | "standing bid", mechanism open | **lives in the hook** — split fill, atomic buy-and-burn (D25) |
| Vault outflow | none built | ONE allowance to the hook, nothing else |
| POL | two-sided at NAV | **one-sided MONO from NAV up**, backed, treasury-owned; bids re-concentrated above the wall as NAV rises (P11 rider) |
| τ windows | gate 15m / throttle 5m / strike 1m | **gate 5m / throttle 5m / strike 1m** (one EMA for gate+throttle) |
| Fire escape | escrow + claim (Mode 2) | **park in place**, no transfer (D26) |
| Channel guards | divergence veto + daily meter | divergence veto only; meter dropped |
| Frozen burn leg | skip-forfeit | **IOU** (`owed`/`reserved`/`claim`), P6g amended |
| addStock target | % allocation, feed-priced | **raw tokens per UNIT**, no price read (D19 as written) |
| Treasury | separate contract | **a multisig address** |
| Treasury trim | 20% fixed | 20% hardcoded MAX, adjustable below, 7-day timelock |
| Compound | claim or compound | **auto-compound preferred** (dev to confirm) |
| Crank | per round | one crank settles all elapsed rounds; round length `[SIM 1–5 min]` |
| UNIT entry | per-user USDG zap (8 swaps) | **UNIT/USDG pool**, arbs pay the mint gas; no per-user zap |
| Fee scale | mixed | one shared scale constant (cleanup) |

---

## 1. What Monolithic is  `[LAW]`
One token, $MONO, on Robinhood Chain (4663). Backed by UNIT (a wrapper of
tokenized stocks) held in a vault that only fills. Floor = vault ÷ supply,
provable from balances, non-decreasing. Price floats freely above; the premium
is the fuel. Two channels monetize it: a tax on every trade and a harvest that
sells small amounts of new MONO above the floor. The only vault outflow is the
wall — the hook buying just under the floor and burning everything it buys, so
even the exit raises the floor. No rebase, no printed APY, no second token, no
redemption.

**Framing law (binding, marketing-wide):** "hold and your floor rises; stake
and you also earn the spread." NEVER "stake or be diluted."

## 2. Glossary
| term | meaning |
|---|---|
| UNIT | wrapper token over tokenized stocks; the vault's only asset |
| floor / NAV | vault UNIT ÷ MONO supply (UNIT per MONO; USD only for display) |
| premium p | pool EMA ÷ NAV − 1 |
| wall | hook-side fill at (1 − wallTick)×NAV; fills burned `[LAW]` |
| tick x | staker's premium share bid, 50–100% (strike = NAV + x·p) |
| harvest power | staked MONO, 1:1; the auction weight |
| funded stake | staked MONO whose budget can settle fills — only this has share |
| pour | one round's capacity split across ticks, q-curve, top-first |
| calendar | immutable weekly cap schedule, decaying to terminal |
| POL | protocol-owned liquidity: the MONO we put in the pool + the UNIT buyers pay in |

## 3. The machine
### 3.1 Vault `[LAW]`
Holds UNIT only. Inflows: genesis seed, tax sweeps, harvest strikes. Outflow:
the wall, via ONE allowance to the hook, set once. Never holds MONO or own-LP
as backing. Vault ≠ treasury (treasury = multisig address).

### 3.2 Floor `[LOCKED]`
NAV from balances only, no oracle. Denominated in UNIT. Non-decreasing under
every code path (mint above NAV, wall burn at 0.99×NAV, tax in).

### 3.3 Wall — in the hook, split fill `[LAW]` mechanism / `[SIM]` tick (D25)
On every MONO→UNIT sell the hook computes how much MONO takes the pool from
its current price down to the wall price `NAV × (1 − wallTick)`; that part
swaps in the pool. The remainder the hook fills itself from the vault's
allowance at the wall price and burns in the same tx. Pool never ends below
the wall; seller gets the pool down to the wall and exactly the wall price
after. Buys untouched. Pool portion is clamped at the lowest tick with
liquidity (one-sided POL), vault takes the rest. Exact-output sells: mirror
the split or revert when the wall would engage — never a path that leaves the
pool under the wall. Never bricks the pool: if the vault pull fails, plain
swap. Sell tax applies to wall fills. `wallTick` 0.5–1% `[SIM]`, timelocked
under a hardcoded ceiling (can never reach NAV). No keeper, no redemption.

### 3.4 Tax `[LOCKED]` (D24)
Continuous curve per side, input = spot ÷ NAV. Launch anchors `[SIM]`: SELL
0.5% @ 1.00 → 4.5% @ 3.00; BUY 2.0% @ 1.00 → 1.5% @ 1.50. **5%/side
ceiling hardcoded**, anchors adjustable within it under a 2-day timelock.
Distribution 70/30 both sides: buy tax (UNIT) → 70% vault / 30% treasury;
sell tax (MONO) → 70% burned / 30% treasury in MONO. Vault-side floor 50%
hardcoded. Hook-take, never LP fee; no exemptions (D21). Sweep = permissionless
crank.

### 3.5 Pool and POL (P11 rider, 2026-09-06)
MONO/UNIT v4 pool with the tax-wall-EMA hook. **POL = MONO only, one-sided,
full range from NAV up.** No UNIT side: the wall is the bid. POL MONO is
minted counted and backed like every MONO; size `[SIM 5–10%]` of genesis
supply (was 15%; a thinner POL routes more early demand through the harvest
into the vault). Treasury-owned, multisig + timelock.
**Re-concentration policy (treasury, not code):** as NAV rises the pool's
collected UNIT drifts below the wall where it can never fire. Re-range the
bid side into `[wall, market]` whenever NAV moves enough to matter; bottom of
the band = the wall. Same UNIT, several times the depth where sellers land.
No LP fee on this pool ⇒ no outside LPs; the POL is the market. Depth only
grows by re-ranging or by price rising (√P).
Unbacked POL is REJECTED: it becomes a vault liability once NAV passes the
price it sold at (worked examples in chat 2026-09-06).

### 3.6 UNIT/USDG entry pool (2026-09-06)
No per-user zap (8 stock swaps ≈ 2M gas ≈ $2–10 at current RH gas). Seed a
tight UNIT/USDG pool (±1–2% band around NAV); arbs mint/burn UNIT against the
stock markets and keep it at NAV, paying the mint gas. Users do one swap. This
pool MAY carry an LP fee (it is not the tax pool). Depth target $100–200k
`[DECIDE source]`. Batch-zap (queued USDG, keeper mints in bulk) is the fallback
if the pool route isn't enough.

## 4. The harvest — stake-native generous auction `[RATIFIED P10/D23]`
The only mint path; the auction is the sole minter `[LAW]` (minter-role
grants behind a ~30-day timelock).

**Participate:** stake MONO → harvest power (1:1, no time multipliers, no
warmup) → ONE bid: tick x ∈ [50, 100]% of premium, 5-pt spacing `[SIM]` →
attach budget (UNIT; USDG converts via the entry pool). Share within a tick =
your power ÷ tick power. Unfunded power has zero share. Re-tick any time.
Unstake delay short `[SIM 1h–24h]`. Auto-compound preferred: fills land
directly as staked MONO, no claim step (dev to confirm); budget top-up manual.

**Each round (`[SIM 1–5 min]`):** gate open if p ≥ 15% on the 5-min EMA;
offer = lot × throttle, lot = weekly cap pre-split across the week's rounds
(capacity never exhausts; unminted lapses; no "week full" state).
throttle = clamp((p − 15%) / (band − 15%)) `[SIM band]`. Pour: top tick
first, weights q^(τ−i) `[SIM q]`; within a tick pro-rata by funded power;
strike = NAV + x·p, p from max(spot, EMA_1m). Vault locks NAV + 0.5p;
treasury takes up to **20% of the excess (hardcoded max, adjustable below,
7-day timelock)**. Escalator lot ×1.5 on ≥90% fills at throttle ≥0.95, lot-cap
HARDCODED. Throttled capacity is never minted.

**Crank:** permissionless; ONE crank settles every elapsed round (closed-form
schedule); tiny tip from the lot; our bot cranks when gas is calm. Uncranked
rounds lapse safely.

**Calendar `[LAW]`:** weekly CAP anchored to week-start supply: 100 → 50 → 25
→ 12 → terminal `[SIM 6–10%]`/wk. The throttle is the premium-driven emission
below the cap, before and after terminal. Say "the mintable amount shrinks
weekly," never "supply drops."

**TWAP discipline (D17 + 2026-09-04) `[LAW]` structure:** one hook EMA
accumulator (zero intra-block accrual), **gate 5 min · throttle 5 min ·
strike 1 min**, gate and throttle read one EMA. Strike = max(spot, EMA_1m),
no band, no skip rule. Security by structure: EMA unmovable intra-block +
max(); prize lot-bounded; paint-down self-strangles; paint-up pays the vault;
gains socialized, costs private; residual = paid griefing. Gate is a
chatter-damper, not a security boundary. Never print window lengths publicly.

## 5. The UNIT wrapper (D14/D18/D19/D22/D26)
- Composition growth-only (NEVER REDUCE). **Fire escape = park in place (D26):**
  removes a frozen stock from the recipe, tokens stay in the contract outside
  NAV, no transfer, 2-day timelock; re-add via `addStock` if it thaws. Sellable
  dead stocks go through the Arcus in-pot sale (built, ERC-1271, proceeds stay
  in the pot). No code path extracts a stock position from the pot.
- Mint = full recipe at the pot's proportions, price-free. Burn = pro-rata raw
  units, price-free; a frozen leg is booked as an IOU (`owed`/`reserved`,
  claim later — P6g amended). Both 24/7.
- Reallocation: `addStock` takes a **raw tokens-per-UNIT target** (governance
  does the dollar math off-chain; no price read). Deficit channel prices the
  new stock from Chainlink ×(1 + 1% haircut) (D20); **auto-closes inside the
  last mint** (remaining deficit < one share's worth → take what's needed, rest
  by recipe, clear the flag). Recipe mint reopens whenever the channel can't
  quote (D22 rider). No daily meter (dropped: the two-source check is the
  blast-radius control).
- **D22 price guard:** per name, every channel mint checks feed vs a live
  market source (Rialto propAMM, Arcus, or v4 pool — must be a REAL 4663
  source, the v3 `slot0` read is a stub). Divergence > ~2% `[SIM]` under a 10%
  hardcoded ceiling → that name halts. Band setter is INSTANT for now
  (asymmetric tighten-now/loosen-timelocked to be discussed). No age check on
  the channel path; the 1h age rule survives only on `saleFloor`.
- Feeds are token prices (uiMultiplier included) — never multiply. Weekends
  need no calendar code.
- `setPriceFeed` under the 2-day timelock, split so one call never moves both
  a feed and its check source.
- P7 wrapper fee `[DECIDE]` (starts 0, ≤5% cap, timelocked).

## 6. Treasury and team `[LOCKED]`
Treasury = a multisig address. Inflows: 30% of tax (UNIT on buys, MONO on
sells) + up to 20% auction trim + Index fees. Additive only. Holds the POL
position. Team economics = treasury flows; no equity token (D23). Treasury is
long MONO by construction (sell-tax share) and should stake it.
Team/referral pMONO: see §12 `[DRAFT]`.

## 7. Laws & parameters
**`[LAW]`:** vault outflow = wall only (one allowance to the hook); wall fills
burn; mint only via harvest above NAV; auction sole minter; no perpetual
emissions; no printed rewards; every minted token paid for above backing;
EMA-only triggers; wall/harvest mutual exclusion; calendar immutable, terminal
rate fixed at deploy; additive-only treasury; vault ≠ treasury; basket NEVER
REDUCE; funded-stake-only share; tax ceiling 5%/side hardcoded; escalator
lot-cap hardcoded; wallTick ceiling hardcoded; treasury trim ≤ 20% hardcoded;
vault-side tax share ≥ 50% hardcoded; no redemption path, ever.

**`[SIM]` queue (campaign-2):** POL size 5–10%; terminal rate; q; tick
spacing; throttle band; wallTick; divergence band; unstake delay; round length
1–5 min; lot bounds; anti-flicker params. Align sim to one-sided POL, τ 5/5/1,
pre-split lots, new tax anchors, $1M genesis.

**`[DECIDE]` queue:** P7 wrapper fee; governance successor; UNIT/USDG pool
capital source; LP fee on the entry pool; staker fee share (§12).

**Mutability `[LOCKED]`:** immutable = laws + calendar + reserve x + wall
mechanism. Timelocked within hardcoded ceilings = tax anchors (2d), wallTick,
treasury trim (7d), gate threshold, throttle band, lot bounds, minter grants
(~30d). Instant under ceiling = divergence band (for now).

## 8. Chain facts & rails `[VERIFIED]`
Chain 4663 (Arbitrum Orbit), 0.1s blocks. USDG 0x5fc5…d168. Feeds: 0.5%
deviation / 24h heartbeat, 24/5, token-priced. Depth (2026-08-26): ≤$100k clips
fill at bps on Arcus RFQ and Rialto; $250k+ only NVDA/SPCX.
**Gas (2026-09-06):** base fee 0.02 gwei (Aug 22) → ~0.4 gwei median, spikes
to 2.0; ≈ $1 per 1M gas now, $5 at spike. Design for 1–2 gwei: crank batching,
no per-user zap, show gas in UI, soft minimum ~$200 on budget top-ups.
Pending: Rialto integrator key (wallet-signed), one real Arcus settlement test.

## 9. Security posture
Floor invariant fuzzed (0 violations). Answers: gate paint (EMA + lot-bounded
prize), strike paint (max(spot,EMA)), stale/wrong feed (two-source veto +
haircut), pool-pin (veto-only), dust/cycling (P7 `[DECIDE]`), inflation attack
(MIN_LIQUIDITY), free-option book (funded-stake rule), flash-stake (never
profitable, no warmup), wall drain (impossible: spends only ≤ 0.99×NAV, burns,
accretive by construction), owner extraction from the pot (no path exists:
D26 + timelocked feeds). Issuer freeze → IOU leg + park in place.

## 10. Launch (growth mode) — mechanics `[LOCKED]`, terms `[DRAFT]` §12
Seed → UNIT → vault (multi-asset genesis allowed). Day-0 NAV $1.00. POL minted
counted, one-sided from NAV. Genesis floor opens below entry by the POL share;
team's tax/trim share → vault until floor = entry. Calendar 100/50/25/12 →
terminal. Dashboard per DASH-HANDOVER + FE-ANSWERS-overview; auction UI per
the reviewed mocks (harvest power → bid → budget). Growth mode ends at
terminal; premium harvested at the terminal cap forever.

## 11. OPEN
1. Governance successor `[DECIDE]` — multisig + long timelock at genesis,
   one-way handoff to time-locked staked-MONO voting.
2. P7 wrapper fee `[DECIDE]`.
3. UNIT/USDG entry pool: capital source and whether it carries an LP fee.
4. Divergence-band mutability: asymmetric option, later.
5. IOU keyed to recipient (router burns strand the claim): claim-on-behalf
   one-liner, undecided.
6. Routing check: Uniswap UI / router / bots through a return-delta hook on
   4663 (testnet), deferred.

## 12. DRAFT — under cofounder review, NOT ratified (2026-09-07)
- **Raise:** $1M, FCFS, 24h window, everyone pays floor. Closes at $1M.
- **Whitelist:** connect X or wallet or both → instant score, tier, referral
  link. Score = wallet holdings on RH chain (stock tokens, NET/NUKE, age) +
  X account score. Referrals lift one tier, unlimited invites, no referral
  rewards. Tier sets the cap only: Founder 70+ $5k · Holder 40–69 $2.5k ·
  Member 20–39 $1k · Waitlist $500.
- **Team:** either 10% pMONO (30d linear, exercise at floor only) OR no team
  allocation at all, team buys at launch on published wallets. Leaning the
  latter: "no team tokens, no options, same price as you."
- **Staker fee share:** +1% sell-side slice (inside the 5% cap) paid to stakers
  in MONO — "sellers pay the people who stay." Vault/treasury shares
  untouched. Base-layer yield; headline numbers are measured harvest capture
  and floor growth, never projected.
- **Hook-native backed POL** (NAV of every pool buy → vault, zero genesis
  dilution): possible, sound, more immutable hook code. Parked.
