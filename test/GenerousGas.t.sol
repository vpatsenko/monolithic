// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../src/GenerousAuction.sol";
import {Mono} from "../src/Mono.sol";
import {IGenerousAuction} from "../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../src/interfaces/IIndex.sol";
import {MockPool} from "./MockPool.sol";
import {TestERC20} from "./TestERC20.sol";

/// Gas shape of `sync`. Separates the three costs that scale differently:
///   - `_gather` + `_pour` compute, measured through the `previewWindow` view (no SSTOREs);
///   - the writeback in `_pourWindow`, measured as `sync` minus the view;
///   - the skip walk over empty ticks, which is the only unbounded stretch.
contract GenerousGasTest is Test {
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint64 internal constant K = 100;

    GenerousAuction internal auction;
    Mono internal mono;
    TestERC20 internal cur;

    uint256 internal constant GENESIS = 1_000_000e18;

    /// `q` chosen per window so `q^windowTicks` stays under the 1% MAX_EDGE_WEIGHT.
    /// @dev `emission` is the supply under test: the sale is not pre-funded, so one round of the
    ///      schedule *is* the draw. NAV opens at 1.0 = `FLOOR`, so every price on the grid bids.
    function _deploy(uint256 windowTicks, uint256 qNum, uint128 emission) internal {
        cur = new TestERC20("Index", "INDEX");
        mono = new Mono(IIndex(address(cur)), 10 * GENESIS);
        cur.mint(address(this), GENESIS);
        cur.approve(address(mono), GENESIS);
        mono.mint(GENESIS, GENESIS, address(this));
        // NAV opens at 1.0; 1.25 in the pool clears the 1500 bip premium gate.
        MockPool monoPool = new MockPool(address(mono), address(cur), 1.25e18);
        mono.setPool(address(monoPool));

        auction = new GenerousAuction(
            IGenerousAuction.Config({
                token: address(mono),
                currency: address(cur),
                admin: address(0xF1),
                floorPrice: FLOOR,
                tickSpacing: SPACING,
                decayQ: (Q96 * qNum) / 1000,
                windowTicks: windowTicks,
                startBlock: uint64(block.number),
                endBlock: 0,
                roundBlocks: K,
                emissionPerRound: emission,
                minPremiumBips: 1_500,
                previousAuction: address(0)
            })
        );
        mono.grantRole(mono.MINTER_ROLE(), address(auction));
        mono.renounceRole(mono.MINTER_ROLE(), address(this));
    }

    /// `n` live ticks, one grid step apart, `capTokens` of capacity each.
    function _book(uint256 n, uint256 capTokens) internal {
        for (uint256 i; i < n; ++i) {
            uint256 price = FLOOR + i * SPACING;
            uint256 prev = i == 0 ? FLOOR : FLOOR + (i - 1) * SPACING;
            uint128 amount = uint128((capTokens * price) / 1e18);
            address who = address(uint160(0x1000 + i));
            mono.transfer(who, 1e18);
            cur.mint(who, amount);
            vm.startPrank(who);
            mono.approve(address(auction), 1e18);
            auction.stake(1e18);
            cur.approve(address(auction), amount);
            auction.submitBid(price, amount, who, prev);
            vm.stopPrank();
        }
    }

    /// One window of `n` ticks, supply running out inside it (the ordinary case).
    function _run(uint256 n, uint256 qNum) internal returns (uint256 view_, uint256 settle_) {
        return _run(n, qNum, 5e18);
    }

    function _run(uint256 n, uint256 qNum, uint256 supplyPerTick) internal returns (uint256 view_, uint256 settle_) {
        _deploy(n == 1 ? 1 : n - 1, qNum, uint128(n * supplyPerTick));
        _book(n, 10e18);
        vm.roll(block.number + K);

        uint256 g = gasleft();
        auction.previewWindow();
        view_ = g - gasleft();

        g = gasleft();
        auction.sync(type(uint256).max);
        settle_ = g - gasleft();
        assertGt(auction.tokensSold(), 0, "benchmark must actually sell");
    }

    function test_gas_byWindowSize() public {
        // `q` is pinned by the window: MAX_EDGE_WEIGHT forces `q^(n-1) <= 1%`, so a narrow
        // window can only be paired with a steep decay.
        uint256[7] memory ns = [uint256(4), 8, 16, 32, 64, 128, 256];
        uint256[7] memory qs = [uint256(210), 510, 730, 860, 920, 964, 982];
        for (uint256 i; i < 7; ++i) {
            (uint256 v, uint256 s) = _run(ns[i], qs[i]);
            emit log_named_uint("--- live ticks", ns[i]);
            emit log_named_uint("  gather+pour (view)", v);
            emit log_named_uint("  settle total", s);
            emit log_named_uint("  per live tick", s / ns[i]);
        }
    }

    /// Worst case for the writeback: supply covers the whole book, so every tick clears whole and
    /// pays three SSTOREs (`demand`, `stakeSum`, `acc`).
    function test_gas_allTicksClear() public {
        (uint256 v, uint256 s) = _run(256, 982, 40e18);
        emit log_named_uint("256 ticks, all clear: gather+pour (view)", v);
        emit log_named_uint("256 ticks, all clear: settle total", s);
        emit log_named_uint("  per live tick", s / 256);
    }

    /// Marginal cost of an empty tick on the skip walk: bid at 200 high ticks, withdraw them all,
    /// then settle a book whose only live tick is the floor. `highestTick` stays at the top.
    function test_gas_skipWalk() public {
        _deploy(8, 500, 100e18);

        uint256 dead = 200;
        _book(dead + 1, 10e18);
        for (uint256 i = 1; i <= dead; ++i) {
            uint256 price = FLOOR + i * SPACING;
            vm.prank(address(uint160(0x1000 + i)));
            auction.withdrawBid();
        }

        vm.roll(block.number + K);
        uint256 g = gasleft();
        auction.sync(type(uint256).max);
        uint256 used = g - gasleft();
        assertEq(auction.settleCursor(), 0, "the walk must complete");
        assertGt(auction.tokensSold(), 0, "the floor tick must be reached and served");
        emit log_named_uint("skip 200 empty ticks + 1 live, settle total", used);
        emit log_named_uint("  approx per empty tick", used / dead);
    }

    /// `settle(1000)` against the worst book for it: a dense run of live ticks, `windowTicks = 255`,
    /// supply covering everything so no window drains early.
    function test_gas_maxTicks1000_dense() public {
        uint256 n = 1300;
        _deploy(255, 982, uint128(n * 40e18));
        _book(n, 10e18);
        vm.roll(block.number + K);

        uint256 g = gasleft();
        auction.sync(1000);
        emit log_named_uint("dense 1300-tick book, settle(1000)", g - gasleft());
        emit log_named_string("sweptWholeBook", auction.settleCursor() == 0 ? "true" : "false");
        emit log_named_uint("settleCursor", auction.settleCursor());
    }

    /// `settle(1000)` where the budget is spent entirely on dead ticks.
    function test_gas_maxTicks1000_dead() public {
        _deploy(8, 500, 100e18);
        uint256 dead = 1200;
        _book(dead + 1, 10e18);
        for (uint256 i = 1; i <= dead; ++i) {
            vm.prank(address(uint160(0x1000 + i)));
            auction.withdrawBid();
        }
        vm.roll(block.number + K);

        uint256 g = gasleft();
        auction.sync(1000);
        emit log_named_uint("1200 dead ticks, settle(1000)", g - gasleft());
        emit log_named_string("sweptWholeBook", auction.settleCursor() == 0 ? "true" : "false");
        emit log_named_uint("settleCursor", auction.settleCursor());
    }

    /// What one caller can afford: how many empty ticks fit under a 30M block.
    function test_gas_budgetCeiling() public {
        _deploy(8, 500, 100e18);
        _book(1, 10e18);
        vm.roll(block.number + K);

        uint256 g = gasleft();
        auction.sync(type(uint256).max);
        emit log_named_uint("single live tick at floor, settle total", g - gasleft());
    }
}
