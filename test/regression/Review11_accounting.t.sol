// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Review7ConfigBase} from "./Review7_config_Base.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";

contract Review11Accounting is Review7ConfigBase {
    uint256 internal claimed;
    address[6] internal users;

    function _check() internal view {
        uint256 live;
        uint256 staked;
        for (uint256 i; i < users.length; ++i) {
            (uint256 amount,) = auction.positionOf(users[i]);
            live += amount;
            staked += auction.stakes(users[i]);
        }
        uint256 unpaid = auction.currencyRaised() - auction.currencyMinted();
        assertGe(cur.balanceOf(address(auction)), live + unpaid, "escrow plus unpacked proceeds exceed currency");
        assertEq(auction.totalStaked(), staked, "stake ledger disagrees with owners");
        assertEq(
            mono.balanceOf(address(auction)),
            staked + auction.tokensMinted() - claimed,
            "minted tokens or stake disappeared"
        );
        assertLe(auction.tokensMinted(), auction.tokensBooked());
        assertLe(auction.tokensBooked(), auction.tokensSold());
        assertLe(auction.tokensSold(), auction.saleSupply());
    }

    function testFuzz_mixedScaleOwnerLifecycle(uint256 seed) public {
        _freshMono();
        IGenerousAuction.Config memory c = _defaultConfig();
        c.admin = address(this);
        _deployWith(c);
        uint256[6] memory stakeSizes = [uint256(1), 7, 1e9, 1e15, 1e18, 10_000e18];
        for (uint256 i; i < users.length; ++i) {
            users[i] = address(uint160(0x22000 + i));
            _stakeFor(users[i], stakeSizes[i]);
        }

        for (uint256 step; step < 160; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            address who = users[(r >> 8) % users.length];
            uint256 op = r % 8;
            if (op == 0) {
                vm.roll(block.number + 1 + ((r >> 16) % 300));
            } else if (op == 1) {
                auction.sync(128);
            } else if (op == 2) {
                claimed += auction.claim(who);
            } else if (op == 3) {
                vm.prank(who);
                claimed += auction.claimAndStake();
            } else if (op == 4) {
                (uint256 live,) = auction.positionOf(who);
                if (live != 0) {
                    vm.prank(who);
                    try auction.withdrawBid() {}
                    catch (bytes memory reason) {
                        assertEq(bytes4(reason), IGenerousAuction.NoPosition.selector, "withdrawal unexpectedly failed");
                    }
                }
            } else if (op == 5) {
                uint256 s = auction.stakes(who);
                if (s != 0) {
                    vm.prank(who);
                    auction.unstake(1 + ((r >> 16) % s));
                }
            } else if (op == 6) {
                _stakeFor(who, stakeSizes[(r >> 16) % stakeSizes.length]);
            } else if (auction.stakes(who) != 0) {
                (uint256 oldPrice,,,,,,) = auction.positions(who);
                (uint256 live,) = auction.positionOf(who);
                uint256[6] memory priceLevels = [uint256(1e18), 1.01e18, 1.07e18, 2e18, 100e18, 10_000e18];
                uint256 price = live != 0 ? oldPrice : priceLevels[(r >> 16) % priceLevels.length];
                if (price >= mono.nav()) {
                    uint256[4] memory amounts = [uint256(1), 1001, 1e18, 1000e18];
                    uint256 amount = amounts[(r >> 24) % amounts.length];
                    uint256 minAmount = (price + 1e18 - 1) / 1e18;
                    if (amount < minAmount) amount = minAmount;
                    _bid(who, price, uint128(amount), 1e18);
                }
            }
            _check();
        }
    }
}
