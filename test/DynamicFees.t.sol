// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {CustomHook} from "../src/CustomHook.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {console} from "forge-std/console.sol";

contract DynamicFeesTest is Test, Deployers {
    using PoolIdLibrary for PoolId;
    using LPFeeLibrary for uint24;

    MockERC20 token;

    Currency ethCurrency = Currency.wrap(address(0));
    Currency usdtCurrency;

    CustomHook hook;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

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
        uint256 indexSlot = 6;
        vm.store(address(hook), bytes32(indexSlot), bytes32(uint256(15)));

        (key, ) = initPool(
            currency0,
            currency1,
            hook,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            SQRT_PRICE_1_1
        );
        bytes memory addHookData = abi.encode(address(this));

        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1000 ether,
                salt: bytes32(0)
            }),
            addHookData
        );
    }

    function test_IndexIsSet() public view {
        uint256 currentIndex = hook.index();
        assertEq(currentIndex, 15, "Index should be set to 15");
    }

    function test_DifferentSwapLevels() public {
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        // Extreme fear (15)
        uint256 balanceOfToken1Before = currency1.balanceOfSelf();

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );
        uint256 balanceOfToken1After = currency1.balanceOfSelf();
        uint256 extremeFearOutput = balanceOfToken1After -
            balanceOfToken1Before;
        console.log("Extreme Fear Output (2x fee):", extremeFearOutput);

        // Fear (25)
        uint256 indexSlot = 6;
        vm.store(address(hook), bytes32(indexSlot), bytes32(uint256(25)));
        balanceOfToken1Before = currency1.balanceOfSelf();
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );
        balanceOfToken1After = currency1.balanceOfSelf();
        uint256 fearOutput = balanceOfToken1After - balanceOfToken1Before;
        console.log("Fear Output (1.5x fee):", fearOutput);

        // Neutral (50)
        vm.store(address(hook), bytes32(indexSlot), bytes32(uint256(50)));
        balanceOfToken1Before = currency1.balanceOfSelf();
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );
        balanceOfToken1After = currency1.balanceOfSelf();
        uint256 neutralOutput = balanceOfToken1After - balanceOfToken1Before;
        console.log("Neutral Output (1x fee):", neutralOutput);

        // Greed (70)
        vm.store(address(hook), bytes32(indexSlot), bytes32(uint256(70)));
        balanceOfToken1Before = currency1.balanceOfSelf();
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );
        balanceOfToken1After = currency1.balanceOfSelf();
        uint256 greedOutput = balanceOfToken1After - balanceOfToken1Before;
        console.log("Greed Output (1.5x fee):", greedOutput);

        // Extreme Greed (90)
        vm.store(address(hook), bytes32(indexSlot), bytes32(uint256(90)));
        balanceOfToken1Before = currency1.balanceOfSelf();
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );
        balanceOfToken1After = currency1.balanceOfSelf();
        uint256 extremeGreedOutput = balanceOfToken1After -
            balanceOfToken1Before;
        console.log("Extreme Greed Output (2x fee):", extremeGreedOutput);

        assertGt(
            neutralOutput,
            fearOutput,
            "Neutral fee should be lower than Fear fee"
        );
        assertGt(
            neutralOutput,
            greedOutput,
            "Neutral fee should be lower than Greed fee"
        );

        assertGt(
            fearOutput,
            extremeFearOutput,
            "Fear fee should be lower than Extreme Fear fee"
        );
        assertGt(
            greedOutput,
            extremeGreedOutput,
            "Greed fee should be lower than Extreme Greed fee"
        );

        assertApproxEqAbs(
            extremeFearOutput,
            extremeGreedOutput,
            1e16,
            "Extreme Fear and Greed should have similar outputs"
        );
    }
}
