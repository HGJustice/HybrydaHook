// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {CustomHook} from "../src/CustomHook.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

contract CustomCurveTest is Test, Deployers {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    MockERC20 token;

    Currency ethCurrency = Currency.wrap(address(0));
    Currency tokenCurrency;

    CustomHook hook;

    function setUp() public {
        deployFreshManagerAndRouters();

        token = new MockERC20("Tether", "USDT", 6);
        tokenCurrency = Currency.wrap(address(token));
        token.mint(address(this), 1000 ether);

        address hookAddress = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG |
                    Hooks.AFTER_ADD_LIQUIDITY_FLAG |
                    Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
                    Hooks.BEFORE_SWAP_FLAG |
                    Hooks.AFTER_SWAP_FLAG |
                    Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            )
        );
        deployCodeTo("CustomHook.sol", abi.encode(manager), hookAddress);
        hook = CustomHook(hookAddress);

        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);

        (key, ) = initPool(
            ethCurrency,
            tokenCurrency,
            hook,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            SQRT_PRICE_1_1 // 1 for 1 ratio of both coins in pool
        );
    }

    function test_addLiquidity() public {
        bytes memory hookData = abi.encode(address(this));

        // test if registers in range positions
        uint160 sqrtPriceAtTickLower = TickMath.getSqrtPriceAtTick(-60);

        uint256 ethToAdd = 2 ether;
        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmount0(
            sqrtPriceAtTickLower,
            SQRT_PRICE_1_1,
            ethToAdd
        );

        modifyLiquidityRouter.modifyLiquidity{value: ethToAdd}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: int256(uint256(liquidityDelta)),
                salt: bytes32(0)
            }),
            hookData
        );

        (, , , , , bool inRange, uint256 nonce, bool exists) = hook
            .userPositions(address(this), 0);

        assertEq(exists, true, "Position should exist");
        assertEq(nonce, 0, "Nonce should be 0");
        assertEq(inRange, true, "Position should be in range");

        // check if it registers out of range positions

        sqrtPriceAtTickLower = TickMath.getSqrtPriceAtTick(60);

        ethToAdd = 2 ether;
        liquidityDelta = LiquidityAmounts.getLiquidityForAmount0(
            sqrtPriceAtTickLower,
            SQRT_PRICE_1_1,
            ethToAdd
        );

        modifyLiquidityRouter.modifyLiquidity{value: ethToAdd}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: 60,
                tickUpper: 120,
                liquidityDelta: int256(uint256(liquidityDelta)),
                salt: bytes32(0)
            }),
            hookData
        );

        (, , , , , bool inRange2, uint256 nonce2, bool exists2) = hook
            .userPositions(address(this), 1);

        assertEq(exists2, true, "Position should exist");
        assertEq(nonce2, 1, "Nonce should be 1");
        assertEq(inRange2, false, "Position should not be in range");
    }

    function test_partialRemoveLiquidity() public {
        bytes memory addHookData = abi.encode(address(this));
        bytes memory removeHookData = abi.encode(address(this), 0);

        // add liquiduty
        uint160 sqrtPriceAtTickLower = TickMath.getSqrtPriceAtTick(-60);

        uint256 ethToAdd = 2 ether;
        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmount0(
            sqrtPriceAtTickLower,
            SQRT_PRICE_1_1,
            ethToAdd
        );

        modifyLiquidityRouter.modifyLiquidity{value: ethToAdd}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: int256(uint256(liquidityDelta)),
                salt: bytes32(0)
            }),
            addHookData
        );

        (
            ,
            ,
            ,
            uint128 beforeAmount0,
            uint128 beforeAmount1,
            bool inRange,
            uint256 nonce,
            bool exists
        ) = hook.userPositions(address(this), 0);

        assertEq(exists, true, "Position should exist");
        assertEq(nonce, 0, "Nonce should be 0");
        assertEq(inRange, true, "Position should be in range");

        // remove half of liquiduty
        uint128 liquidityToRemove = liquidityDelta / 2;
        uint256 initialEthBalance = address(this).balance; // check user balance before removing

        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: -int256(uint256(liquidityToRemove)), // Negative for removal
                salt: bytes32(0)
            }),
            removeHookData
        );

        (
            ,
            ,
            ,
            uint128 afterAmount0,
            uint128 afterAmount1,
            ,
            ,
            bool existsAfter
        ) = hook.userPositions(address(this), 0);

        assertEq(
            existsAfter,
            true,
            "Position should still exist after removing partial liquidity"
        );
        assertLt(
            afterAmount0,
            beforeAmount0,
            "ETH amount should decrease after partial removal"
        );
        assertGt(
            address(this).balance,
            initialEthBalance,
            "ETH balance should increase after removal"
        );
    }

    function test_fullRemoveLiquidity() public {
        bytes memory addHookData = abi.encode(address(this));
        bytes memory removeHookData = abi.encode(address(this), 0);

        // add liquiduty
        uint160 sqrtPriceAtTickLower = TickMath.getSqrtPriceAtTick(-60);

        uint256 ethToAdd = 2 ether;
        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmount0(
            sqrtPriceAtTickLower,
            SQRT_PRICE_1_1,
            ethToAdd
        );

        modifyLiquidityRouter.modifyLiquidity{value: ethToAdd}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: int256(uint256(liquidityDelta)),
                salt: bytes32(0)
            }),
            addHookData
        );

        (
            ,
            ,
            ,
            uint128 beforeAmount0,
            uint128 beforeAmount1,
            bool inRange,
            uint256 nonce,
            bool exists
        ) = hook.userPositions(address(this), 0);

        assertEq(exists, true, "Position should exist");
        assertEq(nonce, 0, "Nonce should be 0");
        assertEq(inRange, true, "Position should be in range");

        uint256 initialEthBalance = address(this).balance;
        //remove all liquiduty and check bool
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: -int256(uint256(liquidityDelta)),
                salt: bytes32(0)
            }),
            removeHookData
        );

        (, , , , , , , bool existsAfter) = hook.userPositions(address(this), 0);

        assertEq(
            existsAfter,
            false,
            "Position should be marked as non-existent after full removal"
        );
        assertGt(
            address(this).balance,
            initialEthBalance,
            "ETH balance should increase after final removal"
        );
    }
}
