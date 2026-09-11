// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../../src/interfaces/IIndex.sol";
import {MockPool} from "../MockPool.sol";
import {TestERC20} from "../TestERC20.sol";

/// ROUND 14, lens `splice`: the rest of the round-9 `mark` hypotheses, each driven to the state
/// it names. All of these come back NEGATIVE — the mark holds — and they are here so the state
/// space that was actually driven is on the record next to the one hole that did open
/// (`Review14_splice_resumeMark.t.sol`).
contract Review14SpliceEdgesTest is Test {
    GenerousAuction internal auction;
    Mono internal mono;
    TestERC20 internal cur;

    uint256 internal constant GENESIS = 1_000_000e18;
    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint256 internal constant Q96 = 1 << 96;

    function _deploy(uint256 decayQ, uint256 windowTicks, uint128 emission) internal {
        cur = new TestERC20("Index", "INDEX");
        mono = new Mono(IIndex(address(cur)), 10 * GENESIS);
        cur.mint(address(this), GENESIS);
        cur.approve(address(mono), GENESIS);
        mono.mint(GENESIS, GENESIS, address(this));
        MockPool pool = new MockPool(address(mono), address(cur), 1.25e18);
        mono.setPool(address(pool));
        auction = new GenerousAuction(
            IGenerousAuction.Config({
                token: address(mono),
                currency: address(cur),
                admin: address(0xF1),
                floorPrice: FLOOR,
                tickSpacing: SPACING,
                decayQ: decayQ,
                windowTicks: windowTicks,
                startBlock: uint64(block.number),
                endBlock: 0,
                roundBlocks: 100,
                emissionPerRound: emission,
                minPremiumBips: 1_500,
                previousAuction: address(0)
            })
        );
        mono.grantRole(mono.MINTER_ROLE(), address(auction));
        mono.renounceRole(mono.MINTER_ROLE(), address(this));
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

    function _bid(address who, uint256 price, uint128 amount, uint256 hint) internal {
        vm.prank(who);
        auction.submitBid(price, amount, who, hint);
    }

    function _linked(uint256 price) internal view returns (bool) {
        if (price == FLOOR) return true;
        (, uint256 pv,,,,,) = auction.ticks(price);
        (uint256 pvNext,,,,,,) = auction.ticks(pv);
        return pvNext == price;
    }

    function _cap(uint256 price) internal view returns (uint256 c) {
        (,, c,,,,) = auction.ticks(price);
    }

    // ---------------------------------------------------------------- H1: the `wt == 0` break

    /// THE SHARPEST HYPOTHESIS IN THE LENS. `_gather` and `_extend` both `break` when `q^d`
    /// rounds to zero, and BOTH leave `w.resume` sitting on the LIVE tick they refused to admit
    /// (the `break` is before `price = t.prev`). So on a dry window `mark = w.resume` is the
    /// price of a tick with capacity.
    ///
    /// Driven with `decayQ = 1` (a legal deploy: `rpow(1, 8, Q96) == 0 <= Q96/100`), where
    /// `_weight(1) == 1` and `_weight(2) == 0`, so the break fires at d = 2 on the FIRST gather.
    ///
    /// NEGATIVE: `_splice(hi, lo)` unlinks the run STRICTLY between its endpoints, so the live
    /// `w.resume` survives as `lo` and becomes both the new `highestTick` and the next window's
    /// start. The claim "everything strictly between is dead" is not violated by this break.
    function test_H1_zeroWeightBreakKeepsTheLiveResumeLinked() public {
        _deploy(1, 8, 40e18);
        address a = address(0xA1);
        address b = address(0xA2);
        address c = address(0xA3);
        uint256 pa = FLOOR + 50 * SPACING;
        uint256 pb = FLOOR + 49 * SPACING; // d = 1, weight 1 (of Q96)
        uint256 pc = FLOOR + 48 * SPACING; // d = 2, weight 0 -> the break

        _fund(a, 10e18, 1_000e18);
        _fund(b, 10e18, 1_000e18);
        _fund(c, 10e18, 1_000e18);
        _bid(c, pc, 100e18, FLOOR);
        _bid(b, pb, 3, pc);
        _bid(a, pa, 3, pb);

        assertEq(auction.weightAt(1), 1, "H1: _weight(1) != 1");
        assertEq(auction.weightAt(2), 0, "H1: _weight(2) != 0 -- the break does not fire");
        emit log_named_uint("H1 cap(a) [d=0]", _cap(pa));
        emit log_named_uint("H1 cap(b) [d=1]", _cap(pb));
        emit log_named_uint("H1 cap(c) [d=2, the resume tick]", _cap(pc));

        vm.roll(block.number + 100);
        auction.sync(1_000);

        emit log_named_uint("H1 after: cap(c)", _cap(pc));
        emit log_named_uint("H1 after: highestTick step", (auction.highestTick() - FLOOR) / SPACING);
        emit log_named_uint("H1 after: c linked", _linked(pc) ? 1 : 0);
        emit log_named_uint("H1 after: b linked", _linked(pb) ? 1 : 0);
        emit log_named_uint("H1 after: tokensSold", auction.tokensSold());

        assertTrue(_linked(pc), "H1: the live zero-weight resume tick was unlinked");
        assertGe(auction.highestTick(), pc, "H1: high-water shaved below the resume tick");
    }

    // ---------------------------------------------------------------- H2: whale INSIDE the band

    /// The same three caps as the finding (2 wei / 1 wei / 1e24) but with the whale INSIDE the
    /// gathered band, so `_extend` is never involved: the whale is keyed at
    /// `capK = min(cap, supply)` in `_solveInit`, entry 0.
    ///
    /// NEGATIVE, and the reason is the mechanism: with `entry == 0` the whale's `kappa` target is
    /// the WHOLE supply, so reaching it needs every wei the dust rungs already took, `dT >= left`
    /// binds, and `drained` latches -> `mark = w.tau`. Only `_extend`'s `reach = min(dem, left)`
    /// (a target that EXCLUDES what was already poured) makes the target reachable a wei early.
    function test_H2_whaleInsideTheBandDrainsAndStaysLinked() public {
        _deploy(Q96 / 2, 8, 40e18);
        address a = address(0xA1);
        address b = address(0xA2);
        address w = address(0xA3);
        uint256 pa = FLOOR + 93 * SPACING;
        uint256 pb = FLOOR + 89 * SPACING; // d = 4
        uint256 pw = FLOOR + 86 * SPACING; // d = 7 -- inside the 8-step band

        _fund(a, 10e18, 1_000e18);
        _fund(b, 10e18, 1_000e18);
        _fund(w, 10e18, 4e24);
        _bid(w, pw, 1.86e24, FLOOR);
        _bid(b, pb, 2, pw);
        _bid(a, pa, 4, pb);
        assertEq(_cap(pa), 2, "H2: cap(a) != 2");
        assertEq(_cap(pb), 1, "H2: cap(b) != 1");

        vm.roll(block.number + 100);
        auction.sync(1_000);

        emit log_named_uint("H2 after: cap(whale)", _cap(pw));
        emit log_named_uint("H2 after: whale linked", _linked(pw) ? 1 : 0);
        emit log_named_uint("H2 after: highestTick step", (auction.highestTick() - FLOOR) / SPACING);
        assertTrue(_linked(pw), "H2: the in-band whale was unlinked");
        assertEq(auction.highestTick(), pw, "H2: high-water is not the whale (drained -> mark = w.tau)");

        uint256 sold1 = auction.tokensSold();
        vm.roll(block.number + 100);
        auction.sync(1_000);
        emit log_named_uint("H2 sold in round 2", auction.tokensSold() - sold1);
        assertGt(auction.tokensSold() - sold1, 39e18, "H2: the sale stalled");
    }

    // ---------------------------------------------------------------- H3: pause inside a tick

    /// `_pourTick` hits the 128-death budget mid-tick, `_pourWindow` breaks with `pausedAt` set
    /// and restores `w.tau = top0`, so the ternary takes the conservative arm. Ticks BELOW the
    /// paused one were never poured at all and must all still be linked and hold their capacity.
    ///
    /// NEGATIVE: they are. 200 seats at the top tick force the pause; the two funded ticks under
    /// it come out of the sync untouched, linked, with the cursor parked at or above them.
    function test_H3_deathBudgetPauseKeepsEverythingBelowLinked() public {
        _deploy(Q96 / 2, 8, 4_000e18);
        uint256 pTop = FLOOR + 40 * SPACING;
        uint256 pMid = FLOOR + 39 * SPACING;
        uint256 pLow = FLOOR + 38 * SPACING;

        address mid = address(0xC1);
        address low = address(0xC2);
        _fund(mid, 10e18, 1_000e18);
        _fund(low, 10e18, 1_000e18);
        _bid(low, pLow, 200e18, FLOOR);
        _bid(mid, pMid, 200e18, pLow);

        // DISTINCT kappas: identical seats all exhaust at one index step and `_pourTick` ends on
        // the `dT >= left` branch with ZERO pops, which never reaches the death budget.
        for (uint256 i; i < 160; ++i) {
            address s = address(uint160(0xD000 + i));
            _fund(s, 1e18, 10e18);
            _bid(s, pTop, uint128(1e18 + i * 1e15), pMid);
        }

        vm.roll(block.number + 100);
        auction.sync(1_000);

        emit log_named_uint(
            "H3 settleCursor step", auction.settleCursor() == 0 ? 9999 : (auction.settleCursor() - FLOOR) / SPACING
        );
        emit log_named_uint("H3 highestTick step", (auction.highestTick() - FLOOR) / SPACING);
        emit log_named_uint("H3 cap(top)", _cap(pTop));
        emit log_named_uint("H3 cap(mid)", _cap(pMid));
        emit log_named_uint("H3 cap(low)", _cap(pLow));
        emit log_named_uint("H3 mid linked", _linked(pMid) ? 1 : 0);
        emit log_named_uint("H3 low linked", _linked(pLow) ? 1 : 0);

        assertTrue(auction.settleCursor() != 0, "H3: the sweep did not pause -- the shape was not reached");
        assertTrue(_linked(pMid), "H3: an un-poured tick under the pause was unlinked");
        assertTrue(_linked(pLow), "H3: an un-poured tick under the pause was unlinked");
        assertGt(_cap(pMid), 0, "H3: mid lost its capacity");
        assertGt(_cap(pLow), 0, "H3: low lost its capacity");
        assertGe(auction.highestTick(), pTop, "H3: high-water shaved under the paused band");
    }
}
