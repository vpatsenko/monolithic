// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Review9LinksBase} from "./Review9_links_Base.sol";

/// Hand-built shapes the randomised drivers cannot reliably reach:
///   * `_splice` with `lo == floorPrice` and a dead ex-top as `hi` (the O(1) drop against the floor)
///   * a death-budget PAUSE inside `_pourTick` (>128 exhaustions in one sync) and the resume
///   * `claim` mutating the list (`_reseat` -> `_relink`, `highestTick` bump) while the cursor is
///     parked — the only list-mutating entry point with no `SettleFirst` guard
///   * a tick re-bid in the same block a sweep unlinked it
///   * unstake-to-zero -> sweep unlinks the tick -> re-stake (`_relink`, no hint)
contract Review9LinksScenariosTest is Review9LinksBase {
    function setUp() public {
        _deploy(0, 40e18);
        _registerGrid(64);
    }

    function _fund(address who, uint256 stakeAmt, uint256 currencyAmt) internal {
        mono.transfer(who, stakeAmt);
        cur.mint(who, currencyAmt);
        vm.startPrank(who);
        mono.approve(address(auction), stakeAmt);
        auction.stake(stakeAmt);
        cur.approve(address(auction), currencyAmt);
        vm.stopPrank();
    }

    function _bid(address who, uint256 step, uint128 amount, uint256 hint) internal {
        vm.prank(who);
        auction.submitBid(FLOOR + step * SPACING, amount, who, hint);
    }

    // ------------------------------------------------------------------ splice against the floor

    /// `hi` is a dead ex-top and `lo` is the FLOOR: the O(1) drop writes `ticks[floor].next = 0`
    /// and `ticks[hi].prev = 0`. Neither must leave the floor half-linked or the ex-top half-linked.
    function test_links_spliceDropAgainstFloor() public {
        address a = address(0xA1);
        address b = address(0xA2);
        _fund(a, 10e18, 200e18);
        _fund(b, 10e18, 200e18);
        _bid(a, 0, 100e18, 0); // the floor
        _bid(b, 30, 100e18, FLOOR); // a lone top, 30 steps up (far outside the 8-step band)

        vm.roll(block.number + 100_000);
        auction.sync(1); // dries the top, then the floor
        _checkList();
        auction.sync(1);
        _checkList();

        (uint256 nx30, uint256 pv30,,,,,) = auction.ticks(FLOOR + 30 * SPACING);
        (uint256 nx0, uint256 pv0,,,,,) = auction.ticks(FLOOR);
        emit log_named_uint("tick30.next", nx30);
        emit log_named_uint("tick30.prev", pv30);
        emit log_named_uint("floor.next", nx0);
        emit log_named_uint("floor.prev", pv0);
        emit log_named_uint("highestTick step", (auction.highestTick() - FLOOR) / SPACING);

        // and a fresh bid must still land in the right place afterwards
        address c = address(0xA3);
        _fund(c, 10e18, 200e18);
        _bid(c, 12, 100e18, 0);
        _checkList();
        assertEq(auction.highestTick(), FLOOR + 12 * SPACING, "new bid is the top");
    }

    /// MINIMAL repro of the leak: two ticks. The top dies INSIDE the pour, so `_splice`'s O(1)
    /// dead-ex-top drop never sees it (the drop only fires when the WALK START is a dead top,
    /// and `_sync` shaved `highestTick` below it in the same call). It is linked forever after.
    function test_links_deadWindowTopNeverUnlinked() public {
        address a = address(0xD1);
        address b = address(0xD2);
        _fund(a, 10e18, 200e18);
        _fund(b, 10e18, 200e18);
        _bid(a, 0, 100e18, 0); // floor
        _bid(b, 30, 100e18, FLOOR); // lone top, its own window (30 > windowTicks = 8)

        vm.roll(block.number + 100_000);
        for (uint256 i; i < 5; ++i) {
            auction.sync(1);
        }
        _checkList();

        uint256 top = FLOOR + 30 * SPACING;
        (uint256 nx, uint256 pv, uint256 capTop,,,,) = auction.ticks(top);
        emit log_named_uint("highestTick step", (auction.highestTick() - FLOOR) / SPACING);
        emit log_named_uint("ex-top capTokens", capTop);
        emit log_named_uint("ex-top prev", pv);
        emit log_named_uint("ex-top next", nx);
        assertEq(capTop, 0, "the ex-top really is dead");
        assertLt(auction.highestTick(), top, "the high-water was shaved below it");
        // `_splice`'s drop exists so this cannot happen ("a sale whose top keeps exhausting does
        // not grow a chain of dead ex-tops above `highestTick`"). It does.
        assertTrue(pv == 0 && nx == 0, "dead ex-top above highestTick is still linked");
    }

    // ------------------------------------------------------------------ death-budget pause

    /// 200 seats at two ticks: one sync's pour blows through `MAX_DEATHS_PER_SYNC = 128` and
    /// `_pourTick` PAUSES mid-tick. The cursor parks on the band's ORIGINAL top; the list must be
    /// sound at the pause, after `claim`s taken while parked, and after the resume.
    function test_links_deathBudgetPauseAndResume() public {
        uint256 n = 200;
        address[] memory who = new address[](n);
        for (uint256 i; i < n; ++i) {
            who[i] = address(uint160(0xF100 + i));
            _fund(who[i], 1e15 + i * 1e12, 3e18);
            // two ticks, both inside one band, so a single pour reaches both
            _bid(who[i], i % 2 == 0 ? 20 : 21, 2e18 + uint128(i) * 1e9, 0);
        }
        _checkList();

        vm.roll(block.number + 100_000);
        auction.sync(1);
        emit log_named_uint("cursor after pour", auction.settleCursor());
        emit log_named_uint("highestTick step", (auction.highestTick() - FLOOR) / SPACING);
        _checkList();
        _checkPositionsReachable(who);

        // `claim` is the one list-mutating call with no `SettleFirst` guard: exercise it while
        // the cursor is parked.
        for (uint256 i; i < 40; ++i) {
            auction.claim(who[i]);
            _checkList();
        }
        _checkPositionsReachable(who);

        for (uint256 r; r < 8; ++r) {
            auction.sync(1);
            _checkList();
            _checkPositionsReachable(who);
        }
        emit log_named_uint("cursor at end", auction.settleCursor());
    }

    // ------------------------------------------------------------------ same-block death + re-bid

    /// A tick dies in a sweep and is re-bid in the SAME block, with the hint the bidder read
    /// BEFORE the sweep (now stale). `_validHint` must reject it and `_predecessor` must land the
    /// tick back in its exact place.
    function test_links_reBidInTheBlockItDied() public {
        address a = address(0xB1);
        address b = address(0xB2);
        address c = address(0xB3);
        _fund(a, 10e18, 400e18);
        _fund(b, 10e18, 400e18);
        _fund(c, 10e18, 400e18);
        _bid(a, 0, 50e18, 0);
        _bid(b, 25, 50e18, FLOOR);
        _bid(c, 40, 50e18, FLOOR + 25 * SPACING);

        uint256 staleHint = FLOOR + 25 * SPACING; // read now, used after the sweep kills tick 25
        vm.roll(block.number + 100_000);

        // one transaction: the implicit sync inside `submitBid` unlinks ticks 25 and 40, then the
        // bid is seated at 25 with the stale hint.
        address d = address(0xB4);
        _fund(d, 10e18, 400e18);
        _bid(d, 25, 50e18, staleHint); // hint == the price itself after the kill: must be refused
        _checkList();

        address e = address(0xB5);
        _fund(e, 10e18, 400e18);
        _bid(e, 40, 50e18, staleHint);
        _checkList();
        assertEq(auction.highestTick(), FLOOR + 40 * SPACING, "top restored");
    }

    // ------------------------------------------------------------------ unstake-to-zero -> relink

    /// Unstake to zero leaves live escrow at a tick that now reads dead; a sweep unlinks it;
    /// re-staking must `_relink` it into its exact place with no hint.
    function test_links_unstakeToZeroThenRestake() public {
        address a = address(0xC1);
        address b = address(0xC2);
        address c = address(0xC3);
        _fund(a, 10e18, 400e18);
        _fund(b, 10e18, 400e18);
        _fund(c, 10e18, 400e18);
        _bid(a, 0, 50e18, 0);
        _bid(b, 20, 50e18, FLOOR);
        _bid(c, 45, 50e18, FLOOR + 20 * SPACING);

        vm.prank(b);
        auction.unstake(10e18); // to zero: escrow stays, the tick reads dead
        _checkList();

        vm.roll(block.number + 400);
        auction.sync(1);
        _checkList();
        (uint256 nx, uint256 pv,,,,,) = auction.ticks(FLOOR + 20 * SPACING);
        emit log_named_uint("tick20.next after sweep", nx);
        emit log_named_uint("tick20.prev after sweep", pv);

        // re-stake: `_reseat` must re-link tick 20 and make it reachable again
        mono.transfer(b, 5e18);
        vm.startPrank(b);
        mono.approve(address(auction), 5e18);
        auction.stake(5e18);
        vm.stopPrank();
        _checkList();
        address[] memory owners = new address[](3);
        owners[0] = a;
        owners[1] = b;
        owners[2] = c;
        _checkPositionsReachable(owners);

        vm.roll(block.number + 400);
        auction.sync(1);
        _checkList();
        _checkPositionsReachable(owners);
    }
}
