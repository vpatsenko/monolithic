// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Review9HintsBase} from "./Review9_hints_Base.sol";

/// Round-9 `hints` lens, part 3: the cost and the termination of the `_predecessor` walk.
///
/// `_initializeTick`'s doc says the fallback walk "is over the live list only — dead runs are
/// unlinked once walked — so its length is the book's, and only the bidder who guessed wrong
/// pays for it". Sweeps only ever walk DOWNWARD from the top and stop the moment the supply
/// drains (`_sync`'s `if (drained) break;`), so a tick that dies BELOW the deepest point any
/// sweep reached is never walked and never unlinked. These tests measure how long the `next`
/// chain from the floor can be made, who pays for it, and whether anything ever reclaims it.
contract Review9HintsPredecessorWalk is Review9HintsBase {
    address internal constant WHALE = address(0x7777);
    address internal constant GRIEF = address(0x6666);
    address internal constant VICTIM = address(0x5555);
    address internal constant RESTAKER = address(0x4444);

    uint256 internal TOP;

    function setUp() public {
        _deploy(40e18, 0);
        TOP = FLOOR + 120 * SPACING;
        // The whale sits far above the grid the griefer uses: every sync drains inside its own
        // window and `_sync` breaks before walking anywhere near the floor.
        _stakeFor(WHALE, 100e18);
        _bid(WHALE, TOP, 400e18, 0);
    }

    function _chainLen() internal view returns (uint256 n) {
        uint256 q = FLOOR;
        while (true) {
            uint256 nx = _next(q);
            if (nx == 0) return n;
            q = nx;
            ++n;
            require(n < 5000, "chain walk did not terminate");
        }
    }

    /// One griefer address, `n` bid/withdraw cycles, all below the whale's band.
    function _trail(uint256 n) internal {
        _stakeFor(GRIEF, 1e15);
        for (uint256 i; i < n; ++i) {
            _bid(GRIEF, FLOOR + (i + 1) * SPACING, 2e18, 0);
            vm.prank(GRIEF);
            auction.withdrawBid();
        }
    }

    /// ONE address grows the `next` chain without bound: bid low, withdraw, bid one tick
    /// higher, withdraw... every abandoned price stays `init` AND linked forever, because no
    /// sweep ever walks that low. NOT bounded by "the book" — the book is one live tick.
    function test_oneAddressGrowsTheHintWalkWithoutBound() public {
        uint256 n = 100;
        _trail(n);
        assertEq(_chainLen(), n + 1, "trail did not accumulate"); // n dead + the whale

        // Sweeps reclaim it: a window whose band ran dry is unlinked down to its resume point,
        // so the trail is walked away a window at a time and the `next` chain converges on the
        // live book instead of retaining one node per price ever bid at (round-9 fix).
        for (uint256 r; r < 8; ++r) {
            vm.roll(block.number + K);
            auction.sync(400);
        }
        uint256 live;
        for (uint256 i; i <= 130; ++i) {
            if (_cap(FLOOR + i * SPACING) != 0) ++live;
        }
        emit log_named_uint("linked nodes on the next chain", _chainLen());
        emit log_named_uint("ticks with capacity (the actual book)", live);
        assertLe(live, 1, "the book is at most one tick");
        // What sweeps DO reclaim is what they walk. Here they never descend: the whale's window
        // drains every round and `_sync` breaks, so the trail below it is never on any sweep's
        // path and stays linked. (A sweep that runs dry unlinks its whole band down to its
        // resume point — see `Review9_links_RidgeScale` — so the trail only survives under a top
        // of book that keeps absorbing the emission.) This is the residual cost of a
        // demand-driven sweep, and it is what the next hintless bid pays for.
        assertGe(_chainLen(), n, "a drained top of book leaves the trail below it untouched");
        emit log_named_uint("nodes the sweep never reached", _chainLen() - live - 1);
        _checkList(_grid(140), "trail");
    }

    /// What an unreachable trail costs the next honest bidder who has no usable hint.
    function test_trailCostsTheNextBidderPerNode() public {
        uint256 clean = _measureBid(0);
        uint256 dirty = _measureBid(100);
        emit log_named_uint("bid gas, clean book, no hint", clean);
        emit log_named_uint("bid gas, 100-node trail, no hint", dirty);
        emit log_named_uint("marginal gas per trail node", (dirty - clean) / 100);
        assertGt(dirty, clean, "the trail is free");
    }

    function _measureBid(uint256 n) internal returns (uint256 used) {
        uint256 snap = vm.snapshotState();
        if (n != 0) _trail(n);
        _stakeFor(VICTIM, 10e18);
        uint256 price = FLOOR + 110 * SPACING;
        cur.mint(VICTIM, 20e18);
        vm.startPrank(VICTIM);
        cur.approve(address(auction), 20e18);
        uint256 g0 = gasleft();
        auction.submitBid(price, 20e18, VICTIM, 0); // no hint: full walk
        used = g0 - gasleft();
        vm.stopPrank();
        vm.revertToState(snap);
    }

    /// The one path with NO hint at all: `_reseat` -> `_relink`. An owner who un-staked to zero
    /// and re-stakes pays the whole walk, and there is no parameter that lets them avoid it, so
    /// "only the bidder who guessed wrong pays for it" does not hold either.
    function test_relinkPaysTheWholeWalkWithNoHintAvailable() public {
        _trail(100);

        // RESTAKER's tick sits ABOVE the whale, so a sweep really does unlink it.
        uint256 rp = FLOOR + 130 * SPACING;
        _stakeFor(RESTAKER, 10e18);
        _bid(RESTAKER, rp, 20e18, 0);
        vm.prank(RESTAKER);
        auction.unstake(10e18);
        vm.roll(block.number + K);
        auction.sync(400);
        assertEq(_prev(rp), 0, "the sweep did not unlink the dead tick");

        mono.transfer(RESTAKER, 5e18);
        vm.startPrank(RESTAKER);
        mono.approve(address(auction), 5e18);
        uint256 g0 = gasleft();
        auction.stake(5e18); // -> _reseat -> _relink -> _predecessor over the whole trail
        uint256 used = g0 - gasleft();
        vm.stopPrank();
        emit log_named_uint("re-stake gas over a 100-node trail", used);
        assertEq(_prev(rp), TOP, "relink landed off the top of the chain");
        _checkList(_grid(140), "relinked over trail");
    }

    /// The correct hint keeps the bid O(1) whatever the trail is: the griefing only bites the
    /// paths with no usable hint.
    function test_correctHintStaysFlat() public {
        uint256 clean = _measureHintedBid(0);
        uint256 dirty = _measureHintedBid(100);
        emit log_named_uint("bid gas, clean book, exact hint", clean);
        emit log_named_uint("bid gas, 100-node trail, exact hint", dirty);
        assertLe(dirty, clean + 20_000, "the exact hint is not O(1) over the trail");
    }

    function _measureHintedBid(uint256 n) internal returns (uint256 used) {
        uint256 snap = vm.snapshotState();
        if (n != 0) _trail(n);
        _stakeFor(VICTIM, 10e18);
        uint256 price = FLOOR + 110 * SPACING;
        uint256 hint = _hintFor(price);
        cur.mint(VICTIM, 20e18);
        vm.startPrank(VICTIM);
        cur.approve(address(auction), 20e18);
        uint256 g0 = gasleft();
        auction.submitBid(price, 20e18, VICTIM, hint);
        used = g0 - gasleft();
        vm.stopPrank();
        vm.revertToState(snap);
    }

    /// What one trail node costs the griefer, for the ratio.
    function test_griefRatio() public {
        _stakeFor(GRIEF, 1e15);
        uint256 g0 = gasleft();
        _bid(GRIEF, FLOOR + SPACING, 2e18, FLOOR);
        vm.prank(GRIEF);
        auction.withdrawBid();
        uint256 cost = g0 - gasleft();
        emit log_named_uint("griefer gas per permanent trail node (bid + withdraw)", cost);
    }

    /// The trail is dormant while the book above it is alive, and becomes a WALL the moment the
    /// book dies: bids revert `SettleFirst` until enough permissionless `sync` calls have walked
    /// it, 128 nodes at a time (`SYNC_TICKS`). Characterisation, with the numbers.
    function test_dormantTrailBecomesAWallWhenTheBookDies() public {
        _trail(300);
        // The whale exits: nothing live is left above the trail.
        vm.prank(WHALE);
        auction.withdrawBid();
        vm.roll(block.number + K);

        // An honest, staked, funded bid cannot land: its own implicit sync parks the cursor.
        _stakeFor(VICTIM, 10e18);
        uint256 price = FLOOR + 310 * SPACING;
        assertFalse(_tryBid(VICTIM, price, 20e18, _hintFor(price)), "the bid landed through the wall");

        uint256 syncs;
        for (uint256 i; i < 40; ++i) {
            auction.sync(0);
            ++syncs;
            if (auction.settleCursor() == 0) break;
        }
        emit log_named_uint("permissionless syncs needed to clear a 300-node trail", syncs);
        assertTrue(_tryBid(VICTIM, price, 20e18, _hintFor(price)), "still walled after the syncs");
        _checkList(_grid(320), "wall cleared");
    }

    /// Composite with the round-8 hint-frontrun: one tick inserted between the victim's hint and
    /// its price invalidates the O(1) path and drops the victim onto the FULL walk — whose
    /// length is the trail, not the book. The attacker pays once per block; the victim pays
    /// 2.3k gas per trail node, every block, and the trail is permanent.
    function test_frontrunOnATrailIsUnbounded() public {
        address WHALE2 = address(0x8888);
        _stakeFor(WHALE2, 100e18);
        _bid(WHALE2, FLOOR + 400 * SPACING, 400e18, 0); // keeps every sweep above the trail

        uint256 n = 300;
        _trail(n);
        uint256 price = FLOOR + 320 * SPACING;
        uint256 hint = _hintFor(price);
        assertEq(hint, FLOOR + n * SPACING, "hint is the top of the trail");

        // Baseline: the honest hint, no frontrun.
        uint256 snap = vm.snapshotState();
        _stakeFor(VICTIM, 10e18);
        cur.mint(VICTIM, 20e18);
        vm.startPrank(VICTIM);
        cur.approve(address(auction), 20e18);
        uint256 g0 = gasleft();
        auction.submitBid(price, 20e18, VICTIM, hint);
        uint256 clean = g0 - gasleft();
        vm.stopPrank();
        vm.revertToState(snap);

        // Frontrun: one tick between the hint and the price.
        address FR = address(0x9999);
        _stakeFor(FR, 1e15);
        _bid(FR, FLOOR + 310 * SPACING, 2e18, hint);

        _stakeFor(VICTIM, 10e18);
        cur.mint(VICTIM, 20e18);
        vm.startPrank(VICTIM);
        cur.approve(address(auction), 20e18);
        g0 = gasleft();
        auction.submitBid(price, 20e18, VICTIM, hint); // now stale: full walk over the trail
        uint256 frontrun = g0 - gasleft();
        vm.stopPrank();

        emit log_named_uint("trail nodes", n);
        emit log_named_uint("victim gas, hint honoured", clean);
        emit log_named_uint("victim gas, hint frontrun", frontrun);
        emit log_named_uint("penalty per trail node", (frontrun - clean) / n);
        assertGt(frontrun, clean, "the frontrun is free");
        _checkList(_grid(420), "frontrun on a trail");
    }
}
