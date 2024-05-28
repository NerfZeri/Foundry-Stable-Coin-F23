//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {Dsc} from "../../src/Dsc.sol";

contract DscTest is Test {
    Dsc dsc;

    function setUp() external {
        dsc = new Dsc();
    }

    function testBurnRevertsIfAmountIsZero() public {
        vm.startPrank(dsc.owner());
        dsc.mint(address(this), 100);
        vm.expectRevert(Dsc.DSC__MustBeMoreThanZero.selector);
        dsc.burn(0);
        vm.stopPrank();
    }

    function testBurnRevertsIfAmountExceedsBalance() public {
        vm.prank(dsc.owner());
        vm.expectRevert(Dsc.DSC__BurnExceedsBalance.selector);
        dsc.burn(1);
    }

    function testBurnorksIfCorrect() public {
        vm.startPrank(dsc.owner());
        dsc.mint(address(this), 100);
        dsc.burn(90);
        vm.stopPrank();
    }

    function testMintRevertsIfNotOwner() public {
        vm.prank(msg.sender);
        vm.expectRevert();
        dsc.mint(address(this), 100);
    }

    function testMintRevertsToZeroAddress() public {
        vm.startPrank(dsc.owner());
        vm.expectRevert(Dsc.DSC_NotZeroAddress.selector);
        dsc.mint(address(0), 100);
        vm.stopPrank();
    }

    function testMintRevertsIfAmountIsZero() public {
        vm.startPrank(dsc.owner());
        vm.expectRevert(Dsc.DSC__MustBeMoreThanZero.selector);
        dsc.mint(address(this), 0);
        vm.stopPrank();
    }

    function testMint() public {
        vm.startPrank(dsc.owner());
        dsc.mint(address(this), 100);
        vm.stopPrank();
    }
}
