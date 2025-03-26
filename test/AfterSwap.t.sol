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
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

contract AfterSwapTest is Test, Deployers {
    using PoolIdLibrary for PoolId;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

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
                liquidityDelta: 1000 ether, // in range liquidity
                salt: bytes32(0)
            }),
            addHookData
        );

        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: 60,
                tickUpper: 120,
                liquidityDelta: 500 ether, // out range liquidity
                salt: bytes32(0)
            }),
            addHookData
        );
    }

    function test_newLiquidityRangeStatus() public {
        (, int24 currentTick, , ) = manager.getSlot0(key.toId());
        console.log("Current tick before test:", currentTick);

        bytes memory addHookData = abi.encode(address(this));

        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: 0,
                tickUpper: 60,
                liquidityDelta: 300 ether,
                salt: bytes32(0)
            }),
            addHookData
        );

        uint128 startInRangeLiquidity = hook.inRangeLiquidity();
        uint128 startOutRangeLiquidity = hook.outRangeLiquidity();

        console.log(
            "After adding liquidity - in-range:",
            startInRangeLiquidity
        );
        console.log(
            "After adding liquidity - out-range:",
            startOutRangeLiquidity
        );

        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        for (uint i = 0; i < 100; i++) {
            swapRouter.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: false,
                    amountSpecified: -0.05 ether,
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
                }),
                settings,
                ZERO_BYTES
            );
        }

        (, int24 newTick, , ) = manager.getSlot0(key.toId());
        console.log("Current tick after swaps:", newTick);

        uint128 afterSwapInRangeLiquidity = hook.inRangeLiquidity();
        uint128 afterSwapOutRangeLiquidity = hook.outRangeLiquidity();

        console.log(
            "After swaps - in-range liquidity:",
            afterSwapInRangeLiquidity
        );
        console.log(
            "After swaps - out-range liquidity:",
            afterSwapOutRangeLiquidity
        );

        bool positionMovedOutOfRange = (afterSwapInRangeLiquidity <
            startInRangeLiquidity);
        bool outRangeLiquidityIncreased = (afterSwapOutRangeLiquidity >
            startOutRangeLiquidity);

        assertTrue(
            positionMovedOutOfRange,
            "Position should have moved out of range"
        );
        assertTrue(
            outRangeLiquidityIncreased,
            "Out-range liquidity should have increased"
        );

        assertEq(
            afterSwapInRangeLiquidity,
            500 ether,
            "In-range liquidity should be equal to Position 2 size"
        );

        assertEq(
            afterSwapOutRangeLiquidity,
            1300 ether,
            "Out-range liquidity should include Position 1 and 3"
        );
    }
}
