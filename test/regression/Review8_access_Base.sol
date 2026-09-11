// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../../src/interfaces/IIndex.sol";
import {MockPool} from "../MockPool.sol";
import {TestERC20} from "../TestERC20.sol";

/// Shared harness for the round-8 `access` lens. Same deployment shape as
/// test/GenerousStaking.t.sol: Index/Mono at NAV 1.0, pool at 1.25, floor 1e18, spacing 1e16,
/// q = Q96/2, windowTicks 8, roundBlocks 100.
abstract contract Review8AccessBase is Test {
    GenerousAuction internal auction;
    Mono internal mono;
    TestERC20 internal cur;

    uint256 internal constant GENESIS = 1_000_000e18;
    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant HALF = Q96 / 2;
    uint64 internal constant K = 100;
    address internal constant ADMIN = address(0xF1);

    uint256 internal constant P0 = FLOOR;
    uint256 internal constant P1 = FLOOR + SPACING;
    uint256 internal constant P2 = FLOOR + 2 * SPACING;
    uint256 internal constant P3 = FLOOR + 3 * SPACING;
    uint256 internal constant P4 = FLOOR + 4 * SPACING;
    uint256 internal constant P5 = FLOOR + 5 * SPACING;

    function _deploy(uint128 emission, uint64 end) internal {
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
                admin: ADMIN,
                floorPrice: FLOOR,
                tickSpacing: SPACING,
                decayQ: HALF,
                windowTicks: 8,
                startBlock: uint64(block.number),
                endBlock: end,
                roundBlocks: K,
                emissionPerRound: emission,
                minPremiumBips: 1_500,
                previousAuction: address(0)
            })
        );
        mono.grantRole(mono.MINTER_ROLE(), address(auction));
        mono.renounceRole(mono.MINTER_ROLE(), address(this));
    }

    function _stakeFor(address who, uint256 amt) internal {
        mono.transfer(who, amt);
        vm.startPrank(who);
        mono.approve(address(auction), amt);
        auction.stake(amt);
        vm.stopPrank();
    }

    /// `who` funds and owns the bid.
    function _bid(address who, uint256 price, uint128 amount, uint256 prev) internal {
        _bidFor(who, who, price, amount, prev);
    }

    /// `payer` funds the escrow, `owner` controls the position — the third-party path.
    function _bidFor(address payer, address owner, uint256 price, uint128 amount, uint256 prev) internal {
        cur.mint(payer, amount);
        vm.startPrank(payer);
        cur.approve(address(auction), amount);
        auction.submitBid(price, amount, owner, prev);
        vm.stopPrank();
    }

    function _owed(address who) internal view returns (uint256 owed) {
        (, owed) = auction.positionOf(who);
    }

    function _live(address who) internal view returns (uint256 live) {
        (live,) = auction.positionOf(who);
    }

    function _price(address who) internal view returns (uint256 price) {
        (price,,,,,,) = auction.positions(who);
    }

    function _cap(uint256 price) internal view returns (uint256 cap) {
        (,, cap,,,,) = auction.ticks(price);
    }

    function _next(uint256 price) internal view returns (uint256 nx) {
        (nx,,,,,,) = auction.ticks(price);
    }

    function _prev(uint256 price) internal view returns (uint256 pv) {
        (, pv,,,,,) = auction.ticks(price);
    }

    function _round() internal {
        vm.roll(block.number + K);
        auction.sync(64);
    }

    /// True when `price` is visited by the sweep's own walk: `prev` from `highestTick` down.
    function _sweepReaches(uint256 price) internal view returns (bool) {
        uint256 p = auction.highestTick();
        for (uint256 i; i < 64 && p != 0; ++i) {
            if (p == price) return true;
            p = _prev(p);
        }
        return false;
    }

    /// True when `price` is visited by the hint walk: `next` from the floor up.
    function _nextChainReaches(uint256 price) internal view returns (bool) {
        uint256 p = FLOOR;
        for (uint256 i; i < 64 && p != 0; ++i) {
            if (p == price) return true;
            p = _next(p);
        }
        return false;
    }
}
