// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

contract CSMM is BaseHook {
    using CurrencySettler for Currency;

    struct CallbackData {
        uint256 amountEach;
        Currency currency0;
        Currency currency1;
        address sender;
    }

    error AddLiquidityThroughHook(); // error to throw when someone tries adding liquidity directly to the PoolManager

    constructor(IPoolManager poolManager) BaseHook(poolManager) {}

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: true, // Don't allow adding liquidity normally
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true, // Override how swaps are done
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true, // Allow beforeSwap to return a custom delta
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function _beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal pure override returns (bytes4) {
        revert AddLiquidityThroughHook();
    }

    // Custom add liquidity function
    function addLiquidity(PoolKey calldata key, uint256 amountEach) external {
        poolManager.unlock(
            abi.encode(
                CallbackData(
                    amountEach,
                    key.currency0,
                    key.currency1,
                    msg.sender
                )
            )
        );
    }

    function unlockCallback(
        bytes calldata data
    ) external onlyPoolManager returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        callbackData.currency0.settle(
            poolManager,
            callbackData.sender,
            callbackData.amountEach,
            false
        );

        callbackData.currency1.settle(
            poolManager,
            callbackData.sender,
            callbackData.amountEach,
            false
        );

        callbackData.currency0.take(
            poolManager,
            address(this),
            callbackData.amountEach,
            true
        );

        callbackData.currency1.take(
            poolManager,
            address(this),
            callbackData.amountEach,
            true
        );

        return "";
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        uint256 amountInOutPosetive = params.amountSpecified > 0
            ? uint256(params.amountSpecified)
            : uint256(-params.amountSpecified);

        BeforeSwapDelta beforeSwapDelta = toBeforeSwapDelta(
            int128(-params.amountSpecified),
            int128(params.amountSpecified)
        );

        if (params.zeroForOne) {
            key.currency0.take(
                poolManager,
                address(this),
                amountInOutPosetive,
                true
            );

            key.currency1.settle(
                poolManager,
                address(this),
                amountInOutPosetive,
                true
            );
        } else {
            key.currency0.settle(
                poolManager,
                address(this),
                amountInOutPosetive,
                true
            );

            key.currency1.take(
                poolManager,
                address(this),
                amountInOutPosetive,
                true
            );
        }

        return (this.beforeSwap.selector, beforeSwapDelta, 0);
    }
}
