// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";

contract CustomHook is BaseHook {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    struct Position {
        int24 tickUpper;
        int24 tickLower;
        uint128 amount0;
        uint128 amount1;
        bool inRange;
        uint256 nonce;
        bool exists;
    }

    mapping(address => mapping(uint256 => Position)) public userPositions;
    mapping(address => uint256) public nonceCount;

    error MustUseDynamicFee();
    error NoHookDataProvided();
    error NoAddressGiven();

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

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
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: true,
                afterRemoveLiquidity: true,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // function _beforeInitialize(
    //     address,
    //     PoolKey calldata key,
    //     uint160
    // ) internal pure override returns (bytes4) {
    //     if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
    //     return this.beforeInitialize.selector;
    // }

    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        if (hookData.length == 0) revert NoHookDataProvided();
        address currentUser = abi.decode(hookData, (address));
        if (currentUser == address(0)) revert NoAddressGiven();
        uint256 currentUserNonce = nonceCount[currentUser];

        if (!userPositions[currentUser][currentUserNonce].exists) {
            // get the current tick in the pool
            (, int24 currentTick, , ) = poolManager.getSlot0(key.toId());
            // check if params of the addeed liq is in range of the current tick
            bool inRange = params.tickLower <= currentTick &&
                currentTick < params.tickUpper;
            if (inRange) {
                // if in range give bool true
                userPositions[currentUser][currentUserNonce] = Position({
                    tickUpper: params.tickUpper,
                    tickLower: params.tickLower,
                    amount0: uint128(delta.amount0()),
                    amount1: uint128(delta.amount1()),
                    inRange: true,
                    nonce: currentUserNonce,
                    exists: true
                });
            } else {
                // else not
                userPositions[currentUser][currentUserNonce] = Position({
                    tickUpper: params.tickUpper,
                    tickLower: params.tickLower,
                    amount0: uint128(delta.amount0()),
                    amount1: uint128(delta.amount1()),
                    inRange: false,
                    nonce: currentUserNonce,
                    exists: true
                });
            }
            nonceCount[currentUser] = currentUserNonce + 1;
        } else {
            // laslty if user just adding to current position just add liquiuduty
            userPositions[currentUser][currentUserNonce].amount0 += uint128(
                delta.amount0()
            );
            userPositions[currentUser][currentUserNonce].amount1 += uint128(
                delta.amount1()
            );
        }
        return (this.afterAddLiquidity.selector, delta);
    }

    function _afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {}

    function _beforeSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) internal view override returns (bytes4, BeforeSwapDelta, uint24) {}

    function _afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {}
}
