// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {LibSort} from "solady/utils/LibSort.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IGenerousAuction} from "./interfaces/IGenerousAuction.sol";
import {IMono} from "./interfaces/IMono.sol";

/// @title GenerousAuction
/// @notice The harvest channel (HANDBOOK §3.5): bidders escrow INDEX, the schedule releases MONO,
///         and every claim mints it against the escrow it filled from — so the strike lands in the
///         vault in the same transaction the supply is created.
/// @notice One token, one currency, one persistent book, emitting continuously: every
///         `roundBlocks` blocks releases `emissionPerRound` tokens, split across every live tick
///         by geometric weight `q^d` instead of filling high → low. WITHIN a tick the split is by
///         STAKE of the sale token, capped by each bidder's own escrow — no stake, no fill, and
///         un-staked escrow is not tick capacity either. Escrow that does not fill stays where it
///         is and competes again next round. Nobody has to open or close anything.
/// @dev The mechanism is `agent-docs/GenerousAuction.md`; the rule and its derivation are
///      `human-docs/generous-auction.md`. Read one of those before changing anything here.
///
///      The five things a reader needs before reaching `_sync`:
///
///      1. EMISSION IS A SCHEDULE, BLOCK-LINEAR. `emittedToDate()` is a closed form of the block
///         number, so a thousand silent rounds are one division and one sweep — not a thousand of
///         either. Accrual is per block (`emissionPerRound / roundBlocks` each), so no boundary
///         ever materialises a chunk atomically — weights are settled against the exact blocks
///         they stood for. What the book could not absorb stays owed in `due()` (carry).
///      2. ONE SWEEP, SOLVED NOT ITERATED — TWICE. `_solveBand` parameterises a band's pour by
///         a scalar `C`; tick `i` exhausts at `kappa_i = cap_i / w_i`. Sort by `kappa`, walk once
///         — and when the band's top runs dry, admit what the moving lower edge reaches and keep
///         walking (the band follows the top, so a lazy sweep lands where per-block syncs would).
///         `_pourTick` then runs the SAME shape inside the tick: weights are stakes, caps are
///         each position's escrow, the scalar is `Tick.acc`. Exhaustion order is not price (or
///         stake) order in either layer, which is why both sort and neither iterates to converge.
///      3. CLAIMS NEVER ITERATE. `Tick.acc` is an additive depletion index (tokens per unit of
///         stake, Q128); a position's consumption is `min(cap, stake * (acc - accAtEntry))` — one
///         closed form across unlimited rounds, and `min` prices its own death. The pour reads
///         ONLY the positions that die (heap head pops) and writes only the tick's aggregates —
///         seats are unlimited.
///      4. ROUNDING IS DOWN EVERYWHERE tokens flow out, UP where escrow is charged, and THE POT
///         BOOKS A LOWER BOUND. Allocations never exceed the supply they are drawn from, and the
///         pot's ledgers (`tokensBooked`, `tokensUnclaimed`, `currencyRaised`) record no more
///         than the positions can ever crystallise and be charged for — `_pourTick` holds back
///         one token-wei per extra seat — so the pack never pulls escrow that still belongs to
///         a live bidder. The pot is only ever AHEAD by dust (uncollectable token-wei that
///         `claim` clamps away, surplus currency-wei that stays here), never short.
///      5. THE SALE IS NOT PRE-FUNDED. `token` must be a `Mono` whose `index` is `currency`, and
///         this contract must be its owner. `claim` calls `Mono.mint`, which refuses any mint
///         that would lower NAV — so `submitBid` floors bids at `nav()` and `claim` clamps rather
///         than reverting. There is no `sweepCurrency`: escrow leaves only as a strike payment.
///         Stake is the same MONO the sale sells; `totalStaked` is held apart and can never pay a
///         claim or a pack.
///
///      ponytail: unbounded carry. A long dry spell hands the first bidder back a large backlog at
///      their own price; cap the per-sync draw if that turns out to be worth gaming.
///      ponytail: the per-pour booking reserve (`_pourTick`) is a worst-case bound — positions
///      that harvest rarely crystallise more than the per-pour floors, so over a long sale the
///      pot accumulates wei of currency nobody can withdraw and token-wei the last claimant
///      cannot collect. Both one-sided and bounded per pour; add a dust sweep to the vault at
///      finalize if it ever adds up to anything.
///      ponytail: a death-budget pause returns the paused tick's un-poured share to `due()`,
///      and each resumed pour re-splits the remainder by q-weight — across repeated pauses the
///      surviving top of the window compounds toward the whole remainder. Forcing a pause costs
///      a sybil position per death and the leak flows to the highest price payer; make the pour
///      remember per-window entitlements if that trade ever stops being acceptable.
///      ponytail: positions that exhaust exactly at a pour's stopping point stay seated with
///      `kappa == acc` until the next pour pops them for free — stale seats read correctly and
///      cost one no-op pop each, never a wrong number. (Any touch that harvests — a claim
///      included — re-seats and clears them early.)
contract GenerousAuction is IGenerousAuction, ReentrancyGuardTransient {
    using SafeTransferLib for address;

    uint256 internal constant WAD = 1e18;

    uint256 internal constant Q96 = 1 << 96;

    /// @notice Scale of `Tick.acc`: tokens per unit of stake, Q128 so dust stakes on long sales
    ///         still resolve to distinct consumption values.
    uint256 internal constant Q128 = 1 << 128;

    /// @notice Bids may not exceed this multiple of the floor price.
    /// @dev Keeps the tick list from being seeded at absurd prices, and stops a bid paying in full
    ///      for zero tokens.
    uint256 internal constant MAX_PRICE_MULTIPLE = 1e4;

    /// @notice Keeps `floorPrice * MAX_PRICE_MULTIPLE` far from overflowing.
    uint256 internal constant MAX_FLOOR_PRICE = type(uint128).max;

    /// @notice Floor on `tickSpacing`. Only rules out the degenerate grids (0 bricks the modulo,
    ///         1 is no grid at all).
    uint256 internal constant MIN_TICK_SPACING = 2;

    /// @notice Low bits of a `_solveInit` sort key, holding the tick's index within the window.
    /// @dev The key is `(kappa << IDX_BITS) | i`, so one sort orders the exhaustions and carries
    ///      the index with them. `MAX_WINDOW_TICKS` is what keeps `i` inside this field.
    uint256 internal constant IDX_BITS = 8;
    uint256 internal constant IDX_MASK = (1 << IDX_BITS) - 1;

    /// @notice Hard ceiling on `windowTicks`. Gas is the real limit long before this, but the
    ///         packing in `_solveInit` needs the index to fit in `IDX_BITS`.
    uint256 internal constant MAX_WINDOW_TICKS = 255;

    /// @notice Position deaths one SYNC processes before pausing — a global budget across every
    ///         tick the sweep pours, not per tick, so a window of half-dead ticks cannot multiply
    ///         it. Deaths are amortised — one per position per lifetime — but a huge backlog can
    ///         owe thousands at once; the pause keeps a single sync inside a sane gas envelope,
    ///         and the cursor resumes exactly where it stopped.
    uint256 internal constant MAX_DEATHS_PER_SYNC = 128;

    /// @notice Largest edge weight `q^windowTicks` a deployment may leave unserved.
    /// @dev The window truncates the curve, so the tick just past the edge loses a share of
    ///      `q^windowTicks / W`. Requiring that to be under 1% stops a deployment from silently
    ///      cutting the book in half — pick `q` and `windowTicks` together. Exempt when `q == ONE`,
    ///      where a flat split across exactly `windowTicks` levels is the intended reading.
    uint256 internal constant MAX_EDGE_WEIGHT = Q96 / 100;

    /// @notice Tick budget the implicit syncs inside `submitBid`/`withdrawBid`/`claim`/`stake`/
    ///         `unstake` run under.
    /// @dev Bounds how many WINDOWS and dead ticks such a sync walks, NOT the work inside one
    ///      window — `_gather` step 2 always collects its whole band, so a single window of up to
    ///      `windowTicks + 1` live ticks runs to completion whatever this is set to. So the real
    ///      ceiling on what one bidder pays for the backlog is `windowTicks` (times the per-tick
    ///      position scan), and that is a deployment choice. Running out of budget is not an
    ///      error — the sync saves `settleCursor` and the rest stays in `due()`.
    uint256 internal constant SYNC_TICKS = 128;

    // ---------------------------------------------------------------- immutable config

    /// @dev 18 decimals assumed on `currency` — the WAD fill math is not decimal-agnostic.
    address public immutable token;
    address public immutable currency;

    /// @dev The only privileged role, and it can do exactly one thing: re-schedule emission from a
    ///      future round boundary. It cannot touch the book, the escrow, the stakes, or anything
    ///      already owed.
    address public immutable admin;

    /// @notice First block that accrues emission, and the last. `endBlock == 0` is open-ended.
    /// @dev Accrual is block-linear, so a life not divisible by `roundBlocks` simply emits the
    ///      exact pro-rata tail up to `endBlock`.
    uint64 public immutable startBlock;
    uint64 public immutable endBlock;

    /// @dev `floorPrice` is the one tick initialised in the constructor.
    uint256 public immutable floorPrice;

    /// @dev Right `tickSpacing`: fine enough that rounding to a tick costs a bidder less than the
    ///      gas to bid, coarse enough that a live book is a few hundred ticks.
    uint256 public immutable tickSpacing;

    /// @dev Calibrate `decayQ` WITH `tickSpacing`, not separately: weights decay per grid step, so
    ///      on this arithmetic grid `q`'s reach is an absolute price band of
    ///      `windowTicks * tickSpacing`. A fine grid needs `q` near 1 for a sensible band, which
    ///      in turn softens the `(1 - q)` soft cap the top tick gets. Window width and top-cap
    ///      strength are one knob. Immutable because changing it would reprice every standing bid.
    uint256 public immutable decayQ;

    uint256 public immutable windowTicks;

    /// @notice The premium MONO had to be trading at for this sale to be deployed, in bips.
    ///         Kept on-chain so the bar a live sale cleared is readable, not just in the deploy tx.
    uint16 public immutable minPremiumBips;

    /// @notice The whole supply of this sale: the MONO it takes to close the premium that was
    ///         standing when it was deployed. Struck once, in the constructor, and never
    ///         recomputed — the sale sells a fixed quantity, not whatever the gap is today.
    uint256 public immutable saleSupply;

    // ---------------------------------------------------------------- state

    mapping(uint256 price => Tick) public ticks;

    /// @dev ONE bid per owner, whole book — which is also what makes the stake → tick attachment
    ///      unambiguous: the whole of `stakes[owner]` weighs at the one price the owner stands at.
    mapping(address owner => Position) public positions;

    /// @dev Each live tick's positions as a min-heap on `Position.kappa` (1-based; seat index
    ///      lives in `Position.heapIdx`). The pour pops only the positions that actually exhaust,
    ///      so a tick seats ANY number of bidders and settling costs O(deaths), not O(seats).
    mapping(uint256 price => mapping(uint256 idx => address)) internal heap;

    mapping(address owner => uint256) public stakes;
    uint256 public totalStaked;
    bool public finalized;

    uint256 public tokensUnclaimed;
    uint256 public currencyRaised;
    /// @dev `tokensSold` is what the schedule handed the book (supply pacing: `due()` and
    ///      `remaining()` read it). `tokensBooked` is the part of it the pot owes claimants —
    ///      `tokensSold` less the per-pour flooring reserve (`_pourTick`). Both cumulative.
    uint256 public tokensSold;
    uint256 public tokensBooked;
    /// @dev What `mintPack` has already packed. Both cumulative; the deltas against `tokensBooked`
    ///      and `currencyRaised` are exactly what the next pack mints.
    uint256 public tokensMinted;
    uint256 public currencyMinted;
    uint256 public highestTick;
    uint256 public settleCursor;

    /// @dev The emission schedule, as an anchor plus a rate. `anchorEmitted` is the cumulative
    ///      emission at `anchorBlock`, so a rate change never has to rewrite history: it only
    ///      re-anchors. One queued generation at a time, effective from `pendingFrom`.
    ///      The groups below are exactly one storage slot each — keep them that way.

    // slot: 64 + 128 + 64
    uint64 internal anchorBlock;
    uint128 internal anchorEmitted;
    uint64 public roundBlocks;

    // slot: 128 + 64 + 64
    uint128 public emissionPerRound;
    uint64 public pendingFrom; // 0 = nothing queued
    uint64 public pendingRoundBlocks;

    uint128 public pendingEmission;
    /// @dev Rounds completed at `anchorBlock`. The anchor moves whenever a queued generation is
    ///      folded in, and the round LENGTH moves with it, so the rounds before it cannot be
    ///      recovered by dividing — they are carried here, exactly as `anchorEmitted` carries the
    ///      emission. Shares `pendingEmission`'s slot.
    uint64 internal anchorRounds;

    constructor(Config memory c) {
        if (c.token == address(0) || c.currency == address(0)) revert InvalidParams();
        // Same asset on both sides would make the fill math circular.
        if (c.token == c.currency) revert InvalidParams();
        // The escrow token has to be the vault's backing asset, or `mint` would pull nothing.
        if (c.currency != address(IMono(c.token).index())) revert InvalidParams();
        if (c.admin == address(0)) revert InvalidParams();
        if (c.startBlock == 0 || c.roundBlocks == 0 || c.roundBlocks > type(uint32).max) revert InvalidParams();
        // On Arbitrum-style rollups `block.number` is the PARENT chain height. A start populated
        // from the rollup's own height sits decades in the parent future and bricks the schedule
        // (it killed this contract's first testnet deploy). A year of parent blocks of headroom
        // is enough for any deliberate delayed start.
        if (c.startBlock > block.number + 2_628_000) revert InvalidParams();
        // And never in the PAST: accrual is a closed form from `startBlock`, so a stale start
        // opens the sale with a backlog already in `due()` — a start 2.3 days stale under the
        // deploy script's schedule puts the WHOLE `saleSupply` in it, and the first bidder takes
        // the sale at the floor in the deploy block (round-7). Read the height, add headroom.
        if (c.startBlock < block.number) revert InvalidParams();
        if (c.endBlock != 0 && c.endBlock <= c.startBlock) revert InvalidParams();
        // A bounded life of one round or less can never reach a round boundary INSIDE the sale:
        // the earliest boundary `setRoundParams` can name is `startBlock + roundBlocks`, and the
        // `ScheduleFrozen` guard refuses a boundary at or past `endBlock`. So the admin's one
        // lever would be inert for the whole sale, and `admin` is immutable — the deploy would
        // have to be thrown away (round-14; equality used to pass this check).
        if (c.endBlock != 0 && c.endBlock - c.startBlock <= c.roundBlocks) revert InvalidParams();
        if (c.tickSpacing < MIN_TICK_SPACING) revert TickSpacingTooSmall();
        if (c.floorPrice == 0 || c.floorPrice > MAX_FLOOR_PRICE) revert InvalidParams();
        if (c.floorPrice % c.tickSpacing != 0) revert TickNotAligned();
        if (c.decayQ == 0 || c.decayQ > Q96) revert InvalidDecay();
        if (c.windowTicks == 0 || c.windowTicks > MAX_WINDOW_TICKS) revert InvalidWindow();
        // Refuse a pairing that would strand real demand just past the window edge. A flat book
        // (q == 1) is exempt: there the window IS the intended participation set.
        if (c.decayQ != Q96 && FixedPointMathLib.rpow(c.decayQ, c.windowTicks, Q96) > MAX_EDGE_WEIGHT) {
            revert WindowTooNarrow();
        }
        // The same check in PRICE terms: the window is an absolute band of
        // `windowTicks * tickSpacing`, and on a grid fine enough that the band is a negligible
        // fraction of the floor the q-curve collapses into strict price priority (an 18-wei
        // overbid took a whole round on a 2-wei grid, round-7). One percent of the floor is the
        // least a band can span and still be a curve; the deploy script's pairing gives 8%.
        if (c.windowTicks * c.tickSpacing < c.floorPrice / 100) revert WindowTooNarrow();

        // Close the outgoing sale BEFORE reading the premium: its pack moves NAV and the pool
        // gap, and this sale's gate and size must be struck against the post-handoff market,
        // not a stale one. It must still hold MINTER_ROLE here — deploy this, THEN grant to
        // this one and revoke from it.
        if (c.previousAuction != address(0)) IGenerousAuction(c.previousAuction).mintPack();

        // The harvest only makes sense into a premium: it mints MONO against escrow at NAV and the
        // market pays above it. With MONO at or under book there is no spread to harvest, and the
        // sale is just supply. Requires `Mono.setPool` to have run — deploy order is Mono, pool,
        // setPool, then this. Reverts `PoolNotSet` otherwise.
        //
        // ponytail: checked ONCE, here, against a SPOT `slot0` read. It stops a sale being opened
        // into a flat market; it does not keep one honest afterwards, and a deployer who controls
        // the pool can push it for one block. Move this to `submitBid` once the v4 TWAP hook lands
        // (HANDBOOK 3.6) — gating every bid on a spot price today just hands anyone a cheap DoS.
        if (IMono(c.token).premiumBips() < int256(uint256(c.minPremiumBips))) revert PremiumTooLow();

        // The premium, restated as supply: how much MONO sold into the pool would carry its price
        // back down to NAV. That is exactly what this sale exists to sell, so it is the sale's
        // whole size — the emission schedule paces it out, and `due()` stops at it.
        saleSupply = IMono(c.token).premiumCloseAmount();
        // A premium the pool has no liquidity to absorb is not a sale.
        if (saleSupply == 0) revert NothingToSell();
        // No price in `[floorPrice, floorPrice * MAX_PRICE_MULTIPLE]` may sit under NAV, or the
        // sale accepts deploys nobody can bid into (`submitBid` floors every bid at `nav()`).
        // `floorPrice >= nav()` itself is deliberately NOT required: a successor deployed with the
        // same floor constant against a risen NAV is legitimate — its live floor is NAV.
        if (c.floorPrice * MAX_PRICE_MULTIPLE < IMono(c.token).nav()) revert BelowNav();
        // A rate above the sale's whole size is economically `saleSupply` (`due()` clamps there)
        // but overflows the uint128 fold in `setRoundParams` after one queued change lands and
        // bricks the admin's only lever for good. Zero is legal: a dormant deploy started later.
        if (c.emissionPerRound > saleSupply) revert InvalidParams();

        token = c.token;
        currency = c.currency;
        admin = c.admin;
        floorPrice = c.floorPrice;
        tickSpacing = c.tickSpacing;
        decayQ = c.decayQ;
        windowTicks = c.windowTicks;
        minPremiumBips = c.minPremiumBips;
        startBlock = c.startBlock;
        endBlock = c.endBlock;
        highestTick = c.floorPrice;

        anchorBlock = c.startBlock;
        roundBlocks = c.roundBlocks;
        emissionPerRound = c.emissionPerRound;

        // One approval for the life of the sale. `Mono` only ever pulls the amount its caller —
        // this contract, in `claim` — passes it, so an unbounded allowance grants it nothing extra.
        c.currency.safeApprove(c.token, type(uint256).max);

        ticks[c.floorPrice].init = true;
    }

    // ---------------------------------------------------------------- emission schedule

    /// @notice Cumulative tokens this sale has released as of now (block-linear), capped at
    ///         `saleSupply` — the schedule paces the sale, the premium sizes it, and whichever
    ///         binds first wins.
    /// @dev The cap is not cosmetic: `setRoundParams`'s fold clamps the stored anchor at
    ///      `saleSupply`, so an unclamped read would fall by the overshoot the moment an admin
    ///      call folded a spent generation in, and an indexer charting it against `roundsElapsed`
    ///      would see cumulative emission go backwards (round-14). Clamping here makes this,
    ///      `due()` and `remaining()` three readings of one number.
    function emittedToDate() public view returns (uint256) {
        uint256 t = _emittedAt(block.number);
        uint256 cap = saleSupply;
        return t > cap ? cap : t;
    }

    /// @notice What a `sync` right now would distribute.
    /// @dev The gap between the schedule and what has actually been sold — so a round the book
    ///      could not absorb stays owed here rather than being burned. Capped at `saleSupply`:
    ///      the schedule paces the sale, the premium sizes it, and whichever binds first wins.
    ///      Once the schedule passes `saleSupply` this returns 0 forever and the sale is over.
    function due() public view returns (uint256) {
        // A finalized sale is OVER: whatever carry the dead book never absorbed is not owed to
        // anyone, and a post-finalize re-stake must not vacuum it at post-unlock weights.
        if (finalized) return 0;
        uint256 sold = tokensSold;
        uint256 target = _emittedAt(block.number);
        uint256 cap = saleSupply;
        if (target > cap) target = cap;
        return target <= sold ? 0 : target - sold;
    }

    /// @notice MONO of this sale still available. Hits 0 when the premium that sized it is spent
    ///         — or when the sale is finalized, which ends it whatever is left unsold.
    /// @dev A sale that finalizes on the "a complete sweep sold nothing" path can end with most
    ///      of `saleSupply` never sold; reporting that as still available (as this used to) reads
    ///      as an open sale to anyone sizing a successor (round-14). `due()` already returns 0
    ///      once finalized.
    function remaining() public view returns (uint256) {
        if (finalized) return 0;
        uint256 sold = tokensSold;
        return sold >= saleSupply ? 0 : saleSupply - sold;
    }

    /// @notice Emission rounds completed since `startBlock`.
    /// @dev Counts under the schedule that ACTUALLY ran, not under whatever length happens to be
    ///      stored now: rounds before the current anchor are carried in `anchorRounds`, and a
    ///      queued generation that has already taken effect is applied here rather than waiting
    ///      for the next `setRoundParams` to fold it. Dividing the whole span by the current
    ///      `roundBlocks` (as this used to) both over-counted across a length change and made the
    ///      reading jump when an admin queued something — in the same block, with no round
    ///      boundary crossed (round-11).
    function roundsElapsed() external view returns (uint256) {
        uint256 t = _scheduleBlock(block.number);
        uint256 anchor = anchorBlock;
        uint256 done = anchorRounds;
        if (t <= anchor) return done;

        uint64 from = pendingFrom;
        // A boundary is always a whole number of rounds above the anchor it was measured from,
        // so the first term is exact.
        if (from != 0 && t >= from) {
            return done + (uint256(from) - anchor) / roundBlocks + (t - from) / pendingRoundBlocks;
        }
        return done + (t - anchor) / roundBlocks;
    }

    /// @dev Cumulative emission at `blockNo`. Closed form, so a thousand silent rounds are one
    ///      division rather than a thousand iterations, and reading it costs nothing.
    function _emittedAt(uint256 blockNo) internal view returns (uint256) {
        uint256 t = _scheduleBlock(blockNo);
        uint64 anchor = anchorBlock;
        if (t <= anchor) return anchorEmitted;

        uint64 from = pendingFrom;
        // A queued generation only bites past its boundary, and everything before it stays priced
        // at the old rate — which is what makes `setRoundParams` non-retroactive even when nobody
        // synced in between.
        if (from != 0 && t >= from) {
            return _accrue(anchorEmitted, anchor, roundBlocks, emissionPerRound, from) + ((t - from) * pendingEmission)
                / pendingRoundBlocks;
        }
        return _accrue(anchorEmitted, anchor, roundBlocks, emissionPerRound, t);
    }

    /// @dev Clamp to the auction's life. Past `endBlock` the schedule is frozen, not reversed.
    function _scheduleBlock(uint256 blockNo) internal view returns (uint256) {
        uint64 end = endBlock;
        return (end != 0 && blockNo > end) ? end : blockNo;
    }

    /// @dev Cumulative emission at `until`: `base` plus BLOCK-LINEAR accrual at `perRound` every
    ///      `blocksPerRound` blocks. Linear, not floored to whole rounds: a round boundary used
    ///      to materialise a whole chunk atomically, which made the first post-boundary sync a
    ///      SNAPSHOT of weights — one block of doubled stake before the boundary captured a whole
    ///      round's inflated share (round-4 review, PoC'd). With per-block accrual a weight
    ///      change is settled against exactly the blocks it stood for; "rounds" remain the pacing
    ///      unit of the schedule, not an allocation unit.
    function _accrue(uint256 base, uint256 from, uint256 blocksPerRound, uint256 perRound, uint256 until)
        internal
        pure
        returns (uint256)
    {
        return base + ((until - from) * perRound) / blocksPerRound;
    }

    /// @notice Queue a new emission schedule, effective from the next round boundary.
    /// @dev No sync needed first: `_emittedAt` is exact for every past block regardless of what is
    ///      queued, so rounds already elapsed keep their old rate whether or not anyone settled
    ///      them. A second call before the boundary simply replaces the first.
    function setRoundParams(uint64 roundBlocks_, uint128 emissionPerRound_) external override {
        if (msg.sender != admin) revert Unauthorized();
        // Bounded so the boundary arithmetic below can never wrap uint64 (a wrapped `next`
        // would park `pendingFrom` in the past and permanently freeze the schedule).
        if (roundBlocks_ == 0 || roundBlocks_ > type(uint32).max) revert InvalidParams();
        if (emissionPerRound_ > saleSupply) revert InvalidParams(); // see the constructor

        // A queued generation that has already taken effect becomes the anchor, so the boundary
        // below is measured under the rate actually running.
        uint64 from = pendingFrom;
        if (from != 0 && block.number >= from) {
            // Clamp the fold to the sale's life: a pending boundary past `endBlock` must not
            // materialise emission the frozen schedule would never have released. And to the
            // sale's size: past `saleSupply` the schedule is spent, and the figure only has to
            // fit the anchor.
            uint256 tf = _scheduleBlock(from);
            uint256 folded = _accrue(anchorEmitted, anchorBlock, roundBlocks, emissionPerRound, tf);
            if (folded > saleSupply) folded = saleSupply;
            if (folded > type(uint128).max) revert InvalidParams();
            // Carry the rounds over with the emission: the length is about to change, so the
            // span before the new anchor can never be recovered by dividing again.
            anchorRounds += uint64((tf - anchorBlock) / roundBlocks);
            anchorEmitted = uint128(folded);
            anchorBlock = uint64(tf);
            roundBlocks = pendingRoundBlocks;
            emissionPerRound = pendingEmission;
        }

        // Strictly the next boundary: the round in flight finishes at the rate it started under.
        uint256 t = _scheduleBlock(block.number);
        uint64 anchor = anchorBlock;
        uint256 elapsed = t > anchor ? (t - anchor) / roundBlocks : 0;
        uint256 boundary = uint256(anchor) + (elapsed + 1) * uint256(roundBlocks);
        if (boundary > type(uint64).max) revert InvalidParams();
        // A boundary at or past `endBlock` never arrives: the schedule is frozen there, and a
        // generation queued for it would only ever emit an event that means nothing. Say so
        // instead of queueing it (the fold above then also never sees a boundary past the end).
        uint64 end = endBlock;
        if (end != 0 && boundary >= end) revert ScheduleFrozen();
        uint64 next = uint64(boundary);

        pendingFrom = next;
        pendingRoundBlocks = roundBlocks_;
        pendingEmission = emissionPerRound_;

        emit RoundParamsQueued(next, roundBlocks_, emissionPerRound_);
    }

    // ---------------------------------------------------------------- staking

    /// @inheritdoc IGenerousAuction
    /// @dev Settles the book, harvests the caller's position at the OLD stake, then applies the
    ///      new one — so a stake weighs exactly the rounds it stood for, nothing retroactive.
    ///      The rounds already settled are untouchable by construction; that is also why the
    ///      lock below only needs to cover the lazy tail after `endBlock`.
    function stake(uint256 amount) external override nonReentrant {
        if (amount == 0) revert InvalidParams();
        _requireStakeOpen();
        _sync(SYNC_TICKS);
        // A stake with no standing bid moves no weight — only a seated position re-weighs.
        if (positions[msg.sender].price != 0) _requireSettled();

        (Position storage p, uint256 live) = _harvest(msg.sender);
        uint256 sOld = stakes[msg.sender];
        uint256 sNew = sOld + amount;
        live; // the reseat below reads the harvested position directly
        _reseat(msg.sender, p, sOld, sNew);

        stakes[msg.sender] = sNew;
        totalStaked += amount;
        token.safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount);
    }

    /// @inheritdoc IGenerousAuction
    /// @dev Unstaking to zero with a live bid is legal and leaves the bid inert: `_harvest` has
    ///      already crystallised everything the old stake earned, the escrow leaves the tick's
    ///      capacity, and the consumption formula reads 0 from then on. Re-staking re-anchors.
    function unstake(uint256 amount) external override nonReentrant {
        if (amount == 0) revert InvalidParams();
        _requireStakeOpen();
        uint256 sOld = stakes[msg.sender];
        if (amount > sOld) revert InsufficientStake();
        _sync(SYNC_TICKS);
        if (positions[msg.sender].price != 0) _requireSettled();

        (Position storage p, uint256 live) = _harvest(msg.sender);
        uint256 sNew = sOld - amount;
        live; // the reseat below reads the harvested position directly
        _reseat(msg.sender, p, sOld, sNew);

        stakes[msg.sender] = sNew;
        totalStaked -= amount;
        token.safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount);
    }

    /// @inheritdoc IGenerousAuction
    /// @dev The lock exists for correctness, not ceremony: the lazy sync may settle pre-`endBlock`
    ///      rounds AFTER `endBlock`, reading weights from current stakes — moving stake in that
    ///      window would reprice rounds that already happened. Once everything owed is distributed
    ///      (or provably never will be), the weights have no more work to do and the lock lifts.
    function finalize(uint256 maxTicks) external override nonReentrant returns (bool done) {
        uint64 end = endBlock;
        if (end == 0 || block.number < end || finalized) revert NotFinalizable();

        uint256 sold = _sync(maxTicks);
        // Done when nothing is owed — or when a COMPLETE sweep (cursor back at top) sold nothing:
        // bids and stakes are both frozen past `endBlock`, so a book that cannot absorb the carry
        // now never will, and holding stakes hostage to it serves nobody. A call that is neither
        // returns false WITHOUT reverting — a revert would roll back the very progress the sync
        // just made, and the tail would never drain. Call again.
        if (due() == 0 || (sold == 0 && settleCursor == 0)) {
            finalized = true;
            emit Finalized();
            // PACK on the way out. "Finalized" used to mean "drained", and the succession runbook
            // revoked the predecessor's minter role on that signal — but `finalize` sells the
            // frozen tail and the successor's constructor packed only what was sold BEFORE it,
            // so a sale ended to the letter of the runbook was left with fills nobody could mint
            // and every claim on it reverted (round-6). Packing here makes "finalized" mean
            // "nothing left to pack". Best-effort ONLY against a revoked role: that must not
            // keep the stake lock closed — the lock lifts regardless, and `mintPack` can run
            // later once the role is back. Anything else (an out-of-gas inside the self-call —
            // a bare catch swallowed it and `finalize` returned true with nothing packed on a
            // 64k-gas band of stipends, round-8) propagates: a finalize that could not pack is
            // not finalized.
            try this.mintPack() {}
            catch (bytes memory reason) {
                if (bytes4(reason) != IAccessControl.AccessControlUnauthorizedAccount.selector) {
                    assembly {
                        revert(add(reason, 0x20), mload(reason))
                    }
                }
            }
            return true;
        }
    }

    /// @dev Stakes move freely during the sale and after finalization; only the settlement tail
    ///      between the two is locked.
    function _requireStakeOpen() internal view {
        if (!_stakeOpen()) revert StakeLocked();
    }

    function _stakeOpen() internal view returns (bool) {
        return endBlock == 0 || block.number < endBlock || finalized;
    }

    /// @dev A weight change is only honest against a SETTLED book. Every mutating entry point
    ///      syncs first, but that sync is budget-bounded — a truncated sweep leaves accrued
    ///      backlog un-poured, and ANY new weight would compete for emission others stood
    ///      behind: below the cursor by joining the pour directly (round-2 PoC turned an honest
    ///      25/25 into 49.7/0.05), and ABOVE it by becoming the new top so the next sweep opens
    ///      on the newcomer and never reaches the standing book (round-3 critical PoC: a
    ///      latecomer above a dead-tick wall took a floor bidder's entire 400e18 backlog). So
    ///      the guard is price-INDEPENDENT: mid-sweep with something owed, no weight moves at
    ///      all. The remedy is a real `sync`; wall-shaving (see `_sync`) makes that a one-time,
    ///      bounded cost however deep the spam.
    function _settled() internal view returns (bool) {
        return settleCursor == 0 || due() == 0;
    }

    function _requireSettled() internal view {
        if (!_settled()) revert SettleFirst();
    }

    /// @dev Bring `owner`'s seat in line with its current `(amount, stake)` after a harvest has
    ///      re-anchored the position. Handles every transition — join, leave, re-key, top-up — as
    ///      an unseat (contribution unwound with the OLD stake that built `kappa`) followed by a
    ///      fresh seat when the position is countable: stake > 0 and escrow that still buys at
    ///      least a wei of token. Everything else — no stake, dust — is inert: not capacity, not
    ///      weight, not in the heap. The strict rule lives here.
    function _reseat(address owner, Position storage p, uint256 sOld, uint256 sNew) internal {
        uint256 price = p.price;
        if (price == 0) return;
        Tick storage t = ticks[price];
        uint256 acc = t.acc;

        if (p.heapIdx != 0) {
            uint256 k = p.kappa;
            uint256 capOld = k > acc ? _tokensFor(sOld, k - acc) : 0;
            uint256 ct = t.capTokens;
            t.capTokens = ct > capOld ? ct - capOld : 0;
            t.stakeSum -= sOld;
            _heapRemove(price, t, p);
            // No stake left behind the tick: whatever capacity dust the floor-unwind left is
            // phantom — zero it so an empty tick cannot anchor a window or hold `tau`.
            if (t.stakeSum == 0) t.capTokens = 0;
        }

        uint256 amount = p.amount; // post-harvest, anchored at `acc`
        if (sNew == 0 || amount == 0) return;
        uint256 cap = FixedPointMathLib.fullMulDiv(amount, WAD, price);
        if (cap == 0) return;
        // The tick may have been unlinked while this position sat here inert (escrow, no stake:
        // not capacity, so the tick read dead and a sweep spliced it out). Seating capacity in
        // an unlinked tick would put it out of every sweep's reach, so re-link it first — the
        // one place a hint is not available, hence the walk (see `_initializeTick` for what it
        // costs). Rare: it needs an owner who un-staked to zero and later re-stakes, and
        // `withdrawBid` returns the escrow without going through here.
        if (!_linked(price)) _relink(price);
        p.kappa = _kappa(acc, cap, sNew);
        t.capTokens += cap;
        t.stakeSum += sNew;
        _heapInsert(price, t, p, owner);
        // Revived capacity must be REACHABLE: a sweep that saw this tick empty may have dropped
        // `highestTick` below it. (No cursor to worry about — the SettleFirst guard means no
        // seat ever happens while a truncated sweep is pending.)
        if (price > highestTick) highestTick = price;
    }

    // ---------------------------------------------------------------- bidding

    /// @inheritdoc IGenerousAuction
    /// @dev ONE bid per owner. Same price tops the position up (harvesting first — the index pair
    ///      is only meaningful for one amount); a different price with live escrow reverts, and
    ///      with nothing live re-binds the position there. `prevTick` is ignored when `price` is
    ///      already initialized.
    function submitBid(uint256 price, uint128 amount, address owner, uint256 prevTick) external override nonReentrant {
        if (endBlock != 0 && block.number >= endBlock) revert AuctionEnded();
        if (amount == 0 || owner == address(0)) revert InvalidParams();
        // Only the owner may create, top up or move a bid, including after a withdrawal.
        // Check before syncing or pulling currency: a third party must never use another stake.
        if (owner != msg.sender) revert Unauthorized();
        if (price < floorPrice) revert BidTooLow();
        if (price > floorPrice * MAX_PRICE_MULTIPLE) revert BidTooHigh();
        if (price % tickSpacing != 0) revert TickNotAligned();
        // Must buy at least 1 wei of token, else the bid pays in full for nothing.
        if (uint256(amount) * WAD < price) revert BidTooSmall();
        // No mint below backing (HANDBOOK §3.1). `floorPrice` is immutable and NAV only rises, so
        // the live floor is NAV, not the constructor's — this is what keeps `claim` from clamping.
        if (price < IMono(token).nav()) revert BelowNav();
        // The strict rule, at the door: escrow without stake would buy nothing and count for
        // nothing, so it does not enter.
        uint256 s = stakes[owner];
        if (s == 0) revert NoStake();

        // Fast-fail while a truncated sweep is KNOWN pending: the full check runs again after
        // the sync below, but failing here costs hundreds of gas instead of a rolled-back pour.
        _requireSettled();
        // Settle what the old book already earned BEFORE this bid joins it. Without this a bidder
        // could arrive after a long silence and take a share of emission that accrued while they
        // were not in the book at all.
        _sync(SYNC_TICKS);
        _requireSettled();

        currency.safeTransferFrom(msg.sender, address(this), amount);

        // Harvest before resizing: `(amount, accAtEntry)` is only meaningful for one amount.
        (Position storage p, uint256 live) = _harvest(owner);
        uint256 oldPrice = p.price;
        // Moving with live escrow is withdraw-then-bid, one decision at a time.
        if (oldPrice != 0 && oldPrice != price && live != 0) revert BidExists();
        // Unseat wherever the position currently sits (still keyed by its old price), then
        // re-bind and seat fresh — two `_reseat` calls cover every transition without cases.
        _reseat(owner, p, s, 0);

        _initializeTick(prevTick, price);
        if (price > highestTick) highestTick = price;
        if (oldPrice != price) {
            p.price = price;
            p.accAtEntry = ticks[price].acc;
        }

        uint256 newAmount = live + amount;
        if (newAmount > type(uint128).max) revert InvalidParams();
        p.amount = uint128(newAmount);
        _reseat(owner, p, 0, s);

        emit BidSubmitted(owner, price, amount);
    }

    /// @inheritdoc IGenerousAuction
    /// @dev ponytail: a free cancel option outside settlement. That is the price of never trapping
    ///      escrow — an offer that never clears must always have an exit. Charge a cancel fee here
    ///      if the option turns out to be worth gaming.
    function withdrawBid() external override nonReentrant returns (uint256 live) {
        // Pay for the emission this escrow was standing behind before taking it out.
        _sync(SYNC_TICKS);
        // The lock window freezes WEIGHTS, and a withdrawal moves them too: with pre-`endBlock`
        // rounds still undrained, pulling escrow out would reprice the frozen backlog onto the
        // remaining stakers. Once the tail is drained (or the book provably dead — `finalize`)
        // the withdrawal is free.
        if (!_stakeOpen() && due() != 0) revert StakeLocked();
        _requireSettled();

        Position storage p;
        (p, live) = _harvest(msg.sender);
        if (live == 0) revert NoPosition();

        uint256 price = p.price;
        _reseat(msg.sender, p, stakes[msg.sender], 0);
        p.amount = 0;
        p.price = 0;

        currency.safeTransfer(msg.sender, live);

        emit BidWithdrawn(msg.sender, price, live);
    }

    // ---------------------------------------------------------------- sync

    /// @notice Distribute everything the schedule has released and the book has not yet absorbed.
    /// @dev Permissionless and always callable — it only ever moves the book to where the schedule
    ///      already says it should be, so who calls it and when decides nothing but who pays the
    ///      gas.
    function sync(uint256 maxTicks) external override nonReentrant {
        _sync(maxTicks);
    }

    /// @dev Processes one window at a time from the top of book down. Each window is solved exactly
    ///      and in full — a window is never left half-poured, because a partial `W` would misprice
    ///      every tick in it. `maxTicks` therefore budgets *list nodes visited*, not work inside a
    ///      window; a truncated sweep saves `settleCursor` and leaves the rest in `due()`.
    ///
    ///      A later window only ever runs once every tick above it is dry, so resuming from the
    ///      cursor is the same computation as never having stopped: the new top of book is exactly
    ///      where the previous window ended.
    ///
    ///      The whole backlog goes in as ONE supply figure rather than round by round. That is not
    ///      an approximation: `_pour` is parameterised by the scalar `C`, relative weights inside
    ///      a band are anchor-independent, and the moment a band's top runs dry the sweep gathers
    ///      a fresh band from the new top before pouring on (`_pour`'s early break) — so `N*R` in
    ///      one sweep lands where `N` sweeps of `R` would, band membership included.
    /// @return sold Tokens actually distributed by this call.
    function _sync(uint256 maxTicks) internal returns (uint256 sold) {
        if (finalized) return 0; // the sale is over; see `due()`
        // A sync may PARK the cursor (and with it lock every weight change behind `SettleFirst`)
        // only after at least `SYNC_TICKS` of real work: `sync(0)` used to park it for ~30k gas
        // with the loop never entered, and `submitBid`'s fast-fail then rejected every bid in
        // the block (round-6). With the floor, parking needs a book deeper than what one
        // implicit sync clears — which, since a sweep unlinks every dead run it walks, means
        // that many ticks on the sweep's own path, most of them funded, staked bids.
        if (maxTicks < SYNC_TICKS) maxTicks = SYNC_TICKS;
        // Inlined `due()` so the schedule is read once rather than again for the event. The
        // `saleSupply` clamp mirrors `due()` exactly — without it a long schedule would keep
        // selling past the size the premium set.
        uint256 emitted = _emittedAt(block.number);
        uint256 cap = saleSupply;
        if (emitted > cap) emitted = cap;
        uint256 alreadySold = tokensSold;
        if (emitted <= alreadySold) return 0;
        uint256 supply = emitted - alreadySold;

        uint256 price = settleCursor;
        if (price == 0) price = highestTick;

        uint256 steps;
        uint256 deathsLeft = MAX_DEATHS_PER_SYNC;
        bool drained;
        while (price != 0 && supply > 0 && steps < maxTicks) {
            Window memory w = _gather(price, maxTicks - steps);
            steps += w.steps;
            // What is left of the budget goes in through `w.steps`; the pour hands back the
            // nodes its band moves walked in the same field.
            w.steps = steps < maxTicks ? maxTicks - steps : 0;
            if (w.n == 0) {
                // Either the list ran out below `price`, or the budget did while skipping dead
                // ticks. Both are "stop here"; `w.resume` is 0 in the first case and the cursor to
                // resume from in the second, which is exactly what `settleCursor` wants below.
                // SHAVE THE WALL on the way out: every node this walk visited above `w.resume` is
                // dead, and on a resumed sweep everything above the old cursor already was — so
                // the high-water drops to the resume point PERMANENTLY. An abandoned spam ridge
                // is paid for once across all syncs, never re-walked (round-3 lockout finding).
                if (w.resume != 0) {
                    uint256 keptAbove = _splice(price, w.resume);
                    uint256 shave = keptAbove != 0 ? keptAbove : w.resume;
                    if (shave < highestTick) highestTick = shave;
                }
                price = w.resume;
                break;
            }
            // Drop the high-water mark onto this window's top — same shaving argument: the walk
            // proved everything above `w.tau` dead or already-dry.
            if (w.tau < highestTick) highestTick = w.tau;
            uint256 poured;
            uint256 pausedAt;
            (poured, drained, pausedAt, deathsLeft) = _pourWindow(w, supply, deathsLeft);
            steps += w.steps;
            supply -= poured;
            sold += poured;
            // ONE splice per window, AFTER the pour. Splicing before the pour as well used to
            // leave the second call starting from a `prev` the first one's dead-ex-top drop had
            // already zeroed, so the ticks that died in the pour kept their pointers —
            // half-linked, `_linked` true, the exact orphan the unlinking splice exists to
            // prevent (round-8, found by four lenses).
            //
            // HOW FAR DOWN the run is dead depends on why the pour stopped, and the difference
            // is the whole band:
            //   - the supply ran out (`drained`) — survivors stand inside the band, so only the
            //     run above `w.tau`, the highest of them, is dead;
            //   - a budget ran out (`pausedAt`) — `_pourWindow` restored `w.tau` to the band's
            //     original top and ticks below the pause point were never poured, so again only
            //     the run above it is dead;
            //   - otherwise the band ran DRY: every tick from the walk's start down to (not
            //     including) `w.resume` is dead, `w.tau` — the last top the band moved to —
            //     included.
            // Unlinking only down to `w.tau` in that last case left each swept window's whole
            // dead band linked forever: the next window starts at `w.resume`, below it, so no
            // later splice ever covers the stretch, while the high-water shave keeps every later
            // sweep from walking it again. The `next` chain that `_predecessor`, `_relink` and
            // every UI walk then retained one node per price the sale ever touched — 78 of them
            // from 160 bids, permanently (round-9). Shave and splice to whichever bound the stop
            // reason justifies; `w.resume == 0` (the band reached the bottom of the book) has no
            // node to splice to, so it keeps the conservative one.
            uint256 mark = (drained || pausedAt != 0 || w.resume == 0) ? w.tau : w.resume;
            // Splice FIRST: it reports the highest tick in the run that still had capacity, and
            // the high-water must not drop below that one. `mark` is what the pour concluded,
            // and the pour's notion of "dead" is the model's — a tick keyed at `min(cap, supply)`
            // can end the walk with real capacity left (round-14), in which case `mark` is too
            // low and only storage knows it.
            uint256 kept = _splice(price, mark);
            if (kept != 0) mark = kept;
            if (mark < highestTick) highestTick = mark;
            if (pausedAt != 0) {
                // A budget ran out — deaths mid-tick, or list nodes mid-band-move. Park the
                // cursor on the band's ORIGINAL top (`_pourWindow` restored `w.tau`), not on the
                // paused tick: ticks above the pause point may have survived their pour with
                // capacity, and a cursor below them would starve them ("above the cursor is
                // dry" must stay true). Every partial advance is exact; the rest stays owed.
                settleCursor = w.tau;
                tokensSold += sold;
                emit Synced(emitted, sold, supply);
                return sold;
            }
            // The supply ran out inside this window, so no tick below it can be reached. Stopping
            // here matters: per-tick flooring leaves a few wei behind, and without this the walk
            // would chase that dust down the entire book — the exact unbounded traversal the
            // high → low fill avoided by zeroing `remaining` on its marginal tick.
            if (drained) break;
            price = w.resume;
        }

        // 0 means "start from the top next time". Anything else is a genuinely truncated sweep,
        // where the ticks above the cursor are known dry and only the budget ran out.
        settleCursor = (drained || supply == 0 || price == 0) ? 0 : price;
        // Cumulative, and only ever credited with what was actually distributed. Whatever the book
        // could not take stays in `due()` — that is the carry.
        tokensSold += sold;

        emit Synced(emitted, sold, supply);
    }

    /// @dev Cut the (walked, all-dead) run strictly between `hi` and `lo` out of the tick list.
    ///      Both endpoints stay linked. Every interior node is UNLINKED (`prev = next = 0`), not
    ///      merely bypassed: a bypassed node keeps pointers into the run, and its neighbours in
    ///      the run keep pointing back at it, so the one-sided "still linked" test in
    ///      `_initializeTick` read it as live. A bid there was then seated without ever being
    ///      re-linked (orphaned from the sweep), and a second splice onto the same `lo` could
    ///      leave a node whose only acceptable hint pointed at itself — `ticks[p].prev = p`, an
    ///      infinite `_gather` walk, every entry point reverting (round-7 critical, reached by
    ///      honest re-bids alone). Clearing costs two zeroing stores per node on a walk the
    ///      gather already paid for, once per node for the life of the sale: the node's `init`
    ///      and `acc` survive (harvests of positions that died there still read correctly), and
    ///      a bid at that price re-inserts it through the checked hint path like any new tick.
    /// @return live The highest node in the run that still had capacity and was therefore KEPT,
    ///         or 0 when the whole run was dead. The caller must not shave the high-water below
    ///         it.
    function _splice(uint256 hi, uint256 lo) internal returns (uint256 live) {
        if (hi == lo || hi == 0 || lo == 0) return 0;
        uint256 p = ticks[hi].prev;
        uint256 last; // lowest kept node so far
        while (p != lo && p != 0) {
            Tick storage t = ticks[p];
            uint256 below = t.prev;
            // NEVER unlink a tick that still has capacity. The caller picks the run's lower bound
            // from what the pour reported, and that has been wrong: a tick whose capacity outran
            // the reachable supply is "dead in the model" (keyed at `min(cap, supply)`) yet holds
            // real capacity, and per-segment flooring can let the sorted walk reach its key
            // without latching `drained` — so the bound landed BELOW a funded top-of-book bid and
            // this loop unlinked it (round-14). Storage is authoritative here: `_pourTick` has
            // already written every tick's remaining `capTokens` by the time this runs. Live
            // nodes are chained to each other and re-attached to both endpoints below.
            if (t.capTokens == 0) {
                t.prev = 0;
                t.next = 0;
            } else if (live == 0) {
                live = p; // walking down, so the first one found is the highest
                last = p;
            } else {
                ticks[last].prev = p;
                t.next = last;
                last = p;
            }
            p = below;
        }
        Tick storage h = ticks[hi];
        // A dead `hi` with nothing above it is the old top of book: drop it too, in O(1), so a
        // top that died OUT of band (a withdrawal or an unstake before the sync) does not stay
        // linked above `highestTick`, where no sweep would walk it again but every hint lookup
        // from the floor would. A dead `hi` with live ticks above it stays as the run's endpoint
        // until the sweep that next walks down through it unlinks the whole run, budgeted.
        bool drop = h.next == 0 && h.capTokens == 0;
        if (drop) h.prev = 0;

        if (live == 0) {
            if (drop) {
                ticks[lo].next = 0;
            } else {
                h.prev = lo;
                ticks[lo].next = hi;
            }
            return 0;
        }
        // The kept chain hangs off `lo`, with `hi` (if it survives) back on top of it.
        ticks[last].prev = lo;
        ticks[lo].next = last;
        if (drop) {
            ticks[live].next = 0;
        } else {
            ticks[live].next = hi;
            h.prev = live;
        }
    }

    /// @dev Put an initialised-but-unlinked tick back into the list at its exact place. Only ever
    ///      needed by `_reseat`; no hint there, so `_initializeTick` walks.
    function _relink(uint256 price) internal {
        _initializeTick(0, price);
    }

    /// @dev True when `price` is a node of the live list: the floor (its bottom), or a tick whose
    ///      lower neighbour points back at it. Unlinked ticks have `prev == 0`, and `ticks[0]`
    ///      points at nothing, so they fail. Sound because `_splice` leaves no stale pointers.
    function _linked(uint256 price) internal view returns (bool) {
        return price == floorPrice || ticks[ticks[price].prev].next == price;
    }

    /// @dev Collect the live ticks of the next window, walking down from `start`.
    /// @param budget List nodes the skip walk in step 1 may visit before giving up — whatever is
    ///        left of the caller's `maxTicks`. It guards that walk and nothing else, because that
    ///        walk is the only stretch here with no structural limit: dead ticks are unlinked only
    ///        once a sweep has walked them, so a fresh ridge can sit above the first live tick. Step 2 is
    ///        bounded by `windowTicks` instead and always runs to completion — a half-collected band
    ///        would misprice every tick in it — so `w.steps` reports what was actually visited and
    ///        can exceed `budget` by up to `windowTicks + 1`. Running out is not an error: `w.n`
    ///        comes back 0 and `w.resume` marks where to pick up.
    function _gather(uint256 start, uint256 budget) internal view returns (Window memory w) {
        // 1. Find the top of book. This is the only unbounded stretch — an untouched high-water
        //    `highestTick` can sit far above any live tick — so it is the part the budget guards.
        uint256 price = start;
        while (price != 0 && ticks[price].capTokens == 0) {
            if (w.steps >= budget) {
                w.resume = price; // budget out: `w.n` stays 0, resume from here next time
                return w;
            }
            price = ticks[price].prev;
            unchecked {
                ++w.steps;
            }
        }
        if (price == 0) return w; // resume stays 0: the book below is empty

        w.tau = price;

        // 2. Collect the band. Bounded by construction, not by `budget`: `low` is a price, and a
        //    band of `windowTicks` grid steps contains at most that many further tick prices.
        uint256 span = windowTicks * tickSpacing;
        uint256 low = price > span ? price - span : 0;
        uint256 size = windowTicks + 1;
        w.price = new uint256[](size);
        w.cap = new uint256[](size);
        w.weight = new uint256[](size);

        while (price != 0 && price >= low) {
            Tick storage t = ticks[price];
            uint256 dem = t.capTokens;
            if (dem != 0) {
                uint256 wt = _weight((w.tau - price) / tickSpacing);
                if (wt == 0) break; // q^d has rounded away; nothing further down can reach the book
                w.price[w.n] = price;
                w.cap[w.n] = dem;
                w.weight[w.n] = wt;
                w.weightSum += wt;
                unchecked {
                    ++w.n;
                }
            }
            price = t.prev;
            unchecked {
                ++w.steps;
            }
        }
        w.resume = price;
    }

    /// @dev One band solve in flight — the sorted walk of `_solveBand`, memory-only. Ticks are
    ///      indexed in list (descending price) order: the gathered band first, then whatever the
    ///      moving lower edge admits, appended as it is reached. Every array is band-indexed and
    ///      grown together.
    struct Solve {
        uint256 n; // ticks admitted so far
        uint256[] price;
        uint256[] cap; // capacity as gathered; 0 once fully dead
        uint256[] capK; // `min(cap, supply)`: what the walk can actually reach — keys use this
        uint256[] weight; // in the walk's current scale (see `_rescale`)
        uint256[] kappa; // the scalar at which the tick runs dry
        uint256[] entry; // the scalar at which the tick joined
        uint256[] tokens; // result: what each tick is handed; non-zero marks a dead tick mid-walk
        uint256[] order; // indices sorted by `kappa`; `head` is the next to die
        uint256 head;
        uint256 top; // index of the highest live tick — the band's anchor
        uint256 C; // the scalar: tokens per unit weight, Q96
        uint256 weightLeft; // sum of live weights
    }

    /// @dev Weights below this are rescaled up before the walk extends further, so a long run of
    ///      band moves never drives `q^d` to zero.
    uint256 internal constant RESCALE_BELOW = 1 << 32;
    uint256 internal constant RESCALE_BY = 1 << 64;

    /// @dev The inter-tick distribution, `human-docs/generous-auction.md` §A.6, in one sweep —
    ///      with the band MOVING as it goes.
    ///
    ///      Write `a_i = w_i * C` for a scalar `C` measured in tokens per unit weight; pouring
    ///      `dT` tokens advances `C` by `dT / W`. Tick `i` runs dry at `C = kappa_i = cap_i / w_i`,
    ///      a value fixed the moment it joins. So: keep the ticks sorted by `kappa`, walk it, and
    ///      each step is either "reach the next exhaustion" (drop that tick from `W` and carry on
    ///      — this is the waterfall of §1.2, the remainder re-flowing by renormalised weights) or
    ///      "the supply runs out first", which fixes `C` and ends it. No iteration to convergence.
    ///
    ///      THE BAND MOVES WHEN ITS TOP RUNS DRY. The band is `[tau - span, tau]` for the top live
    ///      tick `tau`, weights `q^(tau - price)`. Ratios inside the band are shift-invariant, so a
    ///      lower tick dying changes nothing about who else is served; but the TOP dying moves the
    ///      lower edge down with it, and ticks that were just past the old edge now sit inside the
    ///      curve with real weight. Pouring on against the OLD band handed the whole remainder to
    ///      its survivors and 0 to the tick just below the edge — while a sync that happened to
    ///      land right after the top dried gave that tick its full `q^d` share (round-7: same
    ///      book, same emission, 0 vs 29.67 of 100 depending on who called `sync` when; round-6:
    ///      a 2-wei dust bid parked `windowTicks` steps above a whale kept the honest tick out of
    ///      every pour). So when the top dies the walk ADMITS what the new edge reaches — read
    ///      off the list below `w.resume`, weighted `q^d` from the new top in the walk's own scale,
    ///      joining at the current `C` and slotted into the sorted order — and carries on. One
    ///      walk, however many times the band moves; that is exactly what a sync per block would
    ///      have done, so the outcome no longer depends on cadence.
    ///
    ///      Survivors are paid a floor of their curve share `w_i * (C - entry_i)`; a DRY tick is
    ///      paid its whole `cap`, while the walk subtracted only `floor(W * (kappa - C))` for it
    ///      and `kappa` itself was floored — two floors per exhaustion, so the unclamped sum can
    ///      exceed `supply` by up to two wei per dry tick. The running budget clamp at the end is
    ///      what keeps `sum(tokens) <= supply`; when it binds, the last tick in list order (the
    ///      lowest price) is the one shorted, by that many wei.
    ///
    ///      `w` is updated in place for the caller: `tau` ends on the top still standing, `resume`
    ///      on the node below the last band, `steps` counts the list nodes the extensions walked.
    ///      `w.steps` carries the BUDGET in: the list nodes the band moves may walk in total.
    ///      It comes back as the count actually walked. When the budget runs out the walk stops
    ///      at the next top death instead of moving the band: what was poured so far is exact,
    ///      the rest stays owed, and the caller parks the cursor.
    /// @return s The ticks poured, in list order, with `s.tokens` their allocations.
    /// @return drained True when the supply ran out with a survivor standing — nothing below the
    ///         last band can be reached.
    /// @return budgetOut True when the walk stopped for lack of budget with supply to spare.
    function _solveBand(Window memory w, uint256 supply)
        internal
        view
        returns (Solve memory s, bool drained, bool budgetOut)
    {
        uint256 budget = w.steps;
        w.steps = 0;
        _solveInit(w, s, supply);

        uint256 left = supply;
        while (left != 0 && s.head < s.n) {
            uint256 idx = s.order[s.head];
            uint256 dT = FixedPointMathLib.fullMulDiv(s.weightLeft, s.kappa[idx] - s.C, Q96);
            if (dT >= left) {
                // Supply runs out inside this segment: `C` stops partway and everyone still
                // standing is served off the same curve.
                s.C += FixedPointMathLib.fullMulDiv(left, Q96, s.weightLeft);
                left = 0;
                drained = true;
                break;
            }
            s.C = s.kappa[idx];
            left -= dT;
            s.weightLeft -= s.weight[idx];
            // Dead in the model. A tick whose capacity outran the supply (`capK < cap`) is paid
            // `capK` and keeps the rest: it is NOT dry on chain, so the band does not move off it.
            uint256 paid = s.capK[idx];
            s.tokens[idx] = paid;
            s.cap[idx] -= paid;
            unchecked {
                ++s.head;
            }
            if (idx == s.top && s.cap[idx] == 0) {
                // The top ran dry: the anchor moves to the highest tick still standing and the
                // band with it.
                uint256 t = idx + 1;
                while (t < s.n && s.cap[t] == 0) ++t;
                if (t == s.n) break; // nothing left standing: the band is dry
                if (w.steps >= budget) {
                    budgetOut = true;
                    break;
                }
                s.top = t;
                w.tau = s.price[t];
                _extend(w, s, left);
            }
        }

        // Pay out: dead ticks what the walk reached, survivors their curve share, all under a
        // running token budget.
        uint256 pot = supply;
        for (uint256 i; i < s.n; ++i) {
            uint256 a = s.tokens[i];
            if (a == 0) {
                a = FixedPointMathLib.fullMulDiv(s.weight[i], s.C - s.entry[i], Q96);
                if (a > s.cap[i]) a = s.cap[i];
            }
            if (a > pot) a = pot;
            s.tokens[i] = a;
            pot -= a;
        }
    }

    /// @dev Seed the solve with the gathered band: copy it in, key every tick, sort the keys.
    function _solveInit(Window memory w, Solve memory s, uint256 supply) internal view {
        uint256 size = w.n + windowTicks + 1;
        s.price = new uint256[](size);
        s.cap = new uint256[](size);
        s.capK = new uint256[](size);
        s.weight = new uint256[](size);
        s.kappa = new uint256[](size);
        s.entry = new uint256[](size);
        s.tokens = new uint256[](size);
        s.order = new uint256[](size);
        s.n = w.n;
        s.weightLeft = w.weightSum;
        // One sort orders the exhaustions and carries the index along: `(kappa << IDX_BITS) | i`.
        // A tick can never take more than the entire supply, so `capK = min(cap, supply)` keys
        // it: that keeps `kappa` under 2^224 (the index packs without loss and no segment
        // arithmetic can overflow) and cannot change the outcome — a tick capped here would need
        // more tokens than exist, so the supply runs out before it does.
        uint256[] memory keys = new uint256[](w.n);
        for (uint256 i; i < w.n; ++i) {
            s.price[i] = w.price[i];
            uint256 c = w.cap[i];
            s.cap[i] = c;
            if (c > supply) c = supply;
            s.capK[i] = c;
            s.weight[i] = w.weight[i];
            uint256 k = FixedPointMathLib.fullMulDiv(c, Q96, w.weight[i]);
            s.kappa[i] = k;
            keys[i] = (k << IDX_BITS) | i;
        }
        LibSort.sort(keys);
        for (uint256 i; i < w.n; ++i) {
            s.order[i] = keys[i] & IDX_MASK;
        }
    }

    /// @dev EXTEND the band after its top moved: admit every live tick the new lower edge reaches,
    ///      straight from the list below `w.resume`. A newcomer weighs `q^d` from the new top, in
    ///      the walk's current scale, joins at the current `C`, and is slotted into the sorted
    ///      order at its own `kappa`. A weight that would round to zero is not admitted — nothing
    ///      that far down can reach the book until the top moves again — and `w.resume` stays on
    ///      it so a later move reconsiders it.
    function _extend(Window memory w, Solve memory s, uint256 left) internal view {
        if (s.weight[s.top] < RESCALE_BELOW) _rescale(s);
        uint256 wTop = s.weight[s.top];
        uint256 low = _bandLow(w.tau);
        uint256 price = w.resume;
        while (price != 0 && price >= low) {
            Tick storage t = ticks[price];
            uint256 dem = t.capTokens;
            if (dem != 0) {
                uint256 wt = FixedPointMathLib.fullMulDiv(wTop, _weight((w.tau - price) / tickSpacing), Q96);
                if (wt == 0) break;
                _admit(s, price, dem > left ? left : dem, dem, wt);
            }
            price = t.prev;
            unchecked {
                ++w.steps;
            }
        }
        w.resume = price;
    }

    /// @dev Lower edge of the band topped at `tau`.
    function _bandLow(uint256 tau) internal view returns (uint256) {
        uint256 span = windowTicks * tickSpacing;
        return tau > span ? tau - span : 0;
    }

    /// @dev Append one tick to the solve and slot it into the sorted order. `reach` is its
    ///      capacity clamped to what is left to pour (see `_solveInit`).
    function _admit(Solve memory s, uint256 price, uint256 reach, uint256 dem, uint256 wt) internal pure {
        uint256 n = s.n;
        if (n == s.price.length) _growAll(s);
        s.price[n] = price;
        s.cap[n] = dem;
        s.capK[n] = reach;
        s.weight[n] = wt;
        s.entry[n] = s.C;
        uint256 k = s.C + FixedPointMathLib.fullMulDiv(reach, Q96, wt);
        s.kappa[n] = k;
        s.weightLeft += wt;
        // Binary search among the not-yet-dead for the first key above `k`, then shift.
        uint256 lo = s.head;
        uint256 hi = n;
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            if (s.kappa[s.order[mid]] <= k) lo = mid + 1;
            else hi = mid;
        }
        for (uint256 j = n; j > lo; --j) {
            s.order[j] = s.order[j - 1];
        }
        s.order[lo] = n;
        s.n = n + 1;
    }

    /// @dev Multiply every live weight by `RESCALE_BY` and divide the scalars to match, so the
    ///      products `w_i * (C - entry_i)` — the only thing that pays — are unchanged. Keys are
    ///      re-derived; the sorted order survives (everything scaled by one constant).
    function _rescale(Solve memory s) internal pure {
        s.C /= RESCALE_BY;
        s.weightLeft = 0;
        for (uint256 i; i < s.n; ++i) {
            if (s.tokens[i] != 0) continue; // dead: its weight is out of the walk
            uint256 wt = s.weight[i] * RESCALE_BY;
            s.weight[i] = wt;
            s.weightLeft += wt;
            uint256 e = s.entry[i] / RESCALE_BY;
            s.entry[i] = e;
            s.kappa[i] = e + FixedPointMathLib.fullMulDiv(s.capK[i], Q96, wt);
        }
    }

    /// @dev Double every band-indexed array, keeping contents.
    function _growAll(Solve memory s) internal pure {
        s.price = _grow(s.price);
        s.cap = _grow(s.cap);
        s.capK = _grow(s.capK);
        s.weight = _grow(s.weight);
        s.kappa = _grow(s.kappa);
        s.entry = _grow(s.entry);
        s.tokens = _grow(s.tokens);
        s.order = _grow(s.order);
    }

    /// @dev Double a memory array, keeping its contents.
    function _grow(uint256[] memory a) internal pure returns (uint256[] memory b) {
        b = new uint256[](a.length * 2);
        for (uint256 i; i < a.length; ++i) {
            b[i] = a[i];
        }
    }

    /// @dev Solve the band (band moves included), then run each poured tick's own stake-weighted
    ///      pour, once, with its whole allocation.
    /// @return sold Tokens actually taken (model allocation minus intra-tick dust).
    /// @return drained True when the supply ran out with a survivor standing — i.e. nothing below
    ///         can be reached, so settle is finished.
    /// @return pausedAt Non-zero when the sweep must PARK: a tick's pour hit the death budget
    ///         mid-way (its price), or the band moves ran out of tick budget (`w.tau`). In both
    ///         cases `w.tau` is reset to the band's ORIGINAL top so the cursor lands above every
    ///         tick this call touched — survivors and half-poured ticks alike stay reachable.
    /// @return deathsLeft What remains of the sync-wide death budget after this band.
    function _pourWindow(Window memory w, uint256 supply, uint256 deathsBudget)
        internal
        returns (uint256 sold, bool drained, uint256 pausedAt, uint256 deathsLeft)
    {
        uint256 top0 = w.tau;
        (Solve memory s, bool drained_, bool budgetOut) = _solveBand(w, supply);
        drained = drained_;
        deathsLeft = deathsBudget;

        for (uint256 i; i < s.n; ++i) {
            if (s.tokens[i] == 0) continue;
            (uint256 poured, uint256 left, bool paused) = _pourTick(s.price[i], s.tokens[i], deathsLeft);
            sold += poured;
            deathsLeft = left;
            if (paused) {
                pausedAt = s.price[i];
                break;
            }
        }
        if (pausedAt == 0 && budgetOut) pausedAt = top0;
        if (pausedAt != 0) w.tau = top0;
    }

    /// @dev The intra-tick pour: the window's rule one level down, with stakes for weights and
    ///      each position's escrow for a cap (`generous-auction.md` §A.6 shape, stake-weighted).
    ///      Advancing `acc` by `dA` hands every seated position `stake * dA` tokens; position
    ///      `p` exhausts at its stored `kappa`. The tick's heap orders those, so the pour walks
    ///      HEAD POPS ONLY: each step either reaches the next exhaustion (pop it, drop its stake,
    ///      keep pouring — the intra-tick waterfall) or runs out of tokens, which fixes `acc` and
    ///      ends it. Cost is O(deaths this pour), one death per position per lifetime — seats are
    ///      unlimited and settling never scans them.
    ///
    ///      POSITIONS ARE READ ONLY AT THEIR OWN DEATH (the pop). Consumption stays folded in the
    ///      index; a position crystallises on its own next touch, with the same formula the seat
    ///      accounting used. `capTokens` is charged exactly what was poured, and zeroed when the
    ///      heap empties so per-death flooring dust cannot linger as phantom capacity.
    /// @return poured Tokens actually consumed here (can trail `got` by flooring dust when
    ///         everyone exhausts; the shortfall stays in `due()`). `tokensUnclaimed`,
    ///         `tokensBooked` and `currencyRaised` are updated in place with the pot's share of
    ///         it — see the booking note at the end — pay-as-bid at one price, so the booking is
    ///         charged at `price` (per-position ceil charges sum to at least this).
    /// @return deathsLeft What remains of the sync-wide death budget.
    /// @return paused True when that budget ran out: the pour stopped exactly at a death
    ///         boundary, the advance so far is exact, and the sweep must resume at this tick.
    function _pourTick(uint256 price, uint256 got, uint256 deathsBudget)
        internal
        returns (uint256 poured, uint256 deathsLeft, bool paused)
    {
        Tick storage t = ticks[price];
        uint256 S = t.stakeSum;
        uint256 acc = t.acc;
        uint256 left = got;
        uint256 seats = t.heapSize; // every position this pour's index step reaches
        deathsLeft = deathsBudget;
        while (left != 0 && S != 0 && t.heapSize != 0) {
            if (deathsLeft == 0) {
                paused = true;
                break;
            }
            address head = heap[price][1];
            uint256 hk = positions[head].kappa;
            if (hk > acc) {
                uint256 dT = _tokensFor(S, hk - acc);
                if (dT >= left) {
                    // Advance by the CEIL index step: the collective consumption then covers
                    // everything booked (a floored step would book tokens no position can ever
                    // crystallise — charging escrow for supply never handed out — while leaving
                    // a remainder in `due()` that re-grinds the index on every later sync).
                    // Positions clamp at their own caps, so the ≤1-wei overshoot is absorbed
                    // there, in the contract's favour.
                    acc += FixedPointMathLib.fullMulDivUp(left, Q128, S);
                    left = 0;
                    break;
                }
                left -= dT;
                acc = hk;
            }
            _heapPopHead(price, t);
            S -= stakes[head];
            unchecked {
                --deathsLeft;
            }
        }
        poured = got - left;
        t.acc = acc;
        t.stakeSum = S;
        uint256 cap = t.capTokens;
        cap = cap > poured ? cap - poured : 0;
        t.capTokens = t.heapSize == 0 ? 0 : cap;

        // BOOK LESS THAN WAS POURED. Every seat crystallises its consumption with its own floor,
        // so with `seats` positions the sum of what they will ever be able to claim — and be
        // charged for — can trail `poured` by up to `seats - 1` token-wei (each floor loses
        // under a wei; the aggregate index step never does). Booking all of `poured` recorded
        // currency in `currencyRaised` that no position was ever debited for, and at a
        // whole-number price the per-position ceil charge recovers nothing: the pack then
        // pulled escrow that belonged to live bidders, and once they withdrew it every claim
        // reverted on the vault pull (round-7). So the pot's ledgers — `tokensBooked`,
        // `tokensUnclaimed`, `currencyRaised` — take `poured - (seats - 1)`, the lower bound
        // of what positions crystallise; `tokensSold` keeps the full `poured` so the schedule
        // does not re-offer the reserve. What positions crystallise beyond the booking is
        // uncollectable dust (`claim` clamps at `tokensUnclaimed`) and its charge stays in the
        // pot as surplus: the pot is never short, only ever ahead by wei.
        uint256 booked = poured;
        if (seats > 1) {
            uint256 reserve = seats - 1;
            booked = poured > reserve ? poured - reserve : 0;
        }
        uint256 spent = FixedPointMathLib.fullMulDiv(booked, price, WAD);
        tokensUnclaimed += booked;
        tokensBooked += booked;
        currencyRaised += spent;
        emit TickFilled(price, spent, t.capTokens != 0);
    }

    // ---------------------------------------------------------------- the tick heap

    /// @dev Seat `owner` in `price`'s min-heap on `Position.kappa`. O(log seats) sift-up, paid by
    ///      the owner whose seat it is.
    function _heapInsert(uint256 price, Tick storage t, Position storage p, address owner) internal {
        uint256 i = uint256(t.heapSize) + 1;
        t.heapSize = uint32(i);
        uint256 k = p.kappa;
        while (i > 1) {
            uint256 parent = i >> 1;
            address po = heap[price][parent];
            if (positions[po].kappa <= k) break;
            heap[price][i] = po;
            positions[po].heapIdx = uint32(i);
            i = parent;
        }
        heap[price][i] = owner;
        p.heapIdx = uint32(i);
    }

    /// @dev Remove `p` from its seat: the last leaf fills the hole and sifts to its place.
    function _heapRemove(uint256 price, Tick storage t, Position storage p) internal {
        uint256 i = p.heapIdx;
        p.heapIdx = 0;
        uint256 size = t.heapSize;
        t.heapSize = uint32(size - 1);
        if (i == size) return;
        _siftInto(price, i, size - 1, heap[price][size]);
    }

    /// @dev Pop the head — the next position to exhaust. The caller reads it before popping.
    function _heapPopHead(uint256 price, Tick storage t) internal {
        positions[heap[price][1]].heapIdx = 0;
        uint256 size = t.heapSize;
        t.heapSize = uint32(size - 1);
        if (size > 1) _siftInto(price, 1, size - 1, heap[price][size]);
    }

    /// @dev Place `moved` into the hole at `i` of a heap holding `size` seats: sift up, then down.
    function _siftInto(uint256 price, uint256 i, uint256 size, address moved) internal {
        uint256 k = positions[moved].kappa;
        while (i > 1) {
            uint256 parent = i >> 1;
            address po = heap[price][parent];
            if (positions[po].kappa <= k) break;
            heap[price][i] = po;
            positions[po].heapIdx = uint32(i);
            i = parent;
        }
        while (true) {
            uint256 c = i << 1;
            if (c > size) break;
            address co = heap[price][c];
            uint256 ck = positions[co].kappa;
            if (c < size) {
                address co2 = heap[price][c + 1];
                uint256 ck2 = positions[co2].kappa;
                if (ck2 < ck) {
                    c = c + 1;
                    co = co2;
                    ck = ck2;
                }
            }
            if (ck >= k) break;
            heap[price][i] = co;
            positions[co].heapIdx = uint32(i);
            i = c;
        }
        heap[price][i] = moved;
        positions[moved].heapIdx = uint32(i);
    }

    /// @dev `stake * dAcc / 2^128`, clamped at `cap` — a position's consumption, saturating
    ///      instead of reverting when a dust stake left the index deltas astronomically large.
    function _consumed(uint256 s, uint256 dAcc, uint256 cap) internal pure returns (uint256) {
        if (s != 0 && dAcc / Q128 >= type(uint256).max / s) return cap;
        uint256 c = FixedPointMathLib.fullMulDiv(s, dAcc, Q128);
        return c > cap ? cap : c;
    }

    /// @dev Tokens the whole live set eats while `acc` advances by `dAcc`, saturating on the
    ///      "never dies" kappas a dust stake produces.
    function _tokensFor(uint256 S, uint256 dAcc) internal pure returns (uint256) {
        if (dAcc / Q128 >= type(uint256).max / S) return type(uint256).max;
        return FixedPointMathLib.fullMulDiv(S, dAcc, Q128);
    }

    /// @dev The index value at which a position exhausts. Ceil so the death lands at-or-after the
    ///      exact point (`min` clamps any overshoot). Clamped at 2^240 — far past any reachable
    ///      index — both to saturate the dust-stake "never dies" case and to keep the value
    ///      packable above IDX_BITS without loss.
    function _kappa(uint256 aE, uint256 cap, uint256 s) internal pure returns (uint256) {
        uint256 max = 1 << 240;
        if (aE >= max || cap / s >= 1 << 112) return max;
        uint256 k = aE + FixedPointMathLib.fullMulDivUp(cap, Q128, s);
        return k >= max ? max : k;
    }

    /// @dev `q^d` in Q96. Exponentiation by squaring, so cost is logarithmic in the distance —
    ///      about one cold SLOAD at the far edge of any usable window.
    function _weight(uint256 d) internal view returns (uint256) {
        return FixedPointMathLib.rpow(decayQ, d, Q96);
    }

    /// @inheritdoc IGenerousAuction
    function mintPack() external override returns (uint256 minted) {
        return _mintPack();
    }

    /// @dev Mints the unpacked delta and holds it here. The escrow those fills spent goes to the
    ///      vault in the same call, so supply and backing still arrive together and NAV cannot
    ///      fall — the batching moves WHEN that happens, never whether.
    ///
    ///      The clamp: `Mono.mint` refuses anything dilutive, and NAV ratchets up as other packs
    ///      land. A fill priced below the NAV that now stands cannot mint its full share, so the
    ///      pack takes `maxIssuable` instead of reverting and stranding every claimant behind it.
    ///      All of the escrow is still paid in — it bought less MONO than the book promised, and
    ///      the difference raises NAV for everyone rather than sitting here unspendable.
    function _mintPack() internal returns (uint256 minted) {
        uint256 shares = tokensBooked - tokensMinted;
        uint256 assets = currencyRaised - currencyMinted;
        if (shares == 0 || assets == 0) return 0;

        uint256 cap = IMono(token).maxIssuable(assets);
        minted = shares > cap ? cap : shares;
        if (minted == 0) return 0;

        // `tokensMinted` takes what was actually minted, not what was owed — the gap between it
        // and `tokensBooked` IS the shortfall, and `claim` reads the ratio off exactly that pair.
        // `currencyMinted` takes the whole delta regardless: the escrow is spent either way, and
        // leaving it unpacked would re-offer it against a NAV that has only risen since.
        tokensMinted += minted;
        currencyMinted += assets;

        IMono(token).mint(minted, assets, address(this));
        emit PackMinted(minted, assets);
    }

    // ---------------------------------------------------------------- payouts

    /// @inheritdoc IGenerousAuction
    /// @dev MONO is not minted per claim. `_mintPack` mints the WHOLE unpacked sale at once,
    ///      against the escrow its fills spent, and this transfers one claimant's share out of it.
    ///      So the first claim pays the vault for everybody and every later one is a transfer.
    ///
    ///      Packing is deliberately NOT done in `_sync`. A pack lifts NAV, and `submitBid` floors
    ///      bids at `nav()`, so packing on every sync would ratchet the floor out from under the
    ///      bottom tick mid-sale — a bid at `floorPrice` would revert `BelowNav` the moment anyone
    ///      synced. Bidding must be able to happen at a still price.
    ///
    ///      The shortfall clamp: a pack whose fills priced below the NAV standing when it is
    ///      minted buys less MONO than the book promised (see `_mintPack`). The balance held here
    ///      is then short of `tokensUnclaimed` and this pays what there is — NET OF STAKE, which
    ///      is bidders' property and never part of any pack.
    function claim(address owner) external override nonReentrant returns (uint256 tokens) {
        tokens = _claim(owner);
        if (tokens != 0) token.safeTransfer(owner, tokens);
    }

    /// @inheritdoc IGenerousAuction
    /// @dev Caller-only, unlike `claim` — nobody may force someone else's winnings into a stake.
    ///      Inside the lock window the stake leg would revert, and winnings must always flow, so
    ///      it degrades to a plain claim there. The reweigh mirrors `stake()`: `_claim` has just
    ///      harvested (and re-anchored) the position, so the new weight applies forward only.
    function claimAndStake() external override nonReentrant returns (uint256 tokens) {
        tokens = _claim(msg.sender);
        if (tokens == 0) return 0;

        if (!_stakeOpen() || (positions[msg.sender].price != 0 && !_settled())) {
            token.safeTransfer(msg.sender, tokens);
            return tokens;
        }

        uint256 sOld = stakes[msg.sender];
        uint256 sNew = sOld + tokens;
        _reseat(msg.sender, positions[msg.sender], sOld, sNew);
        stakes[msg.sender] = sNew;
        totalStaked += tokens;

        emit Staked(msg.sender, tokens);
    }

    /// @dev The whole of a claim except the payout leg: settle, pack, harvest, clamp, book.
    ///      Returns what the caller must now deliver — by transfer (`claim`) or by crediting the
    ///      stake account (`claimAndStake`).
    function _claim(address owner) internal returns (uint256 tokens) {
        // Bring the book up to date first, so a claim never pays out less than the schedule owes,
        // then mint whatever it just sold. Both are no-ops once someone else has been through.
        _sync(SYNC_TICKS);
        _mintPack();

        (Position storage p,) = _harvest(owner);
        // Re-seat at the post-harvest escrow. The ceil charge can leave the position's real
        // capacity a token-wei under its seat (`kappa`, `capTokens`); every other harvest path
        // re-seats and heals that, and a plain claim that did not left a phantom wei the next
        // pour booked and charged for — at a single-seat tick the pot went short (round-8).
        _reseat(owner, p, stakes[owner], stakes[owner]);

        uint256 owed = p.tokensOwed;
        // Per-position rounding is in the bidder's favour, so it is absorbed here, not in the pot.
        if (owed > tokensUnclaimed) owed = tokensUnclaimed;
        if (owed == 0) return 0;

        // Pro-rata against the REMAINING pot, not a cumulative ratio: each claim takes
        // `owed * held / unclaimed`, which leaves the ratio `held/unclaimed` invariant — so a
        // shortfall (a NAV-clamped pack) gives every claimant the same haircut REGARDLESS of
        // claim order. The cumulative `tokensMinted/tokensSold` ratio looked fair but was not:
        // claims made before the shortfall took ratio 1 and the deficit fell entirely on
        // whoever claimed last.
        uint256 unclaimed = tokensUnclaimed;
        uint256 held = token.balanceOf(address(this)) - totalStaked;
        tokens = held >= unclaimed ? owed : FixedPointMathLib.fullMulDiv(owed, held, unclaimed);
        if (tokens == 0) return 0;

        uint256 assets = p.assetsOwed;
        p.tokensOwed -= uint128(owed);
        p.assetsOwed = 0;
        tokensUnclaimed = unclaimed - owed;

        // The escrow these winnings spent, recorded at harvest time — `p.price` may since have
        // been re-bound or zeroed by a withdrawal, so it is no basis for a cost log.
        emit Claimed(owner, p.price, tokens, assets);
    }

    // ---------------------------------------------------------------- internals

    /// @dev Materialise whatever the depletion index says this position has consumed since its
    ///      anchor — tokens owed up, escrow charged (ceil) — and re-anchor. O(1), idempotent, and
    ///      bit-identical to the in-memory math `_pourTick` runs, which is what lets the pour skip
    ///      writing positions at all.
    function _harvest(address owner) internal returns (Position storage p, uint256 live) {
        p = positions[owner];
        uint256 price = p.price;
        uint256 amount = p.amount;
        if (price == 0 || amount == 0) {
            // Nothing live — but RE-ANCHOR before returning: an exhausted position left at a
            // stale accAtEntry would count the whole index gap since its death as phantom
            // consumption of a later same-price top-up, instantly stealing co-stakers' pot
            // (round-5 critical, PoC'd). The heap rewrite dropped the old scan-harvest's
            // re-base line for this branch; this restores it.
            if (price != 0) p.accAtEntry = ticks[price].acc;
            return (p, 0);
        }

        Tick storage t = ticks[price];
        uint256 s = stakes[owner];
        if (s != 0) {
            uint256 cap = FixedPointMathLib.fullMulDiv(amount, WAD, price);
            uint256 eaten = _consumed(s, t.acc - p.accAtEntry, cap);
            if (eaten != 0) {
                uint256 charged = FixedPointMathLib.fullMulDivUp(eaten, price, WAD);
                p.tokensOwed += uint128(eaten);
                p.assetsOwed += uint128(charged);
                amount -= charged;
                p.amount = uint128(amount);
            }
        }
        // Re-anchor in every case — including `s == 0`, where nothing accrued and nothing may
        // accrue retroactively when the owner stakes again.
        p.accAtEntry = t.acc;
        live = amount;
    }

    /// @dev Insert `price` into the sorted list. `prevPrice` is a HINT: the exact predecessor —
    ///      a linked tick below `price` with nothing between it and `price` — is verified in
    ///      O(1) against the live list and used as is. Anything else (stale, off by one, a node
    ///      a sweep has since unlinked, 0) costs the caller a walk up `next` from the floor to
    ///      the real predecessor, never a revert. Hints are inherently racy now that sweeps
    ///      unlink dead nodes: the implicit sync at the head of `submitBid` itself can drop the
    ///      very node a UI read as the top of book a block earlier (round-7 organic sims: every
    ///      such case was an honest bid), so a wrong hint has to degrade, not fail.
    ///
    ///      COST OF THE WALK. A sweep unlinks every dead run it walks — including each window's
    ///      own band, once that band has run dry — so the chain holds the live book plus only
    ///      what no sweep has reached yet. That last term is not zero and is not bounded by the
    ///      book: `_sync` stops when the supply runs out, so dead ticks below a top of book that
    ///      keeps absorbing the whole emission are never walked and stay linked (measured: 100
    ///      such nodes, one `submitBid` + `withdrawBid` each to create, ~2.3k gas apiece on a
    ///      later hintless bid — round-9). A bidder who sends the exact predecessor pays none of
    ///      it; a bidder who guesses wrong pays for their own guess; `_relink` has no hint to
    ///      send and pays it unavoidably, which is why it is on the rare path only.
    ///      Only ever reached from `submitBid` and `_relink`.
    function _initializeTick(uint256 prevPrice, uint256 price) internal {
        // Already in the list (its lower neighbour points back at it)? Nothing to do. A tick
        // `_splice` unlinked fails this and re-inserts below — acc/aggregates persist, only the
        // links are rebuilt.
        if (ticks[price].init && _linked(price)) return;
        if (!_validHint(prevPrice, price)) prevPrice = _predecessor(price);

        uint256 nextPrice = ticks[prevPrice].next;
        if (nextPrice == price) return; // cannot happen with a sound list; never self-link

        Tick storage t = ticks[price];
        t.next = nextPrice;
        t.prev = prevPrice;
        t.init = true;

        ticks[prevPrice].next = price;
        if (nextPrice != 0) ticks[nextPrice].prev = price;
    }

    /// @dev Is `prevPrice` the exact live-list predecessor of `price`? Every check is against the
    ///      live list, never a node's own stale memory: the hint must be linked (an unlinked
    ///      spliced node would seat the bid outside the sweep), its upper neighbour must point
    ///      back at it, and that neighbour must sit strictly ABOVE `price` — `== price` would
    ///      write `ticks[price].prev = price` and loop the list (round-7 critical).
    function _validHint(uint256 prevPrice, uint256 price) internal view returns (bool) {
        if (prevPrice >= price || !ticks[prevPrice].init || !_linked(prevPrice)) return false;
        uint256 nextPrice = ticks[prevPrice].next;
        return nextPrice == 0 || (nextPrice > price && ticks[nextPrice].prev == prevPrice);
    }

    /// @dev The exact predecessor of `price`, by walking `next` up from the floor.
    function _predecessor(uint256 price) internal view returns (uint256 q) {
        q = floorPrice;
        while (true) {
            uint256 nx = ticks[q].next;
            if (nx == 0 || nx >= price) return q;
            q = nx;
        }
    }

    // ---------------------------------------------------------------- views

    /// @inheritdoc IGenerousAuction
    /// @dev Read-only mirror of `_harvest`, so callers see the truth without anyone harvesting.
    ///      The raw `positions` getter shows only the already-crystallised half.
    ///
    ///      IT MIRRORS THE HARVEST, NOT THE SYNC. `claim` settles the book first (`_claim` runs
    ///      `_sync`), so in any block with `due() != 0` this reports the pre-sync position and a
    ///      claim in that same block pays more — a whole pending round more, on a lazily settled
    ///      book (round-14). A UI that gates a "claim" button on `tokensOwed > 0` should call
    ///      `sync` first, or read `previewWindow` for what the pending pour adds.
    function positionOf(address owner) external view override returns (uint256 live, uint256 tokensOwed) {
        Position storage p = positions[owner];
        tokensOwed = p.tokensOwed;
        uint256 price = p.price;
        uint256 amount = p.amount;
        if (price == 0 || amount == 0) return (0, tokensOwed);

        live = amount;
        uint256 s = stakes[owner];
        if (s != 0) {
            uint256 cap = FixedPointMathLib.fullMulDiv(amount, WAD, price);
            uint256 eaten = _consumed(s, ticks[price].acc - p.accAtEntry, cap);
            if (eaten != 0) {
                tokensOwed += eaten;
                live = amount - FixedPointMathLib.fullMulDivUp(eaten, price, WAD);
            }
        }
    }

    /// @inheritdoc IGenerousAuction
    function tickPositions(uint256 price) external view override returns (address[] memory out) {
        uint256 n = ticks[price].heapSize;
        out = new address[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = heap[price][i + 1];
        }
    }

    /// @notice The weight `q^d` a tick `d` grid steps below the top of book carries, in Q96.
    function weightAt(uint256 d) external view returns (uint256) {
        return _weight(d);
    }

    /// @notice What a sync right now would hand each live tick, without changing anything.
    /// @dev The honest preview: `tokens[i]` is what tick `price[i]` would receive from a `sync` in
    ///      this block, carry included. Runs the same solve a sync would (`_solveBand`: the band,
    ///      re-anchored as its tops run dry) over the same `due()`, window after window down the
    ///      book exactly as `_sync` does, so a UI never has to reimplement the curve; ticks in
    ///      list order, each once. `tau` and `weightSum` are the FIRST band's.
    ///
    ///      TWO THINGS A CALLER MUST NOT ASSUME. (1) The per-tick figure does NOT split among the
    ///      tick's seats by stake alone: `_pourTick` is stake-weighted only until a seat reaches
    ///      its own escrow cap, after which that seat takes exactly its cap and the remainder
    ///      re-flows to the survivors — so a stake-proportional split is wrong for any tick where
    ///      a seat exhausts inside the pour, which is the common case. (2) This view is
    ///      unbudgeted while a real `sync` is bounded by `maxTicks` and by the death budget, so
    ///      on a deep backlog it reports a whole sweep the next transaction will only partly
    ///      perform. Both are integrator-facing; neither affects settlement.
    function previewWindow()
        external
        view
        returns (uint256 tau, uint256 weightSum, uint256[] memory price, uint256[] memory tokens)
    {
        uint256 start = settleCursor;
        if (start == 0) start = highestTick;
        uint256 supply = due();
        uint256 n;
        price = new uint256[](windowTicks + 1);
        tokens = new uint256[](windowTicks + 1);

        while (start != 0) {
            Window memory w = _gather(start, type(uint256).max);
            if (tau == 0) {
                tau = w.tau;
                weightSum = w.weightSum;
            }
            if (w.n == 0) break;
            w.steps = type(uint256).max; // no budget: the preview runs the whole sweep
            (Solve memory s, bool drained,) = _solveBand(w, supply);
            // Append into a buffer that DOUBLES when it fills. Re-allocating both arrays at the
            // accumulated length once per window made the memory O(W^2) words and, with the
            // EVM's quadratic expansion, the gas roughly O(W^4): a 320-window book cost 62M and
            // a 640-window one 562M, so the view died out of gas long before the mechanism did
            // (round-14). Growth is amortised now and the arrays are trimmed on the way out.
            for (uint256 i; i < s.n; ++i) {
                if (n == price.length) {
                    price = _grow(price);
                    tokens = _grow(tokens);
                }
                price[n] = s.price[i];
                tokens[n] = s.tokens[i];
                supply -= s.tokens[i];
                unchecked {
                    ++n;
                }
            }
            if (drained || supply == 0) break;
            start = w.resume;
        }
        assembly {
            mstore(price, n)
            mstore(tokens, n)
        }
    }
}
