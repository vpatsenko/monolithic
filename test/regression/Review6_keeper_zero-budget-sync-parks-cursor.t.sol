// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../../src/interfaces/IIndex.sol";
import {MockPool} from "../MockPool.sol";
import {TestERC20} from "../TestERC20.sol";

/// Review 6 / keeper-attacker lens.
///
/// `sync(0)` does no work at all — `_sync`'s `while (... steps < maxTicks)` never runs — yet
/// its epilogue `settleCursor = (drained || supply == 0 || price == 0) ? 0 : price;` parks the
/// cursor on `highestTick` whenever at least one wei of emission has accrued. That makes
/// `_settled()` false, and `submitBid` FAST-FAILS on `_requireSettled()` BEFORE its own implicit
/// sync gets a chance to clear the cursor (GenerousAuction.sol, submitBid: `_requireSettled();
/// _sync(SYNC_TICKS); _requireSettled();`). One ~30k-gas call per block, from anyone, and no
/// new bid or top-up can enter the book unless it is bundled atomically with a real sync.
/// `stake`/`unstake`/`withdrawBid` sync FIRST and are unaffected — so this is a bid-only DoS.
contract Review6KeeperZeroBudgetTest is Test {
    GenerousAuction internal auction;
    Mono internal mono;
    TestERC20 internal cur;

    uint256 internal constant GENESIS = 1_000_000e18;
    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant HALF = Q96 / 2;
    uint64 internal constant K = 100;
    uint128 internal constant R = 100e18;

    address internal honest = address(0xA1);
    address internal newcomer = address(0xA2);
    address internal griefer = address(0xC1);

    function setUp() public {
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
                windowTicks: 8,
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

        _stakeFor(honest, 1e18);
        _bid(honest, FLOOR, 1_000e18, FLOOR);
        _stakeFor(newcomer, 1e18);
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

    /// A zero-budget sync is raised to the implicit budget: it clears the one-tick book instead
    /// of parking the cursor, and the next bid lands.
    function test_zeroBudgetSyncBlocksBids() public {
        vm.roll(block.number + 1); // one block: 1e18 accrued, book untouched
        assertEq(auction.settleCursor(), 0);

        vm.prank(griefer);
        auction.sync(0);
        emit log_named_uint("settleCursor after sync(0)", auction.settleCursor());
        emit log_named_uint("tokensSold after sync(0)", auction.tokensSold());
        assertGt(auction.tokensSold(), 0, "sync(0) did the work of a sync(128)");
        assertEq(auction.settleCursor(), 0, "and left nothing parked");

        // The bid's implicit sync (SYNC_TICKS = 128) would clear this one-tick book. It never
        // gets to run: the fast-fail fires first.
        cur.mint(newcomer, 100e18);
        vm.startPrank(newcomer);
        cur.approve(address(auction), 100e18);
        (bool ok, bytes memory ret) =
            address(auction).call(abi.encodeCall(IGenerousAuction.submitBid, (FLOOR, 100e18, newcomer, FLOOR)));
        vm.stopPrank();
        if (!ok) {
            assertEq(bytes4(ret), IGenerousAuction.SettleFirst.selector, "reverted with SettleFirst");
        }
        assertTrue(ok, "a bid must not be blocked by a sync that did no work");
    }

    /// The griefing loop over 20 rounds: every block the griefer calls `sync(0)` right after an
    /// honest sync, every round the newcomer bids. Nothing is ever parked, nothing is blocked.
    function test_griefLoopTwentyRounds() public {
        uint256 blocked;
        for (uint256 r; r < 20; ++r) {
            vm.roll(block.number + K);
            // Someone honest settles the book...
            auction.sync(1000);
            assertEq(auction.settleCursor(), 0);
            // ...the griefer re-parks in the same block (any accrual works; here emission
            // accrues per block so the next block has 1e18 due again).
            vm.roll(block.number + 1);
            vm.prank(griefer);
            auction.sync(0);
            assertEq(auction.settleCursor(), 0, "a floored sync cannot park a one-tick book");
            cur.mint(newcomer, 1e18);
            vm.startPrank(newcomer);
            cur.approve(address(auction), 1e18);
            (bool ok,) =
                address(auction).call(abi.encodeCall(IGenerousAuction.submitBid, (FLOOR, 1e18, newcomer, FLOOR)));
            vm.stopPrank();
            if (!ok) ++blocked;
            // A bidless stake by the same wallet is fine — it syncs first, so the park is gone.
            _stakeFor(newcomer, 1);
            assertEq(auction.settleCursor(), 0, "stake's implicit sync cleared the park");
        }
        emit log_named_uint("bids blocked out of 20", blocked);
        assertEq(blocked, 0, "no bid attempt was blocked");
        (, uint256 owed) = auction.positionOf(newcomer);
        assertGt(owed, 0, "newcomer entered the book and was filled");
    }
}
