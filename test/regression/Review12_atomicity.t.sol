// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Review7ConfigBase} from "./Review7_config_Base.sol";
import {IGenerousAuction} from "../../src/interfaces/IGenerousAuction.sol";
import {IMono} from "../../src/interfaces/IMono.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

contract Review12Atomicity is Review7ConfigBase {
    error InjectedMintFailure();

    function setUp() public {
        _freshMono();
        IGenerousAuction.Config memory c = _defaultConfig();
        c.endBlock = c.startBlock + 101; // one block past a whole round: a life of exactly one round is refused
        _deployWith(c);
        _stakeFor(aa, 3e18);
        _stakeFor(bb, 7e18);
        _bid(aa, 1e18, 500e18, 1e18);
        _bid(bb, 1e18, 500e18, 1e18);
        vm.roll(c.startBlock + 50);
    }

    // Capture the observable auction book, accounting, balances and Mono supply around
    // calls which fail AFTER the implicit settlement or mint accounting has run.
    function _read(bytes memory input) internal view returns (bytes memory output) {
        bool ok;
        (ok, output) = address(auction).staticcall(input);
        assertTrue(ok);
    }

    function _digest() internal view returns (bytes32) {
        bytes32 accounting = keccak256(
            abi.encode(
                auction.tokensSold(),
                auction.tokensBooked(),
                auction.tokensMinted(),
                auction.tokensUnclaimed(),
                auction.currencyRaised(),
                auction.currencyMinted(),
                auction.totalStaked(),
                auction.finalized(),
                auction.settleCursor(),
                auction.highestTick()
            )
        );
        bytes32 book = keccak256(
            abi.encode(
                _read(abi.encodeWithSignature("ticks(uint256)", 1e18)),
                _read(abi.encodeWithSignature("positions(address)", aa)),
                _read(abi.encodeWithSignature("positions(address)", bb)),
                auction.stakes(aa),
                auction.stakes(bb)
            )
        );
        return keccak256(
            abi.encode(
                accounting,
                book,
                cur.balanceOf(address(auction)),
                cur.balanceOf(address(mono)),
                cur.balanceOf(aa),
                cur.balanceOf(bb),
                mono.balanceOf(address(auction)),
                mono.balanceOf(aa),
                mono.balanceOf(bb),
                mono.totalSupply()
            )
        );
    }

    function test_failedBidTransferRollsBackImplicitSettlement() public {
        bytes memory transfer =
            abi.encodeWithSignature("transferFrom(address,address,uint256)", bb, address(auction), 1e18);
        vm.mockCall(address(cur), transfer, abi.encode(false));
        bytes32 beforeState = _digest();
        vm.prank(bb);
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        auction.submitBid(1e18, 1e18, bb, 1e18);
        assertEq(_digest(), beforeState, "failed funding changed the book");
        vm.clearMockedCalls();
        _bid(bb, 1e18, 1e18, 1e18);
        assertEq(auction.tokensSold(), 50e18, "retry settles the same pending emission once");
    }

    function test_failedWithdrawTransferRestoresPositionAndSeat() public {
        vm.mockCall(address(cur), abi.encodeWithSignature("transfer(address,uint256)", aa, 485e18), abi.encode(false));
        bytes32 beforeState = _digest();
        vm.prank(aa);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        auction.withdrawBid();
        assertEq(_digest(), beforeState, "failed refund removed escrow or changed the heap");
        vm.clearMockedCalls();
        vm.prank(aa);
        assertEq(auction.withdrawBid(), 485e18);
        assertEq(auction.claim(aa), 15e18);
    }

    function test_failedClaimTransferRollsBackPackAndHarvest() public {
        vm.mockCall(address(mono), abi.encodeWithSignature("transfer(address,uint256)", aa, 15e18), abi.encode(false));
        bytes32 beforeState = _digest();
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        auction.claim(aa);
        assertEq(_digest(), beforeState, "failed payout consumed entitlement or minted a pack");
        vm.clearMockedCalls();
        assertEq(auction.claim(aa), 15e18);
        assertEq(auction.claim(aa), 0, "retry cannot pay twice");
    }

    function test_nonRoleMintFailureCannotFinalizeOrConsumeEscrow() public {
        vm.roll(auction.endBlock());
        vm.mockCallRevert(
            address(mono),
            abi.encodeWithSelector(IMono.mint.selector),
            abi.encodeWithSelector(InjectedMintFailure.selector)
        );
        bytes32 beforeState = _digest();
        vm.expectRevert(InjectedMintFailure.selector);
        auction.finalize(128);
        assertEq(_digest(), beforeState, "failed final pack finalized or consumed the tail");
        vm.clearMockedCalls();
        assertTrue(auction.finalize(128));
        assertEq(auction.currencyMinted(), auction.currencyRaised());
    }

    function test_revokedRoleUnlocksStakeAndRestoredRoleRecoversClaims() public {
        mono.revokeRole(mono.MINTER_ROLE(), address(auction));
        vm.roll(auction.endBlock());
        assertTrue(auction.finalize(128));
        assertEq(auction.tokensMinted(), 0);
        assertGt(auction.currencyRaised(), 0);
        vm.prank(aa);
        auction.unstake(3e18);
        vm.prank(bb);
        auction.unstake(7e18);
        assertEq(auction.totalStaked(), 0);
        mono.grantRole(mono.MINTER_ROLE(), address(auction));
        uint256 paid = auction.claim(aa) + auction.claim(bb);
        assertEq(paid, auction.tokensMinted(), "unlocked stakes must not erase unpaid claims");
        assertGe(paid, 100e18 - 2);
        assertEq(mono.balanceOf(address(auction)), 0);
    }
}
