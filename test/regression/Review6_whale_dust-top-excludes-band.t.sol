// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../../src/interfaces/IIndex.sol";
import {MockPool} from "../MockPool.sol";
import {TestERC20} from "../TestERC20.sol";

/// Review 6 / whale lens — strategic bot simulation.
///
/// Strategy under test: the WHALE stands one tick above the honest crowd (P1 vs P0) and, before
/// every sync, re-arms a 2-wei "dust top" bid exactly `windowTicks` grid steps above its own
/// tick (P9). `_gather` (GenerousAuction.sol, step 2) collects the fixed band
/// `[tau - windowTicks*tickSpacing, tau]` = [P1, P9], so the honest tick P0 falls OUTSIDE the
/// window. The dust dies after 1 wei, its share re-flows to the band SURVIVORS only (`_pour`
/// waterfall), the whale absorbs everything, `drained = dry < w.n` is true and the sweep stops
/// (`_sync`: `if (drained) break;`) — P0 is never poured.
///
/// Control: same book without the dust. Both runs: 20 block-linear rounds, honest keeper syncs
/// once per round, honest stakers are passive.
contract Review6WhaleDustTopTest is Test {
    GenerousAuction internal auction;
    Mono internal mono;
    TestERC20 internal cur;

    uint256 internal constant GENESIS = 1_000_000e18;
    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant HALF = Q96 / 2;
    uint64 internal constant K = 100;
    uint128 internal constant R = 100e18; // 1 token per block
    uint256 internal constant WINDOW = 8;
    uint256 internal constant ROUNDS = 20;

    address[4] internal honest = [address(0xA1), address(0xA2), address(0xA3), address(0xA4)];
    address internal whale = address(0xB1);
    address internal dust = address(0xB2);

    function _p(uint256 d) internal pure returns (uint256) {
        return FLOOR + d * SPACING;
    }

    function _deploy() internal {
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
                decayQ: HALF,
                windowTicks: WINDOW,
                startBlock: uint64(block.number),
                endBlock: 0,
                roundBlocks: K,
                emissionPerRound: R,
                minPremiumBips: 1_500,
                previousAuction: address(0)
            })
        );
        mono.grantRole(mono.MINTER_ROLE(), address(auction));
        mono.renounceRole(mono.MINTER_ROLE(), address(this));
        assertGe(auction.saleSupply(), ROUNDS * uint256(R) * 2, "sale big enough for the sim");
    }

    function _stakeFor(address who, uint256 amt) internal {
        mono.transfer(who, amt);
        vm.startPrank(who);
        mono.approve(address(auction), amt);
        auction.stake(amt);
        vm.stopPrank();
    }

    function _bid(address who, uint256 price, uint128 amount, uint256 prev) internal {
        cur.mint(who, amount);
        vm.startPrank(who);
        cur.approve(address(auction), amount);
        auction.submitBid(price, amount, who, prev);
        vm.stopPrank();
    }

    function _owed(address who) internal view returns (uint256 owed) {
        (, owed) = auction.positionOf(who);
    }

    function _honestOwed() internal view returns (uint256 sum) {
        for (uint256 i; i < honest.length; ++i) {
            sum += _owed(honest[i]);
        }
    }

    /// The common book: four honest stakers (25 MONO each) at P0 with ample escrow, the whale at
    /// P1 with a SMALL stake (1 MONO) and ample escrow.
    function _book() internal {
        for (uint256 i; i < honest.length; ++i) {
            _stakeFor(honest[i], 25e18);
            _bid(honest[i], _p(0), 5_000e18, FLOOR);
        }
        _stakeFor(whale, 1e18);
        _bid(whale, _p(1), 5_000e18, _p(0));
    }

    function _run(bool withDust) internal returns (uint256 whaleTokens, uint256 honestTokens) {
        _deploy();
        _book();
        if (withDust) {
            // 1000 wei of stake, 2 wei of escrow: cap = 2e18 / 1.09e18 = 1 token-wei.
            _stakeFor(dust, 1000);
            _bid(dust, _p(1 + WINDOW), 2, _p(1));
        }
        for (uint256 r; r < ROUNDS; ++r) {
            vm.roll(block.number + K);
            auction.sync(1000); // honest keeper: one sync per round
            if (withDust) {
                // Re-arm: the dust died (1 wei) in that sync; top it up 2 wei for the next one.
                _bid(dust, _p(1 + WINDOW), 2, _p(1));
            }
        }
        whaleTokens = _owed(whale);
        honestTokens = _honestOwed();
    }

    /// Control pins the q-curve: whale (weight 1) 2/3, honest tick (weight q) 1/3.
    function test_control_qCurveSplitsTwoToOne() public {
        (uint256 w, uint256 h) = _run(false);
        uint256 total = ROUNDS * uint256(R);
        assertApproxEqAbs(w, (total * 2) / 3, 1e6, "whale gets 1/(1+q) of the emission");
        assertApproxEqAbs(h, total / 3, 1e6, "honest tick gets q/(1+q)");
        emit log_named_uint("control whale tokens", w);
        emit log_named_uint("control honest tokens", h);
    }

    /// A 2-wei dust bid parked `windowTicks` steps above the whale dies on the first wei of
    /// every pour; the sweep re-anchors on the whale's tick and the honest tick keeps its
    /// q/(1+q) share. The dust buys the whale nothing.
    function test_strategy_dustTopStarvesHonestTick() public {
        (uint256 wc, uint256 hc) = _run(false);
        (uint256 ws, uint256 hs) = _run(true);
        emit log_named_uint("control  whale tokens", wc);
        emit log_named_uint("control  honest tokens", hc);
        emit log_named_uint("strategy whale tokens", ws);
        emit log_named_uint("strategy honest tokens", hs);
        emit log_named_uint("strategy dust tokens", _owed(dust));
        emit log_named_int("whale excess tokens vs control", int256(ws) - int256(wc));
        // The doc's MAX_EDGE_WEIGHT argument says the tick past the edge loses < 1% of its
        // share. Here it loses all of it.
        assertGe(hs * 100, hc * 99, "honest tick past the dust-made edge should lose < 1%");
        assertLe(ws, wc, "the dust buys the whale nothing");
    }
}
