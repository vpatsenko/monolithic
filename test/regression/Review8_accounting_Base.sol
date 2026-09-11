// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GenerousAuction} from "../../src/GenerousAuction.sol";
import {Mono} from "../../src/Mono.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {IIndex} from "../../src/interfaces/IIndex.sol";
import {MockPool} from "../MockPool.sol";
import {TestERC20} from "../TestERC20.sol";

/// Review 8, accounting lens: shared harness. Real `Mono` (the sale token IS the stake token and
/// packs mint into the auction), `TestERC20` as INDEX (the real `Index` has no transfer override,
/// so the only thing the mock hides is the wrap path, which the auction never touches).
abstract contract Review8AccountingBase is Test {
    GenerousAuction internal auction;
    Mono internal mono;
    TestERC20 internal cur;
    MockPool internal pool;

    uint256 internal constant GENESIS = 1_000_000e18;
    uint256 internal constant FLOOR = 1e18;
    uint256 internal constant SPACING = 1e16;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant HALF = Q96 / 2;
    uint256 internal constant WINDOW = 8;
    uint64 internal constant K = 100;
    address internal constant ADMIN = address(0xF1);

    function _deploy(uint128 emission, uint64 end) internal {
        cur = new TestERC20("Index", "INDEX");
        mono = new Mono(IIndex(address(cur)), 10 * GENESIS);
        cur.mint(address(this), GENESIS);
        cur.approve(address(mono), GENESIS);
        mono.mint(GENESIS, GENESIS, address(this)); // NAV = 1.0
        pool = new MockPool(address(mono), address(cur), 1.25e18);
        mono.setPool(address(pool));
        auction = new GenerousAuction(
            IGenerousAuction.Config({
                token: address(mono),
                currency: address(cur),
                admin: ADMIN,
                floorPrice: FLOOR,
                tickSpacing: SPACING,
                decayQ: HALF,
                windowTicks: WINDOW,
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

    function _bid(address who, uint256 price, uint128 amount) internal {
        cur.mint(who, amount);
        vm.startPrank(who);
        cur.approve(address(auction), amount);
        auction.submitBid(price, amount, who, FLOOR);
        vm.stopPrank();
    }

    function _live(address who) internal view returns (uint256 l) {
        (l,) = auction.positionOf(who);
    }

    function _owed(address who) internal view returns (uint256 o) {
        (, o) = auction.positionOf(who);
    }

    /// Currency the contract holds beyond every position's live escrow and the unpacked delta
    /// the next `mintPack` will pull. Negative = the pot owes more than it has (a deficit that
    /// surfaces as a reverting withdraw or a reverting pack once escrow leaves).
    function _coverage(address[] memory owners) internal view returns (int256) {
        uint256 live;
        for (uint256 i; i < owners.length; ++i) {
            live += _live(owners[i]);
        }
        uint256 unpacked = auction.currencyRaised() - auction.currencyMinted();
        return int256(cur.balanceOf(address(auction))) - int256(live) - int256(unpacked);
    }

    /// MONO the contract holds beyond stake, minus what claimants are still owed by the ledger.
    function _monoSlack() internal view returns (int256) {
        uint256 held = mono.balanceOf(address(auction)) - auction.totalStaked();
        return int256(held) - int256(auction.tokensUnclaimed());
    }

    function _try(bytes memory data) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = address(auction).call(data);
    }
}
