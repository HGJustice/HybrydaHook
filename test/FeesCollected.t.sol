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

contract FeesCollected is Test, Deployers {
    using PoolIdLibrary for PoolId;
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
                liquidityDelta: 1000 ether,
                salt: bytes32(0)
            }),
            addHookData
        );
    }

    function test_feesCollected() public {
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        // for (uint i = 0; i < 5; i++) {
        //     swapRouter.swap(
        //         key,
        //         IPoolManager.SwapParams({
        //             zeroForOne: true,                                 //works for true: zeroForOne
        //             amountSpecified: -0.1 ether,
        //             sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        //         }),
        //         settings,
        //         ZERO_BYTES
        //     );
        // }

        for (uint i = 0; i < 5; i++) {
            swapRouter.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: false,
                    amountSpecified: -0.1 ether,
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
                }),
                settings,
                ZERO_BYTES
            );
        }

        uint256 token0ClaimID = CurrencyLibrary.toId(key.currency0);
        uint256 token1ClaimID = CurrencyLibrary.toId(key.currency1);

        uint256 token0Claims = manager.balanceOf(address(hook), token0ClaimID);
        uint256 token1Claims = manager.balanceOf(address(hook), token1ClaimID);

        console.log("Hook's token0 claim balance:", token0Claims);
        console.log("Hook's token1 claim balance:", token1Claims);
    }
}
